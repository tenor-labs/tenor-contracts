// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LendMidnightToVaultCallback} from "../../src/callbacks/LendMidnightToVaultCallback.sol";
import {ILendMidnightToVaultCallback} from "@callbacks/interfaces/ILendMidnightToVaultCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
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
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";

/// @notice Integration tests for LendMidnightToVaultCallback with real Midnight contracts
/// @dev Tests the full lender exit flow: lender has position → creates SELL offer → borrower takes →
///      callback pulls tokens, takes fee, deposits to vault
contract LendMidnightToVaultCallbackIntegrationTest is Test {
    LendMidnightToVaultCallback internal callback;
    IMidnight internal midnight;
    MockERC4626 internal vault;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    uint256 internal LENDER_SK;
    address internal LENDER;
    uint256 internal BORROWER_SK;
    address internal BORROWER;
    address internal FEE_RECIPIENT;
    EcrecoverRatifier internal ecrecoverRatifier;

    uint256 constant INITIAL_BALANCE = 100_000e18;
    uint256 constant LEND_AMOUNT = 1000e18;
    uint256 constant COLLATERAL_AMOUNT = 5000e18;

    function setUp() public {
        // Create test accounts
        (LENDER, LENDER_SK) = makeAddrAndKey("lender");
        (BORROWER, BORROWER_SK) = makeAddrAndKey("borrower");
        FEE_RECIPIENT = makeAddr("feeRecipient");

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
        callback = new LendMidnightToVaultCallback(address(midnight));

        // Mint tokens
        loanToken.mint(LENDER, INITIAL_BALANCE);
        loanToken.mint(BORROWER, INITIAL_BALANCE);
        collateralToken.mint(BORROWER, INITIAL_BALANCE);

        // Lender approvals
        vm.startPrank(LENDER);
        loanToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Borrower approvals
        vm.startPrank(BORROWER);
        loanToken.approve(address(midnight), type(uint256).max);
        collateralToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        // Lender authorizes callback to act on their behalf in Midnight
        vm.prank(LENDER);
        Midnight(address(midnight)).setIsAuthorized(address(callback), true, LENDER);
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

    function _encodeCallbackData(address vaultAddr, uint256 feeRate, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            ILendMidnightToVaultCallback.CallbackData({vault: vaultAddr, feeRate: feeRate, feeRecipient: recipient})
        );
    }

    /// @dev Setup a lending position for lender by having borrower take a BUY offer
    function _setupLenderPosition(Market memory market, uint256 amount) internal {
        bytes32 marketId = _toId(market);

        // Borrower supplies collateral
        vm.prank(BORROWER);
        midnight.supplyCollateral(market, 0, COLLATERAL_AMOUNT, BORROWER);

        // Lender creates BUY offer (wants to lend)
        Offer memory buyOffer = Offer({
            buy: true,
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK, // 1:1 for setup
            group: keccak256(abi.encodePacked("setup", block.timestamp)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(buyOffer, LENDER_SK);
        bytes32 root = HashLib.hashOffer(buyOffer);

        // Borrower takes the BUY offer (creates debt, lender gets shares)
        bytes32 _id = IdLib.toId(buyOffer.market);
        uint256 _shares = amount;
        vm.prank(BORROWER);
        midnight.take(
            buyOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            _shares,
            BORROWER,
            buyOffer.maker,
            address(0),
            ""
        );

        // Verify setup
        assertGt(creditAfterSlashing(midnight, marketId, LENDER), 0, "Lender should have shares");
        assertEq(midnight.debt(marketId, BORROWER), amount, "Borrower should have debt");
    }

    /* ========== FULL LENDER EXIT FLOW TEST ========== */

    function test_fullLenderExitFlow() public {
        // === Setup ===
        Market memory market = _createMarket();
        bytes32 marketId = _toId(market);
        uint256 exitPrice = 0.95e18; // Lender sells at 5% discount (borrower pays 0.95 per unit)
        uint256 feeRate = 0.01e18; // 1% fee on interest

        // Setup lender position
        _setupLenderPosition(market, LEND_AMOUNT);

        uint256 lenderSharesBefore = creditAfterSlashing(midnight, marketId, LENDER);
        uint256 borrowerDebtBefore = midnight.debt(marketId, BORROWER);
        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(FEE_RECIPIENT);
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        // === Lender creates SELL offer to exit position ===
        bytes memory callbackData = _encodeCallbackData(address(vault), feeRate, FEE_RECIPIENT);

        Offer memory sellOffer = Offer({
            buy: false, // SELL offer (lender exits)
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(exitPrice, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("exit", block.timestamp)),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, LENDER_SK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        // === Borrower takes the SELL offer (buys back their debt) ===
        bytes32 _id = IdLib.toId(sellOffer.market);
        uint256 _shares = LEND_AMOUNT;
        vm.prank(BORROWER);
        (uint256 buyerAssets, uint256 sellerAssets) = midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            _shares,
            BORROWER,
            address(0),
            address(0),
            ""
        );

        // === Calculate expected values ===
        // Midnight converts the tick back to a price via TickLib.tickToPrice, which may differ from the raw exitPrice.
        uint256 effectivePrice = TickLib.tickToPrice(TickLib.priceToTick(exitPrice, DEFAULT_TICK_SPACING));
        // The offer has no internal sub-clamping so matched units equal the take request
        // (_shares == LEND_AMOUNT).
        uint256 expectedSellerAssets = (LEND_AMOUNT * effectivePrice) / WAD;
        assertEq(sellerAssets, expectedSellerAssets, "SellerAssets should match formula");

        // buyerAssets = units * buyerPrice / WAD (no settlement fee configured)
        uint256 expectedBuyerAssets = (_shares * effectivePrice) / WAD;
        assertEq(buyerAssets, expectedBuyerAssets, "BuyerAssets should match formula");

        // Fee calculation: fee = sellerAssets * feeRate / WAD
        uint256 expectedFee = (sellerAssets * feeRate) / WAD;

        // === Verify lender exit effects ===

        // Lender's shares should decrease
        uint256 lenderSharesAfter = creditAfterSlashing(midnight, marketId, LENDER);
        assertLt(lenderSharesAfter, lenderSharesBefore, "Lender shares should decrease");

        // Borrower's debt should decrease (they bought back their own debt)
        uint256 borrowerDebtAfter = midnight.debt(marketId, BORROWER);
        assertLt(borrowerDebtAfter, borrowerDebtBefore, "Borrower debt should decrease");

        // Fee recipient should receive the fee
        uint256 feeRecipientBalanceAfter = loanToken.balanceOf(FEE_RECIPIENT);
        assertEq(feeRecipientBalanceAfter - feeRecipientBalanceBefore, expectedFee, "Fee should match calculation");

        // Vault should receive deposit (sellerAssets - fee)
        uint256 expectedDeposit = sellerAssets - expectedFee;
        uint256 vaultBalanceAfter = loanToken.balanceOf(address(vault));
        assertEq(vaultBalanceAfter - vaultBalanceBefore, expectedDeposit, "Vault should receive correct deposit");

        // Lender should have vault shares
        uint256 lenderVaultShares = vault.balanceOf(LENDER);
        uint256 expectedVaultShares = vault.convertToShares(expectedDeposit);
        assertEq(lenderVaultShares, expectedVaultShares, "Lender should have correct vault shares");
    }

    /* ========== PARTIAL FILL TEST ========== */

    function test_partialFill() public {
        Market memory market = _createMarket();
        bytes32 marketId = _toId(market);
        uint256 exitPrice = 0.95e18;

        // Setup larger position
        _setupLenderPosition(market, LEND_AMOUNT);

        uint256 lenderSharesBefore = creditAfterSlashing(midnight, marketId, LENDER);

        // Create SELL offer for full amount but take partially
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        Offer memory sellOffer = Offer({
            buy: false,
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(exitPrice, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("partial_exit", block.timestamp)),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, LENDER_SK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        // First partial fill: 400 tokens
        uint256 partialAmount = 400e18;
        bytes32 _id = IdLib.toId(sellOffer.market);
        uint256 _shares1 = partialAmount;
        vm.prank(BORROWER);
        (, uint256 sellerAssets1) = midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            _shares1,
            BORROWER,
            address(0),
            address(0),
            ""
        );

        uint256 lenderSharesAfterFirst = creditAfterSlashing(midnight, marketId, LENDER);
        uint256 lenderVaultSharesAfterFirst = vault.balanceOf(LENDER);
        assertLt(lenderSharesAfterFirst, lenderSharesBefore, "Shares should decrease after first fill");
        assertEq(lenderVaultSharesAfterFirst, sellerAssets1, "Vault shares should equal first deposit");

        // Second partial fill: 400 more tokens
        uint256 _shares2 = partialAmount;
        vm.prank(BORROWER);
        (, uint256 sellerAssets2) = midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            _shares2,
            BORROWER,
            address(0),
            address(0),
            ""
        );

        uint256 lenderSharesAfterSecond = creditAfterSlashing(midnight, marketId, LENDER);
        uint256 lenderVaultSharesAfterSecond = vault.balanceOf(LENDER);
        assertLt(lenderSharesAfterSecond, lenderSharesAfterFirst, "Shares should decrease after second fill");
        assertEq(
            lenderVaultSharesAfterSecond, sellerAssets1 + sellerAssets2, "Vault shares should equal cumulative deposits"
        );

        // Third partial fill: remaining 200 tokens
        uint256 remaining = 200e18;
        uint256 _shares3 = remaining;
        vm.prank(BORROWER);
        (, uint256 sellerAssets3) = midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            _shares3,
            BORROWER,
            address(0),
            address(0),
            ""
        );

        // Verify cumulative state
        uint256 lenderVaultSharesFinal = vault.balanceOf(LENDER);
        assertEq(
            lenderVaultSharesFinal,
            sellerAssets1 + sellerAssets2 + sellerAssets3,
            "Final vault shares should equal total deposits"
        );
    }

    /* ========== VAULT WITH YIELD TEST ========== */

    function test_vaultWithYield() public {
        Market memory market = _createMarket();
        uint256 exitPrice = 0.95e18;

        // Setup lender position
        _setupLenderPosition(market, LEND_AMOUNT);

        // Simulate vault yield: 10% appreciation
        vault.setExchangeRate(1.1e18);

        // Create SELL offer
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        Offer memory sellOffer = Offer({
            buy: false,
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(exitPrice, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("yield_exit", block.timestamp)),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, LENDER_SK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        // Take the offer
        bytes32 _id = IdLib.toId(sellOffer.market);
        uint256 _shares = LEND_AMOUNT;
        vm.prank(BORROWER);
        (, uint256 sellerAssets) = midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            _shares,
            BORROWER,
            address(0),
            address(0),
            ""
        );

        // With 1.1 exchange rate, shares = assets / 1.1
        // So depositing assets gets fewer shares
        uint256 lenderVaultShares = vault.balanceOf(LENDER);
        uint256 expectedShares = (sellerAssets * WAD) / 1.1e18;
        assertEq(lenderVaultShares, expectedShares, "Shares should account for vault yield");

        // The underlying value may have minor rounding differences due to integer division
        uint256 redeemableAssets = vault.convertToAssets(lenderVaultShares);
        assertApproxEqAbs(redeemableAssets, sellerAssets, 1, "Redeemable assets should approximately equal deposited");
    }

    /* ========== ZERO FEE TEST ========== */

    function test_zeroFee() public {
        Market memory market = _createMarket();
        uint256 exitPrice = 0.95e18;

        _setupLenderPosition(market, LEND_AMOUNT);

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(FEE_RECIPIENT);
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        // Zero fee configuration
        bytes memory callbackData = _encodeCallbackData(address(vault), 0, address(0));

        Offer memory sellOffer = Offer({
            buy: false,
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(exitPrice, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("zero_fee_exit", block.timestamp)),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, LENDER_SK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        bytes32 _id = IdLib.toId(sellOffer.market);
        uint256 _shares = LEND_AMOUNT;
        vm.prank(BORROWER);
        (, uint256 sellerAssets) = midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            _shares,
            BORROWER,
            address(0),
            address(0),
            ""
        );

        // Fee recipient should receive nothing
        assertEq(loanToken.balanceOf(FEE_RECIPIENT), feeRecipientBalanceBefore, "Fee recipient should receive nothing");

        // All assets should go to vault
        assertEq(
            loanToken.balanceOf(address(vault)), vaultBalanceBefore + sellerAssets, "Vault should receive all assets"
        );
    }

    /* ========== MAX FEE RATE TEST ========== */

    function test_maxFeeRate() public {
        Market memory market = _createMarket();
        uint256 exitPrice = 0.95e18;
        uint256 feeRate = 0.01e18; // 1% max fee rate

        _setupLenderPosition(market, LEND_AMOUNT);

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(FEE_RECIPIENT);

        bytes memory callbackData = _encodeCallbackData(address(vault), feeRate, FEE_RECIPIENT);

        Offer memory sellOffer = Offer({
            buy: false,
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(exitPrice, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("max_fee_exit", block.timestamp)),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, LENDER_SK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        bytes32 _id = IdLib.toId(sellOffer.market);
        uint256 _shares = LEND_AMOUNT;
        vm.prank(BORROWER);
        (, uint256 sellerAssets) = midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            _shares,
            BORROWER,
            address(0),
            address(0),
            ""
        );

        // Calculate expected 1% fee on sellerAssets
        uint256 expectedFee = (sellerAssets * feeRate) / WAD;

        assertEq(
            loanToken.balanceOf(FEE_RECIPIENT) - feeRecipientBalanceBefore,
            expectedFee,
            "Fee should be 1% of sellerAssets"
        );
    }

    /* ========== MULTIPLE LENDERS TEST ========== */

    function test_multipleLenders() public {
        // Create second lender
        (address LENDER2, uint256 LENDER2_SK) = makeAddrAndKey("lender2");
        loanToken.mint(LENDER2, INITIAL_BALANCE);
        collateralToken.mint(BORROWER, INITIAL_BALANCE); // More collateral for second position

        vm.startPrank(LENDER2);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, LENDER2);
        vm.stopPrank();

        Market memory market = _createMarket();
        uint256 exitPrice = 0.95e18;

        // Setup positions for both lenders
        _setupLenderPosition(market, LEND_AMOUNT);

        // Setup second lender's position
        vm.prank(BORROWER);
        midnight.supplyCollateral(market, 0, COLLATERAL_AMOUNT, BORROWER);

        Offer memory buyOffer2 = Offer({
            buy: true,
            maker: LENDER2,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup2", block.timestamp)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig2 = _signOffer(buyOffer2, LENDER2_SK);
        bytes32 root2 = HashLib.hashOffer(buyOffer2);

        bytes32 _setupId = IdLib.toId(buyOffer2.market);
        uint256 _setupShares = 500e18;
        vm.prank(BORROWER);
        midnight.take(
            buyOffer2,
            abi.encode(sig2, root2, uint256(0), new bytes32[](0)),
            _setupShares,
            BORROWER,
            buyOffer2.maker,
            address(0),
            ""
        );

        // Both lenders exit
        bytes memory callbackData1 = _encodeCallbackData(address(vault), 0, address(0));
        bytes memory callbackData2 = _encodeCallbackData(address(vault), 0, address(0));

        // Lender 1 exits
        Offer memory sellOffer1 = Offer({
            buy: false,
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(exitPrice, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("exit1", block.timestamp)),
            callback: address(callback),
            callbackData: callbackData1,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sigExit1 = _signOffer(sellOffer1, LENDER_SK);
        bytes32 rootExit1 = HashLib.hashOffer(sellOffer1);

        bytes32 _exitId1 = IdLib.toId(sellOffer1.market);
        uint256 _exitShares1 = 500e18;
        vm.prank(BORROWER);
        midnight.take(
            sellOffer1,
            abi.encode(sigExit1, rootExit1, uint256(0), new bytes32[](0)),
            _exitShares1,
            BORROWER,
            address(0),
            address(0),
            ""
        );

        // Lender 2 exits
        Offer memory sellOffer2 = Offer({
            buy: false,
            maker: LENDER2,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(exitPrice, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("exit2", block.timestamp)),
            callback: address(callback),
            callbackData: callbackData2,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sigExit2 = _signOffer(sellOffer2, LENDER2_SK);
        bytes32 rootExit2 = HashLib.hashOffer(sellOffer2);

        bytes32 _exitId2 = IdLib.toId(sellOffer2.market);
        uint256 _exitShares2 = 500e18;
        vm.prank(BORROWER);
        midnight.take(
            sellOffer2,
            abi.encode(sigExit2, rootExit2, uint256(0), new bytes32[](0)),
            _exitShares2,
            BORROWER,
            address(0),
            address(0),
            ""
        );

        // Both lenders should have vault shares
        assertGt(vault.balanceOf(LENDER), 0, "Lender 1 should have vault shares");
        assertGt(vault.balanceOf(LENDER2), 0, "Lender 2 should have vault shares");
    }

    /* ========== ERROR CASE: ASSET MISMATCH ========== */

    function test_revert_assetMismatch() public {
        Market memory market = _createMarket();
        uint256 exitPrice = 0.95e18;

        _setupLenderPosition(market, LEND_AMOUNT);

        // Create vault with wrong asset
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);
        MockERC4626 wrongVault = new MockERC4626(address(wrongToken), "Wrong Vault", "vWRONG");

        bytes memory callbackData = _encodeCallbackData(address(wrongVault), 0, address(0));

        Offer memory sellOffer = Offer({
            buy: false,
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(exitPrice, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("wrong_vault", block.timestamp)),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, LENDER_SK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        bytes32 _id = IdLib.toId(sellOffer.market);
        uint256 _shares = LEND_AMOUNT;
        vm.prank(BORROWER);
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            _shares,
            BORROWER,
            address(0),
            address(0),
            ""
        );
    }

    /* ========== ERROR CASE: INVALID FEE CONFIG ========== */

    function test_revert_feeRateTooHigh() public {
        Market memory market = _createMarket();
        uint256 exitPrice = 0.95e18;

        _setupLenderPosition(market, LEND_AMOUNT);

        // Fee rate > 1%
        bytes memory callbackData = _encodeCallbackData(address(vault), 0.02e18, FEE_RECIPIENT);

        Offer memory sellOffer = Offer({
            buy: false,
            maker: LENDER,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: TickLib.priceToTick(exitPrice, DEFAULT_TICK_SPACING),
            group: keccak256(abi.encodePacked("high_fee", block.timestamp)),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, LENDER_SK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        bytes32 _id = IdLib.toId(sellOffer.market);
        uint256 _shares = LEND_AMOUNT;
        vm.prank(BORROWER);
        vm.expectRevert(CallbackLib.InvalidFeeConfig.selector);
        midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            _shares,
            BORROWER,
            address(0),
            address(0),
            ""
        );
    }
}
