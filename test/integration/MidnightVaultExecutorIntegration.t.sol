// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {MidnightVaultExecutor} from "../../src/periphery/MidnightVaultExecutor.sol";
import {IMidnightVaultExecutor} from "../../src/periphery/interfaces/IMidnightVaultExecutor.sol";
import {VaultV2AllowlistGate} from "../../src/gates/VaultV2AllowlistGate.sol";
import {MidnightAllowlistGate} from "@gates/MidnightAllowlistGate.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TIME_TO_MAX_LIF} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {Oracle} from "../helpers/Oracle.sol";

import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {IVaultV2} from "@vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "@vault-v2/interfaces/IVaultV2Factory.sol";
import {ErrorsLib} from "@vault-v2/libraries/ErrorsLib.sol";

/// @title Integration tests for MidnightVaultExecutor
contract MidnightVaultExecutorIntegrationTest is Test {
    MidnightVaultExecutor executor;
    VaultV2AllowlistGate gate;
    Midnight midnight;
    EcrecoverRatifier ecrecoverRatifier;
    IVaultV2 vault;
    IVaultV2Factory factory;
    MockERC20 underlying;
    Oracle marketOracle;

    address vaultOwner;
    address vaultCurator;
    address user;
    uint256 userSK;
    address managementFeeRecipient;
    address bundler;

    uint256 constant INITIAL_BALANCE = 1_000_000e18;
    uint256 constant LLTV = 0.77e18;

    function setUp() public {
        // Setup addresses
        vaultOwner = makeAddr("vaultOwner");
        vaultCurator = makeAddr("vaultCurator");
        (user, userSK) = makeAddrAndKey("user");
        managementFeeRecipient = makeAddr("managementFeeRecipient");
        bundler = makeAddr("bundler");

        // Deploy tokens
        underlying = new MockERC20("Underlying", "UND", 18);

        // Midnight activates collateral by querying the oracle, so markets need a live one
        marketOracle = new Oracle();
        marketOracle.setPrice(1e36);

        // Deploy Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(user);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, user);

        // Deploy executor
        executor = new MidnightVaultExecutor(address(midnight));

        // Deploy VaultV2 via factory (deployCode avoids solc version conflict with Midnight)
        factory = IVaultV2Factory(deployCode("out/VaultV2Factory.sol/VaultV2Factory.json"));
        vault = IVaultV2(factory.createVaultV2(vaultOwner, address(underlying), bytes32(0)));

        // Setup vault: owner sets curator
        vm.prank(vaultOwner);
        vault.setCurator(vaultCurator);

        // Curator sets management fee recipient (timelocked, default timelock=0 so immediate)
        vm.prank(vaultCurator);
        vault.submit(abi.encodeCall(IVaultV2.setManagementFeeRecipient, (managementFeeRecipient)));
        vault.setManagementFeeRecipient(managementFeeRecipient);

        // Deploy gate (owned by this test contract)
        gate = new VaultV2AllowlistGate(address(this));

        // Allowlist midnight and executor to receive shares
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](2);
        roles[0] = VaultV2AllowlistGate.Role({
            user: address(midnight),
            canReceiveShares: true,
            canSendShares: true,
            canReceiveAssets: false,
            canSendAssets: false
        });
        roles[1] = VaultV2AllowlistGate.Role({
            user: address(executor),
            canReceiveShares: true,
            canSendShares: false,
            canReceiveAssets: false,
            canSendAssets: false
        });
        gate.setAllowlist(roles);

        // Set gate on vault (timelocked)
        vm.prank(vaultCurator);
        vault.submit(abi.encodeCall(IVaultV2.setReceiveSharesGate, (address(gate))));
        vault.setReceiveSharesGate(address(gate));

        // Mint tokens and authorize user
        underlying.mint(user, INITIAL_BALANCE);

        vm.prank(user);
        midnight.setIsAuthorized(address(executor), true, user);

        vm.prank(user);
        underlying.approve(address(executor), type(uint256).max);
    }

    /* HELPERS */

    function _createMarket() internal view returns (Market memory) {
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(marketOracle)
        });

        return Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(underlying),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    /* AUTHORIZATION TESTS (delegated to Midnight) */

    function test_OnBehalf_DepositWhenAuthorized() public {
        // User authorizes bundler on Midnight
        vm.prank(user);
        midnight.setIsAuthorized(bundler, true, user);

        Market memory market = _createMarket();

        // Bundler holds the assets and approves executor (assets pulled from msg.sender)
        uint256 depositAmount = 1000e18;
        underlying.mint(bundler, depositAmount);
        vm.prank(bundler);
        underlying.approve(address(executor), type(uint256).max);

        vm.prank(bundler);
        (uint256 shares,) = executor.depositAndAddCollateral(market, 0, depositAmount, 0, user);

        assertEq(shares, depositAmount, "Shares should equal deposit amount");
        assertEq(vault.balanceOf(address(midnight)), shares, "Midnight should hold shares");
    }

    function test_OnBehalf_WithdrawWhenAuthorized() public {
        vm.prank(user);
        midnight.setIsAuthorized(bundler, true, user);

        Market memory market = _createMarket();

        // Bundler holds the assets and approves executor
        uint256 depositAmount = 1000e18;
        underlying.mint(bundler, depositAmount);
        vm.prank(bundler);
        underlying.approve(address(executor), type(uint256).max);

        vm.prank(bundler);
        (uint256 shares,) = executor.depositAndAddCollateral(market, 0, depositAmount, 0, user);

        address receiver = makeAddr("receiver");
        vm.prank(bundler);
        uint256 assets = executor.withdrawCollateralAndRedeem(market, 0, shares, user, receiver);

        assertEq(assets, depositAmount, "Should receive original deposit amount back");
        assertEq(underlying.balanceOf(receiver), depositAmount, "Receiver should have assets");
    }

    function test_OnBehalf_RevertsWhenNotAuthorized() public {
        Market memory market = _createMarket();

        // Bundler tries to deposit on behalf of user without Midnight authorization - should revert
        vm.prank(bundler);
        vm.expectRevert(IMidnightVaultExecutor.Unauthorized.selector);
        executor.depositAndAddCollateral(market, 0, 1000e18, 0, user);
    }

    /* MIDNIGHT AUTHORIZATION TESTS */

    function test_DepositAndAddCollateral_SucceedsWhenAuthorized() public {
        Market memory market = _createMarket();

        uint256 depositAmount = 1000e18;
        vm.prank(user);
        (uint256 shares,) = executor.depositAndAddCollateral(market, 0, depositAmount, 0, user);

        assertEq(shares, depositAmount, "Shares should equal deposit amount");
        assertEq(underlying.balanceOf(user), INITIAL_BALANCE - depositAmount, "User should have spent underlying");
        assertEq(underlying.balanceOf(address(vault)), depositAmount, "Vault should have received underlying");
        // Shares go to Midnight (as collateral), not to user's wallet
        assertEq(vault.balanceOf(user), 0, "User should not hold shares directly");
        assertEq(vault.balanceOf(address(midnight)), shares, "Midnight should hold shares as collateral");
    }

    function test_DepositAndAddCollateral_MintMode() public {
        Market memory market = _createMarket();

        uint256 mintShares = 1000e18;
        vm.prank(user);
        (uint256 depositedShares, uint256 usedAssets) = executor.depositAndAddCollateral(market, 0, 0, mintShares, user);

        assertEq(depositedShares, mintShares, "Deposited shares should equal requested shares");
        assertEq(usedAssets, mintShares, "Used assets should equal shares (1:1 first deposit)");
        assertEq(vault.balanceOf(address(midnight)), mintShares, "Midnight should hold shares");
    }

    function test_DepositAndAddCollateral_RevertsOnInvalidInput() public {
        Market memory market = _createMarket();

        // Both zero - should revert
        vm.prank(user);
        vm.expectRevert(IMidnightVaultExecutor.InvalidInput.selector);
        executor.depositAndAddCollateral(market, 0, 0, 0, user);

        // Both non-zero - should revert
        vm.prank(user);
        vm.expectRevert(IMidnightVaultExecutor.InvalidInput.selector);
        executor.depositAndAddCollateral(market, 0, 1000e18, 1000e18, user);
    }

    function test_WithdrawCollateralAndRedeem_SucceedsWhenAuthorized() public {
        Market memory market = _createMarket();

        uint256 depositAmount = 1000e18;
        vm.prank(user);
        (uint256 shares,) = executor.depositAndAddCollateral(market, 0, depositAmount, 0, user);

        vm.prank(user);
        uint256 assets = executor.withdrawCollateralAndRedeem(market, 0, shares, user, user);

        assertEq(assets, depositAmount, "Should receive original deposit amount back");
        assertEq(underlying.balanceOf(user), INITIAL_BALANCE, "User should have original balance back");
        assertEq(vault.balanceOf(address(midnight)), 0, "Midnight should have no shares");
    }

    /* WITHDRAW AUTHORIZATION TESTS */

    function test_WithdrawCollateralAndRedeem_RevertsWhenNotAuthorized() public {
        Market memory market = _createMarket();

        // User deposits first
        uint256 depositAmount = 1000e18;
        vm.prank(user);
        (uint256 shares,) = executor.depositAndAddCollateral(market, 0, depositAmount, 0, user);

        // Bundler tries to withdraw without authorization — should revert
        vm.prank(bundler);
        vm.expectRevert(IMidnightVaultExecutor.Unauthorized.selector);
        executor.withdrawCollateralAndRedeem(market, 0, shares, user, bundler);
    }

    function test_WithdrawCollateralAndRedeem_DifferentReceiver() public {
        Market memory market = _createMarket();

        uint256 depositAmount = 1000e18;
        vm.prank(user);
        (uint256 shares,) = executor.depositAndAddCollateral(market, 0, depositAmount, 0, user);

        // Withdraw to a different receiver than onBehalf
        address receiver = makeAddr("receiver");
        vm.prank(user);
        uint256 assets = executor.withdrawCollateralAndRedeem(market, 0, shares, user, receiver);

        assertEq(assets, depositAmount, "Should redeem full amount");
        assertEq(underlying.balanceOf(receiver), depositAmount, "Receiver should have underlying");
        assertEq(
            underlying.balanceOf(user),
            INITIAL_BALANCE - depositAmount,
            "User balance unchanged (assets went to receiver)"
        );
    }

    /* MULTI-VAULT TESTS */

    function test_Executor_SupportsMultipleVaults() public {
        // Deploy second vault (reuse factory from setUp)
        MockERC20 underlying2 = new MockERC20("Underlying2", "UND2", 18);
        IVaultV2 vault2 = IVaultV2(factory.createVaultV2(vaultOwner, address(underlying2), bytes32(0)));

        // Setup vault2: curator + gate
        vm.prank(vaultOwner);
        vault2.setCurator(vaultCurator);

        // Deploy a separate gate for vault2
        VaultV2AllowlistGate gate2 = new VaultV2AllowlistGate(address(this));

        // Allowlist midnight and executor
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](2);
        roles[0] = VaultV2AllowlistGate.Role({
            user: address(midnight),
            canReceiveShares: true,
            canSendShares: true,
            canReceiveAssets: false,
            canSendAssets: false
        });
        roles[1] = VaultV2AllowlistGate.Role({
            user: address(executor),
            canReceiveShares: true,
            canSendShares: false,
            canReceiveAssets: false,
            canSendAssets: false
        });
        gate2.setAllowlist(roles);

        vm.prank(vaultCurator);
        vault2.submit(abi.encodeCall(IVaultV2.setReceiveSharesGate, (address(gate2))));
        vault2.setReceiveSharesGate(address(gate2));

        // Mint tokens
        underlying2.mint(user, INITIAL_BALANCE);

        // Approve executor for second underlying
        vm.prank(user);
        underlying2.approve(address(executor), INITIAL_BALANCE);

        // Create markets for both vaults
        Market memory market1 = _createMarket();

        CollateralParams[] memory collaterals2 = new CollateralParams[](1);
        collaterals2[0] = CollateralParams({
            token: address(vault2), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(marketOracle)
        });

        Market memory market2 = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(underlying2),
            collateralParams: collaterals2,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Deposit to both vaults via same executor
        vm.prank(user);
        (uint256 shares1,) = executor.depositAndAddCollateral(market1, 0, 1000e18, 0, user);

        vm.prank(user);
        (uint256 shares2,) = executor.depositAndAddCollateral(market2, 0, 2000e18, 0, user);

        // Verify both deposits succeeded
        assertEq(shares1, 1000e18, "First vault shares should be minted");
        assertEq(shares2, 2000e18, "Second vault shares should be minted");

        assertEq(vault.balanceOf(address(midnight)), shares1, "Midnight should hold first vault shares");
        assertEq(vault2.balanceOf(address(midnight)), shares2, "Midnight should hold second vault shares");
    }

    /* REPAY + WITHDRAW COLLATERAL TESTS */

    function _createMarketWithOracle() internal returns (Market memory market, bytes32 marketId) {
        Oracle oracleInstance = new Oracle();
        oracleInstance.setPrice(1e36);

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracleInstance)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(underlying),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        marketId = IdLib.toId(market);
    }

    function _setupBorrowerPosition(Market memory market, uint256 collateralAmount, uint256 borrowAmount)
        internal
        returns (uint256 depositedShares)
    {
        // Deposit collateral
        vm.prank(user);
        (depositedShares,) = executor.depositAndAddCollateral(market, 0, collateralAmount, 0, user);

        // Create debt via sell offer
        (address lender, uint256 lenderSK) = makeAddrAndKey("lender");
        underlying.mint(lender, borrowAmount * 2);
        vm.prank(lender);
        underlying.approve(address(midnight), type(uint256).max);

        Offer memory sellOffer = Offer({
            market: market,
            buy: false,
            maker: user,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("borrow", block.timestamp)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: user,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(sellOffer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), offerRoot));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(userSK, digest);

        bytes32 id = IdLib.toId(market);
        vm.prank(lender);
        midnight.take(
            sellOffer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            borrowAmount,
            lender,
            address(0),
            address(0),
            ""
        );
    }

    /// @dev Direct-repay flow: the executor has no public repay entrypoint; callers invoke `Midnight.repay`
    ///      with the executor as callback, and `onRepay` self-funds from the withdrawn collateral.
    function _directRepay(
        address caller,
        Market memory market,
        uint256 collateralIndex,
        uint256 repayUnits,
        uint256 sharesToWithdraw,
        address onBehalf
    ) internal {
        vm.prank(caller);
        midnight.repay(market, repayUnits, onBehalf, address(executor), abi.encode(collateralIndex, sharesToWithdraw));
    }

    function test_RepayAndWithdrawCollateral_PartialRepay() public {
        (Market memory market, bytes32 marketId) = _createMarketWithOracle();
        _setupBorrowerPosition(market, 1000e18, 500e18);

        uint256 debtBefore = midnight.debt(marketId, user);
        uint256 collateralBefore = midnight.collateral(marketId, user, 0);
        assertGt(debtBefore, 0, "Should have debt");

        uint256 repayAmount = debtBefore / 2;
        uint256 sharesToWithdraw = IERC4626(address(vault)).previewWithdraw(repayAmount);

        _directRepay(user, market, 0, repayAmount, sharesToWithdraw, user);

        assertEq(midnight.debt(marketId, user), debtBefore - repayAmount, "Debt should decrease");
        assertEq(
            midnight.collateral(marketId, user, 0),
            collateralBefore - sharesToWithdraw,
            "Collateral should decrease by specified shares"
        );
        assertGt(midnight.collateral(marketId, user, 0), 0, "Remaining collateral stays on Midnight");
    }

    function test_RepayAndWithdrawCollateral_FullRepay() public {
        (Market memory market, bytes32 marketId) = _createMarketWithOracle();
        _setupBorrowerPosition(market, 1000e18, 500e18);

        uint256 debt = midnight.debt(marketId, user);
        uint256 sharesToWithdraw = IERC4626(address(vault)).previewWithdraw(debt);

        _directRepay(user, market, 0, debt, sharesToWithdraw, user);

        assertEq(midnight.debt(marketId, user), 0, "All debt repaid");
        assertGt(midnight.collateral(marketId, user, 0), 0, "Remaining collateral stays on Midnight");
    }

    function test_RepayAndWithdrawCollateral_RevertsWhenUnauthorized() public {
        (Market memory market,) = _createMarketWithOracle();
        _setupBorrowerPosition(market, 1000e18, 500e18);

        // Midnight's own repay precondition rejects a caller not authorized for `onBehalf`.
        vm.prank(bundler);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        midnight.repay(market, 100e18, user, address(executor), abi.encode(uint256(0), uint256(100e18)));
    }

    /// @dev `onRepay` is reachable by any direct `Midnight.repay` naming the executor as callback, with
    ///      attacker-chosen data. Because the redeemed vault is derived from the market's collateral (not an
    ///      encoded address), a forged repay cannot decouple it to skim the executor's resting shares of an
    ///      unrelated vault: the derived token is the fake market's dummy collateral, and redeeming it reverts.
    function test_OnRepay_DirectMidnightCallback_CannotSkimRestingShares() public {
        // Seed resting real-vault shares on the executor (e.g. donation / mint dust).
        uint256 restingShares = 100e18;
        underlying.mint(address(this), restingShares);
        underlying.approve(address(vault), restingShares);
        vault.deposit(restingShares, address(executor));
        assertEq(vault.balanceOf(address(executor)), restingShares, "executor seeded with resting shares");

        // Attacker builds a fake market whose only collateral is an unrelated dummy ERC20 (not a vault).
        MockERC20 dummy = new MockERC20("Dummy", "DUM", 18);
        Oracle attackerOracle = new Oracle();
        attackerOracle.setPrice(1e36);
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(dummy), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(attackerOracle)
        });
        Market memory fakeMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(underlying),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        address attacker = makeAddr("attacker");
        uint256 sharesToSkim = 40e18;
        dummy.mint(attacker, sharesToSkim);

        vm.startPrank(attacker);
        dummy.approve(address(midnight), sharesToSkim);
        midnight.setIsAuthorized(address(executor), true, attacker);
        midnight.supplyCollateral(fakeMarket, 0, sharesToSkim, attacker);

        // data = (collateralIndex, sharesToWithdraw); the derived vault is the fake market's dummy
        // collateral, whose redeem reverts before the executor's resting real-vault shares are reached.
        bytes memory data = abi.encode(uint256(0), sharesToSkim);
        vm.expectRevert();
        midnight.repay(fakeMarket, 0, attacker, address(executor), data);
        vm.stopPrank();

        assertEq(vault.balanceOf(address(executor)), restingShares, "resting shares untouched");
    }

    /// @dev A resting loan-token balance on the executor must not be skimmable by a forged direct `Midnight.repay`
    ///      naming the executor as callback. With nothing redeemed (units and sharesToWithdraw both zero) the call
    ///      produces no surplus, so the resting balance is left untouched.
    function test_OnRepay_DirectMidnightCallback_CannotSkimRestingLoanTokens() public {
        (Market memory market,) = _createMarketWithOracle();

        uint256 restingBalance = 77e18;
        underlying.mint(address(executor), restingBalance);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        midnight.setIsAuthorized(address(executor), true, attacker);

        // units == sharesToWithdraw == 0: a no-op repay whose only pre-fix effect was sweeping the balance out.
        vm.prank(attacker);
        midnight.repay(market, 0, attacker, address(executor), abi.encode(uint256(0), uint256(0)));

        assertEq(underlying.balanceOf(attacker), 0, "attacker skims nothing");
        assertEq(underlying.balanceOf(address(executor)), restingBalance, "resting balance untouched");
    }

    /// @dev A forged repay that names the REAL vault as the fake market's collateral still cannot redeem the
    ///      executor's leftover shares of that vault: `redeem(sharesToWithdraw)` only runs after
    ///      `withdrawCollateral(sharesToWithdraw)`, which underflow-reverts when the caller's own collateral is
    ///      below the requested amount. An attacker can only redeem shares they actually own.
    function test_OnRepay_CannotSkimLeftoverSharesViaSameVaultFakeMarket() public {
        (Market memory market,) = _createMarketWithOracle(); // collateral == real vault, loan == underlying

        uint256 leftover = 100e18;
        underlying.mint(address(this), leftover);
        underlying.approve(address(vault), leftover);
        vault.deposit(leftover, address(executor));
        assertEq(vault.balanceOf(address(executor)), leftover, "executor seeded with leftover shares");

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        midnight.setIsAuthorized(address(executor), true, attacker);

        // Attacker holds no collateral in the market; withdrawing `leftover` reverts (collateral underflow in
        // Midnight) before any redeem can reach the executor's leftover shares.
        vm.prank(attacker);
        vm.expectRevert();
        midnight.repay(market, 0, attacker, address(executor), abi.encode(uint256(0), leftover));

        assertEq(vault.balanceOf(address(executor)), leftover, "leftover shares untouched");
    }

    /// @dev Approve/pull direction: a repay that redeems no collateral
    ///      (sharesToWithdraw == 0) must not pull a resting loan-token balance through the Midnight approval to
    ///      settle the caller's own debt. The executor funds the repay strictly from in-call redeemed proceeds, so
    ///      an under-redeemed repay reverts instead of draining the resting balance.
    function test_OnRepay_NonZeroUnitsCannotPullRestingLoanTokens() public {
        (Market memory market, bytes32 marketId) = _createMarketWithOracle();
        _setupBorrowerPosition(market, 1000e18, 500e18);

        uint256 restingBalance = 500e18;
        underlying.mint(address(executor), restingBalance);

        uint256 debt = midnight.debt(marketId, user);
        assertGt(debt, 0, "user has debt");

        // sharesToWithdraw == 0 -> redeemed == 0, so funding `debt` could only come from the resting balance.
        vm.prank(user);
        vm.expectRevert(IMidnightVaultExecutor.RepayExceedsRedeemed.selector);
        midnight.repay(market, debt, user, address(executor), abi.encode(uint256(0), uint256(0)));

        assertEq(midnight.debt(marketId, user), debt, "debt unchanged");
        assertEq(underlying.balanceOf(address(executor)), restingBalance, "resting balance untouched");
    }

    /// @dev With the vault derived from the market, the only mismatch left is a collateral whose vault asset
    ///      isn't the loan token; the executor must reject it up front.
    function _marketWithMismatchedVaultCollateral(uint256 salt) internal returns (Market memory market) {
        MockERC20 otherUnderlying = new MockERC20("Other", "OTH", 18);
        IVaultV2 wrongVault = IVaultV2(factory.createVaultV2(vaultOwner, address(otherUnderlying), bytes32(salt)));

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(wrongVault), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(0)
        });
        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(underlying),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function test_DepositAndAddCollateral_RevertsOnVaultMismatch() public {
        Market memory market = _marketWithMismatchedVaultCollateral(1);

        vm.prank(user);
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        executor.depositAndAddCollateral(market, 0, 1000e18, 0, user);
    }

    function test_WithdrawCollateralAndRedeem_RevertsOnVaultMismatch() public {
        Market memory market = _marketWithMismatchedVaultCollateral(2);

        vm.prank(user);
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        executor.withdrawCollateralAndRedeem(market, 0, 100e18, user, user);
    }
}

