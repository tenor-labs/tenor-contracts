// touchMarket summary.
//
// touchMarket is PUBLIC: per Certora semantics an `internal` summary intercepts the external ABI
// entry too (the compiler-generated wrapper calls the summarized internal implementation), so under
// this import the market-creation branch (src/Midnight.sol: chainId/midnight/maturity/collateral-
// list/enabled-lltv/enabled-cursor/maxLif validation, tickSpacing := DEFAULT_TICK_SPACING,
// default-fee copy-down, storeInCode) is DEAD CODE — touchMarketCVL models only already-touched
// markets.
//
// Every one-/many-regime setup imports this file, deliberately keeping creation out of scope there;
// creation itself is verified in market_creation.conf (midnight_market_creation.spec), which imports
// setup/midnight.spec directly and never loads this summary.

methods {
    function MidnightHarness.touchMarket(MidnightHarness.Market memory market)
        internal returns (bytes32) with (env e) => touchMarketCVL(e, market);
}
