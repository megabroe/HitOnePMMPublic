// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 }         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IBuilderRegistry } from "./IBuilderRegistry.sol";

/// @title BuilderRegistry
/// @notice A stake-gated builder registry: an address becomes an eligible builder by staking at
/// least `minStake` of `stakeToken`, and stops being one when it withdraws. The stake is a Sybil
/// barrier — naming yourself as a builder costs the same locked stake as anyone else. This is a
/// REFERENCE implementation living OUTSIDE the market, so the criteria can be swapped later by
/// deploying a different registry and pointing new markets at it; the market only ever reads
/// `isBuilder`.
///
/// `stakeToken == address(0)` ⇒ the stake is the native coin (ETH on MegaETH), staked via
/// `msg.value`. Otherwise it is an ERC-20 (e.g. MEGA), pulled `minStake` at a time via
/// `transferFrom`. There is no owner and no slashing; a builder withdraws its own stake at will.
contract BuilderRegistry is IBuilderRegistry, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable stakeToken; // 0 = native coin
    uint256 public immutable minStake;

    mapping(address => uint256) public stakeOf;

    event BuilderRegistered(address indexed builder, uint256 totalStake);
    event BuilderUnregistered(address indexed builder, uint256 returned);

    error StakeTooLow();
    error ZeroStake();
    error BadValue();
    error NativeTransferFailed();

    constructor(address stakeToken_, uint256 minStake_) {
        if (minStake_ == 0) revert StakeTooLow();
        stakeToken = stakeToken_;
        minStake   = minStake_;
    }

    /// @notice Register (or top up) by staking. Native: send the stake as `msg.value`. ERC-20:
    /// send no value and approve at least `minStake`, which is pulled. Reverts `StakeTooLow` if
    /// the running stake ends below the minimum.
    function register() external payable nonReentrant {
        uint256 s;
        if (stakeToken == address(0)) {
            s = stakeOf[msg.sender] + msg.value;
        } else {
            if (msg.value != 0) revert BadValue();
            IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), minStake);
            s = stakeOf[msg.sender] + minStake;
        }
        stakeOf[msg.sender] = s;
        if (s < minStake) revert StakeTooLow();
        emit BuilderRegistered(msg.sender, s);
    }

    /// @notice Withdraw the full stake and deregister (no cooldown). Accrued builder fees live in
    /// the market and are claimed there — unaffected by this.
    function unregister() external nonReentrant {
        uint256 s = stakeOf[msg.sender];
        if (s == 0) revert ZeroStake();
        stakeOf[msg.sender] = 0; // effects before interaction
        emit BuilderUnregistered(msg.sender, s);
        if (stakeToken == address(0)) {
            (bool ok, ) = payable(msg.sender).call{ value: s }("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(stakeToken).safeTransfer(msg.sender, s);
        }
    }

    /// @inheritdoc IBuilderRegistry
    function isBuilder(address b) external view override returns (bool) {
        uint256 s = stakeOf[b];
        return s >= minStake && s > 0;
    }
}
