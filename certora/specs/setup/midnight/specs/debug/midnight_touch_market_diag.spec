// Diagnostic: proves the touchMarket summary intercepts the EXTERNAL entry.
//
// touchMarket is public; its `internal` summary (setup/touch_market_summary.spec) therefore applies
// to external calls too, making the creation branch dead code in every summarized conf. This
// satisfy is the discriminator: under the summarized regime it must be UNSAT (the summary requires
// an already-touched market, contradicting the untouched pre-state) and the rule FAILS — that
// failure is the expected, documented confirmation of the hole. The live twin (MC-MI-01 in
// midnight_market_creation.spec, run without the summary) must PASS.

import "../midnight_valid_state_one.spec";
import "../setup/callbacks.spec";

// touchMarketCreatesDiag (diagnostic, satisfy, EXPECTED UNSAT): a harness self-check, not a protocol
// property. It asks the prover to exhibit an execution in which touchMarket (the entry point that
// creates a market) turns a never-created market — one whose tick spacing, the offer-price grid
// granularity, is still zero — into a created market with a nonzero tick spacing. Under this
// verification configuration touchMarket is replaced by a summary that only admits already-created
// markets, so no such execution can exist: the rule is deliberately expected to be UNSAT, and that
// reported failure is the confirmation that the summary intercepts external market creation, which
// must therefore be verified in a separate, unsummarized configuration.
// FORMULA: satisfy: exists execution of touchMarket(market).
//          tickSpacing[toId(market)] == 0 AND tickSpacing[toId(market)]' == 4
rule touchMarketCreatesDiag(env e, MidnightHarness.Market market) {
    setupOneMidnight(e);
    bytes32 id = toId(e, market);
    require(ghostMiMarketTickSpacing[id] == 0, "untouched market");

    touchMarket(e, market);

    satisfy(ghostMiMarketTickSpacing[id] == 4); // EXPECTED UNSAT under the summary
}
