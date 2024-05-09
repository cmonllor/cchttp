//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICCTCP_Consumer {
    //To be called from CCTCP Host
    function receiveMessage(
        uint64 origChainId,
        address linkToken,
        uint256 linkAmount,
        bytes memory origData
    ) external; 

    function sendMessage(
        uint64 destChain,
        address destHost,
        address origWallet,//where link will be refunded
        uint256 linkForAck,
        bytes memory data,
        address feeToken,
        uint256 feeAmount
    ) external;

    function retryMessage(
        uint64 destChain,
        address destHost,
        address origWallet,//where link will be refunded
        uint256 linkForAck,
        bytes memory data,
        address feeToken,
        uint256 feeAmount
    ) external;

    function getFeesForMessage(
        uint64 destChain,
        address destHost,
        uint256 linkForAck,
        bytes memory data,
        address feeToken
    ) external view returns (uint256 feeAmount);
}