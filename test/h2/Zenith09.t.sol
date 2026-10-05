// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { BuilderRegistry } from "../../src/h2/BuilderRegistry.sol";

/// A builder contract that can forward a payable register() but has no receive()/fallback.
contract NoReceiveBuilder {
    function reg(BuilderRegistry r) external payable { r.register{ value: msg.value }(); }
    function unreg(BuilderRegistry r) external { r.unregister(); }
    function unregTo(BuilderRegistry r, address payable to) external { r.unregisterTo(to); }
}

/// Zenith #9 — a builder can route its stake refund to an address of its choosing.
contract Zenith09 is H2MarketTest {
    function test_F09_contractBuilderUnregistersToAnotherAddress() public {
        NoReceiveBuilder b = new NoReceiveBuilder();
        vm.deal(address(this), MIN_BUILDER_STAKE);
        b.reg{ value: MIN_BUILDER_STAKE }(reg);
        vm.expectRevert(BuilderRegistry.NativeTransferFailed.selector);
        b.unreg(reg);                                   // plain path unchanged: stake would be stuck
        address payable treasury = payable(makeAddr("builderTreasury"));
        b.unregTo(reg, treasury);
        assertEq(treasury.balance, MIN_BUILDER_STAKE, "stake recovered to a chosen address");
        assertEq(reg.stakeOf(address(b)), 0);
        assertFalse(reg.isBuilder(address(b)));
    }

    function test_F09_unregisterToZeroReverts() public {
        vm.deal(address(this), MIN_BUILDER_STAKE);
        reg.register{ value: MIN_BUILDER_STAKE }();
        vm.expectRevert(BuilderRegistry.ZeroRecipient.selector);
        reg.unregisterTo(payable(address(0)));
    }
}
