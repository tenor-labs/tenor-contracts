// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MidnightAllowlistGateFactory} from "@factories/MidnightAllowlistGateFactory.sol";
import {IMidnightAllowlistGateFactory} from "@factories/interfaces/IMidnightAllowlistGateFactory.sol";
import {MidnightAllowlistGate} from "@gates/MidnightAllowlistGate.sol";

contract MidnightAllowlistGateFactoryTest is Test {
    MidnightAllowlistGateFactory internal factory;
    address internal owner;

    function setUp() public {
        factory = new MidnightAllowlistGateFactory();
        owner = makeAddr("owner");
    }

    function _predictGateAddress(address gateOwner, bytes32 salt) internal view returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(MidnightAllowlistGate).creationCode, abi.encode(gateOwner)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initCodeHash)))));
    }

    function test_deploy_succeeds() public {
        address gate = factory.deployMidnightAllowlistGate(owner, bytes32(0));
        assertTrue(gate.code.length > 0);
        assertTrue(factory.isDeployedGate(gate));
    }

    function test_deploy_setsGateOwner() public {
        address gate = factory.deployMidnightAllowlistGate(owner, bytes32(0));
        assertEq(MidnightAllowlistGate(gate).owner(), owner);
    }

    function test_deploy_emitsEvent() public {
        bytes32 salt = keccak256("event");
        address expectedGate = _predictGateAddress(owner, salt);
        vm.expectEmit(true, true, true, true);
        emit IMidnightAllowlistGateFactory.MidnightAllowlistGateDeployed(expectedGate, owner, salt);
        factory.deployMidnightAllowlistGate(owner, salt);
    }

    function test_deploy_matchesCreate2Prediction() public {
        bytes32 salt = keccak256("deterministic");
        address gate = factory.deployMidnightAllowlistGate(owner, salt);
        assertEq(gate, _predictGateAddress(owner, salt));
    }

    function test_deploy_revertsOnDuplicateOwnerAndSalt() public {
        bytes32 salt = keccak256("duplicate");
        factory.deployMidnightAllowlistGate(owner, salt);
        vm.expectRevert();
        factory.deployMidnightAllowlistGate(owner, salt);
    }

    function test_deploy_differentSaltsProduceDifferentAddresses() public {
        address gate1 = factory.deployMidnightAllowlistGate(owner, bytes32(uint256(1)));
        address gate2 = factory.deployMidnightAllowlistGate(owner, bytes32(uint256(2)));
        assertTrue(gate1 != gate2);
        assertTrue(factory.isDeployedGate(gate1));
        assertTrue(factory.isDeployedGate(gate2));
    }

    function test_deploy_differentOwnersProduceDifferentAddresses() public {
        bytes32 salt = keccak256("same_salt");
        address otherOwner = makeAddr("otherOwner");
        address gate1 = factory.deployMidnightAllowlistGate(owner, salt);
        address gate2 = factory.deployMidnightAllowlistGate(otherOwner, salt);
        assertTrue(gate1 != gate2);
        assertEq(MidnightAllowlistGate(gate1).owner(), owner);
        assertEq(MidnightAllowlistGate(gate2).owner(), otherOwner);
    }

    function test_isDeployedGate_falseForNonDeployed() public {
        assertFalse(factory.isDeployedGate(address(0)));
        assertFalse(factory.isDeployedGate(makeAddr("random")));
    }
}
