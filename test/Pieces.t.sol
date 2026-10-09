// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./KilnBase.sol";

contract PiecesTest is KilnBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function testSeedSellBuyAndEvents() public {
        nft.mint(trader, 736);
        vm.expectEmit(true, false, false, true, address(kiln));
        emit Kiln.Seeded(address(this), 100 ether);
        kiln.seed(100 ether);
        assertEq(kiln.bid(), 2 ether);
        assertEq(kiln.ask(), 2.3 ether);
        uint256 sellerBefore = token.balanceOf(trader);
        vm.expectEmit(true, true, false, true, address(kiln));
        emit Kiln.Sold(736, trader, 2 ether);
        vm.prank(trader);
        kiln.sell(736);
        assertEq(token.balanceOf(trader) - sellerBefore, 2 ether);
        assertEq(nft.ownerOf(736), address(kiln));
        assertEq(kiln.inventory()[0], 736);
        assertEq(kiln.reserve(), 98 ether);
        assertEq(kiln.bid(), 1.96 ether);
        uint256 price = kiln.ask();
        uint256 buyerBefore = token.balanceOf(address(this));
        vm.expectEmit(true, true, false, true, address(kiln));
        emit Kiln.Bought(736, address(this), price);
        // This buyer has no ERC721Receiver: transferFrom must be used.
        kiln.buy(736);
        assertEq(buyerBefore - token.balanceOf(address(this)), price);
        assertEq(kiln.reserve(), 98 ether + price);
        assertEq(nft.ownerOf(736), address(this));
        assertEq(kiln.inventory().length, 0);
        assertFalse(kiln.inInventory(736));
        _assertBacking();
    }

    function testInventorySwapAndPopIncludingIdZero() public {
        kiln.seed(100 ether);
        _mintPass(3);
        vm.startPrank(trader);
        kiln.sell(0);
        kiln.sell(1);
        kiln.sell(2);
        kiln.buy(1);
        assertEq(kiln.inventory().length, 2);
        assertTrue(kiln.inInventory(0));
        assertTrue(kiln.inInventory(2));
        kiln.buy(2);
        kiln.buy(0);
        vm.stopPrank();
        assertEq(kiln.inventory().length, 0);
        _assertBacking();
    }

    function testZeroReserveAndUnheldIdRevert() public {
        nft.mint(trader, 1);
        vm.prank(trader);
        vm.expectRevert(Kiln.ZeroBid.selector);
        kiln.sell(1);
        vm.expectRevert(Kiln.NotInInventory.selector);
        kiln.buy(1);
        assertEq(nft.ownerOf(1), trader);
        assertEq(kiln.inventory().length, 0);
    }

    function testBuyAtZeroAskRevertsUntilReserveIsSeeded() public {
        nft.mint(trader, 7);
        kiln.seed(50);
        assertEq(kiln.bid(), 1);
        vm.prank(trader);
        kiln.sell(7);
        assertEq(kiln.reserve(), 49);
        assertEq(kiln.bid(), 0);
        assertEq(kiln.ask(), 0);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(Kiln.ZeroBid.selector);
        kiln.buy(7);
        assertEq(nft.ownerOf(7), address(kiln));
        assertTrue(kiln.inInventory(7));
        kiln.seed(1);
        assertEq(kiln.ask(), 1);
        vm.prank(stranger);
        vm.expectRevert();
        kiln.buy(7);
        kiln.buy(7);
        assertEq(nft.ownerOf(7), address(this));
        assertEq(kiln.reserve(), 51);
        _assertBacking();
    }

    function testPlainNFTAndZTODonationsAreNotInventoryOrReserve() public {
        nft.mint(trader, 1);
        vm.prank(trader);
        nft.transferFrom(trader, address(kiln), 1);
        assertEq(nft.ownerOf(1), address(kiln));
        assertFalse(kiln.inInventory(1));
        vm.expectRevert(Kiln.NotInInventory.selector);
        kiln.buy(1);
        token.transfer(address(kiln), 100 ether);
        assertEq(kiln.reserve(), 0);
        assertEq(kiln.bid(), 0);
        kiln.seed(50 ether);
        assertEq(kiln.bid(), 1 ether);
        assertEq(kiln.reserve(), 50 ether);
        _assertBacking();
    }

    function testEmptyCollectIsNoOpAndEmits() public {
        vm.expectEmit(false, false, false, true, address(kiln));
        emit Kiln.Collected(0);
        kiln.collect();
        kiln.seed(100 ether);
        kiln.collect();
        assertEq(kiln.reserve(), 100 ether);
        _assertBacking();
    }

    function testFalseERC20SeedRollsBack() public {
        token.setFailTransfers(true);
        vm.expectRevert(Kiln.ZTOTransferFailed.selector);
        kiln.seed(50 ether);
        assertEq(kiln.reserve(), 0);
        _assertBacking();
    }

    function testFalseERC20SellRollsBackNFTAndReserve() public {
        kiln.seed(100 ether);
        nft.mint(trader, 1);
        token.setFailTransfers(true);
        vm.prank(trader);
        vm.expectRevert(Kiln.ZTOTransferFailed.selector);
        kiln.sell(1);
        assertEq(nft.ownerOf(1), trader);
        assertEq(kiln.inventory().length, 0);
        assertEq(kiln.reserve(), 100 ether);
        _assertBacking();
    }

    function testFalseERC20BuyRollsBackInventoryAndReserve() public {
        kiln.seed(100 ether);
        nft.mint(trader, 1);
        vm.prank(trader);
        kiln.sell(1);
        token.setFailTransfers(true);
        vm.expectRevert(Kiln.ZTOTransferFailed.selector);
        kiln.buy(1);
        assertEq(nft.ownerOf(1), address(kiln));
        assertTrue(kiln.inInventory(1));
        assertEq(kiln.reserve(), 98 ether);
        _assertBacking();
    }

    function testUnapprovedOrSomeoneElsesPieceCannotBeSold() public {
        kiln.seed(100 ether);
        nft.mint(trader, 1);
        vm.expectRevert();
        kiln.sell(1);
        vm.prank(trader);
        nft.setApprovalForAll(address(kiln), false);
        vm.prank(trader);
        vm.expectRevert();
        kiln.sell(1);
        assertEq(kiln.reserve(), 100 ether);
        assertFalse(kiln.inInventory(1));
        _assertBacking();
    }

    function testBuyWithoutAllowanceRollsBack() public {
        kiln.seed(100 ether);
        nft.mint(trader, 1);
        vm.prank(trader);
        kiln.sell(1);
        token.approve(address(kiln), 0);
        vm.expectRevert();
        kiln.buy(1);
        assertTrue(kiln.inInventory(1));
        assertEq(kiln.reserve(), 98 ether);
        _assertBacking();
    }

    function testNoWithdrawRescueOwnerPauseOrUpgradeEntryPoints() public {
        kiln.seed(100 ether);
        bytes[7] memory calls = [
            abi.encodeWithSignature("withdraw()"),
            abi.encodeWithSignature("withdraw(uint256)", 1 ether),
            abi.encodeWithSignature("withdraw(address,uint256)", trader, 1 ether),
            abi.encodeWithSignature("sweep(address,address)", address(token), trader),
            abi.encodeWithSignature("transferOwnership(address)", trader),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("upgradeTo(address)", trader)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(trader);
            (bool success,) = address(kiln).call(calls[i]);
            assertFalse(success);
            vm.prank(trader);
            (success,) = address(launcher).call(calls[i]);
            assertFalse(success);
        }
        assertEq(kiln.reserve(), 100 ether);
        _assertBacking();
    }

    function testTierBoundaries() public {
        assertEq(kiln.tierOf(trader), 13000);
        for (uint256 i; i < 25; ++i) {
            nft.mint(trader, i);
            uint256 count = i + 1;
            assertEq(kiln.tierOf(trader), count >= 21 ? 0 : count >= 4 ? 3000 : 8000);
        }
    }

    function testFuzzGeometricBidsAreAlwaysPayable(uint96 amount, uint8 count) public {
        uint256 initial = bound(amount, 50, 10_000 ether);
        uint256 pieces = bound(count, 1, 50);
        kiln.seed(initial);
        _mintPass(pieces);
        uint256 model = initial;
        for (uint256 i; i < pieces; ++i) {
            uint256 price = model / 50;
            if (price == 0) break;
            uint256 before = token.balanceOf(trader);
            vm.prank(trader);
            kiln.sell(i);
            model -= price;
            assertEq(token.balanceOf(trader) - before, price);
            assertEq(kiln.reserve(), model);
            assertLe(kiln.bid(), price);
            _assertBacking();
        }
    }

    function testFuzzMarketSequence(uint256 entropy) public {
        _mintPass(32);
        kiln.seed(100 ether);
        uint256 model = 100 ether;
        for (uint256 step; step < 64; ++step) {
            entropy = uint256(keccak256(abi.encode(entropy, step)));
            uint256 id = entropy % 32;
            uint256 action = (entropy >> 8) % 4;
            if (action == 0) {
                uint256 amount = (entropy >> 16) % 1 ether;
                kiln.seed(amount);
                model += amount;
            } else if (action == 1 && !kiln.inInventory(id)) {
                uint256 price = model / 50;
                vm.prank(trader);
                kiln.sell(id);
                model -= price;
            } else if (action == 2 && kiln.inInventory(id)) {
                uint256 price = (model / 50) * 11500 / 10000;
                vm.prank(trader);
                kiln.buy(id);
                model += price;
            } else {
                kiln.collect();
            }
            assertEq(kiln.reserve(), model);
            uint256[] memory ids = kiln.inventory();
            for (uint256 i; i < ids.length; ++i) {
                assertEq(nft.ownerOf(ids[i]), address(kiln));
                for (uint256 j; j < i; ++j) {
                    assertNotEq(ids[i], ids[j]);
                }
            }
            _assertBacking();
        }
    }
}
