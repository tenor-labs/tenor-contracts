// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {ClampFuzzFixtures} from "../helpers/ClampFuzzFixtures.sol";
import {BuyOfferClamp} from "../../src/router/clamps/BuyOfferClamp.sol";
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
import {OfferRemainingHelper} from "../helpers/OfferRemainingHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title BuyOfferClampFuzzTest
/// @notice Proves that BuyOfferClamp.maxUnits() always returns a maxShares value
///         that results in a successful midnight.take() call (no revert).
contract BuyOfferClampFuzzTest is ClampFuzzFixtures {
    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    BuyOfferClamp internal clampContract;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    OfferRemainingHelper internal offerRemainingHelper;

    uint256 internal lenderSK;
    address internal lender;
    uint256 internal borrowerSK;
    address internal borrower;

    Market internal market;
    bytes32 internal marketId;

    function setUp() public {
        // Create accounts
        (lender, lenderSK) = makeAddrAndKey("lender");
        (borrower, borrowerSK) = makeAddrAndKey("borrower");

        // Deploy tokens and oracle
        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36); // 1 collateral = 10 loan tokens (high enough for health, low enough to avoid overflow)

        // Deploy Midnight (no settlement fees by default)
        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        enableDefaultLltvs(midnight);
        offerRemainingHelper = new OfferRemainingHelper();
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);
        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        // Deploy BuyOfferClamp
        clampContract = new BuyOfferClamp(IMidnight(address(midnight)));

        // Create market
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

        // Seed market with initial liquidity (makes totalUnits non-zero)
        _seedMarket();

        // Deposit massive collateral for the main borrower so health is never an issue
        _depositBorrowerCollateral();
    }

    /* ========== SETUP HELPERS ========== */

    function _seedMarket() internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("seedBorrower");
        address seedLender = makeAddr("seedLender");

        // Fund seed accounts
        loanToken.mint(seedLender, type(uint128).max);
        collateralToken.mint(seedBorrower, type(uint128).max);

        // Deploy collateral callback for seeding
        MidnightSupplyCollateralCallback setupCb = new MidnightSupplyCollateralCallback(address(midnight));

        vm.startPrank(seedBorrower);
        collateralToken.approve(address(setupCb), type(uint256).max);
        midnight.setIsAuthorized(address(setupCb), true, seedBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower);
        vm.stopPrank();

        vm.prank(seedLender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Build callback data for collateral supply
        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = SEED_AMOUNT * 10;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        // Create SELL offer from seedBorrower (borrower sells, seedLender buys)
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

        vm.prank(seedLender);
        midnight.take(
            seedOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            SEED_AMOUNT,
            seedLender,
            address(0),
            address(0),
            ""
        );
    }

    function _depositBorrowerCollateral() internal {
        // With oracle at 10e36 and lltv=0.945: maxDebt = collateral * 10 * 0.945 = collateral * 9.45
        // To cover max uint128 debt (~3.4e38): need ~3.6e37 collateral. Use 1e38 for safe margin.
        // Overflow check: 1e38 * 10e36 = 1e75 (safely within uint256)
        uint256 collateralAmount = 1e38;
        collateralToken.mint(borrower, collateralAmount);

        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, collateralAmount, borrower);
        vm.stopPrank();
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

    /// @notice Proves three invariants for shares-based BUY offers:
    ///         1. Safety: take(maxShares) never reverts
    ///         2. Exhaustion: take(1) after take(maxShares) either reverts or is zero-cost
    ///         3. Tightness: take(maxShares + 1) always reverts
    /// @dev The BuyOfferClamp does NOT check seller (borrower) health — the test deposits
    ///      generous collateral to isolate the clamp's own constraints (consumption + allowance).
    function testFuzz_clampedTakeNeverReverts_shares(
        uint128 offerCapacity,
        uint128 lenderAllowance,
        uint16 tick,
        bool reduceOnly,
        uint8 denomSeed
    ) external {
        // --- Bound inputs ---
        tick = uint16(bound(tick, 1, 1455)) * 4; // tick=0 gives price=0 (degenerate), start at 1
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        lenderAllowance = uint128(bound(lenderAllowance, 0, type(uint128).max));

        // Unique group per fuzz run
        bytes32 group = keccak256(abi.encodePacked(offerCapacity, lenderAllowance, tick));

        // --- Setup per-test state ---

        // Give lender massive balance (balance should never be the bottleneck)
        loanToken.mint(lender, type(uint128).max);

        // Set lender's approval to exactly lenderAllowance
        vm.prank(lender);
        loanToken.approve(address(midnight), uint256(lenderAllowance));

        // --- Build BUY offer ---
        (uint256 mu, uint256 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        // --- Call clamp ---
        BuyOfferClamp.BuyOfferClampData memory clampData =
            BuyOfferClamp.BuyOfferClampData({marketId: marketId, taker: borrower});

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) {
            // Clamp says nothing can be taken — verify the reason is valid
            assertTrue(lenderAllowance == 0 || reduceOnly, "maxShares==0 unexpectedly");
            return;
        }

        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, borrower, address(0), ""
        );

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        uint256 lenderBalBefore = loanToken.balanceOf(lender);
        vm.prank(borrower);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, borrower, address(0), ""
        ) {
            uint256 lenderBalAfter = loanToken.balanceOf(lender);
            assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxShares + 1) reverts ---
        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            borrower,
            borrower,
            address(0),
            ""
        );
    }

    /// @notice Same three invariants (safety, exhaustion, tightness) with isUnits=true.
    function testFuzz_clampedTakeNeverReverts_units(
        uint128 offerCapacity,
        uint128 lenderAllowance,
        uint16 tick,
        bool reduceOnly,
        uint8 denomSeed
    ) external {
        // --- Bound inputs ---
        tick = uint16(bound(tick, 1, 1455)) * 4; // tick=0 gives price=0 (degenerate), start at 1
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        lenderAllowance = uint128(bound(lenderAllowance, 0, type(uint128).max));

        bytes32 group = keccak256(abi.encodePacked("units", offerCapacity, lenderAllowance, tick));

        // --- Setup per-test state ---
        loanToken.mint(lender, type(uint128).max);

        vm.prank(lender);
        loanToken.approve(address(midnight), uint256(lenderAllowance));

        // --- Build BUY offer (units-based capacity) ---
        (uint256 mu, uint256 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        // --- Call clamp ---
        BuyOfferClamp.BuyOfferClampData memory clampData =
            BuyOfferClamp.BuyOfferClampData({marketId: marketId, taker: borrower});

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) {
            assertTrue(lenderAllowance == 0 || reduceOnly, "maxShares==0 unexpectedly");
            return;
        }

        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, borrower, address(0), ""
        );

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        uint256 lenderBalBefore2 = loanToken.balanceOf(lender);
        vm.prank(borrower);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, borrower, address(0), ""
        ) {
            uint256 lenderBalAfter2 = loanToken.balanceOf(lender);
            assertEq(lenderBalBefore2, lenderBalAfter2, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxShares + 1) reverts ---
        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            borrower,
            borrower,
            address(0),
            ""
        );
    }

    /* ========== REPAY PATH FUZZ TESTS ========== */

    /// @notice Proves three invariants for the repay path (buyerIsLender=false):
    ///         1. Safety: take(maxShares) never reverts
    ///         2. Exhaustion: take(1) after take(maxShares) either reverts or is zero-cost
    ///         3. Tightness: take(maxShares + 1) always reverts
    /// @dev No-dust invariant doesn't apply: after take, buyer.debt may go to 0 changing
    ///      buyerIsLender from false to true, so maxUnits() returns non-zero for the new lender role.
    /// @dev When !buyerIsLender, Midnight.take() subtracts units from buyer.debt.
    ///      Without the debt constraint in BuyOfferClamp, this can underflow.
    function testFuzz_clampedTakeNeverReverts_repay(
        uint128 buyerDebtUnits,
        uint128 offerCapacity,
        uint128 repayerAllowance,
        uint16 tick,
        uint8 denomSeed
    ) external {
        // --- Bound inputs ---
        tick = uint16(bound(tick, 1, 1455)) * 4;
        // Buyer's debt must be at least 1 to trigger the repay path
        buyerDebtUnits = uint128(bound(buyerDebtUnits, 1, SEED_AMOUNT)); // Capped to seed liquidity
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        repayerAllowance = uint128(bound(repayerAllowance, 0, type(uint128).max));

        bytes32 group = keccak256(abi.encodePacked("repay", buyerDebtUnits, offerCapacity, repayerAllowance, tick));

        // --- Create repayer with existing debt ---
        (address repayer, uint256 repayerSK) = makeAddrAndKey("repayer");
        _setupBorrowerWithDebt(repayer, repayerSK, buyerDebtUnits);

        // Verify repayer actually has debt
        uint256 actualDebt = midnight.debt(marketId, repayer);
        assertGt(actualDebt, 0, "repayer should have debt");

        // --- Setup per-test state ---
        // Give repayer massive loan token balance (balance is not the bottleneck)
        loanToken.mint(repayer, type(uint128).max);

        // Set repayer's approval
        vm.prank(repayer);
        loanToken.approve(address(midnight), uint256(repayerAllowance));

        // --- Build BUY offer from repayer (who has debt = repay path) ---
        // reduceOnly=true: repayer is closing their borrow position, crossing not allowed
        (uint256 mu, uint256 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: repayer,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: true,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        // --- Call clamp ---
        BuyOfferClamp.BuyOfferClampData memory clampData =
            BuyOfferClamp.BuyOfferClampData({marketId: marketId, taker: borrower});

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, repayerSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, borrower, address(0), ""
        );

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is a zero-cost take ---
        // In the repay path, after take(maxShares) the buyer's debt may reach 0, flipping
        // buyerIsLender from false to true. Subsequent takes are valid new lending, not zero-cost.
        // Only assert zero-cost when the buyer still has debt (role didn't change).
        uint256 debtAfterTake = midnight.debt(marketId, repayer);
        if (debtAfterTake > 0) {
            uint256 repayerBalBefore = loanToken.balanceOf(repayer);
            vm.prank(borrower);
            try midnight.take(
                offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, borrower, address(0), ""
            ) {
                uint256 repayerBalAfter = loanToken.balanceOf(repayer);
                assertEq(repayerBalBefore, repayerBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxShares + 1) reverts ---
        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            borrower,
            borrower,
            address(0),
            ""
        );
    }

    /// @notice Same three invariants (safety, exhaustion, tightness) for repay with isUnits=true.
    function testFuzz_clampedTakeNeverReverts_repayUnits(
        uint128 buyerDebtUnits,
        uint128 offerCapacity,
        uint128 repayerAllowance,
        uint16 tick,
        uint8 denomSeed
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        buyerDebtUnits = uint128(bound(buyerDebtUnits, 1, SEED_AMOUNT));
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        repayerAllowance = uint128(bound(repayerAllowance, 0, type(uint128).max));

        bytes32 group = keccak256(abi.encodePacked("repayUnits", buyerDebtUnits, offerCapacity, repayerAllowance, tick));

        (address repayer, uint256 repayerSK) = makeAddrAndKey("repayer");
        _setupBorrowerWithDebt(repayer, repayerSK, buyerDebtUnits);

        uint256 actualDebt = midnight.debt(marketId, repayer);
        assertGt(actualDebt, 0, "repayer should have debt");

        loanToken.mint(repayer, type(uint128).max);

        vm.prank(repayer);
        loanToken.approve(address(midnight), uint256(repayerAllowance));

        // BUY offer with units-based capacity (typical repay offer)
        // reduceOnly=true: repayer is closing their borrow position, crossing not allowed
        (uint256 mu, uint256 ma) = _denomFields(offerCapacity, denom);
        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: repayer,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: true,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        BuyOfferClamp.BuyOfferClampData memory clampData =
            BuyOfferClamp.BuyOfferClampData({marketId: marketId, taker: borrower});

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));

        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, marketId);
            maxShares = UtilsLib.min(maxShares, remaining);
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, repayerSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, borrower, address(0), ""
        );

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is a zero-cost take ---
        uint256 debtAfterTake2 = midnight.debt(marketId, repayer);
        if (debtAfterTake2 > 0) {
            uint256 repayerBalBefore = loanToken.balanceOf(repayer);
            vm.prank(borrower);
            try midnight.take(
                offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, borrower, address(0), ""
            ) {
                uint256 repayerBalAfter = loanToken.balanceOf(repayer);
                assertEq(repayerBalBefore, repayerBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxShares + 1) reverts ---
        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            borrower,
            borrower,
            address(0),
            ""
        );
    }

    /// @notice Helper: give an account borrower debt on the market
    /// @dev Creates a SELL offer from the account (taken by a temp lender), putting the account in debt.
    function _setupBorrowerWithDebt(address account, uint256 accountSK, uint128 debtUnits) internal {
        address tempLender = makeAddr("tempLender");

        // Fund accounts
        collateralToken.mint(account, type(uint128).max);
        loanToken.mint(tempLender, type(uint128).max);

        // Setup collateral callback for the account
        MidnightSupplyCollateralCallback cb = new MidnightSupplyCollateralCallback(address(midnight));
        vm.startPrank(account);
        collateralToken.approve(address(cb), type(uint256).max);
        midnight.setIsAuthorized(address(cb), true, account);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, account);
        vm.stopPrank();

        vm.prank(tempLender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Build callback data for collateral supply
        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = uint256(debtUnits) * 10; // 10x collateral for health
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: debtUnits, maxBorrowCapacityUsage: 0
            })
        );

        // SELL offer from the account (borrower sells, tempLender buys)
        Offer memory sellOffer = Offer({
            market: market,
            buy: false,
            maker: account,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK, // Price near 1.0 so units ≈ shares
            group: keccak256(abi.encodePacked("debt-setup", account)),
            callback: address(cb),
            callbackData: cbData,
            receiverIfMakerIsSeller: account,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, accountSK);
        bytes32 root = HashLib.hashOffer(sellOffer);
        uint256 shares = debtUnits;

        vm.prank(tempLender);
        midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            shares,
            tempLender,
            address(0),
            address(0),
            ""
        );
    }

    /* ========== EDGE CASE FUZZ TESTS ========== */

    /// @notice Zero allowance always returns 0 shares
    function testFuzz_zeroAllowance_returnsZero(uint128 offerCapacity, uint16 tick) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_OFFER_CAPACITY));

        // Explicitly set zero allowance
        vm.prank(lender);
        loanToken.approve(address(midnight), 0);

        Offer memory offer = Offer({
            market: market,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256(abi.encodePacked("zero-allow", offerCapacity, tick)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        BuyOfferClamp.BuyOfferClampData memory clampData =
            BuyOfferClamp.BuyOfferClampData({marketId: marketId, taker: borrower});

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        assertEq(maxShares, 0, "zero allowance should return zero units");
    }
}
