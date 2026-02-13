// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MoltMarketplace} from "../src/MoltMarketplace.sol";

/// @notice Upgrade MoltMarketplace proxy to new implementation.
///         After upgrade, sets WMON address and adds it as allowed payment token.
///
/// Usage:
///   PROXY=0x... WMON=0x... forge script script/UpgradeMoltMarketplace.s.sol \
///     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
contract UpgradeMoltMarketplace is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY");
        address wmonAddr = vm.envOr("WMON", address(0));

        vm.startBroadcast();

        // 1. Deploy new implementation
        MoltMarketplace newImpl = new MoltMarketplace();
        console.log("New implementation deployed at:", address(newImpl));

        // 2. Upgrade proxy → new implementation
        MoltMarketplace marketplace = MoltMarketplace(payable(proxy));
        marketplace.upgradeToAndCall(address(newImpl), "");
        console.log("Proxy upgraded:", proxy);

        // 3. Configure WMON if provided
        if (wmonAddr != address(0)) {
            marketplace.setWmonAddress(wmonAddr);
            console.log("WMON address set:", wmonAddr);

            // Add WMON as allowed payment token (if not already)
            if (!marketplace.isPaymentTokenAllowed(wmonAddr)) {
                marketplace.addPaymentToken(wmonAddr);
                console.log("WMON added as payment token");
            }
        }

        vm.stopBroadcast();

        // Verify
        console.log("--- Verification ---");
        console.log("  wmonAddress:", marketplace.wmonAddress());
        console.log("  WMON allowed:", marketplace.isPaymentTokenAllowed(wmonAddr));
    }
}
