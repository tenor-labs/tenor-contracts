// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MidnightWithdrawableTestBase} from "../helpers/MidnightWithdrawableTestBase.sol";
import {MidnightWithdrawableCallback} from "../../src/callbacks/MidnightWithdrawableCallback.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

/// @dev Random walk over lender resales, borrows, repayments and time, all through the callback's par offer.
contract MidnightWithdrawableHandler is Test {
    Midnight internal immutable MIDNIGHT;
    MidnightWithdrawableCallback internal immutable CALLBACK;
    MockERC20 internal immutable LOAN_TOKEN;
    bytes32 internal immutable MARKET_ID;
    address internal immutable LENDER;
    address internal immutable BORROWER;

    constructor(
        Midnight midnight,
        MidnightWithdrawableCallback callback,
        MockERC20 loanToken,
        bytes32 marketId,
        address lender,
        address borrower
    ) {
        MIDNIGHT = midnight;
        CALLBACK = callback;
        LOAN_TOKEN = loanToken;
        MARKET_ID = marketId;
        LENDER = lender;
        BORROWER = borrower;
    }

    function lenderSells(uint256 units) external {
        Market memory market = MIDNIGHT.toMarket(MARKET_ID);
        (uint128 credit,,) = MIDNIGHT.updatePositionView(market, MARKET_ID, LENDER);
        uint256 maxUnits = UtilsLib.min(credit, MIDNIGHT.withdrawable(MARKET_ID));
        if (maxUnits == 0) return;

        vm.prank(LENDER);
        MIDNIGHT.take(_offer(market), "", bound(units, 1, maxUnits), LENDER, LENDER, address(0), "");
    }

    function borrowerBorrows(uint256 units) external {
        Market memory market = MIDNIGHT.toMarket(MARKET_ID);
        uint256 maxUnits = MIDNIGHT.withdrawable(MARKET_ID);
        if (block.timestamp > market.maturity || maxUnits == 0) return;

        vm.prank(BORROWER);
        MIDNIGHT.take(_offer(market), "", bound(units, 1, maxUnits), BORROWER, BORROWER, address(0), "");
    }

    function borrowerRepays(uint256 units) external {
        uint256 debt = MIDNIGHT.debt(MARKET_ID, BORROWER);
        if (debt == 0) return;
        units = bound(units, 1, debt);

        LOAN_TOKEN.mint(BORROWER, units);
        vm.startPrank(BORROWER);
        LOAN_TOKEN.approve(address(MIDNIGHT), units);
        MIDNIGHT.repay(MIDNIGHT.toMarket(MARKET_ID), units, BORROWER, address(0), "");
        vm.stopPrank();
    }

    function warp(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 3 days));
    }

    /// @dev Same offer as MidnightWithdrawableTestBase._offer, with start = 0 so it stays valid across warps.
    function _offer(Market memory market) internal view returns (Offer memory) {
        return Offer({
            market: market,
            buy: true,
            maker: address(CALLBACK),
            start: 0,
            expiry: type(uint256).max,
            tick: MAX_TICK,
            group: bytes32(0),
            callback: address(CALLBACK),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(CALLBACK),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }
}

contract MidnightWithdrawableCallbackInvariantTest is MidnightWithdrawableTestBase {
    MidnightWithdrawableHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new MidnightWithdrawableHandler(midnight, callback, loanToken, marketId, lender, borrower);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_callbackHoldsNothing() public view {
        _assertCallbackHoldsNothing(marketId);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_midnightLoanBalanceMatchesAccounting() public view {
        assertEq(
            loanToken.balanceOf(address(midnight)),
            midnight.withdrawable(marketId) + midnight.claimableSettlementFee(address(loanToken)),
            "Midnight loan balance == withdrawable + settlement fees"
        );
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_unitsBackedByDebtOrWithdrawable() public view {
        assertEq(
            midnight.totalUnits(marketId),
            midnight.debt(marketId, borrower) + midnight.debt(marketId, tempBorrower) + midnight.withdrawable(marketId),
            "totalUnits == debt + withdrawable"
        );
    }
}
