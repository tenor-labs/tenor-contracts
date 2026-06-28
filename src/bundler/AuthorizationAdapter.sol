// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {CoreAdapter, ErrorsLib} from "@bundler3/adapters/CoreAdapter.sol";
import {IMidnight} from "@midnight/interfaces/IMidnight.sol";
import {IEcrecoverRatifier} from "@midnight/ratifiers/interfaces/IEcrecoverRatifier.sol";
import {ISetterRatifier} from "@midnight/ratifiers/interfaces/ISetterRatifier.sol";

/// @title AuthorizationAdapter
/// @notice Bundler3 adapter for granting/revoking long-lived authorizations on Morpho Midnight, on behalf of the
///         bundle initiator.
contract AuthorizationAdapter is CoreAdapter {
    /* IMMUTABLES */

    /// @notice The Morpho Midnight contract.
    IMidnight public immutable MORPHO_MIDNIGHT;

    /* CONSTRUCTOR */

    /// @param bundler3 The Bundler3 contract address.
    /// @param morphoMidnight The Morpho Midnight contract address.
    constructor(address bundler3, address morphoMidnight) CoreAdapter(bundler3) {
        require(morphoMidnight != address(0), ErrorsLib.ZeroAddress());
        MORPHO_MIDNIGHT = IMidnight(morphoMidnight);
    }

    /* ACTIONS */

    /// @notice Sets Midnight authorization for `authorized` on behalf of the bundle initiator.
    function midnightSetIsAuthorized(address authorized, bool newIsAuthorized) external onlyBundler3 {
        MORPHO_MIDNIGHT.setIsAuthorized(authorized, newIsAuthorized, initiator());
    }

    /// @notice Sets ratification of `root` on `setterRatifier` on behalf of the bundle initiator.
    function setterRatifierSetIsRootRatified(address setterRatifier, bytes32 root, bool newIsRootRatified)
        external
        onlyBundler3
    {
        ISetterRatifier(setterRatifier).setIsRootRatified(initiator(), root, newIsRootRatified);
    }

    /// @notice Cancels a previously-signed offer-tree root on `ecrecoverRatifier` on behalf of the
    ///         bundle initiator.
    function ecrecoverRatifierCancelRoot(address ecrecoverRatifier, bytes32 root) external onlyBundler3 {
        IEcrecoverRatifier(ecrecoverRatifier).cancelRoot(initiator(), root);
    }
}
