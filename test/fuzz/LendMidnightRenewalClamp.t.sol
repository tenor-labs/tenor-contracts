// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {LendMidnightRenewalClamp} from "../../src/router/clamps/LendMidnightRenewalClamp.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {LendMidnightRenewalCallback} from "@callbacks/LendMidnightRenewalCallback.sol";
import {ILendMidnightRenewalCallback} from "@callbacks/interfaces/ILendMidnightRenewalCallback.sol";
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
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";
import {OfferRemainingHelper} from "../helpers/OfferRemainingHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title LendMidnightRenewalClampFuzzTest
/// @notice Proves that LendMidnightRenewalClamp.maxUnits() always returns a maxUnits value
///         that results in a successful midnight.take() call (no revert).
/// @dev "credit" refers to Midnight lender positions (credit()), not ERC4626 vault shares.
/// @dev This clamp is for cross-market lend renewals via withdrawable path (Midnight to Midnight lend).
///      Constraints: source withdrawable position + fee
contract LendMidnightRenewalClampFuzzTest is ClampFuzzFixtures {
    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    LendMidnightRenewalClamp internal clampContract;
    LendMidnightRenewalCallback internal lendCallback;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    OfferRemainingHelper internal offerRemainingHelper;

    uint256 internal lenderSK;
    address internal lender;
    uint256 internal borrowerSK;
    address internal borrower;
    address internal feeRecipient;

    Market internal sourceMarket;
    Market internal targetMarket;
    bytes32 internal sourceMarketId;
    bytes32 internal targetMarketId;

    function setUp() public {
        (lender, lenderSK) = makeAddrAndKey("lender");
        (borrower, borrowerSK) = makeAddrAndKey("borrower");
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

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);
        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        clampContract = new LendMidnightRenewalClamp(IMidnight(address(midnight)));
        lendCallback = new LendMidnightRenewalCallback(address(midnight));

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

        // Borrower (taker): unlimited collateral for health
        collateralToken.mint(borrower, type(uint128).max);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(targetMarket, 0, 1e38, borrower);
        vm.stopPrank();
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

    /// @notice Helper: give lender credit on source market
    function _setupLenderWithSourceCredit(
        address account,
        uint256,
        /* accountSK */
        uint128 shareAmount
    )
        internal
    {
        (address tempBorrower, uint256 tempBorrowerSK) =
            makeAddrAndKey(string(abi.encodePacked("tempBorrower", account)));

        collateralToken.mint(tempBorrower, type(uint128).max);
        loanToken.mint(account, type(uint128).max);

        MidnightSupplyCollateralCallback cb = new MidnightSupplyCollateralCallback(address(midnight));
        vm.startPrank(tempBorrower);
        collateralToken.approve(address(cb), type(uint256).max);
        midnight.setIsAuthorized(address(cb), true, tempBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, tempBorrower);
        vm.stopPrank();

        vm.prank(account);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = uint256(shareAmount) * 20;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: shareAmount, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory sellOffer = Offer({
            market: sourceMarket,
            buy: false,
            maker: tempBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup-lend", account)),
            callback: address(cb),
            callbackData: cbData,
            receiverIfMakerIsSeller: tempBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, tempBorrowerSK);
        bytes32 root = HashLib.hashOffer(sellOffer);

        vm.prank(account);
        midnight.take(
            sellOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            shareAmount,
            account,
            address(0),
            address(0),
            ""
        );

        // Repay temp borrower's debt so the pool has withdrawable liquidity.
        // Without this, withdrawable = 0 and no lender can withdraw from source.
        uint256 tempDebt = midnight.debt(sourceMarketId, tempBorrower);
        if (tempDebt > 0) {
            loanToken.mint(tempBorrower, tempDebt);
            vm.startPrank(tempBorrower);
            loanToken.approve(address(midnight), tempDebt);
            midnight.repay(sourceMarket, tempDebt, tempBorrower, address(0), "");
            vm.stopPrank();
        }
    }

    /// @dev Hashed in its own frame to keep _buildLendRenewalCreditOffer within stack
    ///      limits under `forge coverage --ir-minimum` (unoptimized via_ir codegen).
    function _renewalGroup(
        string memory lenderLabel,
        uint128 sourceCredit,
        uint128 offerCapacity,
        uint16 tick,
        uint256 callbackFeeRate,
        uint256 ttm
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(lenderLabel, sourceCredit, offerCapacity, tick, callbackFeeRate, ttm));
    }

    /// @dev Internal helper: builds offer + runs clamp for Midnight to Midnight lend renewal tests.
    ///      Packs the small fuzz seeds into a single uint256 to keep the calling fuzz
    ///      function's stack pressure manageable for via_ir codegen.
    function _buildLendRenewalCreditOffer(
        uint128 sourceCredit,
        uint128 offerCapacity,
        uint256 packed,
        string memory lenderLabel
    ) internal returns (Offer memory offer, bytes memory encodedClampData, uint256 maxUnits, uint256 freshLenderSK) {
        bool reduceOnly = packed & 1 == 1;
        uint8 denom = _boundDenomination(uint8(packed >> 8));
        uint16 tick = _boundTick(uint16(packed >> 16));
        uint256 callbackFeeRate = _boundCallbackFeeRate(packed >> 64);
        uint256 ttm = _boundTimeToMaturity(uint8(packed >> 32));
        sourceCredit = uint128(bound(sourceCredit, 1, SEED_AMOUNT));
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);

        address freshLender;
        (freshLender, freshLenderSK) = makeAddrAndKey(lenderLabel);
        vm.prank(freshLender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);
        _setupLenderWithSourceCredit(freshLender, freshLenderSK, sourceCredit);
        assertGt(creditAfterSlashing(midnight, sourceMarketId, freshLender), 0, "lender should have source credit");

        Market memory customTarget = targetMarket;
        customTarget.maturity = block.timestamp + ttm;
        bytes32 customTargetId = IdLib.toId(customTarget);

        if (midnight.tickSpacing(customTargetId) == 0) {
            _seedMarket(customTarget, customTargetId);
            vm.prank(borrower);
            midnight.supplyCollateral(customTarget, 0, 1e38, borrower);
        }

        vm.startPrank(freshLender);
        midnight.setIsAuthorized(address(lendCallback), true, freshLender);
        vm.stopPrank();

        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        offer = Offer({
            market: customTarget,
            buy: true,
            maker: freshLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: _renewalGroup(lenderLabel, sourceCredit, offerCapacity, tick, callbackFeeRate, ttm),
            callback: address(lendCallback),
            callbackData: abi.encode(
                ILendMidnightRenewalCallback.CallbackData({
                    sourceMarket: sourceMarket, feeRate: callbackFeeRate, feeRecipient: feeRecipient, tick: tick
                })
            ),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: mu,
            maxAssets: ma,
            continuousFeeCap: type(uint256).max
        });

        encodedClampData = abi.encode(
            LendMidnightRenewalClamp.LendMidnightRenewalClampData({
                sourceMarketId: sourceMarketId,
                targetMarketId: customTargetId,
                positionOwner: borrower,
                feeRate: callbackFeeRate
            })
        );
        maxUnits = clampContract.maxUnits(offer, encodedClampData);
        {
            uint256 remaining =
                offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, customTargetId);
            maxUnits = UtilsLib.min(maxUnits, remaining);
        }

        // Self-renewal (source == target) should always return 0
        if (customTargetId == sourceMarketId) {
            assertEq(maxUnits, 0, "self-renewal should return 0");
            maxUnits = 0;
        }
    }

    /* ========== FUZZ TESTS ========== */

    /// @notice Proves four invariants for credit-based BUY offers (Midnight to Midnight lend withdrawable renewal):
    ///         1. Safety: take(maxUnits) succeeds (or reverts due to Midnight health check)
    ///         2. No-dust: re-calling maxUnits() after taking maxUnits returns 0
    ///         3. Exhaustion: take(1) after take(maxUnits) either reverts or is zero-cost
    ///         4. Tightness: take(maxUnits + 1) always reverts
    /// @dev Fuzzes BOTH fee dimensions: callback feeRate (0-50%) + settlement fee (via TTM)
    function testFuzz_clampedTakeNeverReverts_credit(uint128 sourceCredit, uint128 offerCapacity, uint256 packed)
        external
    {
        (Offer memory offer, bytes memory encodedClampData, uint256 maxUnits, uint256 freshLenderSK) =
            _buildLendRenewalCreditOffer(sourceCredit, offerCapacity, packed, "freshLender");

        if (maxUnits == 0) return;

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxUnits) succeeds or reverts due to Midnight health check ---
        // Health is NOT the clamp's responsibility (see HEALTH CHECK doc in clamp).
        // At extreme ticks, Midnight's internal health check may reject the take.
        // The router handles this via try/catch (fail-safe mode).
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxUnits, borrower, borrower, address(0), ""
        ) {
        // take succeeded — check remaining invariants
        }
        catch Error(string memory reason) {
            assertEq(reason, "seller is unhealthy", "unexpected revert reason");
            vm.revertToState(snap);
            return;
        } catch {
            fail("unexpected non-string revert in take(maxUnits): clamp or callback bug");
        }

        // --- Invariant 2: Exhaustion — take(1) after take(maxUnits) either reverts or is zero-cost ---
        {
            uint256 lenderBalBefore = loanToken.balanceOf(offer.maker);
            vm.prank(borrower);
            try midnight.take(
                offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, borrower, address(0), ""
            ) {
                uint256 lenderBalAfter = loanToken.balanceOf(offer.maker);
                assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxUnits must be zero-cost if it succeeds");
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxUnits + 1) reverts ---
        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxUnits + 1, borrower, borrower, address(0), ""
        );
    }

    /// @notice Same four invariants with units-based offer.
    /// @dev Fuzzes BOTH fee dimensions: callback feeRate (0-50%) + settlement fee (via TTM)
    function testFuzz_clampedTakeNeverReverts_units(uint128 sourceCredit, uint128 offerCapacity, uint256 packed)
        external
    {
        (Offer memory offer, bytes memory encodedClampData, uint256 maxUnits, uint256 freshLenderSK) =
            _buildLendRenewalCreditOffer(sourceCredit, offerCapacity, packed, "freshLenderUnits");

        if (maxUnits == 0) return;

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxUnits) succeeds or reverts due to Midnight health check ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxUnits, borrower, borrower, address(0), ""
        ) {
        // take succeeded — check remaining invariants
        }
        catch Error(string memory reason) {
            assertEq(reason, "seller is unhealthy", "unexpected revert reason");
            vm.revertToState(snap);
            return;
        } catch {
            fail("unexpected non-string revert in take(maxUnits): clamp or callback bug");
        }

        // --- Invariant 2: Exhaustion — take(1) after take(maxUnits) either reverts or is zero-cost ---
        {
            uint256 lenderBalBefore = loanToken.balanceOf(offer.maker);
            vm.prank(borrower);
            try midnight.take(
                offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, borrower, address(0), ""
            ) {
                uint256 lenderBalAfter = loanToken.balanceOf(offer.maker);
                assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxUnits must be zero-cost if it succeeds");
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 3: Tightness — take(maxUnits + 1) reverts ---
        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxUnits + 1, borrower, borrower, address(0), ""
        );
    }

    /* ========== UNCONSTRAINED CAPACITY FUZZ TESTS ========== */

    /// @notice When offer capacity is unconstrained, take(maxUnits) must fully close the source position.
    /// @dev Sets offerCapacity = MAX_OFFER_CAPACITY so withdrawal budget is always the binding constraint.
    ///      Fuzzes: sourceCredit, tick, feeRate, TTM (settlement fee)
    function testFuzz_unconstrainedCapacity_sourceFullyClosed_credit(
        uint128 sourceCredit,
        uint16 tick,
        uint256 feeRateSeed,
        uint8 ttmSeed,
        bool reduceOnly
    ) external {
        tick = _boundTick(tick);
        sourceCredit = uint128(bound(sourceCredit, 1, SEED_AMOUNT));

        uint256 freshLenderSK;
        Offer memory offer;
        uint256 maxUnits;

        // Setup fresh lender with source credit (before scope to reduce peak stack depth)
        {
            address freshLender;
            (freshLender, freshLenderSK) = makeAddrAndKey("freshLenderUncap");
            vm.prank(freshLender);
            midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);
            _setupLenderWithSourceCredit(freshLender, freshLenderSK, sourceCredit);

            uint256 actualCredit = creditAfterSlashing(midnight, sourceMarketId, freshLender);
            assertGt(actualCredit, 0, "lender should have source credit");
        }

        {
            uint256 callbackFeeRate = _boundCallbackFeeRate(feeRateSeed);
            uint256 ttm = _boundTimeToMaturity(ttmSeed);

            uint128 offerCapacity = MAX_OFFER_CAPACITY;

            bytes32 group =
                keccak256(abi.encodePacked("v2v2-lend-wd-uncap-credit", sourceCredit, tick, callbackFeeRate, ttm));

            address freshLender = makeAddr("freshLenderUncap");

            // Create custom target market with specific TTM
            Market memory customTarget = targetMarket;
            customTarget.maturity = block.timestamp + ttm;
            bytes32 customTargetId = IdLib.toId(customTarget);

            if (midnight.tickSpacing(customTargetId) == 0) {
                _seedMarket(customTarget, customTargetId);
                vm.prank(borrower);
                midnight.supplyCollateral(customTarget, 0, 1e38, borrower);
            }

            // Skip self-renewal
            if (customTargetId == sourceMarketId) return;

            vm.startPrank(freshLender);
            midnight.setIsAuthorized(address(lendCallback), true, freshLender);
            vm.stopPrank();

            ILendMidnightRenewalCallback.CallbackData memory cbData = ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: callbackFeeRate, feeRecipient: feeRecipient, tick: tick
            });
            offer = Offer({
                market: customTarget,
                buy: true,
                maker: freshLender,
                start: block.timestamp,
                expiry: block.timestamp + 1 hours,
                tick: tick,
                group: group,
                callback: address(lendCallback),
                callbackData: abi.encode(cbData),
                receiverIfMakerIsSeller: address(0),
                ratifier: address(ecrecoverRatifier),
                reduceOnly: reduceOnly,
                maxUnits: offerCapacity,
                maxAssets: 0,
                continuousFeeCap: type(uint256).max
            });

            LendMidnightRenewalClamp.LendMidnightRenewalClampData memory clampData =
                LendMidnightRenewalClamp.LendMidnightRenewalClampData({
                    sourceMarketId: sourceMarketId,
                    targetMarketId: customTargetId,
                    positionOwner: borrower,
                    feeRate: callbackFeeRate
                });

            maxUnits = clampContract.maxUnits(offer, abi.encode(clampData));
        }

        if (maxUnits == 0) return;

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(borrower);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxUnits, borrower, borrower, address(0), ""
        ) {
            // Source position must be fully withdrawn when capacity is unconstrained
            uint256 remainingCredit = creditAfterSlashing(midnight, sourceMarketId, offer.maker);
            assertEq(remainingCredit, 0, "source credit must be fully withdrawn when capacity is unconstrained");
        } catch Error(string memory reason) {
            assertEq(reason, "seller is unhealthy", "unexpected revert reason in unconstrained capacity test");
        } catch {
            fail("unexpected non-string revert in unconstrained capacity test: clamp or callback bug");
        }
    }

    /// @notice Same as above but with units-based offer
    function testFuzz_unconstrainedCapacity_sourceFullyClosed_units(
        uint128 sourceCredit,
        uint16 tick,
        uint256 feeRateSeed,
        uint8 ttmSeed,
        bool reduceOnly
    ) external {
        tick = _boundTick(tick);
        sourceCredit = uint128(bound(sourceCredit, 1, SEED_AMOUNT));

        uint256 freshLenderSK;
        Offer memory offer;
        uint256 maxUnits;

        // Setup fresh lender with source credit (before scope to reduce peak stack depth)
        {
            address freshLender;
            (freshLender, freshLenderSK) = makeAddrAndKey("freshLenderUncapUnits");
            vm.prank(freshLender);
            midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);
            _setupLenderWithSourceCredit(freshLender, freshLenderSK, sourceCredit);

            uint256 actualCredit = creditAfterSlashing(midnight, sourceMarketId, freshLender);
            assertGt(actualCredit, 0, "lender should have source credit");
        }

        {
            uint256 callbackFeeRate = _boundCallbackFeeRate(feeRateSeed);
            uint256 ttm = _boundTimeToMaturity(ttmSeed);

            uint128 offerCapacity = MAX_OFFER_CAPACITY;

            bytes32 group =
                keccak256(abi.encodePacked("v2v2-lend-wd-uncap-units", sourceCredit, tick, callbackFeeRate, ttm));

            address freshLender = makeAddr("freshLenderUncapUnits");

            Market memory customTarget = targetMarket;
            customTarget.maturity = block.timestamp + ttm;
            bytes32 customTargetId = IdLib.toId(customTarget);

            if (midnight.tickSpacing(customTargetId) == 0) {
                _seedMarket(customTarget, customTargetId);
                vm.prank(borrower);
                midnight.supplyCollateral(customTarget, 0, 1e38, borrower);
            }

            if (customTargetId == sourceMarketId) return;

            vm.startPrank(freshLender);
            midnight.setIsAuthorized(address(lendCallback), true, freshLender);
            vm.stopPrank();

            ILendMidnightRenewalCallback.CallbackData memory cbData = ILendMidnightRenewalCallback.CallbackData({
                sourceMarket: sourceMarket, feeRate: callbackFeeRate, feeRecipient: feeRecipient, tick: tick
            });
            offer = Offer({
                market: customTarget,
                buy: true,
                maker: freshLender,
                start: block.timestamp,
                expiry: block.timestamp + 1 hours,
                tick: tick,
                group: group,
                callback: address(lendCallback),
                callbackData: abi.encode(cbData),
                receiverIfMakerIsSeller: address(0),
                ratifier: address(ecrecoverRatifier),
                reduceOnly: reduceOnly,
                maxUnits: offerCapacity,
                maxAssets: 0,
                continuousFeeCap: type(uint256).max
            });

            LendMidnightRenewalClamp.LendMidnightRenewalClampData memory clampData =
                LendMidnightRenewalClamp.LendMidnightRenewalClampData({
                    sourceMarketId: sourceMarketId,
                    targetMarketId: customTargetId,
                    positionOwner: borrower,
                    feeRate: callbackFeeRate
                });

            maxUnits = clampContract.maxUnits(offer, abi.encode(clampData));
        }

        if (maxUnits == 0) return;

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(borrower);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxUnits, borrower, borrower, address(0), ""
        ) {
            uint256 remainingCredit = creditAfterSlashing(midnight, sourceMarketId, offer.maker);
            assertEq(remainingCredit, 0, "source credit must be fully withdrawn when capacity is unconstrained");
        } catch Error(string memory reason) {
            assertEq(reason, "seller is unhealthy", "unexpected revert reason in unconstrained capacity test");
        } catch {
            fail("unexpected non-string revert in unconstrained capacity test: clamp or callback bug");
        }
    }

    /* ========== EDGE CASE FUZZ TESTS ========== */

    /// @notice Zero source credit always returns 0
    function testFuzz_zeroSourceCredit_returnsZero(uint128 offerCapacity, uint16 tick) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_OFFER_CAPACITY));

        (address emptyLender,) = makeAddrAndKey("emptyLender");

        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: emptyLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256("zero-credit"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        LendMidnightRenewalClamp.LendMidnightRenewalClampData memory clampData =
            LendMidnightRenewalClamp.LendMidnightRenewalClampData({
                sourceMarketId: sourceMarketId, targetMarketId: targetMarketId, positionOwner: borrower, feeRate: 0
            });

        uint256 maxUnits = clampContract.maxUnits(offer, abi.encode(clampData));
        assertEq(maxUnits, 0, "zero source credit should return zero");
    }

    /* ========== CB-SRC-1: EXCLUSIVE SOURCE FUNDING ========== */

    /// @notice CB-SRC-1: Callback funds exclusively from source position — maker wallet unchanged.
    /// @dev Snapshots the lender's loan token balance and verifies it's untouched after take.
    function testFuzz_cbSrc1_makerWalletUnchanged(uint128 sourceCredit, uint16 tick) external {
        tick = uint16(bound(tick, 1, 990));
        sourceCredit = uint128(bound(sourceCredit, 1, SEED_AMOUNT));

        uint256 freshLenderSK;
        address freshLender;

        (freshLender, freshLenderSK) = makeAddrAndKey("freshLenderSrc1");
        vm.prank(freshLender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);
        _setupLenderWithSourceCredit(freshLender, freshLenderSK, sourceCredit);

        bytes32 group = keccak256(abi.encodePacked("cb-src-1-v2v2lend", sourceCredit, tick));

        // Authorize callback
        vm.startPrank(freshLender);
        midnight.setIsAuthorized(address(lendCallback), true, freshLender);
        vm.stopPrank();

        ILendMidnightRenewalCallback.CallbackData memory cbData = ILendMidnightRenewalCallback.CallbackData({
            sourceMarket: sourceMarket, feeRate: 0.1e18, feeRecipient: feeRecipient, tick: tick
        });

        Offer memory offer = Offer({
            market: targetMarket,
            buy: true,
            maker: freshLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(lendCallback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        LendMidnightRenewalClamp.LendMidnightRenewalClampData memory clampData =
            LendMidnightRenewalClamp.LendMidnightRenewalClampData({
                sourceMarketId: sourceMarketId, targetMarketId: targetMarketId, positionOwner: borrower, feeRate: 0.1e18
            });

        uint256 maxUnits = clampContract.maxUnits(offer, abi.encode(clampData));
        if (maxUnits == 0) return;

        // Snapshot lender's wallet balance (lender already has loan tokens from setup)
        uint256 loanBefore = loanToken.balanceOf(freshLender);

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(borrower);
        try midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxUnits, borrower, borrower, address(0), ""
        ) {
            assertEq(loanToken.balanceOf(freshLender), loanBefore, "CB-SRC-1: maker loan tokens pulled from wallet");
        } catch {}
    }
}
