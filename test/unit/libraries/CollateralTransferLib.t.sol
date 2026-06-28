// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../../helpers/LltvHelper.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {MockERC20} from "../../helpers/mocks/MockERC20.sol";
import {Oracle} from "../../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../../helpers/MaxLifLib.sol";
import {CollateralTransferLib} from "../../../src/libraries/CollateralTransferLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";

/// @title CollateralTransferLibHarness
/// @notice Exposes CollateralTransferLib.transferCollaterals for testing via a callback-like contract.
/// @dev Must be authorized on Midnight to withdraw/supply collateral on behalf of borrower.
contract CollateralTransferLibHarness {
    using CollateralTransferLib for IMidnight;

    IMidnight public immutable MORPHO_MIDNIGHT;

    constructor(address morphoMidnight) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
    }

    function transferCollaterals(
        Market memory sourceMarket,
        Market memory targetMarket,
        address borrower,
        bytes32 sourceMarketId,
        uint256 sourceDebtBefore,
        uint256 repaidUnits
    ) external returns (address[] memory, uint256[] memory) {
        return MORPHO_MIDNIGHT.transferCollaterals(
            sourceMarket, targetMarket, borrower, sourceMarketId, sourceDebtBefore, repaidUnits
        );
    }
}

/// @title CollateralTransferLibTest
/// @notice Tests for CollateralTransferLib (CTL-1..5).
contract CollateralTransferLibTest is Test {
    Midnight internal midnight;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC20 internal collateralToken2;
    Oracle internal oracle;
    CollateralTransferLibHarness internal harness;

    address internal borrower;
    uint256 internal borrowerSK;

    Market internal sourceMarket;
    Market internal targetMarket;
    bytes32 internal sourceMarketId;

    uint256 constant DEBT_AMOUNT = 1000e18;
    uint256 constant COLLATERAL_AMOUNT = 5000e18;

    function setUp() public {
        (borrower, borrowerSK) = makeAddrAndKey("borrower");

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        collateralToken2 = new MockERC20("Col2", "COL2", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));

        harness = new CollateralTransferLibHarness(address(midnight));

        // Authorize harness to act on borrower's behalf
        vm.prank(borrower);
        midnight.setIsAuthorized(address(harness), true, borrower);

        // Create source market with 1 collateral
        CollateralParams[] memory srcCollaterals = new CollateralParams[](1);
        srcCollaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        sourceMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: srcCollaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        sourceMarketId = IdLib.toId(sourceMarket);

        // Create target market with same collateral
        CollateralParams[] memory tgtCollaterals = new CollateralParams[](1);
        tgtCollaterals[0] = srcCollaterals[0];

        targetMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: tgtCollaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Setup: borrower has collateral on source
        collateralToken.mint(borrower, COLLATERAL_AMOUNT);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), COLLATERAL_AMOUNT);
        midnight.supplyCollateral(sourceMarket, 0, COLLATERAL_AMOUNT, borrower);
        vm.stopPrank();

        // Approve harness for collateral tokens (for supplyCollateral to target)
        collateralToken.mint(address(harness), 0); // no extra needed, harness receives from withdraw
        vm.prank(address(harness));
        collateralToken.approve(address(midnight), type(uint256).max);
    }

    /* ═══════════════════════════════════════════════════════════════
       CTL-2: Final fill uses full balance
       ═══════════════════════════════════════════════════════════════ */

    function test_finalFill_transfersFullBalance() public {
        (, uint256[] memory amounts) =
            harness.transferCollaterals(sourceMarket, targetMarket, borrower, sourceMarketId, DEBT_AMOUNT, DEBT_AMOUNT);

        assertEq(amounts[0], COLLATERAL_AMOUNT, "CTL-2: final fill transfers ALL collateral");

        // Verify source is empty
        assertEq(midnight.collateral(sourceMarketId, borrower, 0), 0, "Source collateral = 0");

        // Verify target received
        bytes32 targetId = IdLib.toId(targetMarket);
        assertEq(midnight.collateral(targetId, borrower, 0), COLLATERAL_AMOUNT, "Target got all collateral");
    }

    /* ═══════════════════════════════════════════════════════════════
       CTL-3: Pro-rata is conservative (mulDivDown)
       ═══════════════════════════════════════════════════════════════ */

    function test_partialFill_proRata() public {
        uint256 repaidUnits = DEBT_AMOUNT / 3; // ~333e18

        (, uint256[] memory amounts) =
            harness.transferCollaterals(sourceMarket, targetMarket, borrower, sourceMarketId, DEBT_AMOUNT, repaidUnits);

        // Expected: COLLATERAL_AMOUNT * repaidUnits / DEBT_AMOUNT (mulDivDown)
        uint256 expected = (COLLATERAL_AMOUNT * repaidUnits) / DEBT_AMOUNT;
        assertEq(amounts[0], expected, "CTL-3: pro-rata = mulDivDown");

        // Verify conservative (never over-transfers)
        assertLe(amounts[0], COLLATERAL_AMOUNT, "Never over-transfers");

        // Verify source retains remainder
        uint256 remaining = midnight.collateral(sourceMarketId, borrower, 0);
        assertEq(remaining, COLLATERAL_AMOUNT - expected, "Source retains remainder");
    }

    function testFuzz_partialFill_neverOverTransfers(uint256 repaidUnits) public {
        repaidUnits = bound(repaidUnits, 1, DEBT_AMOUNT - 1); // partial only

        uint256 snap = vm.snapshotState();
        (, uint256[] memory amounts) =
            harness.transferCollaterals(sourceMarket, targetMarket, borrower, sourceMarketId, DEBT_AMOUNT, repaidUnits);
        vm.revertToState(snap);

        assertLe(amounts[0], COLLATERAL_AMOUNT, "CTL-3 fuzz: never over-transfers");
    }

    /* ═══════════════════════════════════════════════════════════════
       CTL-4: No transfer on zero balance
       ═══════════════════════════════════════════════════════════════ */

    function test_zeroBalance_noTransfer() public {
        // Withdraw all collateral first
        vm.prank(borrower);
        midnight.withdrawCollateral(sourceMarket, 0, COLLATERAL_AMOUNT, borrower, borrower);

        (, uint256[] memory amounts) = harness.transferCollaterals(
            sourceMarket, targetMarket, borrower, sourceMarketId, DEBT_AMOUNT, DEBT_AMOUNT / 2
        );

        assertEq(amounts[0], 0, "CTL-4: zero balance = zero transfer");
    }

    /* ═══════════════════════════════════════════════════════════════
       CTL-1: Only matching collaterals transferred
       ═══════════════════════════════════════════════════════════════ */

    function test_nonMatchingCollateral_skipped() public {
        // Create target with DIFFERENT collateral
        CollateralParams[] memory tgtCollaterals = new CollateralParams[](1);
        tgtCollaterals[0] = CollateralParams({
            token: address(collateralToken2), // different token
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        Market memory mismatchTarget = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: tgtCollaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        (, uint256[] memory amounts) = harness.transferCollaterals(
            sourceMarket, mismatchTarget, borrower, sourceMarketId, DEBT_AMOUNT, DEBT_AMOUNT
        );

        assertEq(amounts[0], 0, "CTL-1: non-matching collateral gets 0");

        // Source collateral unchanged
        assertEq(midnight.collateral(sourceMarketId, borrower, 0), COLLATERAL_AMOUNT, "Source collateral unchanged");
    }

    /* ═══════════════════════════════════════════════════════════════
       CTL-2 + CTL-3 combined: final fill vs partial consistency
       ═══════════════════════════════════════════════════════════════ */

    function test_finalFillTransfersMore_thanProRata() public {
        // With non-divisible amounts, final fill transfers more than pro-rata would
        // because pro-rata rounds down but final fill takes ALL

        // repaidUnits = DEBT_AMOUNT means final fill
        uint256 snap1 = vm.snapshotState();
        (, uint256[] memory finalAmounts) =
            harness.transferCollaterals(sourceMarket, targetMarket, borrower, sourceMarketId, DEBT_AMOUNT, DEBT_AMOUNT);
        vm.revertToState(snap1);

        // Same amount as partial (not final fill)
        uint256 snap2 = vm.snapshotState();
        (, uint256[] memory partialAmounts) = harness.transferCollaterals(
            sourceMarket, targetMarket, borrower, sourceMarketId, DEBT_AMOUNT + 1, DEBT_AMOUNT
        );
        vm.revertToState(snap2);

        // Final fill = full balance, partial = pro-rata
        assertEq(finalAmounts[0], COLLATERAL_AMOUNT, "Final fill = full balance");
        assertLe(partialAmounts[0], COLLATERAL_AMOUNT, "Partial <= full balance");
        assertGe(finalAmounts[0], partialAmounts[0], "Final fill >= partial fill");
    }
}

/* ═══════════════════════════════════════════════════════════════════════
   Multi-Collateral Tests
   ═══════════════════════════════════════════════════════════════════════ */

/// @title CollateralTransferLibMultiCollateralTest
/// @notice Tests for CollateralTransferLib with multiple collateral tokens.
contract CollateralTransferLibMultiCollateralTest is Test {
    Midnight internal midnight;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC20 internal collateralToken2;
    MockERC20 internal collateralToken3;
    MockERC20 internal collateralUSDC; // 6-decimal
    Oracle internal oracle;
    CollateralTransferLibHarness internal harness;

    address internal borrower;
    uint256 internal borrowerSK;

    uint256 constant DEBT_AMOUNT = 1000e18;

    function setUp() public {
        (borrower, borrowerSK) = makeAddrAndKey("borrower");

        loanToken = new MockERC20("Loan", "LOAN", 18);
        // Ensure collateral tokens are deployed in ascending address order for Midnight's sorted invariant
        // We'll sort them after deployment
        collateralToken = new MockERC20("Col", "COL", 18);
        collateralToken2 = new MockERC20("Col2", "COL2", 18);
        collateralToken3 = new MockERC20("Col3", "COL3", 18);
        collateralUSDC = new MockERC20("USDC Collateral", "cUSDC", 6);

        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));

        harness = new CollateralTransferLibHarness(address(midnight));

        vm.prank(borrower);
        midnight.setIsAuthorized(address(harness), true, borrower);
    }

    /// @dev Sorts two addresses ascending (Midnight requires sorted collaterals)
    function _sort2(address a, address b) internal pure returns (address low, address high) {
        if (a < b) return (a, b);
        return (b, a);
    }

    /// @dev Sorts three addresses ascending
    function _sort3(address a, address b, address c)
        internal
        pure
        returns (address first, address second, address third)
    {
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        if (a > b) (a, b) = (b, a);
        return (a, b, c);
    }

    /* ═══════════════════════════════════════════════════════════════
       CTL-MC-1: 2 collateral tokens, both match target
       ═══════════════════════════════════════════════════════════════ */

    function test_twoCollaterals_bothMatch_finalFill() public {
        (address low, address high) = _sort2(address(collateralToken), address(collateralToken2));
        uint256 colAmount1 = 5000e18;
        uint256 colAmount2 = 3000e18;

        // Create source market with 2 collaterals (sorted)
        CollateralParams[] memory srcCollaterals = new CollateralParams[](2);
        srcCollaterals[0] = CollateralParams({
            token: low, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        srcCollaterals[1] = CollateralParams({
            token: high, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        Market memory srcObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: srcCollaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 srcId = IdLib.toId(srcObl);

        // Target market with same 2 collaterals
        CollateralParams[] memory tgtCollaterals = new CollateralParams[](2);
        tgtCollaterals[0] = srcCollaterals[0];
        tgtCollaterals[1] = srcCollaterals[1];

        Market memory tgtObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: tgtCollaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Supply both collaterals
        MockERC20(low).mint(borrower, colAmount1);
        MockERC20(high).mint(borrower, colAmount2);
        vm.startPrank(borrower);
        MockERC20(low).approve(address(midnight), colAmount1);
        MockERC20(high).approve(address(midnight), colAmount2);
        midnight.supplyCollateral(srcObl, 0, colAmount1, borrower);
        midnight.supplyCollateral(srcObl, 1, colAmount2, borrower);
        vm.stopPrank();

        // Approve harness for both tokens
        vm.prank(address(harness));
        MockERC20(low).approve(address(midnight), type(uint256).max);
        vm.prank(address(harness));
        MockERC20(high).approve(address(midnight), type(uint256).max);

        // Final fill: both collaterals fully transferred
        (address[] memory tokens, uint256[] memory amounts) =
            harness.transferCollaterals(srcObl, tgtObl, borrower, srcId, DEBT_AMOUNT, DEBT_AMOUNT);

        assertEq(tokens.length, 2, "CTL-MC-1: should return 2 tokens");
        assertEq(amounts[0], colAmount1, "CTL-MC-1: first collateral fully transferred");
        assertEq(amounts[1], colAmount2, "CTL-MC-1: second collateral fully transferred");

        // Source empty
        assertEq(midnight.collateral(srcId, borrower, 0), 0, "Source col 0 = 0");
        assertEq(midnight.collateral(srcId, borrower, 1), 0, "Source col 1 = 0");

        // Target received both
        bytes32 tgtId = IdLib.toId(tgtObl);
        assertEq(midnight.collateral(tgtId, borrower, 0), colAmount1, "Target got col 0");
        assertEq(midnight.collateral(tgtId, borrower, 1), colAmount2, "Target got col 1");
    }

    function test_twoCollaterals_bothMatch_partialFill() public {
        (address low, address high) = _sort2(address(collateralToken), address(collateralToken2));
        uint256 colAmount1 = 5000e18;
        uint256 colAmount2 = 3000e18;
        uint256 repaidUnits = DEBT_AMOUNT / 4; // 25% partial fill

        CollateralParams[] memory srcCollaterals = new CollateralParams[](2);
        srcCollaterals[0] = CollateralParams({
            token: low, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        srcCollaterals[1] = CollateralParams({
            token: high, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        Market memory srcObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: srcCollaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 srcId = IdLib.toId(srcObl);

        CollateralParams[] memory tgtCollaterals = new CollateralParams[](2);
        tgtCollaterals[0] = srcCollaterals[0];
        tgtCollaterals[1] = srcCollaterals[1];

        Market memory tgtObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: tgtCollaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        MockERC20(low).mint(borrower, colAmount1);
        MockERC20(high).mint(borrower, colAmount2);
        vm.startPrank(borrower);
        MockERC20(low).approve(address(midnight), colAmount1);
        MockERC20(high).approve(address(midnight), colAmount2);
        midnight.supplyCollateral(srcObl, 0, colAmount1, borrower);
        midnight.supplyCollateral(srcObl, 1, colAmount2, borrower);
        vm.stopPrank();

        vm.prank(address(harness));
        MockERC20(low).approve(address(midnight), type(uint256).max);
        vm.prank(address(harness));
        MockERC20(high).approve(address(midnight), type(uint256).max);

        (, uint256[] memory amounts) =
            harness.transferCollaterals(srcObl, tgtObl, borrower, srcId, DEBT_AMOUNT, repaidUnits);

        // Pro-rata: colAmount * repaidUnits / DEBT_AMOUNT
        uint256 expected0 = (colAmount1 * repaidUnits) / DEBT_AMOUNT;
        uint256 expected1 = (colAmount2 * repaidUnits) / DEBT_AMOUNT;

        assertEq(amounts[0], expected0, "CTL-MC-1: col 0 pro-rata");
        assertEq(amounts[1], expected1, "CTL-MC-1: col 1 pro-rata");

        // Source retains remainder
        assertEq(midnight.collateral(srcId, borrower, 0), colAmount1 - expected0, "Source col 0 remainder");
        assertEq(midnight.collateral(srcId, borrower, 1), colAmount2 - expected1, "Source col 1 remainder");
    }

    /* ═══════════════════════════════════════════════════════════════
       CTL-MC-2: 3 collateral tokens in source, only 1 matches target
       ═══════════════════════════════════════════════════════════════ */

    function test_threeCollaterals_oneMatch() public {
        (address first, address second, address third) =
            _sort3(address(collateralToken), address(collateralToken2), address(collateralToken3));

        uint256 colAmount1 = 2000e18;
        uint256 colAmount2 = 3000e18;
        uint256 colAmount3 = 4000e18;

        CollateralParams[] memory srcCollaterals = new CollateralParams[](3);
        srcCollaterals[0] = CollateralParams({
            token: first, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        srcCollaterals[1] = CollateralParams({
            token: second, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        srcCollaterals[2] = CollateralParams({
            token: third, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        Market memory srcObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: srcCollaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 srcId = IdLib.toId(srcObl);

        // Target only has the second collateral
        CollateralParams[] memory tgtCollaterals = new CollateralParams[](1);
        tgtCollaterals[0] = CollateralParams({
            token: second, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        Market memory tgtObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: tgtCollaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Supply all 3 collaterals
        MockERC20(first).mint(borrower, colAmount1);
        MockERC20(second).mint(borrower, colAmount2);
        MockERC20(third).mint(borrower, colAmount3);
        vm.startPrank(borrower);
        MockERC20(first).approve(address(midnight), colAmount1);
        MockERC20(second).approve(address(midnight), colAmount2);
        MockERC20(third).approve(address(midnight), colAmount3);
        midnight.supplyCollateral(srcObl, 0, colAmount1, borrower);
        midnight.supplyCollateral(srcObl, 1, colAmount2, borrower);
        midnight.supplyCollateral(srcObl, 2, colAmount3, borrower);
        vm.stopPrank();

        // Approve harness for matching token only (second)
        vm.prank(address(harness));
        MockERC20(second).approve(address(midnight), type(uint256).max);

        // Final fill
        (address[] memory tokens, uint256[] memory amounts) =
            harness.transferCollaterals(srcObl, tgtObl, borrower, srcId, DEBT_AMOUNT, DEBT_AMOUNT);

        assertEq(tokens.length, 3, "CTL-MC-2: returns array for all 3 source collaterals");

        // Find which index corresponds to `second`
        uint256 matchIdx;
        for (uint256 i = 0; i < 3; i++) {
            if (tokens[i] == second) matchIdx = i;
        }

        // Only the matching collateral should be transferred
        for (uint256 i = 0; i < 3; i++) {
            if (i == matchIdx) {
                assertEq(amounts[i], colAmount2, "CTL-MC-2: matching collateral fully transferred");
            } else {
                assertEq(amounts[i], 0, "CTL-MC-2: non-matching collateral = 0");
            }
        }

        // Source: non-matching collaterals unchanged
        assertEq(midnight.collateral(srcId, borrower, 0), colAmount1, "Source col 0 unchanged");
        assertEq(midnight.collateral(srcId, borrower, 2), colAmount3, "Source col 2 unchanged");

        // Source: matching collateral = 0
        assertEq(midnight.collateral(srcId, borrower, matchIdx), 0, "Source matching col = 0");
    }

    /* ═══════════════════════════════════════════════════════════════
       CTL-MC-3: Mixed decimal tokens (18-decimal + 6-decimal)
       ═══════════════════════════════════════════════════════════════ */

    function test_mixedDecimals_18and6() public {
        (address low, address high) = _sort2(address(collateralToken), address(collateralUSDC));
        uint256 colAmount18 = 5000e18;
        uint256 colAmount6 = 10_000e6; // 10,000 USDC

        CollateralParams[] memory srcCollaterals = new CollateralParams[](2);
        srcCollaterals[0] = CollateralParams({
            token: low, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        srcCollaterals[1] = CollateralParams({
            token: high, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        Market memory srcObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: srcCollaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 srcId = IdLib.toId(srcObl);

        CollateralParams[] memory tgtCollaterals = new CollateralParams[](2);
        tgtCollaterals[0] = srcCollaterals[0];
        tgtCollaterals[1] = srcCollaterals[1];

        Market memory tgtObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: tgtCollaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Determine which index is which token
        uint256 idx18 = low == address(collateralToken) ? 0 : 1;
        uint256 idx6 = low == address(collateralUSDC) ? 0 : 1;

        // Supply
        collateralToken.mint(borrower, colAmount18);
        collateralUSDC.mint(borrower, colAmount6);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), colAmount18);
        collateralUSDC.approve(address(midnight), colAmount6);
        midnight.supplyCollateral(srcObl, idx18, colAmount18, borrower);
        midnight.supplyCollateral(srcObl, idx6, colAmount6, borrower);
        vm.stopPrank();

        vm.prank(address(harness));
        collateralToken.approve(address(midnight), type(uint256).max);
        vm.prank(address(harness));
        collateralUSDC.approve(address(midnight), type(uint256).max);

        // Partial fill (1/3)
        uint256 repaidUnits = DEBT_AMOUNT / 3;
        (, uint256[] memory amounts) =
            harness.transferCollaterals(srcObl, tgtObl, borrower, srcId, DEBT_AMOUNT, repaidUnits);

        // Pro-rata for each
        uint256 expected18 = (colAmount18 * repaidUnits) / DEBT_AMOUNT;
        uint256 expected6 = (colAmount6 * repaidUnits) / DEBT_AMOUNT;

        assertEq(amounts[idx18], expected18, "CTL-MC-3: 18-dec pro-rata");
        assertEq(amounts[idx6], expected6, "CTL-MC-3: 6-dec pro-rata");

        // Verify conservative (never over-transfer)
        assertLe(amounts[idx18], colAmount18, "18-dec never over-transfers");
        assertLe(amounts[idx6], colAmount6, "6-dec never over-transfers");

        // Source retains remainder
        assertEq(midnight.collateral(srcId, borrower, idx18), colAmount18 - expected18, "Source 18-dec remainder");
        assertEq(midnight.collateral(srcId, borrower, idx6), colAmount6 - expected6, "Source 6-dec remainder");
    }

    function test_mixedDecimals_finalFill() public {
        (address low, address high) = _sort2(address(collateralToken), address(collateralUSDC));
        uint256 colAmount18 = 5000e18;
        uint256 colAmount6 = 10_000e6;

        CollateralParams[] memory srcCollaterals = new CollateralParams[](2);
        srcCollaterals[0] = CollateralParams({
            token: low, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        srcCollaterals[1] = CollateralParams({
            token: high, lltv: 0.945e18, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        Market memory srcObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: srcCollaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        bytes32 srcId = IdLib.toId(srcObl);

        CollateralParams[] memory tgtCollaterals = new CollateralParams[](2);
        tgtCollaterals[0] = srcCollaterals[0];
        tgtCollaterals[1] = srcCollaterals[1];

        Market memory tgtObl = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: tgtCollaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        uint256 idx18 = low == address(collateralToken) ? 0 : 1;
        uint256 idx6 = low == address(collateralUSDC) ? 0 : 1;

        collateralToken.mint(borrower, colAmount18);
        collateralUSDC.mint(borrower, colAmount6);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), colAmount18);
        collateralUSDC.approve(address(midnight), colAmount6);
        midnight.supplyCollateral(srcObl, idx18, colAmount18, borrower);
        midnight.supplyCollateral(srcObl, idx6, colAmount6, borrower);
        vm.stopPrank();

        vm.prank(address(harness));
        collateralToken.approve(address(midnight), type(uint256).max);
        vm.prank(address(harness));
        collateralUSDC.approve(address(midnight), type(uint256).max);

        // Final fill: all collateral transferred
        (, uint256[] memory amounts) =
            harness.transferCollaterals(srcObl, tgtObl, borrower, srcId, DEBT_AMOUNT, DEBT_AMOUNT);

        assertEq(amounts[idx18], colAmount18, "CTL-MC-3: 18-dec fully transferred on final fill");
        assertEq(amounts[idx6], colAmount6, "CTL-MC-3: 6-dec fully transferred on final fill");

        assertEq(midnight.collateral(srcId, borrower, idx18), 0, "Source 18-dec = 0");
        assertEq(midnight.collateral(srcId, borrower, idx6), 0, "Source 6-dec = 0");
    }
}
