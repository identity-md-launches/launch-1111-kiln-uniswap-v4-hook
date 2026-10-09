// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../KilnBase.sol";
import {ClaimDonor} from "../ClaimDonation.t.sol";

/// @dev Only these bounded actions are targeted. Mocks cannot mint or change behavior mid-campaign.
contract KilnHandler is Test {
    Kiln public immutable kiln;
    MockZTO public immutable token;
    MockPepeolithic public immutable nft;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    ClaimDonor public immutable donor;
    PoolKey private key;
    address[4] public actors;
    address[26] public owners;
    bool[26] public listed;
    bool[26] public stuck;

    uint256 public seeded;
    uint256 public buyerPayments;
    uint256 public sellerPayouts;
    uint256 public collected;
    uint256 public swapCuts;
    uint256 public donatedClaims;
    uint256 public pendingDonatedClaims;
    uint256 public directZTO;
    uint256 public listedCount;
    uint256 public sales;
    uint256 public purchases;
    uint256[4] public swapModes;

    constructor(Kiln kiln_, MockZTO token_, MockPepeolithic nft_, IPoolManager manager_, PoolSwapTest router_) {
        kiln = kiln_;
        token = token_;
        nft = nft_;
        manager = manager_;
        router = router_;
        key = kiln_.poolKey();
        donor = new ClaimDonor(manager_, token_, address(kiln_));
        uint256[4] memory counts = [uint256(0), 1, 4, 21];
        uint256 id;
        for (uint256 i; i < 4; ++i) {
            address actor = makeAddr(string.concat("invariant actor ", vm.toString(i)));
            actors[i] = actor;
            token.mint(actor, 100_000 ether);
            vm.deal(actor, 100_000 ether);
            vm.startPrank(actor);
            token.approve(address(kiln), type(uint256).max);
            token.approve(address(router), type(uint256).max);
            nft.setApprovalForAll(address(kiln), true);
            vm.stopPrank();
            for (uint256 j; j < counts[i]; ++j) {
                nft.mint(actor, id);
                owners[id++] = actor;
            }
        }
    }

    function expectedReserve() public view returns (uint256) {
        return seeded + buyerPayments + collected - sellerPayouts;
    }

    function claimBalance() public view returns (uint256) {
        return manager.balanceOf(address(kiln), uint256(uint160(address(token))));
    }

    function seed(uint256 who, uint256 rawAmount) external {
        address actor = actors[who % 4];
        uint256 amount = bound(rawAmount, 0, 10 ether);
        uint256 before = token.balanceOf(actor);
        vm.prank(actor);
        kiln.seed(amount);
        assertEq(before - token.balanceOf(actor), amount, "seed must be funded by sender");
        seeded += amount;
    }

    function collect(uint256 who) public {
        uint256 pending = claimBalance();
        uint256 before = token.balanceOf(address(kiln));
        vm.prank(actors[who % 4]);
        kiln.collect();
        assertEq(token.balanceOf(address(kiln)) - before, pending, "claims redeem one for one");
        assertEq(claimBalance(), 0, "all claim tokens must burn");
        _recordCollection(pending);
    }

    function sell(uint256 rawId) public {
        (bool found, uint256 id) = _find(rawId, false);
        if (!found) return;
        uint256 pending = claimBalance();
        uint256 price = (expectedReserve() + pending) / 50;
        if (price == 0) return;
        address actor = owners[id];
        uint256 before = token.balanceOf(actor);
        vm.prank(actor);
        kiln.sell(id);
        assertEq(token.balanceOf(actor) - before, price, "seller receives collected bid");
        _recordCollection(pending);
        sellerPayouts += price;
        owners[id] = address(kiln);
        listed[id] = true;
        ++listedCount;
        ++sales;
    }

    function buy(uint256 who, uint256 rawId) public {
        (bool found, uint256 id) = _find(rawId, true);
        if (!found) return;
        uint256 pending = claimBalance();
        uint256 price = ((expectedReserve() + pending) / 50) * 11500 / 10000;
        address actor = actors[who % 4];
        uint256 before = token.balanceOf(actor);
        vm.prank(actor);
        kiln.buy(id);
        assertEq(before - token.balanceOf(actor), price, "buyer pays collected ask");
        _recordCollection(pending);
        buyerPayments += price;
        owners[id] = actor;
        listed[id] = false;
        --listedCount;
        ++purchases;
    }

    struct SwapCheck {
        address actor;
        uint256 mode;
        uint256 amount;
        uint256 rate;
        uint256 claimsBefore;
        uint256 ztoBefore;
        uint256 ethBefore;
        uint256 reserveBefore;
        uint256 realZTOBefore;
        bool ethIn;
        bool exactIn;
    }

    function swap(uint256 who, uint256 rawAmount, uint256 rawMode) public {
        SwapCheck memory check;
        check.actor = actors[who % 4];
        check.mode = rawMode % 4;
        check.ethIn = check.mode < 2;
        check.exactIn = check.mode % 2 == 0;
        // At most 0.1 ETH/ZTO per step against 1000 liquidity: full fills remain reachable.
        check.amount = bound(rawAmount, 1000, 0.1 ether);
        uint256 pepes;
        for (uint256 i; i < owners.length; ++i) {
            if (owners[i] == check.actor) ++pepes;
        }
        check.rate = pepes >= 21 ? 0 : pepes >= 4 ? 3000 : pepes >= 1 ? 8000 : 13000;
        check.claimsBefore = claimBalance();
        check.ztoBefore = token.balanceOf(check.actor);
        check.ethBefore = check.actor.balance;
        check.reserveBefore = kiln.reserve();
        check.realZTOBefore = token.balanceOf(address(kiln));
        vm.prank(check.actor, check.actor);
        BalanceDelta delta = router.swap{value: check.ethIn ? 1 ether : 0}(
            key,
            SwapParams(
                check.ethIn,
                check.exactIn ? -int256(check.amount) : int256(check.amount),
                check.ethIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        _checkSwap(check, delta);
    }

    function _checkSwap(SwapCheck memory check, BalanceDelta delta) private {
        uint256 cut = claimBalance() - check.claimsBefore;
        uint256 ztoMoved = check.ethIn
            ? token.balanceOf(check.actor) - check.ztoBefore
            : check.ztoBefore - token.balanceOf(check.actor);
        uint256 ethMoved = check.ethIn ? check.ethBefore - check.actor.balance : check.actor.balance - check.ethBefore;
        assertEq(ztoMoved, uint256(check.ethIn ? int256(delta.amount1()) : -int256(delta.amount1())));
        assertEq(ethMoved, uint256(check.ethIn ? -int256(delta.amount0()) : int256(delta.amount0())));
        assertEq(
            check.exactIn == check.ethIn ? ethMoved : ztoMoved, check.amount, "specified amount must settle exactly"
        );
        uint256 grossZTO = check.ethIn ? ztoMoved + cut : ztoMoved;
        assertApproxEqAbs(cut, grossZTO * check.rate / 1_000_000, 1, "cut matches actual ZTO movement");
        if (check.rate == 0) assertEq(cut, 0, "tier 21 has no cut, even after other tiers swap");
        assertEq(kiln.reserve(), check.reserveBefore, "uncollected cuts cannot fund quotes");
        assertEq(token.balanceOf(address(kiln)), check.realZTOBefore, "swap cannot take real ZTO");
        swapCuts += cut;
        ++swapModes[check.mode];
    }

    function transferPass(uint256 rawId, uint256 who) external {
        (bool found, uint256 id) = _find(rawId, false);
        if (!found) return;
        address to = actors[who % 4];
        vm.prank(owners[id]);
        nft.transferFrom(owners[id], to, id);
        owners[id] = to;
    }

    function donateZTO(uint256 who, uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 0, 1 ether);
        vm.prank(actors[who % 4]);
        assertTrue(token.transfer(address(kiln), amount));
        directZTO += amount;
    }

    function donateClaims(uint256 who, uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, 1 ether);
        vm.prank(actors[who % 4]);
        assertTrue(token.transfer(address(donor), amount));
        donor.donate(amount);
        donatedClaims += amount;
        pendingDonatedClaims += amount;
    }

    function donatePiece(uint256 rawId) external {
        (bool found, uint256 id) = _find(rawId, false);
        if (!found) return;
        vm.prank(owners[id]);
        nft.transferFrom(owners[id], address(kiln), id);
        owners[id] = address(kiln);
        stuck[id] = true;
    }

    function rejectUnknownBuy(uint256 who, uint256 rawId) external {
        uint256 reserveBefore = kiln.reserve();
        uint256 claimsBefore = claimBalance();
        uint256 realBefore = token.balanceOf(address(kiln));
        // IDs outside our minted set include valid-but-unminted and out-of-collection IDs.
        uint256 id = bound(rawId, 26, type(uint256).max);
        vm.prank(actors[who % 4]);
        vm.expectRevert(Kiln.NotInInventory.selector);
        kiln.buy(id);
        assertEq(kiln.reserve(), reserveBefore, "failed buy rolls back collection");
        assertEq(claimBalance(), claimsBefore, "failed buy preserves claims");
        assertEq(token.balanceOf(address(kiln)), realBefore, "failed buy cannot extract reserve");
    }

    function _recordCollection(uint256 amount) private {
        collected += amount;
        pendingDonatedClaims = 0;
        assertEq(kiln.claims(), 0, "collection clears swap accounting");
        assertEq(claimBalance(), 0, "collection clears donated and earned claims");
    }

    function _find(uint256 rawId, bool wantListed) private view returns (bool, uint256) {
        uint256 start = rawId % owners.length;
        for (uint256 i; i < owners.length; ++i) {
            uint256 id = (start + i) % owners.length;
            if (wantListed ? listed[id] : owners[id] != address(kiln)) return (true, id);
        }
        return (false, 0);
    }
}
