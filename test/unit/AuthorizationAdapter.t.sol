// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AuthorizationAdapter} from "../../src/bundler/AuthorizationAdapter.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EventsLib} from "@midnight/libraries/EventsLib.sol";
import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {SetterRatifier} from "@midnight/ratifiers/SetterRatifier.sol";
import {ISetterRatifier} from "@midnight/ratifiers/interfaces/ISetterRatifier.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";
import {ErrorsLib} from "@bundler3/libraries/ErrorsLib.sol";
import {Fixtures} from "../helpers/Fixtures.sol";

contract AuthorizationAdapterTestBase is Fixtures {
    AuthorizationAdapter internal authAdapter;
    Midnight internal midnight;
    SetterRatifier internal setterRatifier;
    IBundler3 internal bundler3;

    address internal user;
    address internal unauthorized;
    address internal agent;
    address internal ratifier;

    function setUp() public virtual {
        user = makeAddr("User");
        unauthorized = makeAddr("Unauthorized");
        agent = makeAddr("Agent");
        ratifier = makeAddr("Ratifier");

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        bundler3 = deployBundler3();
        setterRatifier = new SetterRatifier(address(midnight));
        authAdapter = new AuthorizationAdapter(address(bundler3), address(midnight));

        vm.prank(user);
        midnight.setIsAuthorized(address(authAdapter), true, user);
    }

    function _setAuth(address authorized, bool value) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = _call(address(authAdapter), abi.encodeCall(authAdapter.midnightSetIsAuthorized, (authorized, value)));
    }

    function _setIsRatified(address setterRatifier_, bytes32 root, bool value)
        internal
        view
        returns (Call[] memory calls)
    {
        calls = new Call[](1);
        calls[0] = _call(
            address(authAdapter),
            abi.encodeCall(authAdapter.setterRatifierSetIsRootRatified, (setterRatifier_, root, value))
        );
    }
}

contract AuthorizationAdapterConstructorTest is AuthorizationAdapterTestBase {
    function test_constructor_revertsZeroBundler3() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new AuthorizationAdapter(address(0), address(midnight));
    }

    function test_constructor_revertsZeroMidnight() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new AuthorizationAdapter(address(bundler3), address(0));
    }

    function test_constructor_setsImmutables() public view {
        assertEq(authAdapter.BUNDLER3(), address(bundler3));
        assertEq(address(authAdapter.MORPHO_MIDNIGHT()), address(midnight));
    }
}

contract AuthorizationAdapterSetIsAuthorizedTest is AuthorizationAdapterTestBase {
    function test_grant() public {
        assertFalse(midnight.isAuthorized(user, agent));

        vm.prank(user);
        bundler3.multicall(_setAuth(agent, true));

        assertTrue(midnight.isAuthorized(user, agent));
    }

    function test_revoke() public {
        vm.prank(user);
        midnight.setIsAuthorized(agent, true, user);

        vm.prank(user);
        bundler3.multicall(_setAuth(agent, false));

        assertFalse(midnight.isAuthorized(user, agent));
    }

    function test_emitsEvent() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit EventsLib.SetIsAuthorized(address(authAdapter), agent, true, user);
        bundler3.multicall(_setAuth(agent, true));
    }

    function test_onlyBundler3_directCallReverts() public {
        vm.prank(user);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        authAdapter.midnightSetIsAuthorized(agent, true);
    }

    function test_onlyBundler3_arbitraryEOAReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        authAdapter.midnightSetIsAuthorized(agent, true);
    }

    /// @dev Initiators that haven't permanently authorized this adapter are rejected by Midnight
    ///      itself, not by the adapter — msg.sender (adapter) lacks auth from onBehalf (initiator).
    function test_unauthorizedInitiator_midnightReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        bundler3.multicall(_setAuth(agent, true));
    }

    function testFuzz_grant(address fuzzAgent, bool isAuthorized) public {
        vm.assume(fuzzAgent != address(0));

        vm.prank(user);
        bundler3.multicall(_setAuth(fuzzAgent, isAuthorized));

        assertEq(midnight.isAuthorized(user, fuzzAgent), isAuthorized);
    }

    function test_grantAndRevokeBatched() public {
        Call[] memory calls = new Call[](2);
        calls[0] = _call(address(authAdapter), abi.encodeCall(authAdapter.midnightSetIsAuthorized, (agent, true)));
        calls[1] = _call(address(authAdapter), abi.encodeCall(authAdapter.midnightSetIsAuthorized, (agent, false)));

        vm.prank(user);
        bundler3.multicall(calls);

        assertFalse(midnight.isAuthorized(user, agent));
    }
}

