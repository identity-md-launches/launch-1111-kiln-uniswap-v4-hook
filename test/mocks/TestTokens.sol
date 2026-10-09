// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC721} from "solmate/src/tokens/ERC721.sol";

contract MockZTO is ERC20 {
    bool public failTransfers;

    constructor() ERC20("Rehearsal ZTO", "ZTO", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfers(bool fail) external {
        failTransfers = fail;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        return !failTransfers && super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        return !failTransfers && super.transferFrom(from, to, amount);
    }
}

contract MockPepeolithic is ERC721 {
    error InvalidId();
    error NoSafeTransfers();

    constructor() ERC721("Pepeolithic", "PEPEO") {}

    function mint(address to, uint256 id) external {
        if (id >= 737) revert InvalidId();
        _mint(to, id);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    function safeTransferFrom(address, address, uint256) public pure override {
        revert NoSafeTransfers();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) public pure override {
        revert NoSafeTransfers();
    }
}
