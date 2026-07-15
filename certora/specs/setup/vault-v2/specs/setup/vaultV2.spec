// Commented for cross-protocol Tenor scenes: midnight supplies the env / ERC20
// models (identical ghost names). Re-enable for standalone vault-v2 runs.
// import "env.spec";
// import "erc20.spec";
import "vaultv2_safe_erc20.spec";
import "vaultv2_gates.spec";
import "vaultv2_adapters.spec";

using VaultV2Harness as _VaultV2;

methods {
    // Multicall: unbounded delegatecall loop; paths covered by direct method
    // calls. Removed from the scene.
    function _VaultV2.multicall(bytes[]) external => NONDET DELETE;

    // ── Envfree getters (pure storage reads / immutables) ────────────────────
    function _VaultV2.owner() external returns (address) envfree;
    function _VaultV2.curator() external returns (address) envfree;
    function _VaultV2.receiveSharesGate() external returns (address) envfree;
    function _VaultV2.sendSharesGate() external returns (address) envfree;
    function _VaultV2.receiveAssetsGate() external returns (address) envfree;
    function _VaultV2.sendAssetsGate() external returns (address) envfree;
    function _VaultV2.adapterRegistry() external returns (address) envfree;
    function _VaultV2.isSentinel(address) external returns (bool) envfree;
    function _VaultV2.isAllocator(address) external returns (bool) envfree;
    function _VaultV2.isAdapter(address) external returns (bool) envfree;
    function _VaultV2.adapters(uint256) external returns (address) envfree;
    function _VaultV2.adaptersLength() external returns (uint256) envfree;
    function _VaultV2.absoluteCap(bytes32) external returns (uint256) envfree;
    function _VaultV2.relativeCap(bytes32) external returns (uint256) envfree;
    function _VaultV2.allocation(bytes32) external returns (uint256) envfree;
    function _VaultV2.forceDeallocatePenalty(address) external returns (uint256) envfree;
    function _VaultV2.timelock(bytes4) external returns (uint256) envfree;
    function _VaultV2.abdicated(bytes4) external returns (bool) envfree;
    function _VaultV2.executableAt(bytes) external returns (uint256) envfree;
    function _VaultV2.performanceFee() external returns (uint96) envfree;
    function _VaultV2.performanceFeeRecipient() external returns (address) envfree;
    function _VaultV2.managementFee() external returns (uint96) envfree;
    function _VaultV2.managementFeeRecipient() external returns (address) envfree;
    function _VaultV2.maxRate() external returns (uint64) envfree;
    function _VaultV2.lastUpdate() external returns (uint64) envfree;
    function _VaultV2._totalAssets() external returns (uint128) envfree;
    function _VaultV2.totalSupply() external returns (uint256) envfree;
    function _VaultV2.balanceOf(address) external returns (uint256) envfree;
    function _VaultV2.allowance(address, address) external returns (uint256) envfree;
    function _VaultV2.nonces(address) external returns (uint256) envfree;
    function _VaultV2.liquidityAdapter() external returns (address) envfree;
    function _VaultV2.virtualShares() external returns (uint256) envfree;
    function _VaultV2.canSendShares(address) external returns (bool) envfree;
    function _VaultV2.canReceiveShares(address) external returns (bool) envfree;
    function _VaultV2.canSendAssets(address) external returns (bool) envfree;
    function _VaultV2.canReceiveAssets(address) external returns (bool) envfree;
}

