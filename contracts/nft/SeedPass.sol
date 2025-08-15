// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "ERC721A-Upgradeable/contracts/ERC721AUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/common/ERC2981Upgradeable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";

import "openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title SeedPass
 * @dev ERC721A NFT contract with UUPS upgradeability, ERC2981 royalties, and USDT payments
 * Specifications from AGV deployment runbook:
 * - Total Supply: 400 NFTs
 * - Public Allocation: 300 NFTs
 * - Reserved/Agent Premint: 100 NFTs
 * - Max Per Wallet: 3 NFTs
 * - WL Price: 29 USDT
 * - Public Price: 29 USDT
 * - Agent Price: 29 USDT
 * - Royalty: 5% via ERC2981
 */
contract SeedPass is
    ERC721AUpgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC2981Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    //  ROLE CONSTANTS:
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AGENT_MINTER_ROLE = keccak256("AGENT_MINTER_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    // --- State Variables ---

    uint256 public constant MAX_SUPPLY = 400;
    uint256 public constant MAX_PER_WALLET = 3;
    uint256 public constant PUBLIC_ALLOCATION = 300;
    uint256 public constant RESERVED_ALLOCATION = 100;
    uint256 public constant PRICE_USDT = 29 * 10 ** 6; // 29 USDT (6 decimals)
    uint96 public constant ROYALTY_BPS = 500; // 5%

    bool public metadataFrozen = false;
    string private _baseTokenURI;

    struct SaleConfig {
        uint256 wlStartTime; // Start time for whitelisted sale
        uint256 wlEndTime; // End time for whitelisted sale
        bool saleActive; // Indicates if the sale is active
    }

    SaleConfig public saleConfig;
    IERC20 public usdtToken;
    bytes32 public whitelistMerkleRoot;
    address public treasuryReceiver;

    uint256 public publicMinted;
    uint256 public reservedMinted;

    // --- Errors ---
    error InsufficientUSDTBalance();
    error ExceedsMaxSupply();
    error ExceedsPublicAllocation();
    error ExceedsReservedAllocation();
    error ExceedsWalletLimit();
    error InvalidAmount();
    error SaleNotActive();
    error NotWhitelisted();
    error PublicSaleNotStarted();
    error WhitelistSaleEnded();
    error NotAuthorizedAgent();
    error InvalidConfiguration();
    error ExceedsMaxPerTx();
    error MetadataFrozen();
    error ZeroAddress();

    // ----- Events -----
    event PublicMint(address indexed minter, uint256 quantity, uint256 payment);
    event WhitelistMint(address indexed minter, uint256 quantity, uint256 payment);
    event AgentMint(address indexed agent, address indexed recipient, uint256 quantity);
    event SaleConfigUpdated(uint256 wlStartTime, uint256 wlEndTime, bool active);
    event WhitelistUpdated(bytes32 newRoot);
    event AgentUpdated(address indexed agent, bool authorized);
    event MetadataFrozened();
    event BaseURIUpdated(string newBaseURI);
    event TreasuryWithdraw(address indexed token, uint256 amount);

    // --- Initialization ---

    function initialize(
        string memory name,
        string memory symbol,
        address owner,
        address usdtAddress,
        address treasury,
        bytes32 initialMerkleRoot,
        uint256 wlStartTime,
        uint256 wlEndTime
    ) public initializerERC721A initializer {
        __ERC721A_init(name, symbol);
        __Ownable_init(owner);
        __UUPSUpgradeable_init();
        __ERC2981_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        if (usdtAddress == address(0)) revert ZeroAddress();
        if (treasury == address(0)) revert ZeroAddress();
        if (owner == address(0)) revert ZeroAddress();

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(ADMIN_ROLE, owner);
        _grantRole(TREASURER_ROLE, treasury);

        usdtToken = IERC20(usdtAddress);
        treasuryReceiver = treasury;
        whitelistMerkleRoot = initialMerkleRoot;

        saleConfig = SaleConfig({
            wlStartTime: wlStartTime,
            wlEndTime: wlEndTime,
            saleActive: true // Sale starts active
        });

        // Set default royalty to treasury at 5%
        _setDefaultRoyalty(treasury, ROYALTY_BPS);
    }

    // --- Public Functions ---

    /**
     * @dev Mint tokens during whitelist or public sale
     * @param amount Number of tokens to mint
     * @param merkleProof Merkle proof for whitelist (empty for public)
     */
    function mint(uint256 amount, bytes32[] calldata merkleProof) external nonReentrant whenNotPaused {
        if (!saleConfig.saleActive) revert SaleNotActive();
        if (amount == 0) revert InvalidAmount();
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        if (_numberMinted(msg.sender) + amount > MAX_PER_WALLET) {
            revert ExceedsWalletLimit();
        }

        bool isWhitelistPeriod = block.timestamp >= saleConfig.wlStartTime && block.timestamp <= saleConfig.wlEndTime;
        bool isPublicPeriod = block.timestamp > saleConfig.wlEndTime;

        if (isWhitelistPeriod) {
            // Whitelist sale
            if (!_verifyWhitelist(msg.sender, merkleProof)) {
                revert NotWhitelisted();
            }
            if (publicMinted + amount > PUBLIC_ALLOCATION) {
                revert ExceedsPublicAllocation();
            }

            publicMinted += amount;
            uint256 payment = amount * PRICE_USDT;
            usdtToken.safeTransferFrom(msg.sender, treasuryReceiver, payment);

            _safeMint(msg.sender, amount);
            emit WhitelistMint(msg.sender, amount, payment);
        } else if (isPublicPeriod) {
            // Public sale
            if (publicMinted + amount > PUBLIC_ALLOCATION) {
                revert ExceedsPublicAllocation();
            }

            publicMinted += amount;
            uint256 payment = amount * PRICE_USDT;
            usdtToken.safeTransferFrom(msg.sender, treasuryReceiver, payment);

            _safeMint(msg.sender, amount);
            emit PublicMint(msg.sender, amount, payment);
        } else {
            revert PublicSaleNotStarted();
        }
    }

    /**
     * @dev Agent mint for airdrops and reserved allocations
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts per recipient
     */
    function agentMint(address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyRole(AGENT_MINTER_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (recipients.length != amounts.length) revert InvalidConfiguration();

        uint256 totalQuantity = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalQuantity += amounts[i];
        }

        if (totalSupply() + totalQuantity > MAX_SUPPLY) {
            revert ExceedsMaxSupply();
        }
        if (reservedMinted + totalQuantity > RESERVED_ALLOCATION) {
            revert ExceedsReservedAllocation();
        }

        reservedMinted += totalQuantity;

        for (uint256 i = 0; i < recipients.length; i++) {
            if (amounts[i] > 0) {
                _safeMint(recipients[i], amounts[i]);
                emit AgentMint(msg.sender, recipients[i], amounts[i]);
            }
        }
    }

    // ---- Admin Functions ----

    /**
     * @dev Update sale configuration
     */
    function setSaleConfig(uint256 wlStartTime, uint256 wlEndTime, bool active) external onlyRole(ADMIN_ROLE) {
        saleConfig = SaleConfig({wlStartTime: wlStartTime, wlEndTime: wlEndTime, saleActive: active});
        emit SaleConfigUpdated(wlStartTime, wlEndTime, active);
    }

    /**
     * @dev Update whitelist merkle root
     */
    function setWhitelistRoot(bytes32 newRoot) external onlyRole(ADMIN_ROLE) {
        whitelistMerkleRoot = newRoot;
        emit WhitelistUpdated(newRoot);
    }

    /**
     * @dev Authorize/deauthorize agent minters
     */
    function grantAgentRole(address agent) external onlyRole(ADMIN_ROLE) {
        if (agent == address(0)) revert ZeroAddress();
        _grantRole(AGENT_MINTER_ROLE, agent);
        emit AgentUpdated(agent, true);
    }

    /**
     * @dev Revoke agent minter role
     * Requirements:
     * - Caller must have ADMIN_ROLE
     * - Agent must be currently authorized
     */
    function revokeAgentRole(address agent) external onlyRole(ADMIN_ROLE) {
        _revokeRole(AGENT_MINTER_ROLE, agent);
        emit AgentUpdated(agent, false);
    }

    /**
     * @dev Update treasury receiver (address where USDT payments for NFT go)
     */
    function setTreasuryReceiver(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();

        revokeRole(TREASURER_ROLE, treasuryReceiver);
        _grantRole(TREASURER_ROLE, newTreasury);

        treasuryReceiver = newTreasury;
    }

    /**
     * @dev Update royalty information
     */
    function setRoyaltyInfo(address receiver, uint96 fee) external onlyRole(ADMIN_ROLE) {
        if (receiver == address(0)) revert ZeroAddress();
        _setDefaultRoyalty(receiver, fee);
    }

    /**
     * @dev Set base URI for metadata
     */
    function setBaseURI(string calldata newBaseURI) external onlyRole(ADMIN_ROLE) {
        if (metadataFrozen) revert MetadataFrozen();
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function freezeMetadata() external onlyRole(ADMIN_ROLE) {
        metadataFrozen = true;
        emit MetadataFrozened();
    }

    /**
     * @dev Withdraw treasury funds (USDT or native token)
     * @param token Address of the token to withdraw (0x for native token)
     * Requirements:
     * - Caller must have TREASURER_ROLE
     * - Contract must have a balance of the specified token
     */
    function withdrawTreasury(address token) external onlyRole(TREASURER_ROLE) {
        if (token == address(0)) {
            // Withdraw native token
            uint256 balance = address(this).balance;
            if (balance > 0) {
                (bool success,) = payable(treasuryReceiver).call{value: balance}("");
                require(success, "Transfer failed");
                emit TreasuryWithdraw(address(0), balance);
            }
        } else {
            // Withdraw ERC20 token
            IERC20 tokenContract = IERC20(token);
            uint256 balance = tokenContract.balanceOf(address(this));
            if (balance > 0) {
                tokenContract.safeTransfer(treasuryReceiver, balance);
                emit TreasuryWithdraw(token, balance);
            }
        }
    }

    /**
     * @dev Pause the contract (disables minting and transfers)
     * Requirements:
     * - Caller must have ADMIN_ROLE
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract (enables minting and transfers)
     * Requirements:
     * - Caller must have ADMIN_ROLE
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Override _startTokenId to start token IDs from 1 instead of 0
     * This is required by ERC721A to ensure correct token ID management.
     */
    function _startTokenId() internal pure override returns (uint256) {
        return 1; // Start token IDs from 1 instead of 0
    }

    // -------- View Functions --------

    /**
     * @dev This function is required to be overridden due to a conflict in the
     * `supportsInterface` function between ERC721Upgradeable and ERC2981Upgradeable.
     * It ensures that the contract correctly reports support for both the
     * ERC-721 token standard and the ERC-2981 royalty standard, allowing
     * marketplaces and other contracts to properly interact with this NFT.
     *
     * @param interfaceId The interface identifier, as specified in ERC-165.
     * @return True if the contract supports the interface, false otherwise.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721AUpgradeable, AccessControlUpgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Get current mint phase
     */
    function getCurrentPhase() external view returns (string memory) {
        if (!saleConfig.saleActive) return "INACTIVE";
        if (block.timestamp < saleConfig.wlStartTime) return "UPCOMING";
        if (block.timestamp <= saleConfig.wlEndTime) return "WHITELIST";
        return "PUBLIC";
    }

    /**
     * @dev Get remaining supply for public allocation
     */
    function getRemainingPublicSupply() external view returns (uint256) {
        return PUBLIC_ALLOCATION - publicMinted;
    }

    /**
     * @dev Get remaining supply for reserved allocation
     */
    function getRemainingReservedSupply() external view returns (uint256) {
        return RESERVED_ALLOCATION - reservedMinted;
    }

    /**
     * @dev Get number of tokens minted by address
     */
    function numberMinted(address owner) external view returns (uint256) {
        return _numberMinted(owner);
    }

    /**
     * @dev Returns the base URI for the NFT metadata.
     * This function is used to retrieve the metadata URI for a given token ID.
     * It can be overridden in derived contracts to provide a custom base URI.
     *
     * @return The base URI as a string.
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }

    // --- Internal Helper Functions ---

    /**
     * @dev Authorize upgrade for UUPS proxy
     * This function is called by the UUPS proxy to authorize upgrades.
     * Only the owner can authorize upgrades.
     *
     * @param newImplementation The address of the new implementation contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
    }

    /**
     * @dev Verify if an address is whitelisted using Merkle proof
     * @param account Address to verify
     * @param proof Merkle proof for the whitelist
     * @return True if the address is whitelisted, false otherwise
     */
    function _verifyWhitelist(address account, bytes32[] calldata proof) internal view returns (bool) {
        if (whitelistMerkleRoot == bytes32(0)) return false;
        bytes32 leaf = keccak256(abi.encodePacked(account));
        return MerkleProof.verify(proof, whitelistMerkleRoot, leaf);
    }

    // --- Upgrade Gap ---
    // This is used to reserve space for future upgrades without breaking existing storage layout.
    uint256[45] private __gap;
}
