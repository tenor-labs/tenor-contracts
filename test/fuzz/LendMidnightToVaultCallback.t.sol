// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LendMidnightToVaultCallback} from "../../src/callbacks/LendMidnightToVaultCallback.sol";
import {ILendMidnightToVaultCallback} from "@callbacks/interfaces/ILendMidnightToVaultCallback.sol";
import {IMidnight, Market, CollateralParams, Offer} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {MockERC4626} from "../helpers/mocks/MockERC4626.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib, MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";

/// @title LendMidnightToVaultCallbackFuzzTest
/// @notice Fuzz tests for LendMidnightToVaultCallback to verify invariants hold across wide range of inputs
contract LendMidnightToVaultCallbackFuzzTest is Test {
    LendMidnightToVaultCallback internal callback;
    IMidnight internal midnight;
    EcrecoverRatifier internal ecrecoverRatifier;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC4626 internal vault;
    Oracle internal oracle;

    uint256 internal lenderSK;
    address internal lender;
    uint256 internal borrowerSK;
    address internal borrower;
    address internal feeRecipient;

    Market internal sourceMarket;

    function setUp() public {
        // Create test accounts
        (lender, lenderSK) = makeAddrAndKey("lender");
        (borrower, borrowerSK) = makeAddrAndKey("borrower");
        feeRecipient = makeAddr("feeRecipient");

        // Deploy tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral", "COL", 18);

        // Deploy oracle
        oracle = new Oracle();
        oracle.setPrice(10e36); // 10:1 price

        // Deploy Midnight
        midnight = IMidnight(deployCode("Midnight.sol:Midnight"));
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        IMidnight(address(midnight)).setIsAuthorized(address(ecrecoverRatifier), true, lender);
        vm.prank(borrower);
        IMidnight(address(midnight)).setIsAuthorized(address(ecrecoverRatifier), true, borrower);

        // Deploy callback and vault
        callback = new LendMidnightToVaultCallback(address(midnight));
        vault = new MockERC4626(address(loanToken), "Vault", "vLOAN");

        // Setup collaterals for market
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
            maturity: block.timestamp + 7 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Set up tokens and approvals
        loanToken.mint(lender, type(uint128).max);
        loanToken.mint(borrower, type(uint128).max);
        collateralToken.mint(borrower, type(uint128).max);

        vm.startPrank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        // Authorize callback to act on lender's behalf
        IMidnight(address(midnight)).setIsAuthorized(address(callback), true, lender);
        vm.stopPrank();

        vm.startPrank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);
        collateralToken.approve(address(midnight), type(uint256).max);
        vm.stopPrank();
    }

    /* ========== HELPERS ========== */

    function _setupLendPosition(uint256 lendAmount) internal {
        // Borrower supplies collateral
        vm.prank(borrower);
        midnight.supplyCollateral(sourceMarket, 0, lendAmount * 2, borrower);

        // Lender creates BUY offer (to lend), borrower takes it
        Offer memory buyOffer = Offer({
            market: sourceMarket,
            buy: true,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: MAX_TICK,
            group: keccak256(abi.encodePacked("setup", block.timestamp, gasleft())),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(buyOffer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(buyOffer);

        bytes32 _id = IdLib.toId(buyOffer.market);
        uint256 _shares = lendAmount;
        vm.prank(borrower);
        midnight.take(
            buyOffer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            borrower,
            address(0),
            ""
        );
    }

    function _signOffer(Offer memory offer, uint256 privateKey) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));

        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(privateKey, digest);
        return signature;
    }

    /* ========== FUZZ TESTS ========== */

    /// @notice Fuzz test: Fee calculation remains consistent across various amounts and fee rates
    function testFuzz_feeCalculation(uint256 lendAmount, uint256 feeRate, uint256 price) public {
        // Bound inputs to reasonable ranges
        lendAmount = bound(lendAmount, 1e18, 1000e18);
        feeRate = bound(feeRate, 0, 0.01e18); // 0% to 1%
        price = bound(price, 0.8e18, 1e18); // 80% to 100% (discount prices only)

        // Setup position
        _setupLendPosition(lendAmount);

        bytes32 marketId = IdLib.toId(sourceMarket);
        uint256 lenderSharesBefore = creditAfterSlashing(midnight, marketId, lender);
        vm.assume(lenderSharesBefore > 0);

        // Create lend exit offer
        bytes memory callbackData = abi.encode(
            ILendMidnightToVaultCallback.CallbackData({
                vault: address(vault), feeRate: feeRate, feeRecipient: feeRecipient
            })
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        uint256 tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: tick,
            group: keccak256(abi.encodePacked("exit", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, lenderSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = lendAmount;
        vm.prank(borrower);
        (uint256 buyerAssets, uint256 sellerAssets) = midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            address(0),
            address(0),
            ""
        );

        // Verify fee invariant: fee = sellerAssets * feeRate / WAD
        uint256 actualFee = loanToken.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        uint256 vaultDeposit = loanToken.balanceOf(address(vault)) - vaultBalanceBefore;

        if (feeRate > 0) {
            uint256 expectedFee = (sellerAssets * feeRate) / WAD;
            assertEq(actualFee, expectedFee, "Fee calculation invariant violated");
        } else {
            assertEq(actualFee, 0, "Fee should be zero when feeRate=0");
        }

        // Invariant: fee + vaultDeposit == sellerAssets
        assertEq(actualFee + vaultDeposit, sellerAssets, "Fee + deposit should equal sellerAssets");
    }

    /// @notice Fuzz test: Deposit amount plus fee equals seller assets
    function testFuzz_depositPlusFeeEqualsSellerAssets(uint256 lendAmount, uint256 feeRate) public {
        // Bound inputs
        lendAmount = bound(lendAmount, 1e18, 1000e18);
        feeRate = bound(feeRate, 0, 0.01e18);

        // Setup position
        _setupLendPosition(lendAmount);

        bytes32 marketId = IdLib.toId(sourceMarket);
        vm.assume(creditAfterSlashing(midnight, marketId, lender) > 0);

        bytes memory callbackData = abi.encode(
            ILendMidnightToVaultCallback.CallbackData({
                vault: address(vault), feeRate: feeRate, feeRecipient: feeRecipient
            })
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);
        uint256 vaultBalanceBefore = loanToken.balanceOf(address(vault));

        uint256 tick = TickLib.priceToTick(0.95e18, DEFAULT_TICK_SPACING);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: tick,
            group: keccak256(abi.encodePacked("deposit_test", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, lenderSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = lendAmount;
        vm.prank(borrower);
        (, uint256 sellerAssets) = midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            address(0),
            address(0),
            ""
        );

        uint256 actualFee = loanToken.balanceOf(feeRecipient) - feeRecipientBalanceBefore;
        uint256 vaultDeposit = loanToken.balanceOf(address(vault)) - vaultBalanceBefore;

        // Core invariant: fee + deposit == sellerAssets
        assertEq(actualFee + vaultDeposit, sellerAssets, "Invariant: fee + deposit == sellerAssets");
    }

    /// @notice Fuzz test: Lender receives correct vault shares
    function testFuzz_vaultSharesReceived(uint256 lendAmount, uint256 exchangeRate) public {
        // Bound inputs
        lendAmount = bound(lendAmount, 1e18, 1000e18);
        exchangeRate = bound(exchangeRate, 1e18, 2e18); // 1x to 2x (simulating yield)

        // Set vault exchange rate
        vault.setExchangeRate(exchangeRate);

        // Setup position
        _setupLendPosition(lendAmount);

        bytes32 marketId = IdLib.toId(sourceMarket);
        vm.assume(creditAfterSlashing(midnight, marketId, lender) > 0);

        uint256 lenderVaultSharesBefore = vault.balanceOf(lender);

        bytes memory callbackData = abi.encode(
            ILendMidnightToVaultCallback.CallbackData({
                vault: address(vault),
                feeRate: 0, // No fee for simplicity
                feeRecipient: address(0)
            })
        );

        uint256 tick = TickLib.priceToTick(0.98e18, DEFAULT_TICK_SPACING);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: tick,
            group: keccak256(abi.encodePacked("shares_test", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, lenderSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = lendAmount;
        vm.prank(borrower);
        (, uint256 sellerAssets) = midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            address(0),
            address(0),
            ""
        );

        uint256 lenderVaultSharesAfter = vault.balanceOf(lender);
        uint256 sharesReceived = lenderVaultSharesAfter - lenderVaultSharesBefore;

        // Verify shares calculation: shares = assets * 1e18 / exchangeRate
        uint256 expectedShares = (sellerAssets * 1e18) / exchangeRate;
        assertEq(sharesReceived, expectedShares, "Vault shares calculation invariant violated");
    }

    /// @notice Fuzz test: Fee always rounds down
    function testFuzz_feeRoundsDown(uint256 lendAmount, uint256 feeRate, uint256 price) public {
        // Use values that create non-divisible results
        lendAmount = bound(lendAmount, 1e18, 1000e18);
        feeRate = bound(feeRate, 1, 0.01e18); // At least some fee
        price = bound(price, 0.85e18, 0.99e18); // Price with discount

        // Setup position
        _setupLendPosition(lendAmount);

        bytes32 marketId = IdLib.toId(sourceMarket);
        vm.assume(creditAfterSlashing(midnight, marketId, lender) > 0);

        bytes memory callbackData = abi.encode(
            ILendMidnightToVaultCallback.CallbackData({
                vault: address(vault), feeRate: feeRate, feeRecipient: feeRecipient
            })
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        uint256 tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: tick,
            group: keccak256(abi.encodePacked("round_test", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, lenderSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = lendAmount;
        vm.prank(borrower);
        (, uint256 sellerAssets) = midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            address(0),
            address(0),
            ""
        );

        uint256 actualFee = loanToken.balanceOf(feeRecipient) - feeRecipientBalanceBefore;

        // Calculate expected fee with mulDivDown (rounds down): fee = sellerAssets * feeRate / WAD
        uint256 expectedFee = (sellerAssets * feeRate) / WAD;
        assertEq(actualFee, expectedFee, "Fee should be calculated with mulDivDown");

        // Verify rounding down: fee * WAD <= sellerAssets * feeRate
        assertTrue(actualFee * WAD <= sellerAssets * feeRate, "Fee should round down");
    }

    /// @notice Unit test: With 0.01e18 (1%) fee rate, fee never exceeds assets even at discounted prices
    /// @dev Verifies that with 1% fee rate, the fee never exceeds assets even at discounted prices
    function test_discountedPriceSucceedsWithLowFeeRate() public {
        uint256 lendAmount = 100e18;

        // Setup position
        _setupLendPosition(lendAmount);

        // Use a discounted price with 1% fee rate
        // With 1% fee rate, even extreme discounts won't cause fee to exceed assets
        uint256 price = 0.8e18;
        uint256 feeRate = 0.01e18;

        bytes memory callbackData = abi.encode(
            ILendMidnightToVaultCallback.CallbackData({
                vault: address(vault), feeRate: feeRate, feeRecipient: feeRecipient
            })
        );

        uint256 tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: tick,
            group: keccak256(abi.encodePacked("discount_test", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, lenderSK);

        // With fee rate of 1%, this should succeed
        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = lendAmount;
        vm.prank(borrower);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            address(0),
            address(0),
            ""
        );

        // Verify fee was collected and is non-zero (there is interest at discounted price)
        uint256 feeCollected = loanToken.balanceOf(feeRecipient);
        assertTrue(feeCollected > 0, "Fee should be collected for discounted sale");
        assertTrue(feeCollected < lendAmount, "Fee should be much less than principal with 1% rate");
    }

    /// @notice Unit test: Zero fee rate means no fee charged
    function testFuzz_zeroFeeRateNoFee(uint256 lendAmount, uint256 price) public {
        lendAmount = bound(lendAmount, 1e18, 1000e18);
        price = bound(price, 0.8e18, 1e18);

        // Setup position
        _setupLendPosition(lendAmount);

        bytes32 marketId = IdLib.toId(sourceMarket);
        vm.assume(creditAfterSlashing(midnight, marketId, lender) > 0);

        bytes memory callbackData = abi.encode(
            ILendMidnightToVaultCallback.CallbackData({
                vault: address(vault),
                feeRate: 0, // Zero fee rate
                feeRecipient: address(0)
            })
        );

        uint256 feeRecipientBalanceBefore = loanToken.balanceOf(feeRecipient);

        uint256 tick = TickLib.priceToTick(price, DEFAULT_TICK_SPACING);

        Offer memory offer = Offer({
            market: sourceMarket,
            buy: false,
            maker: lender,
            start: block.timestamp,
            expiry: block.timestamp + 200,
            tick: tick,
            group: keccak256(abi.encodePacked("zero_fee_test", block.timestamp, gasleft())),
            callback: address(callback),
            callbackData: callbackData,
            receiverIfMakerIsSeller: address(callback),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        bytes32 offerRoot = HashLib.hashOffer(offer);
        Signature memory sig = _signOffer(offer, lenderSK);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = lendAmount;
        vm.prank(borrower);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            address(0),
            address(0),
            ""
        );

        uint256 feeRecipientBalanceAfter = loanToken.balanceOf(feeRecipient);
        assertEq(feeRecipientBalanceAfter, feeRecipientBalanceBefore, "No fee should be charged with feeRate=0");
    }
}
