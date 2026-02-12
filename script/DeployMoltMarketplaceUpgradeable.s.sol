// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MoltMarketplace} from "../src/MoltMarketplace.sol";
import {MoltMarketplaceProxy} from "../src/MoltMarketplaceProxy.sol";

contract DeployMoltMarketplaceUpgradeable is Script {
    function run() external {
        address initialAdmin = vm.envAddress("ADMIN");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 platformFeeBps = vm.envUint("PLATFORM_FEE_BPS");

        vm.startBroadcast();

        // 1. Deploy implementation
        MoltMarketplace impl = new MoltMarketplace();

        // 2. Encode initializer call data
        bytes memory initData = abi.encodeCall(
            MoltMarketplace.initialize,
            (initialAdmin, feeRecipient, platformFeeBps)
        );

        // 3. Deploy proxy
        MoltMarketplaceProxy proxy = new MoltMarketplaceProxy(address(impl), initData);

        // 4. Cast proxy to marketplace interface
        MoltMarketplace marketplace = MoltMarketplace(payable(address(proxy)));

        vm.stopBroadcast();

        console.log("MoltMarketplace implementation deployed at:", address(impl));
        console.log("MoltMarketplaceProxy deployed at:", address(proxy));
        console.log("  admin:", initialAdmin);
        console.log("  feeRecipient:", marketplace.feeRecipient());
        console.log("  platformFeeBps:", marketplace.platformFeeBps());
    }
}
