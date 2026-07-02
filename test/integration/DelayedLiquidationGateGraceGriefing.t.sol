// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DelayedLiquidationGate} from "@gates/DelayedLiquidationGate.sol";
import {IDelayedLiquidationGate} from "@gates/interfaces/IDelayedLiquidationGate.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {IBuyCallback, ISellCallback} from "@midnight/interfaces/ICallbacks.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {SetterRatifier} from "@midnight/ratifiers/SetterRatifier.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

/// @dev Borrower's own callback. Supplies collateral in onSell so the position becomes healthy
///      before take() returns. It is pre-authorized by the borrower to call supplyCollateral on their behalf.
contract BorrowerCallback is ISellCallback {
    IMidnight public immutable MORPHO_MIDNIGHT;
    IERC20 public immutable COLLATERAL;

    constructor(address morphoMidnight, address _collateral) {
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
        COLLATERAL = IERC20(_collateral);
    }

    function onSell(
        bytes32,
        Market memory market,
        uint256,
        uint256,
        uint256,
        address seller,
        address,
        bytes memory data
    ) external returns (bytes32) {
        (uint256 collateralIndex, uint256 amount) = abi.decode(data, (uint256, uint256));
        COLLATERAL.approve(msg.sender, amount);
        MORPHO_MIDNIGHT.supplyCollateral(market, collateralIndex, amount, seller);
        return CALLBACK_SUCCESS;
    }
}

/// @dev Malicious taker callback. In onBuy (while the borrower is transiently unhealthy) it calls
///      startGracePeriod() on the borrower. The callback contract must also hold and approve the loan
///      token because Midnight uses buyerCallback as the payer when it is set (Midnight.sol:390).
contract AttackerCallback is IBuyCallback {
    DelayedLiquidationGate public immutable GATE;
    bytes32 public immutable MARKET_ID;
    address public immutable TARGET_BORROWER;
    address public immutable ATTACKER_EOA;

    constructor(address _gate, bytes32 _marketId, address _targetBorrower, address _attackerEOA) {
        GATE = DelayedLiquidationGate(_gate);
        MARKET_ID = _marketId;
        TARGET_BORROWER = _targetBorrower;
        ATTACKER_EOA = _attackerEOA;
    }

    bool public startGracePeriodReverted;

    function onBuy(bytes32, Market memory, uint256, uint256, uint256, address, bytes memory)
        external
        returns (bytes32)
    {
        // Borrower is transiently unhealthy here: debt has been applied but collateral has not yet
        // been supplied (that happens in the borrower's onSell, which runs after onBuy).
        try GATE.startGracePeriod(MARKET_ID, TARGET_BORROWER, ATTACKER_EOA) {}
        catch {
            startGracePeriodReverted = true;
        }
        return CALLBACK_SUCCESS;
    }
}

