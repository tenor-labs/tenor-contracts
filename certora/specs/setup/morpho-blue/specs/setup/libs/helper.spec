using HelperCVL as _HelperCVL;

methods {
    function _HelperCVL.assertOnFailure(bool success) external envfree;
}

// Trigger a Solidity assertion from CVL
function ASSERT(bool expression, string _message) {
    _HelperCVL.assertOnFailure(expression);
}
