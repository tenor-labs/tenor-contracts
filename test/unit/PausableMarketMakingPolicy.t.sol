// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PausableMarketMakingPolicy} from "../../src/ratifiers/policies/PausableMarketMakingPolicy.sol";
import {IPausableInterestRatePolicy} from "../../src/ratifiers/interfaces/IPausableInterestRatePolicy.sol";
import {IMarketMakingPolicy} from "../../src/ratifiers/interfaces/IMarketMakingPolicy.sol";

contract PausableMarketMakingPolicyTest is Test {
    PausableMarketMakingPolicy internal policy;
    address internal midnight = makeAddr("midnight");
    address internal owner = makeAddr("owner");
    address internal pauser = makeAddr("pauser");
    address internal mm = makeAddr("mm");

    bytes32 internal constant SRC = bytes32(uint256(0x5e1));
    bytes32 internal constant TGT = bytes32(uint256(0x6e1));

    function setUp() public {
        policy = new PausableMarketMakingPolicy(owner, midnight);
        vm.mockCall(midnight, abi.encodeWithSelector(IMidnight.isAuthorized.selector), abi.encode(false));
        vm.prank(owner);
        policy.setPauser(pauser, true);

        IMarketMakingPolicy.CurvePoint[] memory pts = new IMarketMakingPolicy.CurvePoint[](2);
        pts[0] = IMarketMakingPolicy.CurvePoint({ttm: 100, sellRate: 1e18, buyRate: 2e18});
        pts[1] = IMarketMakingPolicy.CurvePoint({ttm: 200, sellRate: 1e18, buyRate: 2e18});
        vm.prank(mm);
        policy.setCurve(mm, TGT, pts);
    }

    function test_pauseUnpauseLifecycle() public {
        vm.warp(1_000_000);

        // Unpaused → getRate works
        policy.getRate(SRC, TGT, 0, mm, 0, 1_000_150, true);

        // Pause
        vm.prank(pauser);
        policy.pause();
        vm.expectRevert(IPausableInterestRatePolicy.IsPaused.selector);
        policy.getRate(SRC, TGT, 0, mm, 0, 1_000_150, true);

        // Double-pause reverts
        vm.prank(pauser);
        vm.expectRevert(IPausableInterestRatePolicy.AlreadyPaused.selector);
        policy.pause();

        // Unpause (owner only)
        vm.prank(owner);
        policy.unpause();
        policy.getRate(SRC, TGT, 0, mm, 0, 1_000_150, true);

        // Double-unpause reverts
        vm.prank(owner);
        vm.expectRevert(IPausableInterestRatePolicy.NotPaused.selector);
        policy.unpause();
    }

    function test_pause_onlyPauser() public {
        vm.expectRevert(IPausableInterestRatePolicy.OnlyPauser.selector);
        policy.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(pauser);
        policy.pause();

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pauser));
        policy.unpause();
    }

    function test_setPauser_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        policy.setPauser(address(0xdead), true);
    }

    function test_setCurve_worksWhilePaused() public {
        // Pause should affect quotes, not curve administration.
        vm.prank(pauser);
        policy.pause();

        IMarketMakingPolicy.CurvePoint[] memory pts = new IMarketMakingPolicy.CurvePoint[](1);
        pts[0] = IMarketMakingPolicy.CurvePoint({ttm: 50, sellRate: 1e18, buyRate: 5e18});
        vm.prank(mm);
        policy.setCurve(mm, SRC, pts);
        // Wrote landed: the (only) point is reachable via the public mapping getter.
        policy.curves(mm, SRC, 0);
    }
}
