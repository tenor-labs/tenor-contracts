// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {IMidnight, Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS, WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {LinearInterpolationLib} from "../../libraries/LinearInterpolationLib.sol";
import {PriceLib} from "../../libraries/PriceLib.sol";
import {TenorMarketIdLib} from "../../libraries/TenorMarketIdLib.sol";
import {IMarketMakingPolicy} from "../interfaces/IMarketMakingPolicy.sol";
import {IRenewalCadence} from "../interfaces/IRenewalCadence.sol";
import {IMidnightAdapterCurveRatifier} from "./interfaces/IMidnightAdapterCurveRatifier.sol";
import {AdapterMarketData, IMidnightAdapterMinimal, IVaultV2Roles} from "./interfaces/IMidnightAdapterMinimal.sol";

/// @title MidnightAdapterCurveRatifier
/// @notice Sub-ratifier for Morpho Vault V2 MidnightAdapters that ratifies the adapter's maker offers against an
/// onchain curve of (ttm, sellRate, buyRate) per Tenor market, so that anyone can take them (passive quoting).
/// @dev The adapter is Midnight's ratifier for its own offers. It checks the offer shape (maker, callback, loan asset,
/// Midnight, sell receiver, liquidation lock), then forwards to a sub-ratifier that its allocators allowlisted with
/// `setIsSubRatifier`. The adapter's `ratifierData` for this contract is `abi.encode(address(this), "")`.
/// @dev Same curve format and validation as MarketMakingPolicy. Curves are keyed by (adapter, Tenor market ID), so a
/// curve also allowlists the market's loan token, collateral params, rcfThreshold and gates. The ID excludes maturity.
///
/// ROLES
/// @dev Roles are read from the adapter's parent vault. Allocators set curves, funding sources, rolling and the
/// cadence. Sentinels can only clear curves, disallow funding sources and rolling, and unset the cadence.
/// @dev The caller must be `onBehalf` or be authorized by it on the adapter's Midnight.
/// @dev Settings made by an allocator survive the removal of that allocator, until changed.
///
/// STANDING CONSENT
/// @dev While a curve is set, anyone can take the adapter's offers at any tick that satisfies the curve. Offers carry
/// no signature and no nonce.
/// @dev There is no fill budget, so a vault that rolls from maturity to maturity needs no upkeep. Buys are bounded by
/// the vault's and adapter's caps, and sells by the adapter's credit. Sentinels stop fills by clearing curves,
/// unsetting the cadence, disallowing funding sources and rolling, removing this sub-ratifier, or lowering caps.
/// @dev Offer groups must start with CURVE_GROUP_HEADER: the "tenor" domain prefix with a version byte of its own, as
/// in MigrationRatifier. Curve fills then never consume the groups of the adapter's other offers. The low 208 bits are
/// free, so `consumed` bounds nothing here: a taker can use a fresh group per offer.
/// @dev The loss factor only shows realized losses. A lender of a market with pending bad debt can sell its credit to
/// the adapter before the loss is realized, and the vault then bears it. The lender and the borrower can be the same
/// party, and the adapter needs no prior position in the market, so the vault's caps are the amount that can be lent
/// against pending bad debt. A liquidator gate that delays liquidations keeps that window open for the whole delay.
///
/// BUYS
/// @dev Net rate floor: the curve buyRate at ttm. The price is checked against units net of Midnight's continuous fee,
/// which is the adapter's net-credit basis.
/// @dev Buys need ttm within [first knot ttm, last knot ttm]: the curve's ends are not extended to tenors it does not
/// quote. A single-point curve only ratifies buys at that exact ttm.
/// @dev The funding source (the offer's callbackData) must be allowed. See FUNDING.
/// @dev Buys are rejected in markets with a nonzero loss factor. A loss factor never returns to zero, so the first
/// realized bad debt in a market, however small, ends buys in that market through this contract. Allocators can still
/// buy there through another sub-ratifier.
///
/// FUNDING
/// @dev The adapter funds a buy from the source in the offer's callbackData, (fundingAdapter, fundingData): idle assets
/// for address(0), another adapter of the vault, or one of its own markets for the adapter itself. Takers write the
/// offer, so the source must be allowed: an exact callbackData an allocator allowed, or, when rolling is allowed,
/// (adapter, abi.encode(market)) for any matured market.
/// @dev Rolling: the adapter withdraws the buyer assets from the matured market inside onBuy, as itself, so matured
/// credit funds the next term without an allocator. The take reverts if the market has too little withdrawable, or
/// is force-removed or liquidation-locked. Unmatured markets are excluded: credit repaid early is valued below par
/// until maturity, so withdrawing it at par would realize a gain at once (see SELL GUARDRAILS).
/// @dev Each take has one funding source. A route over several sources is several takes of offers that differ only
/// in callbackData.
/// @dev Malformed callbackData makes the decoding revert without an error.
///
/// MATURITY CADENCE
/// @dev Buys are only ratified at maturities on the adapter's cadence: cadencePeriodStart(maturity) == maturity, as in
/// MigrationRatifier. Without a cadence, buys are rejected.
/// @dev The adapter accepts any maturity up to maxTtm, and each maturity is a separate market in its list of at most
/// MAX_MARKETS, which realAssets iterates on every vault interaction. The cadence bounds the markets a taker can make
/// the adapter enter to the cadence points within each curve's ttm range, e.g. about 7 at a time per curve for a
/// four-week cadence over 180 days. Sells are not restricted: they only reduce markets the adapter already holds.
/// @dev The bound is only as tight as the cadence: one that accepts every timestamp bounds nothing.
/// @dev The bound is on the markets open at one time. A taker can open every cadence maturity in range with dust, and
/// a market stays in the adapter's list until its net credit returns to zero. Before maturity, anyone can buy the dust
/// back through a ratified sell. After maturity, an allocator withdraws it once the debt is repaid or liquidated.
///
/// SELL GUARDRAILS
/// @dev Rate ceiling: min(curve sellRate at ttm, market netRate). The curve's ttm is clamped to its ends, so a
/// position can be exited at any ttm before maturity.
/// @dev Capping at the market's netRate means a ratified sell never has a shortfall in the adapter: it neither consumes
/// the curator's shortfallAllowance nor lowers the rates of the adapter's other markets.
/// @dev A sell below the market's netRate realizes its gain at once in the adapter's realAssets. A taker can trigger
/// it by buying from the adapter and selling back, at the cost of the spread. A depositor that enters the vault just
/// before then shares a gain that existing depositors would have earned until maturity. At the curve's sell price the
/// gain is at most (netRate - sellRate) * ttm per asset sold, so it is bounded by the adapter's credit and by how far
/// the curve is below the rates the adapter holds. Lowering a curve far below those rates is what opens the gap.
/// @dev While a market has withdrawable assets before maturity, a taker can buy the adapter's credit below par and
/// withdraw it at par. The adapter is still paid the curve price; allocators that want par should withdraw first.
/// @dev The price is checked against gross units, which bounds the proceeds per unit of sold net credit from below:
/// the seller's pending fee decrease only reduces the sold net credit.
/// @dev Sells must be reduceOnly, so the adapter never sells past its credit into debt.
/// @dev Sells are rejected in force-sellable markets, where the adapter replaces its rate checks with
/// minForceSellPrice. They are not rejected in markets with a loss, which can still be exited at or above their
/// amortized value.
///
/// MARKET STATE
/// @dev Both sides are rejected after maturity. Exits from matured markets are left to allocators and to withdrawals.
///
/// ADAPTER GUARDRAILS
/// @dev The adapter reverts the take itself on maxTtm, minNetBuyRate and force-sellable markets for buys, on
/// maxNetSellRate for sells, and on force-removed markets for both. They are not checked again here.
///
/// LOOP SAFETY
/// @dev sellRate <= buyRate at every point, so a taker buying from and selling back to the same adapter at the same
/// ttm pays at least the spread to the vault.
/// @dev With sellRate == buyRate the spread is zero: the round trip only costs the taker Midnight's settlement fees and
/// tick rounding.
///
/// NOT CHECKED
/// @dev The taker, start and expiry are not checked: any taker can take while Midnight's start and expiry allow.
/// @dev There is no settlement or Tenor fee to net: the maker is the adapter, and takers pay Midnight's settlement fee.
contract MidnightAdapterCurveRatifier is IMidnightAdapterCurveRatifier {
    /// @inheritdoc IMidnightAdapterCurveRatifier
    uint256 public constant MAX_POINTS = 8;

    /// @inheritdoc IMidnightAdapterCurveRatifier
    /// @dev Top 6 bytes = "tenor" (0x74656e6f72) domain prefix + schema version byte 0xF0; the 0xF0-0xFF version
    /// range is reserved for vault curve group schema versions (this mask matches 0xF0 exactly), next to
    /// MigrationRatifier's 0xE0-0xEF. The low 208 bits stay free to vary per offer.
    bytes32 public constant CURVE_GROUP_HEADER = hex"74656e6f72f0";

    /// @inheritdoc IMidnightAdapterCurveRatifier
    bytes32 public constant CURVE_GROUP_HEADER_MASK = hex"ffffffffffff";

    /// @inheritdoc IMidnightAdapterCurveRatifier
    mapping(address adapter => mapping(bytes32 tenorMarketId => IMarketMakingPolicy.CurvePoint[])) public curves;

    /// @inheritdoc IMidnightAdapterCurveRatifier
    mapping(address adapter => mapping(bytes32 callbackDataHash => bool)) public isFundingSource;

    /// @inheritdoc IMidnightAdapterCurveRatifier
    mapping(address adapter => bool) public allowsRolling;

    /// @inheritdoc IMidnightAdapterCurveRatifier
    mapping(address adapter => address) public cadence;

    /* SETTERS */

    /// @inheritdoc IMidnightAdapterCurveRatifier
    function setCadence(address adapter, address newCadence, address onBehalf) external {
        _authorize(adapter, onBehalf, newCadence == address(0));
        cadence[adapter] = newCadence;
        emit CadenceSet(adapter, onBehalf, newCadence);
    }

    /// @inheritdoc IMidnightAdapterCurveRatifier
    function setCurve(
        address adapter,
        bytes32 tenorMarketId,
        IMarketMakingPolicy.CurvePoint[] calldata points,
        address onBehalf
    ) external {
        _authorize(adapter, onBehalf, false);
        uint256 n = points.length;
        if (n == 0) revert EmptyCurve();
        if (n > MAX_POINTS) revert TooManyPoints();

        if (points[0].sellRate > points[0].buyRate) revert CrossedCurve();
        for (uint256 i = 1; i < n; i++) {
            if (points[i].ttm <= points[i - 1].ttm) revert NonStrictlyIncreasingTtm();
            if (points[i].sellRate > points[i].buyRate) revert CrossedCurve();
        }

        curves[adapter][tenorMarketId] = points;
        emit CurveSet(adapter, tenorMarketId, onBehalf, points);
    }

    /// @inheritdoc IMidnightAdapterCurveRatifier
    function clearCurve(address adapter, bytes32 tenorMarketId, address onBehalf) external {
        _authorize(adapter, onBehalf, true);
        delete curves[adapter][tenorMarketId];
        emit CurveCleared(adapter, tenorMarketId, onBehalf);
    }

    /// @inheritdoc IMidnightAdapterCurveRatifier
    function setIsFundingSource(address adapter, bytes calldata callbackData, bool allowed, address onBehalf) external {
        _authorize(adapter, onBehalf, !allowed);
        isFundingSource[adapter][keccak256(callbackData)] = allowed;
        emit FundingSourceSet(adapter, onBehalf, callbackData, allowed);
    }

    /// @inheritdoc IMidnightAdapterCurveRatifier
    function setAllowsRolling(address adapter, bool allowed, address onBehalf) external {
        _authorize(adapter, onBehalf, !allowed);
        allowsRolling[adapter] = allowed;
        emit AllowsRollingSet(adapter, onBehalf, allowed);
    }

    /* RATIFICATION */

    /// @inheritdoc IMidnightAdapterCurveRatifier
    function curveLength(address adapter, bytes32 tenorMarketId) external view returns (uint256) {
        return curves[adapter][tenorMarketId].length;
    }

    /// @inheritdoc IMidnightAdapterCurveRatifier
    function buyRateBound(address adapter, Market memory market) external view returns (uint256 rate) {
        (rate,,) = _buyRateBound(adapter, market);
    }

    /// @inheritdoc IMidnightAdapterCurveRatifier
    function sellRateBound(address adapter, Market memory market) external view returns (uint256 rate) {
        (rate,) = _sellRateBound(adapter, market);
    }

    /// @notice Ratifies a maker offer of the calling adapter.
    /// @dev The caller must be the offer's maker: the adapter forwards its own offers here.
    /// @dev The offer's group must start with CURVE_GROUP_HEADER. Its maxAssets and maxUnits are not checked: they only
    /// limit the taker's own fill.
    function isRatified(
        Offer memory offer,
        bytes memory ratifierData,
        address /* taker */
    )
        external
        view
        returns (bytes32)
    {
        address adapter = offer.maker;
        if (msg.sender != adapter) revert NotMaker();
        if (ratifierData.length != 0) revert NonEmptyRatifierData();
        if ((offer.group & CURVE_GROUP_HEADER_MASK) != CURVE_GROUP_HEADER) revert InvalidGroup();

        uint256 tickPrice = TickLib.tickToPrice(offer.tick);

        if (offer.buy) {
            _checkFunding(adapter, offer.callbackData);

            (uint256 rate, uint256 ttm, uint256 netUnitsPerWad) = _buyRateBound(adapter, offer.market);
            if (tickPrice * WAD > netUnitsPerWad * PriceLib.computePrice(true, rate, ttm)) revert WorsePrice();
        } else {
            if (!offer.reduceOnly) revert NotReduceOnly();

            (uint256 rate, uint256 ttm) = _sellRateBound(adapter, offer.market);
            if (tickPrice < PriceLib.computePrice(false, rate, ttm)) revert WorsePrice();
        }
        return CALLBACK_SUCCESS;
    }

    /* INTERNAL */

    /// @dev Reverts unless `onBehalf` is an allocator of the adapter's parent vault (or a sentinel when
    /// `sentinelAllowed`), and the caller is `onBehalf` or authorized by it on the adapter's Midnight.
    function _authorize(address adapter, address onBehalf, bool sentinelAllowed) internal view {
        IVaultV2Roles vault = IVaultV2Roles(IMidnightAdapterMinimal(adapter).parentVault());
        bool hasRole = vault.isAllocator(onBehalf) || (sentinelAllowed && vault.isSentinel(onBehalf));
        bool isCaller = msg.sender == onBehalf
            || IMidnight(IMidnightAdapterMinimal(adapter).midnight()).isAuthorized(onBehalf, msg.sender);
        if (!hasRole || !isCaller) revert Unauthorized();
    }

    /// @dev Reverts unless `callbackData` is an allowed funding source of `adapter`'s buys. See FUNDING.
    function _checkFunding(address adapter, bytes memory callbackData) internal view {
        if (isFundingSource[adapter][keccak256(callbackData)]) return;
        if (!allowsRolling[adapter]) revert UnauthorizedFundingSource();
        (address fundingAdapter, bytes memory fundingData) = abi.decode(callbackData, (address, bytes));
        if (fundingAdapter != adapter) revert UnauthorizedFundingSource();
        if (abi.decode(fundingData, (Market)).maturity > block.timestamp) revert FundingMarketNotMatured();
    }

    /// @dev Returns the buy rate floor, the time to maturity, and the fraction of each bought unit (in WAD) that is net
    /// credit after Midnight's continuous fee. See BUYS.
    function _buyRateBound(address adapter, Market memory market)
        internal
        view
        returns (uint256 rate, uint256 ttm, uint256 netUnitsPerWad)
    {
        bytes32 id;
        IMarketMakingPolicy.CurvePoint[] storage curve;
        (id, ttm, curve) = _checkMarket(adapter, market);
        if (ttm < curve[0].ttm || ttm > curve[curve.length - 1].ttm) revert TtmOutOfRange();

        address _cadence = cadence[adapter];
        if (_cadence == address(0)) revert NoCadence();
        if (IRenewalCadence(_cadence).cadencePeriodStart(market.maturity) != market.maturity) {
            revert MaturityOffCadence();
        }

        IMidnight midnight = IMidnight(IMidnightAdapterMinimal(adapter).midnight());
        if (midnight.lossFactor(id) != 0) revert MarketHasLoss();
        // Midnight rounds the pending fee increase down, so the adapter's net credit is at least this.
        // No underflow: Midnight caps the continuous fee at 1% per year and the time to maturity at 100 years.
        netUnitsPerWad = WAD - uint256(midnight.continuousFee(id)) * ttm;
        rate = _interpolate(curve, true, ttm);
    }

    /// @dev Returns the sell rate ceiling and the time to maturity. See SELL GUARDRAILS.
    function _sellRateBound(address adapter, Market memory market) internal view returns (uint256 rate, uint256 ttm) {
        bytes32 id;
        IMarketMakingPolicy.CurvePoint[] storage curve;
        (id, ttm, curve) = _checkMarket(adapter, market);

        AdapterMarketData memory md = IMidnightAdapterMinimal(adapter).marketData(id);
        if (md.forceSellable) revert ForceSellable();
        rate = _interpolate(curve, false, ttm);
        if (md.netRate < rate) rate = md.netRate;
    }

    /// @dev Checks the maturity and loads the adapter's curve. See MARKET STATE.
    function _checkMarket(address adapter, Market memory market)
        internal
        view
        returns (bytes32 id, uint256 ttm, IMarketMakingPolicy.CurvePoint[] storage curve)
    {
        if (block.timestamp >= market.maturity) revert PostMaturity();
        ttm = market.maturity - block.timestamp;
        id = IdLib.toId(market);

        curve = curves[adapter][TenorMarketIdLib.toTenorMarketId(market)];
        if (curve.length == 0) revert NoCurve();
    }

    /// @dev Interpolates the buy or sell side of `curve` at `ttm`, clamping at the ends.
    function _interpolate(IMarketMakingPolicy.CurvePoint[] storage curve, bool buySide, uint256 ttm)
        internal
        view
        returns (uint256)
    {
        uint256 n = curve.length;
        uint256[] memory knots = new uint256[](n);
        uint256[] memory values = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            IMarketMakingPolicy.CurvePoint memory p = curve[i];
            knots[i] = p.ttm;
            values[i] = buySide ? p.buyRate : p.sellRate;
        }
        return LinearInterpolationLib.interpolate(knots, values, ttm);
    }
}
