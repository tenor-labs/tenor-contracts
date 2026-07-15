// MigrationRatifier — VALID STATE: inductive invariants holding in every reachable state of feeConfigs.

import "../setup/ratifier/ratifier_setup.spec";

// RTF-VS-01 (ORCH-1): no reachable state stores an above-cap fee rate; setFeeConfig's guard is the inductive step.
// FORMULA: feeConfigs[cb][id].feeRate <= cap(cb)  (cap = 0 on the V2->V1 exits, 0.5e18 otherwise)
invariant feeRateNeverExceedsCallbackCap(address cb, bytes32 id)
    to_mathint(currentContract.feeConfigs[cb][id].feeRate) <=
        ((cb == _Ratifier.BORROW_MIDNIGHT_TO_BLUE_CALLBACK || cb == _Ratifier.LEND_MIDNIGHT_TO_VAULT_CALLBACK)
            ? MAX_FEE_RATE_FIXED_TO_VARIABLE() : MAX_FEE_RATE())
    filtered { f -> EXCLUDED_FUNCTION(f) }

// RTF-VS-02 (ORCH-2): a stored non-zero fee rate always carries a recipient.
// FORMULA: invariant: feeConfigs[cb][id].feeRate > 0 => feeConfigs[cb][id].feeRecipient != 0
invariant nonZeroFeeRateImpliesRecipient(address cb, bytes32 id)
    currentContract.feeConfigs[cb][id].feeRate > 0
        => currentContract.feeConfigs[cb][id].feeRecipient != 0
    filtered { f -> EXCLUDED_FUNCTION(f) }
