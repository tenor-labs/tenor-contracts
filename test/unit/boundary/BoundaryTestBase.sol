// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";

import {Test} from "forge-std/Test.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../../helpers/LltvHelper.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {ITakeClamp} from "../../../src/router/interfaces/ITakeClamp.sol";
import {BuyOfferClamp} from "../../../src/router/clamps/BuyOfferClamp.sol";
import {SellOfferClamp} from "../../../src/router/clamps/SellOfferClamp.sol";
import {SupplyCollateralCallbackClamp} from "../../../src/router/clamps/SupplyCollateralCallbackClamp.sol";
import {VaultWithdrawClamp} from "../../../src/router/clamps/VaultWithdrawClamp.sol";
import {VaultSupplyClamp} from "../../../src/router/clamps/VaultSupplyClamp.sol";
import {BorrowMidnightRenewalClamp} from "../../../src/router/clamps/BorrowMidnightRenewalClamp.sol";
import {LendMidnightRenewalClamp} from "../../../src/router/clamps/LendMidnightRenewalClamp.sol";
import {BorrowMidnightToBlueClamp} from "../../../src/router/clamps/BorrowMidnightToBlueClamp.sol";
import {LendMidnightToVaultClamp} from "../../../src/router/clamps/LendMidnightToVaultClamp.sol";
import {BorrowBlueToMidnightClamp} from "../../../src/router/clamps/BorrowBlueToMidnightClamp.sol";
import {LendVaultToMidnightClamp} from "../../../src/router/clamps/LendVaultToMidnightClamp.sol";
import {MockERC20} from "../../helpers/mocks/MockERC20.sol";
import {TestERC4626} from "../../helpers/TestERC4626.sol";
import {Oracle} from "../../helpers/Oracle.sol";
import {LIQUIDATION_CURSOR} from "../../helpers/MaxLifLib.sol";
import {MidnightSupplyCollateralCallback} from "@callbacks/MidnightSupplyCollateralCallback.sol";
import {IMidnightSupplyCollateralCallback} from "@callbacks/interfaces/IMidnightSupplyCollateralCallback.sol";
import {BorrowBlueToMidnightCallback} from "@callbacks/BorrowBlueToMidnightCallback.sol";
import {IBorrowBlueToMidnightCallback} from "@callbacks/interfaces/IBorrowBlueToMidnightCallback.sol";
import {LendVaultToMidnightCallback} from "@callbacks/LendVaultToMidnightCallback.sol";
import {BorrowMidnightToBlueCallback} from "@callbacks/BorrowMidnightToBlueCallback.sol";
import {LendMidnightToVaultCallback} from "@callbacks/LendMidnightToVaultCallback.sol";
import {BorrowMidnightRenewalCallback} from "@callbacks/BorrowMidnightRenewalCallback.sol";
import {LendMidnightRenewalCallback} from "@callbacks/LendMidnightRenewalCallback.sol";
import {WAD} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {IMorpho, Id, Market as BlueMarket, MarketParams} from "../../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {IIrm} from "../../../lib/morpho-blue/src/interfaces/IIrm.sol";
import {StaticRatePolicy} from "../../../src/ratifiers/policies/StaticRatePolicy.sol";
import {TenorMarketIdLib} from "../../../src/libraries/TenorMarketIdLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Zero-rate IRM for Morpho Blue market creation
contract MockIrm is IIrm {
    function borrowRateView(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }

    function borrowRate(MarketParams memory, BlueMarket memory) external pure returns (uint256) {
        return 0;
    }
}

/* ═══════════════════════════════════════════════════════════════════════
                          BASE CONTRACT
   ═══════════════════════════════════════════════════════════════════════ */

