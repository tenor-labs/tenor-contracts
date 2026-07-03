// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {MigrationRatifier} from "../../src/ratifiers/MigrationRatifier.sol";
import {IMigrationRatifier} from "../../src/ratifiers/interfaces/IMigrationRatifier.sol";
import {IBorrowMidnightRenewalCallback} from "@callbacks/interfaces/IBorrowMidnightRenewalCallback.sol";
import {IBorrowMidnightToBlueCallback} from "@callbacks/interfaces/IBorrowMidnightToBlueCallback.sol";
import {Offer, Market, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MarketParams, Id} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {MarketMakingPolicy} from "../../src/ratifiers/policies/MarketMakingPolicy.sol";
import {IMarketMakingPolicy} from "../../src/ratifiers/interfaces/IMarketMakingPolicy.sol";
import {StaticRatePolicy} from "../../src/ratifiers/policies/StaticRatePolicy.sol";
import {ILendVaultToMidnightCallback} from "@callbacks/interfaces/ILendVaultToMidnightCallback.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {PriceLib} from "../../src/libraries/PriceLib.sol";

contract NoopMidnightForRatifier {
    mapping(address => mapping(address => bool)) public _auth;

    /// @dev Settable so tests that need a non-zero Midnight settlement fee can opt in.
    uint256 public settlementFeeReturn;

    /// @dev When set, settlementFee reverts — lets a test prove the maker path never reads it.
    bool public revertOnSettlementFee;

    function isAuthorized(address u, address a) external view returns (bool) {
        return _auth[u][a];
    }

    function setIsAuthorized(address a, bool v, address u) external {
        _auth[u][a] = v;
    }

    function setSettlementFeeReturn(uint256 v) external {
        settlementFeeReturn = v;
    }

    function setRevertOnSettlementFee(bool v) external {
        revertOnSettlementFee = v;
    }

    function continuousFee(bytes32) external pure returns (uint256) {
        return 0;
    }

    function settlementFee(bytes32, uint256) external view returns (uint256) {
        require(!revertOnSettlementFee, "settlementFee must not be read on the maker path");
        return settlementFeeReturn;
    }
}

/// @dev Cadence stub that treats every timestamp as a valid period boundary (passthrough). Lets vault-source
/// flows (zero source maturity) clear `_ratifyWindow`/`_validateTargetMaturity` without a real cadence.
contract PassthroughCadence {
    function cadencePeriodStart(uint256 t) external pure returns (uint256) {
        return t;
    }
}

