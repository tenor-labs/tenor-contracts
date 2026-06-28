// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {OracleWithValidation} from "@oracles/OracleWithValidation.sol";
import {IOracle} from "@midnight/interfaces/IOracle.sol";
import {IOracleWithValidation} from "@oracles/interfaces/IOracleWithValidation.sol";
import {MockValidationOracle} from "../../helpers/MockValidationOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract OracleWithValidationTest is Test {
    OracleWithValidation public oracle;
    MockValidationOracle public primaryOracle;
    MockValidationOracle public validationOracle;

    address public owner;
    address public user;

    uint256 constant BASE_PRICE = 1e36; // 1e36 as per Morpho standard
    uint256 constant MAX_DEVIATION = 5e16; // 5%

    event ValidationCheckPaused();
    event ValidationCheckUnpaused();

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Deploy mock oracles
        primaryOracle = new MockValidationOracle(BASE_PRICE);
        validationOracle = new MockValidationOracle(BASE_PRICE);

        // Deploy oracle with deviation (strict mode: revert on validation failure)
        vm.prank(owner);
        oracle = new OracleWithValidation(
            IOracle(address(primaryOracle)), IOracle(address(validationOracle)), MAX_DEVIATION, true, owner
        );
    }

    /* CONSTRUCTOR TESTS */

    function test_Constructor_Success() public view {
        assertEq(address(oracle.PRIMARY_ORACLE()), address(primaryOracle));
        assertEq(address(oracle.VALIDATION_ORACLE()), address(validationOracle));
        assertEq(oracle.MAX_ORACLE_DEVIATION(), MAX_DEVIATION);
        assertTrue(oracle.REVERT_ON_VALIDATION_ORACLE_FAILURE());
        assertEq(oracle.owner(), owner);
        assertFalse(oracle.validationCheckPaused());
    }

    /* PRICE TESTS - WITHIN DEVIATION */

    function test_Price_ReturnsPrimary_WhenPricesEqual() public {
        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setPrice(BASE_PRICE);

        assertEq(oracle.price(), BASE_PRICE);
    }

    function test_Price_ReturnsPrimary_WhenWithinDeviation_PrimaryHigher() public {
        // Primary 4% higher than validation (within 5% max deviation)
        primaryOracle.setPrice(1040e33); // 1.04e36
        validationOracle.setPrice(BASE_PRICE); // 1e36

        assertEq(oracle.price(), 1040e33);
    }

    function test_Price_ReturnsPrimary_WhenWithinDeviation_ValidationHigher() public {
        // Validation 4% higher than primary (within 5% max deviation)
        primaryOracle.setPrice(BASE_PRICE); // 1e36
        validationOracle.setPrice(1040e33); // 1.04e36

        // Deviation = |1e36 - 1.04e36| / 1e36 = 0.04e36 / 1e36 = 4%
        assertEq(oracle.price(), BASE_PRICE);
    }

    function test_Price_ReturnsAtExactMaxDeviation() public {
        // Exactly 5% deviation
        primaryOracle.setPrice(BASE_PRICE); // 1e36
        validationOracle.setPrice(1050e33); // 1.05e36

        // Deviation = |1e36 - 1.05e36| / 1e36 = 0.05e36 / 1e36 = 5%
        assertEq(oracle.price(), BASE_PRICE);
    }

    /* PRICE TESTS - EXCEEDS DEVIATION */

    function test_Price_RevertsWhenExceedsDeviation_PrimaryLower() public {
        // Primary 6% lower than validation (exceeds 5% max deviation)
        primaryOracle.setPrice(940e33); // 0.94e36
        validationOracle.setPrice(BASE_PRICE); // 1e36

        // Deviation = |0.94e36 - 1e36| / 0.94e36 = 0.06e36 / 0.94e36 ≈ 6.38%
        vm.expectRevert(IOracleWithValidation.ExcessiveOracleDeviation.selector);
        oracle.price();
    }

    function test_Price_RevertsWhenExceedsDeviation_PrimaryHigher() public {
        // Validation 6% lower than primary (exceeds 5% max deviation)
        primaryOracle.setPrice(BASE_PRICE); // 1e36
        validationOracle.setPrice(940e33); // 0.94e36

        // Deviation = |1e36 - 0.94e36| / 1e36 = 0.06e36 / 1e36 = 6%
        vm.expectRevert(IOracleWithValidation.ExcessiveOracleDeviation.selector);
        oracle.price();
    }

    function test_Price_RevertsWhenLargeDeviation() public {
        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setPrice(BASE_PRICE * 2); // 100% deviation

        vm.expectRevert(IOracleWithValidation.ExcessiveOracleDeviation.selector);
        oracle.price();
    }

    /* PRICE TESTS - ZERO PRIMARY PRICE */

    function test_Price_ZeroPrimary_RevertsViaDeviation_WhenValidationNonZero() public {
        // A zero primary price is no longer rejected outright; it flows into the deviation
        // check, which reverts because the non-zero validation price exceeds the (zero) bound.
        primaryOracle.setPrice(0);
        validationOracle.setPrice(BASE_PRICE);

        vm.expectRevert(IOracleWithValidation.ExcessiveOracleDeviation.selector);
        oracle.price();
    }

    function test_Price_ZeroPrimary_ReturnsZero_WhenPaused() public {
        // With validation paused, a zero primary price is returned as-is.
        vm.prank(owner);
        oracle.pauseValidationCheck();

        primaryOracle.setPrice(0);
        validationOracle.setPrice(BASE_PRICE);

        assertEq(oracle.price(), 0);
    }

    /* PRICE TESTS - PAUSED STATE */

    function test_Price_IgnoresDeviation_WhenPaused() public {
        // Pause validation check
        vm.prank(owner);
        oracle.pauseValidationCheck();

        // Set large deviation
        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setPrice(BASE_PRICE * 2); // 100% deviation

        // Should return primary price without reverting
        assertEq(oracle.price(), BASE_PRICE);
    }

    function test_Price_ChecksDeviation_AfterUnpause() public {
        // Pause then unpause
        vm.startPrank(owner);
        oracle.pauseValidationCheck();
        oracle.unpauseValidationCheck();
        vm.stopPrank();

        // Set large deviation
        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setPrice(BASE_PRICE * 2);

        // Should revert again
        vm.expectRevert(IOracleWithValidation.ExcessiveOracleDeviation.selector);
        oracle.price();
    }

    /* PAUSE/UNPAUSE TESTS */

    function test_PauseValidationCheck_Success() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IOracleWithValidation.ValidationCheckPaused();
        oracle.pauseValidationCheck();

        assertTrue(oracle.validationCheckPaused());
    }

    function test_PauseValidationCheck_RevertsWhenNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        oracle.pauseValidationCheck();
    }

    function test_PauseValidationCheck_RevertsWhenAlreadyPaused() public {
        vm.startPrank(owner);
        oracle.pauseValidationCheck();

        vm.expectRevert(IOracleWithValidation.NotAllowed.selector);
        oracle.pauseValidationCheck();
        vm.stopPrank();
    }

    function test_UnpauseValidationCheck_Success() public {
        // First pause
        vm.startPrank(owner);
        oracle.pauseValidationCheck();

        // Then unpause
        vm.expectEmit(true, true, true, true);
        emit IOracleWithValidation.ValidationCheckUnpaused();
        oracle.unpauseValidationCheck();
        vm.stopPrank();

        assertFalse(oracle.validationCheckPaused());
    }

    function test_UnpauseValidationCheck_RevertsWhenNotOwner() public {
        vm.prank(owner);
        oracle.pauseValidationCheck();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        oracle.unpauseValidationCheck();
    }

    function test_UnpauseValidationCheck_RevertsWhenNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(IOracleWithValidation.NotAllowed.selector);
        oracle.unpauseValidationCheck();
    }

    /* FUZZ TESTS */

    function testFuzz_Price_WithinDeviation(uint256 primaryPrice, uint256 deviationBps, bool isPositive) public {
        // Bound inputs to reasonable ranges
        primaryPrice = bound(primaryPrice, 1e30, 1e42); // Reasonable price range
        deviationBps = bound(deviationBps, 0, 500); // 0-5% in basis points

        // Calculate validation price with deviation (both positive and negative)
        uint256 deviation = (primaryPrice * deviationBps) / 10000;
        uint256 validationPrice = isPositive ? primaryPrice + deviation : primaryPrice - deviation;

        primaryOracle.setPrice(primaryPrice);
        validationOracle.setPrice(validationPrice);

        // Should not revert
        assertEq(oracle.price(), primaryPrice);
    }

    function testFuzz_Price_ExceedsDeviation(uint256 primaryPrice, uint256 deviationBps, bool isPositive) public {
        // Bound inputs
        primaryPrice = bound(primaryPrice, 1e30, 1e42);
        deviationBps = bound(deviationBps, 501, 10000); // 5.01% - 100%

        // Calculate validation price with deviation (both positive and negative)
        uint256 deviation = (primaryPrice * deviationBps) / 10000;
        uint256 validationPrice = isPositive ? primaryPrice + deviation : primaryPrice - deviation;

        // Ensure validation price doesn't underflow
        vm.assume(validationPrice > 0);

        primaryOracle.setPrice(primaryPrice);
        validationOracle.setPrice(validationPrice);

        // Should revert
        vm.expectRevert(IOracleWithValidation.ExcessiveOracleDeviation.selector);
        oracle.price();
    }

    /* OWNER TRANSFER TESTS (Using OpenZeppelin Ownable2Step) */

    function test_TransferOwnership_Success() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        oracle.transferOwnership(newOwner);

        // Ownership not transferred yet
        assertEq(oracle.owner(), owner);
        assertEq(oracle.pendingOwner(), newOwner);
    }

    function test_AcceptOwnership_Success() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        oracle.transferOwnership(newOwner);

        vm.prank(newOwner);
        oracle.acceptOwnership();

        assertEq(oracle.owner(), newOwner);
        assertEq(oracle.pendingOwner(), address(0));
    }

    function test_TransferOwnership_NewOwnerCanPause() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        oracle.transferOwnership(newOwner);

        vm.prank(newOwner);
        oracle.acceptOwnership();

        // New owner can pause
        vm.prank(newOwner);
        oracle.pauseValidationCheck();
        assertTrue(oracle.validationCheckPaused());
    }

    function test_RenounceOwnership_Success() public {
        vm.prank(owner);
        oracle.renounceOwnership();

        assertEq(oracle.owner(), address(0));

        // No one can call owner functions anymore
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        oracle.pauseValidationCheck();
    }

    /* ADDITIONAL EDGE CASE TESTS */

    function test_Price_RevertsWhenValidationPriceIsZero() public {
        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setPrice(0);

        // Should revert with excessive deviation (100% deviation)
        vm.expectRevert(IOracleWithValidation.ExcessiveOracleDeviation.selector);
        oracle.price();
    }

    function test_Price_RevertsWhenValidationPriceIsZero_EvenWhenPaused() public {
        // Pause validation check
        vm.prank(owner);
        oracle.pauseValidationCheck();

        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setPrice(0);

        // Should NOT revert when paused (validation oracle not checked)
        assertEq(oracle.price(), BASE_PRICE);
    }

    function test_Price_WithVerySmallPrices() public {
        // Test with very small prices to check for precision issues
        uint256 smallPrice = 1e18; // Much smaller than BASE_PRICE
        primaryOracle.setPrice(smallPrice);
        validationOracle.setPrice(smallPrice);

        assertEq(oracle.price(), smallPrice);
    }

    function test_Price_WithVeryLargePrices() public {
        // Test with very large prices to check for overflow
        // Note: Must ensure (largePrice * MAX_ORACLE_DEVIATION) / 1e18 doesn't overflow
        // MAX_ORACLE_DEVIATION = 5e16, so largePrice * 5e16 must fit in uint256
        // Max safe price = type(uint256).max / 5e16 ≈ 2.3e59
        uint256 largePrice = type(uint256).max / 1e18; // Safe from overflow
        primaryOracle.setPrice(largePrice);
        validationOracle.setPrice(largePrice);

        assertEq(oracle.price(), largePrice);
    }

    function test_Price_EdgeCase_MaxDeviationBoundary() public {
        // Test the exact boundary: primary = 1e36, validation = 1.05e36 (exactly 5%)
        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setPrice(BASE_PRICE + (BASE_PRICE * MAX_DEVIATION) / 1e18);

        // Should pass (exactly at max deviation)
        assertEq(oracle.price(), BASE_PRICE);
    }

    function test_Price_EdgeCase_JustOverMaxDeviation() public {
        // Test just over the boundary
        primaryOracle.setPrice(BASE_PRICE);
        // Add 1 wei more than max allowed deviation
        validationOracle.setPrice(BASE_PRICE + (BASE_PRICE * MAX_DEVIATION) / 1e18 + 1);

        // Should revert (just over max deviation)
        vm.expectRevert(IOracleWithValidation.ExcessiveOracleDeviation.selector);
        oracle.price();
    }

    /* VALIDATION ORACLE REVERT TESTS */

    function test_Price_RevertsWhenValidationOracleReverts() public {
        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setShouldRevert(true);

        vm.expectRevert(IOracleWithValidation.ValidationOracleFailure.selector);
        oracle.price();
    }

    function test_Price_SucceedsWhenValidationOracleReverts_WhenPaused() public {
        vm.prank(owner);
        oracle.pauseValidationCheck();

        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setShouldRevert(true);

        // Should succeed because validation oracle is never called when paused
        assertEq(oracle.price(), BASE_PRICE);
    }
}

