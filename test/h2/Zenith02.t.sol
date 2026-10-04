// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";
import { IH2Oracle }  from "../../src/h2/IH2Oracle.sol";

/// A fallback aggregator that is down (#2).
contract RevertingAgg {
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) { revert("down"); }
}

/// Zenith #2 — an unavailable fallback (reverting or answering badly) is skipped on the operator
/// path like a stale one; where the fallback is mandatory it still fails closed.
contract Zenith02 is H2MarketTest {
    uint256 internal _nn = 1000;

    function _ord(uint256 pk, uint256 m, bool isLong, bool isOpen, uint256 size, uint256 lev, uint256 target)
        internal returns (IH2Market.Order memory)
    {
        return IH2Market.Order({
            user: vm.addr(pk), marketId: m, isLong: isLong, isOpen: isOpen, size: size, leverage: lev,
            targetPrice: target, maxSlippageBps: 500, deadline: uint64(block.timestamp + 365 days),
            channel: 7, nonce: _nn++, builder: address(0), builderFeePpm: 0
        });
    }

    function _attach(uint256 mark, bytes memory data) internal {
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        oracle.pushAndCall(feedId, mark, calls);
    }

    function _orderData(uint256 m, IH2Market.Order memory o) internal view returns (bytes memory) {
        return abi.encode(m, uint8(IH2Market.ActionKind.Order_), abi.encode(o, _sign(alicePk, o)));
    }

    function _mktWithFallback(address fb) internal returns (uint256 m) {
        IH2Market.OracleParams memory o = _oracleParams();
        o.fallbackFeed = fb;
        vm.prank(op);
        m = h.createMarket(token, _fees(), _risk(0), o, _spread(), address(reg));
        _seedTreasury(m, 1_000_000e18);
    }

    function test_F02_badAnswerFallbackNoLongerBlocksFreshPrimaryClose() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp); // reference healthy: push valid
        fallbackFeed.setAnswer(0);                                  // fallback broken (answer <= 0)
        _attach(50_000e18, _orderData(mkt, _ord(alicePk, mkt, true, false, 1e18, 0, 50_000e18)));
        assertTrue(h.positions(id).closed, "close executes on the fresh primary");
    }

    function test_F02_revertingFallbackNoLongerBlocksPrimaryLiquidation() public {
        uint256 m = _mktWithFallback(address(new RevertingAgg()));
        _adv(1);
        _refresh(50_000e18);
        _attach(50_000e18, _orderData(m, _ord(alicePk, m, true, true, 1e18, 100, 50_000e18)));
        uint256 id = h.activePositionId(alice, m);
        assertTrue(id != 0, "open executes despite the reverting fallback");
        _adv(1);
        uint256[] memory ids = new uint256[](1); ids[0] = id;
        _refresh(49_000e18);
        _attach(49_000e18, abi.encode(m, uint8(IH2Market.ActionKind.Liquidate), abi.encode(ids)));
        assertTrue(h.positions(id).closed, "liquidation executes despite the reverting fallback");
    }

    function test_F02_requiredAnchorStillFailsClosed() public {
        _adv(2);
        fallbackFeed.setAnswer(0); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = _ord(alicePk, mkt, true, true, 1e18, 100, 50_200e18);
        bytes memory sig = _sign(alicePk, o);
        vm.expectRevert(IH2Market.OracleBadAnswer.selector);
        h.executeAtMark(o, sig);                 // self-service needs the anchor: still reverts
        _adv(300);
        vm.expectRevert(IH2Market.OracleBadAnswer.selector);
        h.executeAtFallback(o, sig);             // fallback mode needs a price: still reverts
    }
}
