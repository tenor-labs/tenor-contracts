# Mutations — `MidnightWithdrawableCallback` (`src/callbacks/MidnightWithdrawableCallback.sol`)

Each numbered file is the contract with **one** line broken; the listed rule caught it — it flipped to a counterexample on the mutant. Run the clean source first (`certoraRun <conf> --rule <rule>` → `VERIFIED`), then the mutant with `./certora/mutations/run_mutation.sh MidnightWithdrawableCallback <N>` (`VIOLATED` = killed).

| # | What we test | Caught by | Kill run |
|---|---|---|---|
| ✗ [1](1.sol) | maker check dropped: offers made by anyone else are ratified | [`isRatifiedOnlyAcceptsOwnParBuyOffer`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L15) (MWC-1) | [❌](https://prover.certora.com/output/2121305/61e19330608e44fb881cb024db1ef37b?anonymousKey=7bf87fcc066f2ae1b4c554ff110d03f2ce44ac88) |
| ✗ [2](2.sol) | callback check dropped: own offers without the onBuy withdraw are ratified | [`isRatifiedOnlyAcceptsOwnParBuyOffer`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L15) (MWC-1) | [❌](https://prover.certora.com/output/2121305/588628233d154169abb30d60341da157?anonymousKey=c43db24a6cdcee1327d0cc64ec3fd59ee11fddfb) |
| ✗ [3](3.sol) | par check dropped: below-par ticks are ratified | [`isRatifiedOnlyAcceptsOwnParBuyOffer`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L15) (MWC-1) | [❌](https://prover.certora.com/output/2121305/e87efe6bf2ae4b85b10583731069e0e9?anonymousKey=53c2159795db261d421501596494cc8dd2a96b01) |
| ✗ [4](4.sol) | Midnight-only guard dropped: anyone can call onBuy | [`onBuyRevertsForNonMidnightCaller`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L50) (MWC-3) | [❌](https://prover.certora.com/output/2121305/b4e2f5353d6c46fbb3a29a58778ac7c5?anonymousKey=0c9e96425261d880003c5f764d6c81eb7a68218a) |
| ✗ [5](5.sol) | buyer guard dropped: foreign offers pointing their callback here reach the withdraw | [`onBuyRevertsForOtherBuyer`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L62) (MWC-4) | [❌](https://prover.certora.com/output/2121305/7f6a1e431a45453a8376dbc150cd3b17?anonymousKey=ffb25817e2220db8f2f75a03f0e3b43603b2fe4b) |
| ✗ [6](6.sol) | withdraws one unit short: the callback keeps 1 unit of credit after the fill | [`callbackPositionStaysZero`](../../specs/callbacks/MidnightWithdrawableCallback/many.spec#L6) (MWC-6) | [❌](https://prover.certora.com/output/2121305/58ddc09df3d74c1eb24f99ac6318ef53?anonymousKey=c2030f360557511b5db71aab7fd6aa2834256482) |
| ✗ [7](7.sol) | extra approval to tx.origin: whoever triggers a first fill can later pull the callback's tokens | [`callbackOnlyApprovesMidnight`](../../specs/callbacks/MidnightWithdrawableCallback/many.spec#L22) (MWC-7) | [❌](https://prover.certora.com/output/2121305/c93b4839bc2843bfa514c7a68f80d9a7?anonymousKey=e495b08d6e1e950357a7d3d9deb44726f9783392) |
| ✗ [8](8.sol) | zero guard dropped: zero-unit fills reach the withdraw | [`onBuyRevertsOnZeroAssetsOrUnits`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L79) (MWC-14) | [❌](https://prover.certora.com/output/2121305/f97d3a6e4ed64f3db6067a8a13403d33?anonymousKey=964a2a6bc4a4e979ba99225563afe229dd56b3fe) |
| ✗ [9](9.sol) | approval check inverted: a first fill never approves Midnight, so the payer pull reverts | [`positiveFillIsReachable`](../../specs/callbacks/MidnightWithdrawableCallback/many.spec#L144) (MWC-13) | [❌](https://prover.certora.com/output/2121305/7b1de1ee617646f7b9f3fb0fde86508d?anonymousKey=519af41e22b6b8167ff5ca5fdd88a2d2ce539277) |

## Clean runs

Every rule verified on the unmutated source (`MWC-13` is a `satisfy` witness).

| Properties | Conf | Run |
|---|---|---|
| MWC-1..5, MWC-14 | `certora/confs/callbacks/MidnightWithdrawableCallback/standalone.conf` | [✅](https://prover.certora.com/output/2121305/94abf80e0349469b988e565b8f3bcc8e?anonymousKey=1a06c0acbcc3979c37f0ffd65537addf5d195ba7) |
| MWC-6 | `certora/confs/callbacks/MidnightWithdrawableCallback/perf/callbackPositionStaysZero.conf` | [✅](https://prover.certora.com/output/2121305/94685494d0ed4bcdbf135f0618bfc4e8?anonymousKey=07b4d8ad0c721f1e91ccfd4835ad6fa390aa2435) |
| MWC-7 | `certora/confs/callbacks/MidnightWithdrawableCallback/callbackOnlyApprovesMidnight.conf` | [✅](https://prover.certora.com/output/2121305/19023e811026405182897f352b2f367a?anonymousKey=c3cace7dd59d554d2c233ac5fcfe9b69ce842079) |
| MWC-8 | `certora/confs/callbacks/MidnightWithdrawableCallback/callbackBalanceUnchanged.conf` | [✅](https://prover.certora.com/output/2121305/c6f1e5b8332748649ea7d167cef9e327?anonymousKey=e7f752048d4f549b7e6e50acfb0cc1e63b858950) |
| MWC-9 | `certora/confs/callbacks/MidnightWithdrawableCallback/withdrawableDropsByUnits.conf` | [✅](https://prover.certora.com/output/2121305/00936b473dad41e890bd8707d4ed8fd2?anonymousKey=b6b7f7f4f02db3eaafc19f2a0e15364bda7276ec) |
| MWC-10 | `certora/confs/callbacks/MidnightWithdrawableCallback/perf/takerPositionShiftsByUnits.conf` | [✅](https://prover.certora.com/output/2121305/b1beab338d614da88029f51cb3bd6c2e?anonymousKey=9e9a56de56eb8ad48695d2e5dc7ca6c10c61284b) |
| MWC-11 | `certora/confs/callbacks/MidnightWithdrawableCallback/bystanderPositionUnchanged.conf` | [✅](https://prover.certora.com/output/2121305/62f69fc7858d4128ae46f7ee60c66e3f?anonymousKey=86e95bcddd3f0d4ed4306b08413948a332c4eb48) |
| MWC-12 | `certora/confs/callbacks/MidnightWithdrawableCallback/sellerPaidWithdrawableMinusSettlementFee.conf` | [✅](https://prover.certora.com/output/2121305/568957aabcbd4c2a9886e1af5c4e5d29?anonymousKey=02e89ab76dde1403db2a62e8cf2d2d14f4e8d689) |
| MWC-13 | `certora/confs/callbacks/MidnightWithdrawableCallback/perf_satisfy/positiveFillIsReachable.conf` | [✅](https://prover.certora.com/output/2121305/5b50c02efce64497ac42eed07092f4af?anonymousKey=a5189bf11e0b7f376a16bf6c2e97f91b7f49fd3f) |
