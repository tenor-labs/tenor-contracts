// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity >=0.5.0;

import {IInterestRatePolicy} from "./IInterestRatePolicy.sol";

/// @title IPausableInterestRatePolicy
/// @notice Interface of pausable interest rate policies.
interface IPausableInterestRatePolicy is IInterestRatePolicy {
    event Paused(address account);
    event Unpaused(address account);
    event PauserSet(address pauser, bool allowed);

    error OnlyPauser();
    error AlreadyPaused();
    error NotPaused();
    error IsPaused();

    /// @notice Whether the policy is paused.
    function paused() external view returns (bool);

    /// @notice Whether an address is a pauser.
    function isPauser(address) external view returns (bool);

    /// @notice Adds or removes a pauser. Only callable by the owner.
    function setPauser(address pauser, bool allowed) external;

    /// @notice Pauses the policy, blocking all rate queries. Callable by any pauser.
    function pause() external;

    /// @notice Unpauses the policy, allowing rate queries. Only callable by the owner.
    function unpause() external;
}
