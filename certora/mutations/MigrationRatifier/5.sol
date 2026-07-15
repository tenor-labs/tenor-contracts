/* ── MUTATION MigrationRatifier #5 ──────────────────────────────
 * @desc:   ratifierData market-match guard flipped != to == : accepts a source-market mismatch
 * @rules:  ratifierDataMustMatchCallbackMarkets
 * @conf:   certora/confs/ratifier/revert.conf
 * @status: killed
 * @target: src/ratifiers/MigrationRatifier.sol
 * Was:     if (callbackSourceMarketId != sourceTenorMarketId || callbackTargetMarketId != targetTenorMarketId) {
 * Now:     if (callbackSourceMarketId == sourceTenorMarketId || callbackTargetMarketId != targetTenorMarketId) {
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {Offer} from "@midnight/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "@midnight/libraries/ConstantsLib.sol";
import {BaseMigrationRatifier} from "./BaseMigrationRatifier.sol";
import {IMigrationRatifier} from "./interfaces/IMigrationRatifier.sol";

/// @title MigrationRatifier
/// @notice Migration ratifier with per-user params stored on this contract, keyed by
/// `(callback, sourceTenorMarketId, targetTenorMarketId)`.
/// @dev Midnight calls `isRatified` when this contract is the offer's `ratifier` and the maker has authorized it on
/// Midnight. The ratification flow is implemented in `BaseMigrationRatifier._ratify`.
/// @dev The offer's `ratifierData` must be `abi.encode(bytes32 sourceTenorMarketId, bytes32 targetTenorMarketId)`.
/// @dev A Tenor market ID excludes maturity, per TenorMarketIdLib, so the params key is maturity-agnostic: one
/// `setParams` applies across every maturity of that market.
/// @dev `setParams`/`clearParams` use the Midnight contract as authorization authority: the caller must be `onBehalf`
/// or authorized by it on Midnight.
///
/// STANDING CONSENT
/// @dev Params are never consumed, have no amount cap or nonce, and opposite-direction params can be live at once,
/// so a keeper can repeatedly migrate the user's entire position in either direction while set.
/// @dev Params set by a Midnight-authorized delegate survive a later revocation of that delegate.
///
/// ROUTE LOOP SAFETY
/// @dev Routes are validated independently; crossing paths are not checked. Routes that loop back to the starting
/// market (e.g. both `BORROW_BLUE_TO_MIDNIGHT_CALLBACK` and `BORROW_MIDNIGHT_TO_BLUE_CALLBACK` between the same
/// markets) let a keeper renew through the full loop in one transaction.
/// @dev A loop must either carry a positive spread (enter rate > exit rate) or not have both legs active at once
/// (e.g. `BlueToMidnight.minDuration > MidnightToBlue.renewalWindow`).
/// @dev The single-leg case is the same constraint: keep `renewalWindow < minDuration` or a freshly renewed position
/// is immediately renewable, allowing repeated renewals (and fees) within one window.
///
/// TARGET MARKET
/// @dev The target market choice is the user's responsibility: callbacks only check loan-token equality, not
/// collateral quality, so a lend renewal can enter a market with pending bad debt that the lender later absorbs.
contract MigrationRatifier is BaseMigrationRatifier {
    /// @inheritdoc IMigrationRatifier
    /// @dev Top 6 bytes = "tenor" (0x74656e6f72) domain prefix + schema version byte 0xE0; the 0xE0-0xEF
    /// version range is reserved for migration-group schema versions (this mask matches 0xE0 exactly). The low
    /// 208 bits stay free to vary per offer.
    bytes32 public constant MIGRATION_GROUP_HEADER = hex"74656e6f72e0";

    /// @inheritdoc IMigrationRatifier
    bytes32 public constant MIGRATION_GROUP_HEADER_MASK = hex"ffffffffffff";

    mapping(
        address user
            => mapping(
            address callback
                => mapping(bytes32 sourceTenorMarketId => mapping(bytes32 targetTenorMarketId => UserMigrationParams))
        )
    )
        public
        override userParams;

    constructor(
        address morphoMidnight,
        address borrowMidnightRenewalCallback,
        address borrowBlueToMidnightCallback,
        address lendVaultToMidnightCallback,
        address borrowMidnightToBlueCallback,
        address lendMidnightToVaultCallback,
        address lendMidnightRenewalCallback,
        address _owner
    )
        BaseMigrationRatifier(
            morphoMidnight,
            borrowMidnightRenewalCallback,
            borrowBlueToMidnightCallback,
            lendVaultToMidnightCallback,
            borrowMidnightToBlueCallback,
            lendMidnightToVaultCallback,
            lendMidnightRenewalCallback,
            _owner
        )
    {}

    /// @dev Accepting `onBehalf` lets bundler flows atomically update params alongside a take.
    function setParams(
        address onBehalf,
        address callback,
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        UserMigrationParams calldata params
    ) external override {
        if (msg.sender != onBehalf && !MORPHO_MIDNIGHT.isAuthorized(onBehalf, msg.sender)) {
            revert Unauthorized();
        }
        userParams[onBehalf][callback][sourceTenorMarketId][targetTenorMarketId] = params;
        emit ParamsSet(onBehalf, callback, sourceTenorMarketId, targetTenorMarketId, params);
    }

    function clearParams(address onBehalf, address callback, bytes32 sourceTenorMarketId, bytes32 targetTenorMarketId)
        external
        override
    {
        if (msg.sender != onBehalf && !MORPHO_MIDNIGHT.isAuthorized(onBehalf, msg.sender)) {
            revert Unauthorized();
        }
        delete userParams[onBehalf][callback][sourceTenorMarketId][targetTenorMarketId];
        emit ParamsCleared(onBehalf, callback, sourceTenorMarketId, targetTenorMarketId);
    }

    /// @notice Midnight ratification entry point; reverts on any policy breach, returns CALLBACK_SUCCESS otherwise.
    /// @dev `ratifierData` must be `abi.encode(bytes32 sourceTenorMarketId, bytes32 targetTenorMarketId)`; `_ratify`
    /// validates `offer.maker`'s params for that tuple.
    /// @dev Make-on-behalf settlement guards (the user is the offer maker): proceeds must flow to `offer.callback` on
    /// sells, and there is no taker-funded receiver on buys.
    /// @dev The offer is confined to the reserved migration-group namespace (see `MIGRATION_GROUP_HEADER`).
    function isRatified(Offer memory offer, bytes memory ratifierData, address taker)
        external
        view
        virtual
        returns (bytes32)
    {
        if (ratifierData.length != 64) revert InvalidRatifierData();
        (bytes32 src, bytes32 tgt) = abi.decode(ratifierData, (bytes32, bytes32));
        if (offer.receiverIfMakerIsSeller != (offer.buy ? address(0) : offer.callback)) revert InvalidReceiver();
        if ((offer.group & MIGRATION_GROUP_HEADER_MASK) != MIGRATION_GROUP_HEADER) revert InvalidGroup();
        UserMigrationParams memory params = userParams[offer.maker][offer.callback][src][tgt];
        _ratify(offer.maker, taker, offer.callback, offer.callbackData, offer, src, tgt, params);
        return CALLBACK_SUCCESS;
    }

    /// @dev Requires the maker-declared route to equal the callback-derived markets. The params lookup is already
    /// keyed by `(callback, src, tgt)`, so this binds that key to the callback's actual source/target markets,
    /// preventing a take from ratifying one tuple's params while passing callback data for another tuple.
    function _validateMarketPair(
        bytes32 sourceTenorMarketId,
        bytes32 targetTenorMarketId,
        bytes32 callbackSourceMarketId,
        bytes32 callbackTargetMarketId
    ) internal pure override {
        if (callbackSourceMarketId == sourceTenorMarketId || callbackTargetMarketId != targetTenorMarketId) {  // MUTATION: rebased
            revert InvalidCallbackData();
        }
    }
}
