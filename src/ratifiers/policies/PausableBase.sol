// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPausableInterestRatePolicy} from "../interfaces/IPausableInterestRatePolicy.sol";

/// @title PausableBase
/// @notice Shared pause state and admin for IInterestRatePolicy variants.
/// @dev Pausers (configured by the owner) can pause; only the owner can unpause.
abstract contract PausableBase is IPausableInterestRatePolicy, Ownable2Step {
    bool public paused;
    mapping(address => bool) public isPauser;

    constructor(address _owner) Ownable(_owner) {}

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    function setPauser(address pauser, bool allowed) external onlyOwner {
        isPauser[pauser] = allowed;
        emit PauserSet(pauser, allowed);
    }

    function pause() external {
        if (!isPauser[msg.sender]) revert OnlyPauser();
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }
}
