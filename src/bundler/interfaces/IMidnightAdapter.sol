// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IMidnight, Market} from "@midnight/interfaces/IMidnight.sol";
import {IFlashLoanCallback} from "@midnight/interfaces/ICallbacks.sol";

interface IMidnightAdapter is IFlashLoanCallback {
    error InconsistentInput();

    function MORPHO_MIDNIGHT() external view returns (IMidnight);

    /// @notice Repays debt on Morpho Midnight on behalf of the initiator.
    /// @dev Strictly uses tokens already on the adapter; does not pull from initiator.
    /// @dev `assets` and `debt` are mutually exclusive: passing both non-zero reverts `InconsistentInput`. If the
    ///      resolved repay amount is zero (e.g. a max sentinel on a zero-balance adapter or a zero-debt position),
    ///      the call returns silently rather than reverting, so a best-effort residual or sweep repay can sit
    ///      unconditionally in a bundle even when an earlier leg already cleared the debt.
    /// @param market The market to repay.
    /// @param assets The amount of assets to repay. Pass `type(uint256).max` to use the adapter's full balance
    ///        (requires `callbackAddr == address(0)`, reverts `InconsistentInput` otherwise).
    /// @param debt The amount to repay. Pass `type(uint256).max` to repay the initiator's entire debt.
    /// @param callbackAddr The `Midnight.repay` callback target, forwarded as-is. Pass `address(0)` for no callback.
    ///      `MidnightAdapterBase` does not implement an `onRepay` handler.
    /// @param callbackData Arbitrary data forwarded to `callbackAddr.onRepay`. Unused when `callbackAddr ==
    /// address(0)`.
    function midnightRepay(
        Market calldata market,
        uint256 assets,
        uint256 debt,
        address callbackAddr,
        bytes calldata callbackData
    ) external;

    /// @notice Supplies collateral to Morpho Midnight on behalf of the initiator.
    /// @dev Strictly uses tokens already on the adapter; does not pull from initiator.
    /// @param market The market to supply collateral to.
    /// @param collateralIndex The index of the collateral in `market.collateralParams`.
    /// @param assets The amount of collateral to supply. Pass `type(uint256).max` to use the adapter's full balance.
    function midnightSupplyCollateral(Market calldata market, uint256 collateralIndex, uint256 assets) external;

    /// @notice Withdraws collateral from Morpho Midnight on behalf of the initiator.
    /// @param market The market to withdraw collateral from.
    /// @param collateralIndex The index of the collateral in `market.collateralParams`.
    /// @param assets The amount of collateral to withdraw. Pass `type(uint256).max` to withdraw the initiator's full
    ///        collateral balance.
    /// @param receiver The account receiving the withdrawn collateral.
    function midnightWithdrawCollateral(
        Market calldata market,
        uint256 collateralIndex,
        uint256 assets,
        address receiver
    ) external;

    /// @notice Withdraws from a market on Morpho Midnight on behalf of the initiator.
    /// @dev Does not cap on available liquidity. Reverts if the market's `withdrawable` liquidity is insufficient.
    /// @param market The market to withdraw from.
    /// @param units The amount of market units to withdraw. Pass `type(uint256).max` to withdraw all the
    ///        initiator's credit after position update (slashing + fee accrual).
    /// @param receiver The account receiving the withdrawn assets.
    function midnightWithdraw(Market calldata market, uint256 units, address receiver) external;

    /// @notice Sets the consumed amount for an offer group on Morpho Midnight on behalf of the initiator.
    /// @dev Used for atomic cancel operations (cancel + withdraw, cancel + disable auto-renewal). Passing
    ///      `type(uint128).max` cancels all offers in the group.
    /// @param group The offer group to set consumed amount for.
    /// @param amount The new consumed amount; must be >= current consumed amount.
    function midnightSetConsumed(bytes32 group, uint128 amount) external;

    /// @notice Triggers a flash loan on Morpho Midnight.
    /// @dev The flash-loaned tokens land on this adapter; the reenter actions in `data` must consume (and repay)
    ///      them within the loan, as any balance left on the adapter is skimmable by a later bundle.
    /// @param tokens The addresses of the tokens to flash loan.
    /// @param assets The amounts of assets to flash loan, paired with `tokens` by index.
    /// @param data Arbitrary data forwarded to `onFlashLoan` (bundler3 reenter payload).
    function midnightFlashLoan(address[] calldata tokens, uint256[] calldata assets, bytes calldata data) external;
}
