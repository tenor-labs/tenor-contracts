// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {RatePointLib, PackedRatePoint} from "../../src/libraries/RatePointLib.sol";

contract RatePointLibTest is Test {
    function testFuzz_packUnpack_identity(uint128 r, uint128 d) public pure {
        PackedRatePoint p = RatePointLib.pack(r, d);
        assertEq(p.rate(), uint256(r));
        assertEq(p.duration(), uint256(d));
    }

    function testFuzz_bitIsolation(uint128 r, uint128 d) public pure {
        PackedRatePoint p = RatePointLib.pack(r, d);

        // Changing duration doesn't affect rate
        PackedRatePoint p2 = RatePointLib.pack(r, d == 0 ? 1 : d - 1);
        assertEq(p.rate(), p2.rate());

        // Changing rate doesn't affect duration
        PackedRatePoint p3 = RatePointLib.pack(r == 0 ? 1 : r - 1, d);
        assertEq(p.duration(), p3.duration());
    }
}
