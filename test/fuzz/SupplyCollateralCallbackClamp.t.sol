// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {SupplyCollateralCallbackClamp} from "../../src/router/clamps/SupplyCollateralCallbackClamp.sol";
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
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {TakeMathLib} from "../../src/libraries/TakeMathLib.sol";
import {ClampFuzzFixtures} from "../helpers/ClampFuzzFixtures.sol";
import {OfferRemainingHelper} from "../helpers/OfferRemainingHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title SupplyCollateralCallbackClampFuzzTest
/// @notice Proves that SupplyCollateralCallbackClamp.maxUnits() always returns a maxShares value
///         that results in a successful midnight.take() call (no revert).
/// @dev This clamp is for SELL offers using MidnightSupplyCollateralCallback.
///      The callback supplies collateral pro-rata on take.
///      Fuzz params: offerCapacity, tick, collateral allowance/balance, ttm.
contract SupplyCollateralCallbackClampFuzzTest is ClampFuzzFixtures {
    using UtilsLib for uint256;

    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    SupplyCollateralCallbackClamp internal clampContract;
    MidnightSupplyCollateralCallback internal callback;
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
        oracle.setPrice(10e36); // High price so health is easy to satisfy

        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        offerRemainingHelper = new OfferRemainingHelper();
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        clampContract = new SupplyCollateralCallbackClamp(IMidnight(address(midnight)));
        callback = new MidnightSupplyCollateralCallback(address(midnight));

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

        // Lender (buyer/taker): unlimited balance and allowance
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
            maxUnits: 0,
            maxAssets: type(uint128).max,
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

    /// @notice Build callback data for a SELL offer using MidnightSupplyCollateralCallback
    function _buildCallbackData(uint256 collateralForFull, uint256 offerSellerAssets)
        internal
        pure
        returns (bytes memory)
    {
        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = collateralForFull;

        return abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: offerSellerAssets, maxBorrowCapacityUsage: 0
            })
        );
    }

    /// @notice Seed an market with initial totalUnits
    function _seedMarketCustom(Market memory obl, bytes32 oblId) internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("seedBorrowerCustom");
        address seedLender = makeAddr("seedLenderCustom");

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
            market: obl,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("seed", oblId)),
            callback: address(setupCb),
            callbackData: cbData,
            receiverIfMakerIsSeller: seedBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: type(uint128).max,
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

    /* ========== HELPERS ========== */

    function _clampAndCap(Offer memory offer, bytes memory encodedClampData, bytes32 oblId)
        internal
        view
        returns (uint256)
    {
        uint256 maxShares = clampContract.maxUnits(offer, encodedClampData);
        uint256 remaining = offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, oblId);
        return UtilsLib.min(maxShares, remaining);
    }

    /* ========== FUZZ TESTS ========== */

    /// @notice Four invariants — offer uses maxSellerAssets denomination.
    function testFuzz_clampedTakeNeverReverts_sellerAssets(
        uint128 offerCapacity,
        uint128 collateralAvailable,
        uint16 tick,
        bool reduceOnly
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_ASSET_DENOMINATED_CAPACITY));
        collateralAvailable = uint128(bound(collateralAvailable, offerCapacity, type(uint128).max));
        _runSellerAssetsFuzz(offerCapacity, collateralAvailable, tick, reduceOnly);
    }

    function _runSellerAssetsFuzz(uint128 offerCapacity, uint128 collateralAvailable, uint16 tick, bool reduceOnly)
        internal
    {
        (address freshBorrower, uint256 freshBorrowerSK) = makeAddrAndKey("freshBorrowerSA");
        _seedFreshBorrower(freshBorrower, collateralAvailable);

        Offer memory offer = _buildSellOffer(
            market,
            freshBorrower,
            offerCapacity,
            tick,
            reduceOnly,
            keccak256(abi.encodePacked("col-sa", offerCapacity, collateralAvailable, tick))
        );

        uint256 maxShares = _clampShares(offer, offerCapacity, marketId);
        if (maxShares == 0) return;

        bytes memory ratifierData =
            abi.encode(_signOffer(offer, freshBorrowerSK), HashLib.hashOffer(offer), uint256(0), new bytes32[](0));

        _runSafetyAndTightness(offer, ratifierData, maxShares, freshBorrower);
    }

    function _seedFreshBorrower(address freshBorrower, uint128 collateralAvailable) internal {
        collateralToken.mint(freshBorrower, collateralAvailable);
        vm.startPrank(freshBorrower);
        collateralToken.approve(address(callback), collateralAvailable);
        midnight.setIsAuthorized(address(callback), true, freshBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshBorrower);
        vm.stopPrank();
    }

    function _runSafetyAndTightness(Offer memory offer, bytes memory ratifierData, uint256 maxShares, address recv)
        internal
    {
        uint256 snap = vm.snapshotState();

        vm.prank(lender);
        midnight.take(offer, ratifierData, maxShares, lender, address(0), address(0), "");

        vm.revertToState(snap);

        vm.prank(lender);
        vm.expectRevert();
        midnight.take(offer, ratifierData, maxShares + 1, lender, address(0), address(0), "");
    }

    /// @notice Proves three invariants for maxSellerAssets SELL offers with collateral callback.
    ///         Fuzzes time-to-maturity to cover all 8 Midnight settlement fee breakpoints.
    ///         1. Safety: take(maxShares) never reverts
    ///         2. Exhaustion: take(1) after take(maxShares) either reverts or is zero-cost
    ///         3. Tightness: take(maxShares + 1) always reverts
    function testFuzz_clampedTakeNeverReverts_sellerAssets_ttm(
        uint128 offerCapacity,
        uint128 collateralAvailable,
        uint16 tick,
        uint8 ttmSeed,
        bool reduceOnly
    ) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_ASSET_DENOMINATED_CAPACITY));
        collateralAvailable = uint128(bound(collateralAvailable, offerCapacity, type(uint128).max));
        _runTtmFuzz(offerCapacity, collateralAvailable, tick, ttmSeed, reduceOnly);
    }

    function _runTtmFuzz(
        uint128 offerCapacity,
        uint128 collateralAvailable,
        uint16 tick,
        uint8 ttmSeed,
        bool reduceOnly
    ) internal {
        Market memory testMarket = _buildTtmMarket(_boundTimeToMaturity(ttmSeed));
        bytes32 testMarketId = IdLib.toId(testMarket);
        _seedMarketCustom(testMarket, testMarketId);

        (address freshBorrower, uint256 freshBorrowerSK) = makeAddrAndKey("freshBorrower");
        _seedFreshBorrower(freshBorrower, collateralAvailable);

        Offer memory offer = _buildSellOffer(
            testMarket,
            freshBorrower,
            offerCapacity,
            tick,
            reduceOnly,
            keccak256(abi.encodePacked("col-sa-ttm", offerCapacity, collateralAvailable, tick, ttmSeed))
        );

        uint256 maxShares = _clampShares(offer, offerCapacity, testMarketId);
        if (maxShares == 0) return;

        bytes memory ratifierData =
            abi.encode(_signOffer(offer, freshBorrowerSK), HashLib.hashOffer(offer), uint256(0), new bytes32[](0));

        _runAllInvariants(offer, ratifierData, maxShares, freshBorrower);
    }

    function _buildTtmMarket(uint256 ttm) internal view returns (Market memory) {
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });
        return Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + ttm,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    /// @dev `_buildCallbackData(offerCapacity, offerCapacity)`: 1:1 collateral-to-sellerAssets ratio
    ///      keeps the health model trivially satisfied (oracle 10x × lltv 0.945 → 9.45x coverage).
    function _buildSellOffer(
        Market memory mkt,
        address freshBorrower,
        uint128 offerCapacity,
        uint16 tick,
        bool reduceOnly,
        bytes32 group
    ) internal view returns (Offer memory) {
        return Offer({
            market: mkt,
            buy: false,
            maker: freshBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(callback),
            callbackData: _buildCallbackData(offerCapacity, offerCapacity),
            receiverIfMakerIsSeller: freshBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: reduceOnly,
            maxUnits: 0,
            maxAssets: offerCapacity,
            continuousFeeCap: type(uint256).max
        });
    }

    function _clampShares(Offer memory offer, uint128, bytes32 oblId) internal view returns (uint256) {
        return _clampAndCap(
            offer, abi.encode(SupplyCollateralCallbackClamp.ClampData({marketId: oblId, taker: lender})), oblId
        );
    }

    function _runAllInvariants(Offer memory offer, bytes memory ratifierData, uint256 maxShares, address recv)
        internal
    {
        uint256 snap = vm.snapshotState();

        vm.prank(lender);
        midnight.take(offer, ratifierData, maxShares, lender, address(0), address(0), "");

        uint256 lenderBalBefore = loanToken.balanceOf(lender);
        vm.prank(lender);
        try midnight.take(offer, ratifierData, 1, lender, address(0), address(0), "") {
            uint256 lenderBalAfter = loanToken.balanceOf(lender);
            assertEq(lenderBalBefore, lenderBalAfter, "take(1) after maxShares must be zero-cost if it succeeds");
        } catch {}

        vm.revertToState(snap);

        vm.prank(lender);
        vm.expectRevert();
        midnight.take(offer, ratifierData, maxShares + 1, lender, address(0), address(0), "");
    }
}