/// @title Test_GraceGriefAttack
/// @notice A malicious lender takes a borrower's offer and starts the liquidation grace period
///         on the healthy borrower during the take() callbacks. Attack is triggered by the TAKER
///         (lender), not the borrower themselves, as long as the borrower uses a
///         lazy-collateral-supply callback.
contract Test_GraceGriefAttack is Test {
    Midnight internal morphoMidnight;
    DelayedLiquidationGate internal gate;
    SetterRatifier internal ratifier;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    address internal borrower;
    address internal attacker = makeAddr("attacker");

    BorrowerCallback internal borrowerCallback;
    AttackerCallback internal attackerCallback;

    Market internal market;
    bytes32 internal marketId;

    uint256 internal constant GRACE_PERIOD = 1 hours;
    uint256 internal constant LIQUIDATION_PERIOD = 2 hours;
    uint256 internal constant LLTV = 0.77e18;
    uint256 internal constant UNITS = 100e18;

    function setUp() public {
        borrower = makeAddr("borrower");

        morphoMidnight = new Midnight();
        enableDefaultLltvs(morphoMidnight);
        morphoMidnight.setFeeClaimer(address(this));

        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(1e36); // 1:1

        gate = new DelayedLiquidationGate(address(morphoMidnight), GRACE_PERIOD, LIQUIDATION_PERIOD, 1 minutes);
        ratifier = new SetterRatifier(address(morphoMidnight));

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(morphoMidnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(gate)
        });

        morphoMidnight.touchMarket(market);
        marketId = IdLib.toId(market);

        // Deploy the borrower's lazy-collateral callback and fund it with enough collateral
        // to cover the UNITS of debt at the given LLTV (plus a small margin).
        borrowerCallback = new BorrowerCallback(address(morphoMidnight), address(collateralToken));
        uint256 collateralAmount = (UNITS * 1e18) / LLTV + 1e18; // ~130e18
        collateralToken.mint(address(borrowerCallback), collateralAmount);

        // Borrower authorizes the ratifier (required by Midnight.take) and the callback
        // (required so supplyCollateral(onBehalf=borrower) from the callback succeeds).
        vm.startPrank(borrower);
        morphoMidnight.setIsAuthorized(address(ratifier), true, borrower);
        morphoMidnight.setIsAuthorized(address(borrowerCallback), true, borrower);
        vm.stopPrank();

        // Deploy the attacker's callback that calls startGracePeriod() in onBuy.
        attackerCallback = new AttackerCallback(address(gate), marketId, borrower, attacker);

        // Because buyerCallback != 0, Midnight pulls loan tokens from the attackerCallback itself.
        loanToken.mint(address(attackerCallback), UNITS);
        vm.prank(address(attackerCallback));
        loanToken.approve(address(morphoMidnight), type(uint256).max);
    }

    function _buildBorrowerOffer() internal view returns (Offer memory o) {
        o.market = market;
        o.buy = false; // borrower sells bonds = borrows
        o.maker = borrower;
        o.start = block.timestamp;
        o.expiry = block.timestamp + 1 hours;
        o.tick = MAX_TICK; // price = 1 -> buyerAssets = units
        o.callback = address(borrowerCallback);
        o.callbackData = abi.encode(uint256(0), (UNITS * 1e18) / LLTV + 1e18);
        o.receiverIfMakerIsSeller = address(borrowerCallback);
        o.ratifier = address(ratifier);
        o.maxUnits = uint128(UNITS);
    }

    function test_lender_can_grief_borrower_via_take_callback() public {
        Offer memory offer = _buildBorrowerOffer();
        bytes32 offerRoot = HashLib.hashOffer(offer);

        // Borrower pre-ratifies the offer root via SetterRatifier (avoids signing in test).
        vm.prank(borrower);
        ratifier.setIsRootRatified(borrower, offerRoot, true);

        bytes32[] memory emptyProof = new bytes32[](0);

        // Attacker takes the offer and passes their malicious callback as takerCallback.
        vm.prank(attacker);
        morphoMidnight.take(
            offer,
            abi.encode(offerRoot, uint256(0), emptyProof),
            UNITS,
            attacker,
            address(0),
            address(attackerCallback),
            ""
        );

        // Post-conditions with the fix in place:
        //
        // 1. The borrower's position is healthy (collateral was supplied in onSell).
        assertTrue(
            morphoMidnight.isHealthy(market, marketId, borrower), "borrower should be healthy after take() completes"
        );

        // 2. The attacker's startGracePeriod call during onBuy reverted (Midnight's transient
        //    liquidation lock is now honored by DelayedLiquidationGate via isLiquidatable).
        assertTrue(
            attackerCallback.startGracePeriodReverted(),
            "attack path: startGracePeriod should revert while take() is in progress"
        );

        // 3. No grace period is active.
        (uint56 ts,) = gate.gracePeriodInfo(borrower, marketId);
        assertEq(uint256(ts), 0, "no grace period should be set on a healthy borrower");
    }
}
