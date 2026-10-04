// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";
import { IH2Oracle }  from "../../src/h2/IH2Oracle.sol";

/// Zenith #11 — onMark rejects every action kind it does not know; only Order_ and Liquidate route.
contract Zenith11 is H2MarketTest {
    function _attach(uint256 mark, bytes memory data) internal {
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        oracle.pushAndCall(feedId, mark, calls);
    }

    function test_F11_unknownActionKindIsRejected() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        uint256[] memory ids = new uint256[](1); ids[0] = id;
        _refresh(49_000e18);                                    // position IS liquidatable here
        bytes memory data = abi.encode(mkt, uint8(7), abi.encode(ids));
        _attach(49_000e18, data);                               // via the oracle: isolated failure
        assertFalse(h.positions(id).closed, "kind 7 does nothing");
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(IH2Market.BadActionKind.selector, uint8(7)));
        h.onMark(feedId, data);                                 // direct call shows the reason
        _adv(1); _refresh(49_000e18);
        _attach(49_000e18, abi.encode(mkt, uint8(IH2Market.ActionKind.Liquidate), abi.encode(ids)));
        assertTrue(h.positions(id).closed, "the real Liquidate kind still works");
    }
}
