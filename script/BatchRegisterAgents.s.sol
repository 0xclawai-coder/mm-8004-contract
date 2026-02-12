// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

interface IIdentityRegistry {
    function register(string calldata agentURI) external returns (uint256 agentId);
    function totalSupply() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract BatchRegisterAgents is Script {
    uint256 constant NUM_AGENTS = 20;
    uint256 constant FUND_AMOUNT = 0.01 ether;

    address constant IDENTITY_REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

    function _agentKey(uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode("molt-test-agent", i)));
    }

    function _agentURIs() internal pure returns (string[20] memory uris) {
        uris[0]  = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_01.json";
        uris[1]  = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_02.json";
        uris[2]  = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_03.json";
        uris[3]  = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_04.json";
        uris[4]  = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_05.json";
        uris[5]  = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_06.json";
        uris[6]  = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_07.json";
        uris[7]  = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_08.json";
        uris[8]  = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_09.json";
        uris[9]  = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_10.json";
        uris[10] = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_11.json";
        uris[11] = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_12.json";
        uris[12] = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_13.json";
        uris[13] = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_14.json";
        uris[14] = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_15.json";
        uris[15] = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_16.json";
        uris[16] = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_17.json";
        uris[17] = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_18.json";
        uris[18] = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_19.json";
        uris[19] = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_20.json";
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        IIdentityRegistry registry = IIdentityRegistry(IDENTITY_REGISTRY);

        string[20] memory uris = _agentURIs();

        // --- Phase 1: Fund agent wallets from deployer ---
        console.log("=== Phase 1: Funding agent wallets ===");
        vm.startBroadcast(deployerKey);
        for (uint256 i = 0; i < NUM_AGENTS; i++) {
            address agentAddr = vm.addr(_agentKey(i));
            (bool sent,) = agentAddr.call{value: FUND_AMOUNT}("");
            require(sent, "Fund transfer failed");
            console.log("Funded agent", i, "at", agentAddr);
        }
        vm.stopBroadcast();

        // --- Phase 2: Each agent registers itself ---
        console.log("=== Phase 2: Registering agents ===");
        for (uint256 i = 0; i < NUM_AGENTS; i++) {
            uint256 agentKey = _agentKey(i);
            vm.startBroadcast(agentKey);
            uint256 agentId = registry.register(uris[i]);
            vm.stopBroadcast();
            console.log("Registered agent", i, "-> agentId:", agentId);
        }

        // --- Summary ---
        console.log("=== Done ===");
        console.log("Total agents registered:", NUM_AGENTS);
    }
}
