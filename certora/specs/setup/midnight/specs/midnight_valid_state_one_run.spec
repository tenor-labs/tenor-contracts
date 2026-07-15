// Run driver for valid-state one-market regime -- re-exports invariants under callbacks summary.

import "midnight_valid_state_one.spec";
import "setup/callbacks.spec";

use invariant creditCoversPendingFee;
use invariant positionLastLossFactorWithinMarket;
use invariant lastAccrualNotInFuture;
use invariant collateralBitmapMatchesSlot;
use invariant marketSettlementFeesBounded;
use invariant marketContinuousFeeBounded;
use invariant defaultSettlementFeesBounded;
use invariant defaultContinuousFeeBounded;
use invariant nonEmptyPositionImpliesTouched;
use invariant creditAndDebtMutuallyExclusive;
use invariant creditOrLastLossFactorImpliesLastAccrual;
use invariant claimableAndWithdrawableBackedByBalance;
use invariant collateralBackedByBalance;
use invariant perTokenClaimableBounded;
use invariant noSelfApprove;
use invariant creditSumAndCfcEqualTotalUnitsWhenNoBadDebt;
use invariant debtSumAndWithdrawableWithinTotalUnits;
use invariant pendingFeePositiveImpliesCreditPositive;
use invariant tickSpacingDividesDefault;
use invariant debtPositiveImpliesCollateralBitmapNonZero;
use invariant continuousFeeCreditWithinTotalUnitsMinusDebt;
