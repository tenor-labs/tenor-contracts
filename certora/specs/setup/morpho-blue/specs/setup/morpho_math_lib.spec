// ========== MathLib CVL Summaries ==========
// Method summaries for MathLib internal functions.

methods {
    function MathLib.mulDivDown(uint256 x, uint256 y, uint256 d) internal returns (uint256)
        => morphoMulDivDownCVL(x, y, d);
    function MathLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256)
        => morphoMulDivUpCVL(x, y, d);
    function MathLib.wMulDown(uint256 x, uint256 y) internal returns (uint256)
        => wMulDownCVL(x, y);
    function MathLib.wDivDown(uint256 x, uint256 y) internal returns (uint256)
        => wDivDownCVL(x, y);
    function MathLib.wDivUp(uint256 x, uint256 y) internal returns (uint256)
        => wDivUpCVL(x, y);
    function MathLib.wTaylorCompounded(uint256 x, uint256 n) internal returns (uint256)
        => wTaylorCompoundedCVL(x, n);
}

function morphoMulDivDownCVL(uint256 x, uint256 y, uint256 d) returns uint256 {
    require(d != 0, "SAFE: mulDivDown denominator non-zero");
    return require_uint256((to_mathint(x) * to_mathint(y)) / to_mathint(d));
}

function morphoMulDivUpCVL(uint256 x, uint256 y, uint256 d) returns uint256 {
    require(d != 0, "SAFE: mulDivUp denominator non-zero");
    return require_uint256((to_mathint(x) * to_mathint(y) + (to_mathint(d) - 1)) / to_mathint(d));
}

function wMulDownCVL(uint256 x, uint256 y) returns uint256 {
    return morphoMulDivDownCVL(x, y, 1000000000000000000);
}

function wDivDownCVL(uint256 x, uint256 y) returns uint256 {
    return morphoMulDivDownCVL(x, 1000000000000000000, y);
}

function wDivUpCVL(uint256 x, uint256 y) returns uint256 {
    return morphoMulDivUpCVL(x, 1000000000000000000, y);
}

// e^(nx) - 1 approx: firstTerm + secondTerm + thirdTerm
function wTaylorCompoundedCVL(uint256 x, uint256 n) returns uint256 {
    mathint firstTerm = to_mathint(x) * to_mathint(n);
    mathint secondTerm = (firstTerm * firstTerm) / (2 * 1000000000000000000);
    mathint thirdTerm = (secondTerm * firstTerm) / (3 * 1000000000000000000);
    return require_uint256(firstTerm + secondTerm + thirdTerm);
}
