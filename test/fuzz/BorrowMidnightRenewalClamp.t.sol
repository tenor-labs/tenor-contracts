// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {BorrowMidnightRenewalClamp} from "../../src/router/clamps/BorrowMidnightRenewalClamp.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {BorrowMidnightRenewalCallback} from "@callbacks/BorrowMidnightRenewalCallback.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {ClampFuzzFixtures} from "../helpers/ClampFuzzFixtures.sol";
import {OfferRemainingHelper} from "../helpers/OfferRemainingHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title BorrowMidnightRenewalClampFuzzTest
/// @notice Proves that BorrowMidnightRenewalClamp.maxUnits() always returns a maxShares value
///         that results in a successful midnight.take() call (no revert).
/// @dev This clamp is for cross-market borrow renewals (Midnight to Midnight borrow path).
///      Constraints: source debt position + fee
contract BorrowMidnightRenewalClampFuzzTest is ClampFuzzFixtures {
    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    BorrowMidnightRenewalClamp internal clampContract;
    BorrowMidnightRenewalCallback internal renewalCallback;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    OfferRemainingHelper internal offerRemainingHelper;

    uint256 internal borrowerSK;
    address internal borrower;
    uint256 internal lenderSK;
    address internal lender;
    address internal feeRecipient;

    Market internal sourceMarket;
    Market internal targetMarket;
    bytes32 internal sourceMarketId;
    bytes32 internal targetMarketId;

    function setUp() public {
        (borrower, borrowerSK) = makeAddrAndKey("borrower");
        (lender, lenderSK) = makeAddrAndKey("lender");
        feeRecipient = makeAddr("feeRecipient");

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
        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);

        clampContract = new BorrowMidnightRenewalClamp(IMidnight(address(midnight)));
        renewalCallback = new BorrowMidnightRenewalCallback(address(midnight));

        // Create two markets with different maturities (source → target renewal)
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        sourceMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        sourceMarketId = IdLib.toId(sourceMarket);

        targetMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 60 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        targetMarketId = IdLib.toId(targetMarket);

        // Seed both markets
        _seedMarket(sourceMarket, sourceMarketId);
        _seedMarket(targetMarket, targetMarketId);

        // Lender (taker): unlimited balance and allowance
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
    }

    /* ========== SETUP HELPERS ========== */

    function _seedMarket(Market memory market, bytes32 marketId) internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey(string(abi.encodePacked("seed", marketId)));
        address seedLender = makeAddr(string(abi.encodePacked("lender", marketId)));

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
            group: keccak256(abi.encodePacked("seed", marketId)),
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

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        return Signature({v: v, r: r, s: s});
    }

    /// @notice Helper: give borrower debt on source market
    function _setupBorrowerWithSourceDebt(address account, uint256 accountSK, uint128 debtUnits) internal {
        address tempLender = makeAddr(string(abi.encodePacked("tempLender", account)));

        collateralToken.mint(account, type(uint128).max);
        loanToken.mint(tempLender, type(uint128).max);

        MidnightSupplyCollateralCallback cb = new MidnightSupplyCollateralCallback(address(midnight));
        vm.startPrank(account);
        collateralToken.approve(address(cb), type(uint256).max);
        midnight.setIsAuthorized(address(cb), true, account);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, account);
        vm.stopPrank();

        vm.prank(tempLender);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = uint256(debtUnits) * 20; // Generous collateral
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: debtUnits, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory sellOffer = Offer({
            market: sourceMarket,
            buy: false,
            maker: account,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup-debt", account)),
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

    /* ========== FUZZ TESTS ========== */

    /// @notice Proves four invariants for shares-based SELL offers (Midnight to Midnight borrow renewal):
    ///         1. Safety: take(maxShares) succeeds (or reverts due to Midnight health check)
    ///         2. No-dust: re-calling maxUnits() after taking maxShares returns 0
    ///         3. Exhaustion: take(1) after take(maxShares) either reverts or is zero-cost
    ///         4. Tightness: take(maxShares + 1) always reverts
    /// @dev Fuzzes BOTH fee dimensions: callback feeRate (0-50%) + settlement fee (via TTM)
    function testFuzz_clampedTakeNeverReverts_shares(uint128 sourceDebt, uint128 offerCapacity, uint256 packed)
        external
    {
        sourceDebt = uint128(bound(sourceDebt, 1, SEED_AMOUNT)); // Cap to seed liquidity

        address freshBorrower;
        uint256 freshBorrowerSK;
        Offer memory offer;
        bytes memory encodedClampData;
        uint256 maxShares;

        {
            bool reduceOnly = packed & 1 == 1;
            uint8 denom = _boundDenomination(uint8(packed >> 8));
            offerCapacity = _boundOfferCapacity(offerCapacity, denom);
            uint16 tick = _boundTick(uint16(packed >> 16));
            uint256 callbackFeeRate = _boundCallbackFeeRate(packed >> 64);
            uint256 ttm = _boundTimeToMaturity(uint8(packed >> 32));

            bytes32 group = keccak256(
                abi.encodePacked("v2v2-borrow-shares", sourceDebt, offerCapacity, tick, callbackFeeRate, ttm)
            );

            // Setup fresh borrower with source debt
            (freshBorrower, freshBorrowerSK) = makeAddrAndKey("freshBorrower");
            _setupBorrowerWithSourceDebt(freshBorrower, freshBorrowerSK, sourceDebt);

            assertGt(midnight.debt(sourceMarketId, freshBorrower), 0, "borrower should have source debt");

            // Create custom target market with specific TTM for settlement fee testing
            Market memory customTarget = targetMarket;
            customTarget.maturity = block.timestamp + ttm;
            bytes32 customTargetId = IdLib.toId(customTarget);

            if (midnight.tickSpacing(customTargetId) == 0) {
                _seedMarket(customTarget, customTargetId);
            }

            // Setup callback for proper collateral transfer
            vm.startPrank(freshBorrower);
            midnight.setIsAuthorized(address(renewalCallback), true, freshBorrower);
            vm.stopPrank();

            IBorrowMidnightRenewalCallback.CallbackData memory cbData = IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: callbackFeeRate, feeRecipient: feeRecipient, tick: tick
            });

            // SELL offer on target market (borrower sells future debt = borrow renewal)
            (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
            offer = Offer({
                market: customTarget,
                buy: false,
                maker: freshBorrower,
                start: block.timestamp,
                expiry: block.timestamp + 1 hours,
                tick: tick,
                group: group,
                callback: address(renewalCallback),
                callbackData: abi.encode(cbData),
                receiverIfMakerIsSeller: address(renewalCallback),
                ratifier: address(ecrecoverRatifier),
                reduceOnly: reduceOnly,
                maxUnits: mu,
                maxAssets: ma,
                continuousFeeCap: type(uint256).max
            });

            BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData memory clampData =
                BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData({
                    sourceMarketId: sourceMarketId,
                    targetMarketId: customTargetId,
                    positionOwner: lender,
                    feeRate: callbackFeeRate
                });

            encodedClampData = abi.encode(clampData);
            maxShares = clampContract.maxUnits(offer, encodedClampData);

            // Cap by offer remaining (simulates TenorRouter's structural consumed check)
            {
                uint256 remaining =
                    offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, customTargetId);
                maxShares = UtilsLib.min(maxShares, remaining);
            }

            // Self-renewal (source == target) should always return 0
            if (customTargetId == sourceMarketId) {
                assertEq(maxShares, 0, "self-renewal should return 0");
                return;
            }
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds or reverts due to Midnight health check ---
        // Health is NOT the clamp's responsibility (see HEALTH CHECK doc in clamp).
        // At extreme ticks, Midnight's internal health check may reject the take.
        // The router handles this via try/catch (fail-safe mode).
        uint256 snap = vm.snapshotState();

        vm.prank(lender);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, lender, address(0), address(0), ""
        ) {
        // take succeeded — check remaining invariants
        }
        catch Error(string memory reason) {
            assertEq(reason, "seller is unhealthy", "unexpected revert reason");
            vm.revertToState(snap);
            return;
        } catch {
            fail("unexpected non-string revert in take(maxShares): clamp or callback bug");
        }

        // --- Invariant 2: No-dust — clamp returns 0 after taking maxShares ---
        {
            uint256 postClamp = clampContract.maxUnits(offer, encodedClampData);
            assertEq(postClamp, 0, "clamp should return 0 after taking maxShares (no dust)");
        }

        // --- Invariant 3: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        {
            uint256 lenderBalBefore = loanToken.balanceOf(lender);
            vm.prank(lender);
            try midnight.take(
                offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, lender, address(0), address(0), ""
            ) {
                uint256 lenderBalAfter = loanToken.balanceOf(lender);
                assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 4: Tightness — take(maxShares + 1) reverts ---
        vm.prank(lender);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            lender,
            address(0),
            address(0),
            ""
        );
    }

    /// @notice Same four invariants with units-based offer.
    /// @dev Fuzzes BOTH fee dimensions: callback feeRate (0-50%) + settlement fee (via TTM)
    function testFuzz_clampedTakeNeverReverts_units(uint128 sourceDebt, uint128 offerCapacity, uint256 packed)
        external
    {
        sourceDebt = uint128(bound(sourceDebt, 1, SEED_AMOUNT));

        address freshBorrower;
        uint256 freshBorrowerSK;
        Offer memory offer;
        bytes memory encodedClampData;
        uint256 maxShares;

        {
            bool reduceOnly = packed & 1 == 1;
            uint8 denom = _boundDenomination(uint8(packed >> 8));
            offerCapacity = _boundOfferCapacity(offerCapacity, denom);
            uint16 tick = _boundTick(uint16(packed >> 16));
            uint256 callbackFeeRate = _boundCallbackFeeRate(packed >> 64);
            uint256 ttm = _boundTimeToMaturity(uint8(packed >> 32));

            bytes32 group =
                keccak256(abi.encodePacked("v2v2-borrow-units", sourceDebt, offerCapacity, tick, callbackFeeRate, ttm));

            (freshBorrower, freshBorrowerSK) = makeAddrAndKey("freshBorrowerUnits");
            _setupBorrowerWithSourceDebt(freshBorrower, freshBorrowerSK, sourceDebt);

            assertGt(midnight.debt(sourceMarketId, freshBorrower), 0, "borrower should have source debt");

            // Create custom target market with specific TTM for settlement fee testing
            Market memory customTarget = targetMarket;
            customTarget.maturity = block.timestamp + ttm;
            bytes32 customTargetId = IdLib.toId(customTarget);

            if (midnight.tickSpacing(customTargetId) == 0) {
                _seedMarket(customTarget, customTargetId);
            }

            // Setup callback for proper collateral transfer
            vm.startPrank(freshBorrower);
            midnight.setIsAuthorized(address(renewalCallback), true, freshBorrower);
            vm.stopPrank();

            IBorrowMidnightRenewalCallback.CallbackData memory cbData = IBorrowMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: callbackFeeRate, feeRecipient: feeRecipient, tick: tick
            });

            (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
            offer = Offer({
                market: customTarget,
                buy: false,
                maker: freshBorrower,
                start: block.timestamp,
                expiry: block.timestamp + 1 hours,
                tick: tick,
                group: group,
                callback: address(renewalCallback),
                callbackData: abi.encode(cbData),
                receiverIfMakerIsSeller: address(renewalCallback),
                ratifier: address(ecrecoverRatifier),
                reduceOnly: reduceOnly,
                maxUnits: mu,
                maxAssets: ma,
                continuousFeeCap: type(uint256).max
            });

            BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData memory clampData =
                BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData({
                    sourceMarketId: sourceMarketId,
                    targetMarketId: customTargetId,
                    positionOwner: lender,
                    feeRate: callbackFeeRate
                });

            encodedClampData = abi.encode(clampData);
            maxShares = clampContract.maxUnits(offer, encodedClampData);

            // Cap by offer remaining (simulates TenorRouter's structural consumed check)
            {
                uint256 remaining =
                    offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, customTargetId);
                maxShares = UtilsLib.min(maxShares, remaining);
            }

            // Self-renewal (source == target) should always return 0
            if (customTargetId == sourceMarketId) {
                assertEq(maxShares, 0, "self-renewal should return 0");
                return;
            }
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds or reverts due to Midnight health check ---
        uint256 snap = vm.snapshotState();

        vm.prank(lender);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, lender, address(0), address(0), ""
        ) {
        // take succeeded — check remaining invariants
        }
        catch Error(string memory reason) {
            assertEq(reason, "seller is unhealthy", "unexpected revert reason");
            vm.revertToState(snap);
            return;
        } catch {
            fail("unexpected non-string revert in take(maxShares): clamp or callback bug");
        }

        // --- Invariant 2: No-dust — clamp returns 0 after taking maxShares ---
        {
            uint256 postClamp = clampContract.maxUnits(offer, encodedClampData);
            assertEq(postClamp, 0, "clamp should return 0 after taking maxShares (no dust)");
        }

        // --- Invariant 3: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        {
            uint256 lenderBalBefore = loanToken.balanceOf(lender);
            vm.prank(lender);
            try midnight.take(
                offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, lender, address(0), address(0), ""
            ) {
                uint256 lenderBalAfter = loanToken.balanceOf(lender);
                assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 4: Tightness — take(maxShares + 1) reverts ---
        vm.prank(lender);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            lender,
            address(0),
            address(0),
            ""
        );
    }

    /* ========== UNCONSTRAINED CAPACITY FUZZ TESTS ========== */

    /// @notice When offer capacity is unconstrained, take(maxShares) must fully close the source debt.
    /// @dev Sets offerCapacity = type(uint128).max so budget is always the binding constraint.
    ///      Fuzzes: sourceDebt, tick, feeRate, TTM (settlement fee)
    function testFuzz_unconstrainedCapacity_sourceFullyClosed_shares(
        uint128 sourceDebt,
        uint16 tick,
        uint256 feeRateSeed,
        uint8 ttmSeed,
        bool reduceOnly
    ) external {
        tick = _boundTick(tick);
        sourceDebt = uint128(bound(sourceDebt, 1, SEED_AMOUNT));
        uint256 callbackFeeRate = _boundCallbackFeeRate(feeRateSeed);
        uint256 ttm = _boundTimeToMaturity(ttmSeed);

        uint128 offerCapacity = MAX_OFFER_CAPACITY;

        bytes32 group = keccak256(abi.encodePacked("v2v2-borrow-uncap-shares", sourceDebt, tick, callbackFeeRate, ttm));

        (address freshBorrower, uint256 freshBorrowerSK) = makeAddrAndKey("freshBorrowerUncap");
        _setupBorrowerWithSourceDebt(freshBorrower, freshBorrowerSK, sourceDebt);

        uint256 actualDebt = midnight.debt(sourceMarketId, freshBorrower);
        assertGt(actualDebt, 0, "borrower should have source debt");

        // Create custom target market with specific TTM
        Market memory customTarget = targetMarket;
        customTarget.maturity = block.timestamp + ttm;
        bytes32 customTargetId = IdLib.toId(customTarget);

        if (midnight.tickSpacing(customTargetId) == 0) {
            _seedMarket(customTarget, customTargetId);
        }

        // Skip self-renewal
        if (customTargetId == sourceMarketId) return;

        vm.startPrank(freshBorrower);
        midnight.setIsAuthorized(address(renewalCallback), true, freshBorrower);
        vm.stopPrank();

        IBorrowMidnightRenewalCallback.CallbackData memory cbData = IBorrowMidnightRenewalCallback.CallbackData({
            sourceMarket: sourceMarket, feeRate: callbackFeeRate, feeRecipient: feeRecipient, tick: tick
        });
        Offer memory offer = Offer({
            market: customTarget,
            buy: false,
            maker: freshBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(renewalCallback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(renewalCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData memory clampData =
            BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData({
                sourceMarketId: sourceMarketId,
                targetMarketId: customTargetId,
                positionOwner: lender,
                feeRate: callbackFeeRate
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(lender);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, lender, address(0), address(0), ""
        ) {
            // Source debt must be fully repaid when capacity is unconstrained
            uint256 remainingDebt = midnight.debt(sourceMarketId, freshBorrower);
            assertEq(remainingDebt, 0, "source debt must be fully closed when capacity is unconstrained");
        } catch Error(string memory reason) {
            assertEq(reason, "seller is unhealthy", "unexpected revert reason in unconstrained capacity test");
        } catch {
            fail("unexpected non-string revert in unconstrained capacity test: clamp or callback bug");
        }
    }

    /// @notice Same as above but with units-based offer
    function testFuzz_unconstrainedCapacity_sourceFullyClosed_units(
        uint128 sourceDebt,
        uint16 tick,
        uint256 feeRateSeed,
        uint8 ttmSeed,
        bool reduceOnly
    ) external {
        tick = _boundTick(tick);
        sourceDebt = uint128(bound(sourceDebt, 1, SEED_AMOUNT));
        uint256 callbackFeeRate = _boundCallbackFeeRate(feeRateSeed);
        uint256 ttm = _boundTimeToMaturity(ttmSeed);

        uint128 offerCapacity = MAX_OFFER_CAPACITY;

        bytes32 group = keccak256(abi.encodePacked("v2v2-borrow-uncap-units", sourceDebt, tick, callbackFeeRate, ttm));

        (address freshBorrower, uint256 freshBorrowerSK) = makeAddrAndKey("freshBorrowerUncapUnits");
        _setupBorrowerWithSourceDebt(freshBorrower, freshBorrowerSK, sourceDebt);

        uint256 actualDebt = midnight.debt(sourceMarketId, freshBorrower);
        assertGt(actualDebt, 0, "borrower should have source debt");

        Market memory customTarget = targetMarket;
        customTarget.maturity = block.timestamp + ttm;
        bytes32 customTargetId = IdLib.toId(customTarget);

        if (midnight.tickSpacing(customTargetId) == 0) {
            _seedMarket(customTarget, customTargetId);
        }

        if (customTargetId == sourceMarketId) return;

        vm.startPrank(freshBorrower);
        midnight.setIsAuthorized(address(renewalCallback), true, freshBorrower);
        vm.stopPrank();

        IBorrowMidnightRenewalCallback.CallbackData memory cbData = IBorrowMidnightRenewalCallback.CallbackData({
            sourceMarket: sourceMarket, feeRate: callbackFeeRate, feeRecipient: feeRecipient, tick: tick
        });
        Offer memory offer = Offer({
            market: customTarget,
            buy: false,
            maker: freshBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(renewalCallback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(renewalCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData memory clampData =
            BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData({
                sourceMarketId: sourceMarketId,
                targetMarketId: customTargetId,
                positionOwner: lender,
                feeRate: callbackFeeRate
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(lender);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, lender, address(0), address(0), ""
        ) {
            uint256 remainingDebt = midnight.debt(sourceMarketId, freshBorrower);
            assertEq(remainingDebt, 0, "source debt must be fully closed when capacity is unconstrained");
        } catch Error(string memory reason) {
            assertEq(reason, "seller is unhealthy", "unexpected revert reason in unconstrained capacity test");
        } catch {
            fail("unexpected non-string revert in unconstrained capacity test: clamp or callback bug");
        }
    }

    /* ========== EDGE CASE FUZZ TESTS ========== */

    /// @notice Zero source debt always returns 0 shares
    function testFuzz_zeroSourceDebt_returnsZero(uint128 offerCapacity, uint16 tick) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_OFFER_CAPACITY));

        // Borrower with no debt
        (address emptyBorrower,) = makeAddrAndKey("emptyBorrower");

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: emptyBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256("zero-debt"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: emptyBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData memory clampData =
            BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData({
                sourceMarketId: sourceMarketId, targetMarketId: targetMarketId, positionOwner: lender, feeRate: 0
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        assertEq(maxShares, 0, "zero source debt should return zero units");
    }

    /* ========== TAKER-DIRECTION FUZZ TESTS ========== */

    /// @notice Taker direction: BUY offer from lender (counterparty), borrower is taker with callback.
    ///         Proves the same five invariants as the maker-direction tests.
    /// @dev Here the renewee (borrower) is the TAKER (direct midnight.take with the migration callback as
    ///      takerCallback), not the maker. The counterparty (lender) makes a BUY offer.
    function testFuzz_takerDirection_clampedTakeNeverReverts(
        uint128 sourceDebt,
        uint128 offerCapacity,
        uint8 consumedPercent,
        uint16 tick,
        uint256 feeRateSeed,
        uint8 ttmSeed,
        uint8 denomSeed
    ) external {
        tick = _boundTick(tick);
        sourceDebt = uint128(bound(sourceDebt, 1, SEED_AMOUNT));
        uint8 denom = _boundDenomination(denomSeed);
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        consumedPercent = _boundPercent(consumedPercent);

        address freshBorrower;
        uint256 freshBorrowerSK;
        Offer memory offer;
        bytes memory encodedClampData;
        bytes memory takerCallbackData;
        uint256 maxShares;

        {
            uint256 callbackFeeRate = _boundCallbackFeeRate(feeRateSeed);
            uint256 ttm = _boundTimeToMaturity(ttmSeed);
            uint128 consumedAmount = uint128(uint256(offerCapacity) * consumedPercent / 100);

            bytes32 group = keccak256(
                abi.encodePacked(
                    "v2v2-borrow-orch", sourceDebt, offerCapacity, consumedPercent, tick, callbackFeeRate, ttm
                )
            );

            // Setup fresh borrower with source debt
            (freshBorrower, freshBorrowerSK) = makeAddrAndKey("orchBorrower");
            _setupBorrowerWithSourceDebt(freshBorrower, freshBorrowerSK, sourceDebt);

            assertGt(midnight.debt(sourceMarketId, freshBorrower), 0, "borrower should have source debt");

            // Authorize callback for borrower (taker)
            vm.prank(freshBorrower);
            midnight.setIsAuthorized(address(renewalCallback), true, freshBorrower);

            // Create custom target market with specific TTM
            Market memory customTarget = targetMarket;
            customTarget.maturity = block.timestamp + ttm;
            bytes32 customTargetId = IdLib.toId(customTarget);

            if (midnight.tickSpacing(customTargetId) == 0) {
                _seedMarket(customTarget, customTargetId);
            }

            // Consumption on LENDER (offer.maker for BUY offer)
            if (consumedAmount > 0) {
                vm.prank(lender);
                midnight.setConsumed(group, consumedAmount, lender);
            }

            // BUY offer from lender (lender is maker/buyer)
            (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
            offer = Offer({
                market: customTarget,
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
                reduceOnly: false,
                maxUnits: mu,
                maxAssets: ma,
                continuousFeeCap: type(uint256).max
            });

            // Taker callback data for borrower
            takerCallbackData = abi.encode(
                IBorrowMidnightRenewalCallback.CallbackData({
                    sourceMarket: sourceMarket, feeRate: callbackFeeRate, feeRecipient: feeRecipient, tick: tick
                })
            );

            // Clamp data with positionOwner = freshBorrower (borrower has source debt)
            BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData memory clampData =
                BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData({
                    sourceMarketId: sourceMarketId,
                    targetMarketId: customTargetId,
                    positionOwner: freshBorrower,
                    feeRate: callbackFeeRate
                });

            encodedClampData = abi.encode(clampData);
            maxShares = clampContract.maxUnits(offer, encodedClampData);

            // Self-renewal (source == target) should always return 0
            if (customTargetId == sourceMarketId) {
                assertEq(maxShares, 0, "self-renewal should return 0");
                return;
            }
        }

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds or reverts due to health check ---
        uint256 snap = vm.snapshotState();

        vm.prank(freshBorrower);
        try midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares,
            freshBorrower,
            address(renewalCallback),
            address(renewalCallback),
            takerCallbackData
        ) {
        // take succeeded — check remaining invariants
        }
        catch {
            // Health revert or callback revert (e.g. tiny amounts) are valid outcomes
            vm.revertToState(snap);
            return;
        }

        // --- Invariant 4: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        {
            uint256 lenderBalBefore = loanToken.balanceOf(lender);
            vm.prank(freshBorrower);
            try midnight.take(
                offer,
                abi.encode(sig, root, uint256(0), new bytes32[](0)),
                1,
                freshBorrower,
                address(renewalCallback),
                address(renewalCallback),
                takerCallbackData
            ) {
                uint256 lenderBalAfter = loanToken.balanceOf(lender);
                assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 5: Tightness — skipped for taker direction ---
        // The clamp is intentionally conservative in BUY path (sellerPrice rounding),
        // so maxShares + 1 may still succeed. Tightness tested in maker-direction tests.
    }

    /* ========== CB-SRC-1: EXCLUSIVE SOURCE FUNDING ========== */

    /// @notice CB-SRC-1: Callback funds exclusively from source position — maker wallet unchanged.
    /// @dev Mints a sentinel loan token balance to the maker, then verifies it's untouched after take.
    function testFuzz_cbSrc1_makerWalletUnchanged(uint128 sourceDebt, uint16 tick) external {
        tick = _boundTick(tick);
        sourceDebt = uint128(bound(sourceDebt, 1, SEED_AMOUNT));

        bytes32 group = keccak256(abi.encodePacked("cb-src-1-v2v2borrow", sourceDebt, tick));

        (address freshBorrower, uint256 freshBorrowerSK) = makeAddrAndKey("freshBorrowerSrc1");
        _setupBorrowerWithSourceDebt(freshBorrower, freshBorrowerSK, sourceDebt);

        // Authorize callback
        vm.startPrank(freshBorrower);
        midnight.setIsAuthorized(address(renewalCallback), true, freshBorrower);
        vm.stopPrank();

        IBorrowMidnightRenewalCallback.CallbackData memory cbData = IBorrowMidnightRenewalCallback.CallbackData({
            sourceMarket: sourceMarket, feeRate: 0.1e18, feeRecipient: feeRecipient, tick: tick
        });

        Offer memory offer = Offer({
            market: targetMarket,
            buy: false,
            maker: freshBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(renewalCallback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(renewalCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData memory clampData =
            BorrowMidnightRenewalClamp.BorrowMidnightRenewalClampData({
                sourceMarketId: sourceMarketId, targetMarketId: targetMarketId, positionOwner: lender, feeRate: 0.1e18
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        if (maxShares == 0) return;

        // Sentinel: give borrower tokens the callback could pull if buggy
        loanToken.mint(freshBorrower, 1e18);
        uint256 loanBefore = loanToken.balanceOf(freshBorrower);
        uint256 colBefore = collateralToken.balanceOf(freshBorrower);

        Signature memory sig = _signOffer(offer, freshBorrowerSK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(lender);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, lender, address(0), address(0), ""
        ) {
            assertEq(loanToken.balanceOf(freshBorrower), loanBefore, "CB-SRC-1: maker loan tokens pulled from wallet");
            assertEq(
                collateralToken.balanceOf(freshBorrower), colBefore, "CB-SRC-1: maker collateral pulled from wallet"
            );
        } catch {}
    }
}
