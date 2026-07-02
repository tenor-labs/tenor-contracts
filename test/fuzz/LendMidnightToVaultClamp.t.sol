// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {LendMidnightToVaultClamp} from "../../src/router/clamps/LendMidnightToVaultClamp.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {MockERC4626} from "../helpers/mocks/MockERC4626.sol";
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

/// @title LendMidnightToVaultClampFuzzTest
/// @notice Proves that LendMidnightToVaultClamp.maxUnits() always returns a maxShares value
///         that results in a successful midnight.take() call (no revert).
/// @dev This clamp is for Midnight to Vault lend exit.
///      Constraints: offer consumption + source withdrawable position + vault deposit capacity
contract LendMidnightToVaultClampFuzzTest is ClampFuzzFixtures {
    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    LendMidnightToVaultClamp internal clampContract;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC4626 internal targetVault;
    Oracle internal oracle;
    OfferRemainingHelper internal offerRemainingHelper;

    uint256 internal lenderSK;
    address internal lender;
    uint256 internal borrowerSK;
    address internal borrower;

    Market internal sourceMarket;
    bytes32 internal sourceMarketId;

    function setUp() public {
        (lender, lenderSK) = makeAddrAndKey("lender");
        (borrower, borrowerSK) = makeAddrAndKey("borrower");

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        targetVault = new MockERC4626(address(loanToken), "Vault", "vLOAN");
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

        clampContract = new LendMidnightToVaultClamp(IMidnight(address(midnight)));

        // Create Midnight source market
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
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        sourceMarketId = IdLib.toId(sourceMarket);

        _seedSourceMarket();

        // Borrower (taker): unlimited collateral for health + loan tokens for buying
        collateralToken.mint(borrower, 1e38);
        loanToken.mint(borrower, type(uint128).max);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(sourceMarket, 0, 1e38, borrower);
        vm.stopPrank();
    }

    /* ========== SETUP HELPERS ========== */

    function _seedSourceMarket() internal {
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
            market: sourceMarket,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("seed-v2"),
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

    function _seedMarket(Market memory market, bytes32 marketId) internal {
        (address seedBorrower2, uint256 seedBorrowerSK2) = makeAddrAndKey(string(abi.encodePacked("seed2", marketId)));
        address seedLender2 = makeAddr(string(abi.encodePacked("lender2", marketId)));

        loanToken.mint(seedLender2, type(uint128).max);
        collateralToken.mint(seedBorrower2, type(uint128).max);

        MidnightSupplyCollateralCallback setupCb2 = new MidnightSupplyCollateralCallback(address(midnight));

        vm.startPrank(seedBorrower2);
        collateralToken.approve(address(setupCb2), type(uint256).max);
        midnight.setIsAuthorized(address(setupCb2), true, seedBorrower2);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower2);
        vm.stopPrank();

        vm.prank(seedLender2);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts2 = new uint256[](1);
        colAmounts2[0] = SEED_AMOUNT * 10;
        bytes memory cbData2 = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts2, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory seedOffer2 = Offer({
            market: market,
            buy: false,
            maker: seedBorrower2,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("seed2", marketId)),
            callback: address(setupCb2),
            callbackData: cbData2,
            receiverIfMakerIsSeller: seedBorrower2,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig2 = _signOffer(seedOffer2, seedBorrowerSK2);
        bytes32 root2 = HashLib.hashOffer(seedOffer2);
        uint256 shares2 = SEED_AMOUNT;

        vm.prank(seedLender2);
        midnight.take(
            seedOffer2,
            abi.encode(sig2, root2, uint256(0), new bytes32[](0)),
            shares2,
            seedLender2,
            address(0),
            address(0),
            ""
        );
    }

    /// @notice Helper: give lender shares on any market
    function _setupLenderWithShares(
        address account,
        uint256, /* accountSK */
        uint128 shareAmount,
        Market memory market,
        bytes32 marketId
    ) internal {
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

        {
            uint256[] memory colAmounts = new uint256[](1);
            colAmounts[0] = uint256(shareAmount) * 20;
            bytes memory cbData = abi.encode(
                IMidnightSupplyCollateralCallback.CallbackData({
                    amounts: colAmounts, offerSellerAssets: shareAmount, maxBorrowCapacityUsage: 0
                })
            );

            Offer memory sellOffer = Offer({
                market: market,
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

            bytes memory ratifierData = abi.encode(
                _signOffer(sellOffer, tempBorrowerSK), HashLib.hashOffer(sellOffer), uint256(0), new bytes32[](0)
            );

            vm.prank(account);
            midnight.take(sellOffer, ratifierData, shareAmount, account, address(0), address(0), "");
        }
    }

    /* ========== FUZZ TESTS ========== */

    /// @dev Internal helper: builds offer + runs clamp for Midnight to Vault lend tests.
    function _buildMidnightToVaultLendOffer(uint128 offerCapacity, uint256 packed, string memory lenderLabel)
        internal
        returns (uint256 freshLenderSK, Offer memory offer, bytes memory encodedClampData, uint256 maxShares)
    {
        (freshLenderSK, offer, encodedClampData) =
            _buildMidnightToVaultLendOfferInner(offerCapacity, packed, lenderLabel);

        maxShares = clampContract.maxUnits(offer, encodedClampData);
        // Cap by offer remaining (simulates TenorRouter's structural consumed check)
        {
            uint256 remaining =
                offerRemainingHelper.getOfferRemaining(IMidnight(address(midnight)), offer, IdLib.toId(offer.market));
            maxShares = UtilsLib.min(maxShares, remaining);
        }
    }

    function _buildMidnightToVaultLendOfferInner(uint128 offerCapacity, uint256 packed, string memory lenderLabel)
        internal
        returns (uint256 freshLenderSK, Offer memory offer, bytes memory encodedClampData)
    {
        uint16 tick = _boundTick(uint16(packed >> 16));
        uint128 sourceShares = uint128(bound(uint128(packed >> 128), 1, SEED_AMOUNT));

        Market memory customSource = sourceMarket;
        customSource.maturity = block.timestamp + _boundTimeToMaturity(uint8(packed >> 32));
        bytes32 customSourceId = IdLib.toId(customSource);

        if (midnight.tickSpacing(customSourceId) == 0) {
            _seedMarket(customSource, customSourceId);
            collateralToken.mint(borrower, 1e38);
            vm.prank(borrower);
            midnight.supplyCollateral(customSource, 0, 1e38, borrower);
        }

        address freshLender;
        (freshLender, freshLenderSK) = makeAddrAndKey(lenderLabel);
        vm.prank(freshLender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);
        _setupLenderWithShares(freshLender, freshLenderSK, sourceShares, customSource, customSourceId);

        assertGt(creditAfterSlashing(midnight, customSourceId, freshLender), 0, "lender should have source shares");

        encodedClampData = abi.encode(
            LendMidnightToVaultClamp.LendMidnightToVaultClampData({
                sourceMarketId: customSourceId,
                targetVault: address(targetVault),
                positionOwner: borrower,
                vaultType: LendMidnightToVaultClamp.VaultType.ERC4626
            })
        );

        offer = _makeOffer(
            customSource, freshLender, tick, packed & 1 == 1, offerCapacity, packed, lenderLabel, sourceShares
        );
    }

    function _makeOffer(
        Market memory obl,
        address maker,
        uint16 tick,
        bool reduceOnly,
        uint128 offerCapacity,
        uint256 packed,
        string memory lenderLabel,
        uint128 sourceShares
    ) internal returns (Offer memory o) {
        uint8 denom = _boundDenomination(uint8(packed >> 8));
        offerCapacity = _boundOfferCapacity(offerCapacity, denom);
        (uint128 mu, uint128 ma) = _denomFields(offerCapacity, denom);
        o.market = obl;
        o.maker = maker;
        o.start = block.timestamp;
        o.expiry = block.timestamp + 1 hours;
        o.tick = tick;
        o.group = keccak256(
            abi.encodePacked(lenderLabel, sourceShares, offerCapacity, tick, _boundTimeToMaturity(uint8(packed >> 32)))
        );
        o.receiverIfMakerIsSeller = maker;
        o.ratifier = address(ecrecoverRatifier);
        o.reduceOnly = reduceOnly;
        o.maxUnits = mu;
        o.maxAssets = ma;
    }

    /// @notice Proves four invariants for shares-based SELL offers (Midnight to Vault lend exit)
    /// @dev Fuzzes: sourceShares, offerCapacity, tick, ttm, reduceOnly, denomination
    function testFuzz_clampedTakeNeverReverts_shares(uint128 offerCapacity, uint256 packed) external {
        (uint256 freshLenderSK, Offer memory offer, bytes memory encodedClampData, uint256 maxShares) =
            _buildMidnightToVaultLendOffer(offerCapacity, packed, "freshLender");

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety — take(maxShares) succeeds ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, address(0), address(0), ""
        );

        // --- Invariant 2: Exhaustion — take(1) after take(maxShares) either reverts or is zero-cost ---
        {
            uint256 borrowerBalBefore = loanToken.balanceOf(borrower);
            vm.prank(borrower);
            try midnight.take(
                offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, address(0), address(0), ""
            ) {
                uint256 borrowerBalAfter = loanToken.balanceOf(borrower);
                assertEq(
                    borrowerBalBefore, borrowerBalAfter, "take(1) after maxShares must be zero-cost if it succeeds"
                );
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
            address(0),
            address(0),
            ""
        );
    }

    /// @notice Same three invariants with units-based offer
    function testFuzz_clampedTakeNeverReverts_units(uint128 offerCapacity, uint256 packed) external {
        (uint256 freshLenderSK, Offer memory offer, bytes memory encodedClampData, uint256 maxShares) =
            _buildMidnightToVaultLendOffer(offerCapacity, packed, "freshLenderUnits");

        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        // --- Invariant 1: Safety ---
        uint256 snap = vm.snapshotState();

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, address(0), address(0), ""
        );

        // --- Invariant 2: Exhaustion ---
        {
            uint256 borrowerBalBefore = loanToken.balanceOf(borrower);
            vm.prank(borrower);
            try midnight.take(
                offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), 1, borrower, address(0), address(0), ""
            ) {
                uint256 borrowerBalAfter = loanToken.balanceOf(borrower);
                assertEq(
                    borrowerBalBefore, borrowerBalAfter, "take(1) after maxShares must be zero-cost if it succeeds"
                );
            } catch {}
        }

        vm.revertToState(snap);

        // --- Invariant 3: Tightness ---
        vm.prank(borrower);
        vm.expectRevert();
        midnight.take(
            offer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            maxShares + 1,
            borrower,
            address(0),
            address(0),
            ""
        );
    }

    /* ========== UNCONSTRAINED CAPACITY FUZZ TESTS ========== */

    /// @notice When offer capacity is unconstrained, take(maxShares) must fully close the source position.
    function testFuzz_unconstrainedCapacity_sourceFullyClosed_shares(uint128 sourceShares, uint16 tick, uint8 ttmSeed)
        external
    {
        tick = _boundTick(tick);
        sourceShares = uint128(bound(sourceShares, 1, SEED_AMOUNT));
        uint256 ttm = _boundTimeToMaturity(ttmSeed);

        uint128 offerCapacity = MAX_OFFER_CAPACITY;

        bytes32 group = keccak256(abi.encodePacked("v2v1-lend-uncap-shares", sourceShares, tick, ttm));

        Market memory customSource = sourceMarket;
        customSource.maturity = block.timestamp + ttm;
        bytes32 customSourceId = IdLib.toId(customSource);

        if (midnight.tickSpacing(customSourceId) == 0) {
            _seedMarket(customSource, customSourceId);
            collateralToken.mint(borrower, 1e38);
            vm.prank(borrower);
            midnight.supplyCollateral(customSource, 0, 1e38, borrower);
        }

        (address freshLender, uint256 freshLenderSK) = makeAddrAndKey("freshLenderUncap");
        vm.prank(freshLender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);
        _setupLenderWithShares(freshLender, freshLenderSK, sourceShares, customSource, customSourceId);

        assertGt(creditAfterSlashing(midnight, customSourceId, freshLender), 0, "lender should have source shares");

        Offer memory offer = Offer({
            market: customSource,
            buy: false,
            maker: freshLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: freshLender,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        LendMidnightToVaultClamp.LendMidnightToVaultClampData memory clampData =
            LendMidnightToVaultClamp.LendMidnightToVaultClampData({
                sourceMarketId: customSourceId,
                targetVault: address(targetVault),
                positionOwner: borrower,
                vaultType: LendMidnightToVaultClamp.VaultType.ERC4626
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, address(0), address(0), ""
        );

        uint256 remainingShares = creditAfterSlashing(midnight, customSourceId, freshLender);
        assertEq(remainingShares, 0, "source shares must be fully withdrawn when capacity is unconstrained");
    }

    /// @notice Same as above but with units-based offer
    function testFuzz_unconstrainedCapacity_sourceFullyClosed_units(uint128 sourceShares, uint16 tick, uint8 ttmSeed)
        external
    {
        tick = _boundTick(tick);
        sourceShares = uint128(bound(sourceShares, 1, SEED_AMOUNT));
        uint256 ttm = _boundTimeToMaturity(ttmSeed);

        uint128 offerCapacity = MAX_OFFER_CAPACITY;

        bytes32 group = keccak256(abi.encodePacked("v2v1-lend-uncap-units", sourceShares, tick, ttm));

        Market memory customSource = sourceMarket;
        customSource.maturity = block.timestamp + ttm;
        bytes32 customSourceId = IdLib.toId(customSource);

        if (midnight.tickSpacing(customSourceId) == 0) {
            _seedMarket(customSource, customSourceId);
            collateralToken.mint(borrower, 1e38);
            vm.prank(borrower);
            midnight.supplyCollateral(customSource, 0, 1e38, borrower);
        }

        (address freshLender, uint256 freshLenderSK) = makeAddrAndKey("freshLenderUncapUnits");
        vm.prank(freshLender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, freshLender);
        _setupLenderWithShares(freshLender, freshLenderSK, sourceShares, customSource, customSourceId);

        assertGt(creditAfterSlashing(midnight, customSourceId, freshLender), 0, "lender should have source shares");

        Offer memory offer = Offer({
            market: customSource,
            buy: false,
            maker: freshLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: freshLender,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        LendMidnightToVaultClamp.LendMidnightToVaultClampData memory clampData =
            LendMidnightToVaultClamp.LendMidnightToVaultClampData({
                sourceMarketId: customSourceId,
                targetVault: address(targetVault),
                positionOwner: borrower,
                vaultType: LendMidnightToVaultClamp.VaultType.ERC4626
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        if (maxShares == 0) return;

        Signature memory sig = _signOffer(offer, freshLenderSK);
        bytes32 root = HashLib.hashOffer(offer);

        vm.prank(borrower);
        midnight.take(
            offer, abi.encode(sig, root, uint256(0), new bytes32[](0)), maxShares, borrower, address(0), address(0), ""
        );

        uint256 remainingShares = creditAfterSlashing(midnight, customSourceId, freshLender);
        assertEq(remainingShares, 0, "source shares must be fully withdrawn when capacity is unconstrained");
    }

    /* ========== EDGE CASE FUZZ TESTS ========== */

    /// @notice Zero source shares always returns 0
    function testFuzz_zeroSourceShares_returnsZero(uint128 offerCapacity, uint16 tick) external {
        tick = uint16(bound(tick, 1, 1455)) * 4;
        offerCapacity = uint128(bound(offerCapacity, 1, MAX_OFFER_CAPACITY));

        (address emptyLender,) = makeAddrAndKey("emptyLender");

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: emptyLender,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256("zero-shares-v2v1"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: emptyLender,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: offerCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        LendMidnightToVaultClamp.LendMidnightToVaultClampData memory clampData =
            LendMidnightToVaultClamp.LendMidnightToVaultClampData({
                sourceMarketId: sourceMarketId,
                targetVault: address(targetVault),
                positionOwner: borrower,
                vaultType: LendMidnightToVaultClamp.VaultType.ERC4626
            });

        uint256 maxShares = clampContract.maxUnits(offer, abi.encode(clampData));
        assertEq(maxShares, 0, "zero source shares should return zero");
    }
}
