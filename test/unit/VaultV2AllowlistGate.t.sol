// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VaultV2AllowlistGate} from "@gates/VaultV2AllowlistGate.sol";

/// @title Mock VaultV2 exposing fee recipients for gate tests
contract MockVaultV2 {
    address public managementFeeRecipient;
    address public performanceFeeRecipient;

    function setManagementFeeRecipient(address recipient) external {
        managementFeeRecipient = recipient;
    }

    function setPerformanceFeeRecipient(address recipient) external {
        performanceFeeRecipient = recipient;
    }
}

contract VaultV2AllowlistGateTest is Test {
    VaultV2AllowlistGate gate;
    MockVaultV2 vault;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");
    address feeRecipient = makeAddr("feeRecipient");
    address perfFeeRecipient = makeAddr("perfFeeRecipient");

    function setUp() public {
        gate = new VaultV2AllowlistGate(owner);
        vault = new MockVaultV2();
        vault.setManagementFeeRecipient(feeRecipient);
        vault.setPerformanceFeeRecipient(perfFeeRecipient);
    }

    // --- Constructor ---

    function test_Constructor_SetsOwner() public view {
        assertEq(gate.owner(), owner);
    }

    // --- setAllowlist: access control ---

    function test_SetAllowlist_RevertsWhenNotOwner() public {
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(alice, true, true, true, true);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        gate.setAllowlist(roles);
    }

    function test_SetAllowlist_SucceedsAsOwner() public {
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(alice, true, false, true, false);

        vm.prank(owner);
        gate.setAllowlist(roles);

        vm.startPrank(address(vault));
        assertTrue(gate.canReceiveShares(alice));
        assertFalse(gate.canSendShares(alice));
        assertTrue(gate.canReceiveAssets(alice));
        assertFalse(gate.canSendAssets(alice));
        vm.stopPrank();
    }

    // --- setAllowlist: behavior ---

    function test_SetAllowlist_EmitsEvent() public {
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(alice, true, false, true, false);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit VaultV2AllowlistGate.VaultV2AllowlistUpdated(alice, true, false, true, false);
        gate.setAllowlist(roles);
    }

    function test_SetAllowlist_MultipleRoles() public {
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](2);
        roles[0] = VaultV2AllowlistGate.Role(alice, true, true, false, false);
        roles[1] = VaultV2AllowlistGate.Role(bob, false, false, true, true);

        vm.prank(owner);
        gate.setAllowlist(roles);

        vm.startPrank(address(vault));
        assertTrue(gate.canReceiveShares(alice));
        assertTrue(gate.canSendShares(alice));
        assertFalse(gate.canReceiveAssets(alice));
        assertFalse(gate.canSendAssets(alice));

        assertFalse(gate.canReceiveShares(bob));
        assertFalse(gate.canSendShares(bob));
        assertTrue(gate.canReceiveAssets(bob));
        assertTrue(gate.canSendAssets(bob));
        vm.stopPrank();
    }

    function test_SetAllowlist_OverwritesPrevious() public {
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(alice, true, true, true, true);

        vm.prank(owner);
        gate.setAllowlist(roles);
        vm.prank(address(vault));
        assertTrue(gate.canReceiveShares(alice));

        roles[0] = VaultV2AllowlistGate.Role(alice, false, false, false, false);
        vm.prank(owner);
        gate.setAllowlist(roles);

        vm.startPrank(address(vault));
        assertFalse(gate.canReceiveShares(alice));
        assertFalse(gate.canSendShares(alice));
        assertFalse(gate.canReceiveAssets(alice));
        assertFalse(gate.canSendAssets(alice));
        vm.stopPrank();
    }

    // --- Gate views: defaults ---

    function test_GateViews_DefaultToFalse() public {
        vm.startPrank(address(vault));
        assertFalse(gate.canReceiveShares(stranger));
        assertFalse(gate.canSendShares(stranger));
        assertFalse(gate.canReceiveAssets(stranger));
        assertFalse(gate.canSendAssets(stranger));
        vm.stopPrank();
    }

    // --- Fee recipient auto-whitelist ---

    function test_CanReceiveShares_AllowsManagementFeeRecipient() public {
        vm.prank(address(vault));
        assertTrue(gate.canReceiveShares(feeRecipient));
    }

    function test_CanReceiveShares_AllowsPerformanceFeeRecipient() public {
        vm.prank(address(vault));
        assertTrue(gate.canReceiveShares(perfFeeRecipient));
    }

    function test_CanSendShares_AllowsManagementFeeRecipient() public {
        vm.prank(address(vault));
        assertTrue(gate.canSendShares(feeRecipient));
    }

    function test_CanSendShares_AllowsPerformanceFeeRecipient() public {
        vm.prank(address(vault));
        assertTrue(gate.canSendShares(perfFeeRecipient));
    }

    function test_CanReceiveAssets_AllowsManagementFeeRecipient() public {
        vm.prank(address(vault));
        assertTrue(gate.canReceiveAssets(feeRecipient));
    }

    function test_CanReceiveAssets_AllowsPerformanceFeeRecipient() public {
        vm.prank(address(vault));
        assertTrue(gate.canReceiveAssets(perfFeeRecipient));
    }

    function test_CanSendAssets_DoesNotExemptFeeRecipients() public {
        vm.prank(address(vault));
        assertFalse(gate.canSendAssets(feeRecipient));
        vm.prank(address(vault));
        assertFalse(gate.canSendAssets(perfFeeRecipient));
    }

    function test_FeeRecipientExemption_TracksManagementRecipientChange() public {
        address newRecipient = makeAddr("newFeeRecipient");
        vault.setManagementFeeRecipient(newRecipient);

        vm.startPrank(address(vault));
        assertTrue(gate.canReceiveShares(newRecipient));
        assertTrue(gate.canSendShares(newRecipient));
        assertTrue(gate.canReceiveAssets(newRecipient));

        assertFalse(gate.canReceiveShares(feeRecipient));
        assertFalse(gate.canSendShares(feeRecipient));
        assertFalse(gate.canReceiveAssets(feeRecipient));
        vm.stopPrank();
    }

    function test_FeeRecipientExemption_TracksPerformanceRecipientChange() public {
        address newRecipient = makeAddr("newPerfFeeRecipient");
        vault.setPerformanceFeeRecipient(newRecipient);

        vm.startPrank(address(vault));
        assertTrue(gate.canReceiveShares(newRecipient));
        assertTrue(gate.canSendShares(newRecipient));
        assertTrue(gate.canReceiveAssets(newRecipient));

        assertFalse(gate.canReceiveShares(perfFeeRecipient));
        assertFalse(gate.canSendShares(perfFeeRecipient));
        assertFalse(gate.canReceiveAssets(perfFeeRecipient));
        vm.stopPrank();
    }

    // --- Ownership: renounce makes immutable ---

    function test_RenounceOwnership_MakesAllowlistImmutable() public {
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(alice, true, true, true, true);

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
        vm.prank(address(vault));
        assertTrue(gate.canReceiveShares(alice));
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

        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(alice, true, true, true, true);

        vm.prank(newOwner);
        gate.setAllowlist(roles);
        vm.prank(address(vault));
        assertTrue(gate.canReceiveShares(alice));
    }
}