/// @title MigrationRatifierTest
/// @notice Unit tests for MigrationRatifier's `isRatified` — covers
///         fee-admin (ORCH-1..3), per-user params auth guards, the receiver-pinning + reserved-group + ratifier-data
///         guards, and a subset of the callbackData-consistency rules that don't need full integration fixtures.
contract MigrationRatifierTest is Test {
    using TenorMarketIdLib for Market;
    using MarketParamsLib for MarketParams;

    MigrationRatifier internal r;
    NoopMidnightForRatifier internal midnight;

    address internal owner = address(this);
    address internal feeRecipient = address(0xFEE);
    address internal constant CB_BORROW_MIDNIGHT_RENEWAL = address(0x1001);
    address internal constant CB_BORROW_BLUE_TO_MIDNIGHT = address(0x1002);
    address internal constant CB_LEND_VAULT_TO_MIDNIGHT = address(0x1003);
    address internal constant CB_BORROW_MIDNIGHT_TO_BLUE = address(0x1004);
    address internal constant CB_LEND_MIDNIGHT_TO_VAULT = address(0x1005);
    address internal constant CB_LEND_MIDNIGHT_RENEWAL = address(0x1006);

    uint256 internal constant MAX_FEE_RATE = 0.5e18;
    uint256 internal constant MAX_FEE_RATE_FIXED_TO_VARIABLE = 0;

    address internal user = address(0xAA);

    function setUp() public {
        midnight = new NoopMidnightForRatifier();
        r = new MigrationRatifier(
            address(midnight),
            CB_BORROW_MIDNIGHT_RENEWAL,
            CB_BORROW_BLUE_TO_MIDNIGHT,
            CB_LEND_VAULT_TO_MIDNIGHT,
            CB_BORROW_MIDNIGHT_TO_BLUE,
            CB_LEND_MIDNIGHT_TO_VAULT,
            CB_LEND_MIDNIGHT_RENEWAL,
            owner
        );
    }

    /* ═════════════════════════════════════════════════════
       Fee admin — ORCH-1, ORCH-2, ORCH-3
       ═════════════════════════════════════════════════════ */

    function test_setActionFeeConfig_revertsAboveMaxFeeRate() public {
        vm.expectRevert(IMigrationRatifier.InvalidFeeConfig.selector);
        r.setFeeConfig(CB_BORROW_MIDNIGHT_RENEWAL, bytes32(0), MAX_FEE_RATE + 1, feeRecipient);
    }

    function test_setActionFeeConfig_FixedToVariableForbidsNonZeroFee() public {
        vm.expectRevert(IMigrationRatifier.InvalidFeeConfig.selector);
        r.setFeeConfig(CB_BORROW_MIDNIGHT_TO_BLUE, bytes32(0), MAX_FEE_RATE_FIXED_TO_VARIABLE + 1, feeRecipient);

        vm.expectRevert(IMigrationRatifier.InvalidFeeConfig.selector);
        r.setFeeConfig(CB_LEND_MIDNIGHT_TO_VAULT, bytes32(0), MAX_FEE_RATE_FIXED_TO_VARIABLE + 1, feeRecipient);
    }

    /// @dev Exit-flow callbacks reject ANY non-zero fee, across the full range a normal callback would accept,
    /// not just the boundary value. This pins `feeConfig.feeRate` to 0 for these callbacks, which is what makes
    /// the fee folded into `_ratifyRate`'s rate check always 0 for exits. If `MAX_FEE_RATE_FIXED_TO_VARIABLE`
    /// were ever raised, this fails — a signal that exit fees would start tightening the rate check.
    function testFuzz_setActionFeeConfig_FixedToVariableRejectsAnyNonZeroFee(uint256 feeRate) public {
        feeRate = bound(feeRate, 1, MAX_FEE_RATE);

        vm.expectRevert(IMigrationRatifier.InvalidFeeConfig.selector);
        r.setFeeConfig(CB_BORROW_MIDNIGHT_TO_BLUE, bytes32(0), feeRate, feeRecipient);

        vm.expectRevert(IMigrationRatifier.InvalidFeeConfig.selector);
        r.setFeeConfig(CB_LEND_MIDNIGHT_TO_VAULT, bytes32(0), feeRate, feeRecipient);
    }

    function test_setActionFeeConfig_revertsOnZeroRecipientWithNonZeroRate() public {
        vm.expectRevert(IMigrationRatifier.InvalidFeeConfig.selector);
        r.setFeeConfig(CB_BORROW_MIDNIGHT_RENEWAL, bytes32(0), 0.01e18, address(0));
    }

    function test_setActionFeeConfig_zeroRateZeroRecipient_legal() public {
        r.setFeeConfig(CB_BORROW_MIDNIGHT_RENEWAL, bytes32(0), 0, address(0));
        (address recip, uint96 rate) = r.feeConfigs(CB_BORROW_MIDNIGHT_RENEWAL, bytes32(0));
        assertEq(recip, address(0));
        assertEq(rate, 0);
    }

    function test_getEffectiveFeeConfig_marketOverridesAction() public {
        r.setFeeConfig(CB_BORROW_MIDNIGHT_RENEWAL, bytes32(0), 0.01e18, feeRecipient);
        r.setFeeConfig(CB_BORROW_MIDNIGHT_RENEWAL, bytes32("mkt"), 0.02e18, feeRecipient);
        IMigrationRatifier.FeeConfig memory eff = r.getEffectiveFeeConfig(CB_BORROW_MIDNIGHT_RENEWAL, bytes32("mkt"));
        assertEq(eff.feeRate, 0.02e18);
    }

    function test_getEffectiveFeeConfig_fallsBackToActionLevel() public {
        r.setFeeConfig(CB_BORROW_MIDNIGHT_RENEWAL, bytes32(0), 0.01e18, feeRecipient);
        IMigrationRatifier.FeeConfig memory eff =
            r.getEffectiveFeeConfig(CB_BORROW_MIDNIGHT_RENEWAL, bytes32("unset-market"));
        assertEq(eff.feeRate, 0.01e18);
        assertEq(eff.feeRecipient, feeRecipient);
    }

    function test_setActionFeeConfig_onlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        r.setFeeConfig(CB_BORROW_MIDNIGHT_RENEWAL, bytes32(0), 0.01e18, feeRecipient);
    }

    function test_setMarketFeeConfig_onlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        r.setFeeConfig(CB_BORROW_MIDNIGHT_RENEWAL, bytes32("mkt"), 0.01e18, feeRecipient);
    }

    /* ═════════════════════════════════════════════════════
       Per-user params — setParams / clearParams auth
       ═════════════════════════════════════════════════════ */

    function _sampleParams() internal pure returns (IMigrationRatifier.UserMigrationParams memory) {
        return IMigrationRatifier.UserMigrationParams({
            interestRatePolicy: address(0x1),
            renewalWindow: 1 days,
            minDuration: 1 hours,
            maxDuration: 365 days,
            renewalCadence: address(0),
            limitRatePerSecond: 0
        });
    }

    function test_setParams_selfStoresAndEmits() public {
        bytes32 src = bytes32("src");
        bytes32 tgt = bytes32("tgt");
        IMigrationRatifier.UserMigrationParams memory p = _sampleParams();

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit IMigrationRatifier.ParamsSet(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt, p);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt, p);

        (address policy,,,,,) = r.userParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt);
        assertEq(policy, address(0x1), "params persisted");
    }

    function test_setParams_revertsWhenCallerUnauthorized() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(IMigrationRatifier.Unauthorized.selector);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, bytes32("src"), bytes32("tgt"), _sampleParams());
    }

    function test_setParams_succeedsViaMidnightDelegate() public {
        address delegate = address(0xDE1E);
        midnight.setIsAuthorized(delegate, true, user);

        vm.prank(delegate);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, bytes32("src"), bytes32("tgt"), _sampleParams());

        (address policy,,,,,) = r.userParams(user, CB_BORROW_MIDNIGHT_RENEWAL, bytes32("src"), bytes32("tgt"));
        assertEq(policy, address(0x1), "delegate wrote params");
    }

    function test_clearParams_selfEmitsAndZeroes() public {
        bytes32 src = bytes32("src");
        bytes32 tgt = bytes32("tgt");

        vm.prank(user);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt, _sampleParams());

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit IMigrationRatifier.ParamsCleared(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt);
        r.clearParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt);

        (address policy,,,,,) = r.userParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt);
        assertEq(policy, address(0), "params cleared");
    }

    function test_clearParams_revertsWhenCallerUnauthorized() public {
        vm.prank(user);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, bytes32("src"), bytes32("tgt"), _sampleParams());

        vm.prank(address(0xBAD));
        vm.expectRevert(IMigrationRatifier.Unauthorized.selector);
        r.clearParams(user, CB_BORROW_MIDNIGHT_RENEWAL, bytes32("src"), bytes32("tgt"));
    }

    function test_setParams_overwritesExistingEntry() public {
        bytes32 src = bytes32("src");
        bytes32 tgt = bytes32("tgt");

        IMigrationRatifier.UserMigrationParams memory p1 = _sampleParams();
        p1.limitRatePerSecond = 111;
        IMigrationRatifier.UserMigrationParams memory p2 = _sampleParams();
        p2.limitRatePerSecond = 222;

        vm.startPrank(user);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt, p1);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt, p2);
        vm.stopPrank();

        (,,,,, uint40 stored) = r.userParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt);
        assertEq(stored, 222, "second setParams must overwrite the first");
    }

    /* ═════════════════════════════════════════════════════
       isRatified — guards. ratifierData encodes (src, tgt).
       The offer's maker is the user; offer.callback selects the route.
       ═════════════════════════════════════════════════════ */

    function _grp() internal view returns (bytes32) {
        bytes32 mask = r.MIGRATION_GROUP_HEADER_MASK();
        return (bytes32(uint256(1)) & ~mask) | r.MIGRATION_GROUP_HEADER();
    }

    /// @dev A migration offer: maker == user, given callback + side, receiver pinned, group stamped.
    function _mkOffer(uint16 tick, bool buy, address callback) internal view returns (Offer memory o) {
        CollateralParams[] memory cols = new CollateralParams[](0);
        o.tick = tick;
        o.buy = buy;
        o.maker = user;
        o.callback = callback;
        o.group = _grp();
        o.receiverIfMakerIsSeller = buy ? address(0) : callback;
        o.market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(0),
            collateralParams: cols,
            maturity: 0,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function callRatify(Offer calldata offer, bytes calldata ratifierData) external view returns (bytes32) {
        return r.isRatified(offer, ratifierData, address(0));
    }

    function _ratifyOk(Offer memory offer, bytes memory ratifierData) internal view returns (bool) {
        try this.callRatify(offer, ratifierData) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev InvalidRatifierData: ratifierData that isn't exactly 64 bytes reverts.
    function test_isRatified_revertsOnMalformedRatifierData() public {
        Offer memory offer = _mkOffer(0, false, CB_BORROW_MIDNIGHT_RENEWAL);
        vm.expectRevert(IMigrationRatifier.InvalidRatifierData.selector);
        this.callRatify(offer, hex"dead");
    }

    function test_isRatified_revertsOnExtraBytesInRatifierData() public {
        bytes memory tooLong = abi.encodePacked(abi.encode(bytes32("src"), bytes32("tgt")), uint256(0xdeadbeef));
        Offer memory offer = _mkOffer(0, false, CB_BORROW_MIDNIGHT_RENEWAL);
        vm.expectRevert(IMigrationRatifier.InvalidRatifierData.selector);
        this.callRatify(offer, tooLong);
    }

    /// @dev InvalidReceiver: a sell offer must pin receiverIfMakerIsSeller == offer.callback.
    function test_isRatified_revertsOnUnpinnedReceiver() public {
        Offer memory offer = _mkOffer(0, false, CB_BORROW_MIDNIGHT_RENEWAL);
        offer.receiverIfMakerIsSeller = address(0xC0FFEE); // not the callback
        vm.expectRevert(IMigrationRatifier.InvalidReceiver.selector);
        this.callRatify(offer, abi.encode(bytes32("src"), bytes32("tgt")));
    }

    /// @dev InvalidGroup: the offer's group must carry the reserved migration-group header.
    function test_isRatified_revertsOnWrongGroup() public {
        Offer memory offer = _mkOffer(0, false, CB_BORROW_MIDNIGHT_RENEWAL);
        offer.group = bytes32(uint256(1)); // not stamped
        vm.expectRevert(IMigrationRatifier.InvalidGroup.selector);
        this.callRatify(offer, abi.encode(bytes32("src"), bytes32("tgt")));
    }

    /// @dev InvalidRenewalParams: params slot is all-zero for this (maker, cb, src, tgt).
    function test_isRatified_revertsOnUnconfiguredTuple() public {
        Offer memory offer = _mkOffer(0, false, CB_BORROW_MIDNIGHT_RENEWAL);
        vm.expectRevert(IMigrationRatifier.InvalidRenewalParams.selector);
        this.callRatify(offer, abi.encode(bytes32("src"), bytes32("tgt")));
    }

    function test_isRatified_revertsOnZeroPolicyAddress() public {
        bytes32 src = bytes32("src");
        bytes32 tgt = bytes32("tgt");
        IMigrationRatifier.UserMigrationParams memory p = _sampleParams();
        p.interestRatePolicy = address(0);
        vm.prank(user);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt, p);

        Offer memory offer = _mkOffer(0, false, CB_BORROW_MIDNIGHT_RENEWAL);
        vm.expectRevert(IMigrationRatifier.InvalidRenewalParams.selector);
        this.callRatify(offer, abi.encode(src, tgt));
    }

    function test_isRatified_revertsOnZeroMinDuration() public {
        bytes32 src = bytes32("src");
        bytes32 tgt = bytes32("tgt");
        IMigrationRatifier.UserMigrationParams memory p = _sampleParams();
        p.minDuration = 0;
        vm.prank(user);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt, p);

        Offer memory offer = _mkOffer(0, false, CB_BORROW_MIDNIGHT_RENEWAL);
        vm.expectRevert(IMigrationRatifier.InvalidRenewalParams.selector);
        this.callRatify(offer, abi.encode(src, tgt));
    }

    function test_isRatified_revertsOnMaxBelowMin() public {
        bytes32 src = bytes32("src");
        bytes32 tgt = bytes32("tgt");
        IMigrationRatifier.UserMigrationParams memory p = _sampleParams();
        p.minDuration = 365 days;
        p.maxDuration = 1 days;
        vm.prank(user);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt, p);

        Offer memory offer = _mkOffer(0, false, CB_BORROW_MIDNIGHT_RENEWAL);
        vm.expectRevert(IMigrationRatifier.InvalidRenewalParams.selector);
        this.callRatify(offer, abi.encode(src, tgt));
    }

    /// @dev InvalidCallback: callback that isn't a registered branch reverts.
    function test_isRatified_revertsOnUnknownCallback() public {
        bytes32 src = bytes32("src");
        bytes32 tgt = bytes32("tgt");
        address unknown = address(0xDEADBEEF);
        vm.prank(user);
        r.setParams(user, unknown, src, tgt, _sampleParams());

        Offer memory offer = _mkOffer(0, false, unknown);
        vm.expectRevert(IMigrationRatifier.InvalidCallback.selector);
        this.callRatify(offer, abi.encode(src, tgt));
    }

    /// @dev callbackData.tick mismatched with offer.tick reverts.
    function test_isRatified_revertsOnTickMismatch() public {
        bytes32 src = bytes32("src");
        bytes32 tgt = bytes32("tgt");
        vm.prank(user);
        r.setParams(user, CB_BORROW_MIDNIGHT_RENEWAL, src, tgt, _sampleParams());

        Market memory sourceObl;
        IBorrowMidnightRenewalCallback.CallbackData memory cbd = IBorrowMidnightRenewalCallback.CallbackData({
            sourceMarket: sourceObl, feeRate: 0, feeRecipient: address(0), tick: 528
        });

        Offer memory offer = _mkOffer(99, false, CB_BORROW_MIDNIGHT_RENEWAL);
        offer.callbackData = abi.encode(cbd);

        vm.expectRevert(IMigrationRatifier.InvalidCallbackData.selector);
        this.callRatify(offer, abi.encode(src, tgt));
    }

    /* ═════════════════════════════════════════════════════
       Regression: rate-policy side is callback-derived, not offer.buy
       ═════════════════════════════════════════════════════ */

    function _blueTarget() internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(0xBEEF),
            collateralToken: address(0xCAFE),
            oracle: address(0x0000),
            irm: address(0x0000),
            lltv: 0.8e18
        });
    }

    /// @dev A Midnight-market offer (source for exits, target for entries) for the given callback. maker == user,
    /// receiver pinned, group stamped.
    function _midnightOffer(uint256 maturity, uint16 tick, bool buy, address callback)
        internal
        view
        returns (Offer memory o)
    {
        CollateralParams[] memory cols = new CollateralParams[](0);
        o.tick = tick;
        o.buy = buy;
        o.maker = user;
        o.callback = callback;
        o.group = _grp();
        o.receiverIfMakerIsSeller = buy ? address(0) : callback;
        o.market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(0x1234),
            collateralParams: cols,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    /// @dev The rate-policy side must be derived from the callback (`_userIsBuy`), independent of `offer.buy`.
    ///      With a side-sensitive MarketMakingPolicy and a curve set only on the callback-selected side, flipping
    ///      `offer.buy` (and its pinned receiver) must not change the outcome. Uses LEND_VAULT_TO_MIDNIGHT, a
    ///      supported lend flow whose priced side is the Midnight target; if the side leaked from `offer.buy`, the
    ///      flipped offer would select the curveless vault source and revert.
    function test_ratifyRate_sideFromCallbackNotOfferBuy() public {
        MarketMakingPolicy policy = new MarketMakingPolicy(address(midnight));
        PassthroughCadence cadence = new PassthroughCadence();

        address vault = address(0xDEFA17);
        uint256 targetMaturity = block.timestamp + 30 days;
        uint16 tick = 2940;
        Offer memory offerBuyTrue = _midnightOffer(targetMaturity, tick, true, CB_LEND_VAULT_TO_MIDNIGHT);
        bytes32 targetTenorMarketId = offerBuyTrue.market.toTenorMarketId();
        bytes32 sourceTenorMarketId = TenorMarketIdLib.vaultToTenorMarketId(vault);

        // Curve set ONLY on the callback-selected (Midnight target) side.
        IMarketMakingPolicy.CurvePoint[] memory pts = new IMarketMakingPolicy.CurvePoint[](1);
        pts[0] = IMarketMakingPolicy.CurvePoint({ttm: 0, sellRate: 0, buyRate: 0});
        vm.prank(user);
        policy.setCurve(user, targetTenorMarketId, pts);

        IMigrationRatifier.UserMigrationParams memory p = _sampleParams();
        p.interestRatePolicy = address(policy);
        p.renewalCadence = address(cadence);
        p.limitRatePerSecond = 0;
        vm.prank(user);
        r.setParams(user, CB_LEND_VAULT_TO_MIDNIGHT, sourceTenorMarketId, targetTenorMarketId, p);

        bytes memory cbd = abi.encode(
            ILendVaultToMidnightCallback.CallbackData({
                vault: vault, feeRate: 0, feeRecipient: address(0), tick: tick, morphoBlueMarketId: bytes32(0)
            })
        );
        offerBuyTrue.callbackData = cbd;

        Offer memory offerBuyFalse = _midnightOffer(targetMaturity, tick, false, CB_LEND_VAULT_TO_MIDNIGHT);
        offerBuyFalse.callbackData = cbd;

        bool buyTrueOk = _ratifyOk(offerBuyTrue, abi.encode(sourceTenorMarketId, targetTenorMarketId));
        bool buyFalseOk = _ratifyOk(offerBuyFalse, abi.encode(sourceTenorMarketId, targetTenorMarketId));

        assertTrue(buyTrueOk, "must pass (curve on callback-selected target side)");
        assertEq(buyFalseOk, buyTrueOk, "flipping offer.buy must not change the rate-guard outcome");
    }

    /// @dev The maker never pays the Midnight settlement fee, so the rate check ignores it: a non-zero
    ///      settlementFee on the mock must not change whether a maker offer at the raw tick price passes, and a
    ///      reverting settlementFee proves the maker path never even reads it (the `offer.maker == user ? 0 : ...`
    ///      ternary short-circuits before the external call).
    function test_ratifyRate_settlementFeeNotChargedToMaker() public {
        MarketParams memory blue = _blueTarget();
        bytes32 targetTenorMarketId = Id.unwrap(blue.id());

        uint256 sourceMaturity = block.timestamp + 30 days;
        uint256 duration = sourceMaturity - block.timestamp;
        uint16 tick = 2940;
        uint256 tickPrice = TickLib.tickToPrice(tick);

        uint256 policyRate = 0.05e18 / uint256(365 days);
        uint256 price = PriceLib.computePrice(true, policyRate, duration);
        assertGt(price, tickPrice, "setup: bond price must exceed raw tick price");

        // A large settlement fee on the mock — it must be ignored on the maker path.
        midnight.setSettlementFeeReturn((price - tickPrice) + 1e18);

        // A flat StaticRatePolicy returning policyRate — borrow flows revert under MarketMakingPolicy, and this
        // test is about the maker settlement-fee short-circuit, not side-sensitive curve dispatch.
        uint128[] memory rates = new uint128[](1);
        uint128[] memory durations = new uint128[](1);
        rates[0] = uint128(policyRate);
        durations[0] = 1;
        StaticRatePolicy policy = new StaticRatePolicy(rates, durations);

        Offer memory makerOffer = _midnightOffer(sourceMaturity, tick, false, CB_BORROW_MIDNIGHT_TO_BLUE);
        makerOffer.callbackData = abi.encode(
            IBorrowMidnightToBlueCallback.CallbackData({targetMarketParams: blue, feeRate: 0, feeRecipient: address(0)})
        );
        bytes32 sourceTenorMarketId = makerOffer.market.toTenorMarketId();

        IMigrationRatifier.UserMigrationParams memory p = _sampleParams();
        p.interestRatePolicy = address(policy);
        p.renewalWindow = uint32(30 days);
        p.limitRatePerSecond = 0;
        vm.prank(user);
        r.setParams(user, CB_BORROW_MIDNIGHT_TO_BLUE, sourceTenorMarketId, targetTenorMarketId, p);

        assertTrue(
            _ratifyOk(makerOffer, abi.encode(sourceTenorMarketId, targetTenorMarketId)),
            "maker offer at raw tick price must pass regardless of settlement fee"
        );

        // Stronger: the maker path must never even read the settlement fee. A reverting oracle proves the
        // `offer.maker == user ? 0 : settlementFee(...)` ternary short-circuits before the external call.
        midnight.setRevertOnSettlementFee(true);
        assertTrue(
            _ratifyOk(makerOffer, abi.encode(sourceTenorMarketId, targetTenorMarketId)),
            "maker path must not call MORPHO_MIDNIGHT.settlementFee()"
        );
    }
}
