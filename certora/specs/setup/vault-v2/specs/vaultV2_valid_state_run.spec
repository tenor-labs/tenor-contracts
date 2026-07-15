// Entry-point spec for the valid_state run (referenced by valid_state.conf).
// Separate from vaultV2_valid_state.spec so importers of the library don't
// re-run the invariants; this file adds one `use invariant` per invariant.

import "vaultV2_valid_state.spec";
// import "setup/callbacks.spec";   // none created (adapters/gates summarized directly)

use invariant maxRateBounded;
use invariant relativeCapBounded;
use invariant penaltyBounded;
use invariant performanceFeeBounded;
use invariant managementFeeBounded;
use invariant performanceFeeRecipientConsistency;
use invariant managementFeeRecipientConsistency;
use invariant sharesZeroAddressEmpty;
use invariant zeroCannotApprove;
use invariant sharesSolvency;

