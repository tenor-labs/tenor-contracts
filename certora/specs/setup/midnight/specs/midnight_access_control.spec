// Access-control rules for Midnight (one-market regime).
//
// Parametric (method f, calldataarg args) rules asserting on STATE CHANGE => role / authorization --
// the P3/P2/P4 patterns. Robust to renamed/second setters and unintended-role writes that a selector-
// anchored revert rule would miss. Complementary to the RV-MI revert rules (the dual: a wrong caller
// reverts). Midnight uses ADDRESS roles, so the check is `e.msg.sender == ghostMi<Role>` (no RolesLib
// bitmap, no view-getter, no selectors).
//
// NOTE: per-user POSITION integrity (P1/P6) is intentionally NOT covered -- Midnight lets non-owners
// mutate a position by design (take counterparty, any liquidator, lazy slash), so "third party cannot
// touch position[u]" is false by design. The onBehalf-gated entry points are covered by RV-MI-10..15.
// The only clean per-user access-control property is the authorization graph (AC-MI-11).

import "midnight_valid_state_one.spec";

//
// Role management -- the four role addresses rotate only via the current configurator (P3)
//

// AC-MI-01: the configurator is the protocol's governance admin, the address that appoints every other
// role. No matter which function is called, the configurator address can only be rotated by the current
// configurator itself, so protocol governance cannot be hijacked by any other caller.
// FORMULA: forall f. configurator' != configurator => e.msg.sender == configurator
rule onlyConfiguratorChangesConfigurator(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    address configuratorBefore = ghostMiConfigurator;
    f(e, args);
    assert(ghostMiConfigurator != configuratorBefore => e.msg.sender == configuratorBefore,
        "configurator changes only when the caller is the current configurator");
}

// AC-MI-02: the feeSetter is the role that configures the protocol's fee rates. Across every entry
// point, the feeSetter address can only be replaced when the caller is the current configurator
// (governance), so no other party can install a fee-setting authority.
// FORMULA: forall f. feeSetter' != feeSetter => e.msg.sender == configurator
rule onlyConfiguratorChangesFeeSetter(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    address configuratorBefore = ghostMiConfigurator;
    address feeSetterBefore = ghostMiFeeSetter;
    f(e, args);
    assert(ghostMiFeeSetter != feeSetterBefore => e.msg.sender == configuratorBefore,
        "feeSetter changes only when the caller is the configurator");
}

// AC-MI-03: the feeClaimer is the only role allowed to withdraw the protocol's accrued fee revenue.
// Across every entry point, the feeClaimer address can only be replaced when the caller is the
// current configurator (governance), so no other party can redirect fee revenue to itself.
// FORMULA: forall f. feeClaimer' != feeClaimer => e.msg.sender == configurator
rule onlyConfiguratorChangesFeeClaimer(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    address configuratorBefore = ghostMiConfigurator;
    address feeClaimerBefore = ghostMiFeeClaimer;
    f(e, args);
    assert(ghostMiFeeClaimer != feeClaimerBefore => e.msg.sender == configuratorBefore,
        "feeClaimer changes only when the caller is the configurator");
}

// AC-MI-04: the tickSpacingSetter is the role that controls the granularity of the price grid on
// which borrower offers are placed. Across every entry point, the tickSpacingSetter address can only
// be replaced when the caller is the current configurator (governance).
// FORMULA: forall f. tickSpacingSetter' != tickSpacingSetter => e.msg.sender == configurator
rule onlyConfiguratorChangesTickSpacingSetter(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    address configuratorBefore = ghostMiConfigurator;
    address tickSpacingSetterBefore = ghostMiTickSpacingSetter;
    f(e, args);
    assert(ghostMiTickSpacingSetter != tickSpacingSetterBefore => e.msg.sender == configuratorBefore,
        "tickSpacingSetter changes only when the caller is the configurator");
}

//
// Fee configuration -- only the feeSetter (P3)
//

