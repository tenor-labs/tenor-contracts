// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BorrowBlueToMidnightCallback} from "@callbacks/BorrowBlueToMidnightCallback.sol";
import {IBorrowBlueToMidnightCallback} from "@callbacks/interfaces/IBorrowBlueToMidnightCallback.sol";
import {MarketParams, Id} from "@morphoBlue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morphoBlue/libraries/MarketParamsLib.sol";

contract BorrowBlueToMidnightCallbackHarness is BorrowBlueToMidnightCallback {
    using MarketParamsLib for MarketParams;

    constructor(address morphoMidnight, address morphoBlue)
        BorrowBlueToMidnightCallback(morphoMidnight, morphoBlue) {}

    // FV note: expose the source Blue market id and its irm decoded from the callback data so the
    // setup can re-bind id <-> marketParams (Morpho's id = keccak256(marketParams) + idToMarketParams
    // binding, lost under the harness's id()/storage abstraction). Used to require that the irm fed
    // to MORPHO_BLUE.repay equals the market's stored irm (ghostMbIrm[id]).
    function decodeCallbackSourceMarketId(bytes memory data) external pure returns (Id) {
        IBorrowBlueToMidnightCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowBlueToMidnightCallback.CallbackData));
        return cbd.sourceMarketParams.id();
    }

    function decodeCallbackSourceIrm(bytes memory data) external pure returns (address) {
        IBorrowBlueToMidnightCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowBlueToMidnightCallback.CallbackData));
        return cbd.sourceMarketParams.irm;
    }

    // FV note: expose the source Blue market's loanToken so a revert-characterization rule can assert the
    // onSell TokenMismatch guard (sourceMarketParams.loanToken != market.loanToken => revert).
    function decodeCallbackSourceLoanToken(bytes memory data) external pure returns (address) {
        IBorrowBlueToMidnightCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowBlueToMidnightCallback.CallbackData));
        return cbd.sourceMarketParams.loanToken;
    }

    function decodeCallbackFeeRecipient(bytes memory data) external pure returns (address) {
        IBorrowBlueToMidnightCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowBlueToMidnightCallback.CallbackData));
        return cbd.feeRecipient;
    }

    function decodeCallbackFeeRate(bytes memory data) external pure returns (uint256) {
        IBorrowBlueToMidnightCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowBlueToMidnightCallback.CallbackData));
        return cbd.feeRate;
    }

    function decodeCallbackTick(bytes memory data) external pure returns (uint256) {
        IBorrowBlueToMidnightCallback.CallbackData memory cbd =
            abi.decode(data, (IBorrowBlueToMidnightCallback.CallbackData));
        return cbd.tick;
    }
}
