// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CallbackLib} from "src/libraries/CallbackLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";

/// @title CallbackLibFeeRoundingDirectionTest
/// @notice Verifies that all fee computations round AGAINST the protocol (fees round down).
///         The protocol must never overcharge users by even 1 wei due to rounding.
contract CallbackLibFeeRoundingDirectionTest is Test {
    /// @notice sellerEffectivePrice must round UP (seller receives more, fee is smaller).
    ///         Verified by checking our result >= floor reference computed with Solidity's `/`.
    function testFuzz_sellerEffPriceRoundsUp(uint256 price, uint256 feeRate) public pure {
        price = bound(price, 1, WAD - 1);
        feeRate = bound(feeRate, 1, WAD);

        uint256 effPrice = CallbackLib.sellerEffectivePrice(price, feeRate);

        // Reference: floor(price * WAD / (WAD + x)) using Math.mulDiv (= floor division)
        uint256 x = Math.mulDiv(WAD - price, feeRate, WAD);
        uint256 refFloor = Math.mulDiv(price, WAD, WAD + x);

        assertGe(effPrice, refFloor, "sellerEffPrice must round up (>= floor)");
    }

    /// @notice buyerEffectivePrice must round DOWN (buyer pays less, fee is smaller).
    ///         Verified by checking our result <= ceil reference.
    function testFuzz_buyerEffPriceRoundsDown(uint256 price, uint256 feeRate) public pure {
        price = bound(price, 1, WAD - 1);
        feeRate = bound(feeRate, 1, WAD);

        uint256 x = Math.mulDiv(WAD - price, feeRate, WAD);
        if (x >= WAD) return; // degenerate input, reverts in real function

        uint256 effPrice = CallbackLib.buyerEffectivePrice(price, feeRate);

        // Reference: ceil(price * WAD / (WAD - x))
        uint256 refCeil = Math.mulDiv(price, WAD, WAD - x, Math.Rounding.Ceil);

        assertLe(effPrice, refCeil, "buyerEffPrice must round down (<= ceil)");
    }

    /// @notice sellerFeeFromTick must be <= the maximum fee obtainable by rounding
    ///         every intermediate step in favor of the protocol.
    function testFuzz_sellerFeeRoundsDown(uint256 tick, uint256 feeRate, uint256 units) public pure {
        tick = bound(tick, 1, MAX_TICK - 1); // exclude tick 0 (price ~0) and MAX_TICK (price = WAD)
        feeRate = bound(feeRate, 1, WAD);
        units = bound(units, 1, 1e24);

        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = Math.mulDiv(units, price, WAD); // exact-ish asset amount for these units
        if (assets == 0) return;

        uint256 fee = CallbackLib.sellerFeeFromTick(tick, feeRate, units, assets);

        // Protocol-favorable reference: effPrice floors, budget floors -> max fee
        uint256 x = Math.mulDiv(WAD - price, feeRate, WAD);
        uint256 effPriceFloor = Math.mulDiv(price, WAD, WAD + x);
        uint256 budgetFloor = Math.mulDiv(units, effPriceFloor, WAD);
        uint256 maxFee = assets > budgetFloor ? assets - budgetFloor : 0;

        assertLe(fee, maxFee, "sellerFee must round against protocol (<= maxFee)");
    }

    /// @notice buyerFeeFromTick must be <= the maximum fee obtainable by rounding
    ///         every intermediate step in favor of the protocol.
    function testFuzz_buyerFeeRoundsDown(uint256 tick, uint256 feeRate, uint256 units) public pure {
        tick = bound(tick, 1, MAX_TICK - 1);
        feeRate = bound(feeRate, 1, WAD);
        units = bound(units, 1, 1e24);

        uint256 price = TickLib.tickToPrice(tick);
        uint256 assets = Math.mulDiv(units, price, WAD);
        if (assets == 0) return;

        uint256 x = Math.mulDiv(WAD - price, feeRate, WAD);
        if (x >= WAD) return; // degenerate, reverts

        uint256 fee = CallbackLib.buyerFeeFromTick(tick, feeRate, units, assets);

        // Protocol-favorable reference: effPrice ceils, budget ceils -> max fee
        uint256 effPriceCeil = Math.mulDiv(price, WAD, WAD - x, Math.Rounding.Ceil);
        uint256 budgetCeil = Math.mulDiv(units, effPriceCeil, WAD, Math.Rounding.Ceil);
        uint256 maxFee = budgetCeil > assets ? budgetCeil - assets : 0;

        assertLe(fee, maxFee, "buyerFee must round against protocol (<= maxFee)");
    }

    /// @notice percentageFee always rounds down (trivial: single mulDivDown).
    function testFuzz_percentageFeeRoundsDown(uint256 assets, uint256 feeRate) public pure {
        feeRate = bound(feeRate, 1, CallbackLib.MAX_PERCENTAGE_FEE_RATE);
        assets = bound(assets, 1, 1e24);

        uint256 fee = CallbackLib.percentageFee(assets, feeRate);

        // Ceil reference
        uint256 refCeil = Math.mulDiv(assets, feeRate, WAD, Math.Rounding.Ceil);
        assertLe(fee, refCeil, "percentageFee must round down (<= ceil)");

        // Floor reference (should be exact match)
        uint256 refFloor = Math.mulDiv(assets, feeRate, WAD);
        assertEq(fee, refFloor, "percentageFee must equal floor");
    }
}
