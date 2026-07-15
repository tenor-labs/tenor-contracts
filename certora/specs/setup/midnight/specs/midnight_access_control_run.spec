// Run driver for the access-control rules under the callbacks summary.

import "midnight_access_control.spec";
import "setup/callbacks.spec";

use rule onlyConfiguratorChangesConfigurator;
use rule onlyConfiguratorChangesFeeSetter;
use rule onlyConfiguratorChangesFeeClaimer;
use rule onlyConfiguratorChangesTickSpacingSetter;
use rule onlyFeeSetterChangesDefaultSettlementFee;
use rule onlyFeeSetterChangesDefaultContinuousFee;
use rule onlyFeeSetterChangesMarketSettlementFee;
use rule onlyFeeSetterChangesMarketContinuousFee;
use rule onlyTickSpacingSetterChangesTickSpacing;
use rule onlyFeeClaimerDrainsClaimableSettlementFee;
use rule onlyAuthorizerChangesAuthorization;
use rule onlyConfiguratorChangesLltvEnabled;
use rule onlyConfiguratorChangesLiquidationCursorEnabled;
