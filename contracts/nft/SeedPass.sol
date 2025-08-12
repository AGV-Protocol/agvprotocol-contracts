// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// import "ERC721A/contracts/ERC721A.sol";
import "ERC721A-Upgradeable/contracts/ERC721AUpgradeable.sol";
// import "../../lib/ERC721A/contracts/ERC721A.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/common/ERC2981Upgradeable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title SeedPass
 * @dev This contract implements an ERC721 NFT with royalty support using ERC2981.
 * It allows for minting a limited number of NFTs, with a maximum supply and per-wallet limit.
 * The contract is upgradeable and owned by a single owner.
 */
contract SeedPass is
    Initializable,
    ERC721AUpgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC2981Upgradeable
{
    using SafeERC20 for IERC20;
    // --- State Variables ---
    uint256 public constant MAX_SUPPLY = 400;
    uint256 public constant MAX_PER_WALLET = 3;
    uint256 public constant PUBLIC_ALLOCATION = 300;
    uint256 public constant RESERVED_ALLOCATION = 100;
    uint256 public constant PRICE_USDT = 29 * 10**6; // 29 USDT (6 decimals)
    uint96 public constant ROYALTY_BPS = 500; // 5%

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
    
    mapping(address => bool) public agentMinters;

    // --- Errors ---
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

    // ----- Events -----
     event PublicMint(address indexed minter, uint256 quantity, uint256 payment);
    event WhitelistMint(address indexed minter, uint256 quantity, uint256 payment);
    // event AgentMint(address indexed agent, address indexed recipient, uint256 quantity);
    // event SaleConfigUpdated(uint256 wlStartTime, uint256 wlEndTime, bool active);
    // event WhitelistUpdated(bytes32 newRoot);
    // event AgentUpdated(address indexed agent, bool authorized);

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
        // SaleConfig memory config
    ) public initializer {
        __ERC721A_init(name, symbol);
        __Ownable_init(owner);
        __UUPSUpgradeable_init();
        __ERC2981_init();

        if (usdtAddress == address(0) || treasury == address(0)) {
            revert InvalidConfiguration();
        }

        usdtToken = IERC20(usdtAddress);
        treasuryReceiver = treasury;
        whitelistMerkleRoot = initialMerkleRoot;
        
        saleConfig = SaleConfig({
            wlStartTime: wlStartTime,
            wlEndTime: wlEndTime,
            saleActive: false // Sale starts inactive // @audit should it start as active or inactive?
        });

        // Set default royalty to treasury at 5%
        _setDefaultRoyalty(treasury, ROYALTY_BPS);
    }

    // --- Public Functions ---
     function mint(uint256 amount, bytes32[] calldata merkleProof) external {
         if (!saleConfig.saleActive) revert SaleNotActive();
        if (amount == 0) revert InvalidAmount();
        if (totalSupply() + amount > MAX_SUPPLY) revert ExceedsMaxSupply();
        if (_numberMinted(msg.sender) + amount > MAX_PER_WALLET) revert ExceedsWalletLimit();

        bool isWhitelistPeriod = block.timestamp >= saleConfig.wlStartTime && 
                                block.timestamp <= saleConfig.wlEndTime;
        bool isPublicPeriod = block.timestamp > saleConfig.wlEndTime;

        if (isWhitelistPeriod) {
            // Whitelist sale
            if (!_verifyWhitelist(msg.sender, merkleProof)) revert NotWhitelisted();
            if (publicMinted + amount > PUBLIC_ALLOCATION) revert ExceedsPublicAllocation();
            
            publicMinted += amount;
            uint256 payment = amount * PRICE_USDT;
            usdtToken.safeTransferFrom(msg.sender, treasuryReceiver, payment);
            
            _safeMint(msg.sender, amount);
            emit WhitelistMint(msg.sender, amount, payment);
            
        } else if (isPublicPeriod) {
            // Public sale
            if (publicMinted + amount > PUBLIC_ALLOCATION) revert ExceedsPublicAllocation();
            
            publicMinted += amount;
            uint256 payment = amount * PRICE_USDT;
            usdtToken.safeTransferFrom(msg.sender, treasuryReceiver, payment);
            
            _safeMint(msg.sender, amount);
            emit PublicMint(msg.sender, amount, payment);
            
        } else {
            revert PublicSaleNotStarted();
        }
    }

    // --- Internal Helper Functions ---
    function _verifyMerkleProof(bytes32[] memory merkleProof) internal view returns (bool) {
        // Merkle proof verification logic here.
        // It would check against the whitelistMerkleRoot.
        return true; // Simplified for the sketch
    }

     function _verifyWhitelist(
        address account,
        bytes32[] calldata proof
    ) internal view returns (bool) {
        if (whitelistMerkleRoot == bytes32(0)) return false;
        bytes32 leaf = keccak256(abi.encodePacked(account));
        return MerkleProof.verify(proof, whitelistMerkleRoot, leaf);
    }

    // ---- Admin Functions ----

    function setRoyaltyInfo(address receiver, uint96 fee) external onlyOwner {
        _setDefaultRoyalty(receiver, fee);
    }

     function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}



    

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
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(ERC721AUpgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    /**
     * @dev Returns the base URI for the NFT metadata.
     * This function is used to retrieve the metadata URI for a given token ID.
     * It can be overridden in derived contracts to provide a custom base URI.
     *
     * @return The base URI as a string.
     */
    function _baseURI() internal view virtual override returns (string memory) {}   
}