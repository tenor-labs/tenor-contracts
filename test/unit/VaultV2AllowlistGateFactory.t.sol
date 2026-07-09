// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultV2AllowlistGateFactory} from "@factories/VaultV2AllowlistGateFactory.sol";
import {IVaultV2AllowlistGateFactory} from "@factories/interfaces/IVaultV2AllowlistGateFactory.sol";
import {VaultV2AllowlistGate} from "@gates/VaultV2AllowlistGate.sol";

contract VaultV2AllowlistGateFactoryTest is Test {
    VaultV2AllowlistGateFactory internal factory;
    address internal owner;

    function setUp() public {
        factory = new VaultV2AllowlistGateFactory();
        owner = makeAddr("owner");
    }

    function _predictGateAddress(address gateOwner, bytes32 salt) internal view returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(VaultV2AllowlistGate).creationCode, abi.encode(gateOwner)));
        return vm.computeCreate2Address(salt, initCodeHash, address(factory));
    }

    function test_deploy_succeeds() public {
        address gate = factory.deployVaultV2AllowlistGate(owner, bytes32(0));
        assertTrue(gate.code.length > 0);
        assertTrue(factory.isDeployedGate(gate));
    }

    function test_deploy_setsGateOwner() public {
        address gate = factory.deployVaultV2AllowlistGate(owner, bytes32(0));
        assertEq(VaultV2AllowlistGate(gate).owner(), owner);
    }

    function test_deploy_emitsEvent() public {
        bytes32 salt = keccak256("event");
        address expectedGate = _predictGateAddress(owner, salt);
        vm.expectEmit(true, true, true, true);
        emit IVaultV2AllowlistGateFactory.VaultV2AllowlistGateDeployed(expectedGate, owner, salt);
        factory.deployVaultV2AllowlistGate(owner, salt);
    }

    function test_deploy_matchesCreate2Prediction() public {
        bytes32 salt = keccak256("deterministic");
        address gate = factory.deployVaultV2AllowlistGate(owner, salt);
        assertEq(gate, _predictGateAddress(owner, salt));
    }

    function test_deploy_revertsOnDuplicateOwnerAndSalt() public {
        bytes32 salt = keccak256("duplicate");
        factory.deployVaultV2AllowlistGate(owner, salt);
        vm.expectRevert(new bytes(0));
        factory.deployVaultV2AllowlistGate(owner, salt);
    }

    function test_deploy_differentSaltsProduceDifferentAddresses() public {
        address gate1 = factory.deployVaultV2AllowlistGate(owner, bytes32(uint256(1)));
        address gate2 = factory.deployVaultV2AllowlistGate(owner, bytes32(uint256(2)));
        assertTrue(gate1 != gate2);
        assertTrue(factory.isDeployedGate(gate1));
        assertTrue(factory.isDeployedGate(gate2));
    }

    function test_deploy_differentOwnersProduceDifferentAddresses() public {
        bytes32 salt = keccak256("same_salt");
        address otherOwner = makeAddr("otherOwner");
        address gate1 = factory.deployVaultV2AllowlistGate(owner, salt);
        address gate2 = factory.deployVaultV2AllowlistGate(otherOwner, salt);
        assertTrue(gate1 != gate2);
        assertEq(VaultV2AllowlistGate(gate1).owner(), owner);
        assertEq(VaultV2AllowlistGate(gate2).owner(), otherOwner);
    }

    function test_isDeployedGate_falseForNonDeployed() public {
        assertFalse(factory.isDeployedGate(address(0)));
        assertFalse(factory.isDeployedGate(makeAddr("random")));
    }
}
