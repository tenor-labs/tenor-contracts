// UtilsLib summaries: bit-counting, msb, transient storage, mulDiv arithmetic.

methods {
    function UtilsLib.countBits(uint128 x) internal returns (uint256)
        => countBitsCVL(x);

    function UtilsLib.msb(uint128 bitmap) internal returns (uint256)
        => msbCVL(bitmap);

    function UtilsLib.setBit(uint128 bitmap, uint256 bit) internal returns (uint128)
        => setBitCVL(bitmap, bit);

    function UtilsLib.clearBit(uint128 bitmap, uint256 bit) internal returns (uint128)
        => clearBitCVL(bitmap, bit);

    function UtilsLib.min(uint256 x, uint256 y) internal returns (uint256)
        => minCVL(x, y);

    function UtilsLib.zeroFloorSub(uint256 x, uint256 y) internal returns (uint256)
        => zeroFloorSubCVL(x, y);

    function UtilsLib.mulDivDown(uint256 x, uint256 y, uint256 d) internal returns (uint256)
        => mulDivDownCVL(x, y, d);

    function UtilsLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256)
        => mulDivUpCVL(x, y, d);

    function UtilsLib.toUint128(uint256 x) internal returns (uint128)
        => toUint128CVL(x);

    function UtilsLib.tExchange(uint256 baseSlot, bytes32 key1, address key2, bool value)
        internal returns (bool) => tExchangeCVL(baseSlot, key1, key2, value);

    function UtilsLib.tGet(uint256 baseSlot, bytes32 key1, address key2)
        internal returns (bool) => tGetCVL(baseSlot, key1, key2);
}

// Two-collateral narrowing: Prover picks ghostNumCollaterals once per rule.
//   1 → bit 0 only, bitmap ∈ {0, 1}
//   2 → bits 0,1,    bitmap ∈ {0..3}
// With loop_iter=2 the activated-collaterals loop unwinds fully.
persistent ghost uint256 ghostNumCollaterals {
    axiom ghostNumCollaterals == 1 || ghostNumCollaterals == 2;
}

definition VALID_COLLATERAL_BIT(uint256 i) returns bool =
    (ghostNumCollaterals == 1 && i == 0)
    || (ghostNumCollaterals == 2 && (i == 0 || i == 1));

definition VALID_COLLATERAL_BITMAP(mathint b) returns bool =
    (ghostNumCollaterals == 1 && b >= 0 && b < 2)
    || (ghostNumCollaterals == 2 && b >= 0 && b < 4);

persistent ghost countBitsGhost(uint256) returns uint256 {
    axiom countBitsGhost(0) == 0;
    axiom countBitsGhost(1) == 1;
    axiom countBitsGhost(2) == 1;
    axiom countBitsGhost(3) == 2;
    axiom forall uint256 x. countBitsGhost(x) <= 2;
}

function countBitsCVL(uint128 x) returns uint256 {
    require(VALID_COLLATERAL_BITMAP(to_mathint(x)),
        "ASSERT: bitmap valid for ghostNumCollaterals");
    return countBitsGhost(require_uint256(x));
}

// msb(0) unconstrained (callers must pass non-zero per natspec).
persistent ghost msbGhost(uint256) returns uint256 {
    axiom msbGhost(1) == 0;
    axiom msbGhost(2) == 1;
    axiom msbGhost(3) == 1;
    axiom forall uint256 x. msbGhost(x) <= 1;
}

function msbCVL(uint128 bitmap) returns uint256 {
    require(VALID_COLLATERAL_BITMAP(to_mathint(bitmap)),
        "ASSERT: bitmap valid for ghostNumCollaterals");
    return msbGhost(require_uint256(bitmap));
}

persistent ghost setBitGhost(uint256 /*bitmap*/, uint256 /*bit*/) returns uint256 {
    axiom setBitGhost(0, 0) == 1;
    axiom setBitGhost(0, 1) == 2;
    axiom setBitGhost(1, 0) == 1;
    axiom setBitGhost(1, 1) == 3;
    axiom setBitGhost(2, 0) == 3;
    axiom setBitGhost(2, 1) == 2;
    axiom setBitGhost(3, 0) == 3;
    axiom setBitGhost(3, 1) == 3;
    axiom forall uint256 b. forall uint256 i. setBitGhost(b, i) <= 3;
}

function setBitCVL(uint128 bitmap, uint256 bit) returns uint128 {
    require(VALID_COLLATERAL_BIT(bit),
        "ASSERT: bit valid for ghostNumCollaterals");
    require(VALID_COLLATERAL_BITMAP(to_mathint(bitmap)),
        "ASSERT: bitmap valid for ghostNumCollaterals");
    return require_uint128(setBitGhost(require_uint256(bitmap), bit));
}

persistent ghost clearBitGhost(uint256 /*bitmap*/, uint256 /*bit*/) returns uint256 {
    axiom clearBitGhost(0, 0) == 0;
    axiom clearBitGhost(0, 1) == 0;
    axiom clearBitGhost(1, 0) == 0;
    axiom clearBitGhost(1, 1) == 1;
    axiom clearBitGhost(2, 0) == 2;
    axiom clearBitGhost(2, 1) == 0;
    axiom clearBitGhost(3, 0) == 2;
    axiom clearBitGhost(3, 1) == 1;
    axiom forall uint256 b. forall uint256 i. clearBitGhost(b, i) <= 3;
}

function clearBitCVL(uint128 bitmap, uint256 bit) returns uint128 {
    require(VALID_COLLATERAL_BIT(bit),
        "ASSERT: bit valid for ghostNumCollaterals");
    require(VALID_COLLATERAL_BITMAP(to_mathint(bitmap)),
        "ASSERT: bitmap valid for ghostNumCollaterals");
    return require_uint128(clearBitGhost(require_uint256(bitmap), bit));
}

function minCVL(uint256 x, uint256 y) returns uint256 {
    return x < y ? x : y;
}

function zeroFloorSubCVL(uint256 x, uint256 y) returns uint256 {
    return x > y ? require_uint256(x - y) : 0;
}

function mulDivDownCVL(uint256 x, uint256 y, uint256 d) returns uint256 {
    require(d != 0, "ASSERT: mulDiv by zero");
    return require_uint256((to_mathint(x) * to_mathint(y)) / to_mathint(d));
}

function mulDivUpCVL(uint256 x, uint256 y, uint256 d) returns uint256 {
    require(d != 0, "ASSERT: mulDiv by zero");
    mathint num = to_mathint(x) * to_mathint(y);
    mathint q = num / to_mathint(d);
    mathint r = num - q * to_mathint(d);
    return require_uint256(r == 0 ? q : q + 1);
}

function toUint128CVL(uint256 x) returns uint128 {
    require(x <= max_uint128, "ASSERT: CastOverflow");
    return require_uint128(x);
}

// Keyed only by LIQUIDATION_LOCK_SLOT (add a baseSlot key if a second slot appears).
persistent ghost mapping(bytes32 => mapping(address => bool)) ghostMiLiquidationLock {
    init_state axiom forall bytes32 id. forall address u. !ghostMiLiquidationLock[id][u];
}

function tExchangeCVL(uint256 baseSlot, bytes32 key1, address key2, bool value) returns bool {
    bool previous = ghostMiLiquidationLock[key1][key2];
    ghostMiLiquidationLock[key1][key2] = value;
    return previous;
}

function tGetCVL(uint256 baseSlot, bytes32 key1, address key2) returns bool {
    return ghostMiLiquidationLock[key1][key2];
}