/// @title Liquidation integration tests for MidnightVaultExecutor
contract MidnightVaultExecutorLiquidationTest is Test {
    MidnightVaultExecutor executor;
    VaultV2AllowlistGate gate;
    Midnight midnight;
    EcrecoverRatifier ecrecoverRatifier;
    IVaultV2 vault;
    MockERC20 underlying;
    Oracle oracle;
    address liquidator;

    address vaultOwner;
    address vaultCurator;
    address borrower;
    uint256 borrowerPrivateKey;
    address lender;

    uint256 constant INITIAL_BALANCE = 1_000_000e18;
    uint256 constant LLTV = 0.77e18;

    function setUp() public {
        // Create actors with signing keys
        vaultOwner = makeAddr("vaultOwner");
        vaultCurator = makeAddr("vaultCurator");
        (borrower, borrowerPrivateKey) = makeAddrAndKey("borrower");
        lender = makeAddr("lender");

        // Deploy tokens
        underlying = new MockERC20("Underlying", "UND", 18);

        // Deploy oracle
        oracle = new Oracle();

        // Deploy Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        // Deploy executor
        executor = new MidnightVaultExecutor(address(midnight));

        // Deploy VaultV2 via factory (deployCode avoids solc version conflict with Midnight)
        IVaultV2Factory factory = IVaultV2Factory(deployCode("out/VaultV2Factory.sol/VaultV2Factory.json"));
        vault = IVaultV2(factory.createVaultV2(vaultOwner, address(underlying), bytes32(0)));

        // Setup vault: owner sets curator
        vm.prank(vaultOwner);
        vault.setCurator(vaultCurator);

        // Deploy gate (owned by this test contract)
        gate = new VaultV2AllowlistGate(address(this));

        // Allowlist midnight and executor
        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](2);
        roles[0] = VaultV2AllowlistGate.Role({
            user: address(midnight),
            canReceiveShares: true,
            canSendShares: true,
            canReceiveAssets: false,
            canSendAssets: false
        });
        roles[1] = VaultV2AllowlistGate.Role({
            user: address(executor),
            canReceiveShares: true,
            canSendShares: false,
            canReceiveAssets: false,
            canSendAssets: false
        });
        gate.setAllowlist(roles);

        // Set gate on vault (timelocked, default timelock=0)
        vm.prank(vaultCurator);
        vault.submit(abi.encodeCall(IVaultV2.setReceiveSharesGate, (address(gate))));
        vault.setReceiveSharesGate(address(gate));

        // Deploy mock liquidator
        liquidator = makeAddr("liquidator");

        // Fund accounts
        underlying.mint(borrower, INITIAL_BALANCE);
        underlying.mint(lender, INITIAL_BALANCE);

        // Borrower: approve executor for underlying, authorize executor on Midnight
        vm.prank(borrower);
        underlying.approve(address(executor), type(uint256).max);
        vm.prank(borrower);
        midnight.setIsAuthorized(address(executor), true, borrower);

        // Lender: approve Midnight for loan tokens
        vm.prank(lender);
        underlying.approve(address(midnight), type(uint256).max);
    }

    /* HELPERS */

    function _createMarket(uint256 maturity) internal view returns (Market memory) {
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        return Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(underlying),
            collateralParams: collaterals,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    /// @dev Deposit underlying into vault and supply as collateral on Midnight via executor
    function _depositCollateral(Market memory market, uint256 amount) internal {
        vm.prank(borrower);
        executor.depositAndAddCollateral(market, 0, amount, 0, borrower);
    }

    /// @dev Create debt by having lender take borrower's offer at MAX_TICK (price = 1)
    function _createDebt(Market memory market, uint256 debtAmount) internal {
        Offer memory borrowerOffer = Offer({
            market: market,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: borrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: uint128(debtAmount),
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        // Sign the offer with borrower's private key
        bytes32 offerRoot = HashLib.hashOffer(borrowerOffer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), offerRoot));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(borrowerPrivateKey, digest);

        vm.prank(lender);
        midnight.take(
            borrowerOffer,
            abi.encode(Signature({v: v, r: r, s: s}), offerRoot, uint256(0), new bytes32[](0)),
            debtAmount,
            lender,
            address(0),
            address(0),
            ""
        );
    }

    /// @dev Setup a liquidatable position: deposit collateral, create debt, warp past maturity
    function _setupLiquidatablePosition(uint256 collateralAmount, uint256 debtAmount)
        internal
        returns (Market memory market)
    {
        market = _createMarket(block.timestamp + 30 days);
        _depositCollateral(market, collateralAmount);
        _createDebt(market, debtAmount);

        // Warp past maturity + TIME_TO_MAX_LIF so position is fully liquidatable
        vm.warp(market.maturity + TIME_TO_MAX_LIF + 1);
    }

    /* LIQUIDATION TESTS */

    /// @dev Direct-liquidate flow: the executor has no public liquidate entrypoint; liquidators invoke
    ///      `Midnight.liquidate` with the executor as both `receiver` and `callback`, and `onLiquidate`
    ///      self-funds from the seized collateral and returns the bonus to the caller.
    function _directLiquidate(
        address caller,
        Market memory market,
        uint256 collateralIndex,
        uint256 seizedShares,
        uint256 repaidUnits,
        address borrower_,
        bool postMaturityMode
    ) internal returns (uint256 seized, uint256 repaid) {
        vm.prank(caller);
        (seized, repaid) = midnight.liquidate(
            market,
            collateralIndex,
            seizedShares,
            repaidUnits,
            borrower_,
            postMaturityMode,
            address(executor),
            address(executor),
            ""
        );
    }

    function test_LiquidateAndRedeem_BasicFlow() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        Market memory market = _setupLiquidatablePosition(collateralAmount, debtAmount);

        (uint256 actualSeized, uint256 actualRepaid) =
            _directLiquidate(liquidator, market, 0, 0, debtAmount, borrower, true);

        assertGt(actualSeized, 0, "Should have seized shares");
        assertEq(actualRepaid, debtAmount, "Should have repaid full debt");

        bytes32 marketId = IdLib.toId(market);
        assertEq(midnight.debt(marketId, borrower), 0, "Borrower debt should be zero");
    }

    function test_LiquidateAndRedeem_GateAllowsFlow() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        Market memory market = _setupLiquidatablePosition(collateralAmount, debtAmount);

        (uint256 actualSeized,) = _directLiquidate(liquidator, market, 0, 0, debtAmount, borrower, true);

        assertGt(actualSeized, 0, "Liquidation should succeed through gate");
        assertEq(vault.balanceOf(address(executor)), 0, "Executor should not hold shares");
        assertEq(vault.balanceOf(liquidator), 0, "Liquidator should not hold shares");
    }

    function test_LiquidateAndRedeem_OnlyMidnightCanCallOnLiquidate() public {
        Market memory market = _createMarket(block.timestamp + 30 days);

        vm.prank(address(0xdead));
        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        executor.onLiquidate(address(0), bytes32(0), market, 0, 100e18, 50e18, borrower, address(0), "", 0);
    }

    /// @dev A direct liquidation whose seized-collateral `receiver` is not the executor must revert: Midnight
    ///      sends the seized shares to `receiver`, so redeeming `seizedShares` would otherwise burn the
    ///      executor's own resting shares to fund the caller's liquidation. `receiver = midnight` is used to
    ///      show the guard fires even for an allowlisted (non-executor) receiver, not just a gated one.
    function test_LiquidateAndRedeem_RevertsWhenReceiverNotExecutor() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        Market memory market = _setupLiquidatablePosition(collateralAmount, debtAmount);

        // Seed resting shares on the executor — the assets the decoupling would drain.
        uint256 restingShares = 100e18;
        underlying.mint(address(this), restingShares);
        underlying.approve(address(vault), restingShares);
        vault.deposit(restingShares, address(executor));
        assertEq(vault.balanceOf(address(executor)), restingShares, "executor seeded with resting shares");

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(IMidnightVaultExecutor.LiquidationReceiverMismatch.selector);
        midnight.liquidate(market, 0, 0, debtAmount, borrower, true, address(midnight), address(executor), "");

        assertEq(vault.balanceOf(address(executor)), restingShares, "resting shares untouched");
    }

    function test_LiquidateAndRedeem_Permissionless() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        Market memory market = _setupLiquidatablePosition(collateralAmount, debtAmount);

        address stranger = makeAddr("stranger");

        (uint256 actualSeized, uint256 actualRepaid) =
            _directLiquidate(stranger, market, 0, 0, debtAmount, borrower, true);

        assertGt(actualSeized, 0, "Stranger should be able to liquidate");
        assertEq(actualRepaid, debtAmount, "Full debt repaid");
    }

    function test_LiquidateAndRedeem_BySeizedShares() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        Market memory market = _setupLiquidatablePosition(collateralAmount, debtAmount);

        uint256 sharesToSeize = 200e18;
        (uint256 actualSeized, uint256 actualRepaid) =
            _directLiquidate(liquidator, market, 0, sharesToSeize, 0, borrower, true);

        assertEq(actualSeized, sharesToSeize, "Should seize exact shares requested");
        assertGt(actualRepaid, 0, "Some debt should be repaid");
        assertLt(actualRepaid, debtAmount, "Should be partial liquidation");

        // Borrower still has remaining debt
        bytes32 marketId = IdLib.toId(market);
        assertGt(midnight.debt(marketId, borrower), 0, "Borrower should still have debt");
    }

    /// @dev No-callback path self-funds from the seized collateral: an EOA liquidator with zero loan
    ///      tokens and no pre-funding can liquidate by `repaidUnits`. The executor redeems into itself,
    ///      Midnight pulls the debt from it, and the seizure bonus is swept to the liquidator.
    function test_LiquidateAndRedeem_NoCallback_SelfFundingByUnits() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        Market memory market = _setupLiquidatablePosition(collateralAmount, debtAmount);

        address eoaLiquidator = makeAddr("selfFundingLiquidator");
        assertEq(underlying.balanceOf(eoaLiquidator), 0, "liquidator starts with no loan tokens");

        (uint256 actualSeized, uint256 actualRepaid) =
            _directLiquidate(eoaLiquidator, market, 0, 0, debtAmount, borrower, true);

        assertGt(actualSeized, 0, "should seize collateral");
        assertEq(actualRepaid, debtAmount, "full debt repaid");
        // 1:1 share price (no yield) → redeemed == actualSeized.
        assertEq(underlying.balanceOf(eoaLiquidator), actualSeized - actualRepaid, "liquidator nets seizure bonus");
        assertGt(underlying.balanceOf(eoaLiquidator), 0, "bonus is strictly positive (LIF > 1)");
        assertEq(underlying.balanceOf(address(executor)), 0, "executor holds no residual loan tokens");
        assertEq(vault.balanceOf(address(executor)), 0, "executor holds no residual shares");

        bytes32 marketId = IdLib.toId(market);
        assertEq(midnight.debt(marketId, borrower), 0, "borrower debt cleared");
    }

    /// @dev `seizedShares` mode (repaidUnits == 0) is the case the old pre-funding workaround could not
    ///      serve: the repaid amount is computed inside Midnight, so the caller cannot know how much to
    ///      pre-fund. Self-funding handles it — the redeemed shares cover the internally-computed repay.
    function test_LiquidateAndRedeem_NoCallback_SelfFundingBySeizedShares() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        Market memory market = _setupLiquidatablePosition(collateralAmount, debtAmount);

        address eoaLiquidator = makeAddr("selfFundingLiquidator2");
        uint256 sharesToSeize = 200e18;

        (uint256 actualSeized, uint256 actualRepaid) =
            _directLiquidate(eoaLiquidator, market, 0, sharesToSeize, 0, borrower, true);

        assertEq(actualSeized, sharesToSeize, "seizes exact shares requested");
        assertGt(actualRepaid, 0, "some debt repaid");
        assertLt(actualRepaid, debtAmount, "partial liquidation");
        // 1:1 share price (no yield) → redeemed == sharesToSeize.
        assertEq(underlying.balanceOf(eoaLiquidator), sharesToSeize - actualRepaid, "liquidator nets seizure bonus");
        assertEq(underlying.balanceOf(address(executor)), 0, "executor holds no residual loan tokens");

        bytes32 marketId = IdLib.toId(market);
        assertGt(midnight.debt(marketId, borrower), 0, "borrower retains residual debt");
    }

    /// @dev A resting loan-token balance on the executor (donation, dust, or a prior call's leftovers) must not be
    ///      skimmed by a liquidator. The surplus swept to the caller is measured
    ///      against the assets redeemed in this call, not the executor's balance, so only the seizure bonus is
    ///      forwarded and the resting balance is left untouched.
    function test_LiquidateAndRedeem_DoesNotSkimRestingLoanTokens() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        Market memory market = _setupLiquidatablePosition(collateralAmount, debtAmount);

        uint256 restingBalance = 123e18;
        underlying.mint(address(executor), restingBalance);

        address eoaLiquidator = makeAddr("eoaLiquidator");
        assertEq(underlying.balanceOf(eoaLiquidator), 0, "liquidator starts with no loan tokens");

        (uint256 actualSeized, uint256 actualRepaid) =
            _directLiquidate(eoaLiquidator, market, 0, 0, debtAmount, borrower, true);

        assertEq(actualRepaid, debtAmount, "full debt repaid");
        // 1:1 share price → redeemed == actualSeized; liquidator nets only the seizure bonus.
        assertEq(underlying.balanceOf(eoaLiquidator), actualSeized - actualRepaid, "liquidator nets only the bonus");
        assertEq(underlying.balanceOf(address(executor)), restingBalance, "resting balance untouched");
    }

    /// @dev Exercises the post-#911 "RCF active post-maturity" combo: unhealthy borrower past maturity,
    ///      liquidated via postMaturityMode=false. Pre-#911 the RCF was disabled post-maturity so this same
    ///      call would have succeeded; post-#911 the RCF reverts when the requested amount would
    ///      over-liquidate beyond what restores health.
    function test_LiquidateAndRedeem_PostMaturityUnhealthy_HealthyPathFalse_RcfReverts() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        Market memory market = _setupLiquidatablePosition(collateralAmount, debtAmount);

        // Halve the collateral price so the borrower is unhealthy at the warped (post-maturity) timestamp:
        //   maxDebt = collateral * price/SCALE * lltv/WAD = 1000e18 * 0.5 * 0.77 = 385e18 < debt 500e18.
        oracle.setPrice(0.5e36);

        vm.prank(liquidator);
        vm.expectRevert(IMidnight.RecoveryCloseFactorConditionsViolated.selector);
        midnight.liquidate(market, 0, 0, debtAmount, borrower, false, address(executor), address(executor), "");
    }

    function _liquidatableMarketWithGate(address liquidatorGate) internal returns (Market memory market) {
        market = _createMarket(block.timestamp + 30 days);
        market.liquidatorGate = liquidatorGate;
        _depositCollateral(market, 1000e18);
        _createDebt(market, 500e18);
        vm.warp(market.maturity + TIME_TO_MAX_LIF + 1);
    }

    function test_LiquidateAndRedeem_RevertsWhenLiquidatorGateRejectsCaller() public {
        // The gate is enforced by Midnight against the direct caller; the stranger is not allowlisted.
        MidnightAllowlistGate allowlist = new MidnightAllowlistGate(address(this));
        Market memory market = _liquidatableMarketWithGate(address(allowlist));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(IMidnight.LiquidatorGatedFromLiquidating.selector);
        midnight.liquidate(market, 0, 0, 500e18, borrower, true, address(executor), address(executor), "");
    }

    function test_LiquidateAndRedeem_AllowsAllowlistedCaller() public {
        // Midnight gates the direct caller, so the liquidator (not the executor) is what must be allowlisted.
        address allowed = makeAddr("allowedLiquidator");
        MidnightAllowlistGate allowlist = new MidnightAllowlistGate(address(this));
        MidnightAllowlistGate.Role[] memory roles = new MidnightAllowlistGate.Role[](1);
        roles[0] = MidnightAllowlistGate.Role({
            user: allowed, canIncreaseCredit: false, canIncreaseDebt: false, canLiquidate: true
        });
        allowlist.setAllowlist(roles);

        Market memory market = _liquidatableMarketWithGate(address(allowlist));

        (uint256 seized, uint256 repaid) = _directLiquidate(allowed, market, 0, 0, 500e18, borrower, true);

        assertGt(seized, 0, "Allowlisted liquidator should seize collateral");
        assertEq(repaid, 500e18, "Allowlisted liquidator should repay full debt");
        assertGt(underlying.balanceOf(allowed), 0, "Allowlisted liquidator should receive redeemed assets");
    }
}

