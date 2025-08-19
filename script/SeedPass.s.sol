// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/SeedPass.sol";
import "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";


contract SeedPassScript is Script {
    // Configuration constants
    string constant NAME = "SeedPass";
    string constant SYMBOL = "SEED";
    
    // Replace these with your actual addresses
    address constant OWNER = 0x742C6C60C04B6f2D91Ab1c46f800D0d12fF1C3A9; // Replace with owner address
    address constant USDT_MAINNET = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    // address constant USDT_POLYGON = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
    address constant TREASURY = 0x123...; // Replace with treasury address
    
    bytes32 constant INITIAL_MERKLE_ROOT = 0x0000000000000000000000000000000000000000000000000000000000000000;


    function run() external {
        // Load private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        
        // Determine USDT address based on chain
        uint256 chainId = block.chainid;
        address usdtAddress = getUSDTAddress(chainId);
        
        console.log("Chain ID:", chainId);
        console.log("USDT Address:", usdtAddress);
        
        // Calculate timestamps
        uint256 wlStartTime = block.timestamp + 1 hours;
        uint256 wlEndTime = block.timestamp + 7 days;
        
        console.log("WL Start Time:", wlStartTime);
        console.log("WL End Time:", wlEndTime);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy implementation
        console.log("Deploying SeedPass implementation...");
        SeedPass implementation = new SeedPass();
        console.log("Implementation deployed at:", address(implementation));
        
        // Prepare initialization data
        bytes memory initData = abi.encodeCall(
            SeedPass.initialize,
            (
                NAME,
                SYMBOL,
                OWNER,
                usdtAddress,
                TREASURY,
                INITIAL_MERKLE_ROOT,
                wlStartTime,
                wlEndTime
            )
        );
        
        // Deploy proxy
        console.log("Deploying ERC1967Proxy...");
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        console.log("Proxy deployed at:", address(proxy));
        
        vm.stopBroadcast();
        
        // Test the deployed contract
        testDeployedContract(address(proxy));
        
        // Log important addresses
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network Chain ID:", chainId);
        console.log("Contract Address (Proxy):", address(proxy));
        console.log("Implementation Address:", address(implementation));
        console.log("Owner:", OWNER);
        console.log("Treasury:", TREASURY);
        console.log("USDT Token:", usdtAddress);
        
        // Save deployment info
        saveDeploymentInfo(chainId, address(proxy), address(implementation));
    }


    function getUSDTAddress(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) {
            // Ethereum Mainnet
            return USDT_MAINNET;
        } else if (chainId == 137) {
            // Polygon
            return USDT_POLYGON;
        } else if (chainId == 11155111) {
            // Sepolia - use a mock address or deploy mock USDT
            return 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06; // Mock USDT on Sepolia
        } else {
            // For other networks, you might want to deploy a mock USDT
            revert("Unsupported network");
        }
    }


    function testDeployedContract(address proxyAddress) internal view {
        console.log("\n=== TESTING DEPLOYED CONTRACT ===");
        
        SeedPass seedpass = SeedPass(proxyAddress);
        
        try {
            string memory name = seedpass.name();
            string memory symbol = seedpass.symbol();
            uint256 totalSupply = seedpass.totalSupply();
            uint256 maxSupply = seedpass.MAX_SUPPLY();
            string memory currentPhase = seedpass.getCurrentPhase();
            uint256 remainingPublic = seedpass.getRemainingPublicSupply();
            uint256 remainingReserved = seedpass.getRemainingReservedSupply();
            
            console.log("Name:", name);
            console.log("Symbol:", symbol);
            console.log("Total Supply:", totalSupply);
            console.log("Max Supply:", maxSupply);
            console.log("Current Phase:", currentPhase);
            console.log("Remaining Public:", remainingPublic);
            console.log("Remaining Reserved:", remainingReserved);
            
            console.log("✅ Contract tests passed!");
        } catch {
            console.log("❌ Contract tests failed!");
        }
    }

}