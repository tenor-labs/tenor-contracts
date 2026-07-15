// TickLib summaries: monotone tick<->price ghosts narrowed to a five-tick model.

methods {
    function TickLib.tickToPrice(uint256 tick) internal returns (uint256)
        => tickToPriceCVL(tick);

    function TickLib.priceToTick(uint256 price, uint256 spacing) internal returns (uint256)
        => priceToTickCVL(price, spacing);

    function TickLib.wExp(int256 x) internal returns (uint256)
        => wExpCVL(x);

    function TickLib.divHalfDownUnchecked(uint256 x, uint256 d) internal returns (uint256)
        => divHalfDownUncheckedCVL(x, d);
}

// MAX_TICK = 6744; tickToPrice maps [0, MAX_TICK] → non-decreasing (1e11-rounded) uint256 price scaled 1e18.
definition MAX_TICK_CVL() returns mathint = 6744;
definition WAD_MATH() returns mathint = 1000000000000000000; // 1e18

// Five-tick narrowing: ghostNumTicks ∈ {1..5} picks how many ghostTick* values
// are active; strict ordering ghostTickOne < ... < ghostTickFive implies pairwise ≠.
persistent ghost uint256 ghostNumTicks {
    axiom ghostNumTicks == 1 || ghostNumTicks == 2 || ghostNumTicks == 3
        || ghostNumTicks == 4 || ghostNumTicks == 5;
}

persistent ghost uint256 ghostTickOne {
    axiom ghostTickOne <= MAX_TICK_CVL();
}

persistent ghost uint256 ghostTickTwo {
    axiom ghostTickTwo <= MAX_TICK_CVL();
    axiom ghostTickOne < ghostTickTwo;
}

persistent ghost uint256 ghostTickThree {
    axiom ghostTickThree <= MAX_TICK_CVL();
    axiom ghostTickTwo < ghostTickThree;
}

persistent ghost uint256 ghostTickFour {
    axiom ghostTickFour <= MAX_TICK_CVL();
    axiom ghostTickThree < ghostTickFour;
}

persistent ghost uint256 ghostTickFive {
    axiom ghostTickFive <= MAX_TICK_CVL();
    axiom ghostTickFour < ghostTickFive;
}

definition VALID_TICK(uint256 t) returns bool =
    (ghostNumTicks >= 1 && t == ghostTickOne)
    || (ghostNumTicks >= 2 && t == ghostTickTwo)
    || (ghostNumTicks >= 3 && t == ghostTickThree)
    || (ghostNumTicks >= 4 && t == ghostTickFour)
    || (ghostNumTicks >= 5 && t == ghostTickFive);

persistent ghost tickToPriceGhost(uint256) returns uint256 {
    axiom forall uint256 t. tickToPriceGhost(t) <= WAD_MATH();
    // Non-strict monotonicity: tickToPrice rounds to multiples of PRICE_ROUNDING_STEP (1e11),
    // so distinct ticks may collapse to an equal price (low-tick tail); mirrors the
    // ratifier-side tickPriceGhost.
    axiom tickToPriceGhost(ghostTickOne)   <= tickToPriceGhost(ghostTickTwo);
    axiom tickToPriceGhost(ghostTickTwo)   <= tickToPriceGhost(ghostTickThree);
    axiom tickToPriceGhost(ghostTickThree) <= tickToPriceGhost(ghostTickFour);
    axiom tickToPriceGhost(ghostTickFour)  <= tickToPriceGhost(ghostTickFive);
}

function tickToPriceCVL(uint256 tick) returns uint256 {
    require(tick <= MAX_TICK_CVL(), "ASSERT: TickOutOfRange");
    require(VALID_TICK(tick),
        "UNSAFE: tick ∈ {ghostTickOne..ghostTickFive} (five-tick narrowing)");
    return tickToPriceGhost(tick);
}

persistent ghost priceToTickGhost(uint256) returns uint256 {
    axiom forall uint256 p. priceToTickGhost(p) <= MAX_TICK_CVL();
    axiom forall uint256 p. VALID_TICK(priceToTickGhost(p));
}

// spacing only refines which ticks priceToTick may return; the five-tick model
// already constrains the result to the symbolic tick set, so spacing is unused.
function priceToTickCVL(uint256 price, uint256 spacing) returns uint256 {
    require(price <= WAD_MATH(), "ASSERT: PriceGreaterThanOne");
    return priceToTickGhost(price);
}

// wExp(x) = exp(x / 1e18) * 1e18; positive over the full int256 domain.
persistent ghost wExpGhost(int256) returns uint256 {
    axiom forall int256 x. wExpGhost(x) >= 1;
}

function wExpCVL(int256 x) returns uint256 {
    return wExpGhost(x);
}

function divHalfDownUncheckedCVL(uint256 x, uint256 d) returns uint256 {
    require(d != 0, "ASSERT: divHalfDown by zero");
    mathint half = (to_mathint(d) - 1) / 2;
    return require_uint256((to_mathint(x) + half) / to_mathint(d));
}
