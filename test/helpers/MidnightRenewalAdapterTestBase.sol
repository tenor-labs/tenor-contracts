// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {MidnightRenewalAdapter} from "../../src/bundler/MidnightRenewalAdapter.sol";
import {TenorAdapter} from "../../src/bundler/TenorAdapter.sol";
import {ExecuteParams, FillAxis, Action, MidnightTakeData} from "../../src/router/TenorRouter.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {WAD, DEFAULT_TICK_SPACING, ORACLE_PRICE_SCALE} from "@midnight/libraries/ConstantsLib.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Oracle} from "./Oracle.sol";
import {Fixtures} from "./Fixtures.sol";
import {LIQUIDATION_CURSOR} from "./MaxLifLib.sol";
import {enableDefaultLltvs} from "./LltvHelper.sol";

/// @dev All `midnightRenew` / `midnightRenewLend` arguments, so tests can tweak one field of a default roll.
struct BorrowRoll {
    Market source;
    uint256 repayUnits;
    ExecuteParams exitParams;
    Action[] exitActions;
    ExecuteParams borrowParams;
    Action[] borrowActions;
    int256 maxForwardRate;
    bytes32 consumeGroup;
    uint128 maxConsumed;
}

struct LendRoll {
    Market source;
    uint256 withdrawUnits;
    ExecuteParams exitParams;
    Action[] exitActions;
    ExecuteParams lendParams;
    Action[] lendActions;
    int256 minForwardRate;
    bytes32 consumeGroup;
    uint128 maxConsumed;
}

