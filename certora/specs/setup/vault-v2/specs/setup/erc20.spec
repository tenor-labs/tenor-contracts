// ========== ERC20 CVL Model ==========
// Bounded ERC20 ghost model for the VaultV2 underlying `asset` token:
//   - MAX_ERC20_USERS() distinct accounts per token (bounded set).
//   - balance / allowance / totalSupply / decimals ghosts keyed on calledContract.
//   - total-supply solvency assumption (sum of the bounded balances).
// VaultV2 reaches it via IERC20(asset).balanceOf/decimals and (redirected in
// safe_erc20.spec) SafeERC20Lib.safeTransfer/From.

methods {
    function _.balanceOf(address account) external
        => balanceOfERC20CVL(calledContract, account) expect uint256;

    function _.decimals() external
        => decimalsERC20CVL(calledContract) expect uint8;

    function _.totalSupply() external
        => totalSupplyERC20CVL(calledContract) expect uint256;

    function _.approve(address spender, uint256 amount) external with (env e)
        => approveERC20CVL(calledContract, e.msg.sender, spender, amount) expect bool;

    function _.transfer(address to, uint256 amount) external with (env e)
        => transferERC20CVL(calledContract, e.msg.sender, to, amount) expect bool;

    function _.transferFrom(address from, address to, uint256 amount) external with (env e)
        => transferFromERC20CVL(calledContract, e.msg.sender, from, to, amount) expect bool;

    function _.allowance(address owner, address spender) external
        => allowanceERC20CVL(calledContract, owner, spender) expect uint256;
}

// ========== BOUNDED ACCOUNT SET ==========

definition MAX_ERC20_USERS() returns mathint = 5;

// True when `account` is one of the bounded accounts of `token`.
definition ERC20_ACCOUNT_BOUNDS(address token, address account) returns bool =
    ghostErc20AccountsValues[token][0] == account
    || ghostErc20AccountsValues[token][1] == account
    || ghostErc20AccountsValues[token][2] == account
    || ghostErc20AccountsValues[token][3] == account
    || ghostErc20AccountsValues[token][4] == account
    ;

// MAX_ERC20_USERS() distinct accounts per token.
persistent ghost ghostErc20Accounts(address, mathint) returns address {
    // UNSAFE: injectivity -- all accounts in the bounded range are distinct.
    axiom forall address token. forall mathint i. forall mathint j.
        i >= 0 && i < MAX_ERC20_USERS()
        && j >= 0 && j < MAX_ERC20_USERS()
        && i != j
        => ghostErc20Accounts(token, i) != ghostErc20Accounts(token, j);
}

persistent ghost mapping (address => mapping (mathint => address)) ghostErc20AccountsValues {
    axiom forall address token. forall mathint i.
        ghostErc20AccountsValues[token][i] == ghostErc20Accounts(token, i);
    axiom forall address token. forall mathint i.
        (i >= 0 && i < MAX_ERC20_USERS())
        => ghostErc20AccountsValues[token][i] != 0;
}

// ========== HELPERS ==========

definition ERC20_TRANSFERRED(
    mathint senderBalanceBefore,
    mathint senderBalanceAfter,
    mathint receiverBalanceBefore,
    mathint receiverBalanceAfter
) returns bool =
    senderBalanceAfter < senderBalanceBefore
    && receiverBalanceAfter > receiverBalanceBefore
    && (senderBalanceBefore - senderBalanceAfter)
        == (receiverBalanceAfter - receiverBalanceBefore);

definition ERC20_TOTAL_SUPPLY_SOLVENCY() returns bool =
    forall address token.
        ghostERC20TotalSupply256[token]
        == ghostERC20Balances128[token][ghostErc20AccountsValues[token][0]]
        + ghostERC20Balances128[token][ghostErc20AccountsValues[token][1]]
        + ghostERC20Balances128[token][ghostErc20AccountsValues[token][2]]
        + ghostERC20Balances128[token][ghostErc20AccountsValues[token][3]]
        + ghostERC20Balances128[token][ghostErc20AccountsValues[token][4]];

// ========== SETUP ==========

function setupERC20() {
    require(ERC20_TOTAL_SUPPLY_SOLVENCY(),
        "SAFE: Assume total supply equals sum of all balances for ERC20 tokens");

    require(forall address token.
        ghostERC20Decimals8[token] >= 6 && ghostERC20Decimals8[token] <= 18,
        "SAFE: Assume realistic token decimals between 6 and 18");
}

// ========== GHOSTS ==========

persistent ghost mapping(address => uint8) ghostERC20Decimals8;

persistent ghost mapping(address => mapping(address => mathint)) ghostERC20Balances128 {
    init_state axiom forall address token. forall address account.
        ghostERC20Balances128[token][account] == 0;
    // UNSAFE: balance bounded by max_uint128 to avoid overflows.
    axiom forall address token. forall address account.
        ghostERC20Balances128[token][account] >= 0
        && ghostERC20Balances128[token][account] <= max_uint128;
}

persistent ghost mapping(address => mapping(address => mapping(address => mathint))) ghostERC20Allowances256 {
    init_state axiom forall address token. forall address owner. forall address spender.
        ghostERC20Allowances256[token][owner][spender] == 0;
    // SAFE: type-width bound (uint256).
    axiom forall address token. forall address owner. forall address spender.
        ghostERC20Allowances256[token][owner][spender] >= 0
        && ghostERC20Allowances256[token][owner][spender] <= max_uint256;
}

