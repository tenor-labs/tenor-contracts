// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {MigrationRatifierTestBase} from "../helpers/MigrationRatifierTestBase.sol";
import {IMigrationRatifier} from "../../src/ratifiers/interfaces/IMigrationRatifier.sol";
import {IInterestRatePolicy} from "../../src/ratifiers/interfaces/IInterestRatePolicy.sol";
import {Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";

/// @dev Policy that only quotes to a preferred taker, delegating the actual rate to an inner policy.
///      `isRatified` runs under STATICCALL so the policy cannot record the taker; instead the revert
///      error carries the taker it received, letting tests assert the exact forwarded address.
contract TakerGatedPolicy is IInterestRatePolicy {
    error TakerNotPreferred(address taker);

    address public immutable PREFERRED_TAKER;
    IInterestRatePolicy public immutable INNER;

    constructor(address preferredTaker, IInterestRatePolicy inner) {
        PREFERRED_TAKER = preferredTaker;
        INNER = inner;
    }

    function getRate(
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        uint256 renewalPeriodStart,
        address user,
        address taker,
        uint256 sourceMaturity,
        uint256 targetMaturity,
        bool userIsBuyer
    ) external view returns (uint256) {
        if (taker != PREFERRED_TAKER) revert TakerNotPreferred(taker);
        return INNER.getRate(
            sourceTenorMarketId,
            targetTenorMarketId,
            renewalPeriodStart,
            user,
            taker,
            sourceMaturity,
            targetMaturity,
            userIsBuyer
        );
    }
}

/// @title TakerAwareRatePolicyTest
/// @notice End-to-end coverage of the taker plumbing: `Midnight.take` -> `MigrationRatifier.isRatified(offer, data,
///         taker)` -> `BaseMigrationRatifier._ratifyRate` -> `IInterestRatePolicy.getRate(..., taker, ...)`.
///         Uses the borrow-renewal flow: the borrower is the maker-seller, the taker is the buyer.
contract TakerAwareRatePolicyTest is MigrationRatifierTestBase {
    using TenorMarketIdLib for Market;

    bytes32 internal sourceTenorMarketId;
    bytes32 internal targetTenorMarketId;

    function setUp() public override {
        super.setUp();
        sourceTenorMarketId = sourceMarket.toTenorMarketId();
        targetTenorMarketId = targetMarket.toTenorMarketId();
    }

    function _setBorrowParamsWithPolicy(address policy) internal {
        IMigrationRatifier.UserMigrationParams memory params = _defaultBorrowParams();
        params.interestRatePolicy = policy;
        _setParams(
            borrower, address(borrowMidnightRenewalCallback), sourceTenorMarketId, targetTenorMarketId, params
        );
    }

    function test_takeSucceedsForPreferredTaker() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _setBorrowParamsWithPolicy(address(new TakerGatedPolicy(lender, permissiveRatePolicy)));
        _warpToRenewalWindow(sourceMarket);

        uint256 takeUnits = 100e18;
        (,, uint256 units) =
            _takeBorrowMidnightRenewal(borrower, lender, takeUnits, sourceMarket, targetMarket, DEFAULT_TICK);

        assertEq(units, takeUnits, "preferred taker fills through the gated policy");
        assertEq(midnight.debt(targetMarketId, borrower), units, "renewal settled on target");
    }

    function test_takeRevertsForOtherTaker_withForwardedTakerInError() public {
        _setupBorrowerWithDebt(borrower, borrowerSK, DEFAULT_BORROW_AMOUNT, sourceMarket, sourceMarketId);
        _setBorrowParamsWithPolicy(address(new TakerGatedPolicy(lender, permissiveRatePolicy)));
        _warpToRenewalWindow(sourceMarket);

        address otherTaker = makeAddr("otherTaker");
        loanToken.mint(otherTaker, DEFAULT_BORROW_AMOUNT);
        vm.prank(otherTaker);
        loanToken.approve(address(midnight), type(uint256).max);

        bytes memory cbd = _encodeBorrowMidnightRenewalCallbackData(sourceMarket, DEFAULT_TICK);
        Offer memory offer =
            _migrationOffer(borrower, targetMarket, false, DEFAULT_TICK, address(borrowMidnightRenewalCallback), cbd);
        bytes memory rd = abi.encode(sourceTenorMarketId, targetTenorMarketId);

        // The error carries the taker the policy received, proving the exact address was forwarded.
        vm.expectRevert(abi.encodeWithSelector(TakerGatedPolicy.TakerNotPreferred.selector, otherTaker));
        vm.prank(otherTaker);
        midnight.take(offer, rd, 100e18, otherTaker, address(0), address(0), "");
    }
}
