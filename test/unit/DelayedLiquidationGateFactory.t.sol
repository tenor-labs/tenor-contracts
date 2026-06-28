// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DelayedLiquidationGateFactory} from "../../src/factories/DelayedLiquidationGateFactory.sol";
import {IDelayedLiquidationGateFactory} from "../../src/factories/interfaces/IDelayedLiquidationGateFactory.sol";
import {DelayedLiquidationGate} from "@gates/DelayedLiquidationGate.sol";
import {Midnight} from "@midnight/Midnight.sol";

import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

contract DelayedLiquidationGateFactoryTest is Test {
    DelayedLiquidationGateFactory internal factory;
    Midnight internal morphoMidnight;

    uint256 internal constant MIN_PERIOD = 1 minutes;
    uint256 internal constant MAX_PERIOD = 86400 * 3;

    function setUp() public {
        morphoMidnight = new Midnight();
        enableDefaultLltvs(morphoMidnight);
        factory = new DelayedLiquidationGateFactory(address(morphoMidnight));
    }

    // ──────────────────────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────────────────────

    function test_constructor_setsMidnight() public view {
        assertEq(factory.MORPHO_MIDNIGHT(), address(morphoMidnight));
    }

    function test_constructor_constants() public view {
        assertEq(factory.MIN_PERIOD(), MIN_PERIOD);
        assertEq(factory.MAX_PERIOD(), MAX_PERIOD);
    }

    // ──────────────────────────────────────────────────────────────
    //  Successful deployment
    // ──────────────────────────────────────────────────────────────

    function test_deploy_succeeds() public {
        address gate = factory.deployDelayedLiquidationGate(1 hours, 2 hours, 1 minutes, bytes32(0));
        assertTrue(factory.isDeployedGate(gate));
    }

    function test_deploy_emitsEvent() public {
        vm.expectEmit(false, true, false, true);
        emit IDelayedLiquidationGateFactory.DelayedLiquidationGateDeployed(
            address(0), 1 hours, 2 hours, 1 minutes, address(this)
        );
        factory.deployDelayedLiquidationGate(1 hours, 2 hours, 1 minutes, bytes32(0));
    }

    function test_deploy_setsGateImmutables() public {
        address gate = factory.deployDelayedLiquidationGate(1 hours, 2 hours, 1 minutes, bytes32(0));
        DelayedLiquidationGate g = DelayedLiquidationGate(gate);
        assertEq(address(g.MORPHO_MIDNIGHT()), address(morphoMidnight));
        assertEq(g.GRACE_PERIOD(), 1 hours);
        assertEq(g.LIQUIDATION_PERIOD(), 2 hours);
        assertEq(g.PRIORITY_PERIOD(), 1 minutes);
    }

    function test_deploy_minPeriodBoundary() public {
        // gracePeriod = MIN_PERIOD, liquidationPeriod = priorityPeriod + MIN_PERIOD (minimum valid)
        address gate = factory.deployDelayedLiquidationGate(MIN_PERIOD, MIN_PERIOD + MIN_PERIOD, MIN_PERIOD, bytes32(0));
        assertTrue(factory.isDeployedGate(gate));
    }

    function test_deploy_maxPeriodBoundary() public {
        // Both at MAX_PERIOD, priorityPeriod capped at MIN_PERIOD
        address gate = factory.deployDelayedLiquidationGate(MAX_PERIOD, MAX_PERIOD, MIN_PERIOD, bytes32(0));
        assertTrue(factory.isDeployedGate(gate));
    }

    function test_deploy_zeroPriorityPeriod() public {
        // priorityPeriod = 0, liquidationPeriod just needs to be >= 0 + MIN_PERIOD = MIN_PERIOD
        address gate = factory.deployDelayedLiquidationGate(1 hours, MIN_PERIOD, 0, bytes32(0));
        assertTrue(factory.isDeployedGate(gate));
    }

    // ──────────────────────────────────────────────────────────────
    //  Validation: gracePeriod
    // ──────────────────────────────────────────────────────────────

    function test_deploy_revertsIfGracePeriodBelowMin() public {
        vm.expectRevert(IDelayedLiquidationGateFactory.InvalidPeriod.selector);
        factory.deployDelayedLiquidationGate(MIN_PERIOD - 1, 2 hours, 1 minutes, bytes32(0));
    }

    function test_deploy_revertsIfGracePeriodAboveMax() public {
        vm.expectRevert(IDelayedLiquidationGateFactory.InvalidPeriod.selector);
        factory.deployDelayedLiquidationGate(MAX_PERIOD + 1, 2 hours, 1 minutes, bytes32(0));
    }

    // ──────────────────────────────────────────────────────────────
    //  Validation: liquidationPeriod
    // ──────────────────────────────────────────────────────────────

    function test_deploy_revertsIfLiquidationPeriodBelowMin() public {
        vm.expectRevert(IDelayedLiquidationGateFactory.InvalidPeriod.selector);
        factory.deployDelayedLiquidationGate(1 hours, MIN_PERIOD - 1, 0, bytes32(0));
    }

    function test_deploy_revertsIfLiquidationPeriodAboveMax() public {
        vm.expectRevert(IDelayedLiquidationGateFactory.InvalidPeriod.selector);
        factory.deployDelayedLiquidationGate(1 hours, MAX_PERIOD + 1, 1 minutes, bytes32(0));
    }

    // ──────────────────────────────────────────────────────────────
    //  Validation: liquidationPeriod vs priorityPeriod gap
    // ──────────────────────────────────────────────────────────────

    function test_deploy_revertsIfLiquidationPeriodEqualsPriorityPeriod() public {
        // liquidationPeriod == priorityPeriod → gap is 0 < MIN_PERIOD
        vm.expectRevert(IDelayedLiquidationGateFactory.InvalidPeriod.selector);
        factory.deployDelayedLiquidationGate(1 hours, 2 hours, 2 hours, bytes32(0));
    }

    function test_deploy_revertsIfGapLessThanMinPeriod() public {
        // liquidationPeriod = priorityPeriod + MIN_PERIOD - 1 → gap is 59 seconds < MIN_PERIOD
        vm.expectRevert(IDelayedLiquidationGateFactory.InvalidPeriod.selector);
        factory.deployDelayedLiquidationGate(1 hours, 2 minutes - 1, 1 minutes, bytes32(0));
    }

    function test_deploy_succeedsIfGapExactlyMinPeriod() public {
        // liquidationPeriod = priorityPeriod + MIN_PERIOD → gap is exactly MIN_PERIOD
        address gate = factory.deployDelayedLiquidationGate(1 hours, 2 minutes, 1 minutes, bytes32(0));
        assertTrue(factory.isDeployedGate(gate));
    }

    function test_deploy_revertsIfLiquidationPeriodBelowPriorityPeriod() public {
        // liquidationPeriod < priorityPeriod
        vm.expectRevert(IDelayedLiquidationGateFactory.InvalidPeriod.selector);
        factory.deployDelayedLiquidationGate(1 hours, 1 minutes, 2 hours, bytes32(0));
    }

    // ──────────────────────────────────────────────────────────────
    //  Validation: priorityPeriod cap (audit I-01)
    // ──────────────────────────────────────────────────────────────

    function test_deploy_revertsIfPriorityPeriodAboveMin() public {
        // priorityPeriod > MIN_PERIOD must revert even if liquidationPeriod leaves a valid gap
        vm.expectRevert(IDelayedLiquidationGateFactory.InvalidPeriod.selector);
        factory.deployDelayedLiquidationGate(1 hours, MAX_PERIOD, MIN_PERIOD + 1, bytes32(0));
    }

    function test_deploy_succeedsIfPriorityPeriodEqualsMin() public {
        // priorityPeriod == MIN_PERIOD is the cap boundary (inclusive)
        address gate = factory.deployDelayedLiquidationGate(1 hours, 2 hours, MIN_PERIOD, bytes32(0));
        assertTrue(factory.isDeployedGate(gate));
    }

    // ──────────────────────────────────────────────────────────────
    //  isDeployedGate
    // ──────────────────────────────────────────────────────────────

    function test_isDeployedGate_falseForNonDeployed() public view {
        assertFalse(factory.isDeployedGate(address(0)));
        assertFalse(factory.isDeployedGate(address(this)));
    }

    // ──────────────────────────────────────────────────────────────
    //  CREATE2 determinism
    // ──────────────────────────────────────────────────────────────

    function test_deploy_differentSaltsProduceDifferentAddresses() public {
        address gate1 = factory.deployDelayedLiquidationGate(1 hours, 2 hours, 1 minutes, bytes32(uint256(1)));
        address gate2 = factory.deployDelayedLiquidationGate(1 hours, 2 hours, 1 minutes, bytes32(uint256(2)));
        assertTrue(gate1 != gate2);
        assertTrue(factory.isDeployedGate(gate1));
        assertTrue(factory.isDeployedGate(gate2));
    }
}
