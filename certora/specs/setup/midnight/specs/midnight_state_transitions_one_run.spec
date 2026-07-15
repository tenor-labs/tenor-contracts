// Run driver for state-transition one-market regime -- rules under the callbacks summary.

import "midnight_state_transitions_one.spec";
import "setup/callbacks.spec";

use rule claimableSettlementFeeDecreasesOnlyViaClaim;
use rule collateralOpsPreserveCreditDebtFeeSurface;
use rule lossFactorIncreaseCoincidesWithTotalUnitsDecrease;
use rule creditSideChangeStampsAccrual;
use rule liquidateRequiresBorrowerDebt;
use rule takeCannotIncreaseDebtPostMaturity;
use rule takePairsCreditAndDebtDirectionally;
use rule creditDecreaseDoesNotRaisePendingFee;
use rule withdrawCollateralMatchesMidnightBalance;
use rule claimSettlementFeeMatchesBalance;
use rule takeLeavesSellerLockedOrHealthy;
use rule tickSpacingRefinesToDivisor;
use rule liquidateRequiresUnlockedBorrower;
use rule lossFactorRaisedOnlyByLiquidate;
use rule liquidatePreservesCreditSideSurface;
use rule debtDecreaseOnlyViaTakeRepayOrLiquidate;
use rule lltvEnabledIsMonotone;
use rule liquidationCursorEnabledIsMonotone;
