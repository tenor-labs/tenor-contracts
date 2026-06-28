// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LendMidnightToVaultCallback} from "../../src/callbacks/LendMidnightToVaultCallback.sol";
import {ILendMidnightToVaultCallback} from "@callbacks/interfaces/ILendMidnightToVaultCallback.sol";
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
import {Oracle} from "../helpers/Oracle.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";

contract LendMidnightToVaultCallbackTest is Test {
    LendMidnightToVaultCallback internal callback;
    Midnight internal midnight;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC4626 internal vault;
    Oracle internal oracle;
    address internal lender; // Lender (seller) who wants to exit position
    uint256 internal lenderSK;
    address internal borrower; // Borrower who takes the lender's SELL offer
    address internal feeRecipient;
    EcrecoverRatifier internal ecrecoverRatifier;

    Market internal sourceMarket;

    function setUp() public virtual {
        (lender, lenderSK) = makeAddrAndKey("Lender");
        borrower = makeAddr("Borrower");
        feeRecipient = makeAddr("FeeRecipient");

        // Deploy real tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);

        // Deploy oracle
        oracle = new Oracle();
        oracle.setPrice(10e36); // 10:1 price

        // Deploy real Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);

        // Deploy callback contract
        callback = new LendMidnightToVaultCallback(address(midnight));

        // Deploy vault with correct asset
        vault = new MockERC4626(address(loanToken), "Vault", "vLOAN");

        // Set up collaterals
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        // Source market (current maturity, where lender has position)
        sourceMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Setup borrower with collateral to create initial borrow position
        collateralToken.mint(borrower, 10000e18);
        loanToken.mint(lender, 100000e18);
        vm.prank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Create initial lend position for lender
        // Lender creates BUY offer (to lend), borrower takes it creating debt
        _setupLenderPosition(100e18);

        // Setup borrower with loan tokens to take lender's exit offer
        loanToken.mint(borrower, 200e18);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);

        // Lender authorizes callback to act on their behalf in Midnight
        vm.prank(lender);
        midnight.setIsAuthorized(address(callback), true, lender);
    }

    /* ========== HELPERS ========== */

    /// @dev Setup initial lend position for lender
    function _setupLenderPosition(uint256 amount) internal {
        // First, supply collateral for borrower
        vm.prank(borrower);
        midnight.supplyCollateral(sourceMarket, 0, 1000e18, borrower);

        // Lender creates BUY offer (wants to lend)
        bytes32 setupGroup = keccak256(abi.encodePacked("setup", block.timestamp));
        Offer memory buyOffer = Offer({
            market: sourceMarket,
            buy: true, // BUY offer (lender wants to buy market units = lend)
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: setupGroup,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(buyOffer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(buyOffer);

        // Borrower takes the BUY offer (creates debt)
        bytes32 _id = IdLib.toId(buyOffer.market);
        uint256 _units = amount;
        vm.prank(borrower);
        midnight.take(
            buyOffer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _units,
            borrower,
            buyOffer.maker,
            address(0),
            ""
        );
    }

    /// @dev Helper to sign an offer
    function _signOffer(Offer memory offer, uint256 privateKey) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(privateKey, digest);
        return signature;
    }

    /// @dev Helper to encode CallbackData
    function _encodeCallbackData(address vaultAddr, uint256 feeRate, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            ILendMidnightToVaultCallback.CallbackData({vault: vaultAddr, feeRate: feeRate, feeRecipient: recipient})
        );
    }

    /// @dev Result struct for take operations
    struct TakeResult {
        uint256 buyerAssets;
        uint256 sellerAssets;
        uint256 units;
    }

    /// @dev Prepare a SELL offer (computes shares via external calls) without executing the take.
    ///      This allows placing vm.expectRevert() between preparation and execution.
    function _prepareOffer(uint256 sellerAssets, bytes memory callbackData, address _taker)
        internal
        view
        returns (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units)
    {
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, gasleft()));

        offer = Offer({
            market: sourceMarket,
            buy: false, // SELL offer (lender selling their lending position)
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING), // Price at 0.99 means ~1% interest
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

        offerRoot = HashLib.hashOffer(offer);
        sig = _signOffer(offer, lenderSK);

        bytes32 _id = IdLib.toId(offer.market);
        _units = sellerAssets;
    }

    /// @dev Helper to create and execute a SELL offer for lend exit
    /// @param sellerAssets Amount of loan tokens lender will receive
    /// @param callbackData Encoded CallbackData
    /// @param taker Address of the borrower who provides loan tokens
    function _takeOffer(uint256 sellerAssets, bytes memory callbackData, address taker)
        internal
        returns (TakeResult memory result)
    {
        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, sellerAssets, gasleft()));

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false, // SELL offer (lender selling their lending position)
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING), // Price at 0.99 means ~1% interest
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
        Signature memory sig = _signOffer(offer, lenderSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _takeShares = sellerAssets;
        vm.prank(taker);
        (result.buyerAssets, result.sellerAssets) = midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _takeShares,
            taker,
            address(0),
            address(0),
            ""
        );
    }

    /// @dev Helper to calculate expected fee (fee = sellerAssets * feeRate / WAD)
    function _calculateExpectedFee(uint256 sellerAssets, uint256 feeRate) internal pure returns (uint256) {
        if (feeRate == 0) return 0;
        return (sellerAssets * feeRate) / WAD;
    }

    /* ========== CONSTRUCTOR ========== */

    function test_constructor_setsMidnight() public view {
        assertEq(address(callback.MORPHO_MIDNIGHT()), address(midnight));
    }

    /* ========== onSell - AUTHORIZATION ========== */

    function test_onSell_revertsWhenNotCalledByMidnight() public {
        bytes memory data = _encodeCallbackData(address(vault), 0, address(0));

        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onSell(bytes32(0), sourceMarket, 100e18, 105e18, 0, lender, address(callback), data);
    }

    function test_onSell_revertsWhenReceiverIsNotCallback() public {
        bytes memory data = _encodeCallbackData(address(vault), 0, address(0));

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.InvalidReceiver.selector);
        callback.onSell(bytes32(0), sourceMarket, 100e18, 105e18, 0, lender, lender, data);
    }

    /* ========== onSell - VALIDATION ========== */

    function test_onSell_revertsWhenSellerAssetsIsZero() public {
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        bytes32 uniqueGroup = keccak256(abi.encodePacked("zero_test", block.timestamp));
        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
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
        Signature memory sig = _signOffer(offer, lenderSK);

        vm.prank(borrower);
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), 0, borrower, address(0), address(0), ""
        );
    }

    function test_onSell_revertsWhenUnitsIsZero() public {
        bytes memory data = _encodeCallbackData(address(vault), 0, address(0));

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        callback.onSell(bytes32(0), sourceMarket, 100e18, 0, 0, lender, address(callback), data);
    }

    function test_onSell_revertsWhenVaultAssetMismatch() public {
        // Create vault with different asset
        MockERC20 differentToken = new MockERC20("Different", "DIFF", 18);
        MockERC4626 wrongVault = new MockERC4626(address(differentToken), "Wrong Vault", "wVAULT");

        bytes memory callbackData = _encodeCallbackData(address(wrongVault), 0, address(0));

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareOffer(50e18, callbackData, borrower);
        vm.prank(borrower);
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _units,
            borrower,
            address(0),
            address(0),
            ""
        );
    }

    function test_onSell_revertsInvalidFeeConfig_feeRateTooHigh() public {
        // Fee rate exceeds WAD (CallbackLib limit)
        bytes memory callbackData = _encodeCallbackData(address(vault), 0.02e18, feeRecipient);

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareOffer(50e18, callbackData, borrower);
        vm.prank(borrower);
        vm.expectRevert(CallbackLib.InvalidFeeConfig.selector);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _units,
            borrower,
            address(0),
            address(0),
            ""
        );
    }

    /* ========== onSell - FEE CALCULATION ========== */

    function test_onSell_zeroFeeRate() public {
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        TakeResult memory result = _takeOffer(50e18, callbackData, borrower);

        // Fee recipient should receive nothing
        assertEq(loanToken.balanceOf(feeRecipient), feeRecipientBalanceBefore, "Fee recipient should receive 0");

        // Vault should receive all sellerAssets
        assertEq(
            loanToken.balanceOf(address(vault)),
            vaultBalanceBefore + result.sellerAssets,
            "Vault should receive all sellerAssets"
        );
    }

    function test_onSell_feeCalculationWith1PercentRate() public {
        uint256 feeRate = 0.01e18;
        bytes memory callbackData = _encodeCallbackData(address(vault), feeRate, feeRecipient);

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        TakeResult memory result = _takeOffer(50e18, callbackData, borrower);

        uint256 expectedFee = _calculateExpectedFee(result.sellerAssets, feeRate);

        assertEq(
            loanToken.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + expectedFee,
            "Fee recipient should receive calculated fee"
        );
    }

    function test_onSell_feeCalculationWithMaxRate() public {
        uint256 feeRate = 0.01e18; // Maximum fee rate (1%)
        bytes memory callbackData = _encodeCallbackData(address(vault), feeRate, feeRecipient);

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        TakeResult memory result = _takeOffer(50e18, callbackData, borrower);

        uint256 expectedFee = _calculateExpectedFee(result.sellerAssets, feeRate);

        assertEq(
            loanToken.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + expectedFee,
            "Fee recipient should receive 1% of sellerAssets"
        );
    }

    function test_onSell_feeCalculationRoundsDown() public {
        uint256 feeRate = 0.005e18; // 0.5% fee rate
        bytes memory callbackData = _encodeCallbackData(address(vault), feeRate, feeRecipient);

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        // Use non-round amount for rounding test
        bytes32 uniqueGroup = keccak256(abi.encodePacked("rounding_test", block.timestamp));
        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
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
        Signature memory sig = _signOffer(offer, lenderSK);

        {
            bytes32 _id = IdLib.toId(offer.market);
            uint256 _units = TakeAmountsLib.sellerAssetsToUnits(address(midnight), _id, offer, 33e18);
            vm.prank(borrower);
            midnight.take(
                offer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _units,
                borrower,
                address(0),
                address(0),
                ""
            );
        }

        // Calculate expected fee: sellerAssets * feeRate / WAD
        uint256 sellerAssets = 33e18;
        uint256 expectedFee = (sellerAssets * feeRate) / WAD;

        assertEq(
            loanToken.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + expectedFee,
            "Fee should match mulDivDown calculation"
        );

        // Fee should be 0.5% of 33e18 = 0.165e18
        assertEq(expectedFee, 0.165e18, "Fee should be 0.5% of sellerAssets");
    }

    /* ========== onSell - VAULT DEPOSIT ========== */

    function test_onSell_depositsIntoVault() public {
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        uint256 lenderSharesBefore = vault.balanceOf(lender);
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        TakeResult memory result = _takeOffer(50e18, callbackData, borrower);

        // Vault should receive assets
        assertEq(
            loanToken.balanceOf(address(vault)),
            vaultBalanceBefore + result.sellerAssets,
            "Vault should receive sellerAssets"
        );

        // Lender should receive shares
        uint256 expectedShares = vault.convertToShares(result.sellerAssets);
        assertEq(vault.balanceOf(lender), lenderSharesBefore + expectedShares, "Lender should receive vault shares");
    }

    function test_onSell_depositsCorrectAmountAfterFee() public {
        uint256 feeRate = 0.01e18; // 1% (max fee rate)
        bytes memory callbackData = _encodeCallbackData(address(vault), feeRate, feeRecipient);

        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        TakeResult memory result = _takeOffer(50e18, callbackData, borrower);

        uint256 expectedFee = _calculateExpectedFee(result.sellerAssets, feeRate);
        uint256 expectedDeposit = result.sellerAssets - expectedFee;

        assertEq(
            loanToken.balanceOf(address(vault)),
            vaultBalanceBefore + expectedDeposit,
            "Vault should receive sellerAssets - fee"
        );
    }

    function test_onSell_lenderReceivesVaultShares() public {
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        uint256 lenderSharesBefore = vault.balanceOf(lender);

        TakeResult memory result = _takeOffer(50e18, callbackData, borrower);

        uint256 expectedShares = vault.convertToShares(result.sellerAssets);
        assertEq(vault.balanceOf(lender), lenderSharesBefore + expectedShares, "Lender should receive correct shares");
    }

    function test_onSell_vaultWithYield() public {
        // Set vault exchange rate to 1.1 (10% yield)
        vault.setExchangeRate(1.1e18);

        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        uint256 lenderSharesBefore = vault.balanceOf(lender);

        TakeResult memory result = _takeOffer(50e18, callbackData, borrower);

        // With 1.1 exchange rate, shares = assets * 1e18 / 1.1e18
        uint256 expectedShares = (result.sellerAssets * 1e18) / 1.1e18;
        assertEq(
            vault.balanceOf(lender), lenderSharesBefore + expectedShares, "Shares should account for exchange rate"
        );
    }

    function test_onSell_partialFill() public {
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        bytes32 marketId = IdLib.toId(sourceMarket);
        uint256 lenderSharesBefore = creditAfterSlashing(midnight, marketId, lender);

        // Take partial fill (25e18 out of 100e18 shares)
        TakeResult memory result = _takeOffer(25e18, callbackData, borrower);

        uint256 lenderSharesAfter = creditAfterSlashing(midnight, marketId, lender);

        // Lender's shares should decrease
        assertTrue(lenderSharesAfter < lenderSharesBefore, "Lender shares should decrease");

        // Lender should have vault shares
        assertTrue(vault.balanceOf(lender) > 0, "Lender should have vault shares");
    }

    /* ========== onSell - EVENT EMISSION ========== */

    function test_onSell_emitsVaultDepositedEvent() public {
        uint256 feeRate = 0.01e18;
        bytes memory callbackData = _encodeCallbackData(address(vault), feeRate, feeRecipient);

        bytes32 marketId = IdLib.toId(sourceMarket);

        // We can't predict exact values, but verify event is emitted
        vm.expectEmit(true, true, true, false, address(callback));
        emit ILendMidnightToVaultCallback.VaultDeposited(lender, marketId, address(vault), 0, 0, 0);

        _takeOffer(50e18, callbackData, borrower);
    }

    /* ========== POSITION CROSSING GUARD ========== */

    function test_onSell_revertsPositionCrossing() public {
        // Lender has 100e18 credit from setUp. Selling 150e18 would flip them to 50e18 debt.
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        (Offer memory offer, Signature memory sig, bytes32 offerRoot,) = _prepareOffer(150e18, callbackData, borrower);

        vm.prank(borrower);
        vm.expectRevert(CallbackLib.PositionCrossing.selector);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            150e18,
            borrower,
            address(0),
            address(0),
            ""
        );
    }

    /* ========== EDGE CASES ========== */

    function test_onSell_minimumAmounts() public {
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        // Very small amount
        TakeResult memory result = _takeOffer(1e6, callbackData, borrower);

        assertTrue(vault.balanceOf(lender) > 0, "Lender should receive shares even for small amounts");
    }

    /* ========== RECEIVER = CALLBACK (Option A) ========== */

    function test_onSell_receiverIsCallback_depositsIntoVault() public {
        // Option A: receiverIfMakerIsSeller = callback contract, no transferFrom needed
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));
        uint256 lenderSharesBefore = vault.balanceOf(lender);

        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, uint256(50e18), "optionA"));
        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: uniqueGroup,
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback), // Tokens go directly to callback
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, lenderSK);

        vm.prank(borrower);
        (uint256 buyerAssets, uint256 sellerAssets) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), 50e18, borrower, address(0), address(0), ""
        );

        // Vault should receive all sellerAssets
        assertEq(
            loanToken.balanceOf(address(vault)), vaultBalanceBefore + sellerAssets, "Vault should receive sellerAssets"
        );

        // Lender should receive vault shares
        assertTrue(vault.balanceOf(lender) > lenderSharesBefore, "Lender should receive vault shares");

        // Callback contract should retain no tokens
        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback should retain no tokens");
    }

    function test_onSell_receiverIsCallback_withFee() public {
        uint256 feeRate = 0.01e18;
        bytes memory callbackData = _encodeCallbackData(address(vault), feeRate, feeRecipient);

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        bytes32 uniqueGroup = keccak256(abi.encodePacked(block.timestamp, uint256(50e18), "optionAFee"));
        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
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
        Signature memory sig = _signOffer(offer, lenderSK);

        vm.prank(borrower);
        (uint256 buyerAssets, uint256 sellerAssets) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), 50e18, borrower, address(0), address(0), ""
        );

        uint256 expectedFee = _calculateExpectedFee(sellerAssets, feeRate);
        uint256 expectedDeposit = sellerAssets - expectedFee;

        assertEq(
            loanToken.balanceOf(feeRecipient),
            feeRecipientBalanceBefore + expectedFee,
            "Fee recipient should receive fee"
        );
        assertEq(
            loanToken.balanceOf(address(vault)),
            vaultBalanceBefore + expectedDeposit,
            "Vault should receive sellerAssets - fee"
        );
        assertEq(loanToken.balanceOf(address(callback)), 0, "Callback should retain no tokens");
    }

    function test_onSell_largeAmounts() public {
        // Setup larger position - use a different approach to avoid offer group collision
        loanToken.mint(lender, 1000000e18);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        loanToken.mint(borrower, 1000000e18);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);

        // Mint more collateral for borrower
        collateralToken.mint(borrower, 1000000e18);

        // Supply more collateral
        vm.prank(borrower);
        midnight.supplyCollateral(sourceMarket, 0, 100000e18, borrower);

        // Create a new large lend position using a unique group
        bytes32 largeSetupGroup = keccak256(abi.encodePacked("large_setup", block.timestamp, block.number));
        Offer memory largeBuyOffer = Offer({
            market: sourceMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: largeSetupGroup,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(largeBuyOffer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(largeBuyOffer);

        {
            bytes32 _id = IdLib.toId(largeBuyOffer.market);
            uint256 _units = 10000e18;
            vm.prank(borrower);
            midnight.take(
                largeBuyOffer,
                abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
                _units,
                borrower,
                largeBuyOffer.maker,
                address(0),
                ""
            );
        }

        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        TakeResult memory result = _takeOffer(5000e18, callbackData, borrower);

        uint256 expectedShares = vault.convertToShares(result.sellerAssets);
        assertTrue(vault.balanceOf(lender) >= expectedShares, "Lender should receive shares for large amounts");
    }
}
