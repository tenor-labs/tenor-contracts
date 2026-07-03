// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TenorAdapter} from "../../src/bundler/TenorAdapter.sol";
import {ExecuteParams, FillAxis, Action, MidnightTakeData} from "../../src/router/TenorRouter.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {Fixtures} from "../helpers/Fixtures.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";

/// @title FlashLoanReenterExecuteTest
/// @notice TRST-M-05 regression: a bundle that flash-loans a token via `midnightFlashLoan`, reenters
///         Bundler3 from `onFlashLoan`, and runs a same-token `routerIsPayer` take through `execute`
///         must not clear the loanToken -> Midnight allowance the in-flight flash loan still needs
///         for its final repayment pull.
contract FlashLoanReenterExecuteTest is Fixtures {
    TenorAdapter internal adapter;
    Midnight internal midnight;
    IBundler3 internal bundler3;

    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;

    address internal taker;
    address internal maker;
    uint256 internal makerSK;

    EcrecoverRatifier internal ecrecoverRatifier;
    Market internal market;
    bytes32 internal marketId;

    uint256 internal constant TAKE_UNITS = 50e18;
    uint256 internal constant FLASH_AMOUNT = 25e18;
    uint256 internal constant ADAPTER_FUNDS = 100e18;

    function setUp() public {
        taker = makeAddr("Taker");
        (maker, makerSK) = makeAddrAndKey("Maker");

        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);

        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(maker);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, maker);

        bundler3 = deployBundler3();
        adapter = new TenorAdapter(address(bundler3), address(midnight), makeAddr("Ratifier"));

        vm.prank(taker);
        midnight.setIsAuthorized(address(adapter), true, taker);

        Oracle oracle = new Oracle();
        oracle.setPrice(10e36);

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
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        marketId = IdLib.toId(market);

        // Maker is the seller/borrower on the SELL offer: needs collateral to pass the health check.
        collateralToken.mint(maker, 10_000e18);
        vm.startPrank(maker);
        collateralToken.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, 10_000e18, maker);
        vm.stopPrank();

        // The routerIsPayer take pulls buyerAssets from the adapter; fund it independently of the
        // flash loan so the flash-loaned amount is intact for Midnight's repayment pull.
        loanToken.mint(address(adapter), ADAPTER_FUNDS);

        // Midnight needs liquidity to lend out in the flash loan.
        loanToken.mint(address(midnight), FLASH_AMOUNT);
    }

    function _sign(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 offerHash = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), offerHash));
        bytes32 domainSeparator =
            keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        return Signature({v: v, r: r, s: s});
    }

    /// @dev SELL offer (maker = seller/borrower) with no takerCallback: the taker is the buyer and
    ///      Midnight resolves the payer to the router, i.e. the `routerIsPayer` branch.
    function _routerIsPayerTakeAction(uint256 takeUnits) internal view returns (Action memory) {
        Offer memory offer = Offer({
            market: market,
            buy: false,
            maker: maker,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: TickLib.priceToTick(0.99e18, DEFAULT_TICK_SPACING),
            group: keccak256("sell-offer"),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: maker,
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _sign(offer, makerSK);
        MidnightTakeData memory take = MidnightTakeData({
            takeUnits: takeUnits,
            takerCallback: address(0),
            takerCallbackData: "",
            receiverIfTakerIsSeller: address(0),
            ratifierData: abi.encode(sig, HashLib.hashOffer(offer), uint256(0), new bytes32[](0))
        });

        return Action({
            take: take,
            allowRevert: false,
            offer: offer,
            clamp: address(0),
            clampData: "",
            feeAdjuster: address(0),
            feeAdjusterData: ""
        });
    }

    /// @dev Builds the outer bundle: `midnightFlashLoan(loanToken, FLASH_AMOUNT, reenterData)` where
    ///      the reentered bundle runs a same-token `routerIsPayer` take through `execute`.
    function _flashLoanReenterBundle() internal view returns (Call[] memory calls) {
        Action[] memory actions = new Action[](1);
        actions[0] = _routerIsPayerTakeAction(TAKE_UNITS);

        ExecuteParams memory params = ExecuteParams({
            deadline: 0,
            fillAxis: FillAxis.UNITS,
            maxFill: TAKE_UNITS,
            minFill: TAKE_UNITS,
            minPrice: 0,
            maxPrice: type(uint256).max,
            maxContinuousFee: type(uint256).max,
            reduceOnly: false
        });

        Call[] memory innerCalls = new Call[](1);
        innerCalls[0] = _call(address(adapter), abi.encodeCall(adapter.execute, (params, actions)));

        address[] memory tokens = new address[](1);
        tokens[0] = address(loanToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = FLASH_AMOUNT;

        bytes memory reenterData = abi.encode(innerCalls);

        calls = new Call[](1);
        calls[0] = Call({
            to: address(adapter),
            data: abi.encodeCall(adapter.midnightFlashLoan, (tokens, amounts, reenterData)),
            value: 0,
            skipRevert: false,
            callbackHash: keccak256(reenterData)
        });
    }

    /// @notice TRST-M-05: the nested take must not reset the allowance the outer flash loan relies
    ///         on for its post-callback repayment pull.
    function test_flashLoan_reenter_routerIsPayerTake_succeeds() public {
        uint256 midnightBalanceBefore = loanToken.balanceOf(address(midnight));

        vm.prank(taker);
        bundler3.multicall(_flashLoanReenterBundle());

        // Nested take filled: the taker (initiator) bought TAKE_UNITS of credit.
        assertEq(midnight.credit(marketId, taker), TAKE_UNITS, "taker credit from nested take");

        // Flash loan repaid in full and take settled: Midnight's balance moves exactly by what the
        // adapter paid in (buyerAssets) minus what it paid out to the maker (sellerAssets).
        uint256 adapterSpent = ADAPTER_FUNDS - loanToken.balanceOf(address(adapter));
        uint256 makerReceived = loanToken.balanceOf(maker);
        assertGt(adapterSpent, 0, "adapter paid buyerAssets for the take");
        assertEq(
            loanToken.balanceOf(address(midnight)),
            midnightBalanceBefore + adapterSpent - makerReceived,
            "flash loan repaid in full"
        );

        // The shared allowance survives for any outer in-flight pull.
        assertEq(
            loanToken.allowance(address(adapter), address(midnight)),
            type(uint256).max,
            "allowance not cleared by nested take"
        );
    }
}
