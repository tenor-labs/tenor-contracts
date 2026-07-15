// ERC-4626 core stub: shared asset() map for all callbacks.

methods {
    function _.asset() external
        => ghostERC4626Asset[calledContract] expect address;
}

persistent ghost mapping(address => address) ghostERC4626Asset {
    init_state axiom forall address vault.
        ghostERC4626Asset[vault] == 0;
}
