// Run driver for high-level rules under the callbacks summary.

import "midnight_high_level.spec";
import "setup/callbacks.spec";

use rule claimableSettlementFeeNeverDecreases;
use rule takeCapturesExactSettlementFee;
use rule withdrawExactDecrement;
use rule repayExactSwap;
use rule claimContinuousFeeExactDecrement;
use rule supplyCollateralExactAdd;
use rule flashLoanBalanceNeutral;
use rule withdrawCollateralLeavesBorrowerHealthy;
use rule liquidateIsReductive;
use rule collateralRoundTripRestoresSlot;
use rule updatePositionPreservesTotalUnitsAndWithdrawable;
use rule loanTokenSurplusNonDecreasing;
use rule collateralTokenSurplusNonDecreasing;
use rule updatePositionViewMatchesState;
use rule liquidateRespectsLifSeizureBound;
use rule withdrawRequiresAuthorization;
use rule withdrawCollateralRequiresAuthorization;
use rule lossFactorMonotonic;
use rule slashNeverMintsCredit;
use rule takeDoesNotTouchBystander;
use rule consumedBoundedByOfferMax;
use rule gettersMatchStorage;

// Light/moderate tier (the heavy tier runs in
// midnight_high_level_heavy_run.spec / high_level_heavy.conf).
use rule accrualConservesCreditIntoFeePot;
use rule takeSellerBurnsPendingFeeProportionally;
use rule updatePositionIdempotentSameBlock;
use rule accrualLinearInTimeWithMaturityCutoff;
use rule feeAccrualMonotoneAndFrozenAfterMaturity;
use rule liquidateOnlyWhenUnhealthyOrPastMaturity;
use rule liquidateLoanInCollateralOutExact;
use rule liquidateDoesNotTouchBystander;
use rule reduceOnlyHonoredForMaker;
use rule takeHonorsOfferIntegrityGates;
use rule settlementFeeNeverExceedsProtocolMax;
use rule takeSellRoutesPayerReceiverMidnightExactly;
use rule takeBuyRoutesPayerReceiverMidnightExactly;
use rule consumedMonotoneGlobally;
use rule isHealthyMatchesFormula;
use rule repayPullsExactlyFromPayerOnly;
use rule withdrawPaysReceiverExactly;
use rule supplyCollateralPullsSenderOnly;
use rule withdrawCollateralPaysReceiverExactly;
use rule claimContinuousFeePaysReceiverExactly;
use rule claimSettlementFeePaysReceiverExactly;

// Liquidate coverage (light tier; the heavy liquidate exactness rules run in
// midnight_high_level_heavy_run.spec).
use rule liquidateCollateralTokenRoutingExact;
use rule liquidateLoanTokenRoutingExact;