/// @title Full gate lockdown tests — all gates set on vault
/// @notice Verifies the executor works when receiveShares, sendShares, and sendAssets
///         gates are all configured. This mirrors production deployment where the vault
///         is fully restricted to Midnight collateral usage.
contract MidnightVaultExecutorFullGateTest is Test {
    MidnightVaultExecutor executor;
    VaultV2AllowlistGate gate;
    Midnight midnight;
    EcrecoverRatifier ecrecoverRatifier;
    IVaultV2 vault;
    MockERC20 underlying;
    Oracle oracle;
    address liquidator;

    address vaultOwner;
    address vaultCurator;
    address borrower;
    uint256 borrowerPrivateKey;
    address lender;
    address stranger;

    uint256 constant INITIAL_BALANCE = 1_000_000e18;
    uint256 constant LLTV = 0.77e18;

    function setUp() public {
        vaultOwner = makeAddr("vaultOwner");
        vaultCurator = makeAddr("vaultCurator");
        (borrower, borrowerPrivateKey) = makeAddrAndKey("borrower");
        lender = makeAddr("lender");
        stranger = makeAddr("stranger");

        underlying = new MockERC20("Underlying", "UND", 18);
        oracle = new Oracle();
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        executor = new MidnightVaultExecutor(address(midnight));

        IVaultV2Factory factory = IVaultV2Factory(deployCode("out/VaultV2Factory.sol/VaultV2Factory.json"));
        vault = IVaultV2(factory.createVaultV2(vaultOwner, address(underlying), bytes32(0)));

        vm.prank(vaultOwner);
        vault.setCurator(vaultCurator);

        // --- Deploy gate with production-like permissions ---
        gate = new VaultV2AllowlistGate(address(this));

        VaultV2AllowlistGate.Role[] memory roles = new VaultV2AllowlistGate.Role[](2);
        // Executor: full permissions (deposit, withdraw, redeem)
        roles[0] = VaultV2AllowlistGate.Role({
            user: address(executor),
            canReceiveShares: true,
            canSendShares: true,
            canReceiveAssets: false,
            canSendAssets: true
        });
        // Midnight: receives shares (supplyCollateral) and sends shares (withdrawCollateral/liquidate)
        roles[1] = VaultV2AllowlistGate.Role({
            user: address(midnight),
            canReceiveShares: true,
            canSendShares: true,
            canReceiveAssets: false,
            canSendAssets: false
        });
        gate.setAllowlist(roles);

        // --- Set THREE gates on the vault (receiveShares, sendShares, sendAssets) ---
        // receiveAssetsGate is intentionally NOT set — withdraw/liquidation receivers vary.
        vm.startPrank(vaultCurator);
        vault.submit(abi.encodeCall(IVaultV2.setReceiveSharesGate, (address(gate))));
        vault.setReceiveSharesGate(address(gate));

        vault.submit(abi.encodeCall(IVaultV2.setSendSharesGate, (address(gate))));
        vault.setSendSharesGate(address(gate));

        vault.submit(abi.encodeCall(IVaultV2.setSendAssetsGate, (address(gate))));
        vault.setSendAssetsGate(address(gate));
        vm.stopPrank();

        // --- Fund and authorize ---
        liquidator = makeAddr("liquidator");
        underlying.mint(borrower, INITIAL_BALANCE);
        underlying.mint(lender, INITIAL_BALANCE);

        vm.prank(borrower);
        underlying.approve(address(executor), type(uint256).max);
        vm.prank(borrower);
        midnight.setIsAuthorized(address(executor), true, borrower);

        vm.prank(lender);
        underlying.approve(address(midnight), type(uint256).max);
    }

    function _createMarket(uint256 maturity) internal view returns (Market memory) {
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        return Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(underlying),
            collateralParams: collaterals,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _setupLiquidatablePosition(uint256 collateralAmount, uint256 debtAmount)
        internal
        returns (Market memory market)
    {
        market = _createMarket(block.timestamp + 30 days);

        vm.prank(borrower);
        executor.depositAndAddCollateral(market, 0, collateralAmount, 0, borrower);

        Offer memory borrowerOffer = Offer({
            market: market,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: borrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: uint128(debtAmount),
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(borrowerOffer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), offerRoot));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(borrowerPrivateKey, digest);

        vm.prank(lender);
        midnight.take(
            borrowerOffer,
            abi.encode(Signature({v: v, r: r, s: s}), offerRoot, uint256(0), new bytes32[](0)),
            debtAmount,
            lender,
            address(0),
            address(0),
            ""
        );

        vm.warp(market.maturity + TIME_TO_MAX_LIF + 1);
    }

    /* FULL GATE: DEPOSIT + WITHDRAW */

    function test_FullGate_DepositAndWithdrawViaExecutor() public {
        Market memory market = _createMarket(block.timestamp + 30 days);

        uint256 depositAmount = 1000e18;
        vm.prank(borrower);
        (uint256 shares,) = executor.depositAndAddCollateral(market, 0, depositAmount, 0, borrower);
        assertEq(shares, depositAmount, "Shares should be minted");

        vm.prank(borrower);
        uint256 assets = executor.withdrawCollateralAndRedeem(market, 0, shares, borrower, borrower);
        assertEq(assets, depositAmount, "Should redeem full amount");
    }

    /* FULL GATE: LIQUIDATION */

    function test_FullGate_LiquidationViaExecutor() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        Market memory market = _setupLiquidatablePosition(collateralAmount, debtAmount);

        vm.prank(liquidator);
        (uint256 actualSeized, uint256 actualRepaid) =
            midnight.liquidate(market, 0, 0, debtAmount, borrower, true, address(executor), address(executor), "");

        assertGt(actualSeized, 0, "Should seize shares");
        assertEq(actualRepaid, debtAmount, "Should repay full debt");

        bytes32 marketId = IdLib.toId(market);
        assertEq(midnight.debt(marketId, borrower), 0, "Debt should be cleared");
    }

    /* FULL GATE: DIRECT ACCESS BLOCKED (sendAssetsGate-specific) */

    function test_FullGate_DirectDepositBlockedBySendAssetsGate() public {
        // Stranger tries to deposit on behalf of executor (canReceiveShares ok for executor,
        // but stranger has no canSendAssets). This gate dimension is NOT tested in
        // VaultV2AllowlistGateIntegration which uses all 4 gates on the same address.
        underlying.mint(stranger, 1000e18);
        vm.prank(stranger);
        underlying.approve(address(vault), 1000e18);

        vm.prank(stranger);
        vm.expectRevert(ErrorsLib.CannotSendAssets.selector);
        vault.deposit(1000e18, address(executor));
    }
}
