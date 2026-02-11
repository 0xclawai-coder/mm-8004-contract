// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MoltMarketplace} from "../src/MoltMarketplace.sol";

contract DeployMoltMarketplace is Script {
    function run() external {
        address initialAdmin = vm.envAddress("ADMIN");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 platformFeeBps = vm.envUint("PLATFORM_FEE_BPS");

        vm.startBroadcast();

        MoltMarketplace marketplace = new MoltMarketplace(initialAdmin, feeRecipient, platformFeeBps);

        vm.stopBroadcast();

        console.log("MoltMarketplace deployed at:", address(marketplace));
        console.log("  admin:", initialAdmin);
        console.log("  feeRecipient:", marketplace.feeRecipient());
        console.log("  platformFeeBps:", marketplace.platformFeeBps());
    }
}
