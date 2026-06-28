// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LendVaultToMidnightCallback} from "../../src/callbacks/LendVaultToMidnightCallback.sol";
import {ILendVaultToMidnightCallback} from "@callbacks/interfaces/ILendVaultToMidnightCallback.sol";
import {CallbackLib} from "../../src/libraries/CallbackLib.sol";
import {Market, CollateralParams, Offer, IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {Signature, EIP712_DOMAIN_TYPEHASH} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {UtilsLib} from "@midnight/libraries/UtilsLib.sol";
import {HashLib} from "@midnight/ratifiers/libraries/HashLib.sol";
import {Midnight} from "@midnight/Midnight.sol";
import {enableDefaultLltvs} from "../helpers/LltvHelper.sol";
import {EcrecoverRatifier} from "@midnight/ratifiers/EcrecoverRatifier.sol";
import {MockERC20} from "../helpers/mocks/MockERC20.sol";
import {MockERC4626} from "../helpers/mocks/MockERC4626.sol";
import {Oracle} from "../helpers/Oracle.sol";
import {WAD, DEFAULT_TICK_SPACING} from "@midnight/libraries/ConstantsLib.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {TickLib} from "@midnight/libraries/TickLib.sol";
import {TakeAmountsLib} from "@midnight/periphery/TakeAmountsLib.sol";
import {LIQUIDATION_CURSOR} from "../helpers/MaxLifLib.sol";
import {creditAfterSlashing} from "../helpers/CreditHelper.sol";

contract LendVaultToMidnightCallbackTest is Test {
    LendVaultToMidnightCallback internal callback;
    Midnight internal midnight;
    MockERC20 internal loanToken;
    MockERC20 internal collateralToken;
    MockERC4626 internal vault;
    Oracle internal oracle;

    address internal lender;
    uint256 internal lenderSK;
    address internal borrower;
    address internal feeRecipient;
    EcrecoverRatifier internal ecrecoverRatifier;

    Market internal market;

    uint256 constant PRICE = 0.95e18; // 5% discount

    function setUp() public virtual {
        (lender, lenderSK) = makeAddrAndKey("Lender");
        borrower = makeAddr("Borrower");
        feeRecipient = makeAddr("FeeRecipient");

        // Deploy tokens
        loanToken = new MockERC20("Loan Token", "LOAN", 18);
        collateralToken = new MockERC20("Collateral Token", "COL", 18);

        // Deploy oracle (1:1)
        oracle = new Oracle();
        oracle.setPrice(1e36);

        // Deploy real Midnight
        midnight = new Midnight();
        enableDefaultLltvs(midnight);
        midnight.setFeeClaimer(address(this));
        ecrecoverRatifier = new EcrecoverRatifier(address(midnight));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ecrecoverRatifier), true, lender);

        // Deploy vault backed by loanToken
        vault = new MockERC4626(address(loanToken), "Test Vault", "vTEST");

        // Deploy callback
        callback = new LendVaultToMidnightCallback(address(midnight));

        // Setup market
        CollateralParams[] memory collaterals = new CollateralParams[](1);
        collaterals[0] = CollateralParams({
            token: address(collateralToken),
            lltv: 0.77e18,
            liquidationCursor: LIQUIDATION_CURSOR,
            oracle: address(oracle)
        });

        market = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(loanToken),
            collateralParams: collaterals,
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });

        // Fund lender and deposit into vault
        loanToken.mint(lender, 100_000e18);
        vm.startPrank(lender);
        loanToken.approve(address(vault), type(uint256).max);
        loanToken.approve(address(midnight), type(uint256).max);
        vault.deposit(50_000e18, lender);
        vault.approve(address(callback), type(uint256).max); // callback burns lender vault shares
        vm.stopPrank();

        // Fund borrower with collateral + loan tokens
        collateralToken.mint(borrower, 100_000e18);
        loanToken.mint(borrower, 100_000e18);
        vm.startPrank(borrower);
        collateralToken.approve(address(midnight), type(uint256).max);
        loanToken.approve(address(midnight), type(uint256).max);
        // Borrower supplies collateral so they can take the lender's BUY offer
        midnight.supplyCollateral(market, 0, 50_000e18, borrower);
        vm.stopPrank();
    }

    /* ========== HELPERS ========== */

    function _signOffer(Offer memory offer, uint256 sk) internal view returns (Signature memory) {
        bytes32 root = HashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(HashLib.offerTreeTypeHash(0), root));
        bytes32 domainSep = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, address(ecrecoverRatifier)));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", domainSep, structHash));
        Signature memory signature;
        (signature.v, signature.r, signature.s) = vm.sign(sk, digest);
        return signature;
    }

    function _buildBuyOffer(uint256 feeRate, address _feeRecipient) internal view returns (Offer memory) {
        uint256 tick = TickLib.priceToTick(PRICE, DEFAULT_TICK_SPACING);
        ILendVaultToMidnightCallback.CallbackData memory cbData = ILendVaultToMidnightCallback.CallbackData({
            vault: address(vault),
            feeRate: feeRate,
            feeRecipient: _feeRecipient,
            tick: tick,
            morphoBlueMarketId: bytes32(0)
        });

        return Offer({
            buy: true,
            maker: lender,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256(abi.encodePacked(block.timestamp, feeRate, gasleft())),
            callback: address(callback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    /// @dev Take a BUY offer for a given buyerAssets amount; returns actual values from take()
    function _takeBuyOffer(uint256 buyerAssets, uint256 feeRate, address _feeRecipient)
        internal
        returns (uint256 retBuyerAssets, uint256 retSellerAssets, uint256 retUnits)
    {
        Offer memory offer = _buildBuyOffer(feeRate, _feeRecipient);
        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, buyerAssets);

        vm.prank(borrower);
        (retBuyerAssets, retSellerAssets) = midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            offer.maker,
            address(0),
            ""
        );
    }

    /* ========== GUARD TESTS ========== */

    function test_onBuy_revertsIfNotMidnight() public {
        ILendVaultToMidnightCallback.CallbackData memory cbData = ILendVaultToMidnightCallback.CallbackData({
            vault: address(vault),
            feeRate: 0,
            feeRecipient: address(0),
            tick: TickLib.priceToTick(PRICE, DEFAULT_TICK_SPACING),
            morphoBlueMarketId: bytes32(0)
        });

        vm.expectRevert(CallbackLib.OnlyMidnight.selector);
        callback.onBuy(bytes32(0), market, 100e18, 105e18, 0, lender, abi.encode(cbData));
    }

    function test_onBuy_revertsZeroAmount() public {
        Offer memory offer = _buildBuyOffer(0, address(0));
        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);

        // Taking 0 units triggers the ZeroAmount guard
        vm.prank(borrower);
        vm.expectRevert(CallbackLib.ZeroAmount.selector);
        midnight.take(
            offer, abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)), 0, borrower, offer.maker, address(0), ""
        );
    }

    function test_onBuy_revertsTokenMismatch() public {
        // Create vault with a different underlying asset
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);
        MockERC4626 wrongVault = new MockERC4626(address(wrongToken), "Wrong Vault", "wVAULT");

        uint256 tick = TickLib.priceToTick(PRICE, DEFAULT_TICK_SPACING);
        ILendVaultToMidnightCallback.CallbackData memory cbData = ILendVaultToMidnightCallback.CallbackData({
            vault: address(wrongVault), feeRate: 0, feeRecipient: address(0), tick: tick, morphoBlueMarketId: bytes32(0)
        });

        Offer memory offer = Offer({
            buy: true,
            maker: lender,
            market: market,
            start: block.timestamp,
            expiry: block.timestamp + 1 hours,
            tick: tick,
            group: keccak256(abi.encodePacked("mismatch", block.timestamp)),
            callback: address(callback),
            callbackData: abi.encode(cbData),
            receiverIfMakerIsSeller: address(0),
            ratifier: address(ecrecoverRatifier),
            reduceOnly: false,
            maxUnits: type(uint128).max,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });

        Signature memory sig = _signOffer(offer, lenderSK);
        bytes32 offerRoot = HashLib.hashOffer(offer);

        bytes32 _id = IdLib.toId(offer.market);
        uint256 _shares = TakeAmountsLib.buyerAssetsToUnits(address(midnight), _id, offer, 1000e18);

        vm.prank(borrower);
        vm.expectRevert(CallbackLib.TokenMismatch.selector);
        midnight.take(
            offer,
            abi.encode(sig, offerRoot, uint256(0), new bytes32[](0)),
            _shares,
            borrower,
            offer.maker,
            address(0),
            ""
        );
    }

    /* ========== HAPPY PATH TESTS ========== */

    function test_onBuy_happyPath_withFee() public {
        uint256 buyerAmount = 1000e18;
        uint256 feeRate = 0.5e18; // 50% of interest

        bytes32 marketId = IdLib.toId(market);

        // Record state before
        uint256 lenderSharesBefore = vault.balanceOf(lender);
        uint256 vaultAssetsBefore = loanToken.balanceOf(address(vault));
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        // Execute
        (uint256 retBuyerAssets,,) = _takeBuyOffer(buyerAmount, feeRate, feeRecipient);

        // Record state after
        uint256 lenderSharesAfter = vault.balanceOf(lender);
        uint256 vaultAssetsAfter = loanToken.balanceOf(address(vault));

        // 1. Vault shares burned
        assertLt(lenderSharesAfter, lenderSharesBefore, "Vault shares should decrease");

        // 2. Fee paid to recipient
        uint256 feeReceived = loanToken.balanceOf(feeRecipient) - feeRecipientBefore;
        assertGt(feeReceived, 0, "Fee recipient should receive fee");

        // 3. Vault had assets withdrawn (buyerAssets + fee)
        uint256 withdrawn = vaultAssetsBefore - vaultAssetsAfter;
        assertEq(withdrawn, retBuyerAssets + feeReceived, "Vault withdrawal should equal buyerAssets + fee");

        // 4. Borrower has debt
        uint256 borrowerDebt = midnight.debt(marketId, borrower);
        assertGt(borrowerDebt, 0, "Borrower should have debt");

        // 5. Lender has credit (market shares)
        uint256 lenderCredit = creditAfterSlashing(midnight, marketId, lender);
        assertGt(lenderCredit, 0, "Lender should have market shares");

        // CB-DUST-1: callback balance == 0
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1: no loan tokens stranded in callback");
    }

    function test_onBuy_happyPath_zeroFee() public {
        uint256 buyerAmount = 1000e18;

        bytes32 marketId = IdLib.toId(market);

        // Record state before
        uint256 lenderSharesBefore = vault.balanceOf(lender);
        uint256 vaultAssetsBefore = loanToken.balanceOf(address(vault));
        uint256 feeRecipientBefore = loanToken.balanceOf(feeRecipient);

        // Execute with zero fee
        (uint256 retBuyerAssets,,) = _takeBuyOffer(buyerAmount, 0, address(0));

        // Record state after
        uint256 lenderSharesAfter = vault.balanceOf(lender);
        uint256 vaultAssetsAfter = loanToken.balanceOf(address(vault));

        // Vault shares burned
        assertLt(lenderSharesAfter, lenderSharesBefore, "Vault shares should decrease");

        // Vault had exactly buyerAssets withdrawn (no fee)
        uint256 withdrawn = vaultAssetsBefore - vaultAssetsAfter;
        assertEq(withdrawn, retBuyerAssets, "Vault withdrawal should equal exactly buyerAssets with zero fee");

        // No fee paid
        assertEq(loanToken.balanceOf(feeRecipient), feeRecipientBefore, "Fee recipient should receive nothing");

        // Lender has credit
        uint256 lenderCredit = creditAfterSlashing(midnight, marketId, lender);
        assertGt(lenderCredit, 0, "Lender should have market shares");

        // CB-DUST-1: callback balance == 0
        assertEq(loanToken.balanceOf(address(callback)), 0, "CB-DUST-1: no loan tokens stranded in callback");
    }

    function test_onBuy_emitsVaultWithdrawnEvent() public {
        uint256 buyerAmount = 1000e18;
        bytes32 marketId = IdLib.toId(market);

        // Expect VaultWithdrawn event (check indexed topics, skip exact data values)
        vm.expectEmit(true, true, true, false, address(callback));
        emit ILendVaultToMidnightCallback.VaultWithdrawn(lender, marketId, address(vault), 0, 0, 0);

        _takeBuyOffer(buyerAmount, 0, address(0));
    }
}
