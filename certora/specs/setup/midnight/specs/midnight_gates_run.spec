// Run driver for gate-enforcement rules under the callbacks summary.

import "midnight_gates.spec";
import "setup/callbacks.spec";

use rule takeBuyerCreditIncreaseRequiresGateApproval;
use rule takeSellerDebtIncreaseRequiresGateApproval;
use rule liquidateRequiresLiquidatorGateApproval;
use rule takeRequiresRatifierSuccess;
