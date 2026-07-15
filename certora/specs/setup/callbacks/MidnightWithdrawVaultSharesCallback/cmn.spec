// MWV setup: onBuy-only, buyer-side scenario; shared bindings/narrowings for CLB rules.

import "../../midnight/specs/midnight_valid_state_many.spec";
// Real VaultV2 contract on scene (not a CVL model).
import "../../vault-v2/specs/vaultV2_valid_state.spec";
import "../../vault-v2/specs/setup/vaultv2_token_routing.spec";
import "../../../callbacks/callbacks.spec";

using MidnightWithdrawVaultSharesCallbackHarness as _Callback;

methods {
    // ERC-4626 vault entry: the only implementer on scene is VaultV2Harness (real code).
    function _.previewWithdraw(uint256 assets) external => DISPATCHER(true);
    function _.withdraw(uint256 assets, address receiver, address owner) external => DISPATCHER(true);
    // Direct read of the real immutable from CVL (receiver here is the contract name).
    function VaultV2Harness.assetHarness() external returns (address) envfree;

    function _.onBuy(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, bytes) external
        => DISPATCHER(true);

    function _.onSell(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, address, bytes) external
        => onSellOppositeSideExcluded(calledContract) expect bytes32;
}

// MWV is onBuy-only; onSell path impossible
function onSellOppositeSideExcluded(address called) returns bytes32 {
    require(called != _Callback, "SAFE: MWV is a buy-only (onBuy) callback");
    bytes32 ret;
    return ret;
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

// pin maker=buyer regime so buyer callback is MWV
function setupMigrationRatifier(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    require(offer.buy == true,            "SCOPE: buy-side flow (maker is buyer; MWV.onBuy fires via offer.callback)");
    require(offer.callback == _Callback,  "TRUSTED: MWV is the activated buy-side callback");
    require(takerCallback == 0,           "SCOPE: single-sided scenario excludes the taker callback");

    // validateVaultCollateral reconstruction; vault pinned to the on-scene instance and slot 0.
    address vault = _Callback.decodeCallbackVault(e, offer.callbackData);
    require(vault == _VaultV2,
        "SAFE: the decoded vault is the on-scene VaultV2 instance (link-analog for a decoded address)");
    require(_Callback.decodeCallbackCollateralIndex(e, offer.callbackData) == 0,
        "SAFE: vault pinned to collateral slot 0 (single-write narrowing)");
    require(offer.market.collateralParams.length == ghostNumCollaterals,
        "UNSAFE: offer market collateral count matches the model");
    require(ghostERC4626Asset[vault] == offer.market.loanToken,
        "ASSERT: vault.asset() == loanToken (validateVaultCollateral reverts on mismatch)");
    require(offer.market.collateralParams[0].token == vault,
        "ASSERT: vault listed at collateral slot 0 (validateVaultCollateral reverts on mismatch)");
    require(vault != offer.market.loanToken,
        "SAFE: vault is an ERC4626 share token, never its own underlying loanToken");
}

// revert helper for callback rules
function callbackCallWithRevert(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) returns bool {
    _Callback.onBuy@withrevert(e, id, market, assets, units, pendingFee, user, data);
    return lastReverted;
}

// no-fee hooks: MWV has no fee recipient
function decodeActiveFeeRecipient(env e, MidnightHarness.Offer offer) returns address {
    return 0;
}
function requireThirdPartyNarrowings(env e, address u,
        MidnightHarness.Offer offer) {
}
function requireFeeRecipientNarrowings(env e, address feeRecipient) {
}

// sellerAssets receiver is the trader, never the callback
function requireReceiverNarrowing(env e,
        MidnightHarness.Offer offer, address receiverIfTakerIsSeller) {
    address receiver = offer.buy ? receiverIfTakerIsSeller : offer.receiverIfMakerIsSeller;
    require(receiver != _Callback,
        "SCOPE: sellerAssets land on the trader, not the buy-only callback");
}

// sell-side callback is never MWV (onBuy-only)
function requireCallbackEndpointNarrowings(env e,
        MidnightHarness.Offer offer) {
    // Subsumed by setupMigrationRatifier's takerCallback == 0 pin (applied via callbackSetup before this runs).
}
