// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MidnightWithdrawableCallback} from "../../src/callbacks/MidnightWithdrawableCallback.sol";
import {MidnightWithdrawableClamp} from "../../src/router/clamps/MidnightWithdrawableClamp.sol";
import {TenorRouter, ExecuteParams, Action, FillAxis, MidnightTakeData} from "../../src/router/TenorRouter.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {WAD, MAX_CONTINUOUS_FEE, maxSettlementFee} from "@midnight/libraries/ConstantsLib.sol";
import {enableDefaultLltvs} from "./LltvHelper.sol";
import {MockAcceptAllRatifier} from "./mocks/MockAcceptAllRatifier.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTenorRouter} from "./mocks/MockTenorRouter.sol";
import {Oracle} from "./Oracle.sol";
import {LIQUIDATION_CURSOR} from "./MaxLifLib.sol";

/// @dev Shared setup for MidnightWithdrawableCallback and MidnightWithdrawableClamp: a market with max settlement
/// and continuous fees, a lender whose credit is backed by LENDER_CREDIT of withdrawable, and a collateralized
/// borrower.
abstract contract MidnightWithdrawableTestBase is Test {
    using UtilsLib for uint256;

    MidnightWithdrawableCallback internal callback;
    MidnightWithdrawableClamp internal clamp;
    Midnight internal midnight;
    MockAcceptAllRatifier internal acceptAllRatifier;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;
    TenorRouter internal router;

    address internal lender; // Holds credit funded by an early repayment
    address internal borrower; // Has collateral, borrows at par from withdrawable
    address internal tempBorrower; // Borrows from the lender then repays early, creating withdrawable
    address internal attacker;

    Market internal market;
    bytes32 internal marketId;

    uint256 internal constant LENDER_CREDIT = 1000e18;
    uint256 internal constant COLLATERAL = 10_000e18;

    function setUp() public virtual {
        lender = makeAddr("Lender");
        borrower = makeAddr("Borrower");
        tempBorrower = makeAddr("TempBorrower");
        attacker = makeAddr("Attacker");

        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COL", 18);

        // 10:1 so collateral is worth more than loan token
        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeSetter(address(this));
        acceptAllRatifier = new MockAcceptAllRatifier();
        callback = new MidnightWithdrawableCallback(address(midnight));
        clamp = new MidnightWithdrawableClamp(IMidnight(address(midnight)));
        router = new MockTenorRouter(address(midnight));

        market = _market(address(0));
        marketId = _createMarketWithFees(market);

        _supplyCollateral(market, tempBorrower, COLLATERAL);
        _supplyCollateral(market, borrower, COLLATERAL);
        _setupLenderWithCredit(market, lender, LENDER_CREDIT);
    }

    function _market(address enterGate) internal view returns (Market memory) {
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
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: enterGate,
            liquidatorGate: address(0)
        });
    }

    /// @dev Creates the market with max settlement fees and max continuous fee, so fills exercise both.
    function _createMarketWithFees(Market memory targetMarket) internal returns (bytes32 id) {
        id = midnight.touchMarket(targetMarket);
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, maxSettlementFee(i));
        }
        midnight.setMarketContinuousFee(id, MAX_CONTINUOUS_FEE);
    }

    function _supplyCollateral(Market memory targetMarket, address user, uint256 amount) internal {
        collateralToken.mint(user, amount);
        vm.startPrank(user);
        collateralToken.approve(address(midnight), amount);
        midnight.supplyCollateral(targetMarket, 0, amount, user);
        vm.stopPrank();
    }

    /// @dev Gives the account `units` of credit and the market `units` of withdrawable: the account's par BUY offer is
    /// taken by tempBorrower, who then repays early.
    function _setupLenderWithCredit(Market memory targetMarket, address account, uint256 units) internal {
        loanToken.mint(account, units);
        vm.startPrank(account);
        loanToken.approve(address(midnight), units);
        midnight.setIsAuthorized(address(acceptAllRatifier), true, account);
        vm.stopPrank();

        Offer memory lenderOffer = _offer(targetMarket);
        lenderOffer.maker = account;
        lenderOffer.ratifier = address(acceptAllRatifier);
        lenderOffer.callback = address(0);

        vm.prank(tempBorrower);
        midnight.take(lenderOffer, "", units, tempBorrower, tempBorrower, address(0), "");

        loanToken.mint(tempBorrower, units);
        vm.startPrank(tempBorrower);
        loanToken.approve(address(midnight), units);
        midnight.repay(targetMarket, units, tempBorrower, address(0), "");
        vm.stopPrank();
    }

    /// @dev The callback's standing par BUY offer.
    function _offer(Market memory targetMarket) internal view returns (Offer memory) {
        return Offer({
            market: targetMarket,
            buy: true,
            maker: address(callback),
            start: block.timestamp,
            expiry: type(uint256).max,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(callback),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(callback),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _take(Offer memory offer, uint256 units, address taker) internal returns (uint256, uint256) {
        vm.prank(taker);
        return midnight.take(offer, "", units, taker, taker, address(0), "");
    }

    function _expectedSellerAssets(bytes32 id, uint256 units) internal view returns (uint256) {
        uint256 fee = midnight.settlementFee(id, market.maturity.zeroFloorSub(block.timestamp));
        return units.mulDivDown(WAD - fee, WAD);
    }

    function _assertCallbackHoldsNothing(bytes32 id) internal view {
        (uint128 credit, uint128 pendingFee,,, uint128 debt,) = midnight.position(id, address(callback));
        assertEq(credit, 0, "callback credit");
        assertEq(pendingFee, 0, "callback pendingFee");
        assertEq(debt, 0, "callback debt");
        assertEq(loanToken.balanceOf(address(callback)), 0, "callback balance");
        assertEq(loanToken.allowance(address(callback), address(midnight)), 0, "callback allowance");
    }

    function _routerAction(uint256 units, address receiver) internal view returns (Action memory) {
        return Action({
            take: MidnightTakeData({
                takeUnits: units,
                takerCallback: address(0),
                takerCallbackData: "",
                receiverIfTakerIsSeller: receiver,
                ratifierData: ""
            }),
            allowRevert: false,
            offer: _offer(market),
            clamp: address(clamp),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    function _routerParams(bool reduceOnly) internal pure returns (ExecuteParams memory) {
        return ExecuteParams({
            deadline: 0,
            fillAxis: FillAxis.UNITS,
            maxFill: type(uint128).max,
            minFill: 0,
            minPrice: 0,
            maxPrice: type(uint256).max,
            maxContinuousFee: type(uint256).max,
            reduceOnly: reduceOnly
        });
    }
}
