// UNTRUSTED ratifier. The source-side `require(... == CALLBACK_SUCCESS, RatifierFail())`
// in `take` prunes every non-revert path to the single ghost value that equals
// CALLBACK_SUCCESS, so we don't need to pin the return ourselves. `bytes data` is
// required empty to drop the symbolic dynamic-bytes argument from `take` calldata.

methods {
    function _.isRatified(MidnightHarness.Offer, bytes data, address) external
        => isRatifiedCVL(data) expect bytes32;
}

persistent ghost bytes32 ghostCallbackSuccess;

function isRatifiedCVL(bytes data) returns bytes32 {
    require(data.length == 0, "UNSAFE: empty ratifierData (take run tractability)");
    return ghostCallbackSuccess;
}
