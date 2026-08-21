// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { H2Oracle }  from "../../src/h2/H2Oracle.sol";
import { IH2Oracle, IH2OracleCallback } from "../../src/h2/IH2Oracle.sol";
import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";

/// @dev Records the mark it observed at callback time, and can be told to revert — to test
/// that the oracle isolates a failing call.
contract MockCallback is IH2OracleCallback {
    address public oracle;
    uint256 public lastFeedId;
    bytes   public lastData;
    uint256 public calls;
    bool    public boom;

    constructor(address o) { oracle = o; }
    function setBoom(bool b) external { boom = b; }

    function onMark(uint256 feedId, bytes calldata data) external override {
        require(msg.sender == oracle, "not oracle");
        if (boom) revert("boom");
        lastFeedId = feedId;
        lastData = data;
        calls++;
    }
}

contract H2OracleTest is Test {
    H2Oracle internal oracle;
    MockAggregatorV3 internal ref;
    address internal op = makeAddr("operator");

    uint64 internal constant RATE_CAP = 2_560_000_000_000_000; // ~1%/hour
    uint256 internal _t;
    function _adv(uint64 dt) internal { _t += dt; vm.warp(_t); }

    function setUp() public {
        _t = 1_786_986_000;
        vm.warp(_t);
        oracle = new H2Oracle();
        ref = new MockAggregatorV3(8, 50_000e8, block.timestamp);
    }

    function _bandedFeed() internal returns (uint256 id) {
        vm.prank(op);
        id = oracle.createFeed(op, 1e18, RATE_CAP, address(ref), 8, 100_000, 1 hours); // 10% band
    }

    function test_createFeedFreezesParams() public {
        uint256 id = _bandedFeed();
        IH2Oracle.FeedView memory f = oracle.feedOf(id);
        assertEq(f.operator, op);
        assertEq(f.priceTick, 1e18);
        assertEq(f.refFeed, address(ref));
        assertEq(uint256(f.maxRatePerSec), RATE_CAP);
    }

    function test_unbandedFeedRejectsBandFields() public {
        vm.prank(op);
        vm.expectRevert(IH2Oracle.BadFeedParams.selector);
        oracle.createFeed(op, 1e18, RATE_CAP, address(0), 0, 100_000, 0); // band with no feed
    }

    function test_onlyOperatorPushes() public {
        uint256 id = _bandedFeed();
        _adv(1);
        vm.expectRevert(IH2Oracle.NotOperator.selector);
        oracle.push(id, 50_000e18);
    }

    function test_pushChecksBand() public {
        uint256 id = _bandedFeed();
        _adv(1);
        vm.prank(op);
        vm.expectRevert(IH2Oracle.MarkOutOfBand.selector);
        oracle.push(id, 60_000e18); // ref 50k, 10% band → cap 55k
    }

    function test_pushEnforcesRateCap() public {
        uint256 id = _bandedFeed();
        _adv(1);
        IH2Oracle.Call[] memory none = new IH2Oracle.Call[](0);
        vm.prank(op);
        vm.expectRevert(IH2Oracle.RateCapExceeded.selector);
        oracle.pushWithParams(id, 50_000e18, int64(int256(uint256(RATE_CAP)) + 1), 0, 0, none);
    }

    function test_markMustBeTickMultiple() public {
        uint256 id = _bandedFeed();
        _adv(1);
        vm.prank(op);
        vm.expectRevert(IH2Oracle.BadMark.selector);
        oracle.push(id, 50_000e18 + 1);
    }

    function test_sameMillisecondReverts() public {
        uint256 id = _bandedFeed();
        _adv(1);
        vm.prank(op);
        oracle.push(id, 50_000e18);
        vm.prank(op);
        vm.expectRevert(IH2Oracle.MarkSameSlot.selector);
        oracle.push(id, 50_001e18); // same block.timestamp → same HP ms
    }

    function test_fundingIndexAccrues() public {
        uint256 id = _bandedFeed();
        _adv(1);
        IH2Oracle.Call[] memory none = new IH2Oracle.Call[](0);
        vm.prank(op);
        oracle.pushWithParams(id, 50_000e18, int64(uint64(RATE_CAP)), 0, 0, none); // long pays
        _adv(3600);
        // Index projects forward even without a new push.
        assertGt(oracle.indexNow(id, true), int128(0));
        assertEq(oracle.indexNow(id, false), int128(0));
    }

    function test_ratesAndSpreadAreStickyAcrossMarkOnlyPushes() public {
        uint256 id = _bandedFeed();
        IH2Oracle.Call[] memory none = new IH2Oracle.Call[](0);
        _adv(1);
        vm.prank(op);
        oracle.pushWithParams(id, 50_000e18, int64(uint64(RATE_CAP)), 0, 2_000, none); // set once
        // Subsequent hot pushes carry only the mark; rate + spread persist.
        _adv(1);
        vm.prank(op);
        oracle.push(id, 50_100e18);
        IH2Oracle.FeedView memory f = oracle.feedOf(id);
        assertEq(f.rateLong, int64(uint64(RATE_CAP)));
        assertEq(uint256(f.spreadPpm), 2_000);
        assertEq(f.mark, 50_100e18);
        // Funding still accrued over the interval at the sticky rate.
        _adv(3600);
        assertGt(oracle.indexNow(id, true), int128(0));
    }

    function test_pushAndCallDeliversMarkThenCallback() public {
        uint256 id = _bandedFeed();
        MockCallback cb = new MockCallback(address(oracle));
        _adv(1);
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(cb), data: hex"1234" });
        vm.prank(op);
        oracle.pushAndCall(id, 50_100e18, calls);
        assertEq(cb.calls(), 1);
        assertEq(cb.lastFeedId(), id);
        assertEq(oracle.feedOf(id).mark, 50_100e18); // committed before the callback ran
    }

    function test_callFailureIsIsolated() public {
        uint256 id = _bandedFeed();
        MockCallback cb = new MockCallback(address(oracle));
        cb.setBoom(true);
        _adv(1);
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(cb), data: hex"" });
        vm.prank(op);
        vm.expectEmit(true, true, false, true);
        emit IH2Oracle.CallFailed(id, 0, address(cb));
        oracle.pushAndCall(id, 50_100e18, calls); // mark still commits
        assertEq(oracle.feedOf(id).mark, 50_100e18);
        assertEq(cb.calls(), 0);
    }

    function test_futureStampedReferenceRejected() public {
        uint256 id = _bandedFeed();
        ref.setUpdatedAt(block.timestamp + 10 * 365 days);
        _adv(1);
        vm.prank(op);
        vm.expectRevert(IH2Oracle.RefBadAnswer.selector);
        oracle.push(id, 50_000e18);
    }

    function test_staleReferenceRejected() public {
        uint256 id = _bandedFeed();
        ref.setUpdatedAt(block.timestamp - 2 hours); // > 1h refMaxStale
        _adv(1);
        vm.prank(op);
        vm.expectRevert(IH2Oracle.RefStale.selector);
        oracle.push(id, 50_000e18);
    }
}
