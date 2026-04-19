// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20T2} from "./ERC20T2.sol";

/// @notice Concrete ERC20T2 with open mint/burn for testing purposes.
contract TestToken is ERC20T2 {
    constructor(string memory name_, string memory symbol_) ERC20T2(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
