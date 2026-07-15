// Block-environment bounds and same-env helper shared across all run configs.

definition MIN_BLOCK_TIMESTAMP() returns mathint = max_uint16;
definition MAX_BLOCK_TIMESTAMP() returns mathint = max_uint32;

function setupEnv(env e) {
    require(e.msg.value == 0, "SAFE: no ETH");
    require(e.msg.sender != 0 && e.msg.sender != currentContract, "SAFE: valid sender");
    require(e.block.timestamp >= MIN_BLOCK_TIMESTAMP() && e.block.timestamp < MAX_BLOCK_TIMESTAMP(),
        "SAFE: realistic timestamp bounds");
    require(e.block.number != 0, "SAFE: non-zero block");
}

function requireSameEnv(env e1, env e2) {
    require(e1.block.number == e2.block.number, "SAFE: same block number");
    require(e1.block.timestamp == e2.block.timestamp, "SAFE: same timestamp");
    require(e1.msg.sender == e2.msg.sender, "SAFE: same sender");
    require(e1.msg.value == e2.msg.value, "SAFE: same msg.value");
}
