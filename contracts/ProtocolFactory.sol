//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ContractFactory} from "./ContractFactory.sol";
import {CCTCP_Host} from "./CCTCP_Host.sol";
import {CCHTTP_Peer} from "./CCHTTP_Peer.sol";


contract ProtocolFactory is ContractFactory{
    function deploy(
        address CCIP_Router,
        address LinkToken,
        uint64 chainId
    ) internal {


        bytes memory bytecode = type(CCHTTP_PEER).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(tx.origin, abi.encode("CCHTTP")));
        address dappLayerAddress = create2Contract(bytecode, salt);
        CCHTTP_Peer(dappLayerAddress).initialize(CCIP_Router, LinkToken, chainId);

        bytecode = type(CCTCP_Host).creationCode;
        salt = keccak256(  abi.encodePacked( tx.origin, abi.encode("CCTCP") )  );

    }
}