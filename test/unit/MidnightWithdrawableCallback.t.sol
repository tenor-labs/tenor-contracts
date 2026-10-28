// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {stdError} from "forge-std/StdError.sol";
import {MidnightWithdrawableTestBase} from "../helpers/MidnightWithdrawableTestBase.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {MidnightAllowlistGate} from "@gates/MidnightAllowlistGate.sol";
import {IMidnight, Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {ISellCallback} from "@midnight/interfaces/ICallbacks.sol";
import {CALLBACK_SUCCESS, MAX_CONTINUOUS_FEE} from "@midnight/libraries/ConstantsLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {MockDecrementingERC20} from "../helpers/mocks/MockDecrementingERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Taker whose seller callback takes the same offer again, nesting a second fill inside the first.
contract NestedTaker is ISellCallback {
    IMidnight internal immutable MORPHO_MIDNIGHT;

    constructor(IMidnight morphoMidnight) {
        MORPHO_MIDNIGHT = morphoMidnight;
    }

    function take(Offer memory offer, uint256 units, uint256 nestedUnits) external {
        MORPHO_MIDNIGHT.take(
            offer, "", units, address(this), address(this), address(this), abi.encode(offer, nestedUnits)
        );
    }

    function onSell(bytes32, Market memory, uint256, uint256, uint256, address, address, bytes memory data)
        external
        returns (bytes32)
    {
        (Offer memory offer, uint256 nestedUnits) = abi.decode(data, (Offer, uint256));
        MORPHO_MIDNIGHT.take(offer, "", nestedUnits, address(this), address(this), address(0), "");
        return CALLBACK_SUCCESS;
    }
}

contract MidnightWithdrawableCallbackTest is MidnightWithdrawableTestBase {
    /* ========== SETUP ========== */

    function test_setUp() public view {
        assertTrue(midnight.isAuthorized(address(callback), address(callback)));
        assertEq(midnight.credit(marketId, lender), LENDER_CREDIT);
        assertEq(midnight.withdrawable(marketId), LENDER_CREDIT);
        assertGt(midnight.settlementFee(marketId, 30 days), 0);
    }

    /* ========== LENDER RESALE ========== */

    function test_lenderResellsAtPar() public {
        uint256 units = LENDER_CREDIT / 2;
        uint256 claimableBefore = midnight.claimableSettlementFee(address(loanToken));

        (uint256 buyerAssets, uint256 sellerAssets) = _take(_offer(market), units, lender);

        assertEq(buyerAssets, units, "buyerAssets");
        assertEq(sellerAssets, _expectedSellerAssets(marketId, units), "sellerAssets");
        assertEq(loanToken.balanceOf(lender), sellerAssets, "lender received");
        assertEq(midnight.credit(marketId, lender), LENDER_CREDIT - units, "lender credit");
        assertEq(midnight.debt(marketId, lender), 0, "lender debt");
        assertEq(midnight.withdrawable(marketId), LENDER_CREDIT - units, "withdrawable");
        assertEq(midnight.claimableSettlementFee(address(loanToken)) - claimableBefore, units - sellerAssets, "fee");
        _assertCallbackHoldsNothing(marketId);
    }

    function test_lenderExitsPostMaturity() public {
        vm.warp(market.maturity + 1);
        (uint128 credit,,) = midnight.updatePositionView(market, marketId, lender);

        _take(_offer(market), credit, lender);

        assertEq(midnight.credit(marketId, lender), 0, "lender credit");
        assertEq(midnight.debt(marketId, lender), 0, "lender debt");
        _assertCallbackHoldsNothing(marketId);
    }

    /* ========== BORROWER AT 0% ========== */

    function test_borrowerBorrowsAtPar() public {
        uint256 units = LENDER_CREDIT;

        (, uint256 sellerAssets) = _take(_offer(market), units, borrower);

        assertEq(sellerAssets, _expectedSellerAssets(marketId, units), "sellerAssets");
        assertEq(loanToken.balanceOf(borrower), sellerAssets, "borrower received");
        assertEq(midnight.debt(marketId, borrower), units, "borrower debt");
        assertEq(midnight.withdrawable(marketId), 0, "withdrawable");
        // Lender credit is now backed by the borrower's debt instead of withdrawable.
        assertEq(midnight.credit(marketId, lender), LENDER_CREDIT, "lender credit");
        _assertCallbackHoldsNothing(marketId);
    }

    function test_unhealthyBorrowerReverts() public {
        address poorBorrower = makeAddr("PoorBorrower");
        _supplyCollateral(market, poorBorrower, 1e18); // Worth 10 loan tokens

        vm.prank(poorBorrower);
        vm.expectRevert(IMidnight.SellerIsLiquidatable.selector);
        midnight.take(_offer(market), "", 100e18, poorBorrower, poorBorrower, address(0), "");
    }

    function test_borrowPostMaturityReverts() public {
        vm.warp(market.maturity + 1);

        vm.prank(borrower);
        vm.expectRevert(IMidnight.CannotIncreaseDebtPostMaturity.selector);
        midnight.take(_offer(market), "", 1e18, borrower, borrower, address(0), "");
    }

    /* ========== WITHDRAWABLE CAP ========== */

    function test_takeAboveWithdrawableReverts() public {
        vm.prank(borrower);
        vm.expectRevert(stdError.arithmeticError);
        midnight.take(_offer(market), "", LENDER_CREDIT + 1, borrower, borrower, address(0), "");
    }

    function test_zeroUnitsReverts() public {
        vm.prank(borrower);
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        midnight.take(_offer(market), "", 0, borrower, borrower, address(0), "");
    }

    function test_zeroUnitsOnEmptyWithdrawableReverts() public {
        _take(_offer(market), LENDER_CREDIT, borrower);

        vm.prank(lender);
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        midnight.take(_offer(market), "", 0, lender, lender, address(0), "");
    }

    function test_maxAssetsOffer() public {
        Offer memory offer = _offer(market);
        offer.maxUnits = 0;
        offer.maxAssets = type(uint128).max;

        _take(offer, 100e18, borrower);

        // At par, buyerAssets == units, so consumed grows by units on the asset axis too.
        assertEq(midnight.consumed(address(callback), offer.group), 100e18, "consumed");
        assertEq(midnight.debt(marketId, borrower), 100e18, "borrower debt");
        _assertCallbackHoldsNothing(marketId);
    }

    function test_nestedTakeFromSellerCallback() public {
        NestedTaker nestedTaker = new NestedTaker(IMidnight(address(midnight)));
        _supplyCollateral(market, address(nestedTaker), COLLATERAL);

        nestedTaker.take(_offer(market), 300e18, 200e18);

        assertEq(midnight.debt(marketId, address(nestedTaker)), 500e18, "taker debt");
        assertEq(midnight.withdrawable(marketId), LENDER_CREDIT - 500e18, "withdrawable");
        assertEq(
            loanToken.balanceOf(address(nestedTaker)),
            _expectedSellerAssets(marketId, 300e18) + _expectedSellerAssets(marketId, 200e18),
            "taker received"
        );
        _assertCallbackHoldsNothing(marketId);
    }

    /* ========== BAD DEBT ========== */

    function test_lenderResaleAfterBadDebt() public {
        _take(_offer(market), 400e18, borrower);

        // Collateral goes to zero and the borrower's whole debt is realized as bad debt.
        oracle.setPrice(0);
        midnight.liquidate(market, 0, 0, 0, borrower, false, address(this), address(0), "");
        oracle.setPrice(10e36);
        assertGt(midnight.lossFactor(marketId), 0, "lossFactor");

        (uint128 slashedCredit,,) = midnight.updatePositionView(market, marketId, lender);
        assertLt(slashedCredit, LENDER_CREDIT, "lender slashed");

        uint256 units = UtilsLib.min(slashedCredit, midnight.withdrawable(marketId));
        _take(_offer(market), units, lender);

        assertEq(midnight.credit(marketId, lender), slashedCredit - units, "lender credit");
        assertEq(midnight.debt(marketId, lender), 0, "lender debt");
        _assertCallbackHoldsNothing(marketId);
    }

    /* ========== AUTHORIZATION ========== */

    function test_thirdPartyCannotTakeForVictim() public {
        vm.prank(attacker);
        vm.expectRevert(IMidnight.TakerUnauthorized.selector);
        midnight.take(_offer(market), "", 1e18, borrower, attacker, address(0), "");
    }

    function test_authorizingCallbackGrantsNothing() public {
        vm.prank(borrower);
        midnight.setIsAuthorized(address(callback), true, borrower);

        // An offer made on the borrower's behalf with this contract as ratifier is rejected.
        Offer memory offer = _offer(market);
        offer.maker = borrower;

        vm.prank(attacker);
        vm.expectRevert(CallbackLib.NotSelf.selector);
        midnight.take(offer, "", 1e18, attacker, attacker, address(0), "");
    }

    /* ========== OFFER SHAPE ========== */

    function test_otherCallbackReverts() public {
        Offer memory offer = _offer(market);
        offer.callback = address(0);

        vm.prank(borrower);
        vm.expectRevert(CallbackLib.NotSelf.selector);
        midnight.take(offer, "", 1e18, borrower, borrower, address(0), "");
    }

    function test_sellOfferReverts() public {
        Offer memory offer = _offer(market);
        offer.buy = false;

        vm.prank(borrower);
        vm.expectRevert(CallbackLib.NotSelf.selector);
        midnight.take(offer, "", 1e18, borrower, address(0), address(0), "");
    }

    function test_belowParReverts() public {
        Offer memory offer = _offer(market);
        offer.tick = MAX_TICK - midnight.tickSpacing(marketId);

        vm.prank(borrower);
        vm.expectRevert(CallbackLib.NotPar.selector);
        midnight.take(offer, "", 1e18, borrower, borrower, address(0), "");
    }

    function test_reduceOnlyReverts() public {
        Offer memory offer = _offer(market);
        offer.reduceOnly = true;

        vm.prank(borrower);
        vm.expectRevert(IMidnight.MakerCreditOrDebtIncreased.selector);
        midnight.take(offer, "", 1e18, borrower, borrower, address(0), "");
    }

    function test_otherRatifierReverts() public {
        // A below-par offer as this contract, ratified elsewhere, is rejected before isRatified is even called.
        Offer memory offer = _offer(market);
        offer.ratifier = address(acceptAllRatifier);
        offer.tick = MAX_TICK - midnight.tickSpacing(marketId);

        vm.prank(borrower);
        vm.expectRevert(IMidnight.RatifierUnauthorized.selector);
        midnight.take(offer, "", 1e18, borrower, borrower, address(0), "");
    }

    function test_foreignOfferWithThisCallbackReverts() public {
        // The lender's own BUY offer, ratified elsewhere, pointing its callback here.
        Offer memory offer = _offer(market);
        offer.maker = lender;
        offer.ratifier = address(acceptAllRatifier);

        vm.prank(borrower);
        vm.expectRevert(CallbackLib.NotSelf.selector);
        midnight.take(offer, "", 1e18, borrower, borrower, address(0), "");
    }

    function test_onBuyOnlyMidnight() public {
        vm.prank(attacker);
        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onBuy(marketId, market, 1e18, 1e18, 0, address(callback), "");
    }

    function testFuzz_onBuyZeroAmountReverts(uint256 buyerAssets, uint256 units, bool zeroUnits) public {
        if (zeroUnits) units = 0;
        else buyerAssets = 0;

        vm.prank(address(midnight));
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        callback.onBuy(marketId, market, buyerAssets, units, 0, address(callback), "");
    }

    /* ========== APPROVAL ========== */

    function test_firstFillApprovesMidnightMax() public {
        assertEq(loanToken.allowance(address(callback), address(midnight)), 0, "allowance before");

        _take(_offer(market), 100e18, borrower);

        assertEq(loanToken.allowance(address(callback), address(midnight)), type(uint256).max, "allowance after");
    }

    function test_laterFillsSkipApprove() public {
        _take(_offer(market), 100e18, borrower);

        vm.expectCall(address(loanToken), abi.encodeWithSelector(IERC20.approve.selector), 0);
        _take(_offer(market), 100e18, borrower);

        assertEq(loanToken.allowance(address(callback), address(midnight)), type(uint256).max, "allowance");
    }

    function test_decrementingTokenReapprovesBelowUnits() public {
        vm.etch(address(loanToken), address(new MockDecrementingERC20("", "", 18)).code);

        _take(_offer(market), 100e18, borrower);
        assertEq(
            loanToken.allowance(address(callback), address(midnight)), type(uint256).max - 100e18, "spent allowance"
        );

        // Simulates the allowance running out after enough volume.
        vm.prank(address(callback));
        loanToken.approve(address(midnight), 1e18);

        _take(_offer(market), 100e18, borrower);
        assertEq(loanToken.allowance(address(callback), address(midnight)), type(uint256).max - 100e18, "reapproved");
        assertEq(midnight.debt(marketId, borrower), 200e18, "borrower debt");
    }

    function testFuzz_anyPriorAllowanceFills(uint256 priorAllowance, uint256 units) public {
        units = bound(units, 1, LENDER_CREDIT);
        vm.prank(address(callback));
        loanToken.approve(address(midnight), priorAllowance);

        _take(_offer(market), units, borrower);

        uint256 expected =
            priorAllowance < units || priorAllowance == type(uint256).max ? type(uint256).max : priorAllowance - units;
        assertEq(loanToken.allowance(address(callback), address(midnight)), expected, "allowance");
        assertEq(midnight.debt(marketId, borrower), units, "borrower debt");
    }

    /* ========== EDGE CASES ========== */

    function test_zeroSettlementFeeMarket() public {
        // A distinct market created with the (zero) default fees.
        Market memory freeMarket = _market(address(0));
        freeMarket.maturity += 1;
        bytes32 freeMarketId = midnight.touchMarket(freeMarket);
        address freeLender = makeAddr("FreeLender");
        _supplyCollateral(freeMarket, tempBorrower, COLLATERAL);
        _setupLenderWithCredit(freeMarket, freeLender, LENDER_CREDIT);
        assertEq(midnight.settlementFee(freeMarketId, 30 days), 0, "settlement fee");

        (uint256 buyerAssets, uint256 sellerAssets) = _take(_offer(freeMarket), LENDER_CREDIT, freeLender);

        assertEq(buyerAssets, LENDER_CREDIT, "buyerAssets");
        assertEq(sellerAssets, LENDER_CREDIT, "sellerAssets");
        assertEq(loanToken.balanceOf(freeLender), LENDER_CREDIT, "lender received");
        _assertCallbackHoldsNothing(freeMarketId);
    }

    function test_lenderCrossesIntoDebt() public {
        uint256 extra = 100e18;
        _setupLenderWithCredit(market, makeAddr("OtherLender"), extra);
        _supplyCollateral(market, lender, COLLATERAL);
        (uint128 credit,,) = midnight.updatePositionView(market, marketId, lender);

        _take(_offer(market), credit + extra, lender);

        assertEq(midnight.credit(marketId, lender), 0, "lender credit");
        assertEq(midnight.debt(marketId, lender), extra, "lender debt");
        _assertCallbackHoldsNothing(marketId);
    }

    function test_donatedTokensUntouched() public {
        uint256 donation = 5e18;
        loanToken.mint(address(callback), donation);

        _take(_offer(market), LENDER_CREDIT, borrower);

        assertEq(loanToken.balanceOf(address(callback)), donation, "callback balance");
    }

    function test_continuousFeeAboveCapReverts() public {
        Offer memory offer = _offer(market);
        offer.continuousFeeCap = MAX_CONTINUOUS_FEE - 1;

        vm.prank(borrower);
        vm.expectRevert(IMidnight.ContinuousFeeAboveOfferCap.selector);
        midnight.take(offer, "", 1e18, borrower, borrower, address(0), "");
    }

    function test_parTickAccessibleAfterTickSpacingRefinement() public {
        midnight.setTickSpacingSetter(address(this));

        midnight.setMarketTickSpacing(marketId, 2);
        _take(_offer(market), 1e18, borrower);

        midnight.setMarketTickSpacing(marketId, 1);
        _take(_offer(market), 1e18, borrower);

        assertEq(midnight.debt(marketId, borrower), 2e18, "borrower debt");
        _assertCallbackHoldsNothing(marketId);
    }

    /* ========== GATED MARKET ========== */

    function test_gatedMarket() public {
        MidnightAllowlistGate gate = new MidnightAllowlistGate(address(this));
        Market memory gatedMarket = _market(address(gate));
        bytes32 gatedMarketId = _createMarketWithFees(gatedMarket);

        MidnightAllowlistGate.Role[] memory roles = new MidnightAllowlistGate.Role[](2);
        roles[0] = MidnightAllowlistGate.Role(lender, true, false, false);
        roles[1] = MidnightAllowlistGate.Role(tempBorrower, false, true, false);
        gate.setAllowlist(roles);

        _supplyCollateral(gatedMarket, tempBorrower, COLLATERAL);
        _supplyCollateral(gatedMarket, borrower, COLLATERAL);
        _setupLenderWithCredit(gatedMarket, lender, LENDER_CREDIT);

        vm.prank(borrower);
        vm.expectRevert(IMidnight.BuyerGatedFromIncreasingCredit.selector);
        midnight.take(_offer(gatedMarket), "", 1e18, borrower, borrower, address(0), "");

        roles = new MidnightAllowlistGate.Role[](1);
        roles[0] = MidnightAllowlistGate.Role(address(callback), true, false, false);
        gate.setAllowlist(roles);

        vm.prank(borrower);
        vm.expectRevert(IMidnight.SellerGatedFromIncreasingDebt.selector);
        midnight.take(_offer(gatedMarket), "", 1e18, borrower, borrower, address(0), "");

        // Lender exits are never gated on debt.
        _take(_offer(gatedMarket), LENDER_CREDIT, lender);
        assertEq(midnight.credit(gatedMarketId, lender), 0, "lender credit");
        _assertCallbackHoldsNothing(gatedMarketId);
    }

    /* ========== FUZZ ========== */

    function testFuzz_lenderResale(uint256 units, uint256 elapsed) public {
        vm.warp(block.timestamp + bound(elapsed, 0, 40 days));
        (uint128 credit,,) = midnight.updatePositionView(market, marketId, lender);
        units = bound(units, 1, UtilsLib.min(credit, midnight.withdrawable(marketId)));
        uint256 claimableBefore = midnight.claimableSettlementFee(address(loanToken));

        (uint256 buyerAssets, uint256 sellerAssets) = _take(_offer(market), units, lender);

        assertEq(buyerAssets, units, "buyerAssets");
        assertEq(sellerAssets, _expectedSellerAssets(marketId, units), "sellerAssets");
        assertEq(midnight.claimableSettlementFee(address(loanToken)) - claimableBefore, units - sellerAssets, "fee");
        assertEq(midnight.debt(marketId, lender), 0, "lender debt");
        _assertCallbackHoldsNothing(marketId);
    }

    function testFuzz_borrowAtPar(uint256 units, uint256 elapsed) public {
        vm.warp(block.timestamp + bound(elapsed, 0, 30 days));
        units = bound(units, 1, midnight.withdrawable(marketId));

        (uint256 buyerAssets, uint256 sellerAssets) = _take(_offer(market), units, borrower);

        assertEq(buyerAssets, units, "buyerAssets");
        assertEq(sellerAssets, _expectedSellerAssets(marketId, units), "sellerAssets");
        assertEq(midnight.debt(marketId, borrower), units, "borrower debt");
        _assertCallbackHoldsNothing(marketId);
    }
}
