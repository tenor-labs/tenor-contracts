// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LendMidnightRenewalCallback} from "../../src/callbacks/LendMidnightRenewalCallback.sol";
import {ILendMidnightRenewalCallback} from "@callbacks/interfaces/ILendMidnightRenewalCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

contract LendMidnightRenewalCallbackTest is Test {
    LendMidnightRenewalCallback internal callback;
    Midnight internal midnight;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    address internal lender; // Lender (buyer) who owns credit on source and wants to roll
    uint256 internal lenderSK;
    address internal borrower; // Borrower (seller/taker) who takes the lender's BUY offer on target
    address internal feeRecipient;
    EcrecoverRatifier internal ecrecoverRatifier;

    Market internal sourceMarket;
    Market internal targetMarket;

    uint256 internal offerTick; // ~0.99 price => ~1% discount (set in setUp via priceToTick)
    uint256 internal constant LENDER_CREDIT = 200e18;

    function setUp() public virtual {
        (lender, lenderSK) = makeAddrAndKey("Lender");
        borrower = makeAddr("Borrower");
        feeRecipient = makeAddr("FeeRecipient");

        // Deploy tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COL", 18);

        // Deploy oracle (10:1 so collateral is worth more than loan token)
        oracle = new Oracle();
        oracle.setPrice(10e36);

        // Deploy real Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);

        // Deploy callback
        callback = new LendMidnightRenewalCallback(address(midnight));

        // Compute tick for ~0.99 price (~1% discount = ~1% interest)
        offerTick = TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING);

        // Setup collaterals array (shared between source and target)
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        // Source market (lender has credit here)
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

        // Target market (lender wants to lend here)
        targetMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Setup lender with credit and withdrawable balance on source market
        _setupLenderWithCredit(LENDER_CREDIT);

        // Lender authorizes callback on Midnight
        vm.prank(lender);
        midnight.setIsAuthorized(address(callback), true, lender);

        // Lender approves Midnight for loan tokens (Midnight pulls buyerAssets after onBuy)
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Setup borrower with collateral for the target market
        // (borrower will be the seller/taker, needs to pass health check)
        collateralToken.mint(borrower, 10000e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(targetMarket, 0, 10000e18, borrower);
        vm.stopPrank();
    }

    /* ========== HELPERS ========== */

    /// @dev Sets up lender with credit + withdrawable balance on source market.
    ///      Steps: lender takes BUY offer -> temp borrower gets debt -> temp borrower repays -> withdrawable created.
    function _setupLenderWithCredit(uint256 creditAmount) internal {
        // 1. Lender needs loan tokens to take a BUY offer (Midnight pulls from buyer)
        loanToken.mint(lender, creditAmount);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        // 2. Temp borrower needs collateral to pass health check after take
        address tempBorrower = makeAddr("TempBorrower");
        collateralToken.mint(tempBorrower, 10000e18);
        vm.startPrank(tempBorrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(sourceMarket, 0, 10000e18, tempBorrower);
        vm.stopPrank();

        // 3. Lender creates a BUY offer on source market (wants to lend)
        //    Use tick=MAX_TICK (price=1.0) for setup so creditAmount maps cleanly to units
        Offer memory buyOffer = Offer({
            market: sourceMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("setup-lender-credit"),
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

        // 4. Temp borrower takes the offer (becomes seller, gets loan tokens, incurs debt)
        vm.prank(tempBorrower);
        midnight.take(
            buyOffer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            creditAmount,
            tempBorrower,
            tempBorrower,
            address(0),
            ""
        );

        // 5. Temp borrower repays debt to create withdrawable balance
        bytes32 sourceId = IdLib.toId(sourceMarket);
        uint256 tempDebt = midnight.debt(sourceId, tempBorrower);
        loanToken.mint(tempBorrower, tempDebt);
        vm.startPrank(tempBorrower);
        loanToken.approve(address(midnight), tempDebt);
        midnight.repay(sourceMarket, tempDebt, tempBorrower, address(0), "");
        vm.stopPrank();

        // Verify: lender has credit, and market has withdrawable balance
        uint256 lenderCredit = midnight.credit(sourceId, lender);
        uint256 withdrawable = midnight.withdrawable(sourceId);
        assertGt(lenderCredit, 0, "Setup: lender should have credit");
        assertGt(withdrawable, 0, "Setup: market should have withdrawable balance");
    }

    /// @dev Sign an offer using a private key
    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(sk, digest);
        return signature;
    }

    /// @dev Encode callback data
    function _encodeCallbackData(uint256 feeRate, address recipient) internal view returns (bytes memory) {
        return abi.encode(
            ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: feeRate, feeRecipient: recipient, tick: offerTick
            })
        );
    }

    /// @dev Encode callback data with custom tick
    function _encodeCallbackDataWithTick(uint256 feeRate, address recipient, uint256 tick)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: feeRate, feeRecipient: recipient, tick: tick
            })
        );
    }

    /// @dev Prepare a BUY offer for the lender without executing (allows vm.expectRevert before take)
    function _prepareBuyOffer(uint256 buyerAssets, bytes memory callbackData)
        internal
        view
        returns (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units)
    {
        offer = Offer({
            market: targetMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: offerTick,
            group: keccak256(abi.encodePacked("buy_offer", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        sig = _signOffer(offer, lenderSK);
        offerRoot = HashLib.hashOffer(offer);

        bytes32 _id = IdLib.toId(offer.market);
        _units = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, buyerAssets);
    }

    /// @dev Execute a BUY offer take (borrower takes lender's BUY offer on target market)
    struct TakeResult {
        uint256 buyerAssets;
        uint256 sellerAssets;
        uint256 units;
    }

    function _takeBuyOffer(uint256 buyerAssets, bytes memory callbackData) internal returns (TakeResult memory result) {
        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareBuyOffer(buyerAssets, callbackData);

        vm.prank(borrower);
        (result.buyerAssets, result.sellerAssets) = midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, borrower, borrower, address(0), ""
        );
        result.units = _units;
    }

    /// @dev Calculate expected buyer fee using independent raw math (not CallbackLib)
    ///      buyerEffPrice = price * WAD / (WAD - x) rounded down
    ///      buyerFee = mulDivDown(units, buyerEffPrice, WAD) - buyerAssets (zero floor)
    ///      where x = (WAD - price) * feeRate / WAD rounded down
    function _calculateExpectedFee(uint256 units, uint256 assets, uint256 feeRate, uint256 tick)
        internal
        pure
        returns (uint256)
    {
        if (feeRate == 0) return 0;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 x = UtilsLib.mulDivDown(WAD - price, feeRate, WAD);
        uint256 effPrice = UtilsLib.mulDivDown(price, WAD, WAD - x);
        return UtilsLib.zeroFloorSub(UtilsLib.mulDivDown(units, effPrice, WAD), assets);
    }

    /* ========== GUARDS ========== */

    function test_onBuy_revertsIfNotMidnight() public {
        ILendMidnightRenewalCallback.CallbackData memory data = ILendMidnightRenewalCallback.CallbackData({
            sourceMarket: sourceMarket, feeRate: 0.01e18, feeRecipient: feeRecipient, tick: offerTick
        });

        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onBuy(bytes32(0), targetMarket, 100e18, 100e18, 0, lender, abi.encode(data));
    }

    function test_onBuy_revertsZeroAmount_buyerAssets() public {
        bytes memory callbackData = _encodeCallbackData(0, address(0));

        // Direct call from midnight with buyerAssets == 0
        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        callback.onBuy(bytes32(0), targetMarket, 0, 100e18, 0, lender, callbackData);
    }

    function test_onBuy_revertsZeroAmount_units() public {
        bytes memory callbackData = _encodeCallbackData(0, address(0));

        // Direct call from midnight with units == 0
        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        callback.onBuy(bytes32(0), targetMarket, 100e18, 0, 0, lender, callbackData);
    }

    /* ========== VALIDATION ========== */

    function test_onBuy_revertsIfLoanTokenMismatch() public {
        // Create a different source market with wrong loan token
        MockERC20 wrongLoanToken = new MockERC20("Wrong Token", "WRONG", 18);

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        Market memory mismatchedSource = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(wrongLoanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        bytes memory callbackData = abi.encode(
            ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: mismatchedSource, feeRate: 0, feeRecipient: address(0), tick: offerTick
            })
        );

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareBuyOffer(50e18, callbackData);
        vm.prank(borrower);
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, borrower, borrower, address(0), ""
        );
    }

    /// @notice Sherlock #69: source market must differ from the target market being bought into.
    function test_onBuy_revertsIfSourceMarketEqualsTarget() public {
        bytes memory callbackData = abi.encode(
            ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: targetMarket, feeRate: 0, feeRecipient: address(0), tick: offerTick
            })
        );

        bytes32 targetMarketId = IdLib.toId(targetMarket);

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.SameMarket.selector);
        callback.onBuy(targetMarketId, targetMarket, 100e18, 100e18, 0, lender, callbackData);
    }

    function test_onBuy_revertsIfSourceCreditIsZero() public {
        // Create a fresh source market where lender has no credit
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        Market memory emptySource = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 14 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        bytes memory callbackData = abi.encode(
            ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: emptySource, feeRate: 0, feeRecipient: address(0), tick: offerTick
            })
        );

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareBuyOffer(50e18, callbackData);
        vm.prank(borrower);
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, borrower, borrower, address(0), ""
        );
    }

    function test_onBuy_revertsIfSourceCreditInsufficient() public {
        // Lender has LENDER_CREDIT (200e18) on the source market. Request a withdrawal larger than
        // that but greater than zero: 0 < credit < buyerAssets + fee. The named guard must fire
        // instead of letting Midnight's withdraw underflow.
        bytes memory callbackData = _encodeCallbackData(0, address(0));
        bytes32 targetMarketId = IdLib.toId(targetMarket);

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.InsufficientCredit.selector);
        callback.onBuy(targetMarketId, targetMarket, LENDER_CREDIT + 1, LENDER_CREDIT + 1, 0, lender, callbackData);
    }

    /* ========== HAPPY PATHS ========== */

    function test_onBuy_happyPath_withFee() public {
        uint256 feeRate = 0.5e18; // 50% of interest (within WAD limit for buyerFeeFromTick)
        bytes memory callbackData = _encodeCallbackData(feeRate, feeRecipient);

        bytes32 sourceId = IdLib.toId(sourceMarket);

        uint256 sourceCreditBefore = midnight.credit(sourceId, lender);
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);
        uint256 lenderBalBefore = loanToken.balanceOf(lender);

        // Take for 50e18 buyerAssets worth
        TakeResult memory result = _takeBuyOffer(50e18, callbackData);

        // Compute expected fee using exact same math as callback
        uint256 expectedFee = _calculateExpectedFee(result.units, result.buyerAssets, feeRate, offerTick);

        // 1. Source credit decreased (withdrawal happened)
        uint256 sourceCreditAfter = midnight.credit(sourceId, lender);
        assertLt(sourceCreditAfter, sourceCreditBefore, "Source credit should decrease");

        // 2. Fee paid to recipient (exact amount)
        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "Fee recipient should receive exact fee");
        assertGt(feeReceived, 0, "Fee should be > 0 with non-zero feeRate");

        // 3. Lender balance unchanged: callback withdraws (buyerAssets + fee) from source to itself,
        //    sends fee to feeRecipient, sends buyerAssets to lender.
        //    Then Midnight pulls buyerAssets from lender. Net effect on lender = 0.
        assertEq(loanToken.balanceOf(lender), lenderBalBefore, "Lender balance should be unchanged");

        // 4. CB-DUST-1: callback should have zero loan token balance after
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1: callback should have zero balance");
    }

    function test_onBuy_happyPath_zeroFee() public {
        bytes memory callbackData = _encodeCallbackData(0, address(0));

        bytes32 sourceId = IdLib.toId(sourceMarket);

        uint256 sourceCreditBefore = midnight.credit(sourceId, lender);
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);
        uint256 lenderBalBefore = loanToken.balanceOf(lender);

        TakeResult memory result = _takeBuyOffer(50e18, callbackData);

        // 1. Source credit decreased
        uint256 sourceCreditAfter = midnight.credit(sourceId, lender);
        assertLt(sourceCreditAfter, sourceCreditBefore, "Source credit should decrease");

        // 2. No fee paid
        assertEq(loanToken.balanceOf(feeRecipient), feeRecipientBefore, "No fee should be paid");

        // 3. Verify fee computation returns 0
        uint256 expectedFee = _calculateExpectedFee(result.units, result.buyerAssets, 0, offerTick);
        assertEq(expectedFee, 0, "Fee should be zero with zero feeRate");

        // 4. Lender balance unchanged: with zero fee, callback withdraws buyerAssets directly
        //    to lender, then Midnight pulls buyerAssets from lender. Net effect = 0.
        assertEq(loanToken.balanceOf(lender), lenderBalBefore, "Lender balance should be unchanged");

        // 5. CB-DUST-1: no dust
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1: callback should have zero balance");
    }

    /* ========== FULL MIGRATION ========== */

    /// @notice The lender can roll their ENTIRE source credit, draining the source position to zero.
    /// @dev Guards against a regression where the `sourceCredit == 0` sentinel or the
    ///      `buyerAssets + fee` withdraw would cap a full renewal. With zero fee, buyerAssets can
    ///      equal the full source credit and the source position drains completely.
    function test_onBuy_fullMigration_zeroFee() public {
        bytes memory callbackData = _encodeCallbackData(0, address(0));

        bytes32 sourceId = IdLib.toId(sourceMarket);
        bytes32 targetId = IdLib.toId(targetMarket);

        uint256 sourceCreditBefore = midnight.credit(sourceId, lender);
        uint256 targetCreditBefore = midnight.credit(targetId, lender);
        uint256 lenderBalBefore = loanToken.balanceOf(lender);

        // Roll the FULL source credit into the target market.
        _takeBuyOffer(sourceCreditBefore, callbackData);

        // Source fully drained.
        assertEq(midnight.credit(sourceId, lender), 0, "Source position should be fully drained");

        // Target credit created (lender now lends on target).
        assertGt(midnight.credit(targetId, lender), targetCreditBefore, "Target credit should increase");

        // Lender net balance unchanged, no callback dust.
        assertEq(loanToken.balanceOf(lender), lenderBalBefore, "Lender balance should be unchanged");
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1: callback should have zero balance");
    }

    /// @notice The lender can drain their entire source position even when a fee is skimmed.
    /// @dev With a fee, the source must cover buyerAssets + fee, so the full migration lends
    ///      (credit - fee) into the target. Solve for the buyerAssets that consumes the whole
    ///      source credit, then assert the source drains to zero and the fee is paid.
    function test_onBuy_fullMigration_withFee() public {
        uint256 feeRate = 0.5e18; // 50% of interest

        bytes32 sourceId = IdLib.toId(sourceMarket);
        bytes32 targetId = IdLib.toId(targetMarket);

        uint256 sourceCreditBefore = midnight.credit(sourceId, lender);
        uint256 targetCreditBefore = midnight.credit(targetId, lender);
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        // Find the largest buyerAssets whose (buyerAssets + fee) still fits within the source credit.
        uint256 buyerAssets = _solveFullDrainBuyerAssets(sourceCreditBefore, feeRate);

        bytes memory callbackData = _encodeCallbackData(feeRate, feeRecipient);
        TakeResult memory result = _takeBuyOffer(buyerAssets, callbackData);

        uint256 expectedFee = _calculateExpectedFee(result.units, result.buyerAssets, feeRate, offerTick);
        assertGt(expectedFee, 0, "Fee should be > 0");

        // Source fully drained: withdrawing buyerAssets + fee consumed the whole credit.
        assertEq(midnight.credit(sourceId, lender), 0, "Source position should be fully drained");

        // Target received the migrated principal (credit - fee); fee paid to recipient.
        assertGt(midnight.credit(targetId, lender), targetCreditBefore, "Target credit should increase");
        assertEq(
            loanToken.balanceOf(feeRecipient) - feeRecipientBefore, expectedFee, "Fee recipient should receive fee"
        );
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1: callback should have zero balance");
    }

    /// @dev Binary-search the buyerAssets B such that B + fee(B) == credit (largest B that fully
    ///      drains the source without over-withdrawing). buyerAssets -> units -> fee is monotonic.
    function _solveFullDrainBuyerAssets(uint256 credit, uint256 feeRate) internal view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = credit;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            (,,, uint256 units) = _prepareBuyOffer(mid, "");
            uint256 fee = _calculateExpectedFee(units, mid, feeRate, offerTick);
            if (mid + fee <= credit) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }

    /* ========== FEE EDGE CASES ========== */

    function test_onBuy_feeAt100PercentOfInterest() public {
        // feeRate = WAD (100% of interest). At ~0.99 price, interest per unit ~= 0.01.
        // So fee ~= interest = (units - buyerAssets). The callback withdraws (buyerAssets + fee)
        // from source. As long as source has enough credit, this succeeds.
        uint256 feeRate = WAD; // 100% of interest goes to fee
        bytes memory callbackData = _encodeCallbackData(feeRate, feeRecipient);

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        TakeResult memory result = _takeBuyOffer(50e18, callbackData);

        uint256 expectedFee = _calculateExpectedFee(result.units, result.buyerAssets, feeRate, offerTick);
        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "Fee should match expected calculation");
        assertGt(feeReceived, 0, "Fee should be > 0 at 100% interest fee");

        // CB-DUST-1
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1");
    }

    function test_onBuy_maxFeeRate() public {
        // feeRate = WAD (1e18 = 100% of interest) is the max allowed by _interestFeeComponent
        uint256 feeRate = WAD;
        bytes memory callbackData = _encodeCallbackData(feeRate, feeRecipient);

        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        TakeResult memory result = _takeBuyOffer(50e18, callbackData);

        uint256 expectedFee = _calculateExpectedFee(result.units, result.buyerAssets, feeRate, offerTick);
        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertEq(feeReceived, expectedFee, "Fee at max rate should match expected");

        // CB-DUST-1
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1");
    }

    function test_onBuy_revertsIfFeeRateExceedsMax() public {
        // feeRate > WAD should revert with InvalidFeeConfig
        uint256 feeRate = WAD + 1;
        bytes memory callbackData = _encodeCallbackData(feeRate, feeRecipient);

        (Offer memory offer, Signature memory sig, bytes32 offerRoot, uint256 _units) =
            _prepareBuyOffer(50e18, callbackData);
        vm.prank(borrower);
        vm.expectRevert(CallbackLib.InvalidFeeConfig.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), _units, borrower, borrower, address(0), ""
        );
    }
}
