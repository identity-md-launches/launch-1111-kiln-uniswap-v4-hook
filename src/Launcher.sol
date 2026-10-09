// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kiln} from "./Kiln.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Permissionlessly deploys one Kiln and opens its static-fee ETH/ZTO pool.
contract Launcher {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 public constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address public immutable zto;
    address public immutable pepeo;
    IPoolManager public immutable poolManager;
    Kiln public kiln;

    error InvalidAddress();
    error AlreadyOpened();
    error InvalidHookAddress(address hook);

    event Opened(address indexed kiln, PoolId indexed poolId);

    constructor(address zto_, address pepeo_, address poolManager_) {
        if (zto_ == address(0) || pepeo_ == address(0) || poolManager_ == address(0)) revert InvalidAddress();
        zto = zto_;
        pepeo = pepeo_;
        poolManager = IPoolManager(poolManager_);
    }

    function initCodeHash() external view returns (bytes32) {
        return keccak256(bytes.concat(type(Kiln).creationCode, abi.encode(zto, pepeo, address(poolManager))));
    }

    function open(bytes32 salt, uint160 sqrtPriceX96) external returns (Kiln deployed) {
        if (address(kiln) != address(0)) revert AlreadyOpened();
        deployed = new Kiln{salt: salt}(zto, pepeo, address(poolManager));
        if ((uint160(address(deployed)) & Hooks.ALL_HOOK_MASK) != REQUIRED_HOOK_FLAGS) {
            revert InvalidHookAddress(address(deployed));
        }
        kiln = deployed;
        PoolKey memory key = deployed.poolKey();
        PoolId poolId = key.toId();
        // v4 lets anyone initialize this key with the codeless predicted Kiln address (it has no
        // initialize bits), which would otherwise burn the salt for ever. Adopt such a pool
        // instead: it is empty, so its price is movable by a swap before liquidity is funded.
        (uint160 currentPrice,,,) = poolManager.getSlot0(poolId);
        if (currentPrice == 0) poolManager.initialize(key, sqrtPriceX96);
        emit Opened(address(deployed), poolId);
    }
}