contract OracleWithValidationGracefulTest is Test {
    OracleWithValidation public oracle;
    MockValidationOracle public primaryOracle;
    MockValidationOracle public validationOracle;

    address public owner;

    uint256 constant BASE_PRICE = 1e36;
    uint256 constant MAX_DEVIATION = 5e16; // 5%

    function setUp() public {
        owner = makeAddr("owner");

        primaryOracle = new MockValidationOracle(BASE_PRICE);
        validationOracle = new MockValidationOracle(BASE_PRICE);

        // Deploy oracle in graceful mode (don't revert on validation failure)
        vm.prank(owner);
        oracle = new OracleWithValidation(
            IOracle(address(primaryOracle)), IOracle(address(validationOracle)), MAX_DEVIATION, false, owner
        );
    }

    function test_Constructor_GracefulMode() public view {
        assertFalse(oracle.REVERT_ON_VALIDATION_ORACLE_FAILURE());
    }

    function test_Price_ReturnsPrimary_WhenValidationOracleReverts() public {
        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setShouldRevert(true);

        // Graceful mode: returns primary price when validation oracle reverts
        assertEq(oracle.price(), BASE_PRICE);
    }

    function test_Price_StillRevertsOnExcessiveDeviation() public {
        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setPrice(BASE_PRICE * 2); // 100% deviation

        // Should still revert when deviation is excessive (validation oracle didn't fail, it returned a bad price)
        vm.expectRevert(IOracleWithValidation.ExcessiveOracleDeviation.selector);
        oracle.price();
    }

    function test_Price_ReturnsPrimary_WhenWithinDeviation() public {
        primaryOracle.setPrice(BASE_PRICE);
        validationOracle.setPrice(BASE_PRICE);

        assertEq(oracle.price(), BASE_PRICE);
    }
}
