// MigrationRatifier — ACCESS-CONTROL: owner-/authorization-gated mutations.
// Ownership rotation itself (OZ Ownable2Step transfer/accept/renounce) is out of FV scope.

import "../setup/ratifier/ratifier_setup.spec";

// RTF-AC-01 (ORCH-1, owner-gate): only the owner can change a stored fee config (access-control facet of the ORCH-1 fee-config family; the value-bound is RTF-VS-01).
// FORMULA: feeConfigs[cb][id]' != feeConfigs[cb][id] => msg.sender == owner
rule feeConfigChangeRequiresOwner(env e, method f, calldataarg args, address cb, bytes32 id)
        filtered { f -> EXCLUDED_FUNCTION(f) } {

    address owner = _Ratifier.owner(e);
    address rcptBefore; uint96 rateBefore;
    rcptBefore, rateBefore = _Ratifier.feeConfigs(e, cb, id);

    f(e, args);

    address rcptAfter; uint96 rateAfter;
    rcptAfter, rateAfter = _Ratifier.feeConfigs(e, cb, id);

    assert((rcptAfter != rcptBefore || rateAfter != rateBefore) => e.msg.sender == owner,
        "a stored fee config changes only when the caller is the owner");
}

// RTF-AC-02 (REG-1): a user's stored params change only when the caller is onBehalf or Midnight-authorized for them.
// FORMULA: userParams[onBehalf][cb][src][tgt]' != userParams[onBehalf][cb][src][tgt] => sender == onBehalf OR isAuthorized(onBehalf, sender)
rule userParamsChangeRequiresAuthorization(env e, method f, calldataarg args,
        address onBehalf, address cb, bytes32 src, bytes32 tgt)
        filtered { f -> EXCLUDED_FUNCTION(f) } {
    
    bool authorized = e.msg.sender == onBehalf || ghostMnIsAuthorized[onBehalf][e.msg.sender];

    address polBefore; uint32 winBefore; uint32 minBefore; uint32 maxBefore; address cadBefore; uint40 limBefore;
    polBefore, winBefore, minBefore, maxBefore, cadBefore, limBefore = _Ratifier.userParams(e, onBehalf, cb, src, tgt);

    f(e, args);

    address polAfter; uint32 winAfter; uint32 minAfter; uint32 maxAfter; address cadAfter; uint40 limAfter;
    polAfter, winAfter, minAfter, maxAfter, cadAfter, limAfter = _Ratifier.userParams(e, onBehalf, cb, src, tgt);

    assert((polAfter != polBefore || winAfter != winBefore || minAfter != minBefore
            || maxAfter != maxBefore || cadAfter != cadBefore || limAfter != limBefore) => authorized,
        "a user's stored params change only when the caller is authorized for onBehalf");
}
