// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./KilnBase.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract ClaimDonor is IUnlockCallback {
    IPoolManager private immutable manager;
    MockZTO private immutable token;
    address private immutable kiln;
    error OnlyManager();
    error TransferFailed();

    constructor(IPoolManager manager_, MockZTO token_, address kiln_) {
        manager = manager_;
        token = token_;
        kiln = kiln_;
    }

    function donate(uint256 amount) external {
        manager.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        uint256 amount = abi.decode(data, (uint256));
        manager.sync(Currency.wrap(address(token)));
        if (!token.transfer(address(manager), amount)) revert TransferFailed();
        manager.settle();
        manager.mint(kiln, uint256(uint160(address(token))), amount);
        return "";
    }
}

contract ClaimDonationTest is KilnBase {
    function testCollectBurnsWholeClaimBalanceIncludingDonations() public {
        ClaimDonor donor = new ClaimDonor(manager, token, address(kiln));
        token.mint(address(donor), 50 ether);
        donor.donate(50 ether);
        assertEq(kiln.claims(), 0);
        assertEq(manager.balanceOf(address(kiln), uint256(uint160(address(token)))), 50 ether);
        kiln.collect();
        assertEq(kiln.reserve(), 50 ether);
        assertEq(kiln.bid(), 1 ether);
        assertEq(token.balanceOf(address(kiln)), 50 ether);
        _assertBacking();
    }

    function testStrangerCannotTransferKilnsClaims() public {
        ClaimDonor donor = new ClaimDonor(manager, token, address(kiln));
        token.mint(address(donor), 50 ether);
        donor.donate(50 ether);
        vm.prank(trader);
        vm.expectRevert();
        manager.transferFrom(address(kiln), trader, uint256(uint160(address(token))), 1 ether);
        kiln.collect();
        assertEq(kiln.reserve(), 50 ether);
        _assertBacking();
    }
}
