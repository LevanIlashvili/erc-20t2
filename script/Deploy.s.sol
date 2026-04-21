// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TestToken} from "../src/TestToken.sol";

/// @notice Deploys a demo ERC-8236 token for kicking the tires on a testnet.
/// @dev    The deployer receives 1,000,000 tokens in their *available* balance
///         (minted tokens bypass the settlement delay — there's no counterparty to unwind from).
contract Deploy is Script {
    function run() external returns (TestToken token) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        token = new TestToken("ERC-8236 Demo Token", "T2DEMO");
        token.mint(deployer, 1_000_000 ether);

        vm.stopBroadcast();

        console.log("TestToken deployed at:", address(token));
        console.log("Deployer balance:     ", token.availableBalanceOf(deployer));
    }
}
