// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {MigrationRatifier} from "../../src/ratifiers/MigrationRatifier.sol";

/// @dev Test-only harness exposing MigrationRatifier._userIsBuy for direct assertion.
contract DirectionalityHarness is MigrationRatifier {
    constructor(address cb1, address cb2, address cb3, address cb4, address cb5, address cb6)
        MigrationRatifier(address(1), cb1, cb2, cb3, cb4, cb5, cb6, address(1))
    {}

    /// @notice Public wrapper exposing the internal _userIsBuy mapping.
    function userIsBuy(address callback) external view returns (bool) {
        return _userIsBuy(callback);
    }
}

/// @title DirectionalityMatrix
/// @notice Proves DEFAULT-1 / RATE-3: the `_userIsBuy(callback)` mapping on the canonical ratifier
///         matches main's per-take hardcoded `isBuy` argument for each of the 6 renewal callbacks.
/// @dev Per PROPERTIES.md RATE-3: "a single inversion means users get the opposite protection —
///      ceiling becomes floor or vice versa." This test is the explicit matrix check guarding against
///      that inversion during any future refactor of the ratifier.
contract DirectionalityMatrix is Test {
    DirectionalityHarness internal r;

    address internal constant CB_BORROW_MIDNIGHT_RENEWAL = address(0xB22);
    address internal constant CB_BORROW_BLUE_TO_MIDNIGHT = address(0xB12);
    address internal constant CB_LEND_VAULT_TO_MIDNIGHT = address(0xA12);
    address internal constant CB_BORROW_MIDNIGHT_TO_BLUE = address(0xB21);
    address internal constant CB_LEND_MIDNIGHT_TO_VAULT = address(0xA21);
    address internal constant CB_LEND_MIDNIGHT_RENEWAL = address(0xA22);

    function setUp() public {
        r = new DirectionalityHarness(
            CB_BORROW_MIDNIGHT_RENEWAL,
            CB_BORROW_BLUE_TO_MIDNIGHT,
            CB_LEND_VAULT_TO_MIDNIGHT,
            CB_BORROW_MIDNIGHT_TO_BLUE,
            CB_LEND_MIDNIGHT_TO_VAULT,
            CB_LEND_MIDNIGHT_RENEWAL
        );
    }

    /// @dev Matrix of expected values, ported verbatim from main, where each per-take site
    ///      take function passed a hardcoded bool to `_validatePrice`:
    ///
    ///        takeBorrowMidnightRenewal           → _validatePrice(false, ...)
    ///        takeBorrowBlueToMidnight                → _validatePrice(false, ...)
    ///        takeLendVaultToMidnight                  → _validatePrice(true,  ...)
    ///        takeBorrowMidnightToBlue                → _validatePrice(true,  ...)
    ///        takeLendMidnightToVault                  → _validatePrice(false, ...)
    ///        takeLendMidnightRenewal      → _validatePrice(true,  ...)
    ///
    ///      Any change to this mapping inverts rate-limit protection for that callback.
    function test_userIsBuy_matchesMainMapping() public view {
        assertEq(r.userIsBuy(CB_BORROW_MIDNIGHT_RENEWAL), false, "BORROW_MIDNIGHT_RENEWAL: isBuy=false");
        assertEq(r.userIsBuy(CB_BORROW_BLUE_TO_MIDNIGHT), false, "BORROW_BLUE_TO_MIDNIGHT: isBuy=false");
        assertEq(r.userIsBuy(CB_LEND_VAULT_TO_MIDNIGHT), true, "LEND_VAULT_TO_MIDNIGHT: isBuy=true");
        assertEq(r.userIsBuy(CB_BORROW_MIDNIGHT_TO_BLUE), true, "BORROW_MIDNIGHT_TO_BLUE: isBuy=true");
        assertEq(r.userIsBuy(CB_LEND_MIDNIGHT_TO_VAULT), false, "LEND_MIDNIGHT_TO_VAULT: isBuy=false");
        assertEq(r.userIsBuy(CB_LEND_MIDNIGHT_RENEWAL), true, "LEND_MIDNIGHT_RENEWAL: isBuy=true");
    }

    /// @dev Any unknown callback defaults to isBuy=false (seller/borrower ceiling).
    /// @dev Documents the fall-through behavior explicitly so future ratifier changes can't
    ///      silently change the default without breaking this test.
    function test_userIsBuy_unknownCallbackDefaultsFalse(address randomCb) public view {
        vm.assume(randomCb != CB_LEND_VAULT_TO_MIDNIGHT);
        vm.assume(randomCb != CB_BORROW_MIDNIGHT_TO_BLUE);
        vm.assume(randomCb != CB_LEND_MIDNIGHT_RENEWAL);
        assertEq(r.userIsBuy(randomCb), false, "unknown callback must default to isBuy=false");
    }

    /// @dev The three "buy-side" callbacks are exactly the set defined in the implementation.
    ///      Partitions the callback space into buy (floor protection) and sell (ceiling protection).
    function test_userIsBuy_exactBuySidePartition() public view {
        // Buy side: lender-like (floor protection via max(policyRate, limitRate))
        bool[3] memory buySide;
        buySide[0] = r.userIsBuy(CB_LEND_VAULT_TO_MIDNIGHT);
        buySide[1] = r.userIsBuy(CB_BORROW_MIDNIGHT_TO_BLUE);
        buySide[2] = r.userIsBuy(CB_LEND_MIDNIGHT_RENEWAL);
        for (uint256 i; i < 3; i++) {
            assertTrue(buySide[i], "expected buy-side callback");
        }

        // Sell side: borrower-like (ceiling protection via min(policyRate, limitRate))
        bool[3] memory sellSide;
        sellSide[0] = r.userIsBuy(CB_BORROW_MIDNIGHT_RENEWAL);
        sellSide[1] = r.userIsBuy(CB_BORROW_BLUE_TO_MIDNIGHT);
        sellSide[2] = r.userIsBuy(CB_LEND_MIDNIGHT_TO_VAULT);
        for (uint256 i; i < 3; i++) {
            assertFalse(sellSide[i], "expected sell-side callback");
        }
    }
}
