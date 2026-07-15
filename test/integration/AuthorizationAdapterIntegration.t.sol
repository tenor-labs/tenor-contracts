// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AuthorizationAdapter} from "../../src/bundler/AuthorizationAdapter.sol";
import {TenorAdapter} from "../../src/bundler/TenorAdapter.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";
import {Fixtures} from "../helpers/Fixtures.sol";

/// @title AuthorizationAdapterIntegration
/// @notice End-to-end model: user permanently authorizes ONLY AuthorizationAdapter, and
///         every bundle grants / uses / revokes TenorAdapter atomically inside a single Bundler3
///         multicall (issue #374).
contract AuthorizationAdapterIntegrationTest is Fixtures {
    AuthorizationAdapter internal authAdapter;
    TenorAdapter internal tenorAdapter;
    Midnight internal midnight;
    IBundler3 internal bundler3;

    address internal user;

    bytes32 internal constant GROUP = keccak256("integration-group");
    uint128 internal constant CONSUMED_AMOUNT = 123e18;

    function setUp() public {
        user = makeAddr("User");

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        bundler3 = deployBundler3();
        authAdapter = new AuthorizationAdapter(address(bundler3), address(midnight));
        tenorAdapter = deployTenorAdapter(bundler3, address(midnight));

        vm.prank(user);
        midnight.setIsAuthorized(address(authAdapter), true, user);
    }

    function _grant(address adapter, bool value) internal view returns (Call memory) {
        return _call(address(authAdapter), abi.encodeCall(authAdapter.midnightSetIsAuthorized, (adapter, value)));
    }

    function _setConsumed(bytes32 group, uint128 amount) internal view returns (Call memory) {
        return _call(address(tenorAdapter), abi.encodeCall(tenorAdapter.midnightSetConsumed, (group, amount)));
    }

    /* ───────── baseline: TenorAdapter has no permanent auth ───────── */

    function test_tenorAdapterHasNoPermanentAuth() public view {
        assertFalse(midnight.isAuthorized(user, address(tenorAdapter)));
        assertTrue(midnight.isAuthorized(user, address(authAdapter)));
    }

    function test_tenorAdapterOpWithoutGrantReverts() public {
        Call[] memory calls = new Call[](1);
        calls[0] = _setConsumed(GROUP, CONSUMED_AMOUNT);

        vm.prank(user);
        vm.expectRevert(IMidnight.Unauthorized.selector);
        bundler3.multicall(calls);
    }

    /* ───────── the practical use case: atomic grant → op → revoke ───────── */

    function test_grantOpRevoke_singleBundle() public {
        Call[] memory calls = new Call[](3);
        calls[0] = _grant(address(tenorAdapter), true);
        calls[1] = _setConsumed(GROUP, CONSUMED_AMOUNT);
        calls[2] = _grant(address(tenorAdapter), false);

        vm.prank(user);
        bundler3.multicall(calls);

        assertEq(midnight.consumed(user, GROUP), CONSUMED_AMOUNT);
        assertFalse(midnight.isAuthorized(user, address(tenorAdapter)));
        assertTrue(midnight.isAuthorized(user, address(authAdapter)));
    }

    /// @dev A revert mid-bundle unwinds the transient grant too, so no state leaks.
    function test_grantOpRevoke_bundleRevertUnwindsGrant() public {
        Call[] memory calls = new Call[](4);
        calls[0] = _grant(address(tenorAdapter), true);
        calls[1] = _setConsumed(GROUP, CONSUMED_AMOUNT);
        // Midnight.setConsumed reverts if new amount < current (consumed is monotonic).
        calls[2] = _setConsumed(GROUP, CONSUMED_AMOUNT - 1);
        calls[3] = _grant(address(tenorAdapter), false);

        vm.prank(user);
        vm.expectRevert();
        bundler3.multicall(calls);

        assertEq(midnight.consumed(user, GROUP), 0);
        assertFalse(midnight.isAuthorized(user, address(tenorAdapter)));
        assertTrue(midnight.isAuthorized(user, address(authAdapter)));
    }

    /// @dev Matches the issue's scope expansion: grant, use, and revoke multiple distinct
    ///      adapters (TenorAdapter + callbacks + renewal) in one bundle.
    function test_grantOpRevoke_multipleAdaptersInOneBundle() public {
        address phantomCallback = makeAddr("PhantomCallback");

        Call[] memory calls = new Call[](5);
        calls[0] = _grant(address(tenorAdapter), true);
        calls[1] = _grant(phantomCallback, true);
        calls[2] = _setConsumed(GROUP, CONSUMED_AMOUNT);
        calls[3] = _grant(address(tenorAdapter), false);
        calls[4] = _grant(phantomCallback, false);

        vm.prank(user);
        bundler3.multicall(calls);

        assertEq(midnight.consumed(user, GROUP), CONSUMED_AMOUNT);
        assertFalse(midnight.isAuthorized(user, address(tenorAdapter)));
        assertFalse(midnight.isAuthorized(user, phantomCallback));
        assertTrue(midnight.isAuthorized(user, address(authAdapter)));
    }
}
