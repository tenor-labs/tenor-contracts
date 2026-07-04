// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IMorpho} from "@morphoBlue/interfaces/IMorpho.sol";
import {IBundler3, Call} from "@bundler3/interfaces/IBundler3.sol";

abstract contract Fixtures is Test {
    function deployMorphoBlue(address owner) internal returns (IMorpho) {
        return IMorpho(deployCode("test/bin/Morpho.json", abi.encode(owner)));
    }

    function deployBundler3() internal returns (IBundler3) {
        return IBundler3(deployCode("test/bin/Bundler3.json"));
    }

    function _call(address to, bytes memory data) internal pure returns (Call memory) {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }
}
