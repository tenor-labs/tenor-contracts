// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Les entreprises shippooor inc.
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IEnterGate, ILiquidatorGate} from "@midnight/interfaces/IGate.sol";

/// @title MidnightAllowlistGate
/// @notice Allowlist-based gate for Midnight markets.
/// @dev Set as the market's enterGate and/or liquidatorGate.
/// @dev The owner can setAllowlist then renounceOwnership to make the stored allowlist immutable.
/// @dev Allowlisting a public router or executor extends its permission to anyone able to call through it.
contract MidnightAllowlistGate is IEnterGate, ILiquidatorGate, Ownable2Step {
    struct Role {
        address user;
        bool canIncreaseCredit;
        bool canIncreaseDebt;
        bool canLiquidate;
    }

    event MidnightAllowlistUpdated(
        address indexed user, bool canIncreaseCredit, bool canIncreaseDebt, bool canLiquidate
    );

    mapping(address => Role) public allowlist;

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Sets the allowlist roles of one or more accounts.
    /// @param roles The roles to set. Each role specifies a user and their gate permissions.
    function setAllowlist(Role[] calldata roles) external onlyOwner {
        for (uint256 i; i < roles.length; ++i) {
            Role calldata role = roles[i];
            allowlist[role.user] = role;
            emit MidnightAllowlistUpdated(role.user, role.canIncreaseCredit, role.canIncreaseDebt, role.canLiquidate);
        }
    }

    /// @inheritdoc IEnterGate
    function canIncreaseCredit(address account) external view override returns (bool) {
        return allowlist[account].canIncreaseCredit;
    }

    /// @inheritdoc IEnterGate
    function canIncreaseDebt(address account) external view override returns (bool) {
        return allowlist[account].canIncreaseDebt;
    }

    /// @inheritdoc ILiquidatorGate
    function canLiquidate(address account) external view override returns (bool) {
        return allowlist[account].canLiquidate;
    }
}
