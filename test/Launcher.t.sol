// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./KilnBase.sol";
import {MineSalt} from "../script/MineSalt.s.sol";

contract LauncherTest is KilnBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function testOpenHasExactFlagsKeyAndNoLiquidity() public view {
        assertEq(address(kiln), _predict(address(launcher), salt, launcher.initCodeHash()));
        assertEq(uint160(address(kiln)) & 0x3fff, 0xcc);
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(token));
        assertEq(address(key.hooks), address(kiln));
        assertEq(key.fee, 2000);
        assertEq(key.tickSpacing, 60);
        (uint160 price, int24 tick,, uint24 fee) = manager.getSlot0(key.toId());
        assertEq(price, Q96);
        assertEq(tick, 0);
        assertEq(fee, 2000);
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertEq(token.balanceOf(address(manager)), 0);
    }

    function testCannotOpenTwice() public {
        vm.prank(trader);
        vm.expectRevert(Launcher.AlreadyOpened.selector);
        launcher.open(salt, Q96);
    }

    function testBadBitsRollBackDeploymentAndAllowRetry() public {
        Launcher fresh = new Launcher(address(token), address(nft), address(manager));
        bytes32 hash = fresh.initCodeHash();
        bytes32 badSalt;
        address predicted = _predict(address(fresh), badSalt, hash);
        while ((uint160(predicted) & 0x3fff) == 0xcc) {
            badSalt = bytes32(uint256(badSalt) + 1);
            predicted = _predict(address(fresh), badSalt, hash);
        }
        vm.expectRevert(abi.encodeWithSelector(Launcher.InvalidHookAddress.selector, predicted));
        fresh.open(badSalt, Q96);
        assertEq(predicted.code.length, 0);
        assertEq(address(fresh.kiln()), address(0));
        bytes32 goodSalt = _mine(fresh);
        address expected = _predict(address(fresh), goodSalt, hash);
        PoolKey memory expectedKey = key;
        expectedKey.hooks = IHooks(expected);
        vm.expectEmit(true, true, false, true, address(fresh));
        emit Launcher.Opened(expected, expectedKey.toId());
        vm.prank(trader);
        assertEq(address(fresh.open(goodSalt, Q96)), expected);
    }

    function testInvalidPriceRollsBackAndCanRetry() public {
        Launcher fresh = new Launcher(address(token), address(nft), address(manager));
        bytes32 goodSalt = _mine(fresh);
        vm.expectRevert();
        fresh.open(goodSalt, 0);
        assertEq(address(fresh.kiln()), address(0));
        fresh.open(goodSalt, Q96);
    }

    function testConstructorsWorkWithoutDependencyCodeAndDoNotValidateKilnBits() public {
        address ztoAddress = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        address pepeoAddress = address(bytes20(hex"0ce3157eac34eccdcff239738983976fabdefb2a"));
        address managerAddress = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        assertEq(ztoAddress.code.length + pepeoAddress.code.length + managerAddress.code.length, 0);
        Launcher fresh = new Launcher(ztoAddress, pepeoAddress, managerAddress);
        Kiln direct = new Kiln(ztoAddress, pepeoAddress, managerAddress);
        assertEq(fresh.zto(), ztoAddress);
        assertEq(address(direct.pepeo()), pepeoAddress);
        assertEq(address(direct.poolManager()), managerAddress);
        assertLt(address(direct).code.length, 12_000);
        assertLe(address(fresh).code.length, 24_576);
    }

    function testZTOOnlyRangeBelowOpeningTickAndETHOnlyAbove() public {
        BalanceDelta below = _addLiquidity(-1200, -60, int256(uint256(LIQUIDITY)));
        assertEq(below.amount0(), 0);
        assertLt(below.amount1(), 0);
        BalanceDelta above = _addLiquidity(60, 1200, int256(uint256(LIQUIDITY)));
        assertLt(above.amount0(), 0);
        assertEq(above.amount1(), 0);
        // No liquidity callbacks restrict either direction or subsequent removal.
        BalanceDelta removal = _addLiquidity(-1200, -60, -int256(uint256(LIQUIDITY)));
        assertEq(removal.amount0(), 0);
        assertGt(removal.amount1(), 0);
    }

    function testFirstZTOInputWorksWithNoZTOInManager() public {
        _addLiquidity(60, 1200, int256(uint256(LIQUIDITY)));
        assertEq(token.balanceOf(address(manager)), 0);
        _swap(false, true, 1 ether);
        assertEq(kiln.claims(), 0.013 ether);
        assertEq(token.balanceOf(address(kiln)), 0);
        kiln.collect();
        assertEq(kiln.reserve(), 0.013 ether);
        _assertBacking();
    }

    function testFirstETHInputFromZTOOnlyRange() public {
        _addLiquidity(-1200, -60, int256(uint256(LIQUIDITY)));
        assertEq(address(manager).balance, 0);
        _swap(true, true, 1 ether);
        assertGt(kiln.claims(), 0);
        kiln.collect();
        _assertBacking();
    }

    function testOfflineMinerMatchesLauncher() public {
        MineSalt miner = new MineSalt();
        (bytes32 found, address predicted) = miner.find(address(launcher), launcher.initCodeHash(), 0, 200_000);
        assertEq(found, salt);
        assertEq(predicted, address(kiln));
        bytes32 hash = launcher.initCodeHash();
        vm.expectRevert(MineSalt.SaltNotFound.selector);
        miner.find(address(launcher), hash, 0, 0);
    }

    function testApplicationBytecodeHasNoEscapeOpcodes() public view {
        _checkBytecode(address(kiln).code);
        _checkBytecode(address(launcher).code);
    }

    function _checkBytecode(bytes memory code) private pure {
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }
}
