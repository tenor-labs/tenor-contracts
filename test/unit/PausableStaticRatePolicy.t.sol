// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PausableStaticRatePolicy} from "../../src/ratifiers/policies/PausableStaticRatePolicy.sol";
import {IPausableInterestRatePolicy} from "../../src/ratifiers/interfaces/IPausableInterestRatePolicy.sol";

contract PausableStaticRatePolicyTest is Test {
    PausableStaticRatePolicy internal policy;
    address internal pauser;

    uint128 constant RATE_A = 1e18;
    uint128 constant RATE_B = 2e18;
    uint128 constant DURATION_A = 0;
    uint128 constant DURATION_B = 3600;

    function setUp() public {
        vm.warp(1 days);

        pauser = makeAddr("pauser");

        uint128[] memory rates = new uint128[](2);
        rates[0] = RATE_A;
        rates[1] = RATE_B;

        uint128[] memory durations = new uint128[](2);
        durations[0] = DURATION_A;
        durations[1] = DURATION_B;

        policy = new PausableStaticRatePolicy(address(this), rates, durations);
        policy.setPauser(pauser, true);
    }

    function test_pauseUnpauseLifecycle() public {
        uint256 renewalStart = block.timestamp;

        // Unpaused by default — getRate works
        policy.getRate(bytes32(0), bytes32(0), renewalStart, address(2), 0, 0, false);

        // Pause
        vm.prank(pauser);
        policy.pause();
        vm.expectRevert(IPausableInterestRatePolicy.IsPaused.selector);
        policy.getRate(bytes32(0), bytes32(0), renewalStart, address(2), 0, 0, false);

        // Double-pause reverts
        vm.prank(pauser);
        vm.expectRevert(IPausableInterestRatePolicy.AlreadyPaused.selector);
        policy.pause();

        // Unpause (owner only)
        policy.unpause();
        policy.getRate(bytes32(0), bytes32(0), renewalStart, address(2), 0, 0, false);

        // Double-unpause reverts
        vm.expectRevert(IPausableInterestRatePolicy.NotPaused.selector);
        policy.unpause();
    }

    function test_accessControl() public {
        // Non-pauser cannot pause
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(IPausableInterestRatePolicy.OnlyPauser.selector);
        policy.pause();

        // Pauser cannot unpause (only owner)
        vm.prank(pauser);
        policy.pause();
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pauser));
        policy.unpause();

        // Non-owner cannot setPauser
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nobody));
        policy.setPauser(nobody, true);
    }

    function test_setPauser_addsAndRemoves() public {
        address newPauser = makeAddr("new");
        policy.setPauser(newPauser, true);
        assertTrue(policy.isPauser(newPauser));
        policy.setPauser(newPauser, false);
        assertFalse(policy.isPauser(newPauser));
    }

    function test_getRateStillInterpolates() public {
        // At renewalStart = block.timestamp, elapsed = 0, should return RATE_A
        uint256 rate = policy.getRate(bytes32(0), bytes32(0), block.timestamp, address(0), 0, 0, false);
        assertEq(rate, RATE_A);

        // At renewalStart = block.timestamp - DURATION_B, elapsed = DURATION_B, should return RATE_B
        rate = policy.getRate(bytes32(0), bytes32(0), block.timestamp - DURATION_B, address(0), 0, 0, false);
        assertEq(rate, RATE_B);

        // Midpoint: elapsed = DURATION_B / 2, should return midpoint rate
        rate = policy.getRate(bytes32(0), bytes32(0), block.timestamp - DURATION_B / 2, address(0), 0, 0, false);
        assertEq(rate, (RATE_A + RATE_B) / 2);

        // Past the last point: elapsed > DURATION_B, should clamp to RATE_B
        rate = policy.getRate(bytes32(0), bytes32(0), block.timestamp - DURATION_B * 2, address(0), 0, 0, false);
        assertEq(rate, RATE_B);
    }

    function test_ownerIsNotPauserByDefault() public {
        assertFalse(policy.isPauser(address(this)));
        vm.expectRevert(IPausableInterestRatePolicy.OnlyPauser.selector);
        policy.pause();
    }

    function test_pause_emitsEvent() public {
        vm.prank(pauser);
        vm.expectEmit(true, true, true, true, address(policy));
        emit IPausableInterestRatePolicy.Paused(pauser);
        policy.pause();
    }

    function test_unpause_emitsEvent() public {
        vm.prank(pauser);
        policy.pause();
        vm.expectEmit(true, true, true, true, address(policy));
        emit IPausableInterestRatePolicy.Unpaused(address(this));
        policy.unpause();
    }

    function test_setPauser_emitsEvent() public {
        address newPauser = makeAddr("new");
        vm.expectEmit(true, true, true, true, address(policy));
        emit IPausableInterestRatePolicy.PauserSet(newPauser, true);
        policy.setPauser(newPauser, true);

        vm.expectEmit(true, true, true, true, address(policy));
        emit IPausableInterestRatePolicy.PauserSet(newPauser, false);
        policy.setPauser(newPauser, false);
    }

    function test_removedPauser_cannotPause() public {
        policy.setPauser(pauser, false);
        assertFalse(policy.isPauser(pauser));
        vm.prank(pauser);
        vm.expectRevert(IPausableInterestRatePolicy.OnlyPauser.selector);
        policy.pause();
    }

    function testFuzz_getRate_revertsWhenPaused(
        bytes32 srcId,
        bytes32 tgtId,
        address b,
        uint256 c,
        uint256 d,
        uint256 e
    ) public {
        vm.prank(pauser);
        policy.pause();
        vm.expectRevert(IPausableInterestRatePolicy.IsPaused.selector);
        policy.getRate(srcId, tgtId, c, b, d, e, false);
    }
}