definition EXCLUDED_FUNCTION_VA(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

// ── Boundaries / domain constants (mirror src/libraries/ConstantsLib.sol) ──

definition VV_WAD_CVL() returns mathint = 1000000000000000000;           // 1e18
definition SECONDS_PER_YEAR_CVL() returns mathint = 365 * 86400;      // 365 days = 31536000
// MAX_MAX_RATE = 200e16 / 365 days
definition MAX_MAX_RATE_CVL() returns mathint = 2000000000000000000 / SECONDS_PER_YEAR_CVL();
// MAX_PERFORMANCE_FEE = 0.5e18
definition MAX_PERFORMANCE_FEE_CVL() returns mathint = 500000000000000000;
// MAX_MANAGEMENT_FEE = 0.05e18 / 365 days
definition MAX_MANAGEMENT_FEE_CVL() returns mathint = 50000000000000000 / SECONDS_PER_YEAR_CVL();
// MAX_FORCE_DEALLOCATE_PENALTY = 0.02e18
definition MAX_FORCE_DEALLOCATE_PENALTY_CVL() returns mathint = 20000000000000000;

function setupBoundariesVaultV2() {
    require(to_mathint(_VaultV2.virtualShares()) >= 1
        && to_mathint(_VaultV2.virtualShares()) <= VV_WAD_CVL(),
        "SAFE: virtualShares = 10^decimalOffset in [1, 1e18]");
}

function setupVaultV2(env e) {
    setupEnv(e);
    setupBoundariesVaultV2();
    setupERC20();
    // Time monotonicity is outside the per-call model, so this stays a SAFE premise, not a proven invariant.
    require(ghostTvLastUpdate <= to_mathint(e.block.timestamp),
        "SAFE: lastUpdate <= block.timestamp (monotone time)");
}

// ── STORAGE MIRRORS: persistent ghost + paired Sload/Sstore hooks ──────────
// Sload: require(ghost == storage). Sstore: ghost = storage.

// ── ROLES STORAGE ─────────────────────────────────────────────────────────

// address owner  (constructor sets owner = _owner; no init_state constraint)
persistent ghost address ghostTvOwner;
hook Sload address val _VaultV2.owner {
    require(ghostTvOwner == val, "SAFE: sync owner");
}
hook Sstore _VaultV2.owner address val {
    ghostTvOwner = val;
}

// address curator
persistent ghost address ghostTvCurator {
    init_state axiom ghostTvCurator == 0;
}
hook Sload address val _VaultV2.curator {
    require(ghostTvCurator == val, "SAFE: sync curator");
}
hook Sstore _VaultV2.curator address val {
    ghostTvCurator = val;
}

// address receiveSharesGate
persistent ghost address ghostTvReceiveSharesGate {
    init_state axiom ghostTvReceiveSharesGate == 0;
}
hook Sload address val _VaultV2.receiveSharesGate {
    require(ghostTvReceiveSharesGate == val, "SAFE: sync receiveSharesGate");
}
hook Sstore _VaultV2.receiveSharesGate address val {
    ghostTvReceiveSharesGate = val;
}

// address sendSharesGate
persistent ghost address ghostTvSendSharesGate {
    init_state axiom ghostTvSendSharesGate == 0;
}
hook Sload address val _VaultV2.sendSharesGate {
    require(ghostTvSendSharesGate == val, "SAFE: sync sendSharesGate");
}
hook Sstore _VaultV2.sendSharesGate address val {
    ghostTvSendSharesGate = val;
}

// address receiveAssetsGate
persistent ghost address ghostTvReceiveAssetsGate {
    init_state axiom ghostTvReceiveAssetsGate == 0;
}
hook Sload address val _VaultV2.receiveAssetsGate {
    require(ghostTvReceiveAssetsGate == val, "SAFE: sync receiveAssetsGate");
}
hook Sstore _VaultV2.receiveAssetsGate address val {
    ghostTvReceiveAssetsGate = val;
}

// address sendAssetsGate
persistent ghost address ghostTvSendAssetsGate {
    init_state axiom ghostTvSendAssetsGate == 0;
}
hook Sload address val _VaultV2.sendAssetsGate {
    require(ghostTvSendAssetsGate == val, "SAFE: sync sendAssetsGate");
}
hook Sstore _VaultV2.sendAssetsGate address val {
    ghostTvSendAssetsGate = val;
}

// address adapterRegistry
persistent ghost address ghostTvAdapterRegistry {
    init_state axiom ghostTvAdapterRegistry == 0;
}
hook Sload address val _VaultV2.adapterRegistry {
    require(ghostTvAdapterRegistry == val, "SAFE: sync adapterRegistry");
}
hook Sstore _VaultV2.adapterRegistry address val {
    ghostTvAdapterRegistry = val;
}

// mapping(address => bool) isSentinel
persistent ghost mapping(address => bool) ghostTvIsSentinel {
    init_state axiom forall address a. ghostTvIsSentinel[a] == false;
}
hook Sload bool val _VaultV2.isSentinel[KEY address a] {
    require(ghostTvIsSentinel[a] == val, "SAFE: sync isSentinel");
}
hook Sstore _VaultV2.isSentinel[KEY address a] bool val {
    ghostTvIsSentinel[a] = val;
}

// mapping(address => bool) isAllocator
persistent ghost mapping(address => bool) ghostTvIsAllocator {
    init_state axiom forall address a. ghostTvIsAllocator[a] == false;
}
hook Sload bool val _VaultV2.isAllocator[KEY address a] {
    require(ghostTvIsAllocator[a] == val, "SAFE: sync isAllocator");
}
hook Sstore _VaultV2.isAllocator[KEY address a] bool val {
    ghostTvIsAllocator[a] = val;
}

// ── TOKEN STORAGE ───────────────────────────────────────────────────────────
// Vault share ledger mirrored into the SHARED ERC20 ghosts (ghostERC20TotalSupply256 /
// ghostERC20Balances128 / ghostERC20Allowances256), keyed by the vault address — the vault
// "as a token" reuses the scene's shared infra.
// NOTE: shared ghostERC20Balances128 is capped at max_uint128 (UNSAFE model cap);
// the Sload require_uint128 is consistent with that cap.

// uint256 totalSupply -> shared ghostERC20TotalSupply256[_VaultV2]
hook Sload uint256 val _VaultV2.totalSupply {
    require(require_uint256(ghostERC20TotalSupply256[_VaultV2]) == val, "SAFE: sync totalSupply (shared ghost)");
}
hook Sstore _VaultV2.totalSupply uint256 val {
    ghostERC20TotalSupply256[_VaultV2] = val;
}

// mapping(address => uint256) balanceOf -> shared ghostERC20Balances128[_VaultV2][a]
hook Sload uint256 val _VaultV2.balanceOf[KEY address a] {
    require(require_uint128(ghostERC20Balances128[_VaultV2][a]) == val, "SAFE: sync balanceOf (shared ghost)");
}
hook Sstore _VaultV2.balanceOf[KEY address a] uint256 val {
    // UNSAFE: every share holder is in the shared model's bounded account set.
    require(ERC20_ACCOUNT_BOUNDS(_VaultV2, a), "UNSAFE: share holder in bounded ERC20 account set");
    ghostERC20Balances128[_VaultV2][a] = val;
}

// Sum of shares over the shared model's bounded account set.
definition SHARE_SUM() returns mathint =
    ghostERC20Balances128[_VaultV2][ghostErc20AccountsValues[_VaultV2][0]]
    + ghostERC20Balances128[_VaultV2][ghostErc20AccountsValues[_VaultV2][1]]
    + ghostERC20Balances128[_VaultV2][ghostErc20AccountsValues[_VaultV2][2]]
    + ghostERC20Balances128[_VaultV2][ghostErc20AccountsValues[_VaultV2][3]]
    + ghostERC20Balances128[_VaultV2][ghostErc20AccountsValues[_VaultV2][4]];

// mapping(address => mapping(address => uint256)) allowance -> shared ghostERC20Allowances256
hook Sload uint256 val _VaultV2.allowance[KEY address o][KEY address s] {
    require(require_uint256(ghostERC20Allowances256[_VaultV2][o][s]) == val, "SAFE: sync allowance (shared ghost)");
}
hook Sstore _VaultV2.allowance[KEY address o][KEY address s] uint256 val {
    ghostERC20Allowances256[_VaultV2][o][s] = val;
}

// mapping(address => uint256) nonces — vault-specific, donor ghost kept
persistent ghost mapping(address => mathint) ghostTvNonces {
    init_state axiom forall address a. ghostTvNonces[a] == 0;
    axiom forall address a. ghostTvNonces[a] >= 0 && ghostTvNonces[a] <= max_uint256;
}
hook Sload uint256 val _VaultV2.nonces[KEY address a] {
    require(require_uint256(ghostTvNonces[a]) == val, "SAFE: sync nonces");
}
hook Sstore _VaultV2.nonces[KEY address a] uint256 val {
    ghostTvNonces[a] = val;
}

// ── INTEREST STORAGE ────────────────────────────────────────────────────────

// NOTE: `firstTotalAssets` is TRANSIENT storage (separate layout). Hooking it
// makes the Prover reject the run ("Requested variable not in storage layout"),
// so it is left unmirrored — not needed for the valid-state setup.

// uint128 _totalAssets
persistent ghost mathint ghostTvTotalAssets {
    init_state axiom ghostTvTotalAssets == 0;
    axiom ghostTvTotalAssets >= 0 && ghostTvTotalAssets <= max_uint128;
}
hook Sload uint128 val _VaultV2._totalAssets {
    require(require_uint128(ghostTvTotalAssets) == val, "SAFE: sync _totalAssets");
}
hook Sstore _VaultV2._totalAssets uint128 val {
    ghostTvTotalAssets = val;
}

// uint64 lastUpdate
persistent ghost mathint ghostTvLastUpdate {
    init_state axiom ghostTvLastUpdate == 0;
    axiom ghostTvLastUpdate >= 0 && ghostTvLastUpdate <= max_uint64;
}
hook Sload uint64 val _VaultV2.lastUpdate {
    require(require_uint64(ghostTvLastUpdate) == val, "SAFE: sync lastUpdate");
}
hook Sstore _VaultV2.lastUpdate uint64 val {
    ghostTvLastUpdate = val;
}

// uint64 maxRate
persistent ghost mathint ghostTvMaxRate {
    init_state axiom ghostTvMaxRate == 0;
    axiom ghostTvMaxRate >= 0 && ghostTvMaxRate <= max_uint64;
}
hook Sload uint64 val _VaultV2.maxRate {
    require(require_uint64(ghostTvMaxRate) == val, "SAFE: sync maxRate");
}
hook Sstore _VaultV2.maxRate uint64 val {
    ghostTvMaxRate = val;
}

// ── CURATION STORAGE ────────────────────────────────────────────────────────

// mapping(address => bool) isAdapter
persistent ghost mapping(address => bool) ghostTvIsAdapter {
    init_state axiom forall address a. ghostTvIsAdapter[a] == false;
}
hook Sload bool val _VaultV2.isAdapter[KEY address a] {
    require(ghostTvIsAdapter[a] == val, "SAFE: sync isAdapter");
}
hook Sstore _VaultV2.isAdapter[KEY address a] bool val {
    ghostTvIsAdapter[a] = val;
}

// address[] adapters -- length mirror
persistent ghost mathint ghostTvAdaptersLength {
    init_state axiom ghostTvAdaptersLength == 0;
    axiom ghostTvAdaptersLength >= 0 && ghostTvAdaptersLength <= max_uint256;
}
hook Sload uint256 len _VaultV2.adapters.length {
    require(require_uint256(ghostTvAdaptersLength) == len, "SAFE: sync adapters.length");
}
hook Sstore _VaultV2.adapters.length uint256 len {
    ghostTvAdaptersLength = len;
}

// address[] adapters -- element mirror
persistent ghost mapping(uint256 => address) ghostTvAdapters {
    init_state axiom forall uint256 i. ghostTvAdapters[i] == 0;
}
hook Sload address a _VaultV2.adapters[INDEX uint256 i] {
    require(ghostTvAdapters[i] == a, "SAFE: sync adapters[i]");
}
hook Sstore _VaultV2.adapters[INDEX uint256 i] address a {
    ghostTvAdapters[i] = a;
}

// mapping(bytes32 => Caps) caps — three sub-slots hooked separately.

// uint256 caps[id].allocation
persistent ghost mapping(bytes32 => mathint) ghostTvCapsAllocation {
    init_state axiom forall bytes32 id. ghostTvCapsAllocation[id] == 0;
    axiom forall bytes32 id. ghostTvCapsAllocation[id] >= 0 && ghostTvCapsAllocation[id] <= max_uint256;
}
hook Sload uint256 val _VaultV2.caps[KEY bytes32 id].allocation {
    require(require_uint256(ghostTvCapsAllocation[id]) == val, "SAFE: sync caps.allocation");
}
hook Sstore _VaultV2.caps[KEY bytes32 id].allocation uint256 val {
    ghostTvCapsAllocation[id] = val;
}

// uint128 caps[id].absoluteCap
persistent ghost mapping(bytes32 => mathint) ghostTvCapsAbsoluteCap {
    init_state axiom forall bytes32 id. ghostTvCapsAbsoluteCap[id] == 0;
    axiom forall bytes32 id. ghostTvCapsAbsoluteCap[id] >= 0 && ghostTvCapsAbsoluteCap[id] <= max_uint128;
}
hook Sload uint128 val _VaultV2.caps[KEY bytes32 id].absoluteCap {
    require(require_uint128(ghostTvCapsAbsoluteCap[id]) == val, "SAFE: sync caps.absoluteCap");
}
hook Sstore _VaultV2.caps[KEY bytes32 id].absoluteCap uint128 val {
    ghostTvCapsAbsoluteCap[id] = val;
}

// uint128 caps[id].relativeCap
persistent ghost mapping(bytes32 => mathint) ghostTvCapsRelativeCap {
    init_state axiom forall bytes32 id. ghostTvCapsRelativeCap[id] == 0;
    axiom forall bytes32 id. ghostTvCapsRelativeCap[id] >= 0 && ghostTvCapsRelativeCap[id] <= max_uint128;
}
hook Sload uint128 val _VaultV2.caps[KEY bytes32 id].relativeCap {
    require(require_uint128(ghostTvCapsRelativeCap[id]) == val, "SAFE: sync caps.relativeCap");
}
hook Sstore _VaultV2.caps[KEY bytes32 id].relativeCap uint128 val {
    ghostTvCapsRelativeCap[id] = val;
}

// mapping(address => uint256) forceDeallocatePenalty
persistent ghost mapping(address => mathint) ghostTvForceDeallocatePenalty {
    init_state axiom forall address a. ghostTvForceDeallocatePenalty[a] == 0;
    axiom forall address a.
        ghostTvForceDeallocatePenalty[a] >= 0 && ghostTvForceDeallocatePenalty[a] <= max_uint256;
}
hook Sload uint256 val _VaultV2.forceDeallocatePenalty[KEY address a] {
    require(require_uint256(ghostTvForceDeallocatePenalty[a]) == val,
        "SAFE: sync forceDeallocatePenalty");
}
hook Sstore _VaultV2.forceDeallocatePenalty[KEY address a] uint256 val {
    ghostTvForceDeallocatePenalty[a] = val;
}

// ── LIQUIDITY ADAPTER STORAGE ───────────────────────────────────────────────

// address liquidityAdapter
persistent ghost address ghostTvLiquidityAdapter {
    init_state axiom ghostTvLiquidityAdapter == 0;
}
hook Sload address val _VaultV2.liquidityAdapter {
    require(ghostTvLiquidityAdapter == val, "SAFE: sync liquidityAdapter");
}
hook Sstore _VaultV2.liquidityAdapter address val {
    ghostTvLiquidityAdapter = val;
}

// ── TIMELOCKS STORAGE ───────────────────────────────────────────────────────

// mapping(bytes4 => uint256) timelock
persistent ghost mapping(bytes4 => mathint) ghostTvTimelock {
    init_state axiom forall bytes4 sel. ghostTvTimelock[sel] == 0;
    axiom forall bytes4 sel. ghostTvTimelock[sel] >= 0 && ghostTvTimelock[sel] <= max_uint256;
}
hook Sload uint256 val _VaultV2.timelock[KEY bytes4 sel] {
    require(require_uint256(ghostTvTimelock[sel]) == val, "SAFE: sync timelock");
}
hook Sstore _VaultV2.timelock[KEY bytes4 sel] uint256 val {
    ghostTvTimelock[sel] = val;
}

// mapping(bytes4 => bool) abdicated
persistent ghost mapping(bytes4 => bool) ghostTvAbdicated {
    init_state axiom forall bytes4 sel. ghostTvAbdicated[sel] == false;
}
hook Sload bool val _VaultV2.abdicated[KEY bytes4 sel] {
    require(ghostTvAbdicated[sel] == val, "SAFE: sync abdicated");
}
hook Sstore _VaultV2.abdicated[KEY bytes4 sel] bool val {
    ghostTvAbdicated[sel] = val;
}

// ── FEES STORAGE ────────────────────────────────────────────────────────────

// uint96 performanceFee
persistent ghost mathint ghostTvPerformanceFee {
    init_state axiom ghostTvPerformanceFee == 0;
    axiom ghostTvPerformanceFee >= 0 && ghostTvPerformanceFee <= max_uint96;
}
hook Sload uint96 val _VaultV2.performanceFee {
    require(require_uint96(ghostTvPerformanceFee) == val, "SAFE: sync performanceFee");
}
hook Sstore _VaultV2.performanceFee uint96 val {
    ghostTvPerformanceFee = val;
}

// address performanceFeeRecipient
persistent ghost address ghostTvPerformanceFeeRecipient {
    init_state axiom ghostTvPerformanceFeeRecipient == 0;
}
hook Sload address val _VaultV2.performanceFeeRecipient {
    require(ghostTvPerformanceFeeRecipient == val, "SAFE: sync performanceFeeRecipient");
}
hook Sstore _VaultV2.performanceFeeRecipient address val {
    ghostTvPerformanceFeeRecipient = val;
}

// uint96 managementFee
persistent ghost mathint ghostTvManagementFee {
    init_state axiom ghostTvManagementFee == 0;
    axiom ghostTvManagementFee >= 0 && ghostTvManagementFee <= max_uint96;
}
hook Sload uint96 val _VaultV2.managementFee {
    require(require_uint96(ghostTvManagementFee) == val, "SAFE: sync managementFee");
}
hook Sstore _VaultV2.managementFee uint96 val {
    ghostTvManagementFee = val;
}

// address managementFeeRecipient
persistent ghost address ghostTvManagementFeeRecipient {
    init_state axiom ghostTvManagementFeeRecipient == 0;
}
hook Sload address val _VaultV2.managementFeeRecipient {
    require(ghostTvManagementFeeRecipient == val, "SAFE: sync managementFeeRecipient");
}
hook Sstore _VaultV2.managementFeeRecipient address val {
    ghostTvManagementFeeRecipient = val;
}
