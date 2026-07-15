// IdLib summaries: toId via parameterized ghost; storeInCode via non-zero address ghost.

methods {
    function IdLib.toId(MidnightHarness.Market memory market)
        internal returns (bytes32) with (env e) => idLibToIdCVL(e, market);

    function IdLib.storeInCode(MidnightHarness.Market memory market)
        internal returns (address) => idLibStoreInCodeCVL(market);
}

// No collision-resistance axiom -- Prover picks distinct ids freely. Rules that
// need uniqueness add an explicit require.
// chainId/midnight are now struct fields (market.chainId, market.midnight): toId hashes
// abi.encode(market) (incl. both) plus market.midnight, so the id is a pure function of the struct.
persistent ghost idLibToIdGhost(address /*loanToken*/, uint256 /*maturity*/, uint256 /*rcfThreshold*/,
                                  address /*enterGate*/, address /*liquidatorGate*/,
                                  uint256 /*chainId*/, address /*midnight*/) returns bytes32;

function idLibToIdCVL(env e, MidnightHarness.Market market)
    returns bytes32
{
    bytes32 id = idLibToIdGhost(
        market.loanToken,
        market.maturity,
        market.rcfThreshold,
        market.enterGate,
        market.liquidatorGate,
        market.chainId,
        market.midnight
    );
    // Wires market.collateralParams.length to the id-keyed ghost so
    // setupMidnight's narrowing on ghostMiMarketCollateralParamsLength applies.
    require(to_mathint(market.collateralParams.length) == ghostMiMarketCollateralParamsLength[id],
        "ghost mirror: market.collateralParams.length");
    // One-mode pin: every market flowing through toId shares the scalar
    // loanToken (touchMarket establishes this at creation; the summary doesn't
    // model creation, so we pin it here). Without this, claimContinuousFee
    // drains balance[loanToken] when market.loanToken aliases a collateralToken
    // -- breaks the ERC-20-backing invariants. Harmless when the scalar is 0
    // (initial state / many-mode where the scalar is unused).
    require(ghostMiOneMarketLoanToken == 0
         || market.loanToken == ghostMiOneMarketLoanToken,
        "UNSAFE: toId pins market.loanToken to ghostMiOneMarketLoanToken (one-mode)");
    // Many-mode pins: the real IdLib.toId hashes abi.encode(market) (the full
    // struct incl. collateralParams), so a struct resolving to an attributed id
    // carries that id's tokens. claimContinuousFee reaches toId without
    // touchMarket, so touchMarketCVL's stability requires alone cannot pin it.
    // Harmless when the attribution ghost is 0 or many-mode is off.
    require(!ghostMiManyModeActive
         || ghostMiMarketLoanToken[id] == 0
         || market.loanToken == ghostMiMarketLoanToken[id],
        "UNSAFE: toId pins market.loanToken to ghostMiMarketLoanToken[id] (many-mode)");
    require(!ghostMiManyModeActive
         || to_mathint(market.collateralParams.length) < 1
         || ghostMiMarketCollateralToken[id][0] == 0
         || market.collateralParams[0].token == ghostMiMarketCollateralToken[id][0],
        "UNSAFE: toId pins collateralParams[0].token to ghostMiMarketCollateralToken[id][0] (many-mode)");
    require(!ghostMiManyModeActive
         || to_mathint(market.collateralParams.length) < 2
         || ghostMiMarketCollateralToken[id][1] == 0
         || market.collateralParams[1].token == ghostMiMarketCollateralToken[id][1],
        "UNSAFE: toId pins collateralParams[1].token to ghostMiMarketCollateralToken[id][1] (many-mode)");
    // Mirror of touchMarket's MaturityTooFar gate (src L758): a CREATED market was admitted
    // at some past time T <= now with maturity <= T + 100*365 days, hence at every later call
    // maturity <= now + 100*365 days. Keeps continuousFee * timeToMaturity < WAD
    // (MAX_CONTINUOUS_FEE == floor(0.01e18 / 365 days)) — the boundary beyond which take's
    // buyer leg would mint pendingFee > credit (VS-MI-01). Untouched ids carry NO premise,
    // so the creation gate itself stays falsifiable in market_creation.conf (MC-MI-02).
    require(ghostMiOneMarketTickSpacing == 0
         || to_mathint(market.maturity) <= to_mathint(e.block.timestamp) + 3153600000,
        "TRUSTED: created-market maturity within touchMarket's 100-year horizon (one-mode)");
    require(!ghostMiManyModeActive
         || ghostMiMarketTickSpacing[id] == 0
         || to_mathint(market.maturity) <= to_mathint(e.block.timestamp) + 3153600000,
        "TRUSTED: created-market maturity within touchMarket's 100-year horizon (many-mode)");
    return id;
}

persistent ghost mapping(bytes32 => mathint) ghostMiMarketCollateralParamsLength {
    init_state axiom forall bytes32 id. ghostMiMarketCollateralParamsLength[id] == 0;
    axiom forall bytes32 id.
        ghostMiMarketCollateralParamsLength[id] >= 0
        && ghostMiMarketCollateralParamsLength[id] <= 128;
}

// Non-zero by axiom; no bijection with market id (Prover may pick any address).
persistent ghost idLibStoreInCodeGhost(address /*loanToken*/, uint256 /*maturity*/, uint256 /*rcfThreshold*/,
                                       address /*enterGate*/, address /*liquidatorGate*/) returns address {
    axiom forall address lt. forall uint256 m. forall uint256 r. forall address eg. forall address lg.
        idLibStoreInCodeGhost(lt, m, r, eg, lg) != 0;
}

// storeInCode uses a constant create2 salt (0); the deployed address only needs to be non-zero
// for the SStore2DeploymentFailed revert path, so the salt is not threaded into the ghost.
function idLibStoreInCodeCVL(MidnightHarness.Market market) returns address {
    return idLibStoreInCodeGhost(
        market.loanToken,
        market.maturity,
        market.rcfThreshold,
        market.enterGate,
        market.liquidatorGate
    );
}
