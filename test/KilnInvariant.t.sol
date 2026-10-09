// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./KilnBase.sol";
import {KilnHandler} from "./handlers/KilnHandler.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

contract KilnInvariantTest is KilnBase {
    using TransientStateLibrary for IPoolManager;
    KilnHandler private handler;
    uint256 private supply;

    function setUp() public override {
        super.setUp();
        _addLiquidity(-60000, 60000, int256(uint256(LIQUIDITY)));
        handler = new KilnHandler(kiln, token, nft, manager, swapRouter);
        supply = token.totalSupply();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.seed.selector;
        selectors[1] = handler.collect.selector;
        selectors[2] = handler.sell.selector;
        selectors[3] = handler.buy.selector;
        selectors[4] = handler.swap.selector;
        selectors[5] = handler.transferPass.selector;
        selectors[6] = handler.donateZTO.selector;
        selectors[7] = handler.donateClaims.selector;
        selectors[8] = handler.donatePiece.selector;
        selectors[9] = handler.rejectUnknownBuy.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_reserveClaimsInventoryAndSettlement() public view {
        assertEq(kiln.reserve(), handler.expectedReserve(), "reserve equals recorded cash flows");
        assertEq(token.balanceOf(address(kiln)), kiln.reserve() + handler.directZTO(), "reserve is fully backed");
        assertEq(
            handler.collected() + handler.claimBalance(),
            handler.swapCuts() + handler.donatedClaims(),
            "claims can be redeemed exactly once"
        );
        assertEq(handler.claimBalance(), kiln.claims() + handler.pendingDonatedClaims(), "swap claims reconcile");
        assertLe(kiln.bid(), kiln.reserve(), "bid is payable");
        assertEq(kiln.bid(), kiln.reserve() / 50);
        assertEq(kiln.ask(), kiln.bid() * 11500 / 10000);
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0, "every operation settles manager accounting");
        assertEq(address(kiln).balance, 0, "fees are ZTO only");

        uint256[] memory inventory = kiln.inventory();
        assertEq(inventory.length, handler.listedCount());
        bool[26] memory seen;
        for (uint256 i; i < inventory.length; ++i) {
            uint256 id = inventory[i];
            assertLt(id, 26);
            assertFalse(seen[id], "no duplicate inventory entries");
            seen[id] = true;
            assertTrue(handler.listed(id), "only pieces acquired by sell are inventory");
        }
        for (uint256 id; id < 26; ++id) {
            assertEq(nft.ownerOf(id), handler.owners(id), "piece custody matches completed transfers");
            assertEq(kiln.inInventory(id), handler.listed(id), "membership follows sales and purchases");
            assertEq(seen[id], handler.listed(id), "no missing inventory entries");
            if (handler.stuck(id)) {
                assertFalse(seen[id], "plain transfers never become saleable");
                assertEq(nft.ownerOf(id), address(kiln));
            }
        }

        uint256 holdings = token.balanceOf(address(this)) + token.balanceOf(trader) + token.balanceOf(address(manager))
            + token.balanceOf(address(kiln));
        for (uint256 i; i < 4; ++i) {
            holdings += token.balanceOf(handler.actors(i));
        }
        assertEq(token.totalSupply(), supply, "no mid-sequence minting to conceal insolvency");
        assertEq(holdings, supply, "no ZTO escapes to a router, donor, launcher or other recipient");
        assertEq(address(launcher.kiln()), address(kiln), "opened pool never changes");
    }

    function afterInvariant() public {
        // Liveness after arbitrary history, including donated claims and empty collections.
        handler.collect(0);
        while (handler.listedCount() != 0) handler.buy(0, 0);
        invariant_reserveClaimsInventoryAndSettlement();
    }

    function testHandlerExercisesEveryActionAndSwapMode() public {
        handler.seed(0, 1000);
        for (uint256 actor; actor < 4; ++actor) {
            for (uint256 mode; mode < 4; ++mode) {
                handler.swap(actor, 0.01 ether, mode);
            }
        }
        handler.donateClaims(0, 1 ether);
        handler.rejectUnknownBuy(0, 736);
        handler.sell(0); // sell must collect both earned and donated claims
        handler.buy(0, 0);
        handler.transferPass(0, 2);
        handler.donateZTO(0, 1 ether);
        handler.donatePiece(0);
        handler.collect(3);
        handler.collect(2);
        for (uint256 mode; mode < 4; ++mode) {
            assertEq(handler.swapModes(mode), 4);
        }
        assertEq(handler.sales(), 1);
        assertEq(handler.purchases(), 1);
        assertGt(handler.swapCuts(), 0);
        assertGt(handler.collected(), 1 ether);
        invariant_reserveClaimsInventoryAndSettlement();
    }
}
