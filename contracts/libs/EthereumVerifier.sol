// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import "./CallDataRLPReader.sol";
import "../LBTC/ILBTC.sol";

library EthereumVerifier {

    bytes32 constant TOPIC_PEG_IN_BRIDGED = keccak256("DepositToBridge(uint256,address,address,address,address,uint256,uint256)");

    enum PegInType {
        None,
        Bridged
    }

    struct State {
        bytes32 receiptHash;
        address contractAddress;
        uint256 chainId;
        address fromAddress;
        address toAddress;
        address fromToken;
        address toToken;
        uint256 totalAmount;
        uint256 nonce;
    }

    function parseTransactionReceipt(uint256 receiptOffset)
        internal
        pure
        returns (State memory state, PegInType pegInType)
    {
        /* parse peg-in data from logs */
        uint256 iter = CallDataRLPReader.beginIteration(receiptOffset + 0x20);
        {
            /* postStateOrStatus - we must ensure that tx is not reverted */
            uint256 statusOffset = iter;
            iter = CallDataRLPReader.next(iter);
            require(
                CallDataRLPReader.payloadLen(
                    statusOffset,
                    iter - statusOffset
                ) == 1,
                "EthereumVerifier: tx is reverted"
            );
        }
        /* skip cumulativeGasUsed */
        iter = CallDataRLPReader.next(iter);
        /* logs - we need to find our logs */
        uint256 logs = iter;
        iter = CallDataRLPReader.next(iter);
        uint256 logsIter = CallDataRLPReader.beginIteration(logs);
        for (; logsIter < iter; ) {
            uint256 log = logsIter;
            logsIter = CallDataRLPReader.next(logsIter);
            /* make sure there is only one peg-in event in logs */
            PegInType logType = _decodeReceiptLogs(state, log);
            if (logType != PegInType.None) {
                require(
                    pegInType == PegInType.None,
                    "EthereumVerifier: multiple logs"
                );
                pegInType = logType;
            }
        }
        /* don't allow to process if peg-in type is unknown */
        require(pegInType != PegInType.None, "EthereumVerifier: missing logs");
        return (state, pegInType);
    }

    function _decodeReceiptLogs(State memory state, uint256 log)
        internal
        pure
        returns (PegInType pegInType)
    {
        uint256 logIter = CallDataRLPReader.beginIteration(log);
        address contractAddress;
        {
            /* parse smart contract address */
            uint256 addressOffset = logIter;
            logIter = CallDataRLPReader.next(logIter);
            contractAddress = CallDataRLPReader.toAddress(addressOffset);
        }
        /* topics */
        bytes32 mainTopic;
        address fromAddress;
        address toAddress;
        {
            uint256 topicsIter = logIter;
            logIter = CallDataRLPReader.next(logIter);
            // Must be 3 topics RLP encoded: event signature, fromAddress, toAddress
            // Each topic RLP encoded is 33 bytes (0xa0[32 bytes data])
            // Total payload: 99 bytes. Since it's list with total size bigger than 55 bytes we need 2 bytes prefix (0xf863)
            // So total size of RLP encoded topics array must be 101
            if (CallDataRLPReader.itemLength(topicsIter) != 101) {
                return PegInType.None;
            }
            topicsIter = CallDataRLPReader.beginIteration(topicsIter);
            mainTopic = bytes32(CallDataRLPReader.toUintStrict(topicsIter));
            topicsIter = CallDataRLPReader.next(topicsIter);
            fromAddress = address(
                bytes20(uint160(CallDataRLPReader.toUintStrict(topicsIter)))
            );
            topicsIter = CallDataRLPReader.next(topicsIter);
            toAddress = address(
                bytes20(uint160(CallDataRLPReader.toUintStrict(topicsIter)))
            );
            topicsIter = CallDataRLPReader.next(topicsIter);
            require(topicsIter == logIter); // safety check that iteration is finished
        }

        uint256 ptr = CallDataRLPReader.rawDataPtr(logIter);
        logIter = CallDataRLPReader.next(logIter);
        uint256 len = logIter - ptr;
        {
            // parse logs based on topic type and check that event data has correct length
            uint256 expectedLen;
            if (mainTopic == TOPIC_PEG_IN_BRIDGED) {
                expectedLen = 0xA0;
                pegInType = PegInType.Bridged;
            } else {
                return PegInType.None;
            }
            if (len != expectedLen) {
                return PegInType.None;
            }
        }
        {
            // read chain id separately and verify that contract that emitted event is relevant
            uint256 chainId;
            assembly {
                chainId := calldataload(ptr)
            }
            // All checks are passed after this point, no errors allowed and we can modify state
            state.chainId = chainId;
            ptr += 0x20;
            len -= 0x20;
        }

        {
            uint256 structOffset;
            assembly {
                // skip 5 fields: receiptHash, contractAddress, chainId, fromAddress, toAddress
                structOffset := add(state, 0xa0)
                calldatacopy(structOffset, ptr, len)
            }
        }
        state.contractAddress = contractAddress;
        state.fromAddress = fromAddress;
        state.toAddress = toAddress;
        return pegInType;
    }
}
