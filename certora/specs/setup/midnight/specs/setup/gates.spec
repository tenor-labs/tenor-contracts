// UNTRUSTED gate callbacks (canIncreaseCredit/Debt/Liquidate), summarized as recording
// CVL stubs. NONDET-equivalent: each gate is consulted at most once per external entry
// (take: one canIncreaseCredit + one canIncreaseDebt, src L397-406; liquidate: one
// canLiquidate, src L597-600; multicall is NONDET DELETE'd), so a single unconstrained
// persistent-ghost verdict per gate is adversarially identical to a fresh NONDET return.
// The recorder ghosts exist for the GT-MI-* rules (midnight_gates.spec); every other
// spec sees unchanged semantics.

persistent ghost bool ghostGateCanIncreaseCreditCalled;
persistent ghost address ghostGateCanIncreaseCreditCallee;
persistent ghost address ghostGateCanIncreaseCreditAccount;
persistent ghost bool ghostGateCanIncreaseCreditVerdict;

persistent ghost bool ghostGateCanIncreaseDebtCalled;
persistent ghost address ghostGateCanIncreaseDebtCallee;
persistent ghost address ghostGateCanIncreaseDebtAccount;
persistent ghost bool ghostGateCanIncreaseDebtVerdict;

persistent ghost bool ghostGateCanLiquidateCalled;
persistent ghost address ghostGateCanLiquidateCallee;
persistent ghost address ghostGateCanLiquidateAccount;
persistent ghost bool ghostGateCanLiquidateVerdict;

function canIncreaseCreditCVL(address callee, address account) returns bool {
    ghostGateCanIncreaseCreditCalled = true;
    ghostGateCanIncreaseCreditCallee = callee;
    ghostGateCanIncreaseCreditAccount = account;
    return ghostGateCanIncreaseCreditVerdict;
}

function canIncreaseDebtCVL(address callee, address account) returns bool {
    ghostGateCanIncreaseDebtCalled = true;
    ghostGateCanIncreaseDebtCallee = callee;
    ghostGateCanIncreaseDebtAccount = account;
    return ghostGateCanIncreaseDebtVerdict;
}

function canLiquidateCVL(address callee, address account) returns bool {
    ghostGateCanLiquidateCalled = true;
    ghostGateCanLiquidateCallee = callee;
    ghostGateCanLiquidateAccount = account;
    return ghostGateCanLiquidateVerdict;
}

methods {
    function _.canIncreaseCredit(address account) external
        => canIncreaseCreditCVL(calledContract, account) expect bool;
    function _.canIncreaseDebt(address account) external
        => canIncreaseDebtCVL(calledContract, account) expect bool;
    function _.canLiquidate(address account) external
        => canLiquidateCVL(calledContract, account) expect bool;
}
