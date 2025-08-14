// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/nft/SeedPass.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDT
 * @dev Mock USDT token for testing
 */
contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {
        _mint(msg.sender, 1000000 * 10**6); // 1M USDT
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title SeedPassTest
 * @dev Comprehensive test suite for SeedPass contract
 */
contract SeedPassTest is Test {
    
    // --- Test Contracts ---
    SeedPass public seedPassImpl;
    SeedPass public seedPass;
    MockUSDT public usdt;
    ERC1967Proxy public proxy;

    // --- Test Addresses ---
    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");
    address public agent = makeAddr("agent");
    address public nonWhitelisted = makeAddr("nonWhitelisted");

    // --- Test Constants ---
    uint256 public constant PRICE_USDT = 29 * 10**6; // 29 USDT
    uint256 public constant MAX_SUPPLY = 400;
    uint256 public constant MAX_PER_WALLET = 3;
    
    // --- Test Variables ---
    bytes32 public merkleRoot;
    bytes32[] public user1Proof;
    bytes32[] public user2Proof;
    uint256 public wlStartTime;
    uint256 public wlEndTime;

    // --- Events for Testing ---
    event PublicMint(address indexed minter, uint256 quantity, uint256 payment);
    event WhitelistMint(address indexed minter, uint256 quantity, uint256 payment);
    event AgentMint(address indexed agent, address indexed recipient, uint256 quantity);

    function setUp() public {
        // Set up time
        wlStartTime = block.timestamp + 1 hours;
        wlEndTime = wlStartTime + 24 hours;

        // Deploy mock USDT
        usdt = new MockUSDT();

        // Create simple merkle tree for testing
        // user1 and user2 are whitelisted, user3 and nonWhitelisted are not
        bytes32 leaf1 = keccak256(abi.encodePacked(user1));
        bytes32 leaf2 = keccak256(abi.encodePacked(user2));
        merkleRoot = keccak256(abi.encodePacked(leaf1, leaf2));
        
        // Create proofs
        user1Proof.push(keccak256(abi.encodePacked(user2)));
        user2Proof.push(keccak256(abi.encodePacked(user1)));

        // Deploy implementation
        seedPassImpl = new SeedPass();

        // Prepare initialization data
        bytes memory initData = abi.encodeCall(
            SeedPass.initialize,
            (
                "SeedPass",
                "SEED",
                owner,
                address(usdt),
                treasury,
                merkleRoot,
                wlStartTime,
                wlEndTime
            )
        );

        // Deploy proxy
        proxy = new ERC1967Proxy(address(seedPassImpl), initData);
        seedPass = SeedPass(address(proxy));

        // Setup test users with USDT
        usdt.mint(user1, 1000 * 10**6); // 1000 USDT
        usdt.mint(user2, 1000 * 10**6);
        usdt.mint(user3, 1000 * 10**6);
        usdt.mint(nonWhitelisted, 1000 * 10**6);

        // Approve spending
        vm.prank(user1);
        usdt.approve(address(seedPass), type(uint256).max);
        vm.prank(user2);
        usdt.approve(address(seedPass), type(uint256).max);
        vm.prank(user3);
        usdt.approve(address(seedPass), type(uint256).max);
        vm.prank(nonWhitelisted);
        usdt.approve(address(seedPass), type(uint256).max);

        // Set up agent
        vm.prank(owner);
        seedPass.setAgentMinter(agent, true);
    }

    // --- Initialization Tests ---

    function test_Initialize() public {
        assertEq(seedPass.name(), "SeedPass");
        assertEq(seedPass.symbol(), "SEED");
        assertEq(seedPass.owner(), owner);
        assertEq(address(seedPass.usdtToken()), address(usdt));
        assertEq(seedPass.treasuryReceiver(), treasury);
        assertEq(seedPass.whitelistMerkleRoot(), merkleRoot);
        
        (uint256 wlStart, uint256 wlEnd, bool active) = seedPass.saleConfig();
        assertEq(wlStart, wlStartTime);
        assertEq(wlEnd, wlEndTime);
        assertTrue(active);
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert("Initializable: contract is already initialized");
        seedPass.initialize(
            "Test", "TEST", owner, address(usdt), treasury, 
            bytes32(0), wlStartTime, wlEndTime
        );
    }

    // --- Whitelist Mint Tests ---

    function test_WhitelistMint_Success() public {
        // Fast forward to whitelist period
        vm.warp(wlStartTime);

        uint256 quantity = 2;
        uint256 expectedPayment = quantity * PRICE_USDT;
        uint256 treasuryBalanceBefore = usdt.balanceOf(treasury);

        vm.expectEmit(true, true, true, true);
        emit WhitelistMint(user1, quantity, expectedPayment);

        vm.prank(user1);
        seedPass.mint(quantity, user1Proof);

        // Check balances
        assertEq(seedPass.balanceOf(user1), quantity);
        assertEq(usdt.balanceOf(treasury), treasuryBalanceBefore + expectedPayment);
        assertEq(seedPass.publicMinted(), quantity);
        assertEq(seedPass.numberMinted(user1), quantity);
    }

    function test_WhitelistMint_InvalidProof() public {
        vm.warp(wlStartTime);

        vm.expectRevert("Not whitelisted");
        vm.prank(nonWhitelisted);
        seedPass.mint(1, user1Proof); // Wrong proof
    }

    function test_WhitelistMint_ExceedsWalletLimit() public {
        vm.warp(wlStartTime);

        // First mint 3 (max)
        vm.prank(user1);
        seedPass.mint(3, user1Proof);

        // Try to mint 1 more
        vm.expectRevert("Exceeds wallet limit");
        vm.prank(user1);
        seedPass.mint(1, user1Proof);
    }

    function test_WhitelistMint_BeforeStart() public {
        vm.warp(wlStartTime - 1);

        vm.expectRevert("Public sale not started");
        vm.prank(user1);
        seedPass.mint(1, user1Proof);
    }

    // --- Public Mint Tests ---

    function test_PublicMint_Success() public {
        // Fast forward to public period
        vm.warp(wlEndTime + 1);

        uint256 quantity = 2;
        uint256 expectedPayment = quantity * PRICE_USDT;

        vm.expectEmit(true, true, true, true);
        emit PublicMint(user3, quantity, expectedPayment);

        vm.prank(user3);
        seedPass.mint(quantity, new bytes32[](0)); // No proof needed for public

        assertEq(seedPass.balanceOf(user3), quantity);
        assertEq(seedPass.publicMinted(), quantity);
    }

    function test_PublicMint_NoProofRequired() public {
        vm.warp(wlEndTime + 1);

        // Non-whitelisted user can mint in public sale
        vm.prank(nonWhitelisted);
        seedPass.mint(1, new bytes32[](0));

        assertEq(seedPass.balanceOf(nonWhitelisted), 1);
    }

    // --- Agent Mint Tests ---

    function test_AgentMint_Success() public {
        address[] memory recipients = new address[](2);
        uint256[] memory quantities = new uint256[](2);
        
        recipients[0] = user1;
        recipients[1] = user2;
        quantities[0] = 5;
        quantities[1] = 3;

        vm.expectEmit(true, true, true, true);
        emit AgentMint(agent, user1, 5);
        vm.expectEmit(true, true, true, true);
        emit AgentMint(agent, user2, 3);

        vm.prank(agent);
        seedPass.agentMint(recipients, quantities);

        assertEq(seedPass.balanceOf(user1), 5);
        assertEq(seedPass.balanceOf(user2), 3);
        assertEq(seedPass.reservedMinted(), 8);
    }

    function test_AgentMint_OnlyAgent() public {
        address[] memory recipients = new address[](1);
        uint256[] memory quantities = new uint256[](1);
        recipients[0] = user1;
        quantities[0] = 1;

        vm.expectRevert("Not authorized agent");
        vm.prank(user1);
        seedPass.agentMint(recipients, quantities);
    }

    function test_AgentMint_ExceedsReservedAllocation() public {
        address[] memory recipients = new address[](1);
        uint256[] memory quantities = new uint256[](1);
        recipients[0] = user1;
        quantities[0] = 101; // Exceeds 100 reserved

        vm.expectRevert(abi.encodeWithSelector(SeedPass.ExceedsReservedAllocation.selector));
        vm.prank(agent);
        seedPass.agentMint(recipients, quantities);
    }

    // --- Supply Limit Tests ---

    function test_ExceedsMaxSupply() public {
        vm.warp(wlEndTime + 1);

        // First, agent mints 100 (reserved)
        address[] memory recipients = new address[](1);
        uint256[] memory quantities = new uint256[](1);
        recipients[0] = user1;
        quantities[0] = 100;

        vm.prank(agent);
        seedPass.agentMint(recipients, quantities);

        // Then public mints 300
        vm.prank(user2);
        seedPass.mint(3, new bytes32[](0));
        
        // Try to mint 298 more (would exceed 400 total)
        vm.prank(user3);
        seedPass.mint(3, new bytes32[](0));

        // This should work (total = 100 + 3 + 3 = 106)
        assertEq(seedPass.totalSupply(), 106);

        // Now try to mint way too many
        vm.expectRevert("Exceeds max supply");
        vm.prank(user3);
        seedPass.mint(300, new bytes32[](0)); // Would exceed 400
    }

    // --- Admin Function Tests ---

    function test_SetSaleConfig() public {
        uint256 newWlStart = block.timestamp + 2 hours;
        uint256 newWlEnd = newWlStart + 12 hours;

        vm.prank(owner);
        seedPass.setSaleConfig(newWlStart, newWlEnd, false);

        (uint256 wlStart, uint256 wlEnd, bool active) = seedPass.saleConfig();
        assertEq(wlStart, newWlStart);
        assertEq(wlEnd, newWlEnd);
        assertFalse(active);
    }

    function test_SetSaleConfig_OnlyOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(user1);
        seedPass.setSaleConfig(wlStartTime, wlEndTime, true);
    }

    function test_SetWhitelistRoot() public {
        bytes32 newRoot = keccak256("new root");
        
        vm.prank(owner);
        seedPass.setWhitelistRoot(newRoot);
        
        assertEq(seedPass.whitelistMerkleRoot(), newRoot);
    }

    function test_SetAgentMinter() public {
        address newAgent = makeAddr("newAgent");
        
        vm.prank(owner);
        seedPass.setAgentMinter(newAgent, true);
        
        assertTrue(seedPass.agentMinters(newAgent));
        
        vm.prank(owner);
        seedPass.setAgentMinter(newAgent, false);
        
        assertFalse(seedPass.agentMinters(newAgent));
    }

    function test_SetTreasuryReceiver() public {
        address newTreasury = makeAddr("newTreasury");
        
        vm.prank(owner);
        seedPass.setTreasuryReceiver(newTreasury);
        
        assertEq(seedPass.treasuryReceiver(), newTreasury);
    }

    function test_SetRoyaltyInfo() public {
        address royaltyReceiver = makeAddr("royaltyReceiver");
        uint96 royaltyFee = 750; // 7.5%
        
        vm.prank(owner);
        seedPass.setRoyaltyInfo(royaltyReceiver, royaltyFee);
        
        (address receiver, uint256 amount) = seedPass.royaltyInfo(1, 10000);
        assertEq(receiver, royaltyReceiver);
        assertEq(amount, 750); // 7.5% of 10000
    }

    // --- View Function Tests ---

    function test_GetCurrentPhase() public {
        // Before whitelist
        assertEq(seedPass.getCurrentPhase(), "UPCOMING");
        
        // During whitelist
        vm.warp(wlStartTime);
        assertEq(seedPass.getCurrentPhase(), "WHITELIST");
        
        // During public
        vm.warp(wlEndTime + 1);
        assertEq(seedPass.getCurrentPhase(), "PUBLIC");
        
        // Inactive
        vm.prank(owner);
        seedPass.setSaleConfig(wlStartTime, wlEndTime, false);
        assertEq(seedPass.getCurrentPhase(), "INACTIVE");
    }

    function test_GetRemainingSupply() public {
        assertEq(seedPass.getRemainingPublicSupply(), 300);
        assertEq(seedPass.getRemainingReservedSupply(), 100);
        
        // After some mints
        vm.warp(wlEndTime + 1);
        vm.prank(user1);
        seedPass.mint(2, new bytes32[](0));
        
        assertEq(seedPass.getRemainingPublicSupply(), 298);
        
        address[] memory recipients = new address[](1);
        uint256[] memory quantities = new uint256[](1);
        recipients[0] = user2;
        quantities[0] = 10;
        
        vm.prank(agent);
        seedPass.agentMint(recipients, quantities);
        
        assertEq(seedPass.getRemainingReservedSupply(), 90);
    }

    // --- Edge Case Tests ---

    function test_MintZeroAmount() public {
        vm.warp(wlStartTime);
        
        vm.expectRevert("Amount must be greater than zero");
        vm.prank(user1);
        seedPass.mint(0, user1Proof);
    }

    function test_SaleInactive() public {
        vm.prank(owner);
        seedPass.setSaleConfig(wlStartTime, wlEndTime, false);
        
        vm.warp(wlStartTime);
        
        vm.expectRevert("Sale not active");
        vm.prank(user1);
        seedPass.mint(1, user1Proof);
    }

    function test_InsufficientUSDTBalance() public {
        vm.warp(wlStartTime);
        
        // Create user with insufficient balance
        address poorUser = makeAddr("poorUser");
        usdt.mint(poorUser, 10 * 10**6); // Only 10 USDT
        
        vm.prank(poorUser);
        usdt.approve(address(seedPass), type(uint256).max);
        
        // This will fail because user needs 29 USDT but only has 10
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(poorUser);
        seedPass.mint(1, user1Proof); // Assuming poorUser has valid proof
    }

    // --- Upgrade Tests ---

    function test_UpgradeAuthorization() public {
        address newImpl = address(new SeedPass());
        
        // Only owner can upgrade
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(user1);
        seedPass.upgradeToAndCall(newImpl, "");
        
        // Owner can upgrade
        vm.prank(owner);
        seedPass.upgradeToAndCall(newImpl, "");
    }

    // --- Fuzz Tests ---

    // function testFuzz_MintQuantity(uint256 quantity) public {
    //     vm.assume(quantity > 0 && quantity <= MAX_PER_WALLET);
    //     vm.warp(wlStartTime);
        
    //     vm.prank(user1);
    //     seedPass.mint(quantity, user1Proof);
        
    //     assertEq(seedPass.balanceOf(user1), quantity);
    //     assertEq(seedPass.numberMinted(user1), quantity);
    // }

    // function testFuzz_MintPrice(uint256 quantity) public {
    //     vm.assume(quantity > 0 && quantity <= MAX_PER_WALLET);
    //     vm.warp(wlStartTime);
        
    //     uint256 treasuryBefore = usdt.balanceOf(treasury);
    //     uint256 expectedPayment = quantity * PRICE_USDT;
        
    //     vm.prank(user1);
    //     seedPass.mint(quantity, user1Proof);
        
    //     assertEq(usdt.balanceOf(treasury), treasuryBefore + expectedPayment);
    // }

    // --- Integration Tests ---

    function test_FullMintingScenario() public {
        // 1. Agent premints 50 reserved
        address[] memory recipients = new address[](1);
        uint256[] memory quantities = new uint256[](1);
        recipients[0] = makeAddr("premintUser");
        quantities[0] = 50;
        
        vm.prank(agent);
        seedPass.agentMint(recipients, quantities);
        
        // 2. Whitelist period - user1 mints 3
        vm.warp(wlStartTime);
        vm.prank(user1);
        seedPass.mint(3, user1Proof);
        
        // 3. Still whitelist - user2 mints 2
        vm.prank(user2);
        seedPass.mint(2, user2Proof);
        
        // 4. Public period - user3 mints 1
        vm.warp(wlEndTime + 1);
        vm.prank(user3);
        seedPass.mint(1, new bytes32[](0));
        
        // Check final state
        assertEq(seedPass.totalSupply(), 56); // 50 + 3 + 2 + 1
        assertEq(seedPass.publicMinted(), 6); // 3 + 2 + 1
        assertEq(seedPass.reservedMinted(), 50);
        assertEq(seedPass.balanceOf(recipients[0]), 50);
        assertEq(seedPass.balanceOf(user1), 3);
        assertEq(seedPass.balanceOf(user2), 2);
        assertEq(seedPass.balanceOf(user3), 1);
    }
}