//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract ContractFactory {

    function create2Contract(bytes32 salt, bytes memory _code) public {
        assembly{
            let contract := create2(0, add(_code, 0x20), mload(_code), salt)
            if iszero(contract) {
                revert(0, 0)
            }
            sstore(0x00, contract)
        }      
    }
}

