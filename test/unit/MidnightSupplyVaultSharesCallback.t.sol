// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MidnightSupplyVaultSharesCallback} from "../../src/callbacks/MidnightSupplyVaultSharesCallback.sol";
import {IMidnightSupplyVaultSharesCallback} from "@callbacks/interfaces/IMidnightSupplyVaultSharesCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {MockERC4626} from "../helpers/mocks/MockERC4626.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

contract MidnightSupplyVaultSharesCallbackTest is Test {
    MidnightSupplyVaultSharesCallback internal callback;
    Midnight internal midnight;
    MockERC20 internal loanToken;
    MockERC4626 internal vault;
    Oracle internal oracle;

    address internal seller;
    uint256 internal sellerSK;
    address internal lender;
    EcrecoverRatifier internal ecrecoverRatifier;

    Market internal testMarket;

    function setUp() public virtual {
        (seller, sellerSK) = makeAddrAndKey("Seller");
        lender = makeAddr("Lender");

        // Deploy tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);

        // Deploy vault backed by loan token
        vault = new MockERC4626(address(loanToken), "Vault Shares", "vLOAN");

        // Deploy oracle (1:1 price)
        oracle = new Oracle();
        oracle.setPrice(1e36);

        // Deploy Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(seller);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seller);

        // Deploy callback
        callback = new MidnightSupplyVaultSharesCallback(address(midnight));

        // Set up test market with vault as collateral (80% LLTV)
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vault), lltv: 0.77e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        testMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Fund seller with loan tokens (for totalDeposit which exceeds sellerAssets)
        loanToken.mint(seller, 10000e18);

        // Seller approves callback for loan tokens and authorizes on Midnight
        vm.startPrank(seller);
        loanToken.approve(address(callback), type(uint256).max);
        midnight.setIsAuthorized(address(callback), true, seller);
        vm.stopPrank();

        // Fund lender and approve Midnight
        loanToken.mint(lender, 100000e18);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ========== HELPERS ========== */

    function _signOffer(Offer memory offer, uint256 privateKey) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(privateKey, digest);
        return signature;
    }

    uint256 internal constant DEFAULT_ADDITIONAL_DEPOSIT_PERCENT = 0.3e18; // 30%

    uint256 internal constant DEFAULT_TICK = MAX_TICK;

    function _encodeCallbackData(address _vault) internal pure returns (bytes memory) {
        return abi.encode(
            IMidnightSupplyVaultSharesCallback.CallbackData({
                vault: _vault, collateralIndex: 0, additionalDepositPercent: DEFAULT_ADDITIONAL_DEPOSIT_PERCENT
            })
        );
    }

    function _takeOffer(uint256 sellerAssets, bytes memory callbackData, address taker) internal {
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, gasleft()));

        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = sellerAssets;
        vm.prank(taker);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, taker, address(0), address(0), ""
        );
    }

    using UtilsLib for uint256;

    /// @dev Computes sellerAssets from units for a sell offer (buy=false).
    ///      Matches Midnight: sellerAssets = units.mulDivUp(sellerPrice, WAD) where sellerPrice = tickToPrice(tick).
    function _calculateSellerAssets(uint256 units, uint256 tick) internal pure returns (uint256) {
        return units.mulDivUp(TickLib.tickToPrice(tick), WAD);
    }

    /// @dev Calculates the amount the seller must pay on top of sellerAssets.
    ///      Matches the contract logic: amountFromSeller = ceil(sellerAssets * additionalDepositPercent / WAD).
    function _calculateAmountFromSeller(uint256 units, uint256 additionalDepositPercent, uint256 tick)
        internal
        pure
        returns (uint256)
    {
        return _calculateSellerAssets(units, tick).mulDivUp(additionalDepositPercent, WAD);
    }

    /// @dev Calculates expected totalDeposit = sellerAssets + amountFromSeller.
    function _calculateTotalDeposit(uint256 units, uint256 additionalDepositPercent, uint256 tick)
        internal
        pure
        returns (uint256)
    {
        uint256 sellerAssets = _calculateSellerAssets(units, tick);
        return sellerAssets + _calculateAmountFromSeller(units, additionalDepositPercent, tick);
    }

    /* ========== CONSTRUCTOR ========== */

    function test_constructor_setsMidnight() public view {
        assertEq(address(callback.MORPHO_MIDNIGHT()), address(midnight));
    }

    /* ========== AUTHORIZATION ========== */

    function test_onSell_revertsWhenCallerIsNotMidnight() public {
        bytes memory data = _encodeCallbackData(address(vault));

        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onSell(bytes32(0), testMarket, 50e18, 100e18, 0, seller, address(callback), data);
    }

    function test_onSell_revertsWhenCallerIsRandomAddress() public {
        address randomCaller = makeAddr("RandomCaller");
        bytes memory data = _encodeCallbackData(address(vault));

        vm.prank(randomCaller);
        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onSell(bytes32(0), testMarket, 50e18, 100e18, 0, seller, address(callback), data);
    }

    /* ========== INPUT VALIDATION ========== */

    function test_onSell_revertsWhenReceiverIsNotCallback() public {
        bytes memory data = _encodeCallbackData(address(vault));

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.InvalidReceiver.selector);
        callback.onSell(bytes32(0), testMarket, 50e18, 100e18, 0, seller, seller, data);
    }

    function test_onSell_revertsWhenSellerAssetsIsZero() public {
        bytes memory data = _encodeCallbackData(address(vault));

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        callback.onSell(bytes32(0), testMarket, 0, 100e18, 0, seller, address(callback), data);
    }

    function test_onSell_revertsWhenVaultAssetMismatch() public {
        // Deploy a vault with different underlying asset
        MockERC20 wrongAsset = new MockERC20("Wrong Asset", "WRONG", 18);
        MockERC4626 wrongVault = new MockERC4626(address(wrongAsset), "Wrong Vault", "vWRONG");

        bytes memory data = _encodeCallbackData(address(wrongVault));

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        callback.onSell(bytes32(0), testMarket, 50e18, 100e18, 0, seller, address(callback), data);
    }

    function test_onSell_revertsWhenVaultNotInCollaterals() public {
        // Deploy a different vault (same asset but not in collaterals)
        MockERC4626 differentVault = new MockERC4626(address(loanToken), "Different Vault", "vDIFF");

        bytes memory data = _encodeCallbackData(address(differentVault));

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        callback.onSell(bytes32(0), testMarket, 50e18, 100e18, 0, seller, address(callback), data);
    }

    function test_onSell_zeroVaultShares_suppliesNothing() public {
        // Set exchange rate extremely high so deposit returns 0 shares
        vault.setExchangeRate(type(uint128).max);

        bytes memory data = _encodeCallbackData(address(vault));

        // Direct onSell call: pre-fund callback with sellerAssets since midnight isn't transferring
        uint256 sellerAssets = 1;
        loanToken.mint(address(callback), sellerAssets);

        // supplyCollateral(0) is a no-op in Midnight (no revert, no state change)
        vm.prank(address(midnight));
        callback.onSell(bytes32(0), testMarket, sellerAssets, 1, 0, seller, address(callback), data);

        bytes32 oblId = IdLib.toId(testMarket);
        assertEq(midnight.collateral(oblId, seller, 0), 0, "no collateral supplied");
    }

    /* ========== CORE CALCULATION ========== */

    function test_onSell_calculatesTotalDepositCorrectly_30Pct() public {
        // With 30% additionalDepositPercent and 100e18 sellerAssets:
        // amountFromSeller = ceil(100e18 * 0.3e18 / WAD) = 30e18
        // totalDeposit = 100e18 + 30e18 = 130e18
        bytes memory callbackData = _encodeCallbackData(address(vault));

        uint256 sellerBalanceBefore = loanToken.balanceOf(seller);
        _takeOffer(100e18, callbackData, lender);
        uint256 sellerBalanceAfter = loanToken.balanceOf(seller);

        // Midnight sends sellerAssets to callback (receiverIfMakerIsSeller=callback).
        // Callback pulls amountFromSeller from seller. Seller net change = amountFromSeller.
        uint256 expectedAmountFromSeller =
            _calculateAmountFromSeller(100e18, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK);
        assertEq(sellerBalanceBefore - sellerBalanceAfter, expectedAmountFromSeller, "Seller net change incorrect");
    }

    function test_onSell_calculatesTotalDepositCorrectly_10Pct() public {
        // With 10% additionalDepositPercent and 100e18 sellerAssets:
        // amountFromSeller = ceil(100e18 * 0.1e18 / WAD) = 10e18
        // totalDeposit = 100e18 + 10e18 = 110e18
        // Increase oracle so 10% additional is enough for LLTV=0.77 health check
        oracle.setPrice(1.5e36);

        uint256 additionalDepositPercent = 0.1e18;

        bytes memory callbackData = abi.encode(
            IMidnightSupplyVaultSharesCallback.CallbackData({
                vault: address(vault), collateralIndex: 0, additionalDepositPercent: additionalDepositPercent
            })
        );

        uint256 sellerBalanceBefore = loanToken.balanceOf(seller);
        _takeOffer(100e18, callbackData, lender);
        uint256 sellerBalanceAfter = loanToken.balanceOf(seller);

        // Net change = amountFromSeller (callback pulls this from seller)
        uint256 expectedAmountFromSeller = _calculateAmountFromSeller(100e18, additionalDepositPercent, DEFAULT_TICK);
        assertEq(
            sellerBalanceBefore - sellerBalanceAfter,
            expectedAmountFromSeller,
            "Seller net change incorrect for 10% additionalDepositPercent"
        );
    }

    /// @dev The extra deposit scales off the sellerAssets Midnight actually moved, not units * tickToPrice(tick).
    ///      Feeding a sellerAssets that diverges from units * price (as the taker/settlement-fee path does) must
    ///      yield amountFromSeller = ceil(sellerAssets * pct / WAD), independent of units.
    function test_onSell_scalesAdditionalOffSellerAssets() public {
        uint256 sellerAssets = 40e18; // deliberately != units * tickToPrice(tick)
        uint256 units = 100e18;
        bytes memory data = _encodeCallbackData(address(vault));

        // Direct onSell: Midnight isn't transferring sellerAssets here, so pre-fund the callback.
        loanToken.mint(address(callback), sellerAssets);

        uint256 sellerBalanceBefore = loanToken.balanceOf(seller);
        vm.prank(address(midnight));
        callback.onSell(bytes32(0), testMarket, sellerAssets, units, 0, seller, address(callback), data);
        uint256 sellerBalanceAfter = loanToken.balanceOf(seller);

        uint256 expected = sellerAssets.mulDivUp(DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, WAD); // 12e18, not 30e18
        assertEq(sellerBalanceBefore - sellerBalanceAfter, expected, "extra deposit must scale off sellerAssets");
    }

    /* ========== TOKEN FLOW ========== */

    function test_onSell_pullsLoanTokensFromSeller() public {
        bytes memory callbackData = _encodeCallbackData(address(vault));

        uint256 sellerBalanceBefore = loanToken.balanceOf(seller);
        _takeOffer(100e18, callbackData, lender);
        uint256 sellerBalanceAfter = loanToken.balanceOf(seller);

        // Midnight sends sellerAssets to callback (receiver=callback), not to seller.
        // Callback pulls amountFromSeller from seller.
        uint256 expectedAmountFromSeller =
            _calculateAmountFromSeller(100e18, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK);
        assertEq(sellerBalanceBefore - sellerBalanceAfter, expectedAmountFromSeller);
    }

    function test_onSell_depositsIntoVault() public {
        bytes memory callbackData = _encodeCallbackData(address(vault));
        uint256 expectedTotalDeposit = _calculateTotalDeposit(100e18, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK);

        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        _takeOffer(100e18, callbackData, lender);
        uint256 vaultBalanceAfter = loanToken.balanceOf(address(vault));

        assertEq(vaultBalanceAfter - vaultBalanceBefore, expectedTotalDeposit);
    }

    function test_onSell_suppliesSharesAsCollateral() public {
        bytes memory callbackData = _encodeCallbackData(address(vault));
        uint256 expectedTotalDeposit = _calculateTotalDeposit(100e18, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK);

        // At 1:1 exchange rate, shares = totalDeposit
        uint256 expectedShares = vault.convertToShares(expectedTotalDeposit);

        _takeOffer(100e18, callbackData, lender);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 sellerCollateral = midnight.collateral(marketId, seller, 0);

        assertEq(sellerCollateral, expectedShares, "Collateral not supplied to seller");
    }

    function test_onSell_callbackRetainsNoTokens() public {
        bytes memory callbackData = _encodeCallbackData(address(vault));

        _takeOffer(100e18, callbackData, lender);

        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback retained loan tokens");
        assertEq(vault.balanceOf(address(callback)), 0, "Callback retained vault shares");
    }

    /* ========== EVENT ========== */

    function test_onSell_emitsVaultSharesSuppliedEvent() public {
        bytes memory callbackData = _encodeCallbackData(address(vault));
        uint256 sellerAssets = 100e18;
        uint256 totalDeposit = _calculateTotalDeposit(100e18, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK);
        uint256 expectedShares = vault.convertToShares(totalDeposit);
        bytes32 marketId = IdLib.toId(testMarket);

        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, gasleft()));
        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        vm.expectEmit(true, true, true, true);
        emit IMidnightSupplyVaultSharesCallback.VaultSharesSupplied(
            seller, marketId, address(vault), sellerAssets, totalDeposit, expectedShares
        );

        bytes32 _takeId = IdLib.toId(offer.market);
        uint256 _takeShares = sellerAssets;
        vm.prank(lender);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _takeShares,
            lender,
            address(0),
            address(0),
            ""
        );
    }

    /* ========== EDGE CASES ========== */

    function test_onSell_handlesZeroAdditionalPct() public {
        // With additionalDepositPercent = 0, no extra deposit needed from seller.
        // Increase oracle so 1:1 collateral passes health check with LLTV=0.77.
        oracle.setPrice(2e36);

        bytes memory callbackData = abi.encode(
            IMidnightSupplyVaultSharesCallback.CallbackData({
                vault: address(vault), collateralIndex: 0, additionalDepositPercent: 0
            })
        );

        uint256 sellerBalanceBefore = loanToken.balanceOf(seller);
        _takeOffer(100e18, callbackData, lender);
        uint256 sellerBalanceAfter = loanToken.balanceOf(seller);

        // Net change should be 0: callback only deposits sellerAssets (no pull from seller)
        assertEq(sellerBalanceBefore, sellerBalanceAfter, "Net change should be zero with 0% additional");
    }

    function test_onSell_findsVaultInMultipleCollaterals() public {
        // Create market with multiple collaterals, vault in middle
        MockERC20 collateral1 = new MockERC20("Col1", "C1", 18);
        MockERC20 collateral2 = new MockERC20("Col2", "C2", 18);

        // Ensure proper address ordering for collaterals array
        address[3] memory addrs = [address(collateral1), address(vault), address(collateral2)];
        // Simple bubble sort
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (addrs[i] > addrs[j]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                }
            }
        }

        // Find vault index in sorted collaterals array
        uint256 vaultIndex;
        for (uint256 i = 0; i < 3; i++) {
            if (addrs[i] == address(vault)) {
                vaultIndex = i;
                break;
            }
        }

        CollateralParams[] memory collaterals = new CollateralParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            collaterals[i] = CollateralParams({
                token: addrs[i], lltv: 0.77e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
            });
        }

        testMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Use the correct vault index in callback data
        bytes memory callbackData = abi.encode(
            IMidnightSupplyVaultSharesCallback.CallbackData({
                vault: address(vault),
                collateralIndex: vaultIndex,
                additionalDepositPercent: DEFAULT_ADDITIONAL_DEPOSIT_PERCENT
            })
        );

        _takeOffer(100e18, callbackData, lender);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 collateral = midnight.collateral(marketId, seller, vaultIndex);
        assertGt(collateral, 0, "Should have supplied vault shares");
    }

    function test_onSell_sharesCalculatedWithExchangeRate() public {
        // Set exchange rate: 1 share = 1.1 assets (10% yield accrued)
        // This means fewer shares are minted for the same deposit
        vault.setExchangeRate(1.1e18);

        // Increase oracle price to properly value vault shares
        // At 1.1 exchange rate, 1 share = 1.1 assets, so price should be 1.1e36
        // Adding slight buffer (1.15e36) to ensure health check passes with rounding
        oracle.setPrice(1.15e36);

        bytes memory callbackData = _encodeCallbackData(address(vault));
        uint256 totalDeposit = _calculateTotalDeposit(100e18, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK); // 125e18

        // Expected shares = totalDeposit * 1e18 / exchangeRate = 125e18 / 1.1 ≈ 113.6e18
        uint256 expectedShares = vault.convertToShares(totalDeposit);

        _takeOffer(100e18, callbackData, lender);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 sellerCollateral = midnight.collateral(marketId, seller, 0);

        assertEq(sellerCollateral, expectedShares, "Shares mismatch with exchange rate");
    }

    /* ========== INTEGRATION ========== */

    function test_integration_fullBorrowFlow() public {
        bytes memory callbackData = _encodeCallbackData(address(vault));
        bytes32 marketId = IdLib.toId(testMarket);

        // Initial state
        assertEq(midnight.debt(marketId, seller), 0);
        assertEq(midnight.collateral(marketId, seller, 0), 0);

        // Execute borrow
        _takeOffer(100e18, callbackData, lender);

        // Verify debt created
        assertEq(midnight.debt(marketId, seller), 100e18, "Debt should be created");

        // Verify collateral supplied
        uint256 totalDeposit = _calculateTotalDeposit(100e18, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK);
        uint256 expectedShares = vault.convertToShares(totalDeposit);
        assertEq(midnight.collateral(marketId, seller, 0), expectedShares);

        // Verify position is healthy
        assertTrue(midnight.isHealthy(testMarket, marketId, seller), "Position should be healthy");
    }

    function test_integration_multiplePartialFills() public {
        bytes memory callbackData = _encodeCallbackData(address(vault));
        bytes32 marketId = IdLib.toId(testMarket);

        // First borrow: 50e18
        _takeOffer(50e18, callbackData, lender);

        uint256 debt1 = midnight.debt(marketId, seller);
        uint256 collateral1 = midnight.collateral(marketId, seller, 0);

        assertEq(debt1, 50e18);
        uint256 expectedDeposit1 = _calculateTotalDeposit(50e18, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK);
        assertEq(collateral1, vault.convertToShares(expectedDeposit1));

        // Second borrow: 30e18
        _takeOffer(30e18, callbackData, lender);

        uint256 debt2 = midnight.debt(marketId, seller);
        uint256 collateral2 = midnight.collateral(marketId, seller, 0);

        assertEq(debt2, 80e18);
        uint256 expectedDeposit2 = _calculateTotalDeposit(30e18, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK);
        assertEq(collateral2, collateral1 + vault.convertToShares(expectedDeposit2));

        // Position should still be healthy
        assertTrue(midnight.isHealthy(testMarket, marketId, seller));
    }

    /* ========== TOKEN FLOW DETAILED ========== */

    function test_onSell_tokenFlowOrder_morphoSendsBeforeCallbackPulls() public {
        // This test verifies the exact token flow order:
        // 1. Midnight sends sellerAssets to callback (receiver=callback)
        // 2. Callback pulls amountFromSeller from seller
        // Net effect: seller loses amountFromSeller

        bytes memory callbackData = _encodeCallbackData(address(vault));
        uint256 units = 100e18;
        uint256 expectedAmountFromSeller =
            _calculateAmountFromSeller(units, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK);

        uint256 sellerBalanceBefore = loanToken.balanceOf(seller);

        _takeOffer(units, callbackData, lender);

        uint256 sellerBalanceAfter = loanToken.balanceOf(seller);

        // Net change = amountFromSeller (seller pays the over-collateralization cost)
        uint256 netSellerPayment = sellerBalanceBefore - sellerBalanceAfter;
        assertEq(netSellerPayment, expectedAmountFromSeller, "Seller net payment incorrect");
        assertGt(netSellerPayment, 0, "Net payment should be > 0");
    }

    /* ========== INSUFFICIENT BALANCE ========== */

    function test_onSell_revertsWhenSellerHasInsufficientBalance() public {
        // Create a new seller with insufficient balance for the additional deposit
        // Token flow: Midnight sends sellerAssets (100e18) first, then callback pulls totalDeposit (125e18)
        // So seller needs: totalDeposit - sellerAssets = 25e18 of their own funds
        (address poorSeller, uint256 poorSellerSK) = makeAddrAndKey("PoorSeller");

        uint256 sellerAssets = 100e18;
        uint256 totalDeposit = _calculateTotalDeposit(sellerAssets, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK); // 125e18
        uint256 additionalRequired = totalDeposit - sellerAssets; // 25e18

        // Fund poor seller with less than the additional required amount (e.g., 20e18 instead of 25e18)
        // After receiving sellerAssets (100e18), they'll have 120e18, but callback needs 125e18
        loanToken.mint(poorSeller, additionalRequired - 5e18); // 20e18

        // Poor seller approves callback and authorizes ratifier
        vm.startPrank(poorSeller);
        loanToken.approve(address(callback), type(uint256).max);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, poorSeller);
        vm.stopPrank();

        bytes memory callbackData = abi.encode(
            IMidnightSupplyVaultSharesCallback.CallbackData({
                vault: address(vault), collateralIndex: 0, additionalDepositPercent: DEFAULT_ADDITIONAL_DEPOSIT_PERCENT
            })
        );
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, "poor"));

        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: poorSeller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, poorSellerSK);

        // Should revert because:
        // - Seller starts with 20e18
        // - Midnight sends 100e18, so seller has 120e18
        // - Callback tries to pull 125e18, but seller only has 120e18
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = sellerAssets;
        vm.prank(lender);
        vm.expectRevert();
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );
    }

    /* ========== INSUFFICIENT BALANCE ========== */

    function test_onSell_succeedsWhenSellerHasExactlyAdditionalRequired() public {
        // Create a new seller with exactly the additional amount needed (totalDeposit - sellerAssets)
        (address exactSeller, uint256 exactSellerSK) = makeAddrAndKey("ExactSeller");

        uint256 sellerAssets = 100e18;
        uint256 totalDeposit = _calculateTotalDeposit(sellerAssets, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK); // 125e18
        uint256 additionalRequired = totalDeposit - sellerAssets; // 25e18

        // Fund exact seller with exactly the additional required (25e18)
        // After Midnight sends 100e18, seller will have exactly 125e18 for callback
        loanToken.mint(exactSeller, additionalRequired);

        // Exact seller approves callback and authorizes on Midnight
        vm.startPrank(exactSeller);
        loanToken.approve(address(callback), type(uint256).max);
        midnight.setIsAuthorized(address(callback), true, exactSeller);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, exactSeller);
        vm.stopPrank();

        bytes memory callbackData = abi.encode(
            IMidnightSupplyVaultSharesCallback.CallbackData({
                vault: address(vault), collateralIndex: 0, additionalDepositPercent: DEFAULT_ADDITIONAL_DEPOSIT_PERCENT
            })
        );
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, "exact"));

        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: exactSeller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, exactSellerSK);

        // Token flow:
        // - Seller starts with 25e18
        // - Midnight sends 100e18, seller has 125e18
        // - Callback pulls 125e18, seller has 0e18
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = sellerAssets;
        vm.prank(lender);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, lender, address(0), address(0), ""
        );

        // Verify seller ends up with 0 tokens (all went to vault as collateral)
        assertEq(loanToken.balanceOf(exactSeller), 0, "Seller should have 0 tokens remaining");

        // Verify collateral was supplied
        bytes32 marketId = IdLib.toId(testMarket);
        uint256 collateral = midnight.collateral(marketId, exactSeller, 0);
        assertEq(collateral, totalDeposit, "Collateral should equal totalDeposit");
    }

    /* ========== RECEIVER IS CALLBACK (OPTION A) ========== */

    function test_onSell_receiverIsCallback_suppliesCollateral() public {
        uint256 sellerAssets = 100e18;
        uint256 totalDeposit = _calculateTotalDeposit(sellerAssets, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK); // 125e18

        bytes memory callbackData = abi.encode(
            IMidnightSupplyVaultSharesCallback.CallbackData({
                vault: address(vault), collateralIndex: 0, additionalDepositPercent: DEFAULT_ADDITIONAL_DEPOSIT_PERCENT
            })
        );

        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, "receiverCallback"));

        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        vm.prank(lender);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            sellerAssets,
            lender,
            address(0),
            address(0),
            ""
        );

        // Verify vault shares supplied as collateral
        bytes32 marketId = IdLib.toId(testMarket);
        uint256 expectedShares = vault.convertToShares(totalDeposit);
        uint256 sellerCollateral = midnight.collateral(marketId, seller, 0);
        assertEq(sellerCollateral, expectedShares, "Collateral not supplied to seller");

        // Verify callback retains no tokens
        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback retained loan tokens");
        assertEq(vault.balanceOf(address(callback)), 0, "Callback retained vault shares");
    }

    function test_onSell_receiverIsCallback_sellerOnlyPaysAdditional() public {
        uint256 sellerAssets = 100e18;
        uint256 totalDeposit = _calculateTotalDeposit(sellerAssets, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK); // 125e18
        uint256 additionalRequired = totalDeposit - sellerAssets; // 25e18

        bytes memory callbackData = abi.encode(
            IMidnightSupplyVaultSharesCallback.CallbackData({
                vault: address(vault), collateralIndex: 0, additionalDepositPercent: DEFAULT_ADDITIONAL_DEPOSIT_PERCENT
            })
        );

        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, "sellerPaysAdditional"));

        Offer memory offer = Offer({
            market: testMarket,
            buy: false,
            maker: seller,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, sellerSK);

        uint256 sellerBalanceBefore = loanToken.balanceOf(seller);

        vm.prank(lender);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            sellerAssets,
            lender,
            address(0),
            address(0),
            ""
        );

        uint256 sellerBalanceAfter = loanToken.balanceOf(seller);

        // When receiver = callback, Midnight sends sellerAssets to the callback (not the seller).
        // The callback already has sellerAssets and only pulls (totalDeposit - sellerAssets) from seller.
        // So the seller's balance decreases by only the additional amount, NOT by totalDeposit.
        assertEq(
            sellerBalanceBefore - sellerBalanceAfter,
            additionalRequired,
            "Seller should only pay the additional amount (totalDeposit - sellerAssets)"
        );

        // Contrast: when receiver = seller, the seller's net balance change is also (totalDeposit - sellerAssets),
        // but the seller must have totalDeposit available at the moment the callback pulls, because
        // Midnight sends sellerAssets to seller first, then callback pulls totalDeposit from seller.
        // With receiver = callback, the seller only needs additionalRequired available.
        assertEq(
            additionalRequired,
            _calculateAmountFromSeller(100e18, DEFAULT_ADDITIONAL_DEPOSIT_PERCENT, DEFAULT_TICK),
            "Additional required should match amountFromSeller"
        );
    }
}
