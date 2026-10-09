// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./KilnBase.sol";

contract SwapsTest is KilnBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _addLiquidity(-60000, 60000, int256(uint256(LIQUIDITY)));
    }

    function testAllFourCasesAtEveryTier() public {
        uint256[4] memory pieces = [uint256(0), 1, 4, 21];
        uint24[4] memory rates = [uint24(13000), 8000, 3000, 0];
        for (uint256 tier; tier < 4; ++tier) {
            for (uint256 mode; mode < 4; ++mode) {
                uint256 snapshot = vm.snapshotState();
                _mintPass(pieces[tier]);
                _checkSwap(mode < 2, mode % 2 == 0, 1 ether, pieces[tier], rates[tier]);
                assertTrue(vm.revertToStateAndDelete(snapshot));
            }
        }
    }

    function testFuzzGrossFeeAndBacking(bool ethIn, bool exactIn, uint96 rawAmount, uint8 rawTier) public {
        uint256 amount = bound(uint256(rawAmount), 1000, 10 ether);
        uint256 tier = uint256(rawTier) % 4;
        uint256[4] memory pieces = [uint256(0), 1, 4, 21];
        uint24[4] memory rates = [uint24(13000), 8000, 3000, 0];
        _mintPass(pieces[tier]);
        _checkSwap(ethIn, exactIn, amount, pieces[tier], rates[tier]);
    }

    function _checkSwap(bool ethIn, bool exactIn, uint256 amount, uint256 pepes, uint24 rate) private {
        uint256 ztoBefore = token.balanceOf(trader);
        uint256 ethBefore = trader.balance;
        vm.recordLogs();
        BalanceDelta delta = _swap(ethIn, exactIn, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int128 poolZto;
        int128 poolEth;
        bool sawPool;
        bool sawPass;
        uint256 cut = kiln.claims();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager)
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                uint24 fee;
                (poolEth, poolZto,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, 2000);
                sawPool = true;
            }
            if (
                logs[i].emitter == address(kiln)
                    && logs[i].topics[0] == keccak256("Passed(address,uint256,uint24,uint256)")
            ) {
                assertFalse(sawPass);
                assertEq(address(uint160(uint256(logs[i].topics[1]))), trader);
                (uint256 passPepes, uint24 passRate, uint256 passCut) =
                    abi.decode(logs[i].data, (uint256, uint24, uint256));
                assertEq(passPepes, pepes);
                assertEq(passRate, rate);
                assertEq(passCut, cut);
                sawPass = true;
            }
        }
        assertTrue(sawPool && sawPass);
        assertEq(int256(delta.amount1()), int256(poolZto) - int256(cut));
        assertEq(delta.amount0(), poolEth);
        uint256 grossZto = ethIn ? uint256(int256(poolZto)) : uint256(-int256(delta.amount1()));
        assertApproxEqAbs(cut, FullMath.mulDiv(grossZto, rate, 1_000_000), 1);
        if (rate == 0) assertEq(cut, 0);
        if (ethIn) {
            assertEq(token.balanceOf(trader) - ztoBefore, uint256(int256(delta.amount1())));
            assertEq(ethBefore - trader.balance, uint256(-int256(delta.amount0())));
        } else {
            assertEq(ztoBefore - token.balanceOf(trader), uint256(-int256(delta.amount1())));
            assertEq(trader.balance - ethBefore, uint256(int256(delta.amount0())));
        }
        if (exactIn) assertEq(uint256(-int256(ethIn ? delta.amount0() : delta.amount1())), amount);
        else assertEq(uint256(int256(ethIn ? delta.amount1() : delta.amount0())), amount);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        uint256 lpPaid = FullMath.mulDiv(ethIn ? growth0 : growth1, LIQUIDITY, 1 << 128);
        uint256 poolInput = uint256(-int256(ethIn ? poolEth : poolZto));
        assertApproxEqAbs(lpPaid, FullMath.mulDiv(poolInput, 2000, 1_000_000), 2);
        assertGt(lpPaid, 0);
        assertEq(ethIn ? growth1 : growth0, 0);
        assertEq(kiln.reserve(), 0);
        assertEq(kiln.bid(), 0);
        assertEq(token.balanceOf(address(kiln)), 0);
        _assertBacking();
        vm.expectEmit(false, false, false, true, address(kiln));
        emit Kiln.Collected(cut);
        vm.prank(makeAddr("collector"));
        kiln.collect();
        assertEq(kiln.claims(), 0);
        assertEq(kiln.reserve(), cut);
        assertEq(token.balanceOf(address(kiln)), cut);
        kiln.collect();
        assertEq(kiln.reserve(), cut);
        _assertBacking();
    }

    function testPeripheryRouterAllFourCasesAndTiers() public {
        uint256[4] memory pieces = [uint256(0), 1, 4, 21];
        for (uint256 tier; tier < 4; ++tier) {
            for (uint256 mode; mode < 4; ++mode) {
                uint256 snapshot = vm.snapshotState();
                _mintPass(pieces[tier]);
                bool ethIn = mode < 2;
                bool exactIn = mode % 2 == 0;
                bytes[] memory params = new bytes[](3);
                params[0] = exactIn
                    ? abi.encode(IV4Router.ExactInputSingleParams(key, ethIn, 1 ether, 0.9 ether, 0, ""))
                    : abi.encode(IV4Router.ExactOutputSingleParams(key, ethIn, 1 ether, 1.1 ether, 0, ""));
                params[1] = abi.encode(ethIn ? key.currency0 : key.currency1, 1.1 ether);
                params[2] = abi.encode(ethIn ? key.currency1 : key.currency0, 0.9 ether);
                bytes memory actions = bytes.concat(
                    bytes1(uint8(exactIn ? Actions.SWAP_EXACT_IN_SINGLE : Actions.SWAP_EXACT_OUT_SINGLE)),
                    bytes1(uint8(Actions.SETTLE_ALL)),
                    bytes1(uint8(Actions.TAKE_ALL))
                );
                uint256 ztoBefore = token.balanceOf(trader);
                uint256 ethBefore = trader.balance;
                vm.prank(trader, trader);
                peripheryRouter.executeActionsAndSweepExcessETH{value: ethIn ? 1.1 ether : 0}(
                    abi.encode(actions, params)
                );
                uint256 input = ethIn ? ethBefore - trader.balance : ztoBefore - token.balanceOf(trader);
                uint256 output = ethIn ? token.balanceOf(trader) - ztoBefore : trader.balance - ethBefore;
                assertEq(exactIn ? input : output, 1 ether);
                assertGe(output, 0.9 ether);
                assertLe(input, 1.1 ether);
                uint256 gross = ethIn ? output + kiln.claims() : input;
                assertApproxEqAbs(kiln.claims(), gross * kiln.tierOf(trader) / 1_000_000, 1);
                kiln.collect();
                _assertBacking();
                assertTrue(vm.revertToStateAndDelete(snapshot));
            }
        }
    }

    function testTxOriginPassWorksImmediatelyAndRouterHoldingsDoNotCount() public {
        for (uint256 i; i < 21; ++i) {
            nft.mint(address(swapRouter), i);
        }
        _swap(false, true, 1 ether);
        assertEq(kiln.claims(), 0.013 ether);
        vm.startPrank(address(swapRouter));
        for (uint256 i; i < 21; ++i) {
            nft.transferFrom(address(swapRouter), trader, i);
        }
        vm.stopPrank();
        // Same block: no holding-period guard.
        _swap(false, true, 1 ether);
        assertEq(kiln.claims(), 0.013 ether);
    }

    function testSpecifiedPartialFillsRevertWithoutRetainingClaims() public {
        for (uint256 mode; mode < 2; ++mode) {
            bool ethIn = mode == 0;
            vm.prank(trader, trader);
            vm.expectRevert();
            swapRouter.swap{value: 100 ether}(
                key,
                SwapParams(
                    ethIn,
                    ethIn ? int256(100 ether) : -int256(100 ether),
                    TickMath.getSqrtPriceAtTick(ethIn ? int24(-1) : int24(1))
                ),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            assertEq(kiln.claims(), 0);
            _assertBacking();
        }
    }

    function testUnspecifiedPartialFillChargesOnlyRealizedZTO() public {
        vm.prank(trader, trader);
        BalanceDelta delta = swapRouter.swap{value: 100 ether}(
            key,
            SwapParams(true, -int256(100 ether), TickMath.getSqrtPriceAtTick(-1)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 gross = uint256(int256(delta.amount1())) + kiln.claims();
        assertEq(kiln.claims(), gross * 13000 / 1_000_000);
        assertLt(uint256(-int256(delta.amount0())), 100 ether);
        _assertBacking();
    }

    function testOnlyManagerAndOnlyOwnPool() public {
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(Kiln.OnlyPoolManager.selector);
        kiln.beforeSwap(trader, key, params, "");
        vm.expectRevert(Kiln.OnlyPoolManager.selector);
        kiln.afterSwap(trader, key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(Kiln.OnlyPoolManager.selector);
        kiln.unlockCallback("");
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(Kiln.WrongPool.selector);
        kiln.beforeSwap(trader, wrong, params, "");
        vm.prank(address(manager));
        vm.expectRevert(Kiln.WrongPool.selector);
        kiln.afterSwap(trader, wrong, params, BalanceDelta.wrap(0), "");
    }

    function testSellAndBuyCollectBeforeQuoting() public {
        nft.mint(trader, 1);
        _swap(false, true, 1 ether);
        uint256 earned = kiln.claims();
        uint256 sellerBefore = token.balanceOf(trader);
        vm.prank(trader);
        kiln.sell(1);
        assertEq(token.balanceOf(trader) - sellerBefore, earned / 50);
        assertEq(kiln.claims(), 0);
        uint256 oldReserve = kiln.reserve();
        _swap(false, true, 1 ether);
        uint256 expectedReserve = oldReserve + kiln.claims();
        uint256 expectedAsk = (expectedReserve / 50) * 11500 / 10000;
        uint256 buyerBefore = token.balanceOf(address(this));
        kiln.buy(1);
        assertEq(buyerBefore - token.balanceOf(address(this)), expectedAsk);
        assertEq(kiln.reserve(), expectedReserve + expectedAsk);
        assertEq(kiln.claims(), 0);
        _assertBacking();
    }

    function testRevertingCollectionRestoresClaimsAndReserve() public {
        _swap(false, true, 1 ether);
        uint256 earned = kiln.claims();
        token.setFailTransfers(true);
        vm.expectRevert();
        kiln.collect();
        assertEq(kiln.claims(), earned);
        assertEq(kiln.reserve(), 0);
        _assertBacking();
        token.setFailTransfers(false);
        kiln.collect();
        assertEq(kiln.reserve(), earned);
        _assertBacking();
    }
}
