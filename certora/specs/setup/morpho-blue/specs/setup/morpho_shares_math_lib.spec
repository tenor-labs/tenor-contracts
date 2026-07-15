// ========== SharesMathLib CVL Summaries ==========
// Method summaries for SharesMathLib internal functions.
// Uses morphoMulDivDownCVL/morphoMulDivUpCVL from math_lib.spec.

import "morpho_math_lib.spec";

methods {
    function SharesMathLib.toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal returns (uint256)
        => toSharesDownCVL(assets, totalAssets, totalShares);
    function SharesMathLib.toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares)
        internal returns (uint256)
        => toAssetsDownCVL(shares, totalAssets, totalShares);
    function SharesMathLib.toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal returns (uint256)
        => toSharesUpCVL(assets, totalAssets, totalShares);
    function SharesMathLib.toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares)
        internal returns (uint256)
        => toAssetsUpCVL(shares, totalAssets, totalShares);
}

function toSharesDownCVL(uint256 assets, uint256 totalAssets, uint256 totalShares) returns uint256 {
    return morphoMulDivDownCVL(assets,
        require_uint256(to_mathint(totalShares) + 1000000),
        require_uint256(to_mathint(totalAssets) + 1));
}

function toAssetsDownCVL(uint256 shares, uint256 totalAssets, uint256 totalShares) returns uint256 {
    return morphoMulDivDownCVL(shares,
        require_uint256(to_mathint(totalAssets) + 1),
        require_uint256(to_mathint(totalShares) + 1000000));
}

function toSharesUpCVL(uint256 assets, uint256 totalAssets, uint256 totalShares) returns uint256 {
    return morphoMulDivUpCVL(assets,
        require_uint256(to_mathint(totalShares) + 1000000),
        require_uint256(to_mathint(totalAssets) + 1));
}

function toAssetsUpCVL(uint256 shares, uint256 totalAssets, uint256 totalShares) returns uint256 {
    return morphoMulDivUpCVL(shares,
        require_uint256(to_mathint(totalAssets) + 1),
        require_uint256(to_mathint(totalShares) + 1000000));
}

// --- Mathint helpers for spec assertions (no uint256 truncation) ---

function toSharesDownMathint(
    mathint assets, mathint totalAssets, mathint totalShares
) returns mathint {
    return (assets * (totalShares + VIRTUAL_SHARES_CVL()))
        / (totalAssets + VIRTUAL_ASSETS_CVL());
}

function toAssetsUpMathint(
    mathint shares, mathint totalAssets, mathint totalShares
) returns mathint {
    return (shares * (totalAssets + VIRTUAL_ASSETS_CVL())
        + (totalShares + VIRTUAL_SHARES_CVL()) - 1)
        / (totalShares + VIRTUAL_SHARES_CVL());
}
