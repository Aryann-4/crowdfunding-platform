// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CrowdfundingPlatform} from "../src/CrowdfundingPlatform.sol";

/**
 * @title Deploy
 * @notice Deploys {CrowdfundingPlatform} using configuration from the environment.
 *
 * Required:
 *  - PRIVATE_KEY
 *
 * Optional:
 *  - OWNER             (defaults to the deployer address)
 *  - FEE_RECIPIENT     (defaults to OWNER)
 *  - PLATFORM_FEE_BPS  (defaults to 0, max 500)
 *
 * Example:
 *  forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
 */
contract Deploy is Script {
    function run() external returns (CrowdfundingPlatform platform) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address owner = vm.envOr("OWNER", deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", owner);
        uint256 platformFeeBps = vm.envOr("PLATFORM_FEE_BPS", uint256(0));

        vm.startBroadcast(deployerPrivateKey);

        platform = new CrowdfundingPlatform(owner, feeRecipient, platformFeeBps);

        vm.stopBroadcast();

        console2.log("CrowdfundingPlatform deployed at:", address(platform));
        console2.log("Owner:", owner);
        console2.log("Fee recipient:", feeRecipient);
        console2.log("Platform fee (bps):", platformFeeBps);
    }
}