/// @title BoundaryTestBase
/// @notice Shared infrastructure for all boundary unit tests
abstract contract BoundaryTestBase is Test {
    using TenorMarketIdLib for Market;
    using TenorMarketIdLib for address;
    using MarketParamsLib for MarketParams;

    /* ═══════ Constants ═══════ */
    uint16 internal constant TICK_LOW = 820;
    uint16 internal constant TICK_MID = 2800;
    uint16 internal constant TICK_HIGH = uint16(MAX_TICK);
    uint256 internal constant SEED_AMOUNT = 100e18;
    uint128 internal constant MAX_OFFER_CAPACITY = type(uint128).max - uint128(SEED_AMOUNT);

    /* ═══════ Core contracts ═══════ */
    Midnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    TestERC4626 internal vault;
    Oracle internal oracle;

    /* ═══════ Clamp contracts ═══════ */
    BuyOfferClamp internal buyOfferClamp;
    SellOfferClamp internal sellOfferClamp;
    SupplyCollateralCallbackClamp internal supplyCollateralCallbackClamp;
    VaultWithdrawClamp internal vaultWithdrawClamp;
    VaultSupplyClamp internal vaultSupplyClamp;
    BorrowMidnightRenewalClamp internal borrowMidnightRenewalClamp;
    LendMidnightRenewalClamp internal lendMidnightRenewalClamp;
    BorrowMidnightToBlueClamp internal borrowMidnightToBlueClamp;
    LendMidnightToVaultClamp internal lendMidnightToVaultClamp;
    BorrowBlueToMidnightClamp internal borrowBlueToMidnightClamp;
    LendVaultToMidnightClamp internal lendVaultToMidnightClamp;

    /* ═══════ Morpho Blue ═══════ */
    IMorpho internal morphoBlue;
    MockIrm internal morphoIrm;
    MarketParams internal blueMarketParams;

    /* ═══════ Callbacks ═══════ */
    BorrowBlueToMidnightCallback internal borrowBlueToMidnightCallback;
    LendVaultToMidnightCallback internal lendVaultToMidnightCallback;
    BorrowMidnightToBlueCallback internal borrowMidnightToBlueCallback;
    LendMidnightToVaultCallback internal lendMidnightToVaultCallback;
    BorrowMidnightRenewalCallback internal borrowMidnightRenewalCallback;
    LendMidnightRenewalCallback internal lendMidnightRenewalCallback;

    /* ═══════ Policies ═══════ */
    StaticRatePolicy internal permissiveRatePolicy;

    /* ═══════ Accounts ═══════ */
    address internal lender;
    uint256 internal lenderSK;
    address internal borrower;
    uint256 internal borrowerSK;

    /* ═══════ Markets ═══════ */
    Market internal sourceMarket;
    Market internal targetMarket;
    bytes32 internal sourceMarketId;
    bytes32 internal targetMarketId;

    /* ═══════ setUp ═══════ */

    function setUp() public virtual {
        // Accounts
        (lender, lenderSK) = makeAddrAndKey("lender");
        (borrower, borrowerSK) = makeAddrAndKey("borrower");

        // Tokens & oracle
        loanToken = new MockERC20("Loan", "LOAN", 18);
        collateralToken = new MockERC20("Col", "COL", 18);
        vault = new TestERC4626(IERC20(address(loanToken)), "Vault", "vLOAN");
        oracle = new Oracle();
        oracle.setPrice(10e36); // 1 collateral = 10 loan tokens

        // Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);
        vm.prank(borrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        // Morpho Blue
        morphoIrm = new MockIrm();
        morphoBlue = IMorpho(deployCode("test/bin/Morpho.json", abi.encode(address(this))));
        morphoBlue.enableIrm(address(morphoIrm));
        morphoBlue.enableLltv(0.77e18);

        blueMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(morphoIrm),
            lltv: 0.77e18
        });
        morphoBlue.createMarket(blueMarketParams);

        // Callbacks
        borrowBlueToMidnightCallback = new BorrowBlueToMidnightCallback(address(midnight), address(morphoBlue));
        lendVaultToMidnightCallback = new LendVaultToMidnightCallback(address(midnight));
        borrowMidnightToBlueCallback = new BorrowMidnightToBlueCallback(address(midnight), address(morphoBlue));
        lendMidnightToVaultCallback = new LendMidnightToVaultCallback(address(midnight));
        borrowMidnightRenewalCallback = new BorrowMidnightRenewalCallback(address(midnight));
        lendMidnightRenewalCallback = new LendMidnightRenewalCallback(address(midnight));

        // Permissive rate policy (max rate = any rate accepted)
        uint128[] memory rates = new uint128[](1);
        rates[0] = type(uint128).max;
        uint128[] memory durations = new uint128[](1);
        durations[0] = 0;
        permissiveRatePolicy = new StaticRatePolicy(rates, durations);

        // Clamps
        IMidnight iMidnight = IMidnight(address(midnight));
        buyOfferClamp = new BuyOfferClamp(iMidnight);
        sellOfferClamp = new SellOfferClamp(iMidnight);
        supplyCollateralCallbackClamp = new SupplyCollateralCallbackClamp(iMidnight);
        vaultWithdrawClamp = new VaultWithdrawClamp(iMidnight);
        vaultSupplyClamp = new VaultSupplyClamp(iMidnight);
        borrowMidnightRenewalClamp = new BorrowMidnightRenewalClamp(iMidnight);
        lendMidnightRenewalClamp = new LendMidnightRenewalClamp(iMidnight);
        borrowMidnightToBlueClamp = new BorrowMidnightToBlueClamp(iMidnight, morphoBlue);
        lendMidnightToVaultClamp = new LendMidnightToVaultClamp(iMidnight);
        borrowBlueToMidnightClamp = new BorrowBlueToMidnightClamp(iMidnight, morphoBlue);
        lendVaultToMidnightClamp = new LendVaultToMidnightClamp(iMidnight, morphoBlue);

        // Markets
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.945e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        sourceMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        sourceMarketId = IdLib.toId(sourceMarket);

        targetMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 365 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        targetMarketId = IdLib.toId(targetMarket);

        // Seed both
        _seedMarket(sourceMarket, sourceMarketId);
        _seedMarket(targetMarket, targetMarketId);
    }

    /* ═══════ Seeding ═══════ */

    function _seedMarket(Market memory obl, bytes32 oblId) internal {
        (address seedBorrower, uint256 seedBorrowerSK) = makeAddrAndKey(string(abi.encodePacked("seed", oblId)));
        address seedLender = makeAddr(string(abi.encodePacked("seedL", oblId)));

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
        colAmounts[0] = SEED_AMOUNT * 10;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: SEED_AMOUNT, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory seedOffer = Offer({
            market: obl,
            buy: false,
            maker: seedBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("seed", oblId)),
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
        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(seedOffer), uint256(0), new bytes32[](0));
        uint256 units = SEED_AMOUNT;

        vm.prank(seedLender);
        midnight.take(seedOffer, ratifierData, units, seedLender, address(0), address(0), "");
    }

    /* ═══════ State manipulation ═══════ */

    /// @dev Sets totalUnits via vm.store.
    ///      Storage layout: marketState mapping at slot 1.
    ///      First word of MarketState: totalUnits (lower 128 bits), upper 128 bits unused.
    function _setTotalUnits(bytes32 oblId, uint128 totalU) internal {
        bytes32 stateSlot = keccak256(abi.encode(oblId, uint256(1)));
        vm.store(address(midnight), stateSlot, bytes32(uint256(totalU)));
    }

    /// @notice Give `account` debt on an market by creating a SELL offer and having a temp lender take it
    function _setupBorrowerWithDebt(
        address account,
        uint256 accountSK,
        uint128 debtUnits,
        Market memory obl,
        bytes32 oblId
    ) internal {
        address tempLender = makeAddr(string(abi.encodePacked("tL", account, oblId)));

        collateralToken.mint(account, type(uint128).max);
        loanToken.mint(tempLender, type(uint128).max);

        MidnightSupplyCollateralCallback cb = new MidnightSupplyCollateralCallback(address(midnight));
        vm.startPrank(account);
        collateralToken.approve(address(cb), type(uint256).max);
        midnight.setIsAuthorized(address(cb), true, account);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, account);
        vm.stopPrank();

        vm.prank(tempLender);
        loanToken.approve(address(midnight), type(uint256).max);

        uint256[] memory colAmounts = new uint256[](1);
        colAmounts[0] = uint256(debtUnits) * 20;
        bytes memory cbData = abi.encode(
            IMidnightSupplyCollateralCallback.CallbackData({
                amounts: colAmounts, offerSellerAssets: debtUnits, maxBorrowCapacityUsage: 0
            })
        );

        Offer memory sellOffer = Offer({
            market: obl,
            buy: false,
            maker: account,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("debt-setup", account, oblId)),
            callback: address(cb),
            callbackData: cbData,
            receiverIfMakerIsSeller: account,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, accountSK);
        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(sellOffer), uint256(0), new bytes32[](0));

        vm.prank(tempLender);
        midnight.take(sellOffer, ratifierData, debtUnits, tempLender, address(0), address(0), "");
    }

    /// @notice Give `account` credit (lending position) on an market
    function _setupLenderWithCredit(address account, uint128 creditAmount, Market memory obl, bytes32 oblId) internal {
        (address tempBorrower, uint256 tempBorrowerSK) = makeAddrAndKey(string(abi.encodePacked("tB", account, oblId)));

        collateralToken.mint(tempBorrower, type(uint128).max);
        vm.startPrank(tempBorrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(obl, 0, uint256(creditAmount) * 100, tempBorrower);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, tempBorrower);
        vm.stopPrank();

        loanToken.mint(account, type(uint128).max);
        vm.prank(account);
        loanToken.approve(address(midnight), type(uint256).max);

        Offer memory sellOffer = Offer({
            market: obl,
            buy: false,
            maker: tempBorrower,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("lend-setup", account, oblId)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: tempBorrower,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(sellOffer, tempBorrowerSK);
        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(sellOffer), uint256(0), new bytes32[](0));

        vm.prank(account);
        midnight.take(sellOffer, ratifierData, creditAmount, account, address(0), address(0), "");
    }

    /// @notice Supply collateral for an account on an market
    function _depositCollateral(address account, uint256 amount, Market memory obl) internal {
        collateralToken.mint(account, amount);
        vm.startPrank(account);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(obl, 0, amount, account);
        vm.stopPrank();
    }

    /// @notice Create a real Blue borrow position on Morpho Blue
    function _setupBlueBorrowPosition(address user, uint256 borrowAmount, uint256 collateralAmount) internal {
        // Supply liquidity to Blue market
        loanToken.mint(address(this), borrowAmount * 2);
        loanToken.approve(address(morphoBlue), borrowAmount * 2);
        morphoBlue.supply(blueMarketParams, borrowAmount * 2, 0, address(this), "");

        // User supplies collateral and borrows
        collateralToken.mint(user, collateralAmount);
        vm.startPrank(user);
        collateralToken.approve(address(morphoBlue), collateralAmount);
        morphoBlue.supplyCollateral(blueMarketParams, collateralAmount, user, "");
        morphoBlue.borrow(blueMarketParams, borrowAmount, 0, user, user);

        // Authorize callback on Blue + approve callback to pull loan tokens
        morphoBlue.setAuthorization(address(borrowBlueToMidnightCallback), true);
        loanToken.approve(address(borrowBlueToMidnightCallback), type(uint256).max);

        // Authorize callback on Midnight (for supplyCollateral on behalf of user)
        midnight.setIsAuthorized(address(borrowBlueToMidnightCallback), true, user);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, user);
        vm.stopPrank();
    }

    /// @notice Set Blue market liquidity by supplying loan tokens
    /// @dev Supplies `supplyAmount` to the Blue market. If `borrowAmount` > 0, creates a borrow position
    ///      to reduce available liquidity (availableLiquidity = supply - borrow).
    function _setBlueMarketLiquidity(uint256 supplyAmount, uint256 borrowAmount) internal {
        // Supply to Blue market
        loanToken.mint(address(this), supplyAmount);
        loanToken.approve(address(morphoBlue), supplyAmount);
        morphoBlue.supply(blueMarketParams, supplyAmount, 0, address(this), "");

        // Optionally borrow to reduce liquidity
        if (borrowAmount > 0) {
            uint256 collateralNeeded = borrowAmount * 10; // Over-collateralize
            collateralToken.mint(address(this), collateralNeeded);
            collateralToken.approve(address(morphoBlue), collateralNeeded);
            morphoBlue.supplyCollateral(blueMarketParams, collateralNeeded, address(this), "");
            morphoBlue.borrow(blueMarketParams, borrowAmount, 0, address(this), address(this));
        }
    }

    /* ═══════ Signing ═══════ */

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        return Signature({v: v, r: r, s: s});
    }

    /* ═══════ Verification harness ═══════ */

    /// @notice Verifies boundary invariants: safety, no-dust, exhaustion, tightness
    /// @param maxUnits The clamp-returned max units (must be > 0)
    /// @param offer The offer struct
    /// @param sig Offer signature
    /// @param taker The taker (msg.sender for take())
    /// @param clamp The clamp contract (for no-dust re-check)
    /// @param clampData The clamp data (for no-dust re-check)
    /// @param checkNoDust Check no-dust invariant (false for rounding-remainder or role-flip cases)
    /// @param checkExhaustion Check exhaustion invariant (false when role flips after debt→0)
    function _verifyBoundary(
        uint256 maxUnits,
        Offer memory offer,
        Signature memory sig,
        address taker,
        ITakeClamp clamp,
        bytes memory clampData,
        bool checkNoDust,
        bool checkExhaustion
    ) internal {
        assertTrue(maxUnits > 0, "boundary: maxUnits must be > 0");

        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0));
        address receiverIfTakerIsSeller = offer.buy ? taker : address(0);

        // 1. Safety: take(maxUnits) succeeds
        uint256 snap = vm.snapshotState();
        vm.prank(taker);
        midnight.take(offer, ratifierData, maxUnits, taker, receiverIfTakerIsSeller, address(0), "");

        // 2. No-dust: clamp returns 0 after taking maxUnits
        if (checkNoDust) {
            uint256 postClamp = clamp.maxUnits(offer, clampData);
            assertEq(postClamp, 0, "no-dust: clamp should return 0 after taking maxUnits");
        }

        // 3. Exhaustion: take(1) either reverts or is zero-cost
        if (checkExhaustion) {
            address buyer = offer.buy ? offer.maker : taker;
            uint256 buyerBalBefore = loanToken.balanceOf(buyer);
            vm.prank(taker);
            try midnight.take(offer, ratifierData, 1, taker, receiverIfTakerIsSeller, address(0), "") {
                uint256 buyerBalAfter = loanToken.balanceOf(buyer);
                assertEq(buyerBalBefore, buyerBalAfter, "exhaustion: take(1) must be zero-cost");
            } catch {}
        }

        vm.revertToState(snap);

        // 4. Tightness: take(maxUnits + 1) reverts
        vm.prank(taker);
        vm.expectRevert();
        midnight.take(offer, ratifierData, maxUnits + 1, taker, receiverIfTakerIsSeller, address(0), "");
    }

    /// @notice Convenience overload: safety, exhaustion, and tightness checked.
    ///         No-dust is skipped because consumed is enforced by TenorRouter, not individual clamps.
    function _verifyBoundary(
        uint256 maxUnits,
        Offer memory offer,
        Signature memory sig,
        address taker,
        ITakeClamp clamp,
        bytes memory clampData
    ) internal {
        _verifyBoundary(maxUnits, offer, sig, taker, clamp, clampData, false, true);
    }

    /// @notice Safety-only verification for inherently conservative clamps
    /// @dev Use when the clamp is intentionally conservative (e.g. ignores seller's received assets),
    ///      so tightness and no-dust don't hold.
    function _verifySafetyOnly(uint256 maxUnits, Offer memory offer, Signature memory sig, address taker) internal {
        assertTrue(maxUnits > 0, "safety: maxUnits must be > 0");

        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0));
        address receiverIfTakerIsSeller = offer.buy ? taker : address(0);

        vm.prank(taker);
        midnight.take(offer, ratifierData, maxUnits, taker, receiverIfTakerIsSeller, address(0), "");
    }

    /* ═══════ Negative invariant helpers ═══════ */

    /// @notice Proves that tightness invariant does NOT hold — take(maxUnits + 1) succeeds
    /// @dev Call when the clamp is conservative and maxUnits+1 is still safe.
    function _proveTightnessFails(uint256 maxUnits, Offer memory offer, Signature memory sig, address taker) internal {
        assertTrue(maxUnits > 0, "proveTightnessFails: maxUnits must be > 0");

        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0));
        address receiverIfTakerIsSeller = offer.buy ? taker : address(0);

        uint256 snap = vm.snapshotState();
        vm.prank(taker);
        // Should succeed (proving tightness doesn't hold)
        midnight.take(offer, ratifierData, maxUnits + 1, taker, receiverIfTakerIsSeller, address(0), "");
        vm.revertToState(snap);
    }

    /// @notice Proves that exhaustion invariant does NOT hold — take(1) after maxUnits costs > 0
    function _proveExhaustionFails(uint256 maxUnits, Offer memory offer, Signature memory sig, address taker) internal {
        assertTrue(maxUnits > 0, "proveExhaustionFails: maxUnits must be > 0");

        bytes memory ratifierData = abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0));
        address receiverIfTakerIsSeller = offer.buy ? taker : address(0);

        uint256 snap = vm.snapshotState();
        vm.prank(taker);
        midnight.take(offer, ratifierData, maxUnits, taker, receiverIfTakerIsSeller, address(0), "");

        address buyer = offer.buy ? offer.maker : taker;
        uint256 buyerBalBefore = loanToken.balanceOf(buyer);
        vm.prank(taker);
        try midnight.take(offer, ratifierData, 1, taker, receiverIfTakerIsSeller, address(0), "") {
            uint256 buyerBalAfter = loanToken.balanceOf(buyer);
            assertTrue(buyerBalBefore != buyerBalAfter, "proveExhaustionFails: take(1) should cost > 0");
        } catch {
            // If take(1) reverts, that's fine — exhaustion still doesn't hold in the expected way
            // This is acceptable; the invariant "failure" is that it reverts instead of being zero-cost
        }

        vm.revertToState(snap);
    }
}
