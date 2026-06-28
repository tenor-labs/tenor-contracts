// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LendVaultToMidnightCallback} from "../../src/callbacks/LendVaultToMidnightCallback.sol";
import {ILendVaultToMidnightCallback} from "@callbacks/interfaces/ILendVaultToMidnightCallback.sol";
import {IMidnight, Market, Offer, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {MockERC4626} from "../helpers/mocks/MockERC4626.sol";
import {Oracle} from "../helpers/Oracle.sol";

import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";

/// @notice Integration tests for LendVaultToMidnightCallback with real Midnight contracts
/// @dev Tests the full EWYW (Earn While You Wait) flow: deposit in vault → create buy offer → take offer →
/// callback withdraws
contract LendVaultToMidnightCallbackIntegrationTest is Test {
    using UtilsLib for uint256;

    LendVaultToMidnightCallback internal callback;
    IMidnight internal midnight;
    MockERC4626 internal vault;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    uint256 internal LENDER_SK;
    address internal LENDER;
    uint256 internal BORROWER_SK;
    address internal BORROWER;
    EcrecoverRatifier internal ecrecoverRatifier;

    uint256 constant INITIAL_BALANCE = 100_000e18;
    uint256 constant DEPOSIT_AMOUNT = 10_000e18;
    uint256 constant LEND_AMOUNT = 1000e18;
    uint256 constant COLLATERAL_AMOUNT = 5000e18;

    function setUp() public {
        // Create test accounts
        (LENDER, LENDER_SK) = makeAddrAndKey("lender");
        (BORROWER, BORROWER_SK) = makeAddrAndKey("borrower");

        // Deploy tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COLL", 18);

        // Deploy oracle
        oracle = new Oracle();
        oracle.setPrice(1e36); // 1:1 price (ORACLE_PRICE_SCALE = 1e36)

        // Deploy Midnight
        midnight = IMidnight(address(new Midnight()));
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(LENDER);
        Midnight(address(midnight)).setIsAuthorized(address(ecrecoverRatifier), true, LENDER);

        // Deploy vault backed by loanToken
        vault = new MockERC4626(address(loanToken), "Test Vault", "vTEST");

        // Deploy callback contract
        callback = new LendVaultToMidnightCallback(address(midnight));

        // Mint tokens
        loanToken.mint(LENDER, INITIAL_BALANCE);
        loanToken.mint(BORROWER, INITIAL_BALANCE);
        collateralToken.mint(BORROWER, INITIAL_BALANCE);

        // Lender approvals
        vm.startPrank(LENDER);
        loanToken.approve(address(vault), type(uint256).max);
        loanToken.approve(address(midnight), type(uint256).max);
        vault.approve(address(callback), type(uint256).max); // Allow callback to spend vault shares
        vm.stopPrank();

        // Borrower approvals
        vm.startPrank(BORROWER);
        loanToken.approve(address(midnight), type(uint256).max);
        collateralToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();
    }

    /* ========== HELPERS ========== */

    function _createMarket() internal view returns (Market memory) {
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.77e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        return Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _createBuyOffer(uint256 assets, Market memory market, uint256 price) internal view returns (Offer memory) {
        ILendVaultToMidnightCallback.CallbackData memory callbackData = ILendVaultToMidnightCallback.CallbackData({
            vault: address(vault),
            feeRate: 0, // Zero fee for basic tests
            feeRecipient: address(0),
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            morphoBlueMarketId: bytes32(0)
        });

        return Offer({
            buy: true,
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            group: bytes32(0),
            callback: address(callback),
            callbackData: abi.encode(callbackData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(sk, digest);
        return signature;
    }

    function _toId(Market memory market) internal view returns (bytes32) {
        return IdLib.toId(market);
    }

    /* ========== FULL EWYW FLOW TEST ========== */

    function test_fullEWYWFlow() public {
        // === Setup ===
        Market memory market = _createMarket();
        bytes32 marketId = _toId(market);
        uint256 price = 0.95e18; // 5% discount (lender pays 0.95 to get 1 at maturity)

        // 1. Lender deposits into vault (earns yield while waiting)
        vm.prank(LENDER);
        vault.deposit(DEPOSIT_AMOUNT, LENDER);

        assertEq(vault.balanceOf(LENDER), DEPOSIT_AMOUNT); // 1:1 initial exchange rate
        assertEq(loanToken.balanceOf(address(vault)), DEPOSIT_AMOUNT);

        // 2. Create buy offer with callback
        Offer memory buyOffer = _createBuyOffer(LEND_AMOUNT, market, price);
        Signature memory sig = _signOffer(buyOffer, LENDER_SK);

        // Record lender's initial state
        uint256 lenderSharesBefore = vault.balanceOf(LENDER);

        // 3. Borrower supplies collateral
        vm.prank(BORROWER);
        midnight.supplyCollateral(market, 0, COLLATERAL_AMOUNT, BORROWER);

        // 4. Borrower takes the offer (sells bonds to lender)
        // This triggers the callback which withdraws from vault
        bytes32 root = HashLib.hashOffer(buyOffer);
        bytes32[] memory proof = new bytes32[](0);

        bytes32 _id = IdLib.toId(buyOffer.market);
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, buyOffer, LEND_AMOUNT);
        vm.prank(BORROWER);
        midnight.take(
            buyOffer,
            abi.encode(sig, root, uint256(0), proof),
            _shares,
            BORROWER,
            buyOffer.maker,
            address(0), // no taker callback
            ""
        );

        // 5. Verify: lender has market shares, vault shares decreased
        uint256 lenderSharesAfter = vault.balanceOf(LENDER);
        assertLt(lenderSharesAfter, lenderSharesBefore, "Vault shares should decrease");

        // Lender should have market shares (received bonds)
        uint256 lenderMarketShares = creditAfterSlashing(midnight, marketId, LENDER);
        assertGt(lenderMarketShares, 0, "Lender should have market shares");

        // Borrower should have debt
        uint256 borrowerDebt = midnight.debt(marketId, BORROWER);
        assertGt(borrowerDebt, 0, "Borrower should have debt");
    }

    /* ========== CORRECT WITHDRAWAL AMOUNT TEST ========== */

    /// @notice Verifies the callback withdraws exactly buyerAssets + fee, not units + fee
    /// @dev This test catches the bug where units was used instead of buyerAssets
    function test_withdrawsCorrectAmount_noStrandedFunds() public {
        Market memory market = _createMarket();
        uint256 price = 0.95e18; // 5% discount → 5.26% interest

        // Setup: Lender deposits into vault
        vm.prank(LENDER);
        vault.deposit(DEPOSIT_AMOUNT, LENDER);

        // Create buy offer with NO fee to isolate the withdrawal amount bug
        Offer memory buyOffer = _createBuyOffer(LEND_AMOUNT, market, price);
        Signature memory sig = _signOffer(buyOffer, LENDER_SK);

        // Borrower supplies collateral
        vm.prank(BORROWER);
        midnight.supplyCollateral(market, 0, COLLATERAL_AMOUNT, BORROWER);

        // Record balances before
        uint256 vaultAssetsBefore = loanToken.balanceOf(address(vault));
        uint256 callbackBalanceBefore = loanToken.balanceOf(address(callback));
        assertEq(callbackBalanceBefore, 0, "Callback should start with 0 balance");

        // Take the offer
        bytes32 root = HashLib.hashOffer(buyOffer);
        bytes32[] memory proof = new bytes32[](0);

        bytes32 _id = IdLib.toId(buyOffer.market);
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, buyOffer, LEND_AMOUNT);
        vm.prank(BORROWER);
        midnight.take(
            buyOffer, abi.encode(sig, root, uint256(0), proof), _shares, BORROWER, buyOffer.maker, address(0), ""
        );

        // Calculate expected values
        // buyerAssets = LEND_AMOUNT (what lender pays)
        // units = LEND_AMOUNT / price = 1000e18 / 0.95e18 ≈ 1052.63e18 (face value at maturity)
        uint256 expectedMarketUnits = LEND_AMOUNT.mulDivUp(1e18, price);
        uint256 interest = expectedMarketUnits - LEND_AMOUNT;

        // CRITICAL ASSERTIONS:
        // 1. Callback contract should have NO stranded funds
        uint256 callbackBalanceAfter = loanToken.balanceOf(address(callback));
        assertEq(callbackBalanceAfter, 0, "Callback should have 0 balance - no stranded funds");

        // 2. Vault should have withdrawn exactly buyerAssets (since fee=0)
        uint256 vaultAssetsAfter = loanToken.balanceOf(address(vault));
        uint256 actualWithdrawn = vaultAssetsBefore - vaultAssetsAfter;
        assertEq(actualWithdrawn, LEND_AMOUNT, "Should withdraw exactly buyerAssets");

        // 3. If bug existed (withdrawing units), interest would be stranded
        // This assertion would fail with the old code
        assertTrue(interest > 0, "Interest should be positive for this test to be meaningful");
    }

    /// @notice Verifies correct withdrawal with fees enabled
    function test_withdrawsCorrectAmount_withFee() public {
        Market memory market = _createMarket();
        uint256 price = 0.95e18;
        uint256 feeRate = 0.1e18; // 10% fee on interest
        address feeRecipient = makeAddr("feeRecipient");

        // Setup
        vm.prank(LENDER);
        vault.deposit(DEPOSIT_AMOUNT, LENDER);

        // Create buy offer WITH fee
        ILendVaultToMidnightCallback.CallbackData memory callbackData = ILendVaultToMidnightCallback.CallbackData({
            vault: address(vault),
            feeRate: feeRate,
            feeRecipient: feeRecipient,
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            morphoBlueMarketId: bytes32(0)
        });

        Offer memory buyOffer = Offer({
            buy: true,
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            group: bytes32(0),
            callback: address(callback),
            callbackData: abi.encode(callbackData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig = _signOffer(buyOffer, LENDER_SK);

        // Borrower setup
        vm.prank(BORROWER);
        midnight.supplyCollateral(market, 0, COLLATERAL_AMOUNT, BORROWER);

        // Record balances
        uint256 vaultAssetsBefore = loanToken.balanceOf(address(vault));
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        // Take offer
        bytes32 root = HashLib.hashOffer(buyOffer);
        bytes32[] memory proof = new bytes32[](0);

        bytes32 _id = IdLib.toId(buyOffer.market);
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, buyOffer, LEND_AMOUNT);
        vm.prank(BORROWER);
        midnight.take(
            buyOffer, abi.encode(sig, root, uint256(0), proof), _shares, BORROWER, buyOffer.maker, address(0), ""
        );

        // Assertions
        uint256 callbackBalanceAfter = loanToken.balanceOf(address(callback));
        assertEq(callbackBalanceAfter, 0, "Callback should have 0 balance after execution");

        // Callback withdraws buyerAssets + fee from vault (fee is in loan token assets)
        uint256 vaultAssetsAfter = loanToken.balanceOf(address(vault));
        uint256 actualWithdrawn = vaultAssetsBefore - vaultAssetsAfter;
        assertGt(actualWithdrawn, LEND_AMOUNT, "Should withdraw more than buyerAssets from vault (includes fee)");

        // Fee recipient receives fee in loan tokens
        uint256 feeRecipientAfter = loanToken.balanceOf(feeRecipient);
        uint256 feeReceived = feeRecipientAfter - feeRecipientBefore;
        assertGt(feeReceived, 0, "Fee recipient should receive fee in loan tokens");
        assertEq(actualWithdrawn - LEND_AMOUNT, feeReceived, "Extra withdrawal should equal fee received");
    }

    /* ========== PARTIAL FILL TEST ========== */

    function test_partialFill() public {
        Market memory market = _createMarket();
        uint256 price = 0.95e18;

        // Lender deposits
        vm.prank(LENDER);
        vault.deposit(DEPOSIT_AMOUNT, LENDER);

        // Create offer for 1000 tokens
        Offer memory buyOffer = _createBuyOffer(LEND_AMOUNT, market, price);
        Signature memory sig = _signOffer(buyOffer, LENDER_SK);

        // Borrower supplies collateral
        vm.prank(BORROWER);
        midnight.supplyCollateral(market, 0, COLLATERAL_AMOUNT, BORROWER);

        // First partial fill: 400 tokens
        uint256 partialAmount = 400e18;
        bytes32 root = HashLib.hashOffer(buyOffer);
        bytes32[] memory proof = new bytes32[](0);

        uint256 sharesBefore = vault.balanceOf(LENDER);

        bytes32 _id = IdLib.toId(buyOffer.market);
        uint256 _shares1 = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, buyOffer, partialAmount);
        vm.prank(BORROWER);
        midnight.take(
            buyOffer, abi.encode(sig, root, uint256(0), proof), _shares1, BORROWER, buyOffer.maker, address(0), ""
        );

        uint256 sharesAfterFirst = vault.balanceOf(LENDER);
        assertLt(sharesAfterFirst, sharesBefore, "First fill should burn shares");

        // Second partial fill: 400 more tokens
        uint256 _shares2 = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, buyOffer, partialAmount);
        vm.prank(BORROWER);
        midnight.take(
            buyOffer, abi.encode(sig, root, uint256(0), proof), _shares2, BORROWER, buyOffer.maker, address(0), ""
        );

        uint256 sharesAfterSecond = vault.balanceOf(LENDER);
        assertLt(sharesAfterSecond, sharesAfterFirst, "Second fill should burn more shares");

        // Remaining: 200 tokens should still be available
        uint256 remaining = 200e18;
        uint256 _shares3 = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, buyOffer, remaining);
        vm.prank(BORROWER);
        midnight.take(
            buyOffer, abi.encode(sig, root, uint256(0), proof), _shares3, BORROWER, buyOffer.maker, address(0), ""
        );

        // Offer should be fully consumed now
    }

    /* ========== VAULT WITH YIELD TEST ========== */

    /* ========== ERROR CASE: INSUFFICIENT SHARES ========== */

    function test_revert_insufficientVaultShares() public {
        Market memory market = _createMarket();
        uint256 price = 0.95e18;

        // Lender deposits small amount
        uint256 smallDeposit = 100e18;
        vm.prank(LENDER);
        vault.deposit(smallDeposit, LENDER);

        // Create offer for more than deposited
        Offer memory buyOffer = _createBuyOffer(LEND_AMOUNT, market, price);
        Signature memory sig = _signOffer(buyOffer, LENDER_SK);

        vm.prank(BORROWER);
        midnight.supplyCollateral(market, 0, COLLATERAL_AMOUNT, BORROWER);

        bytes32 root = HashLib.hashOffer(buyOffer);
        bytes32[] memory proof = new bytes32[](0);

        // Should revert due to insufficient vault shares
        bytes32 _id = IdLib.toId(buyOffer.market);
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, buyOffer, LEND_AMOUNT);
        vm.prank(BORROWER);
        vm.expectRevert(); // ERC4626 will revert with arithmetic underflow
        midnight.take(
            buyOffer, abi.encode(sig, root, uint256(0), proof), _shares, BORROWER, buyOffer.maker, address(0), ""
        );
    }

    /* ========== MULTIPLE LENDERS TEST ========== */

    function test_multipleLenders() public {
        // Create second lender
        (address LENDER2, uint256 LENDER2_SK) = makeAddrAndKey("lender2");
        loanToken.mint(LENDER2, INITIAL_BALANCE);

        vm.startPrank(LENDER2);
        loanToken.approve(address(vault), type(uint256).max);
        loanToken.approve(address(midnight), type(uint256).max);
        vault.approve(address(callback), type(uint256).max);
        vault.deposit(DEPOSIT_AMOUNT, LENDER2);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, LENDER2);
        vm.stopPrank();

        // First lender deposits
        vm.prank(LENDER);
        vault.deposit(DEPOSIT_AMOUNT, LENDER);

        Market memory market = _createMarket();
        uint256 price = 0.95e18;

        // Both lenders create offers
        Offer memory offer1 = _createBuyOffer(500e18, market, price);
        offer1.group = bytes32(uint256(1)); // Use unique group
        Signature memory sig1 = _signOffer(offer1, LENDER_SK);

        ILendVaultToMidnightCallback.CallbackData memory lendData2 = ILendVaultToMidnightCallback.CallbackData({
            vault: address(vault),
            feeRate: 0,
            feeRecipient: address(0),
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            morphoBlueMarketId: bytes32(0)
        });

        Offer memory offer2 = Offer({
            buy: true,
            maker: LENDER2,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(price, DEFAULT_TICK_SPACING),
            group: bytes32(uint256(2)), // Use unique group
            callback: address(callback),
            callbackData: abi.encode(lendData2),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        Signature memory sig2 = _signOffer(offer2, LENDER2_SK);

        // Borrower supplies collateral
        vm.prank(BORROWER);
        midnight.supplyCollateral(market, 0, COLLATERAL_AMOUNT, BORROWER);

        // Take first offer
        bytes32 root1 = HashLib.hashOffer(offer1);
        bytes32[] memory proof1 = new bytes32[](0);
        bytes32 _id1 = IdLib.toId(offer1.market);
        uint256 _shares1 = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id1, offer1, 500e18);
        vm.prank(BORROWER);
        midnight.take(
            offer1, abi.encode(sig1, root1, uint256(0), proof1), _shares1, BORROWER, offer1.maker, address(0), ""
        );

        // Take second offer
        bytes32 root2 = HashLib.hashOffer(offer2);
        bytes32[] memory proof2 = new bytes32[](0);
        bytes32 _id2 = IdLib.toId(offer2.market);
        uint256 _shares2 = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id2, offer2, 500e18);
        vm.prank(BORROWER);
        midnight.take(
            offer2, abi.encode(sig2, root2, uint256(0), proof2), _shares2, BORROWER, offer2.maker, address(0), ""
        );

        // Both lenders should have reduced vault shares
        assertLt(vault.balanceOf(LENDER), DEPOSIT_AMOUNT);
        assertLt(vault.balanceOf(LENDER2), DEPOSIT_AMOUNT);
    }
}