persistent ghost mapping(address => mathint) ghostERC20TotalSupply256 {
    init_state axiom forall address token. ghostERC20TotalSupply256[token] == 0;
    // SAFE: type-width bound (uint256).
    axiom forall address token. ghostERC20TotalSupply256[token] >= 0
        && ghostERC20TotalSupply256[token] <= max_uint256;
}

// Access tracking ghost (flags every account read/written during a call).
persistent ghost mapping(address => mapping(address => bool)) ghostERC20AccountAccessed {
    init_state axiom forall address token. forall address account.
        ghostERC20AccountAccessed[token][account] == false;
}

// ========== CVL FUNCTIONS ==========

function balanceOfERC20CVL(address token, address account) returns uint256 {
    require(token != 0, "SAFE: Assume called contract is not zero address");
    require(ERC20_ACCOUNT_BOUNDS(token, account),
        "UNSAFE: Assume account is within predefined account set");
    ghostERC20AccountAccessed[token][account] = true;
    return require_uint256(ghostERC20Balances128[token][account]);
}

function decimalsERC20CVL(address token) returns uint8 {
    require(token != 0, "SAFE: Assume called contract is not zero address");
    return require_uint8(ghostERC20Decimals8[token]);
}

function totalSupplyERC20CVL(address token) returns uint256 {
    require(token != 0, "SAFE: Assume called contract is not zero address");
    return require_uint256(ghostERC20TotalSupply256[token]);
}

function allowanceERC20CVL(address token, address owner, address spender) returns uint256 {
    require(token != 0, "SAFE: Assume called contract is not zero address");
    require(ERC20_ACCOUNT_BOUNDS(token, owner) && ERC20_ACCOUNT_BOUNDS(token, spender),
        "UNSAFE: Assume owner and spender are within predefined account set");
    return require_uint256(ghostERC20Allowances256[token][owner][spender]);
}

function approveERC20CVL(address token, address owner, address spender, uint256 amount) returns bool {
    require(token != 0, "SAFE: Assume called contract is not zero address");
    require(ERC20_ACCOUNT_BOUNDS(token, owner) && ERC20_ACCOUNT_BOUNDS(token, spender),
        "UNSAFE: Assume owner and spender are within predefined account set");
    ghostERC20Allowances256[token][owner][spender] = require_uint256(amount);
    return true;
}

function transferERC20CVL(address token, address from, address to, uint256 amount) returns bool {
    require(token != 0, "SAFE: Assume called contract is not zero address");
    require(ERC20_ACCOUNT_BOUNDS(token, from) && ERC20_ACCOUNT_BOUNDS(token, to),
        "UNSAFE: Assume from and to are within predefined account set");
    require(ghostERC20Balances128[token][from] >= amount, "ASSERT: InsufficientBalance");
    ghostERC20Balances128[token][from] = require_uint256(ghostERC20Balances128[token][from] - amount);
    ghostERC20Balances128[token][to] = require_uint256(ghostERC20Balances128[token][to] + amount);
    ghostERC20AccountAccessed[token][from] = true;
    ghostERC20AccountAccessed[token][to] = true;
    return true;
}

function transferFromERC20CVL(address token, address spender, address from, address to, uint256 amount) returns bool {
    require(token != 0, "SAFE: Assume called contract is not zero address");
    require(ERC20_ACCOUNT_BOUNDS(token, from) && ERC20_ACCOUNT_BOUNDS(token, to),
        "UNSAFE: Assume from and to are within predefined account set");
    require(ghostERC20Allowances256[token][from][spender] == max_uint256
        || ghostERC20Allowances256[token][from][spender] >= amount, "ASSERT: InsufficientAllowance");
    if (ghostERC20Allowances256[token][from][spender] != max_uint256) {
        ghostERC20Allowances256[token][from][spender]
            = require_uint256(ghostERC20Allowances256[token][from][spender] - amount);
    }
    require(ghostERC20Balances128[token][from] >= amount, "ASSERT: InsufficientBalance");
    ghostERC20Balances128[token][from] = require_uint256(ghostERC20Balances128[token][from] - amount);
    ghostERC20Balances128[token][to] = require_uint256(ghostERC20Balances128[token][to] + amount);
    ghostERC20AccountAccessed[token][from] = true;
    ghostERC20AccountAccessed[token][to] = true;
    return true;
}

function mintERC20CVL(address token, address to, uint256 amount) returns bool {
    require(token != 0, "SAFE: Assume called contract is not zero address");
    require(ERC20_ACCOUNT_BOUNDS(token, to), "UNSAFE: Assume to is within predefined account set");
    ghostERC20Balances128[token][to] = require_uint256(ghostERC20Balances128[token][to] + amount);
    ghostERC20TotalSupply256[token] = require_uint256(ghostERC20TotalSupply256[token] + amount);
    ghostERC20AccountAccessed[token][to] = true;
    return true;
}

function burnERC20CVL(address token, address from, uint256 amount) returns bool {
    require(token != 0, "SAFE: Assume called contract is not zero address");
    require(ERC20_ACCOUNT_BOUNDS(token, from), "UNSAFE: Assume from is within predefined account set");
    require(ghostERC20Balances128[token][from] >= amount, "ASSERT: InsufficientBalance");
    ghostERC20Balances128[token][from] = require_uint256(ghostERC20Balances128[token][from] - amount);
    ghostERC20TotalSupply256[token] = require_uint256(ghostERC20TotalSupply256[token] - amount);
    ghostERC20AccountAccessed[token][from] = true;
    return true;
}
