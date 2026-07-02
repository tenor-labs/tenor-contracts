// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {ClampFuzzFixtures} from "../helpers/ClampFuzzFixtures.sol";
import {SellOfferClamp} from "../../src/router/clamps/SellOfferClamp.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";
import {OfferRemainingHelper} from "../helpers/OfferRemainingHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title SellOfferClampFuzzTest
/// @notice Proves that SellOfferClamp.maxUnits() always returns a maxShares value
///         that results in a successful midnight.take() call (no revert).
/// @dev SellOfferClamp checks collateral/health constraints; TenorRouter handles consumption.
///      The test ensures buyer (taker) has unlimited allowance/balance and seller (maker)
///      has generous collateral so those never bind — isolating the domain constraints.
contract SellOfferClampFuzzTest is ClampFuzzFixtures {
    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    SellOfferClamp internal clampContract;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    OfferRemainingHelper internal offerRemainingHelper;

    uint256 internal borrowerSK; // maker = seller = borrower
    address internal borrower;
    address internal lender; // taker = buyer = lender

    Market internal market;
    bytes32 internal marketId;

    function setUp() public {
        (borrower, borrowerSK) = makeAddrAndKey("borrower");
        lender = makeAddr("lender");

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        offerRemainingHelper = new OfferRemainingHelper();
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        clampContract = new SellOfferClamp(IMidnight(address(midnight)));

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        marketId = IdLib.toId(market);

        _seedMarket();

        // Borrower (seller/maker): massive collateral so health is never the issue
        collateralToken.mint(borrower, 1e38);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, 1e38, borrower);
        vm.stopPrank();

        // Lender (buyer/taker): unlimited balance and allowance — not the clamp's concern
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ========== SETUP HELPERS ========== */

    function _seedMarket() internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("seedBorrower");
        address seedLender = makeAddr("seedLender");

        loanToken.mint(seedLender, type(uint128).max);
        collateralToken.mint(seedBorrower, type(uint128).max);

        MidnightSupplyCollateralCallback setupCb = new MidnightSupplyCollateralCallback(address(midnight));

        vm.startPrank(seedBorrower);
        collateralToken.approve(address(setupCb), type(uint256).max);
        midnight.setIsAuthorized(address(setupCb), true, seedBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower);
        vm.stopPrank();

        vm.prank(seedLender);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = SEED_AMOUNT * 10;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory seedOffer = Offer({
            market: market,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("seed"),
            callback: address(setupCb),
            callbackData: cbData,
            receiverIfMakerIsSeller: seedBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(seedOffer, seedBorrowerSK);
        bytes32 root = HashLib.hashOffer(seedOffer);
        bytes memory rd = abi.encode(sig, root, uint256(0), new bytes32[](0));

        vm.prank(seedLender);
        midnight.take(seedOffer, rd, SEED_AMOUNT, seedLender, address(0), address(0), "");
    }

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        return Signature({v: v, r: r, s: s});
    }

    /* ========== FUZZ TESTS ========== */

    /// @notice Proves three invariants for shares-based SELL offers:
    ///         1. Safety: take(maxShares) never reverts
    ///         2. Exhaustion: take(1) after take(maxShares) either reverts or is zero-cost
    ///         3. Tightness: take(maxShares + 1) always reverts
    function testFuzz_clampedTakeNeverReverts_shares(
        uint128 offerCapacity,
        uint16 tick,
        bool reduceOnly,
        uint8 denomSeed
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);

        bytes32 group = keccak256(abi.encodePacked("shares", offerCapacity, tick));

        // SELL offer: maker=borrower (seller), taker=lender (buyer)
        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: borrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        SellOfferClamp.SellOfferClampData memory clampData =
            SellOfferClamp.SellOfferClampData({marketId: marketId, taker: lender});

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) {
            // maxShares==0 is valid if: reduceOnly with no credit to exit
            return;
        }

        Signature memory sig = _signOffer(offer, borrowerSK);
        bytes32 root = HashLib.hashOffer(offer);
        bytes memory rd = abi.encode(sig, root, uint256(0), new bytes32[](0));

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(lender);
        midnight.take(offer, rd, maxShares, lender, address(0), address(0), "");

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        uint256 lenderBalBefore = loanToken.balanceOf(lender);
        vm.prank(lender);
        try midnight.take(offer, rd, 1, lender, address(0), address(0), "") {
            uint256 lenderBalAfter = loanToken.balanceOf(lender);
            assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxShares + 1) reverts ---
        vm.prank(lender);
        vm.expectRevert();
        midnight.take(offer, rd, maxShares + 1, lender, address(0), address(0), "");
    }

    /// @notice Same three invariants with isUnits=true.
    function testFuzz_clampedTakeNeverReverts_units(
        uint128 offerCapacity,
        uint16 tick,
        bool reduceOnly,
        uint8 denomSeed
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);

        bytes32 group = keccak256(abi.encodePacked("units", offerCapacity, tick));

        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: borrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: borrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        SellOfferClamp.SellOfferClampData memory clampData =
            SellOfferClamp.SellOfferClampData({marketId: marketId, taker: lender});

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) {
            // maxShares==0 is valid if: reduceOnly with no credit to exit
            return;
        }

        Signature memory sig = _signOffer(offer, borrowerSK);
        bytes32 root = HashLib.hashOffer(offer);
        bytes memory rd = abi.encode(sig, root, uint256(0), new bytes32[](0));

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(lender);
        midnight.take(offer, rd, maxShares, lender, address(0), address(0), "");

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        uint256 lenderBalBefore = loanToken.balanceOf(lender);
        vm.prank(lender);
        try midnight.take(offer, rd, 1, lender, address(0), address(0), "") {
            uint256 lenderBalAfter = loanToken.balanceOf(lender);
            assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxShares + 1) reverts ---
        vm.prank(lender);
        vm.expectRevert();
        midnight.take(offer, rd, maxShares + 1, lender, address(0), address(0), "");
    }

    /* ========== BORROW WITH COLLATERAL CONSTRAINT ========== */

    /// @notice Proves three invariants when collateral (health) is the binding constraint.
    ///         The seller has fuzzed collateral, so health may be the tightest constraint.
    function testFuzz_clampedTakeNeverReverts_borrowWithCollateral(
        uint128 offerCapacity,
        uint128 collateralAmount,
        uint16 tick,
        uint8 denomSeed
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        // Collateral between 1 and 1e30 — enough to sometimes be healthy, sometimes not
        collateralAmount = uint128(bound(collateralAmount, 1, 1e30));

        bytes32 group = keccak256(abi.encodePacked("borrow-col", offerCapacity, collateralAmount, tick));

        // --- Create fresh borrower with fuzzed collateral ---
        (address freshBorrower, uint256 freshBorrowerSK) = makeAddrAndKey("freshBorrower");
        collateralToken.mint(freshBorrower, collateralAmount);
        vm.startPrank(freshBorrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, collateralAmount, freshBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshBorrower);
        vm.stopPrank();

        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: freshBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: freshBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        SellOfferClamp.SellOfferClampData memory clampData =
            SellOfferClamp.SellOfferClampData({marketId: marketId, taker: lender});

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);
        bytes memory rd = abi.encode(sig, root, uint256(0), new bytes32[](0));

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(lender);
        midnight.take(offer, rd, maxShares, lender, address(0), address(0), "");

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        uint256 lenderBalBefore = loanToken.balanceOf(lender);
        vm.prank(lender);
        try midnight.take(offer, rd, 1, lender, address(0), address(0), "") {
            uint256 lenderBalAfter = loanToken.balanceOf(lender);
            assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxShares + 1) reverts ---
        vm.prank(lender);
        vm.expectRevert();
        midnight.take(offer, rd, maxShares + 1, lender, address(0), address(0), "");
    }

    /* ========== RESELL PATH FUZZ TESTS ========== */

    /// @notice Proves three invariants for the resell path (seller has existing shares, sellerIsBorrower=false).
    ///         The seller is a lender exiting their position. Midnight subtracts marketShares from
    ///         sharesOf[seller], which underflows if shares > seller's balance.
    function testFuzz_clampedTakeNeverReverts_resell(
        uint128 sellerShares,
        uint128 offerCapacity,
        uint16 tick,
        uint8 denomSeed
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        sellerShares = uint128(bound(sellerShares, 1, SEED_AMOUNT)); // Capped to seed liquidity
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);

        bytes32 group = keccak256(abi.encodePacked("resell", sellerShares, offerCapacity, tick));

        // --- Create reseller with existing lending shares ---
        (address reseller, uint256 resellerSK) = makeAddrAndKey("reseller");
        vm.prank(reseller);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, reseller);
        _setupLenderWithShares(reseller, sellerShares);

        uint256 actualShares = creditAfterSlashing(midnight, marketId, reseller);
        assertGt(actualShares, 0, "reseller should have shares");

        // --- Build SELL offer from reseller (who has shares = resell path) ---
        // A second buyer needs loan token allowance
        address buyer2 = makeAddr("buyer2");
        loanToken.mint(buyer2, type(uint128).max);
        vm.prank(buyer2);
        loanToken.approve(address(midnight), type(uint256).max);

        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: reseller,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: reseller,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        SellOfferClamp.SellOfferClampData memory clampData =
            SellOfferClamp.SellOfferClampData({marketId: marketId, taker: buyer2});

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, resellerSK);
        bytes32 root = HashLib.hashOffer(offer);
        bytes memory rd = abi.encode(sig, root, uint256(0), new bytes32[](0));

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(buyer2);
        midnight.take(offer, rd, maxShares, buyer2, address(0), address(0), "");

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        uint256 buyer2BalBefore = loanToken.balanceOf(buyer2);
        vm.prank(buyer2);
        try midnight.take(offer, rd, 1, buyer2, address(0), address(0), "") {
            uint256 buyer2BalAfter = loanToken.balanceOf(buyer2);
            assertEq(buyer2BalBefore, buyer2BalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxShares + 1) reverts ---
        vm.prank(buyer2);
        vm.expectRevert();
        midnight.take(offer, rd, maxShares + 1, buyer2, address(0), address(0), "");
    }

    /// @dev Creates a BUY offer from a temp borrower, taken by the account as lender
    function _setupLenderWithShares(address account, uint128 shareAmount) internal {
        (address tempBorrower, uint256 tempBorrowerSK) = makeAddrAndKey("tempBorrower");

        collateralToken.mint(tempBorrower, type(uint128).max);
        vm.startPrank(tempBorrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, uint256(shareAmount) * 100, tempBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, tempBorrower);
        vm.stopPrank();

        loanToken.mint(account, type(uint128).max);
        vm.prank(account);
        loanToken.approve(address(midnight), type(uint256).max);

        Offer memory sellOffer = Offer({
            market: market,
            buy: false,
            maker: tempBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("lend-setup", account)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: tempBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, tempBorrowerSK);
        bytes32 root = HashLib.hashOffer(sellOffer);
        bytes memory rd = abi.encode(sig, root, uint256(0), new bytes32[](0));

        vm.prank(account);
        midnight.take(sellOffer, rd, shareAmount, account, address(0), address(0), "");
    }
}
