// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/nft/SeedPass.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * @title MockUSDT
 * @dev Mock USDT token for testing
 */
contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {
        _mint(msg.sender, 1000000 * 10 ** 6); // 1M USDT
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
    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public agent1 = makeAddr("agent1");
    address public agent2 = makeAddr("agent2");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");
    address public nonWhitelisted = makeAddr("nonWhitelisted");
    address public attacker = makeAddr("attacker");

    // --- Test Constants ---
    uint256 public constant PRICE_USDT = 29 * 10 ** 6; // 29 USDT
    uint256 public constant MAX_SUPPLY = 400;
    uint256 public constant MAX_PER_WALLET = 3;

    // --- Role Constants ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AGENT_MINTER_ROLE = keccak256("AGENT_MINTER_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

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
    event BaseURIUpdated(string newBaseURI);
    event TreasuryWithdraw(address indexed token, uint256 amount);
    event AgentUpdated(address indexed agent, bool authorized);

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
        // Sort the leaves to ensure a canonical order
        bytes32 a = leaf1;
        bytes32 b = leaf2;
        if (a > b) {
            bytes32 temp = a;
            a = b;
            b = temp;
        }

        // Create the Merkle root from the sorted leaves
        merkleRoot = keccak256(abi.encodePacked(a, b));

        // The proof for a leaf is the hash of the other leaf
        user1Proof.push(leaf2);
        user2Proof.push(leaf1);

        seedPassImpl = new SeedPass();

        bytes memory initData = abi.encodeCall(
            SeedPass.initialize,
            ("SeedPass", "SEED", owner, address(usdt), treasury, merkleRoot, wlStartTime, wlEndTime)
        );

        // Deploy proxy
        proxy = new ERC1967Proxy(address(seedPassImpl), initData);
        seedPass = SeedPass(address(proxy));

        // Setup additional roles
        vm.startPrank(owner);
        seedPass.grantRole(ADMIN_ROLE, admin);
        seedPass.grantAgentRole(agent1);
        seedPass.grantAgentRole(agent2);
        vm.stopPrank();

        // Setup test users with USDT
        usdt.mint(user1, 1000 * 10 ** 6); // 1000 USDT
        usdt.mint(user2, 1000 * 10 ** 6);
        usdt.mint(user3, 1000 * 10 ** 6);
        usdt.mint(nonWhitelisted, 1000 * 10 ** 6);

        // Approve spending
        vm.prank(user1);
        usdt.approve(address(seedPass), type(uint256).max);
        vm.prank(user2);
        usdt.approve(address(seedPass), type(uint256).max);
        vm.prank(user3);
        usdt.approve(address(seedPass), type(uint256).max);
        vm.prank(nonWhitelisted);
        usdt.approve(address(seedPass), type(uint256).max);
    }

    // --- Initialization Tests ---

    function test_Initialize() public view {
        assertEq(seedPass.name(), "SeedPass");
        assertEq(seedPass.symbol(), "SEED");
        assertEq(seedPass.owner(), owner);
        assertEq(address(seedPass.usdtToken()), address(usdt));
        assertEq(seedPass.treasuryReceiver(), treasury);
        assertEq(seedPass.whitelistMerkleRoot(), merkleRoot);

        // Updated to use the new config struct
        (uint64 wlStart, uint64 wlEnd, bool active, bool metadataFrozen, uint16 publicMinted, uint16 reservedMinted) =
            seedPass.config();
        assertEq(wlStart, wlStartTime);
        assertEq(wlEnd, wlEndTime);
        assertTrue(active);
        assertFalse(metadataFrozen);
        assertEq(publicMinted, 0);
        assertEq(reservedMinted, 0);

        // Check roles
        assertTrue(seedPass.hasRole(seedPass.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(seedPass.hasRole(ADMIN_ROLE, owner));
        assertTrue(seedPass.hasRole(ADMIN_ROLE, admin));
        assertTrue(seedPass.hasRole(TREASURER_ROLE, treasury));
        assertTrue(seedPass.hasRole(AGENT_MINTER_ROLE, agent1));

        // Check initial state
        assertFalse(seedPass.paused());
    }

    function test_Initialize_ZeroAddressReverts() public {
        SeedPass temporaryImpl = new SeedPass();

        bytes memory initDataWithZeroOwner = abi.encodeCall(
            SeedPass.initialize,
            (
                "Test",
                "TEST",
                address(0), // Zero owner address
                address(usdt),
                treasury,
                merkleRoot,
                wlStartTime,
                wlEndTime
            )
        );

        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new ERC1967Proxy(address(temporaryImpl), initDataWithZeroOwner);
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert("ERC721A__Initializable: contract is already initialized");
        seedPass.initialize("Test", "TEST", owner, address(usdt), treasury, bytes32(0), wlStartTime, wlEndTime);
    }

    // --- Whitelist Mint Tests ---

    function test_WhitelistMint_Success() public {
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

        // Updated to access publicMinted through the config struct
        (,,,, uint16 publicMinted,) = seedPass.config();
        assertEq(publicMinted, quantity);
        assertEq(seedPass.numberMinted(user1), quantity);
    }

    function test_WhitelistMint_InvalidProof() public {
        vm.warp(wlStartTime);

        vm.expectRevert("NotWhitelisted");
        vm.prank(nonWhitelisted);
        seedPass.mint(1, user1Proof); // Wrong proof
    }

    function test_WhitelistMint_ExceedsWalletLimit() public {
        vm.warp(wlStartTime);

        // First mint 3 (max)
        vm.prank(user1);
        seedPass.mint(3, user1Proof);

        // Try to mint 1 more
        vm.expectRevert("ExceedsWalletLimit");
        vm.prank(user1);
        seedPass.mint(1, user1Proof);
    }

    function test_WhitelistMint_BeforeStart() public {
        vm.warp(wlStartTime - 1);

        vm.expectRevert("PublicSaleNotStarted");
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

        (,,,, uint16 publicMinted,) = seedPass.config();
        assertEq(publicMinted, quantity);
    }

    function test_PublicMint_NoProofRequired() public {
        vm.warp(wlEndTime + 1);

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
        emit AgentMint(agent1, user1, 5);
        vm.expectEmit(true, true, true, true);
        emit AgentMint(agent1, user2, 3);

        vm.prank(agent1);
        seedPass.agentMint(recipients, quantities);

        assertEq(seedPass.balanceOf(user1), 5);
        assertEq(seedPass.balanceOf(user2), 3);

        (,,,,, uint16 reservedMinted) = seedPass.config();
        assertEq(reservedMinted, 8);
    }

    function test_AgentMint_OnlyAgent() public {
        address[] memory recipients = new address[](1);
        uint256[] memory quantities = new uint256[](1);
        recipients[0] = user1;
        quantities[0] = 1;

        vm.expectRevert();
        vm.prank(user1);
        seedPass.agentMint(recipients, quantities);
    }

    function test_AgentMint_ExceedsReservedAllocation() public {
        address[] memory recipients = new address[](1);
        uint256[] memory quantities = new uint256[](1);
        recipients[0] = user1;
        quantities[0] = 101; // Exceeds 100 reserved

        vm.expectRevert("ExceedsReservedAllocation");
        vm.prank(agent1);
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

        vm.prank(agent1);
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
        vm.expectRevert("ExceedsMaxSupply");
        vm.prank(user3);
        seedPass.mint(300, new bytes32[](0)); // Would exceed 400
    }

    // --- Admin Function Tests ---

    function test_SetSaleConfig() public {
        uint256 newWlStart = block.timestamp + 2 hours;
        uint256 newWlEnd = newWlStart + 12 hours;

        vm.prank(owner);
        seedPass.setSaleConfig(newWlStart, newWlEnd, false);

        (uint64 wlStart, uint64 wlEnd, bool active,,,) = seedPass.config();
        assertEq(wlStart, newWlStart);
        assertEq(wlEnd, newWlEnd);
        assertFalse(active);
    }

    function test_SetWhitelistRoot() public {
        bytes32 newRoot = keccak256("new root");

        vm.prank(owner);
        seedPass.setWhitelistRoot(newRoot);

        assertEq(seedPass.whitelistMerkleRoot(), newRoot);
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

    function test_SetTreasuryReceiver_UpdatesRole() public {
        address newTreasury = makeAddr("newTreasury");
        address oldTreasury = seedPass.treasuryReceiver();

        vm.prank(owner);
        seedPass.setTreasuryReceiver(newTreasury);

        assertEq(seedPass.treasuryReceiver(), newTreasury);
        assertFalse(seedPass.hasRole(TREASURER_ROLE, oldTreasury));
        assertTrue(seedPass.hasRole(TREASURER_ROLE, newTreasury));
    }

    // --- Role Management Tests ---

    function test_GrantAgentRole_Success() public {
        address newAgent = makeAddr("newAgent");

        vm.expectEmit(true, true, true, true);
        emit AgentUpdated(newAgent, true);

        vm.prank(admin);
        seedPass.grantAgentRole(newAgent);

        assertTrue(seedPass.hasRole(AGENT_MINTER_ROLE, newAgent));
    }

    function test_RevokeAgentRole_Success() public {
        vm.expectEmit(true, true, true, true);
        emit AgentUpdated(agent1, false);

        vm.prank(admin);
        seedPass.revokeAgentRole(agent1);

        assertFalse(seedPass.hasRole(AGENT_MINTER_ROLE, agent1));
    }

    // --- View Function Tests ---

    function test_GetCurrentPhase() public {
        assertEq(seedPass.getCurrentPhase(), "UPCOMING");

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

        vm.prank(agent1);
        seedPass.agentMint(recipients, quantities);

        assertEq(seedPass.getRemainingReservedSupply(), 90);
    }

    // --- Edge Case Tests ---

    function test_MintZeroAmount() public {
        vm.warp(wlStartTime);

        vm.expectRevert("InvalidAmount");
        vm.prank(user1);
        seedPass.mint(0, user1Proof);
    }

    function test_SaleInactive() public {
        vm.prank(owner);
        seedPass.setSaleConfig(wlStartTime, wlEndTime, false);

        vm.warp(wlStartTime);

        vm.expectRevert("SaleNotActive");
        vm.prank(user1);
        seedPass.mint(1, user1Proof);
    }

    function test_InsufficientUSDTBalance() public {
        vm.warp(wlStartTime);

        // User1 has 1000 USDT, but we will reduce it to 10
        vm.prank(user1);
        usdt.transfer(user2, 990 * 10 ** 6); // Leave only 10 USDT

        vm.expectRevert();
        vm.prank(user1);
        seedPass.mint(1, user1Proof);
    }

    // --- Upgrade Tests ---

    function test_UpgradeAuthorization() public {
        address newImpl = address(new SeedPass());

        // Only owner can upgrade
        vm.expectRevert();
        vm.prank(user1);
        seedPass.upgradeToAndCall(newImpl, "");

        // Owner can upgrade
        vm.prank(admin);
        seedPass.upgradeToAndCall(newImpl, "");
    }

    // --- Integration Tests ---

    function test_CompleteWorkflow() public {
        // 1. Pause contract
        vm.prank(admin);
        seedPass.pause();

        // 2. Set metadata
        vm.prank(admin);
        seedPass.setBaseURI("https://api.example.com/");

        // 3. Unpause and start sale
        vm.prank(admin);
        seedPass.unpause();

        // 4. Agent premint
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = makeAddr("premintUser");
        amounts[0] = 20;

        vm.prank(agent1);
        seedPass.agentMint(recipients, amounts);

        // 5. Whitelist mint
        vm.warp(wlStartTime);
        vm.prank(user1);
        seedPass.mint(3, user1Proof);

        // 6. Public mint
        vm.warp(wlEndTime + 1);
        vm.prank(user3);
        seedPass.mint(2, new bytes32[](0));

        // 7. Freeze metadata
        vm.prank(admin);
        seedPass.freezeMetadata();

        // 8. Verify final state
        assertEq(seedPass.totalSupply(), 25); // 20 + 3 + 2

        (,,, bool metadataFrozen, uint16 publicMinted, uint16 reservedMinted) = seedPass.config();
        assertEq(publicMinted, 5); // 3 + 2
        assertEq(reservedMinted, 20);
        assertTrue(metadataFrozen);
    }
}
