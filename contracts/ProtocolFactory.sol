//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ContractFactory} from "./ContractFactory.sol";
import {CCTCP_Host} from "./CCTCP_Host.sol";
import {CCHTTP_Peer} from "./CCHTTP_Peer.sol";


contract ProtocolFactory is ContractFactory{
    function deploy(
        address CCIP_Router,
        address LinkToken
    ){

    }
}