// Run driver for the reachability rules under the callbacks summary.

import "midnight_reachability.spec";
import "setup/callbacks.spec";

use rule takeMintsCreditReachable;
use rule takeMintsDebtReachable;
use rule takeCapturesSettlementFeeReachable;
use rule withdrawReachable;
use rule withdrawFullCreditExitReachable;
use rule repayReachable;
use rule repayFullDebtReachable;
use rule supplyCollateralActivatesSlotReachable;
use rule withdrawCollateralReachable;
use rule liquidateNormalModeReachable;
use rule liquidatePostMaturityReachable;
use rule liquidateRealizesBadDebtReachable;
use rule positionCanBeUnhealthy;
use rule claimSettlementFeeReachable;
use rule claimContinuousFeeReachable;
use rule flashLoanReachable;
use rule updatePositionSlashesCreditReachable;
use rule borrowThenLiquidateReachable;