// AC-MI-05: the default settlement-fee schedule is the per-loan-token table of trade fees (one bucket
// per time-to-maturity band) that newly created markets inherit; settlement fees are charged on every
// trade and accumulate into the protocol's claimable fee pot. Across every entry point, a default
// settlement-fee bucket can only change when the caller is the feeSetter, so nobody else can raise
// fees on traders or zero out protocol revenue.
// FORMULA: forall f. defaultSettlementFeeCbp[token][index]' != defaultSettlementFeeCbp[token][index]
//          => e.msg.sender == feeSetter'
rule onlyFeeSetterChangesDefaultSettlementFee(env e, method f, calldataarg args, address token, uint256 index)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    mathint before = ghostMiDefaultSettlementFeeCbp16[token][index];
    f(e, args);
    assert(ghostMiDefaultSettlementFeeCbp16[token][index] != before => e.msg.sender == ghostMiFeeSetter,
        "defaultSettlementFeeCbp changes only when the caller is the feeSetter");
}

// AC-MI-06: the default continuous fee is the per-loan-token rate at which borrower debt accrues fee
// units to the protocol over time; newly created markets inherit it. Across every entry point, it can
// only change when the caller is the feeSetter, so nobody else can reprice the cost of borrowing.
// FORMULA: forall f. defaultContinuousFee[token]' != defaultContinuousFee[token]
//          => e.msg.sender == feeSetter'
rule onlyFeeSetterChangesDefaultContinuousFee(env e, method f, calldataarg args, address token)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    mathint before = ghostMiDefaultContinuousFee32[token];
    f(e, args);
    assert(ghostMiDefaultContinuousFee32[token] != before => e.msg.sender == ghostMiFeeSetter,
        "defaultContinuousFee changes only when the caller is the feeSetter");
}

// AC-MI-07: a live market carries seven settlement-fee buckets that determine the trade fee charged
// on take() fills (the take() trade entry point, where a buyer fills a maker's offer) by time to
// maturity. Across every entry point, if any of the seven buckets changes, the caller must be the
// feeSetter -- nobody else can reprice trading fees on an existing market.
// FORMULA: forall f. (exists i in 0..6. settlementFeeCbp_i' != settlementFeeCbp_i)
//          => e.msg.sender == feeSetter'
rule onlyFeeSetterChangesMarketSettlementFee(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    mathint b0 = ghostMiOneMarketSettlementFeeCbp0_16;
    mathint b1 = ghostMiOneMarketSettlementFeeCbp1_16;
    mathint b2 = ghostMiOneMarketSettlementFeeCbp2_16;
    mathint b3 = ghostMiOneMarketSettlementFeeCbp3_16;
    mathint b4 = ghostMiOneMarketSettlementFeeCbp4_16;
    mathint b5 = ghostMiOneMarketSettlementFeeCbp5_16;
    mathint b6 = ghostMiOneMarketSettlementFeeCbp6_16;
    f(e, args);
    bool anyChanged =
        ghostMiOneMarketSettlementFeeCbp0_16 != b0 || ghostMiOneMarketSettlementFeeCbp1_16 != b1
        || ghostMiOneMarketSettlementFeeCbp2_16 != b2 || ghostMiOneMarketSettlementFeeCbp3_16 != b3
        || ghostMiOneMarketSettlementFeeCbp4_16 != b4 || ghostMiOneMarketSettlementFeeCbp5_16 != b5
        || ghostMiOneMarketSettlementFeeCbp6_16 != b6;
    assert(anyChanged => e.msg.sender == ghostMiFeeSetter,
        "a market settlementFeeCbp bucket changes only when the caller is the feeSetter");
}

// AC-MI-08: a live market's continuous fee is the rate at which outstanding borrower debt accrues fee
// units to the protocol over time. Across every entry point, it can only change when the caller is
// the feeSetter, so nobody else can change what borrowers pay on an existing market.
// FORMULA: forall f. continuousFee' != continuousFee => e.msg.sender == feeSetter'
rule onlyFeeSetterChangesMarketContinuousFee(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    mathint before = ghostMiOneMarketContinuousFee32;
    f(e, args);
    assert(ghostMiOneMarketContinuousFee32 != before => e.msg.sender == ghostMiFeeSetter,
        "the market continuousFee changes only when the caller is the feeSetter");
}

//
// Tick spacing -- only the tickSpacingSetter (P3)
//

