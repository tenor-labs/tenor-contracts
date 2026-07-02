// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {EventsLib} from "@midnight/libraries/EventsLib.sol";

contract MidnightSetConsumedTest is Test {
    Midnight internal midnight;
    address internal user;
    address internal authorized;
    address internal unauthorized;

    bytes32 internal constant GROUP = keccak256("test-group");
    uint128 internal constant AMOUNT = 100e18;

    function setUp() public {
        user = makeAddr("User");
        authorized = makeAddr("Authorized");
        unauthorized = makeAddr("Unauthorized");

        midnight = new Midnight();
        enableDefaultLltvs(midnight);

        // Authorize the `authorized` address to act on behalf of `user`
        vm.prank(user);
        midnight.setIsAuthorized(authorized, true, user);
    }

    function test_setConsumed_selfConsume() public {
        vm.prank(user);
        midnight.setConsumed(GROUP, AMOUNT, user);

        assertEq(midnight.consumed(user, GROUP), AMOUNT);
    }

    function test_setConsumed_anyUserCanSetConsumedForSelf() public {
        // setConsumed() requires onBehalf == msg.sender or an authorization; setting consumed for
        // yourself always passes via the onBehalf == msg.sender branch.
        vm.prank(unauthorized);
        midnight.setConsumed(GROUP, AMOUNT, unauthorized);

        assertEq(midnight.consumed(unauthorized, GROUP), AMOUNT);
        // Other users are unaffected
        assertEq(midnight.consumed(user, GROUP), 0);
    }

    function test_setConsumed_emitsEvent() public {
        vm.prank(authorized);
        vm.expectEmit(true, true, true, true);
        emit EventsLib.SetConsumed(authorized, GROUP, AMOUNT, user);
        midnight.setConsumed(GROUP, AMOUNT, user);
    }

    function test_setConsumed_canIncrease() public {
        vm.startPrank(user);
        midnight.setConsumed(GROUP, AMOUNT, user);
        midnight.setConsumed(GROUP, AMOUNT * 2, user);
        vm.stopPrank();

        assertEq(midnight.consumed(user, GROUP), AMOUNT * 2);
    }

    function test_setConsumed_cannotDecrease() public {
        vm.startPrank(user);
        midnight.setConsumed(GROUP, AMOUNT, user);
        vm.expectRevert(IMidnight.AlreadyConsumed.selector);
        midnight.setConsumed(GROUP, AMOUNT - 1, user);
        vm.stopPrank();
    }

    function test_setConsumed_canSetSameValue() public {
        vm.startPrank(user);
        midnight.setConsumed(GROUP, AMOUNT, user);
        midnight.setConsumed(GROUP, AMOUNT, user);
        vm.stopPrank();

        assertEq(midnight.consumed(user, GROUP), AMOUNT);
    }

    function test_setConsumed_maxCancelsAll() public {
        vm.startPrank(user);
        midnight.setConsumed(GROUP, AMOUNT, user);
        midnight.setConsumed(GROUP, type(uint128).max, user);
        vm.stopPrank();

        assertEq(midnight.consumed(user, GROUP), type(uint128).max);
    }

    function test_setConsumed_separateGroups() public {
        bytes32 group2 = keccak256("test-group-2");

        vm.startPrank(user);
        midnight.setConsumed(GROUP, AMOUNT, user);
        midnight.setConsumed(group2, AMOUNT * 2, user);
        vm.stopPrank();

        assertEq(midnight.consumed(user, GROUP), AMOUNT);
        assertEq(midnight.consumed(user, group2), AMOUNT * 2);
    }

    function test_setConsumed_separateUsers() public {
        address user2 = makeAddr("User2");

        vm.prank(user);
        midnight.setConsumed(GROUP, AMOUNT, user);

        vm.prank(user2);
        midnight.setConsumed(GROUP, AMOUNT * 2, user2);

        assertEq(midnight.consumed(user, GROUP), AMOUNT);
        assertEq(midnight.consumed(user2, GROUP), AMOUNT * 2);
    }

    function testFuzz_setConsumed(address onBehalf, bytes32 group, uint128 amount) public {
        vm.assume(onBehalf != address(0));

        vm.prank(onBehalf);
        midnight.setConsumed(group, amount, onBehalf);

        assertEq(midnight.consumed(onBehalf, group), amount);
    }
}