contract AuthorizationAdapterSetterRatifierSetIsRatifiedTest is AuthorizationAdapterTestBase {
    bytes32 internal constant ROOT = keccak256("offer-root");

    function test_ratify() public {
        assertFalse(setterRatifier.isRootRatified(user, ROOT));

        vm.prank(user);
        bundler3.multicall(_setIsRatified(address(setterRatifier), ROOT, true));

        assertTrue(setterRatifier.isRootRatified(user, ROOT));
    }

    function test_unratify() public {
        vm.prank(user);
        bundler3.multicall(_setIsRatified(address(setterRatifier), ROOT, true));

        vm.prank(user);
        bundler3.multicall(_setIsRatified(address(setterRatifier), ROOT, false));

        assertFalse(setterRatifier.isRootRatified(user, ROOT));
    }

    function test_emitsEvent() public {
        vm.prank(user);
        vm.expectEmit(true, true, true, true, address(setterRatifier));
        emit ISetterRatifier.SetIsRootRatified(address(authAdapter), user, ROOT, true);
        bundler3.multicall(_setIsRatified(address(setterRatifier), ROOT, true));
    }

    function test_onlyBundler3_directCallReverts() public {
        vm.prank(user);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        authAdapter.setterRatifierSetIsRootRatified(address(setterRatifier), ROOT, true);
    }

    function test_onlyBundler3_arbitraryEOAReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        authAdapter.setterRatifierSetIsRootRatified(address(setterRatifier), ROOT, true);
    }

    /// @dev An initiator who hasn't midnight-authorized this adapter is rejected by the
    ///      ratifier's own auth gate — msg.sender (adapter) lacks `IMidnight.isAuthorized(maker, ...)`.
    function test_unauthorizedInitiator_ratifierReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(ISetterRatifier.Unauthorized.selector);
        bundler3.multicall(_setIsRatified(address(setterRatifier), ROOT, true));
    }

    function test_independentRatifiers() public {
        SetterRatifier other = new SetterRatifier(address(midnight));

        vm.prank(user);
        bundler3.multicall(_setIsRatified(address(setterRatifier), ROOT, true));

        assertTrue(setterRatifier.isRootRatified(user, ROOT));
        assertFalse(other.isRootRatified(user, ROOT));
    }

    function testFuzz_ratify(bytes32 fuzzRoot, bool value) public {
        vm.prank(user);
        bundler3.multicall(_setIsRatified(address(setterRatifier), fuzzRoot, value));

        assertEq(setterRatifier.isRootRatified(user, fuzzRoot), value);
    }

    function test_batchedWithMidnightAuth() public {
        address freshUser = makeAddr("FreshUser");

        Call[] memory calls = new Call[](2);
        calls[0] = _call(address(authAdapter), abi.encodeCall(authAdapter.midnightSetIsAuthorized, (agent, true)));
        calls[1] = _call(
            address(authAdapter),
            abi.encodeCall(authAdapter.setterRatifierSetIsRootRatified, (address(setterRatifier), ROOT, true))
        );

        vm.prank(freshUser);
        midnight.setIsAuthorized(address(authAdapter), true, freshUser);

        vm.prank(freshUser);
        bundler3.multicall(calls);

        assertTrue(midnight.isAuthorized(freshUser, agent));
        assertTrue(setterRatifier.isRootRatified(freshUser, ROOT));
    }
}
