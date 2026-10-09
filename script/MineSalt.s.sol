// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Offline salt miner. Uses Launcher.initCodeHash(), never keys or broadcasts.
contract MineSalt {
    error SaltNotFound();

    function find(address launcher, bytes32 initCodeHash, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(bytes.concat(hex"ff", bytes20(launcher), salt, initCodeHash)))));
            if ((uint160(predicted) & 0x3fff) == 0xcc) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
