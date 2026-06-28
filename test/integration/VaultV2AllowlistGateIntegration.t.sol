// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IVaultV2} from "@vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "@vault-v2/interfaces/IVaultV2Factory.sol";
import {ErrorsLib} from "@vault-v2/libraries/ErrorsLib.sol";

import {VaultV2AllowlistGate} from "@gates/VaultV2AllowlistGate.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";

/// @title VaultV2AllowlistGate Integration Tests
/// @notice Tests the gate with a real VaultV2 to verify it restricts vault usage
///         to an allowlisted executor (e.g. MidnightVaultExecutor) and preserves
///         liquidation/fee-accrual paths.
contract VaultV2AllowlistGateIntegrationTest is Test {
    IVaultV2Factory factory;
    IVaultV2 vault;
    VaultV2AllowlistGate gate;
    MockERC20 token;

    address vaultOwner = makeAddr("vaultOwner");
    address curator = makeAddr("curator");
    address executor = makeAddr("executor"); // simulates MidnightVaultExecutor
    address stranger = makeAddr("stranger");
    address mgmtFeeRecipient = makeAddr("mgmtFeeRecipient");
    address perfFeeRecipient = makeAddr("perfFeeRecipient");

    uint256 constant DEPOSIT_AMOUNT = 100e18;

    function setUp() public {
        token = new MockERC20("Mock Token", "MOCK", 18);
        factory = IVaultV2Factory(deployCode("VaultV2Factory.sol:VaultV2Factory"));

        // --- Deploy vault ---
        vault = IVaultV2(factory.createVaultV2(vaultOwner, address(token), bytes32(0)));

        // --- Roles ---
        vm.startPrank(vaultOwner);
        vault.setCurator(curator);
        vm.stopPrank();

        // --- Deploy gate ---
        gate = new VaultV2AllowlistGate(vaultOwner);

        // --- Allowlist executor with all permissions ---
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(executor, true, true, true, true);
        vm.prank(vaultOwner);
        gate.setAllowlist(roles);

        // --- Attach gate to all four vault slots (curator submit + execute) ---
        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setReceiveSharesGate, (address(gate))));
        vault.setReceiveSharesGate(address(gate));

        vault.submit(abi.encodeCall(IVaultV2.setSendSharesGate, (address(gate))));
        vault.setSendSharesGate(address(gate));

        vault.submit(abi.encodeCall(IVaultV2.setReceiveAssetsGate, (address(gate))));
        vault.setReceiveAssetsGate(address(gate));

        vault.submit(abi.encodeCall(IVaultV2.setSendAssetsGate, (address(gate))));
        vault.setSendAssetsGate(address(gate));
        vm.stopPrank();

        // --- Fund executor ---
        token.mint(executor, DEPOSIT_AMOUNT * 10);
        vm.prank(executor);
        token.approve(address(vault), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    //  Helpers
    // -----------------------------------------------------------------------

    /// @dev Executor deposits and returns shares minted.
    function _executorDeposit(uint256 assets) internal returns (uint256 shares) {
        vm.prank(executor);
        shares = vault.deposit(assets, executor);
    }

    // -----------------------------------------------------------------------
    //  Non-allowlisted user is blocked
    // -----------------------------------------------------------------------

    function test_Deposit_RevertsForNonAllowlistedUser() public {
        token.mint(stranger, DEPOSIT_AMOUNT);
        vm.prank(stranger);
        token.approve(address(vault), DEPOSIT_AMOUNT);

        // stranger is both msg.sender (canSendAssets) and onBehalf (canReceiveShares);
        // CannotReceiveShares is checked first.
        vm.prank(stranger);
        vm.expectRevert(ErrorsLib.CannotReceiveShares.selector);
        vault.deposit(DEPOSIT_AMOUNT, stranger);
    }

    function test_Deposit_RevertsWhenSenderNotAllowlisted() public {
        // Stranger sends assets on behalf of executor (executor CAN receive shares,
        // but stranger CANNOT send assets).
        token.mint(stranger, DEPOSIT_AMOUNT);
        vm.prank(stranger);
        token.approve(address(vault), DEPOSIT_AMOUNT);

        vm.prank(stranger);
        vm.expectRevert(ErrorsLib.CannotSendAssets.selector);
        vault.deposit(DEPOSIT_AMOUNT, executor);
    }

    function test_Withdraw_RevertsForNonAllowlistedShareHolder() public {
        // Executor deposits first (gets shares), then we give stranger shares
        // via direct storage to simulate an edge case.
        uint256 shares = _executorDeposit(DEPOSIT_AMOUNT);

        // Transfer shares from executor to stranger is also blocked, so give
        // stranger an allowance from executor instead — but stranger still can't
        // call withdraw because onBehalf=stranger has no canSendShares.
        // Instead: temporarily allowlist stranger to receive shares, transfer, then remove.
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(stranger, true, false, false, false);
        vm.prank(vaultOwner);
        gate.setAllowlist(roles);

        vm.prank(executor);
        vault.transfer(stranger, shares);

        // Remove stranger from allowlist
        roles[0] = VaultV2AllowlistGate.Role(stranger, false, false, false, false);
        vm.prank(vaultOwner);
        gate.setAllowlist(roles);

        // Stranger holds shares but cannot withdraw — canSendShares is false.
        vm.prank(stranger);
        vm.expectRevert(ErrorsLib.CannotSendShares.selector);
        vault.withdraw(DEPOSIT_AMOUNT, stranger, stranger);
    }

    function test_Withdraw_RevertsForNonAllowlistedReceiver() public {
        _executorDeposit(DEPOSIT_AMOUNT);

        // Executor tries to withdraw to stranger — stranger cannot receive assets.
        vm.prank(executor);
        vm.expectRevert(ErrorsLib.CannotReceiveAssets.selector);
        vault.withdraw(DEPOSIT_AMOUNT, stranger, executor);
    }

    function test_Transfer_RevertsForNonAllowlistedSender() public {
        _executorDeposit(DEPOSIT_AMOUNT);

        // Give stranger shares (temporarily allowlist to receive).
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(stranger, true, false, false, false);
        vm.prank(vaultOwner);
        gate.setAllowlist(roles);

        vm.prank(executor);
        vault.transfer(stranger, 1e18);

        // Remove receive permission.
        roles[0] = VaultV2AllowlistGate.Role(stranger, false, false, false, false);
        vm.prank(vaultOwner);
        gate.setAllowlist(roles);

        // Stranger cannot transfer — canSendShares is false.
        vm.prank(stranger);
        vm.expectRevert(ErrorsLib.CannotSendShares.selector);
        vault.transfer(executor, 1e18);
    }

    function test_Transfer_RevertsForNonAllowlistedReceiver() public {
        _executorDeposit(DEPOSIT_AMOUNT);

        // Executor tries to transfer shares to stranger — stranger cannot receive.
        vm.prank(executor);
        vm.expectRevert(ErrorsLib.CannotReceiveShares.selector);
        vault.transfer(stranger, 1e18);
    }

    // -----------------------------------------------------------------------
    //  Allowlisted executor succeeds
    // -----------------------------------------------------------------------

    function test_Deposit_SucceedsForAllowlistedExecutor() public {
        uint256 shares = _executorDeposit(DEPOSIT_AMOUNT);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(executor), shares);
        assertEq(token.balanceOf(address(vault)), DEPOSIT_AMOUNT);
    }

    function test_Withdraw_SucceedsForAllowlistedExecutor() public {
        _executorDeposit(DEPOSIT_AMOUNT);

        uint256 balBefore = token.balanceOf(executor);
        vm.prank(executor);
        vault.withdraw(DEPOSIT_AMOUNT, executor, executor);

        assertEq(token.balanceOf(executor), balBefore + DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(executor), 0);
    }

    function test_Redeem_SucceedsForAllowlistedExecutor() public {
        uint256 shares = _executorDeposit(DEPOSIT_AMOUNT);

        uint256 balBefore = token.balanceOf(executor);
        vm.prank(executor);
        vault.redeem(shares, executor, executor);

        assertEq(token.balanceOf(executor), balBefore + DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(executor), 0);
    }

    // -----------------------------------------------------------------------
    //  Liquidation mode: executor can always redeem seized shares
    // -----------------------------------------------------------------------

    /// @notice Simulates the liquidation flow where:
    ///   1. Midnight seizes collateral (vault shares) → executor receives them
    ///   2. Executor redeems shares for underlying
    ///   3. Executor transfers underlying to liquidator
    /// The vault gate must not block any of these steps.
    function test_Liquidation_ExecutorCanRedeemAndForwardToLiquidator() public {
        address liquidator = makeAddr("liquidator");

        // Executor deposits (simulating prior collateral setup).
        uint256 shares = _executorDeposit(DEPOSIT_AMOUNT);

        // Step 2: Executor redeems shares for underlying.
        vm.prank(executor);
        vault.redeem(shares, executor, executor);

        // Step 3: Executor transfers underlying to liquidator (plain ERC20, no gate).
        uint256 redeemed = token.balanceOf(executor);
        vm.prank(executor);
        token.transfer(liquidator, redeemed);

        assertGt(token.balanceOf(liquidator), 0);
        assertEq(vault.balanceOf(executor), 0);
    }

    /// @notice After the gate owner renounces ownership (making the allowlist
    ///         immutable), the executor can still redeem — liquidation is guaranteed
    ///         to work forever.
    function test_Liquidation_WorksAfterAllowlistFrozen() public {
        // Freeze the allowlist.
        vm.prank(vaultOwner);
        gate.renounceOwnership();
        assertEq(gate.owner(), address(0));

        // Nobody can modify allowlist anymore.
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(stranger, true, true, true, true);
        vm.prank(vaultOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, vaultOwner));
        gate.setAllowlist(roles);

        // But executor still works — full deposit + redeem cycle.
        uint256 shares = _executorDeposit(DEPOSIT_AMOUNT);
        assertGt(shares, 0);

        vm.prank(executor);
        vault.redeem(shares, executor, executor);

        assertEq(vault.balanceOf(executor), 0);
    }

    // -----------------------------------------------------------------------
    //  Fee recipients auto-whitelisted for receiving shares
    // -----------------------------------------------------------------------

    function test_FeeRecipient_CanReceiveSharesWithoutExplicitAllowlist() public {
        // Set fee recipients on vault (curator + timelocked).
        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setManagementFeeRecipient, (mgmtFeeRecipient)));
        vault.setManagementFeeRecipient(mgmtFeeRecipient);

        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (perfFeeRecipient)));
        vault.setPerformanceFeeRecipient(perfFeeRecipient);
        vm.stopPrank();

        // Fee recipients are NOT on the allowlist, but canReceiveShares returns true
        // when queried from the vault (msg.sender = vault).
        vm.prank(address(vault));
        assertTrue(gate.canReceiveShares(mgmtFeeRecipient));
        vm.prank(address(vault));
        assertTrue(gate.canReceiveShares(perfFeeRecipient));

        // Confirm they're not explicitly allowlisted.
        (, bool canReceive,,,) = gate.allowlist(mgmtFeeRecipient);
        assertFalse(canReceive);
    }

    function test_FeeRecipient_StrangerStillBlockedEvenIfFeeRecipientAllowed() public {
        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setManagementFeeRecipient, (mgmtFeeRecipient)));
        vault.setManagementFeeRecipient(mgmtFeeRecipient);
        vm.stopPrank();

        // Fee recipient can receive shares…
        vm.prank(address(vault));
        assertTrue(gate.canReceiveShares(mgmtFeeRecipient));

        // …but stranger still cannot.
        vm.prank(address(vault));
        assertFalse(gate.canReceiveShares(stranger));
    }

    function test_FeeRecipient_CanRedeemAccruedFeesAfterAllowlistFrozen() public {
        uint256 mgmtFee = 0.01e18 / uint256(365 days);
        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.setManagementFeeRecipient, (mgmtFeeRecipient)));
        vault.setManagementFeeRecipient(mgmtFeeRecipient);

        vault.submit(abi.encodeCall(IVaultV2.setManagementFee, (mgmtFee)));
        vault.setManagementFee(mgmtFee);
        vm.stopPrank();

        _executorDeposit(DEPOSIT_AMOUNT);

        vm.prank(vaultOwner);
        gate.renounceOwnership();
        (, bool canReceive, bool canSend, bool canReceiveAssets,) = gate.allowlist(mgmtFeeRecipient);
        assertFalse(canReceive);
        assertFalse(canSend);
        assertFalse(canReceiveAssets);

        skip(365 days);
        vault.accrueInterest();
        uint256 feeShares = vault.balanceOf(mgmtFeeRecipient);
        assertGt(feeShares, 0);

        vm.prank(mgmtFeeRecipient);
        uint256 redeemed = vault.redeem(feeShares, mgmtFeeRecipient, mgmtFeeRecipient);

        assertGt(redeemed, 0);
        assertEq(token.balanceOf(mgmtFeeRecipient), redeemed);
        assertEq(vault.balanceOf(mgmtFeeRecipient), 0);
    }

    // -----------------------------------------------------------------------
    //  Multiple executors
    // -----------------------------------------------------------------------

    function test_MultipleExecutors_BothCanOperate() public {
        address executor2 = makeAddr("executor2");

        // Allowlist second executor.
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(executor2, true, true, true, true);
        vm.prank(vaultOwner);
        gate.setAllowlist(roles);

        // Fund and approve.
        token.mint(executor2, DEPOSIT_AMOUNT);
        vm.prank(executor2);
        token.approve(address(vault), type(uint256).max);

        // Both can deposit.
        uint256 shares1 = _executorDeposit(DEPOSIT_AMOUNT);
        vm.prank(executor2);
        uint256 shares2 = vault.deposit(DEPOSIT_AMOUNT, executor2);

        assertGt(shares1, 0);
        assertGt(shares2, 0);

        // Both can redeem.
        vm.prank(executor);
        vault.redeem(shares1, executor, executor);
        vm.prank(executor2);
        vault.redeem(shares2, executor2, executor2);

        assertEq(vault.balanceOf(executor), 0);
        assertEq(vault.balanceOf(executor2), 0);
    }

    // -----------------------------------------------------------------------
    //  Revoking executor access blocks future operations
    // -----------------------------------------------------------------------

    function test_RevokedExecutor_CannotDeposit() public {
        // Revoke executor access.
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(executor, false, false, false, false);
        vm.prank(vaultOwner);
        gate.setAllowlist(roles);

        vm.prank(executor);
        vm.expectRevert(ErrorsLib.CannotReceiveShares.selector);
        vault.deposit(DEPOSIT_AMOUNT, executor);
    }

    function test_RevokedExecutor_CannotWithdrawExistingShares() public {
        // Deposit while still allowlisted.
        _executorDeposit(DEPOSIT_AMOUNT);

        // Revoke.
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](1);
        roles[0] = VaultV2AllowlistGate.Role(executor, false, false, false, false);
        vm.prank(vaultOwner);
        gate.setAllowlist(roles);

        vm.prank(executor);
        vm.expectRevert(ErrorsLib.CannotSendShares.selector);
        vault.withdraw(DEPOSIT_AMOUNT, executor, executor);
    }
}
