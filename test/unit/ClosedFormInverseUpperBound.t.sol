// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {TakeMathLib} from "../../src/libraries/TakeMathLib.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {ClampFuzzFixtures} from "../helpers/ClampFuzzFixtures.sol";

/// @title Harness to expose TakeMathLib budget inverses for closed-form inverse testing
contract ClosedFormInverseHarness {
    using UtilsLib for uint256;

    function maxUnitsForSellerBudget(
        Midnight midnight,
        bytes32 marketId,
        Offer calldata offer,
        uint256 feeRate,
        uint256 maxBudget
    ) external view returns (uint256) {
        return TakeMathLib.maxUnitsForSellerBudget(midnight, marketId, offer, feeRate, maxBudget);
    }

    /// @dev Mirrors CallbackLib.sellerFeeFromTick: repayBudget = mulDivUp(units, sellerEffPrice, WAD).
    function forwardSellerRepayBudget(uint256 units, uint256 sellerPrice, uint256 feeRate)
        external
        pure
        returns (uint256)
    {
        uint256 effPrice = CallbackLib.sellerEffectivePrice(sellerPrice, feeRate);
        return units.mulDivUp(effPrice, WAD);
    }
}

/// @title Closed-Form Inverse Fuzz Test
/// @notice Verifies the safety and tightness invariants of TakeMathLib.maxUnitsForSellerBudget's
///         closed-form inverse computation.
contract ClosedFormInverseTest is ClampFuzzFixtures {
    using UtilsLib for uint256;

    Midnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    ClosedFormInverseHarness internal harness;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    Oracle internal oracle;

    Market internal market;
    bytes32 internal marketId;

    function setUp() public {
        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        oracle = new Oracle();
        oracle.setPrice(10e36);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        harness = new ClosedFormInverseHarness();

        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        marketId = IdLib.toId(market);

        _seedMarket(SEED_AMOUNT);
    }

    /* ═══════ Helpers ═══════ */

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        return Signature({v: v, r: r, s: s});
    }

    function _seedMarket(uint256 seedAmount) internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey("seedBorrower");
        address seedLender = makeAddr("seedLender");

        loanToken.mint(seedLender, type(uint128).max);
        collateralToken.mint(seedBorrower, type(uint128).max);

        MidnightSupplyCollateralCallback setupCb = new MidnightSupplyCollateralCallback(address(midnight));

        vm.startPrank(seedBorrower);
        collateralToken.approve(address(setupCb), type(uint256).max);
        midnight.setIsAuthorized(address(setupCb), true, seedBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, seedBorrower);
        vm.stopPrank();

        vm.prank(seedLender);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = seedAmount * 10;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: seedAmount, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory seedOffer = Offer({
            market: market,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256("seed"),
            callback: address(setupCb),
            callbackData: cbData,
            receiverIfMakerIsSeller: seedBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(seedOffer, seedBorrowerSK);
        bytes32 root = HashLib.hashOffer(seedOffer);
        uint256 seedUnits = seedAmount;

        vm.prank(seedLender);
        midnight.take(
            seedOffer,
            abi.encode(sig, root, uint256(0), new bytes32[](0)),
            seedUnits,
            seedLender,
            address(0),
            address(0),
            ""
        );
    }

    /* ═══════ maxUnitsForSellerBudget tightness (M-08) ═══════ */

    /// @dev Forward wrapper so overflow at result+1 can be caught via try/catch.
    function _tryForwardSellerRepayBudget(uint256 units, uint256 price, uint256 feeRate)
        internal
        view
        returns (bool ok, uint256 budget)
    {
        try harness.forwardSellerRepayBudget(units, price, feeRate) returns (uint256 b) {
            return (true, b);
        } catch {
            return (false, 0);
        }
    }

    /// @notice maxUnitsForSellerBudget SELL+fee — forward = mulDivUp(units, sellerEffPrice, WAD).
    ///         Safety: forward(result) <= maxBudget. Tightness: forward(result+1) > maxBudget.
    function testFuzz_maxUnitsForSellerBudget_sellWithFee(uint16 tickSeed, uint256 feeRateSeed, uint128 maxBudgetSeed)
        public
    {
        uint16 tick = _boundTick(tickSeed);
        uint256 feeRate = bound(feeRateSeed, 1, 0.5e18);
        uint256 maxBudget = bound(maxBudgetSeed, 1, type(uint128).max);

        address testMaker = makeAddr("testMakerSellerBudget");
        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: testMaker,
            start: 0,
            expiry: type(uint256).max,
            tick: tick,
            group: keccak256("test-sell-seller-budget"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        uint256 result = harness.maxUnitsForSellerBudget(midnight, marketId, offer, feeRate, maxBudget);
        uint256 price = TickLib.tickToPrice(tick);

        if (result == 0 || result == type(uint128).max) return;

        (bool ok, uint256 fwd) = _tryForwardSellerRepayBudget(result, price, feeRate);
        assertTrue(ok, "forward(result) overflowed");
        assertLe(fwd, maxBudget, "SAFETY: forward(result) > maxBudget");

        // Overflow at result+1 means the inverse already returned the max representable answer
        // for this budget — tightness vacuously holds.
        (bool okNext, uint256 fwdNext) = _tryForwardSellerRepayBudget(result + 1, price, feeRate);
        if (okNext) {
            assertGt(fwdNext, maxBudget, "TIGHTNESS: forward(result+1) <= maxBudget");
        }
    }
}
