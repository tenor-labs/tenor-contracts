// Run driver for valid-state many-market regime -- re-exports invariants under callbacks summary.

import "midnight_valid_state_many.spec";
import "setup/callbacks.spec";

use invariant creditCoversPendingFee;
use invariant positionLastLossFactorWithinMarket;
use invariant lastAccrualNotInFuture;
use invariant collateralBitmapMatchesSlot;
use invariant nonEmptyPositionImpliesTouched;
use invariant creditAndDebtMutuallyExclusive;
use invariant creditOrLastLossFactorImpliesLastAccrual;
use invariant pendingFeePositiveImpliesCreditPositive;
use invariant marketSettlementFeesBounded;
use invariant marketContinuousFeeBounded;
use invariant defaultSettlementFeesBounded;
use invariant defaultContinuousFeeBounded;
use invariant claimableAndWithdrawableBackedByBalance;
use invariant collateralBackedByBalance;
use invariant perTokenClaimableBounded;
use invariant noSelfApprove;
use invariant debtSumAndWithdrawableWithinTotalUnits;
use invariant creditSumAndCfcEqualTotalUnitsWhenNoBadDebt;
use invariant untouchedMarketIsEmptyParametric;
use invariant tickSpacingDividesDefault;
use invariant debtPositiveImpliesCollateralBitmapNonZero;
use rule gettersMatchStoragePerId;
use rule liquidateMarketIsolationMany;
