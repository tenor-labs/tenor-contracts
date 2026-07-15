// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IMorpho} from "@morphoBlue/interfaces/IMorpho.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";
import {TenorAdapter} from "../../src/bundler/TenorAdapter.sol";
import {MigrationRatifier} from "../../src/ratifiers/MigrationRatifier.sol";

abstract contract Fixtures is Test {
    /// @dev Test-side bundle of the BorrowRenewalConfigurationV1Base constructor params.
    struct RenewalConfig {
        address entryRatePolicy;
        address exitRatePolicy;
        address renewalCadence;
        uint32 renewalWindow;
        uint32 exitWindow;
        uint32 minDuration;
        uint32 maxDuration;
    }

    // Canonical production renewal parameters, mirrored from the SDK renewal spec.
    uint32 internal constant DEFAULT_RENEWAL_WINDOW = 2 days;
    uint32 internal constant DEFAULT_EXIT_WINDOW = 1 days;
    uint32 internal constant DEFAULT_RENEWAL_MIN_DURATION = 24 days;
    uint32 internal constant DEFAULT_RENEWAL_MAX_DURATION = 30 days;

    function deployMorphoBlue(address owner) internal returns (IMorpho) {
        return IMorpho(deployCode("test/bin/Morpho.json", abi.encode(owner)));
    }

    function deployBundler3() internal returns (IBundler3) {
        return IBundler3(deployCode("test/bin/Bundler3.json"));
    }

    function defaultRenewalConfig() internal returns (RenewalConfig memory) {
        return RenewalConfig({
            entryRatePolicy: makeAddr("EntryRatePolicy"),
            exitRatePolicy: makeAddr("ExitRatePolicy"),
            renewalCadence: makeAddr("RenewalCadence"),
            renewalWindow: DEFAULT_RENEWAL_WINDOW,
            exitWindow: DEFAULT_EXIT_WINDOW,
            minDuration: DEFAULT_RENEWAL_MIN_DURATION,
            maxDuration: DEFAULT_RENEWAL_MAX_DURATION
        });
    }

    function deployMigrationRatifier(address midnight) internal returns (MigrationRatifier) {
        return new MigrationRatifier(
            midnight,
            makeAddr("BorrowMidnightRenewalCallback"),
            makeAddr("BorrowBlueToMidnightCallback"),
            makeAddr("LendVaultToMidnightCallback"),
            makeAddr("BorrowMidnightToBlueCallback"),
            makeAddr("LendMidnightToVaultCallback"),
            makeAddr("LendMidnightRenewalCallback"),
            address(this)
        );
    }

    function deployTenorAdapter(IBundler3 bundler3, address midnight, address ratifier, RenewalConfig memory config)
        internal
        returns (TenorAdapter)
    {
        return new TenorAdapter(
            address(bundler3),
            midnight,
            ratifier,
            config.entryRatePolicy,
            config.exitRatePolicy,
            config.renewalCadence,
            config.renewalWindow,
            config.exitWindow,
            config.minDuration,
            config.maxDuration
        );
    }

    function deployTenorAdapter(IBundler3 bundler3, address midnight, address ratifier)
        internal
        returns (TenorAdapter)
    {
        return deployTenorAdapter(bundler3, midnight, ratifier, defaultRenewalConfig());
    }

    function deployTenorAdapter(IBundler3 bundler3, address midnight) internal returns (TenorAdapter) {
        return deployTenorAdapter(bundler3, midnight, address(deployMigrationRatifier(midnight)));
    }

    function _call(address to, bytes memory data) internal pure returns (Call memory) {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }
}