// AC-MI-09: tick spacing is the granularity of the price grid on which borrower offers may sit in a
// market. Across every entry point, the market's tick spacing can only change when the caller is the
// tickSpacingSetter, so nobody else can alter where offers may be priced.
// FORMULA: forall f. tickSpacing' != tickSpacing => e.msg.sender == tickSpacingSetter'
rule onlyTickSpacingSetterChangesTickSpacing(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    mathint before = ghostMiOneMarketTickSpacing;
    f(e, args);
    assert(ghostMiOneMarketTickSpacing != before => e.msg.sender == ghostMiTickSpacingSetter,
        "the market tickSpacing changes only when the caller is the tickSpacingSetter");
}

//
// Fee pot -- only the feeClaimer can drain it (P3 directional)
//

// AC-MI-10: claimableSettlementFee[token] is the per-token pot of trade fees owed to the protocol;
// trading only adds to it. Across every entry point, the pot can only decrease -- i.e. fee revenue
// can only be paid out -- when the caller is the feeClaimer, so nobody else can drain protocol fees.
// FORMULA: forall f. claimableSettlementFee[token]' < claimableSettlementFee[token]
//          => e.msg.sender == feeClaimer'
rule onlyFeeClaimerDrainsClaimableSettlementFee(env e, method f, calldataarg args, address token)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    mathint before = ghostMiClaimableSettlementFee256[token];
    f(e, args);
    assert(ghostMiClaimableSettlementFee256[token] < before => e.msg.sender == ghostMiFeeClaimer,
        "the settlement-fee pot decreases only when the caller is the feeClaimer");
}

//
// Authorization graph (P2)
//

// AC-MI-11: a user `a` may delegate management of their positions to another address through the
// authorization graph (isAuthorized). The delegation flag isAuthorized[a][b] can only be flipped by
// `a` itself or by an address that `a` had already authorized before the call -- a third party can
// never grant itself (or anyone else) control over a's funds.
// FORMULA: forall f. isAuthorized[a][b]' != isAuthorized[a][b]
//          => (e.msg.sender == a OR isAuthorized[a][e.msg.sender])
rule onlyAuthorizerChangesAuthorization(env e, method f, calldataarg args, address a, address b)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    bool before = ghostMiIsAuthorized[a][b];
    bool senderIsDelegateOfA = ghostMiIsAuthorized[a][e.msg.sender];
    f(e, args);
    assert(ghostMiIsAuthorized[a][b] != before => (e.msg.sender == a || senderIsDelegateOfA),
        "isAuthorized[a][*] changes only via `a` or a's existing delegate (no third-party escalation)");
}

//
// Governance-enabled LLTV tiers and liquidation cursors -- only the configurator (P3)
//

// AC-MI-12: the set of enabled LLTV tiers (the loan-to-liquidation thresholds at which markets may be
// created) is governance-controlled. Across every entry point, an LLTV tier's enabled flag can only
// change when the caller is the configurator, so nobody else can widen the borrowable-risk surface.
// FORMULA: forall f, lltv. isLltvEnabled[lltv]' != isLltvEnabled[lltv] => e.msg.sender == configurator
rule onlyConfiguratorChangesLltvEnabled(env e, method f, calldataarg args, uint256 lltv)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    bool before = ghostMiIsLltvEnabled[lltv];
    f(e, args);
    assert(ghostMiIsLltvEnabled[lltv] != before => e.msg.sender == ghostMiConfigurator,
        "isLltvEnabled[lltv] changes only when the caller is the configurator");
}

// AC-MI-13: the set of enabled liquidation cursors (which fix each collateral's maxLif at market
// creation) is governance-controlled. Across every entry point, a cursor's enabled flag can only
// change when the caller is the configurator.
// FORMULA: forall f, cursor. isLiquidationCursorEnabled[cursor]' != isLiquidationCursorEnabled[cursor]
//          => e.msg.sender == configurator
rule onlyConfiguratorChangesLiquidationCursorEnabled(env e, method f, calldataarg args, uint256 cursor)
    filtered { f -> !EXCLUDED_FUNCTION(f) } {
    setupValidStateOneMidnight(e);
    bool before = ghostMiIsLiquidationCursorEnabled[cursor];
    f(e, args);
    assert(ghostMiIsLiquidationCursorEnabled[cursor] != before => e.msg.sender == ghostMiConfigurator,
        "isLiquidationCursorEnabled[cursor] changes only when the caller is the configurator");
}
