// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {MidnightWithdrawVaultSharesCallback} from "../../src/callbacks/MidnightWithdrawVaultSharesCallback.sol";
import {IMidnightWithdrawVaultSharesCallback} from "@callbacks/interfaces/IMidnightWithdrawVaultSharesCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {MockERC4626} from "../helpers/mocks/MockERC4626.sol";
import {MockVaultV2} from "../helpers/mocks/MockVaultV2.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";

contract MidnightWithdrawVaultSharesCallbackTest is Test {
    MidnightWithdrawVaultSharesCallback internal callback;
    Midnight internal midnight;
    MockERC20 internal loanToken;
    MockERC4626 internal vault;
    Oracle internal oracle;

    address internal buyer;
    uint256 internal buyerSK;
    address internal seller; // Taker who provides loan tokens
    EcrecoverRatifier internal ecrecoverRatifier;

    Market internal testMarket;

    function setUp() public virtual {
        (buyer, buyerSK) = makeAddrAndKey("Buyer");
        seller = makeAddr("Seller");

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

        vm.prank(buyer);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, buyer);

        // Deploy callback
        callback = new MidnightWithdrawVaultSharesCallback(address(midnight));

        // Create market with vault as collateral
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

        // Setup seller with loan tokens
        loanToken.mint(seller, 100000e18);
        vm.prank(seller);
        loanToken.approve(address(midnight), type(uint256).max);

        // Buyer authorizes callback to act on their behalf in Midnight
        vm.prank(buyer);
        midnight.setIsAuthorized(address(callback), true, buyer);
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

    function _encodeCallbackData(address vaultAddress) internal pure returns (bytes memory) {
        return abi.encode(IMidnightWithdrawVaultSharesCallback.CallbackData({vault: vaultAddress, collateralIndex: 0}));
    }

    /// @dev Setup buyer with vault shares as collateral AND debt (borrower position)
    /// Also sets up seller as a lender (with market shares) so they can take buy offers
    /// @param vaultShareAmount Amount of vault shares to supply as collateral
    function _setupBuyerPosition(uint256 vaultShareAmount) internal {
        // Step 1: Mint loan tokens to buyer, deposit into vault, supply as collateral
        loanToken.mint(buyer, vaultShareAmount);
        vm.startPrank(buyer);
        loanToken.approve(address(vault), vaultShareAmount);
        uint256 shares = vault.deposit(vaultShareAmount, buyer);

        // Approve Midnight to transfer vault shares
        vault.approve(address(midnight), shares);
        midnight.supplyCollateral(testMarket, 0, shares, buyer);

        // Approve Midnight to pull loan tokens after callback sends them to buyer
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Step 2: Create debt for buyer via a SELL offer (buyer borrows, seller lends)
        // This also gives seller market shares (making them a lender)
        uint256 borrowAmount = vaultShareAmount / 2; // Borrow half of collateral value (safe LTV)

        // Create a sell offer from buyer (to borrow)
        bytes32 uniqueGroup = keccak256(abi.encodePacked("setup_borrow", block.timestamp));
        Offer memory sellOffer = Offer({
            market: testMarket,
            buy: false, // SELL offer (borrow)
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(0), // No callback for setup
            callbackData: "",
            receiverIfMakerIsSeller: buyer,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(sellOffer);
        Signature memory sig = _signOffer(sellOffer, buyerSK);

        // Seller takes the sell offer (provides loan tokens, becomes a lender with shares)
        bytes32 _id = IdLib.toId(sellOffer.market);
        uint256 _shares = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, sellOffer, borrowAmount);
        vm.prank(seller);
        midnight.take(
            sellOffer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            seller,
            address(0),
            address(0),
            ""
        );
    }

    /// @dev Create initial debt for buyer and make seller a lender (without collateral setup)
    /// Used when tests manually set up collateral but need the borrow/lend relationship
    function _setupInitialDebt(uint256 borrowAmount) internal {
        // Create a sell offer from buyer (to borrow)
        bytes32 uniqueGroup = keccak256(abi.encodePacked("setup_debt", block.timestamp, borrowAmount));
        Offer memory sellOffer = Offer({
            market: testMarket,
            buy: false, // SELL offer (borrow)
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(0), // No callback for setup
            callbackData: "",
            receiverIfMakerIsSeller: buyer,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(sellOffer);
        Signature memory sig = _signOffer(sellOffer, buyerSK);

        // Seller takes the sell offer (provides loan tokens, becomes a lender with shares)
        bytes32 _id = IdLib.toId(sellOffer.market);
        uint256 _shares = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, sellOffer, borrowAmount);
        vm.prank(seller);
        midnight.take(
            sellOffer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            seller,
            address(0),
            address(0),
            ""
        );
    }

    /// @dev Create and take a buy offer
    /// @param buyerAssets Amount of assets the buyer needs to pay
    /// @param callbackData Encoded callback data
    function _takeBuyOffer(uint256 buyerAssets, bytes memory callbackData) internal {
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, buyerAssets, gasleft()));

        Offer memory offer = Offer({
            market: testMarket,
            buy: true, // BUY offer
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, buyerSK);

        // Seller takes the buy offer
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _takeShares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, buyerAssets);
        vm.prank(seller);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _takeShares, seller, seller, address(0), ""
        );
    }

    /* ========== CONSTRUCTOR ========== */

    function test_constructor_setsMidnight() public view {
        assertEq(address(callback.MORPHO_MIDNIGHT()), address(midnight));
    }

    /* ========== AUTHORIZATION ========== */

    function test_onBuy_revertsOnlyMidnight() public {
        bytes memory data = _encodeCallbackData(address(vault));

        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onBuy(bytes32(0), testMarket, 100e18, 0, 0, buyer, data);
    }

    function test_onBuy_revertsWhenCallerIsRandomAddress() public {
        address randomCaller = makeAddr("RandomCaller");
        bytes memory data = _encodeCallbackData(address(vault));

        vm.prank(randomCaller);
        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onBuy(bytes32(0), testMarket, 100e18, 0, 0, buyer, data);
    }

    /* ========== INPUT VALIDATION ========== */

    function test_onBuy_revertsZeroAmount() public {
        bytes memory data = _encodeCallbackData(address(vault));

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        callback.onBuy(bytes32(0), testMarket, 0, 0, 0, buyer, data);
    }

    function test_onBuy_revertsVaultAssetMismatch() public {
        // Create vault backed by different token
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);
        MockERC4626 wrongVault = new MockERC4626(address(wrongToken), "Wrong Vault", "vWRONG");

        bytes memory data = _encodeCallbackData(address(wrongVault));

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        callback.onBuy(bytes32(0), testMarket, 100e18, 200e18, 0, buyer, data);
    }

    function test_onBuy_revertsVaultNotInCollaterals() public {
        // Create valid vault (same asset) but not in market collaterals
        MockERC4626 otherVault = new MockERC4626(address(loanToken), "Other Vault", "vOTHER");

        bytes memory data = _encodeCallbackData(address(otherVault));

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        callback.onBuy(bytes32(0), testMarket, 100e18, 200e18, 0, buyer, data);
    }

    /* ========== CORE FUNCTIONALITY ========== */

    function test_onBuy_withdrawsCollateralFromBuyer() public {
        // Setup buyer with 200 vault shares as collateral (100e18 debt)
        // Buy 25e18 so remaining debt > 0 → has-debt branch (partial withdrawal)
        _setupBuyerPosition(200e18);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 collateralBefore = midnight.collateral(marketId, buyer, 0);
        assertEq(collateralBefore, 200e18, "Initial collateral should be 200e18");

        // Take buy offer for 25 assets (partial repayment, leaves remaining debt)
        bytes memory callbackData = _encodeCallbackData(address(vault));
        _takeBuyOffer(25e18, callbackData);

        // Buyer's collateral should decrease by shares needed for 25 assets
        uint256 collateralAfter = midnight.collateral(marketId, buyer, 0);
        uint256 expectedSharesWithdrawn = vault.previewWithdraw(25e18);
        assertEq(collateralAfter, collateralBefore - expectedSharesWithdrawn, "Collateral not reduced correctly");
    }

    function test_onBuy_sendsAssetsToBuyer() public {
        _setupBuyerPosition(100e18);

        uint256 buyerBalanceBefore = loanToken.balanceOf(buyer);

        bytes memory callbackData = _encodeCallbackData(address(vault));
        _takeBuyOffer(50e18, callbackData);

        // In a buy offer with callback:
        // 1. Callback receives vault shares from Midnight.withdrawCollateral
        // 2. Callback redeems vault shares, sending 50e18 to buyer
        // 3. Midnight pulls 50e18 from buyer to pay seller
        // Net effect: buyer's wallet balance stays the same (receives from vault, pays to seller)
        uint256 buyerBalanceAfter = loanToken.balanceOf(buyer);
        assertEq(buyerBalanceAfter, buyerBalanceBefore, "Buyer wallet balance unchanged (receives and pays)");
    }

    function test_onBuy_callbackRetainsNoTokens() public {
        _setupBuyerPosition(100e18);

        bytes memory callbackData = _encodeCallbackData(address(vault));
        _takeBuyOffer(50e18, callbackData);

        // Callback should have no tokens
        assertEq(vault.balanceOf(address(callback)), 0, "Callback should have no vault shares");
        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback should have no loan tokens");
    }

    function test_onBuy_fullFlow() public {
        // Setup buyer with 200 vault shares as collateral (100e18 debt)
        _setupBuyerPosition(200e18);

        bytes32 marketId = IdLib.toId(testMarket);

        // Record initial state
        uint256 buyerCollateralBefore = midnight.collateral(marketId, buyer, 0);
        uint256 buyerDebtBefore = midnight.debt(marketId, buyer);
        uint256 sellerSharesBefore = creditAfterSlashing(midnight, marketId, seller);

        // Take buy offer for 50 assets (partial repayment, leaves remaining debt)
        bytes memory callbackData = _encodeCallbackData(address(vault));
        _takeBuyOffer(50e18, callbackData);

        // Verify final state
        uint256 expectedSharesWithdrawn = vault.previewWithdraw(50e18);

        // Buyer's collateral decreased
        assertEq(
            midnight.collateral(marketId, buyer, 0),
            buyerCollateralBefore - expectedSharesWithdrawn,
            "Buyer collateral not reduced"
        );

        // Buyer's debt decreased (repaid via buy offer)
        assertLt(midnight.debt(marketId, buyer), buyerDebtBefore, "Buyer debt should decrease");

        // Seller's shares decreased (they exited their lending position)
        assertLt(creditAfterSlashing(midnight, marketId, seller), sellerSharesBefore, "Seller shares should decrease");
    }

    /* ========== EXCHANGE RATE TESTS ========== */

    function test_onBuy_exchangeRate_1to1() public {
        // Default rate is 1:1
        // Use 200e18 position (100e18 debt) and buy 25e18 for partial repayment
        _setupBuyerPosition(200e18);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 collateralBefore = midnight.collateral(marketId, buyer, 0);

        bytes memory callbackData = _encodeCallbackData(address(vault));
        _takeBuyOffer(25e18, callbackData);

        // At 1:1 rate, should withdraw exactly 25 shares for 25 assets
        uint256 collateralAfter = midnight.collateral(marketId, buyer, 0);
        assertEq(collateralAfter, collateralBefore - 25e18, "Should withdraw 25 shares at 1:1 rate");
    }

    function test_onBuy_exchangeRate_favorable() public {
        // Set exchange rate to 1.1e18 (1 share = 1.1 assets, favorable to holder)
        vault.setExchangeRate(1.1e18);

        // Deposit 110e18 loan tokens to get 100 shares at 1.1 rate
        loanToken.mint(buyer, 110e18);
        vm.startPrank(buyer);
        loanToken.approve(address(vault), 110e18);
        uint256 shares = vault.deposit(110e18, buyer); // Should get 100 shares
        vault.approve(address(midnight), shares);
        midnight.supplyCollateral(testMarket, 0, shares, buyer);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Setup initial debt and make seller a lender (50e18 debt)
        _setupInitialDebt(50e18);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 collateralBefore = midnight.collateral(marketId, buyer, 0);

        // Buy 25e18 for partial repayment (leaves 25e18 remaining debt)
        bytes memory callbackData = _encodeCallbackData(address(vault));
        _takeBuyOffer(25e18, callbackData);

        // At 1.1 rate: previewWithdraw(25e18) ≈ 22.72e18 shares (fewer shares needed)
        uint256 expectedSharesWithdrawn = vault.previewWithdraw(25e18);
        uint256 collateralAfter = midnight.collateral(marketId, buyer, 0);
        assertEq(collateralAfter, collateralBefore - expectedSharesWithdrawn, "Should withdraw correct shares");
        assertLt(expectedSharesWithdrawn, 25e18, "Should need fewer shares than assets at favorable rate");
    }

    function test_onBuy_exchangeRate_unfavorable() public {
        // Set exchange rate to 0.9e18 (1 share = 0.9 assets, unfavorable to holder)
        vault.setExchangeRate(0.9e18);

        // Deposit 90e18 loan tokens to get 100 shares at 0.9 rate
        loanToken.mint(buyer, 90e18);
        vm.startPrank(buyer);
        loanToken.approve(address(vault), 90e18);
        uint256 shares = vault.deposit(90e18, buyer); // Should get 100 shares
        vault.approve(address(midnight), shares);
        midnight.supplyCollateral(testMarket, 0, shares, buyer);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Setup initial debt and make seller a lender (45e18 debt)
        _setupInitialDebt(45e18);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 collateralBefore = midnight.collateral(marketId, buyer, 0);

        // Buy 20e18 for partial repayment (leaves 25e18 remaining debt)
        bytes memory callbackData = _encodeCallbackData(address(vault));
        _takeBuyOffer(20e18, callbackData);

        // At 0.9 rate, need more shares: ~22.2 shares for 20 assets
        uint256 expectedSharesWithdrawn = vault.previewWithdraw(20e18);
        uint256 collateralAfter = midnight.collateral(marketId, buyer, 0);
        assertEq(
            collateralAfter,
            collateralBefore - expectedSharesWithdrawn,
            "Should withdraw more shares at unfavorable rate"
        );
        assertGt(expectedSharesWithdrawn, 20e18, "Should need more shares than assets at unfavorable rate");
    }

    /* ========== EDGE CASES ========== */

    function test_onBuy_insufficientCollateral() public {
        // Setup buyer with 200e18 vault shares as collateral (100e18 debt)
        _setupBuyerPosition(200e18);

        // Change exchange rate so each vault share is now worth 0.1 assets
        // Buyer has 200 vault shares, but they're only worth 20e18 assets now.
        // When the buy offer tries to withdraw shares for 50e18 assets, it would need
        // previewWithdraw(50e18) = 500 shares, but buyer only has 200.
        vault.setExchangeRate(0.1e18);

        bytes memory callbackData = _encodeCallbackData(address(vault));

        // Build offer inline so we can compute shares before calling vm.expectRevert
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, uint256(50e18), gasleft()));
        Offer memory offer = Offer({
            market: testMarket,
            buy: true,
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, buyerSK);

        // Compute shares before expectRevert to avoid consuming the revert expectation
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _takeShares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, 50e18);

        vm.prank(seller);
        vm.expectRevert(); // Will revert in withdrawCollateral (insufficient collateral)
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _takeShares, seller, seller, address(0), ""
        );
    }

    function test_onBuy_emitsVaultSharesWithdrawnEvent() public {
        // Use 200e18 position (100e18 debt) and buy 25e18 for partial repayment
        _setupBuyerPosition(200e18);

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 buyerAssets = 25e18;
        uint256 expectedShares = vault.previewWithdraw(buyerAssets);

        bytes memory callbackData = _encodeCallbackData(address(vault));

        // Create offer
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, buyerAssets, gasleft()));
        Offer memory offer = Offer({
            market: testMarket,
            buy: true,
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, buyerSK);

        vm.expectEmit(true, true, true, true);
        emit IMidnightWithdrawVaultSharesCallback.VaultSharesWithdrawn(
            buyer, marketId, address(vault), buyerAssets, expectedShares
        );

        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, buyerAssets);
            vm.prank(seller);
            midnight.take(
                offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, seller, seller, address(0), ""
            );
        }
    }

    /* ========== MULTI-COLLATERAL ========== */

    function test_onBuy_multipleCollateralsInMarket() public {
        // Create market with multiple collaterals (vault + another token)
        MockERC20 otherCollateral = new MockERC20("Other", "OTHER", 18);

        // Midnight requires collateralParams sorted by token address (ascending)
        CollateralParams[] memory collaterals = new CollateralParams[](2);
        uint256 vaultIndex;
        if (address(vault) < address(otherCollateral)) {
            collaterals[0] = CollateralParams({
                token: address(vault), lltv: 0.77e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
            });
            collaterals[1] = CollateralParams({
                token: address(otherCollateral),
                lltv: 0.77e18,
                liquidationCursor: LIQUIDATION_CURSOR,
                oracle: address(oracle)
            });
            vaultIndex = 0;
        } else {
            collaterals[0] = CollateralParams({
                token: address(otherCollateral),
                lltv: 0.77e18,
                liquidationCursor: LIQUIDATION_CURSOR,
                oracle: address(oracle)
            });
            collaterals[1] = CollateralParams({
                token: address(vault), lltv: 0.77e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
            });
            vaultIndex = 1;
        }

        Market memory multiCollatMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Setup buyer position for new market
        loanToken.mint(buyer, 100e18);
        vm.startPrank(buyer);
        loanToken.approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, buyer);
        vault.approve(address(midnight), shares);
        midnight.supplyCollateral(multiCollatMarket, vaultIndex, shares, buyer);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Setup debt for buyer and make seller a lender for this market (50e18 debt)
        bytes32 uniqueGroupBorrow = keccak256(abi.encodePacked("setup_multi", block.timestamp));
        Offer memory sellOffer = Offer({
            market: multiCollatMarket,
            buy: false,
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroupBorrow,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: buyer,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        {
            bytes32 _id = IdLib.toId(sellOffer.market);
            uint256 _shares = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, sellOffer, 50e18);
            vm.prank(seller);
            midnight.take(
                sellOffer,
                abi.encode(_signOffer(sellOffer, buyerSK), HashLib.hashOffer(sellOffer), uint256(0), new bytes32[](0)),
                _shares,
                seller,
                address(0),
                address(0),
                ""
            );
        }

        // Create and take buy offer for 25e18 (partial repayment, leaves remaining debt)
        bytes memory callbackData = abi.encode(
            IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vault), collateralIndex: vaultIndex})
        );
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, uint256(25e18), gasleft()));

        Offer memory offer = Offer({
            market: multiCollatMarket,
            buy: true,
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, buyerSK);

        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, 25e18);
            vm.prank(seller);
            midnight.take(
                offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _shares, seller, seller, address(0), ""
            );
        }

        // Verify collateral was withdrawn
        bytes32 marketId = IdLib.toId(multiCollatMarket);
        assertEq(
            midnight.collateral(marketId, buyer, vaultIndex),
            75e18, // 100 - 25 shares withdrawn
            "Collateral should be reduced"
        );
    }

    /* ========== NO-DEBT COLLATERAL WITHDRAWAL ========== */

    /// @notice Tests the buyerDebt==0 branch.
    ///         When the buyer has no debt, the callback withdraws ALL collateral shares,
    ///         redeems exactly buyerAssets worth, and returns remaining shares to buyer.
    ///         Existing tests only cover the debt>0 branch (partial repayment).
    function test_onBuy_noBuyerDebt_fullCollateralWithdraw() public {
        // Step 1: Setup buyer with vault shares as collateral but NO debt.
        // We do this by having buyer supply collateral directly (no borrowing).
        uint256 vaultShareAmount = 100e18;
        loanToken.mint(buyer, vaultShareAmount);
        vm.startPrank(buyer);
        loanToken.approve(address(vault), vaultShareAmount);
        uint256 shares = vault.deposit(vaultShareAmount, buyer);
        vault.approve(address(midnight), shares);
        midnight.supplyCollateral(testMarket, 0, shares, buyer);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Step 2: We need a lender (seller) with credit on this market.
        // Create an independent borrower to create debt/credit pair.
        (address tempBorrower, uint256 tempBorrowerSK) = makeAddrAndKey("tempBorrower");
        loanToken.mint(seller, type(uint128).max);
        vm.prank(seller);
        loanToken.approve(address(midnight), type(uint256).max);

        // tempBorrower needs collateral
        loanToken.mint(tempBorrower, 1000e18);
        vm.startPrank(tempBorrower);
        loanToken.approve(address(vault), 1000e18);
        uint256 tbShares = vault.deposit(1000e18, tempBorrower);
        vault.approve(address(midnight), tbShares);
        midnight.supplyCollateral(testMarket, 0, tbShares, tempBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, tempBorrower);
        vm.stopPrank();

        // Sell offer from tempBorrower, taken by seller (gives seller credit)
        Offer memory sellOffer = Offer({
            market: testMarket,
            buy: false,
            maker: tempBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: keccak256("setup_seller_credit"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: tempBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        {
            bytes32 _id = IdLib.toId(sellOffer.market);
            uint256 _units = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, sellOffer, 50e18);
            Signature memory sig2 = _signOffer(sellOffer, tempBorrowerSK);
            bytes32 root2 = HashLib.hashOffer(sellOffer);
            vm.prank(seller);
            midnight.take(
                sellOffer,
                abi.encode(sig2, root2, uint256(0), new bytes32[](0)),
                _units,
                seller,
                address(0),
                address(0),
                ""
            );
        }

        // Step 3: Verify buyer has no debt
        bytes32 marketId = IdLib.toId(testMarket);
        assertEq(midnight.debt(marketId, buyer), 0, "buyer should have no debt");

        // Step 4: Record state before
        uint256 buyerVaultSharesBefore = vault.balanceOf(buyer);
        uint256 buyerCollateralBefore = midnight.collateral(marketId, buyer, 0);

        // Step 5: Create BUY offer from buyer (no debt => buyerDebt==0 branch)
        uint256 buyerAssets = 25e18;
        bytes memory callbackData = _encodeCallbackData(address(vault));
        bytes32 uniqueGroup = keccak256(abi.encodePacked("no_debt_buy", block.timestamp, gasleft()));
        Offer memory buyOffer = Offer({
            market: testMarket,
            buy: true,
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(buyOffer);
        Signature memory sig = _signOffer(buyOffer, buyerSK);

        {
            bytes32 _id = IdLib.toId(buyOffer.market);
            uint256 _takeUnits = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, buyOffer, buyerAssets);
            vm.prank(seller);
            midnight.take(
                buyOffer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _takeUnits,
                seller,
                seller,
                address(0),
                ""
            );
        }

        // Only needed shares withdrawn, remaining collateral stays on Midnight
        uint256 expectedSharesWithdrawn = vault.previewWithdraw(buyerAssets);
        uint256 buyerCollateralAfter = midnight.collateral(marketId, buyer, 0);
        assertEq(
            buyerCollateralAfter,
            buyerCollateralBefore - expectedSharesWithdrawn,
            "only needed shares should be withdrawn"
        );
        assertGt(buyerCollateralAfter, 0, "remaining collateral stays on Midnight");
    }

    /// @notice With a favorable exchange rate, fewer shares are needed. Remaining stays as collateral.
    function test_onBuy_noBuyerDebt_favorableExchangeRate() public {
        vault.setExchangeRate(2e18);

        loanToken.mint(buyer, 200e18);
        vm.startPrank(buyer);
        loanToken.approve(address(vault), 200e18);
        uint256 shares = vault.deposit(200e18, buyer); // 100 shares at 2:1
        vault.approve(address(midnight), shares);
        midnight.supplyCollateral(testMarket, 0, shares, buyer);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        (address tempBorrower, uint256 tempBorrowerSK) = makeAddrAndKey("tempBorrower2");
        loanToken.mint(seller, type(uint128).max);
        vm.prank(seller);
        loanToken.approve(address(midnight), type(uint256).max);

        loanToken.mint(tempBorrower, 2000e18);
        vm.startPrank(tempBorrower);
        loanToken.approve(address(vault), 2000e18);
        uint256 tbShares = vault.deposit(2000e18, tempBorrower);
        vault.approve(address(midnight), tbShares);
        midnight.supplyCollateral(testMarket, 0, tbShares, tempBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, tempBorrower);
        vm.stopPrank();

        Offer memory sellOffer = Offer({
            market: testMarket,
            buy: false,
            maker: tempBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: keccak256("setup_remaining_shares"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: tempBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        {
            bytes32 _id = IdLib.toId(sellOffer.market);
            uint256 _units = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, sellOffer, 50e18);
            Signature memory sig2 = _signOffer(sellOffer, tempBorrowerSK);
            bytes32 root2 = HashLib.hashOffer(sellOffer);
            vm.prank(seller);
            midnight.take(
                sellOffer,
                abi.encode(sig2, root2, uint256(0), new bytes32[](0)),
                _units,
                seller,
                address(0),
                address(0),
                ""
            );
        }

        bytes32 marketId = IdLib.toId(testMarket);
        uint256 buyerCollateralBefore = midnight.collateral(marketId, buyer, 0);

        uint256 buyerAssets = 20e18;
        bytes memory callbackData = _encodeCallbackData(address(vault));
        bytes32 uniqueGroup = keccak256(abi.encodePacked("remaining_test", block.timestamp, gasleft()));
        Offer memory buyOffer = Offer({
            market: testMarket,
            buy: true,
            maker: buyer,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(buyOffer);
        Signature memory sig = _signOffer(buyOffer, buyerSK);

        {
            bytes32 _id = IdLib.toId(buyOffer.market);
            uint256 _takeUnits = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, buyOffer, buyerAssets);
            vm.prank(seller);
            midnight.take(
                buyOffer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _takeUnits,
                seller,
                seller,
                address(0),
                ""
            );
        }

        // At 2:1 rate, 20 assets needs 10 shares. 90 shares remain as collateral.
        uint256 expectedSharesWithdrawn = vault.previewWithdraw(buyerAssets);
        uint256 buyerCollateralAfter = midnight.collateral(marketId, buyer, 0);
        assertEq(buyerCollateralAfter, buyerCollateralBefore - expectedSharesWithdrawn, "only needed shares withdrawn");
        assertGt(buyerCollateralAfter, 0, "remaining collateral stays on Midnight");
    }

    /* ========== L-01: VAULTV2 ROUNDING DUST ========== */

    /// @notice L-01: VaultV2's previewWithdraw rounds shares UP while previewRedeem rounds
    ///         assets DOWN — so redeem(previewWithdraw(x)) returns >= x, leaving dust in the
    ///         callback. The fix switches to withdraw(x) which pulls exactly x assets.
    function test_onBuy_vaultV2Rounding_noDustLeftInCallback() public {
        MockVaultV2 vaultV2 = new MockVaultV2(address(loanToken), "Vault V2", "vV2");
        MidnightWithdrawVaultSharesCallback callbackV2 = new MidnightWithdrawVaultSharesCallback(address(midnight));

        // Seed vault so totalAssets != totalSupply and rounding bites.
        address depositor = makeAddr("depositor");
        loanToken.mint(depositor, 100e18);
        vm.startPrank(depositor);
        loanToken.approve(address(vaultV2), 100e18);
        vaultV2.deposit(100e18, depositor);
        vm.stopPrank();
        loanToken.mint(address(vaultV2), 100e18);
        vaultV2.setTotalAssets(200e18);

        // Market using vaultV2 shares as collateral.
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(vaultV2), lltv: 0.77e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        Market memory midnightMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Buyer: deposit into vault, supply shares as collateral, authorize callbackV2.
        loanToken.mint(buyer, 200e18);
        vm.startPrank(buyer);
        loanToken.approve(address(vaultV2), 200e18);
        uint256 shares = vaultV2.deposit(200e18, buyer);
        vaultV2.approve(address(midnight), shares);
        midnight.supplyCollateral(midnightMarket, 0, shares, buyer);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.setIsAuthorized(address(callbackV2), true, buyer);
        vm.stopPrank();

        // Create debt for buyer via SELL offer (buyer borrows, seller lends).
        {
            Offer memory sellOffer = Offer({
                market: midnightMarket,
                buy: false,
                maker: buyer,
                start: block.timestamp,
                expiry: block.timestamp + 200,
                tick: MAX_TICK,
                group: keccak256("v2rounding_borrow"),
                callback: address(0),
                callbackData: "",
                receiverIfMakerIsSeller: buyer,
                ratifier: address(ecrecoverRatifier),
                reduceOnly: false,
                maxUnits: type(uint128).max,
                maxAssets: 0,
                continuousFeeCap: type(uint256).max
            });
            bytes32 root = HashLib.hashOffer(sellOffer);
            Signature memory sig = _signOffer(sellOffer, buyerSK);
            bytes32 id = IdLib.toId(midnightMarket);
            uint256 units = TakeAmountsLib.sellerAssetsToUnits(address(midnight), id, sellOffer, 50e18);
            vm.prank(seller);
            midnight.take(
                sellOffer,
                abi.encode(sig, root, uint256(0), new bytes32[](0)),
                units,
                seller,
                address(0),
                address(0),
                ""
            );
        }

        assertEq(loanToken.balanceOf(address(callbackV2)), 0, "callback starts empty");

        // Buyer creates BUY offer with the callbackV2.
        uint256 buyerAssets = 25e18;
        {
            bytes memory callbackData = abi.encode(
                IMidnightWithdrawVaultSharesCallback.CallbackData({vault: address(vaultV2), collateralIndex: 0})
            );
            Offer memory buyOffer = Offer({
                market: midnightMarket,
                buy: true,
                maker: buyer,
                start: block.timestamp,
                expiry: block.timestamp + 200,
                tick: MAX_TICK,
                group: keccak256("v2rounding_exit"),
                callback: address(callbackV2),
                callbackData: callbackData,
                receiverIfMakerIsSeller: address(0),
                ratifier: address(ecrecoverRatifier),
                reduceOnly: false,
                maxUnits: type(uint128).max,
                maxAssets: 0,
                continuousFeeCap: type(uint256).max
            });
            bytes32 root = HashLib.hashOffer(buyOffer);
            Signature memory sig = _signOffer(buyOffer, buyerSK);
            bytes32 id = IdLib.toId(midnightMarket);
            uint256 units = TakeAmountsLib.buyerAssetsToUnits(address(midnight), id, buyOffer, buyerAssets);
            vm.prank(seller);
            midnight.take(
                buyOffer, abi.encode(sig, root, uint256(0), new bytes32[](0)), units, seller, seller, address(0), ""
            );
        }

        // CB-DUST-1: callback must hold no token balances after onBuy.
        assertEq(loanToken.balanceOf(address(callbackV2)), 0, "no loan token dust left in callback");
        assertEq(vaultV2.balanceOf(address(callbackV2)), 0, "no vault shares left in callback");
    }
}
