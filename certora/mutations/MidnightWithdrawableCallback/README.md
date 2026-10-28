# Mutations — `MidnightWithdrawableCallback` (`src/callbacks/MidnightWithdrawableCallback.sol`)

Each numbered file is the contract with **one** line broken; the listed rule caught it — it flipped to a counterexample on the mutant. Run the clean source first (`certoraRun <conf> --rule <rule>` → `VERIFIED`), then the mutant with `./certora/mutations/run_mutation.sh MidnightWithdrawableCallback <N>` (`VIOLATED` = killed).

| # | What we test | Caught by | Kill run |
|---|---|---|---|
| ✗ [1](1.sol) | maker check dropped: offers made by anyone else are ratified | [`isRatifiedOnlyAcceptsOwnParBuyOffer`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L15) (MWC-1) | [❌](https://prover.certora.com/output/2121305/634335b58e7e4338bb0b1264c04550cf?anonymousKey=987e1ee2a93a48cf4adbbdaa78c0bcb15141e619) |
| ✗ [2](2.sol) | callback check dropped: own offers without the onBuy withdraw are ratified | [`isRatifiedOnlyAcceptsOwnParBuyOffer`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L15) (MWC-1) | [❌](https://prover.certora.com/output/2121305/5fdc49768fa34124ba04cb042435e2c6?anonymousKey=31e47410221bb002f8eefa269cd55f89b908be5d) |
| ✗ [3](3.sol) | par check dropped: below-par ticks are ratified | [`isRatifiedOnlyAcceptsOwnParBuyOffer`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L15) (MWC-1) | [❌](https://prover.certora.com/output/2121305/706e6e204863490a817fc8580a757abd?anonymousKey=5ea9360262b908630f603d7c2a04bdbd5bb23786) |
| ✗ [4](4.sol) | Midnight-only guard dropped: anyone can call onBuy | [`onBuyRevertsForNonMidnightCaller`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L50) (MWC-3) | [❌](https://prover.certora.com/output/2121305/b3b17766c9d44dd3a15508fb670079c3?anonymousKey=66c8c2ddd2057dd639ad10c62773baf7545ef380) |
| ✗ [5](5.sol) | buyer guard dropped: foreign offers pointing their callback here reach the withdraw | [`onBuyRevertsForOtherBuyer`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L62) (MWC-4) | [❌](https://prover.certora.com/output/2121305/91f4cc3aca9b451cbc33b0b4d5dbe22b?anonymousKey=83829c01f131d05aa5b8e8152deae84d9f421c65) |
| ✗ [6](6.sol) | withdraws one unit short: the callback keeps 1 unit of credit after the fill | [`callbackPositionStaysZero`](../../specs/callbacks/MidnightWithdrawableCallback/many.spec#L6) (MWC-6) | [❌](https://prover.certora.com/output/2121305/7ab078ddad324ea18bfd696d0f29714d?anonymousKey=6f44c7235a602c1bfb6c165e5608b9dfa3f72043) |
| ✗ [7](7.sol) | approves one unit extra: the callback keeps a standing approval to Midnight | [`callbackKeepsZeroAllowance`](../../specs/callbacks/MidnightWithdrawableCallback/many.spec#L22) (MWC-7) | [❌](https://prover.certora.com/output/2121305/2960b344d9bc4b6a9229462e95c707b4?anonymousKey=ff36926924f8f16b4a7d673d7a829cc8eb157183) |
| ✗ [8](8.sol) | zero guard dropped: zero-unit fills reach the withdraw | [`onBuyRevertsOnZeroAssetsOrUnits`](../../specs/callbacks/MidnightWithdrawableCallback/standalone.spec#L79) (MWC-14) | [❌](https://prover.certora.com/output/2121305/2cacd90956a9481ca59a4d0b8bdd8c33?anonymousKey=def98cd70db9f234a9320f475bdc8a117c2817cf) |

## Clean runs

Every rule verified on the unmutated source (`MWC-13` is a `satisfy` witness).

| Properties | Conf | Run |
|---|---|---|
| MWC-1..5, MWC-14 | `certora/confs/callbacks/MidnightWithdrawableCallback/standalone.conf` | [✅](https://prover.certora.com/output/2121305/5f2dd0049f824047891e2e8967afd78a?anonymousKey=128c4d8a111cba9a3ccf888eb9fd5f7bb157c9b6) |
| MWC-6 | `certora/confs/callbacks/MidnightWithdrawableCallback/perf/callbackPositionStaysZero.conf` | [✅](https://prover.certora.com/output/2121305/cb70bf05062645ddb23614e376dfc3cf?anonymousKey=f17f732ec279588bd125785d749a44ee48c1744e) |
| MWC-7 | `certora/confs/callbacks/MidnightWithdrawableCallback/callbackKeepsZeroAllowance.conf` | [✅](https://prover.certora.com/output/2121305/579a64627aba41fe81c96b2c9cddeacc?anonymousKey=0ef6f70a67e0d5881ebcae937996e24ef40dd713) |
| MWC-8 | `certora/confs/callbacks/MidnightWithdrawableCallback/callbackBalanceUnchanged.conf` | [✅](https://prover.certora.com/output/2121305/8bc04a9fed29479b9e703ea9af102dd8?anonymousKey=89fdbd877d14f5c4178e461f7011ac67efad5a86) |
| MWC-9 | `certora/confs/callbacks/MidnightWithdrawableCallback/withdrawableDropsByUnits.conf` | [✅](https://prover.certora.com/output/2121305/32cf8a7db03c4d69801476e078e7deb2?anonymousKey=410106cdd1a16639dbd26a551882f42fe9554829) |
| MWC-10 | `certora/confs/callbacks/MidnightWithdrawableCallback/perf/takerPositionShiftsByUnits.conf` | [✅](https://prover.certora.com/output/2121305/1977dbdb68d748f39bb01cc3e091379e?anonymousKey=8642929ec0b02b1ff8404f851e3b94996bb6ac40) |
| MWC-11 | `certora/confs/callbacks/MidnightWithdrawableCallback/bystanderPositionUnchanged.conf` | [✅](https://prover.certora.com/output/2121305/db04385e5a3145a1936048310043a450?anonymousKey=9f63252808fb258ea8e3fe841673c725d924b7c6) |
| MWC-12 | `certora/confs/callbacks/MidnightWithdrawableCallback/sellerPaidWithdrawableMinusSettlementFee.conf` | [✅](https://prover.certora.com/output/2121305/426dce58d1bb43b69f9f8903cf486de5?anonymousKey=2d5b578b298baa53987acf265fde3b5c0901e66b) |
| MWC-13 | `certora/confs/callbacks/MidnightWithdrawableCallback/perf/positiveFillIsReachable.conf` | [✅](https://prover.certora.com/output/2121305/dd7d68602e404ca9b4fa975749784948?anonymousKey=9a85ffc970616f840a8509e6e7f8f841c3822d63) |
