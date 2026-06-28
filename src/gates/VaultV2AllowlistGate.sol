// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IReceiveSharesGate, ISendSharesGate, IReceiveAssetsGate, ISendAssetsGate} from "@vault-v2/interfaces/IGate.sol";
import {IVaultV2} from "@vault-v2/interfaces/IVaultV2.sol";

/// @title VaultV2AllowlistGate
/// @notice Allowlist-based gate for VaultV2 share and asset transfers.
/// @dev The owner can setAllowlist then renounceOwnership to make the stored allowlist immutable.
/// @dev Management and performance fee recipients are auto-permitted for canReceiveShares, canSendShares and
/// canReceiveAssets. canSendAssets has no fee-recipient exemption.
/// @dev The effective allowlist is the stored allowlist plus the fee recipients, so it is truly frozen only if the
/// vault curator also abdicates setManagementFeeRecipient and setPerformanceFeeRecipient.
/// @dev VaultV2's forceDeallocate penalty can only be paid in vault shares, burned via a withdraw that requires
/// canSendShares on the holder; denying it to that holder breaks this non-custodial in-kind redemption guarantee.
/// @dev A restrictive canReceiveShares allowlist can break the same guarantee: if only contracts can receive shares,
/// users never hold shares directly, and unless an allowlisted holder exposes a way to call forceDeallocate (or
/// approves an account that can), the escape hatch is unreachable.
contract VaultV2AllowlistGate is
    IReceiveSharesGate,
    ISendSharesGate,
    IReceiveAssetsGate,
    ISendAssetsGate,
    Ownable2Step
{
    struct Role {
        address user;
        bool canReceiveShares;
        bool canSendShares;
        bool canReceiveAssets;
        bool canSendAssets;
    }

    event VaultV2AllowlistUpdated(
        address indexed user, bool canReceiveShares, bool canSendShares, bool canReceiveAssets, bool canSendAssets
    );

    mapping(address => Role) public allowlist;

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Sets the allowlist roles of one or more accounts.
    /// @param roles The roles to set. Each role specifies a user and their gate permissions.
    function setAllowlist(Role[] calldata roles) external onlyOwner {
        for (uint256 i; i < roles.length; ++i) {
            Role calldata role = roles[i];
            allowlist[role.user] = role;
            emit VaultV2AllowlistUpdated(
                role.user, role.canReceiveShares, role.canSendShares, role.canReceiveAssets, role.canSendAssets
            );
        }
    }

    /// @inheritdoc IReceiveSharesGate
    function canReceiveShares(address account) external view override returns (bool) {
        if (allowlist[account].canReceiveShares) return true;
        return _isFeeRecipient(account);
    }

    /// @inheritdoc ISendSharesGate
    function canSendShares(address account) external view override returns (bool) {
        if (allowlist[account].canSendShares) return true;
        return _isFeeRecipient(account);
    }

    /// @inheritdoc IReceiveAssetsGate
    function canReceiveAssets(address account) external view override returns (bool) {
        if (allowlist[account].canReceiveAssets) return true;
        return _isFeeRecipient(account);
    }

    /// @inheritdoc ISendAssetsGate
    function canSendAssets(address account) external view override returns (bool) {
        return allowlist[account].canSendAssets;
    }

    function _isFeeRecipient(address account) internal view returns (bool) {
        IVaultV2 vault = IVaultV2(msg.sender);
        return account == vault.managementFeeRecipient() || account == vault.performanceFeeRecipient();
    }
}
