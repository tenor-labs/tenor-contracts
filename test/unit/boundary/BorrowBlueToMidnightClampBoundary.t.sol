// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {BoundaryTestBase} from "./BoundaryTestBase.sol";
import {BorrowBlueToMidnightClamp} from "../../../src/router/clamps/BorrowBlueToMidnightClamp.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {IBorrowBlueToMidnightCallback} from "@callbacks/interfaces/IBorrowBlueToMidnightCallback.sol";
import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {Id, MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";

/// @title BorrowBlueToMidnightClampBoundary
/// @notice Deterministic boundary tests for BorrowBlueToMidnightClamp
/// @dev Min chain: min(capacityToShares, maxUnitsForSellerBudget(blueDebt, feeRate))
///      SELL offers on TARGET market for Blue to Midnight borrow migration.
///      Maker (seller/borrower) has Blue debt on the source Morpho Blue market.
///      Taker (buyer/lender) provides loan tokens on the target Midnight market.
///
///      Uses real Morpho Blue so the callback actually repays debt.
contract BorrowBlueToMidnightClampBoundary is BoundaryTestBase {
    using MarketParamsLib for MarketParams;

    uint256 private _groupNonce;

    /// @notice Large default values so non-binding constraints don't interfere
    uint128 internal constant MAX_OFFER_CAP = type(uint128).max - uint128(SEED_AMOUNT);

    /// @notice The Morpho Blue market Id (bytes32)
    bytes32 internal blueSourceMarket;

    function setUp() public override {
        super.setUp();

        // Lender (taker/buyer) needs loan tokens + approval for Midnight
        loanToken.mint(lender, type(uint128).max);
        vm.prank(lender);
        loanToken.approve(address(midnight), type(uint256).max);

        // Compute Blue source market key for clamp data
        blueSourceMarket = bytes32(Id.unwrap(blueMarketParams.id()));

        // Default: large Blue borrow position so debt is not binding
        _setupBlueBorrowPosition(borrower, 500e18, 10000e18);

        // Borrower (maker/seller) needs collateral on target market (large amount)
        _depositCollateral(borrower, 1e38, targetMarket);
    }

    /* ======= Helpers ======= */

    function _freshGroup() internal returns (bytes32) {
        return keccak256(abi.encodePacked("v1v2BorrowBoundary", ++_groupNonce));
    }

    function _buildSellOffer(uint128 unitsCapacity, uint16 tick, bytes32 group) internal view returns (Offer memory) {
        return _buildSellOffer(unitsCapacity, tick, group, 0, borrower);
    }

    function _buildSellOffer(uint128 unitsCapacity, uint16 tick, bytes32 group, uint256 feeRate, address maker)
        internal
        view
        returns (Offer memory)
    {
        return Offer({
            market: targetMarket,
            buy: false,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: group,
            callback: address(borrowBlueToMidnightCallback),
            callbackData: abi.encode(
                IBorrowBlueToMidnightCallback.CallbackData({
                    sourceMarketParams: blueMarketParams, feeRate: feeRate, feeRecipient: address(this), tick: tick
                })
            ),
            receiverIfMakerIsSeller: address(borrowBlueToMidnightCallback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: unitsCapacity,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _clampData(address positionOwner, uint256 feeRate) internal view returns (bytes memory) {
        return abi.encode(
            BorrowBlueToMidnightClamp.BorrowBlueToMidnightClampData({
                sourceBlueMarketId: blueSourceMarket,
                marketId: targetMarketId,
                positionOwner: positionOwner,
                feeRate: feeRate
            })
        );
    }

    function _clampData(address positionOwner) internal view returns (bytes memory) {
        return _clampData(positionOwner, 0);
    }

    /* ======= Blue debt binding, no fee ======= */

    /// @notice Blue debt is binding (no fee, fresh 1:1 ratio)
    /// @dev Real Morpho Blue: callback repays Blue debt during take → no-dust holds
    function test_bindingBlueDebt_noFee_fresh() public {
        (address blueBorrower, uint256 blueBorrowerSK) = makeAddrAndKey("v1debtor_fresh");
        _setupBlueBorrowPosition(blueBorrower, 10e18, 200e18);
        _depositCollateral(blueBorrower, 1e38, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, 0, blueBorrower);
        bytes memory cd = _clampData(blueBorrower, 0);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, blueBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowBlueToMidnightClamp)), cd);
    }

    /// @notice Blue debt is binding (no fee, 1:2 ratio)
    function test_bindingBlueDebt_noFee_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);

        (address blueBorrower, uint256 blueBorrowerSK) = makeAddrAndKey("v1debtor_1to2");
        _setupBlueBorrowPosition(blueBorrower, 10e18, 200e18);
        _depositCollateral(blueBorrower, 1e38, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, 0, blueBorrower);
        bytes memory cd = _clampData(blueBorrower, 0);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, blueBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowBlueToMidnightClamp)), cd);
    }

    /// @notice Blue debt is binding (no fee, 99:100 ratio)
    function test_bindingBlueDebt_noFee_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);

        (address blueBorrower, uint256 blueBorrowerSK) = makeAddrAndKey("v1debtor_99to100");
        _setupBlueBorrowPosition(blueBorrower, 10e18, 200e18);
        _depositCollateral(blueBorrower, 1e38, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, 0, blueBorrower);
        bytes memory cd = _clampData(blueBorrower, 0);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, blueBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowBlueToMidnightClamp)), cd);
    }

    /* ======= Blue debt binding, with fee (10%) ======= */

    /// @notice Blue debt is binding (10% fee, fresh 1:1 ratio)
    function test_bindingBlueDebt_withFee_fresh() public {
        uint256 feeRate = 0.1e18;

        (address blueBorrower, uint256 blueBorrowerSK) = makeAddrAndKey("v1debtor_fee_fresh");
        _setupBlueBorrowPosition(blueBorrower, 10e18, 200e18);
        _depositCollateral(blueBorrower, 1e38, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, feeRate, blueBorrower);
        bytes memory cd = _clampData(blueBorrower, feeRate);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, blueBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowBlueToMidnightClamp)), cd);
    }

    /// @notice Blue debt is binding (10% fee, 1:2 ratio)
    function test_bindingBlueDebt_withFee_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);
        uint256 feeRate = 0.1e18;

        (address blueBorrower, uint256 blueBorrowerSK) = makeAddrAndKey("v1debtor_fee_1to2");
        _setupBlueBorrowPosition(blueBorrower, 10e18, 200e18);
        _depositCollateral(blueBorrower, 1e38, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, feeRate, blueBorrower);
        bytes memory cd = _clampData(blueBorrower, feeRate);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, blueBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowBlueToMidnightClamp)), cd);
    }

    /// @notice Blue debt is binding (10% fee, 99:100 ratio)
    function test_bindingBlueDebt_withFee_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);
        uint256 feeRate = 0.1e18;

        (address blueBorrower, uint256 blueBorrowerSK) = makeAddrAndKey("v1debtor_fee_99to100");
        _setupBlueBorrowPosition(blueBorrower, 10e18, 200e18);
        _depositCollateral(blueBorrower, 1e38, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, feeRate, blueBorrower);
        bytes memory cd = _clampData(blueBorrower, feeRate);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, blueBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowBlueToMidnightClamp)), cd);
    }

    /* ======= reduceOnly ======= */

    /// @notice reduceOnly=true returns 0 when maker has no credit on target market
    /// @dev SELL offer on target Midnight: reduceOnly caps by seller's credit on target.
    ///      In a normal Blue to Midnight migration the seller has Blue debt but no Midnight credit,
    ///      so reduceOnly → 0.
    function test_reduceOnly_noTargetCredit_returnsZero() public {
        bytes32 group = _freshGroup();

        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group);
        offer.reduceOnly = true;

        bytes memory cd = _clampData(borrower);
        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "reduceOnly with no target credit should return 0");
    }

    /* ======= Zero edge cases ======= */

    /// @notice Zero Blue debt returns 0 (user with no Blue borrow)
    function test_zeroBlueDebtNoBorrow_returnsZero() public {
        (address noBorrow,) = makeAddrAndKey("noBorrow_snap");

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, 0, noBorrow);
        bytes memory cd = _clampData(noBorrow, 0);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "zero Blue debt: should return 0");
    }

    /// @notice Zero Blue debt returns 0 (position was repaid)
    function test_zeroBlueDebt_returnsZero() public {
        (address repaidUser,) = makeAddrAndKey("repaidUser");
        _setupBlueBorrowPosition(repaidUser, 10e18, 200e18);

        // Repay all Blue debt
        loanToken.mint(repaidUser, 10e18);
        vm.startPrank(repaidUser);
        loanToken.approve(address(morphoBlue), type(uint256).max);
        morphoBlue.repay(blueMarketParams, 10e18, 0, repaidUser, "");
        vm.stopPrank();

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, 0, repaidUser);
        bytes memory cd = _clampData(repaidUser, 0);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertEq(maxUnits, 0, "zero Blue debt: should return 0");
    }

    /* ======= Blue debt binding, max fee (50%) ======= */

    /// @notice Blue debt is binding (50% max fee, fresh 1:1 ratio)
    function test_bindingBlueDebt_maxFee() public {
        uint256 feeRate = 0.5e18;

        (address blueBorrower, uint256 blueBorrowerSK) = makeAddrAndKey("v1debtor_maxfee");
        _setupBlueBorrowPosition(blueBorrower, 10e18, 200e18);
        _depositCollateral(blueBorrower, 1e38, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, feeRate, blueBorrower);
        bytes memory cd = _clampData(blueBorrower, feeRate);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, blueBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowBlueToMidnightClamp)), cd);
    }

    /// @notice Blue debt is binding (50% max fee, 1:2 ratio)
    function test_bindingBlueDebt_maxFee_1to2() public {
        _setTotalUnits(targetMarketId, 100e18);
        uint256 feeRate = 0.5e18;

        (address blueBorrower, uint256 blueBorrowerSK) = makeAddrAndKey("v1debtor_maxfee_1to2");
        _setupBlueBorrowPosition(blueBorrower, 10e18, 200e18);
        _depositCollateral(blueBorrower, 1e38, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, feeRate, blueBorrower);
        bytes memory cd = _clampData(blueBorrower, feeRate);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, blueBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowBlueToMidnightClamp)), cd);
    }

    /// @notice Blue debt is binding (50% max fee, 99:100 ratio)
    function test_bindingBlueDebt_maxFee_99to100() public {
        _setTotalUnits(targetMarketId, 99e18);
        uint256 feeRate = 0.5e18;

        (address blueBorrower, uint256 blueBorrowerSK) = makeAddrAndKey("v1debtor_maxfee_99to100");
        _setupBlueBorrowPosition(blueBorrower, 10e18, 200e18);
        _depositCollateral(blueBorrower, 1e38, targetMarket);

        bytes32 group = _freshGroup();
        Offer memory offer = _buildSellOffer(MAX_OFFER_CAP, TICK_HIGH, group, feeRate, blueBorrower);
        bytes memory cd = _clampData(blueBorrower, feeRate);

        uint256 maxUnits = borrowBlueToMidnightClamp.maxUnits(offer, cd);
        assertTrue(maxUnits > 0, "should have units");

        Signature memory sig = _signOffer(offer, blueBorrowerSK);
        _verifyBoundary(maxUnits, offer, sig, lender, ITakeClamp(address(borrowBlueToMidnightClamp)), cd);
    }
}