/// @title MidnightRenewalAdapterTestBase
/// @notice Real Midnight + Bundler3 fixture for `MidnightRenewalAdapter`.
/// @dev Borrow rolls run as production bundles do: `TenorAdapter.midnightFlashLoan` funds the exit, the reentered
///      bundle moves the loan into the renewal adapter, calls `midnightRenew`, and sweeps the adapter back to
///      `TenorAdapter` for the flash-loan repayment. Every successful call can therefore assert that both adapters
///      end empty.
/// @dev Actors:
///      - `borrower` owes `BORROW_DEBT` on `source` to `srcLender`, collateralized with `col0` and `col1`.
///      - `srcLender` sells its source credit back through SELL offers (the borrow-side exit liquidity).
///      - `tgtLender` buys units on the target through BUY offers (the borrow-side entry liquidity).
///      - `lender` holds `LEND_CREDIT` on `source`, lent to `srcBorrower`; `otherLender` holds `OTHER_CREDIT`.
///        `srcBorrower` repaid `INITIAL_WITHDRAWABLE` at par, which is the source pool's withdrawable liquidity.
///      - `srcBuyer` buys source credit through BUY offers (the lend-side exit liquidity).
///      - `tgtBorrower` sells units on the target through SELL offers (the lend-side entry liquidity).
abstract contract MidnightRenewalAdapterTestBase is Fixtures {
    using UtilsLib for uint256;

    MidnightRenewalAdapter internal adapter;
    TenorAdapter internal tenorAdapter;
    Midnight internal midnight;
    IBundler3 internal bundler3;
    EcrecoverRatifier internal ratifier;

    MockERC20 internal loanToken;
    MockERC20 internal otherLoanToken;
    MockERC20 internal col0;
    MockERC20 internal col1;
    Oracle internal oracle0;
    Oracle internal oracle1;

    Market internal source;
    Market internal target;
    bytes32 internal sourceId;
    bytes32 internal targetId;

    address internal borrower;
    uint256 internal borrowerSK;
    address internal lender;
    uint256 internal lenderSK;
    address internal otherLender;
    address internal srcLender;
    uint256 internal srcLenderSK;
    address internal tgtLender;
    uint256 internal tgtLenderSK;
    address internal srcBorrower;
    uint256 internal srcBorrowerSK;
    address internal srcBuyer;
    uint256 internal srcBuyerSK;
    address internal tgtBorrower;
    uint256 internal tgtBorrowerSK;
    address internal attacker;
    uint256 internal attackerSK;

    uint256 internal constant SOURCE_TTM = 7 days;
    uint256 internal constant DELTA = 30 days;

    uint256 internal constant BORROW_DEBT = 500e18;
    uint256 internal constant BORROWER_COL0 = 600e18;
    uint256 internal constant BORROWER_COL1 = 401e18;

    uint256 internal constant LEND_CREDIT = 500e18;
    uint256 internal constant OTHER_CREDIT = 300e18;
    uint256 internal constant INITIAL_WITHDRAWABLE = 200e18;

    /// @dev Source exit offers trade near par, target entries at a discount: the roll pays a positive forward rate.
    uint256 internal SOURCE_TICK;
    uint256 internal TARGET_TICK;

    uint256 internal _groupNonce;

    function setUp() public virtual {
        (borrower, borrowerSK) = makeAddrAndKey("Borrower");
        (lender, lenderSK) = makeAddrAndKey("Lender");
        otherLender = makeAddr("OtherLender");
        (srcLender, srcLenderSK) = makeAddrAndKey("SrcLender");
        (tgtLender, tgtLenderSK) = makeAddrAndKey("TgtLender");
        (srcBorrower, srcBorrowerSK) = makeAddrAndKey("SrcBorrower");
        (srcBuyer, srcBuyerSK) = makeAddrAndKey("SrcBuyer");
        (tgtBorrower, tgtBorrowerSK) = makeAddrAndKey("TgtBorrower");
        (attacker, attackerSK) = makeAddrAndKey("Attacker");

        SOURCE_TICK = TickLib.priceToTick(0.999e18, DEFAULT_TICK_SPACING);
        TARGET_TICK = TickLib.priceToTick(0.98e18, DEFAULT_TICK_SPACING);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ratifier = new EcrecoverRatifier(address(midnight));
        bundler3 = deployBundler3();
        adapter = new MidnightRenewalAdapter(address(bundler3), address(midnight));
        tenorAdapter = new TenorAdapter(address(bundler3), address(midnight), makeAddr("MigrationRatifier"));

        loanToken = new MockERC20("Loan", "LOAN", 18);
        otherLoanToken = new MockERC20("Other loan", "LOAN2", 18);
        (col0, col1) = _sortedCollaterals();
        oracle0 = new Oracle();
        oracle1 = new Oracle();

        source = _market(block.timestamp + SOURCE_TTM, 2, 0.945e18);
        target = _market(block.timestamp + SOURCE_TTM + DELTA, 2, 0.945e18);
        sourceId = IdLib.toId(source);
        targetId = IdLib.toId(target);

        address[9] memory actors =
            [borrower, lender, otherLender, srcLender, tgtLender, srcBorrower, srcBuyer, tgtBorrower, attacker];
        for (uint256 i; i < actors.length; i++) {
            vm.startPrank(actors[i]);
            midnight.setIsAuthorized(address(ratifier), true, actors[i]);
            loanToken.approve(address(midnight), type(uint256).max);
            col0.approve(address(midnight), type(uint256).max);
            col1.approve(address(midnight), type(uint256).max);
            vm.stopPrank();
            loanToken.mint(actors[i], 1_000_000e18);
        }

        vm.prank(borrower);
        midnight.setIsAuthorized(address(adapter), true, borrower);
        vm.prank(lender);
        midnight.setIsAuthorized(address(adapter), true, lender);

        // Flash-loan liquidity for the borrow-side bundles. Midnight's accounting ignores raw balances.
        loanToken.mint(address(midnight), 10_000_000e18);

        _openBorrowerPosition(source, BORROW_DEBT, BORROWER_COL0, BORROWER_COL1);
        _openLenderPositions();
    }

    /* ═══════ Market and position setup ═══════ */

    function _sortedCollaterals() internal returns (MockERC20 a, MockERC20 b) {
        a = new MockERC20("Collateral A", "COLA", 18);
        b = new MockERC20("Collateral B", "COLB", 18);
        if (address(a) > address(b)) (a, b) = (b, a);
    }

    /// @dev `nCollaterals == 1` lists `col0` only; `2` lists `col0` and `col1`.
    function _market(uint256 maturity, uint256 nCollaterals, uint256 lltv) internal view returns (Market memory m) {
        CollateralParams[] memory collaterals = new CollateralParams[](nCollaterals);
        collaterals[0] = CollateralParams({
            token: address(col0), lltv: lltv, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle0)
        });
        if (nCollaterals == 2) {
            collaterals[1] = CollateralParams({
                token: address(col1), lltv: lltv, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle1)
            });
        }
        m = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    /// @dev `borrower` supplies collateral on `m` and borrows `debt` units from `srcLender`'s BUY offer at par-ish.
    function _openBorrowerPosition(Market memory m, uint256 debt, uint256 c0, uint256 c1) internal {
        col0.mint(borrower, c0);
        col1.mint(borrower, c1);
        vm.startPrank(borrower);
        if (c0 != 0) midnight.supplyCollateral(m, 0, c0, borrower);
        if (c1 != 0) midnight.supplyCollateral(m, 1, c1, borrower);
        vm.stopPrank();

        Offer memory o = _offer(m, true, srcLender, SOURCE_TICK, debt);
        vm.prank(borrower);
        midnight.take(o, _ratifierData(o, srcLenderSK), debt, borrower, borrower, address(0), "");
    }

    function _openLenderPositions() internal {
        col0.mint(srcBorrower, 100_000e18);
        vm.prank(srcBorrower);
        midnight.supplyCollateral(source, 0, 100_000e18, srcBorrower);

        _lendTo(source, lender, srcBorrower, srcBorrowerSK, LEND_CREDIT);
        _lendTo(source, otherLender, srcBorrower, srcBorrowerSK, OTHER_CREDIT);

        vm.prank(srcBorrower);
        midnight.repay(source, INITIAL_WITHDRAWABLE, srcBorrower, address(0), "");

        col0.mint(tgtBorrower, 100_000e18);
        vm.prank(tgtBorrower);
        midnight.supplyCollateral(target, 0, 100_000e18, tgtBorrower);
    }

    /// @dev `who` buys `units` of `m` from `seller`'s SELL offer.
    function _lendTo(Market memory m, address who, address seller, uint256 sellerSK, uint256 units) internal {
        Offer memory o = _offer(m, false, seller, SOURCE_TICK, units);
        vm.prank(who);
        midnight.take(o, _ratifierData(o, sellerSK), units, who, address(0), address(0), "");
    }

    /* ═══════ Offers and actions ═══════ */

    function _offer(Market memory m, bool buy, address maker, uint256 tick, uint256 maxUnits)
        internal
        returns (Offer memory)
    {
        return Offer({
            market: m,
            buy: buy,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 days,
            tick: tick,
            group: keccak256(abi.encode("group", ++_groupNonce)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: buy ? address(0) : maker,
            ratifier: address(ratifier),
            reduceOnly: false,
            maxUnits: uint128(maxUnits),
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _ratifierData(Offer memory offer, uint256 sk) internal view returns (bytes memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domain = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ratifier)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, keccak256(bytes.concat("\x19\x01", domain, structHash)));
        return abi.encode(Signature({v: v, r: r, s: s}), root, uint256(0), new bytes32[](0));
    }

    /// @dev Taker-side receiver is the adapter for BUY offers (the taker sells) and must be zero for SELL offers.
    function _action(Offer memory offer, uint256 makerSK) internal view returns (Action memory) {
        return _action(offer, makerSK, offer.buy ? address(adapter) : address(0));
    }

    function _action(Offer memory offer, uint256 makerSK, address receiverIfTakerIsSeller)
        internal
        view
        returns (Action memory)
    {
        return Action({
            take: MidnightTakeData({
                takeUnits: type(uint128).max,
                takerCallback: address(0),
                takerCallbackData: "",
                receiverIfTakerIsSeller: receiverIfTakerIsSeller,
                ratifierData: _ratifierData(offer, makerSK)
            }),
            allowRevert: false,
            offer: offer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    function _one(Action memory a) internal pure returns (Action[] memory actions) {
        actions = new Action[](1);
        actions[0] = a;
    }

    function _two(Action memory a, Action memory b) internal pure returns (Action[] memory actions) {
        actions = new Action[](2);
        actions[0] = a;
        actions[1] = b;
    }

    function _params(FillAxis axis, uint256 maxFill, uint256 minFill, bool reduceOnly)
        internal
        pure
        returns (ExecuteParams memory)
    {
        return ExecuteParams({
            deadline: 0,
            fillAxis: axis,
            maxFill: maxFill,
            minFill: minFill,
            minPrice: 0,
            maxPrice: type(uint256).max,
            maxContinuousFee: type(uint256).max,
            reduceOnly: reduceOnly
        });
    }

    /// @dev Source exit liquidity for the borrow side: `srcLender` sells back up to `units` of its credit.
    function _srcSellAction(uint256 units) internal returns (Action memory) {
        return _srcSellAction(units, SOURCE_TICK);
    }

    function _srcSellAction(uint256 units, uint256 tick) internal returns (Action memory) {
        return _action(_offer(source, false, srcLender, tick, units), srcLenderSK);
    }

    /// @dev Target entry liquidity for the borrow side: `tgtLender` buys up to `units` on `m`.
    function _tgtBuyAction(Market memory m, uint256 units, uint256 tick) internal returns (Action memory) {
        return _action(_offer(m, true, tgtLender, tick, units), tgtLenderSK);
    }

    /// @dev Source exit liquidity for the lend side: `srcBuyer` buys up to `units` of source credit.
    function _srcBuyAction(uint256 units) internal returns (Action memory) {
        return _srcBuyAction(units, SOURCE_TICK);
    }

    function _srcBuyAction(uint256 units, uint256 tick) internal returns (Action memory) {
        return _action(_offer(source, true, srcBuyer, tick, units), srcBuyerSK);
    }

    /// @dev Target entry liquidity for the lend side: `tgtBorrower` sells up to `units` on `m`.
    function _tgtSellAction(Market memory m, uint256 units, uint256 tick) internal returns (Action memory) {
        return _action(_offer(m, false, tgtBorrower, tick, units), tgtBorrowerSK);
    }

    /* ═══════ Default rolls ═══════ */

    /// @dev Borrow roll of `repayUnits`: up to `exitUnits` through `srcLender`'s offer, the rest at par, into
    ///      `tgtLender`'s target offer. `exitUnits == 0` builds no exit batch. No forward-rate bound.
    function _borrowRoll(uint256 repayUnits, uint256 exitUnits) internal returns (BorrowRoll memory r) {
        r.source = source;
        r.repayUnits = repayUnits;
        r.exitParams = _params(FillAxis.UNITS, 0, 0, false);
        r.exitActions = exitUnits == 0 ? new Action[](0) : _one(_srcSellAction(exitUnits));
        r.borrowParams = _params(FillAxis.ASSETS, 0, 0, false);
        r.borrowActions = _one(_tgtBuyAction(target, type(uint128).max, TARGET_TICK));
        r.maxForwardRate = type(int256).max;
        r.maxConsumed = type(uint128).max;
    }

    /// @dev Lend roll: withdraw up to `withdrawUnits` at par, sell up to `exitUnits` into `srcBuyer`'s offer (the
    ///      batch's maxFill is the credit left after the withdrawal), lend everything into `tgtBorrower`'s offer.
    ///      `exitUnits == 0` builds no exit batch. Zero forward-rate floor.
    function _lendRoll(uint256 withdrawUnits, uint256 exitUnits) internal returns (LendRoll memory r) {
        r.source = source;
        r.withdrawUnits = withdrawUnits;
        r.exitParams = _params(FillAxis.UNITS, type(uint256).max, 0, true);
        r.exitActions = exitUnits == 0 ? new Action[](0) : _one(_srcBuyAction(exitUnits));
        r.lendParams = _params(FillAxis.ASSETS, 0, 0, false);
        r.lendActions = _one(_tgtSellAction(target, type(uint128).max, TARGET_TICK));
        r.maxConsumed = type(uint128).max;
    }

    /* ═══════ Bundles ═══════ */

    function _renewCall(BorrowRoll memory r) internal view returns (bytes memory) {
        return abi.encodeCall(
            adapter.midnightRenew,
            (
                r.source,
                r.repayUnits,
                r.exitParams,
                r.exitActions,
                r.borrowParams,
                r.borrowActions,
                r.maxForwardRate,
                r.consumeGroup,
                r.maxConsumed
            )
        );
    }

    function _renewLendCall(LendRoll memory r) internal view returns (bytes memory) {
        return abi.encodeCall(
            adapter.midnightRenewLend,
            (
                r.source,
                r.withdrawUnits,
                r.exitParams,
                r.exitActions,
                r.lendParams,
                r.lendActions,
                r.minForwardRate,
                r.consumeGroup,
                r.maxConsumed
            )
        );
    }

    /// @dev Flash amount covering any exit: every unit repaid costs at most par plus the settlement fee.
    function _flashAmount(BorrowRoll memory r) internal view returns (uint256) {
        uint256 debt = midnight.debt(IdLib.toId(r.source), borrower);
        uint256 units = r.repayUnits == type(uint256).max || r.repayUnits > debt ? debt : r.repayUnits;
        return units + units / 100 + 1;
    }

    /// @dev TenorAdapter.midnightFlashLoan -> reenter [fund renewal adapter, midnightRenew, sweep back].
    function _borrowBundle(BorrowRoll memory r) internal view returns (Call[] memory calls) {
        uint256 flash = _flashAmount(r);
        Call[] memory inner = new Call[](3);
        inner[0] = _call(
            address(tenorAdapter),
            abi.encodeCall(tenorAdapter.erc20Transfer, (address(loanToken), address(adapter), flash))
        );
        inner[1] = _call(address(adapter), _renewCall(r));
        inner[2] = _call(
            address(adapter),
            abi.encodeCall(adapter.erc20Transfer, (address(loanToken), address(tenorAdapter), type(uint256).max))
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(loanToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flash;
        bytes memory reenterData = abi.encode(inner);

        calls = new Call[](1);
        calls[0] = Call({
            to: address(tenorAdapter),
            data: abi.encodeCall(tenorAdapter.midnightFlashLoan, (tokens, amounts, reenterData)),
            value: 0,
            skipRevert: false,
            callbackHash: keccak256(reenterData)
        });
    }

    function _lendBundle(LendRoll memory r) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = _call(address(adapter), _renewLendCall(r));
    }

    function _renew(BorrowRoll memory r) internal {
        _renewAs(borrower, r);
    }

    function _renewAs(address initiator, BorrowRoll memory r) internal {
        Call[] memory calls = _borrowBundle(r);
        vm.prank(initiator);
        bundler3.multicall(calls);
    }

    function _renewExpectRevert(BorrowRoll memory r, bytes memory err) internal {
        Call[] memory calls = _borrowBundle(r);
        vm.prank(borrower);
        vm.expectRevert(err);
        bundler3.multicall(calls);
    }

    /// @dev Builds the bundle before arming the expectation, so the view calls it makes cannot consume it.
    function _renewExpectPartialRevert(BorrowRoll memory r, bytes4 selector) internal {
        Call[] memory calls = _borrowBundle(r);
        vm.prank(borrower);
        vm.expectPartialRevert(selector);
        bundler3.multicall(calls);
    }

    function _renewLendExpectPartialRevert(LendRoll memory r, bytes4 selector) internal {
        Call[] memory calls = _lendBundle(r);
        vm.prank(lender);
        vm.expectPartialRevert(selector);
        bundler3.multicall(calls);
    }

    function _renewLend(LendRoll memory r) internal {
        _renewLendAs(lender, r);
    }

    function _renewLendAs(address initiator, LendRoll memory r) internal {
        Call[] memory calls = _lendBundle(r);
        vm.prank(initiator);
        bundler3.multicall(calls);
    }

    function _renewLendExpectRevert(LendRoll memory r, bytes memory err) internal {
        Call[] memory calls = _lendBundle(r);
        vm.prank(lender);
        vm.expectRevert(err);
        bundler3.multicall(calls);
    }

    /* ═══════ Dry runs and bounds ═══════ */

    /// @dev New target debt of `r` run without a bound, state rolled back.
    function _dryRunNewDebt(BorrowRoll memory r) internal returns (uint256 newDebt) {
        uint256 snap = vm.snapshotState();
        int256 maxRate = r.maxForwardRate;
        r.maxForwardRate = type(int256).max;
        uint256 before = midnight.debt(IdLib.toId(r.borrowActions[0].offer.market), borrower);
        _renew(r);
        newDebt = midnight.debt(IdLib.toId(r.borrowActions[0].offer.market), borrower) - before;
        r.maxForwardRate = maxRate;
        vm.revertToState(snap);
    }

    /// @dev New target credit and source credit closed by `r` run without a floor, state rolled back.
    function _dryRunLend(LendRoll memory r) internal returns (uint256 newCredit, uint256 closed) {
        uint256 snap = vm.snapshotState();
        int256 minRate = r.minForwardRate;
        r.minForwardRate = type(int256).min;
        Market memory tgt = r.lendActions[0].offer.market;
        uint256 creditTgtBefore = _credit(tgt, lender);
        uint256 creditSrcBefore = _credit(r.source, lender);
        _renewLend(r);
        newCredit = _credit(tgt, lender) - creditTgtBefore;
        closed = creditSrcBefore - _credit(r.source, lender);
        r.minForwardRate = minRate;
        vm.revertToState(snap);
    }

    function _factor(int256 rate, uint256 delta) internal pure returns (uint256) {
        int256 factor = int256(WAD) + rate * int256(delta);
        require(factor > 0, "factor");
        return uint256(factor);
    }

    function _maxNewDebt(uint256 repayUnits, int256 rate, uint256 delta) internal pure returns (uint256) {
        return repayUnits.mulDivDown(_factor(rate, delta), WAD);
    }

    function _minNewCredit(uint256 closed, int256 rate, uint256 delta) internal pure returns (uint256) {
        return closed.mulDivUp(_factor(rate, delta), WAD);
    }

    /// @dev Smallest `maxForwardRate` the roll passes with: ceil((newDebt - repayUnits) * WAD / (repayUnits * delta)).
    function _tightestMaxRate(uint256 repayUnits, uint256 newDebt, uint256 delta) internal pure returns (int256) {
        int256 num = (int256(newDebt) - int256(repayUnits)) * int256(WAD);
        int256 den = int256(repayUnits * delta);
        return num >= 0 ? (num + den - 1) / den : num / den;
    }

    /// @dev Largest `minForwardRate` the roll passes with: floor((newCredit - closed) * WAD / (closed * delta)).
    function _tightestMinRate(uint256 closed, uint256 newCredit, uint256 delta) internal pure returns (int256) {
        int256 num = (int256(newCredit) - int256(closed)) * int256(WAD);
        int256 den = int256(closed * delta);
        return num >= 0 ? num / den : (num - den + 1) / den;
    }

    /* ═══════ State reads and invariants ═══════ */

    function _credit(Market memory m, address user) internal view returns (uint256) {
        (uint128 c,,) = midnight.updatePositionView(m, IdLib.toId(m), user);
        return c;
    }

    function _collateral(Market memory m, address user, uint256 i) internal view returns (uint256) {
        return midnight.collateral(IdLib.toId(m), user, i);
    }

    /// @dev Debt over collateral value, in WAD; collateral valued at the oracle price.
    function _ltv(Market memory m, address user) internal view returns (uint256) {
        bytes32 id = IdLib.toId(m);
        uint256 value;
        for (uint256 i; i < m.collateralParams.length; i++) {
            uint256 price = Oracle(m.collateralParams[i].oracle).price();
            value += uint256(midnight.collateral(id, user, i)).mulDivDown(price, ORACLE_PRICE_SCALE);
        }
        if (value == 0) return midnight.debt(id, user) == 0 ? 0 : type(uint256).max;
        return uint256(midnight.debt(id, user)).mulDivDown(WAD, value);
    }

    /// @dev The adapter (and the TenorAdapter that funded it) end every successful bundle empty: no loan token, no
    ///      collateral, no position on either market.
    function _assertAdaptersEmpty(Market memory src, Market memory tgt) internal view {
        address[2] memory holders = [address(adapter), address(tenorAdapter)];
        for (uint256 h; h < holders.length; h++) {
            assertEq(loanToken.balanceOf(holders[h]), 0, "adapter holds loan token");
            assertEq(col0.balanceOf(holders[h]), 0, "adapter holds col0");
            assertEq(col1.balanceOf(holders[h]), 0, "adapter holds col1");
        }
        Market[2] memory markets = [src, tgt];
        for (uint256 i; i < markets.length; i++) {
            bytes32 id = IdLib.toId(markets[i]);
            assertEq(midnight.debt(id, address(adapter)), 0, "adapter has debt");
            assertEq(midnight.credit(id, address(adapter)), 0, "adapter has credit");
            for (uint256 c; c < markets[i].collateralParams.length; c++) {
                assertEq(midnight.collateral(id, address(adapter), c), 0, "adapter has collateral");
            }
        }
    }
}
