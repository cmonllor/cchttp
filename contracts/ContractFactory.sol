//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract ContractFactory {
    function create2Contract(
        bytes memory bytecode,
        bytes32 salt
    ) internal returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
    }
}