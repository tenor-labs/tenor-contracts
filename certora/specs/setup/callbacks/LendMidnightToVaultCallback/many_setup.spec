// Real VaultV2 contract on scene (not a CVL model).
import "../../vault-v2/specs/vaultV2_valid_state.spec";
import "../../vault-v2/specs/setup/vaultv2_token_routing.spec";
import "../../midnight/specs/midnight_valid_state_many.spec";
import "../../../callbacks/callbacks.spec";

using LendMidnightToVaultCallbackHarness as _Callback;

methods {
    function _.onSell(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, address, bytes) external
        => DISPATCHER(true);
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

function setupMigrationRatifier(env e,
        MidnightHarness.Offer offer, uint256 units, address taker,
        address receiverIfTakerIsSeller, address takerCallback,
        bytes takerCallbackData, bytes ratifierData) {

    require(offer.buy == false,          "SCOPE: maker-side flow (LMV onSell fires on maker=seller)");
    require(offer.callback == _Callback, "TRUSTED: LMV is the activated maker(sell)-side callback");
    require(takerCallback == 0,          "SCOPE: single-sided maker scenario excludes taker callback");

    require(_Callback.decodeCallbackVault(e, offer.callbackData) == _VaultV2,
        "SAFE: the decoded destination vault is the on-scene VaultV2 instance (link-analog for a decoded address)");

    uint256 cbFeeRate = _Callback.decodeCallbackFeeRate(e, offer.callbackData);
    require(to_mathint(cbFeeRate) <= MAX_PERCENTAGE_FEE_RATE(),
        "ASSERT: percentageFee reverts above the 1% contract cap (standalone make/take)");
    address cbFeeRecipient = _Callback.decodeCallbackFeeRecipient(e, offer.callbackData);
    require(cbFeeRate > 0 => cbFeeRecipient != 0,
        "TRUSTED: ratifier/maker rejects a zero fee recipient when a fee is charged");
}

function callbackCallWithRevert(env e, bytes32 id, MidnightHarness.Market market,
        uint256 assets, uint256 units, uint256 pendingFee,
        address user, address receiver, bytes data) returns bool {
    _Callback.onSell@withrevert(e, id, market, assets, units, pendingFee, user, receiver, data);
    return lastReverted;
}

function decodeActiveFeeRecipient(env e, MidnightHarness.Offer offer) returns address {
    return _Callback.decodeCallbackFeeRecipient(e, offer.callbackData);
}

function requireThirdPartyNarrowings(env e, address u,
        MidnightHarness.Offer offer) {
    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(u != feeRecipient, "SAFE: u != active feeRecipient");
}

function requireCallbackEndpointNarrowings(env e,
        MidnightHarness.Offer offer) {
    address feeRecipient = decodeActiveFeeRecipient(e, offer);
    require(feeRecipient != _Callback, "TRUSTED: fee recipient is not the callback itself (no self-payment aliasing)");
}

function requireReceiverNarrowing(env e,
        MidnightHarness.Offer offer, address receiverIfTakerIsSeller) {
    require(offer.receiverIfMakerIsSeller == _Callback,
        "TRUSTED: LMV maker-side flow -- sellerAssets land on the callback for vault deposit");
}

function requireFeeRecipientNarrowings(env e, address feeRecipient) {
    require(ghostERC4626Asset[feeRecipient] == 0,
        "TRUSTED: feeRecipient is not the vault (its loanToken delta is the fee, not a deposit)");
    require(!ghostTvIsAdapter[feeRecipient]
         && feeRecipient != ghostTvLiquidityAdapter
         && feeRecipient != ghostTvPerformanceFeeRecipient
         && feeRecipient != ghostTvManagementFeeRecipient,
        "TRUSTED: feeRecipient's loanToken delta is the callback fee, not vault plumbing");
}
