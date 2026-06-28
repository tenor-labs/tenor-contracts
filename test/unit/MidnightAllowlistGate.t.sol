// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MidnightAllowlistGate} from "@gates/MidnightAllowlistGate.sol";

contract MidnightAllowlistGateTest is Test {
    MidnightAllowlistGate gate;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    function setUp() public {
        gate = new MidnightAllowlistGate(owner);
    }

    // --- Constructor ---

    function test_Constructor_SetsOwner() public view {
        assertEq(gate.owner(), owner);
    }

    // --- setAllowlist: access control ---

    function test_SetAllowlist_RevertsWhenNotOwner() public {
        MidnightAllowlistGate.Role[] memory roles = new MidnightAllowlistGate.Role[](1);
        roles[0] = MidnightAllowlistGate.Role(alice, true, true, true);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        gate.setAllowlist(roles);
    }

    function test_SetAllowlist_SucceedsAsOwner() public {
        MidnightAllowlistGate.Role[] memory roles = new MidnightAllowlistGate.Role[](1);
        roles[0] = MidnightAllowlistGate.Role(alice, true, false, true);

        vm.prank(owner);
        gate.setAllowlist(roles);

        assertTrue(gate.canIncreaseCredit(alice));
        assertFalse(gate.canIncreaseDebt(alice));
        assertTrue(gate.canLiquidate(alice));
    }

    // --- setAllowlist: behavior ---

    function test_SetAllowlist_EmitsEvent() public {
        MidnightAllowlistGate.Role[] memory roles = new MidnightAllowlistGate.Role[](1);
        roles[0] = MidnightAllowlistGate.Role(alice, true, false, true);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MidnightAllowlistGate.MidnightAllowlistUpdated(alice, true, false, true);
        gate.setAllowlist(roles);
    }

    function test_SetAllowlist_MultipleRoles() public {
        MidnightAllowlistGate.Role[] memory roles = new MidnightAllowlistGate.Role[](2);
        roles[0] = MidnightAllowlistGate.Role(alice, true, true, false);
        roles[1] = MidnightAllowlistGate.Role(bob, false, false, true);

        vm.prank(owner);
        gate.setAllowlist(roles);

        assertTrue(gate.canIncreaseCredit(alice));
        assertTrue(gate.canIncreaseDebt(alice));
        assertFalse(gate.canLiquidate(alice));

        assertFalse(gate.canIncreaseCredit(bob));
        assertFalse(gate.canIncreaseDebt(bob));
        assertTrue(gate.canLiquidate(bob));
    }

    function test_SetAllowlist_OverwritesPrevious() public {
        MidnightAllowlistGate.Role[] memory roles = new MidnightAllowlistGate.Role[](1);
        roles[0] = MidnightAllowlistGate.Role(alice, true, true, true);

        vm.prank(owner);
        gate.setAllowlist(roles);
        assertTrue(gate.canIncreaseCredit(alice));

        roles[0] = MidnightAllowlistGate.Role(alice, false, false, false);
        vm.prank(owner);
        gate.setAllowlist(roles);

        assertFalse(gate.canIncreaseCredit(alice));
        assertFalse(gate.canIncreaseDebt(alice));
        assertFalse(gate.canLiquidate(alice));
    }

    // --- Gate views: defaults ---

    function test_GateViews_DefaultToFalse() public view {
        assertFalse(gate.canIncreaseCredit(stranger));
        assertFalse(gate.canIncreaseDebt(stranger));
        assertFalse(gate.canLiquidate(stranger));
    }

    // --- Ownership: renounce makes immutable ---

    function test_RenounceOwnership_MakesAllowlistImmutable() public {
        MidnightAllowlistGate.Role[] memory roles = new MidnightAllowlistGate.Role[](1);
        roles[0] = MidnightAllowlistGate.Role(alice, true, true, true);

        vm.prank(owner);
        gate.setAllowlist(roles);

        vm.prank(owner);
        gate.renounceOwnership();

        assertEq(gate.owner(), address(0));

        // Owner can no longer modify allowlist
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        gate.setAllowlist(roles);

        // But existing allowlist still works
        assertTrue(gate.canIncreaseCredit(alice));
    }

    // --- Ownership: transfer ---

    function test_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        gate.transferOwnership(newOwner);

        // Ownership not yet transferred — pending acceptance
        assertEq(gate.owner(), owner);
        assertEq(gate.pendingOwner(), newOwner);

        vm.prank(newOwner);
        gate.acceptOwnership();

        assertEq(gate.owner(), newOwner);

        MidnightAllowlistGate.Role[] memory roles = new MidnightAllowlistGate.Role[](1);
        roles[0] = MidnightAllowlistGate.Role(alice, true, true, true);

        vm.prank(newOwner);
        gate.setAllowlist(roles);
        assertTrue(gate.canIncreaseCredit(alice));
    }
}
