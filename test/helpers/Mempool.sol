// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

contract Mempool {
    event Log(bytes data) anonymous;

    fallback() external payable {
        emit Log(msg.data);
    }
}
