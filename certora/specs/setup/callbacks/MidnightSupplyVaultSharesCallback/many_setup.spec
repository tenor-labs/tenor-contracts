// Real VaultV2 contract on scene (not a CVL model).
import "../../vault-v2/specs/vaultV2_valid_state.spec";
import "../../vault-v2/specs/setup/vaultv2_token_routing.spec";
import "../../midnight/specs/midnight_valid_state_many.spec";
import "cmn.spec";

methods {
    // ERC-4626 vault entry: the only implementer on scene is VaultV2Harness (real code).
    function _.deposit(uint256 assets, address receiver) external => DISPATCHER(true);
    // Direct read of the real immutable from CVL (receiver here is the contract name).
    function VaultV2Harness.assetHarness() external returns (address) envfree;
}

function setupCallbackState(env e) {
    setupValidStateManyMidnight(e);
    setupValidStateVaultV2(e);

    require(ghostERC4626Asset[_Callback] == 0,
        "SAFE: callback is not an ERC-4626 vault");

    require(_VaultV2 != _Callback && _VaultV2 != _Midnight,
        "SAFE: vault is a distinct deployed contract");

    require(ghostERC4626Asset[_VaultV2] == _VaultV2.assetHarness(),
        "SAFE: asset() ghost mirrors the real vault immutable");

    require(_VaultV2.performanceFee() == 0 && _VaultV2.managementFee() == 0,
        "SCOPE: no fee accrual - no fee-share mints, no fee NLA");
    require(_VaultV2.adaptersLength() == 0,
        "SCOPE: no adapters - accrueInterestView loop is dead, loop_iter=2 suffices");
    require(_VaultV2.liquidityAdapter() == 0,
        "SCOPE: no liquidity adapter - enter/exit skip allocate/deallocate");
}
