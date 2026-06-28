// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {OracleWithValidationFactory} from "@factories/OracleWithValidationFactory.sol";
import {IOracleWithValidationFactory} from "@factories/interfaces/IOracleWithValidationFactory.sol";
import {OracleWithValidation} from "@oracles/OracleWithValidation.sol";
import {IOracle} from "@midnight/interfaces/IOracle.sol";
import {IOracleWithValidation} from "@oracles/interfaces/IOracleWithValidation.sol";
import {MockValidationOracle} from "../../helpers/MockValidationOracle.sol";

contract OracleWithValidationFactoryTest is Test {
    OracleWithValidationFactory public factory;
    MockValidationOracle public primaryOracle;
    MockValidationOracle public validationOracle;

    address public owner;

    uint256 constant BASE_PRICE = 1e36;
    uint256 constant MAX_DEVIATION = 5e16; // 5%

    event OracleWithValidationDeployed(
        address indexed oracle,
        address primaryOracle,
        address validationOracle,
        uint256 maxOracleDeviation,
        bool revertOnValidationOracleFailure,
        address owner,
        bytes32 salt
    );

    function setUp() public {
        factory = new OracleWithValidationFactory();
        primaryOracle = new MockValidationOracle(BASE_PRICE);
        validationOracle = new MockValidationOracle(BASE_PRICE);
        owner = makeAddr("owner");
    }

    /* DEPLOYMENT TESTS */

    function test_DeployOracle_Success() public {
        bytes32 salt = keccak256("test_salt");

        vm.expectEmit(false, false, false, true);
        emit IOracleWithValidationFactory.OracleWithValidationDeployed(
            address(0), // We don't know the address yet
            address(primaryOracle),
            address(validationOracle),
            MAX_DEVIATION,
            true,
            owner,
            salt
        );

        address oracleAddress = factory.createOracleWithValidation(
            IOracle(address(primaryOracle)), IOracle(address(validationOracle)), MAX_DEVIATION, true, owner, salt
        );

        // Verify oracle was deployed
        assertTrue(oracleAddress != address(0));
        assertTrue(factory.isDeployedOracle(oracleAddress));

        // Verify oracle configuration
        IOracleWithValidation oracleInterface = IOracleWithValidation(oracleAddress);
        OracleWithValidation oracleImpl = OracleWithValidation(oracleAddress);
        assertEq(address(oracleInterface.PRIMARY_ORACLE()), address(primaryOracle));
        assertEq(address(oracleInterface.VALIDATION_ORACLE()), address(validationOracle));
        assertEq(oracleInterface.MAX_ORACLE_DEVIATION(), MAX_DEVIATION);
        assertEq(oracleImpl.owner(), owner);
        assertFalse(oracleInterface.validationCheckPaused());
    }

    function test_DeployOracle_DeterministicAddress() public {
        bytes32 salt = keccak256("deterministic");

        address oracleAddress = factory.createOracleWithValidation(
            IOracle(address(primaryOracle)), IOracle(address(validationOracle)), MAX_DEVIATION, true, owner, salt
        );

        // Compute expected CREATE2 address
        bytes memory creationCode = abi.encodePacked(
            type(OracleWithValidation).creationCode,
            abi.encode(IOracle(address(primaryOracle)), IOracle(address(validationOracle)), MAX_DEVIATION, true, owner)
        );
        address expected = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(creationCode)))))
        );

        assertEq(oracleAddress, expected);
    }

    function test_DeployOracle_DuplicateSaltReverts() public {
        bytes32 salt = keccak256("duplicate");

        factory.createOracleWithValidation(
            IOracle(address(primaryOracle)), IOracle(address(validationOracle)), MAX_DEVIATION, true, owner, salt
        );

        // Same salt + same params should revert
        vm.expectRevert();
        factory.createOracleWithValidation(
            IOracle(address(primaryOracle)), IOracle(address(validationOracle)), MAX_DEVIATION, true, owner, salt
        );
    }

    function test_DeployOracle_MultipleDeployments() public {
        // Deploy first oracle
        address oracle1 = factory.createOracleWithValidation(
            IOracle(address(primaryOracle)),
            IOracle(address(validationOracle)),
            MAX_DEVIATION,
            true,
            owner,
            keccak256("salt1")
        );

        // Deploy second oracle with different parameters
        MockValidationOracle primaryOracle2 = new MockValidationOracle(BASE_PRICE * 2);
        address oracle2 = factory.createOracleWithValidation(
            IOracle(address(primaryOracle2)),
            IOracle(address(validationOracle)),
            MAX_DEVIATION,
            true,
            owner,
            keccak256("salt2")
        );

        // Verify both are tracked
        assertTrue(factory.isDeployedOracle(oracle1));
        assertTrue(factory.isDeployedOracle(oracle2));

        // Verify they are different addresses
        assertTrue(oracle1 != oracle2);
    }

    function test_IsDeployedOracle_ReturnsTrueForDeployed() public {
        address oracleAddr = factory.createOracleWithValidation(
            IOracle(address(primaryOracle)),
            IOracle(address(validationOracle)),
            MAX_DEVIATION,
            true,
            owner,
            keccak256("deployed")
        );

        assertTrue(factory.isDeployedOracle(oracleAddr));
    }

    function test_IsDeployedOracle_ReturnsFalseForNonDeployed() public {
        address randomAddress = makeAddr("random");
        assertFalse(factory.isDeployedOracle(randomAddress));
    }

    /* INTEGRATION TESTS */

    function test_DeployedOracle_CanCallPrice() public {
        address oracleAddress = factory.createOracleWithValidation(
            IOracle(address(primaryOracle)),
            IOracle(address(validationOracle)),
            MAX_DEVIATION,
            true,
            owner,
            keccak256("price_test")
        );

        IOracleWithValidation oracleInterface = IOracleWithValidation(oracleAddress);
        uint256 oraclePrice = oracleInterface.price();
        assertEq(oraclePrice, BASE_PRICE);
    }

    function test_DeployedOracle_OwnerCanPause() public {
        address oracleAddress = factory.createOracleWithValidation(
            IOracle(address(primaryOracle)),
            IOracle(address(validationOracle)),
            MAX_DEVIATION,
            true,
            owner,
            keccak256("pause_test")
        );

        IOracleWithValidation oracleInterface = IOracleWithValidation(oracleAddress);

        vm.prank(owner);
        oracleInterface.pauseValidationCheck();

        assertTrue(oracleInterface.validationCheckPaused());
    }
}
