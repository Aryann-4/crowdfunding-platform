// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CrowdfundingPlatform} from "../src/CrowdfundingPlatform.sol";

/**
 * @title Deploy
 * @notice Deploys {CrowdfundingPlatform} using configuration from the environment.
 *
 * Required:
 *  - PRIVATE_KEY       non-zero private key of the deploying account
 *
 * Optional:
 *  - OWNER             defaults to the deployer (empty or zero address is ignored)
 *  - FEE_RECIPIENT     defaults to OWNER (empty or zero address is ignored)
 *  - PLATFORM_FEE_BPS  defaults to 0, max 500
 *
 * Example:
 *  forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
 */
contract Deploy is Script {
    function run() external returns (CrowdfundingPlatform platform) {
        string memory privateKeyString = vm.envOr("PRIVATE_KEY", string(""));
        require(bytes(privateKeyString).length != 0, "PRIVATE_KEY is required");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        require(deployerPrivateKey != 0, "PRIVATE_KEY must be non-zero");
        require(
            bytes(privateKeyString).length == 66 || bytes(privateKeyString).length == 64, "PRIVATE_KEY must be 32 bytes"
        );

        address deployer = vm.addr(deployerPrivateKey);

        address owner = _envAddressOrDefault("OWNER", deployer);
        address feeRecipient = _envAddressOrDefault("FEE_RECIPIENT", owner);
        uint256 platformFeeBps = _envUintOrDefault("PLATFORM_FEE_BPS", 0);

        vm.startBroadcast(deployerPrivateKey);

        platform = new CrowdfundingPlatform(owner, feeRecipient, platformFeeBps);

        vm.stopBroadcast();

        console2.log("CrowdfundingPlatform deployed at:", address(platform));
        console2.log("Deployer:", deployer);
        console2.log("Owner:", owner);
        console2.log("Fee recipient:", feeRecipient);
        console2.log("Platform fee (bps):", platformFeeBps);
    }

    /**
     * @dev Reads an address from the environment, falling back when the variable
     *      is missing, empty, or set to the zero-address placeholder.
     */
    function _envAddressOrDefault(string memory key, address defaultValue) private view returns (address) {
        string memory raw = vm.envOr(key, string(""));
        if (bytes(raw).length == 0) return defaultValue;

        address parsed = vm.parseAddress(raw);
        return parsed == address(0) ? defaultValue : parsed;
    }

    /**
     * @dev Reads a uint from the environment, falling back when the variable is
     *      missing or empty.
     */
    function _envUintOrDefault(string memory key, uint256 defaultValue) private view returns (uint256) {
        string memory raw = vm.envOr(key, string(""));
        if (bytes(raw).length == 0) return defaultValue;
        return vm.parseUint(raw);
    }
}
