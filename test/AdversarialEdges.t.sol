// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./KilnBase.sol";
import {stdError} from "forge-std/StdError.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

contract AdversarialEdgesTest is KilnBase {
    using TransientStateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _addLiquidity(-60000, 60000, int256(uint256(LIQUIDITY)));
    }

    function testRevertingUnapprovedSaleRollsBackItsCollection() public {
        nft.mint(trader, 0);
        _swap(false, true, 1 ether);
        uint256 pending = kiln.claims();
        vm.prank(trader);
        nft.setApprovalForAll(address(kiln), false);
        vm.prank(trader);
        vm.expectRevert(bytes("NOT_AUTHORIZED"));
        kiln.sell(0);
        _assertUncollected(pending, 0);
        assertEq(nft.ownerOf(0), trader);
        assertEq(kiln.inventory().length, 0);
    }

    function testRevertingBuyRollsBackItsCollectionAndSwapPop() public {
        kiln.seed(100 ether);
        _mintPass(3);
        vm.startPrank(trader);
        kiln.sell(0);
        kiln.sell(1);
        kiln.sell(2);
        vm.stopPrank();
        uint256 oldReserve = kiln.reserve();
        uint256[] memory beforeInventory = kiln.inventory();
        _swap(false, true, 1 ether);
        uint256 pending = kiln.claims();
        address unfunded = makeAddr("unfunded buyer");
        vm.startPrank(unfunded);
        token.approve(address(kiln), type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        kiln.buy(1);
        vm.stopPrank();
        _assertUncollected(pending, oldReserve);
        assertEq(kiln.inventory(), beforeInventory);
        assertEq(nft.ownerOf(1), address(kiln));
        assertTrue(kiln.inInventory(1));
    }

    function testCannotSellAnInventoryPieceTwiceEvenWithPendingClaims() public {
        kiln.seed(100 ether);
        nft.mint(trader, 0);
        vm.prank(trader);
        kiln.sell(0);
        _swap(false, true, 1 ether);
        uint256 pending = kiln.claims();
        uint256 sellerBefore = token.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(Kiln.AlreadyInInventory.selector);
        kiln.sell(0);
        _assertUncollected(pending, 98 ether);
        assertEq(token.balanceOf(trader), sellerBefore);
        assertEq(kiln.inventory().length, 1);
    }

    function testRevertingNFTDeliveryRestoresBuyerTokensAndInventory() public {
        kiln.seed(100 ether);
        nft.mint(trader, 0);
        vm.prank(trader);
        kiln.sell(0);
        uint256 buyerBefore = token.balanceOf(address(this));
        uint256 allowanceBefore = token.allowance(address(this), address(kiln));
        bytes memory reason = abi.encodeWithSignature("NFTDeliveryFailed()");
        vm.mockCallRevert(address(nft), abi.encodeCall(nft.transferFrom, (address(kiln), address(this), 0)), reason);
        vm.expectRevert(reason);
        kiln.buy(0);
        vm.clearMockedCalls();
        assertEq(token.balanceOf(address(this)), buyerBefore);
        assertEq(token.allowance(address(this), address(kiln)), allowanceBefore);
        assertEq(kiln.reserve(), 98 ether);
        assertEq(nft.ownerOf(0), address(kiln));
        assertEq(kiln.inventory()[0], 0);
        assertTrue(kiln.inInventory(0));
        _assertBacking();
    }

    function testInsufficientSeedBalanceCannotCreateReserve() public {
        address unfunded = makeAddr("unfunded seeder");
        vm.startPrank(unfunded);
        token.approve(address(kiln), type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        kiln.seed(1);
        vm.stopPrank();
        assertEq(kiln.reserve(), 0);
        _assertBacking();
    }

    function testReserveDustAndOneWeiBidBoundary() public {
        nft.mint(trader, 0);
        kiln.seed(0);
        kiln.seed(1);
        kiln.seed(48);
        vm.prank(trader);
        vm.expectRevert(Kiln.ZeroBid.selector);
        kiln.sell(0);
        assertEq(kiln.reserve(), 49);
        assertEq(nft.ownerOf(0), trader);
        kiln.seed(1);
        assertEq(kiln.bid(), 1);
        uint256 before = token.balanceOf(trader);
        vm.prank(trader);
        kiln.sell(0);
        assertEq(token.balanceOf(trader) - before, 1);
        assertEq(kiln.reserve(), 49);
        assertEq(kiln.bid(), 0);
        _assertBacking();
    }

    function testNearUint256MaximumReserveQuotesAndPaysWithoutOverflow() public {
        token.mint(address(this), type(uint256).max - token.totalSupply());
        uint256 amount = token.balanceOf(address(this));
        token.approve(address(kiln), amount);
        kiln.seed(amount);
        uint256 bid = amount / 50;
        // Quotient/remainder oracle avoids overflowing the multiplication under test.
        uint256 expectedAsk = (bid / 10000) * 11500 + ((bid % 10000) * 11500) / 10000;
        assertEq(kiln.ask(), expectedAsk);
        assertLe(kiln.ask(), amount);
        nft.mint(trader, 0);
        uint256 before = token.balanceOf(trader);
        vm.prank(trader);
        kiln.sell(0);
        assertEq(token.balanceOf(trader) - before, bid);
        assertEq(kiln.reserve(), amount - bid);
        _assertBacking();
    }

    function testEntireCollectionFitsInventoryAndCanBeBought() public {
        kiln.seed(100 ether);
        _mintPass(737);
        uint256 before = token.balanceOf(trader);
        vm.startPrank(trader);
        for (uint256 id; id < 737; ++id) {
            kiln.sell(id);
        }
        vm.stopPrank();
        assertEq(kiln.inventory().length, 737);
        assertEq(nft.balanceOf(address(kiln)), 737);
        assertEq(token.balanceOf(trader) - before, 100 ether - kiln.reserve());
        kiln.buy(0);
        kiln.buy(368);
        kiln.buy(736);
        assertEq(nft.ownerOf(0), address(this));
        assertEq(nft.ownerOf(368), address(this));
        assertEq(nft.ownerOf(736), address(this));
        assertEq(kiln.inventory().length, 734);
        _assertBacking();
    }

    function testSellOfUnmintedOrOutOfCollectionIdRevertsWithoutEffects() public {
        kiln.seed(100 ether);
        uint256[3] memory ids = [uint256(5), 737, type(uint256).max];
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(trader);
            vm.expectRevert(bytes("WRONG_FROM"));
            kiln.sell(ids[i]);
            assertFalse(kiln.inInventory(ids[i]));
        }
        assertEq(kiln.reserve(), 100 ether);
        assertEq(kiln.inventory().length, 0);
        _assertUncollected(0, 100 ether);
    }

    /// The no-hold rule lets a zero-piece wallet rent the Kiln's own inventory: buy 21 pieces,
    /// swap cut-free, sell them back. The rent (spread plus bid drift) lands in the reserve, does
    /// not depend on swap size, and is cheaper than the cut only for swaps of several reserves.
    function testRentingTwentyOnePiecesFromInventorySkipsTheCutAndPaysRentIntoReserve() public {
        address holder = makeAddr("piece holder");
        vm.prank(holder);
        nft.setApprovalForAll(address(kiln), true);
        kiln.seed(100 ether);
        for (uint256 id; id < 21; ++id) {
            nft.mint(holder, id);
            vm.prank(holder);
            kiln.sell(id);
        }
        uint256 reserveBefore = kiln.reserve();
        assertEq(kiln.tierOf(trader), 13000);
        uint256 traderBefore = token.balanceOf(trader);
        uint256 rentSmall = _rentAndSwap(1 ether, traderBefore);
        assertEq(kiln.tierOf(trader), 13000, "pieces are back in inventory");
        assertEq(kiln.reserve(), reserveBefore + rentSmall, "the rent is paid into the reserve");
        assertEq(kiln.inventory().length, 21);
        assertGt(rentSmall, reserveBefore * 5 / 100);
        assertLt(rentSmall, reserveBefore * 6 / 100);
        _assertUncollected(0, reserveBefore + rentSmall);

        uint256 snapshot = vm.snapshotState();
        _swap(false, true, 200 ether);
        uint256 cutOnTwoHundred = kiln.claims();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        snapshot = vm.snapshotState();
        _swap(false, true, 300 ether);
        uint256 cutOnThreeHundred = kiln.claims();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        assertGt(rentSmall, cutOnTwoHundred, "renting is dearer than the cut for ordinary swaps");
        assertLt(rentSmall, cutOnThreeHundred, "renting is cheaper only for swaps of several reserves");

        uint256 reserveMid = kiln.reserve();
        uint256 rentLarge = _rentAndSwap(300 ether, token.balanceOf(trader));
        assertEq(kiln.reserve(), reserveMid + rentLarge);
        assertApproxEqRel(rentLarge, rentSmall * reserveMid / reserveBefore, 1e15, "rent scales with the reserve only");
    }

    function _rentAndSwap(uint256 swapAmount, uint256 traderBefore) private returns (uint256 rent) {
        vm.startPrank(trader);
        for (uint256 id; id < 21; ++id) {
            kiln.buy(id);
        }
        vm.stopPrank();
        assertEq(kiln.tierOf(trader), 0);
        _swap(false, true, swapAmount);
        assertEq(kiln.claims(), 0, "rented pass pays no cut");
        vm.startPrank(trader);
        for (uint256 id; id < 21; ++id) {
            kiln.sell(id);
        }
        vm.stopPrank();
        rent = traderBefore - swapAmount - token.balanceOf(trader);
    }

    /// README seeding caveat: with a piece in inventory, buy before a seed and sell after it. The
    /// capture is at most 2% of the inflow, loses below about 12.7% of the reserve and wins above
    /// 20%, and whatever the sandwich does not take stays in the reserve.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSeedSandwichCaptureIsBoundedByTwoPercentOfTheInflow(uint96 rawReserve, uint96 rawSeed) public {
        uint256 initial = bound(rawReserve, 1 ether, 50_000 ether);
        uint256 inflow = bound(rawSeed, 0, 50_000 ether);
        nft.mint(address(this), 0);
        nft.setApprovalForAll(address(kiln), true);
        kiln.seed(initial);
        kiln.sell(0);
        uint256 reserveBefore = kiln.reserve();
        uint256 attackerBefore = token.balanceOf(trader);
        vm.prank(trader);
        kiln.buy(0);
        kiln.seed(inflow);
        vm.prank(trader);
        kiln.sell(0);
        int256 profit = int256(token.balanceOf(trader)) - int256(attackerBefore);
        assertLe(profit, int256(inflow / 50), "capture never exceeds 2% of the inflow");
        if (inflow * 1000 <= reserveBefore * 127) {
            assertLe(profit, 2, "below the breakeven fraction the sandwich loses");
        }
        if (inflow * 10 >= reserveBefore * 2) assertGt(profit, 0, "above it the sandwich wins");
        assertEq(int256(kiln.reserve()), int256(reserveBefore + inflow) - profit, "the rest of the seed stays");
        assertEq(nft.ownerOf(0), address(kiln));
        _assertUncollected(0, kiln.reserve());
    }

    function testSeedSandwichPinnedOnBothSidesOfBreakeven() public {
        // Reserve 98 ether with one piece listed, ask 2.254. A 10 ether seed (10.2%) loses
        // 0.04892; a 30 ether seed (30.6%) wins 0.35108, under 2% of the inflow.
        nft.mint(address(this), 0);
        nft.setApprovalForAll(address(kiln), true);
        kiln.seed(100 ether);
        kiln.sell(0);
        assertEq(kiln.reserve(), 98 ether);
        int256[2] memory expected = [int256(-0.04892 ether), int256(0.35108 ether)];
        uint256[2] memory inflows = [uint256(10 ether), 30 ether];
        for (uint256 i; i < 2; ++i) {
            uint256 snapshot = vm.snapshotState();
            uint256 attackerBefore = token.balanceOf(trader);
            vm.prank(trader);
            kiln.buy(0);
            assertEq(attackerBefore - token.balanceOf(trader), 2.254 ether);
            kiln.seed(inflows[i]);
            vm.prank(trader);
            kiln.sell(0);
            assertEq(int256(token.balanceOf(trader)) - int256(attackerBefore), expected[i]);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function testEveryPoolKeyFieldIsValidatedByBothCallbacks() public {
        for (uint256 field; field < 5; ++field) {
            PoolKey memory wrong = kiln.poolKey();
            if (field == 0) wrong.currency0 = Currency.wrap(address(token));
            if (field == 1) wrong.currency1 = Currency.wrap(address(nft));
            if (field == 2) wrong.fee = 2001;
            if (field == 3) wrong.tickSpacing = 61;
            if (field == 4) wrong.hooks = IHooks(address(launcher));
            SwapParams memory params = SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1);
            vm.prank(address(manager));
            vm.expectRevert(Kiln.WrongPool.selector);
            kiln.beforeSwap(trader, wrong, params, "");
            vm.prank(address(manager));
            vm.expectRevert(Kiln.WrongPool.selector);
            kiln.afterSwap(trader, wrong, params, BalanceDelta.wrap(0), "");
        }
        _assertUncollected(0, 0);
    }

    function testMinimumSignedSwapRevertsWithCustomErrorAndNoEffects() public {
        vm.prank(trader, trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(kiln),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(Kiln.InvalidSwapAmount.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            key,
            SwapParams(false, type(int256).min, TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        _assertUncollected(0, 0);
    }

    function testZeroSwapRejectedWithoutCut() public {
        vm.prank(trader, trader);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        swapRouter.swap(
            key, SwapParams(false, 0, TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
        );
        _assertUncollected(0, 0);
    }

    function testRevertingRouterSettlementRollsBackMintedCutAndPoolPrice() public {
        token.setFailTransfers(true);
        vm.prank(trader, trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        swapRouter.swap(
            key, SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1), PoolSwapTest.TestSettings(false, false), ""
        );
        token.setFailTransfers(false);
        _assertUncollected(0, 0);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, PoolIdLibrary.toId(key));
        assertEq(price, Q96);
    }

    function testOneWeiSwapsInAllModesAndTiers() public {
        uint256[4] memory counts = [uint256(0), 1, 4, 21];
        for (uint256 tier; tier < 4; ++tier) {
            for (uint256 mode; mode < 4; ++mode) {
                uint256 snapshot = vm.snapshotState();
                _mintPass(counts[tier]);
                _checkSmallSwap(mode, 1);
                assertTrue(vm.revertToStateAndDelete(snapshot));
            }
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFeeRoundingBelowOneToken(uint64 rawAmount, uint8 mode, uint8 tier) public {
        uint256[4] memory counts = [uint256(0), 1, 4, 21];
        _mintPass(counts[tier % 4]);
        _checkSmallSwap(mode % 4, bound(rawAmount, 1, 1_000_000));
    }

    function _checkSmallSwap(uint256 mode, uint256 amount) private {
        bool ethIn = mode < 2;
        bool exactIn = mode % 2 == 0;
        uint256 before = token.balanceOf(trader);
        BalanceDelta delta = _swap(ethIn, exactIn, amount);
        uint256 moved = ethIn ? token.balanceOf(trader) - before : before - token.balanceOf(trader);
        uint256 cut = kiln.claims();
        uint256 gross = ethIn ? moved + cut : moved;
        assertApproxEqAbs(cut, gross * kiln.tierOf(trader) / 1_000_000, 1);
        if (kiln.tierOf(trader) == 0) assertEq(cut, 0);
        int128 specified = exactIn == ethIn ? delta.amount0() : delta.amount1();
        assertEq(specified, exactIn ? -int256(amount) : int256(amount));
        assertEq(kiln.reserve(), 0);
        kiln.collect();
        assertEq(kiln.reserve(), cut);
        _assertBacking();
    }

    function _assertUncollected(uint256 claims, uint256 reserve) private view {
        assertEq(kiln.claims(), claims);
        assertEq(kiln.reserve(), reserve);
        assertEq(token.balanceOf(address(kiln)), reserve);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        _assertBacking();
    }
}
