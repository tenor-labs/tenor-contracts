// UNTRUSTED callback summaries. We do NOT model reentry; the post-call source
// code re-asserts CALLBACK_SUCCESS on every callback, constraining the
// return-value space rules see. Payload `bytes data` is opaque to Midnight
// (forwarded verbatim, never inspected), so we require it empty to remove the
// symbolic bytes argument from take / repay / liquidate / flash-loan calldata.

methods {
    function _.onBuy(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, bytes data) external
        => onBuyCVL(data) expect bytes32;
    function _.onSell(bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, address, bytes data) external
        => onSellCVL(data) expect bytes32;
    function _.onRepay(bytes32, MidnightHarness.Market, uint256, address, bytes data) external
        => onRepayCVL(data) expect bytes32;
    function _.onLiquidate(address, bytes32, MidnightHarness.Market, uint256, uint256, uint256, address, address, bytes data, uint256) external
        => onLiquidateCVL(data) expect bytes32;
    function _.onFlashLoan(address, address[], uint256[], bytes data) external
        => onFlashLoanCVL(data) expect bytes32;
}

// `persistent` pins the return across all call sites within one rule, so every
// callback invocation of the same kind returns the same bytes32.
persistent ghost bytes32 ghostOnBuyRet;
persistent ghost bytes32 ghostOnSellRet;
persistent ghost bytes32 ghostOnRepayRet;
persistent ghost bytes32 ghostOnLiquidateRet;
persistent ghost bytes32 ghostOnFlashLoanRet;

function onBuyCVL(bytes data) returns bytes32 {
    require(data.length == 0, "UNSAFE: empty callback payload (take run tractability)");
    return ghostOnBuyRet;
}

function onSellCVL(bytes data) returns bytes32 {
    require(data.length == 0, "UNSAFE: empty callback payload (take run tractability)");
    return ghostOnSellRet;
}

function onRepayCVL(bytes data) returns bytes32 {
    require(data.length == 0, "UNSAFE: empty callback payload (take run tractability)");
    return ghostOnRepayRet;
}

function onLiquidateCVL(bytes data) returns bytes32 {
    require(data.length == 0, "UNSAFE: empty callback payload (take run tractability)");
    return ghostOnLiquidateRet;
}

function onFlashLoanCVL(bytes data) returns bytes32 {
    require(data.length == 0, "UNSAFE: empty callback payload (take run tractability)");
    return ghostOnFlashLoanRet;
}
