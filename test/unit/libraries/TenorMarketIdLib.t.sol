// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Market, CollateralParams} from "@midnight/interfaces/IMidnight.sol";
import {TenorMarketIdLib} from "../../../src/libraries/TenorMarketIdLib.sol";

contract MarketIdLibTest is Test {
    using TenorMarketIdLib for Market;

    Market internal base;
    bytes32 internal baseMarketId;

    function setUp() public {
        base.chainId = 1;
        base.midnight = address(0xABCD);
        base.loanToken = address(1);
        base.collateralParams
            .push(CollateralParams({token: address(2), lltv: 0.8e18, liquidationCursor: 0.25e18, oracle: address(3)}));
        base.maturity = 1000;
        base.rcfThreshold = 500;
        base.enterGate = address(4);
        base.liquidatorGate = address(5);
        baseMarketId = _clone().toTenorMarketId();
    }

    function _clone() internal view returns (Market memory) {
        return abi.decode(abi.encode(base), (Market));
    }

    function test_sameId_whenOnlyMaturityDiffers() public view {
        Market memory b = _clone();
        b.maturity = 9999;

        assertEq(baseMarketId, b.toTenorMarketId(), "maturity must not affect market ID");
    }

    function test_differentId_whenChainIdDiffers() public view {
        Market memory b = _clone();
        b.chainId = 999;

        assertNotEq(baseMarketId, b.toTenorMarketId(), "different chainId must yield different ID");
    }

    function test_differentId_whenMidnightDiffers() public view {
        Market memory b = _clone();
        b.midnight = address(0xBEEF);

        assertNotEq(baseMarketId, b.toTenorMarketId(), "different midnight must yield different ID");
    }

    function test_differentId_whenLoanTokenDiffers() public view {
        Market memory b = _clone();
        b.loanToken = address(0xBEEF);

        assertNotEq(baseMarketId, b.toTenorMarketId(), "different loanToken must yield different ID");
    }

    function test_differentId_whenCollateralTokenDiffers() public view {
        Market memory b = _clone();
        b.collateralParams[0].token = address(0xBEEF);

        assertNotEq(baseMarketId, b.toTenorMarketId(), "different collateralToken must yield different ID");
    }

    function test_differentId_whenLltvDiffers() public view {
        Market memory b = _clone();
        b.collateralParams[0].lltv = 0.5e18;

        assertNotEq(baseMarketId, b.toTenorMarketId(), "different lltv must yield different ID");
    }

    function test_differentId_whenLiquidationCursorDiffers() public view {
        Market memory b = _clone();
        b.collateralParams[0].liquidationCursor = 0.3e18;

        assertNotEq(baseMarketId, b.toTenorMarketId(), "different liquidationCursor must yield different ID");
    }

    function test_differentId_whenOracleDiffers() public view {
        Market memory b = _clone();
        b.collateralParams[0].oracle = address(0xBEEF);

        assertNotEq(baseMarketId, b.toTenorMarketId(), "different oracle must yield different ID");
    }

    function test_differentId_whenRcfThresholdDiffers() public view {
        Market memory b = _clone();
        b.rcfThreshold = 999;

        assertNotEq(baseMarketId, b.toTenorMarketId(), "different rcfThreshold must yield different ID");
    }

    function test_differentId_whenEnterGateDiffers() public view {
        Market memory b = _clone();
        b.enterGate = address(0xBEEF);

        assertNotEq(baseMarketId, b.toTenorMarketId(), "different enterGate must yield different ID");
    }

    function test_differentId_whenLiquidatorGateDiffers() public view {
        Market memory b = _clone();
        b.liquidatorGate = address(0xBEEF);

        assertNotEq(baseMarketId, b.toTenorMarketId(), "different liquidatorGate must yield different ID");
    }
}
