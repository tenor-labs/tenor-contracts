// Run driver for the HEAVY tier of the high-level rules: nonlinear slash/lossFactor
// arithmetic, take pricing exactness, and the inductive solvency sweep. Runs under
// high_level_heavy.conf (extended smt budget, solver portfolio — same shape as
// valid_state_one_ext.conf).

import "midnight_high_level.spec";
import "setup/callbacks.spec";

use rule takeBuyerFeePreChargeExactAndBounded;
use rule lossFactorUpdateExact;
use rule cfcRescaleExact;
use rule lossFactorRiseImpliesUndercollateralizedAtMaxLif;
use rule rcfDustEscapeRequiresDustCollateral;
use rule rcfDustEscapeReachable;
use rule lossFactorMaxOnlyWhenUnitsWiped;
use rule postSlashSolvencyOneStep;
use rule postSlashSolvencyPreservedExceptLiquidate;
use rule slashBurnsPendingFeeProportionally;
use rule idleLenderCreditNonIncreasing;
use rule slashTimingFairness;
use rule takeNettingUnitConservation;
use rule takeFeeIncidenceMatchesLeviedFee;
use rule takeFillAccountingExact;
use rule takeSettlementSpreadCappedByProtocolMax;

// Liquidate coverage (nonlinear ceil/floor mulDiv chains and the time-ramped lif —
// same arithmetic class as lossFactorUpdateExact/rcfDustEscape*).
use rule rcfDustEscapeTwoCollateral;
use rule badDebtFormulaExact;
use rule seizureToRepaidConversionExact;
use rule repaidToSeizedConversionExact;
use rule postMaturityLifIncentiveMonotoneInTime;
