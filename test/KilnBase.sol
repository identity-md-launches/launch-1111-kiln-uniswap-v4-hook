// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Kiln} from "../src/Kiln.sol";
import {Launcher} from "../src/Launcher.sol";
import {MockZTO, MockPepeolithic} from "./mocks/TestTokens.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MockV4Router} from "@uniswap/v4-periphery/test/mocks/MockV4Router.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

abstract contract KilnBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant Q96 = 1 << 96;
    uint128 internal constant LIQUIDITY = 1000 ether;
    MockZTO internal token;
    MockPepeolithic internal nft;
    IPoolManager internal manager;
    Launcher internal launcher;
    Kiln internal kiln;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    MockV4Router internal peripheryRouter;
    PoolKey internal key;
    bytes32 internal salt;
    address internal trader;

    function setUp() public virtual {
        vm.chainId(11155111);
        trader = makeAddr("trader");
        token = new MockZTO();
        nft = new MockPepeolithic();
        manager = IPoolManager(address(new PoolManager(address(this))));
        launcher = new Launcher(address(token), address(nft), address(manager));
        salt = _mine(launcher);
        kiln = launcher.open(salt, Q96);
        key = kiln.poolKey();
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        peripheryRouter = new MockV4Router(manager);
        token.mint(address(this), 100_000 ether);
        token.mint(trader, 100_000 ether);
        token.approve(address(liquidityRouter), 100_000 ether);
        token.approve(address(kiln), 100_000 ether);
        vm.startPrank(trader);
        token.approve(address(swapRouter), 100_000 ether);
        token.approve(address(peripheryRouter), 100_000 ether);
        token.approve(address(kiln), 100_000 ether);
        nft.setApprovalForAll(address(kiln), true);
        vm.stopPrank();
        vm.deal(address(this), 100_000 ether);
        vm.deal(trader, 100_000 ether);
    }

    function _mine(Launcher target) internal view returns (bytes32 result) {
        bytes32 hash = target.initCodeHash();
        for (uint256 i;; ++i) {
            address predicted = _predict(address(target), bytes32(i), hash);
            if ((uint160(predicted) & 0x3fff) == 0xcc) return bytes32(i);
        }
    }

    function _predict(address deployer, bytes32 value, bytes32 hash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes.concat(hex"ff", bytes20(deployer), value, hash)))));
    }

    function _addLiquidity(int24 lower, int24 upper, int256 amount) internal returns (BalanceDelta) {
        return liquidityRouter.modifyLiquidity{value: 2000 ether}(
            key, ModifyLiquidityParams(lower, upper, amount, bytes32(0)), ""
        );
    }

    function _mintPass(uint256 pieces) internal {
        for (uint256 i; i < pieces; ++i) {
            nft.mint(trader, i);
        }
    }

    function _swap(bool ethIn, bool exactIn, uint256 amount) internal returns (BalanceDelta) {
        vm.prank(trader, trader);
        return swapRouter.swap{value: ethIn ? 100 ether : 0}(
            key,
            SwapParams(
                ethIn,
                exactIn ? -int256(amount) : int256(amount),
                ethIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _assertBacking() internal view {
        assertLe(kiln.reserve(), token.balanceOf(address(kiln)));
        assertEq(kiln.claims(), manager.balanceOf(address(kiln), uint256(uint160(address(token)))));
    }

    receive() external payable {}
}
