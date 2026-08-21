// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { H2Storage }    from "./H2Storage.sol";
import { ParamCatalog } from "../common/ParamCatalog.sol";

/// @title H2Orders
/// @notice User-signed-order verification, nonce lifecycle, and slippage-band checks.
///
/// Verification does not check the submitter: on the primary path the feed operator
/// relays orders inside mark commits, and on the fallback path anyone may submit — the
/// order names its `marketId`, which pins everything the user consented to, so nothing is
/// delegated to whoever carries it.
abstract contract H2Orders is H2Storage {
    function _orderDigest(Order memory o) internal view returns (bytes32) {
        bytes32 sh = keccak256(abi.encode(
            ORDER_TYPEHASH,
            o.user, o.marketId, o.isLong, o.isOpen, o.size, o.leverage,
            o.targetPrice, o.maxSlippageBps, o.deadline, o.channel, o.nonce
        ));
        return _hashTypedDataV4(sh);
    }

    /// @dev Verify sig + consume nonce. Submitter authorization is the CALLER's concern.
    function _verifyAndConsumeOrder(Order memory o, bytes memory sig) internal {
        if (block.timestamp > o.deadline) revert OrderExpired();
        if (nonceUsed[o.user][o.channel][o.nonce]) revert NonceAlreadyUsed();
        address signer = ECDSA.recover(_orderDigest(o), sig);
        if (signer != o.user) revert BadUserSig();
        nonceUsed[o.user][o.channel][o.nonce] = true;
        emit NonceUsed(o.user, o.channel, o.nonce);
    }

    /// @notice Retire the caller's own unspent (channel, nonce): a signed-but-abandoned
    /// order would otherwise be a free option to the world until its deadline. A cancel
    /// landing ahead of an in-flight commit reverts that order's execution — a normal
    /// outcome the operator stack must expect.
    function cancelNonce(uint256 channel, uint256 nonce) external override {
        if (nonceUsed[msg.sender][channel][nonce]) revert NonceAlreadyUsed();
        nonceUsed[msg.sender][channel][nonce] = true;
        emit NonceCancelled(msg.sender, channel, nonce);
    }

    /// @dev Enforce fillPrice within the user's [targetPrice ± maxSlippageBps] band.
    function _checkSlippageBand(uint256 fillPrice, uint256 targetPrice, uint256 maxSlippageBps) internal pure {
        uint256 diff = fillPrice > targetPrice ? fillPrice - targetPrice : targetPrice - fillPrice;
        if (diff * ParamCatalog.BPS_DENOM > targetPrice * maxSlippageBps) revert SlippageExceeded();
    }

    /// @dev Band check with the fee folded in adversely: the ALL-IN price (fill already
    /// carrying any spread, worsened further by the fee) must sit inside the signed band,
    /// bounding every formulaic cost by the user's own worst-price tolerance. The adverse
    /// direction is up for open-long and close-short, down for the other two — i.e.
    /// `up = (isLong == isOpen)`.
    function _checkBandWithFee(
        uint256 fillPrice, uint256 targetPrice, uint256 maxSlippageBps,
        bool isLong, bool isOpen, uint256 feePpm
    ) internal pure {
        uint256 feeImpact = fillPrice * feePpm / ParamCatalog.RATE_DENOM;
        bool up = (isLong == isOpen);
        uint256 effective = up ? fillPrice + feeImpact : fillPrice - feeImpact;
        _checkSlippageBand(effective, targetPrice, maxSlippageBps);
    }
}
