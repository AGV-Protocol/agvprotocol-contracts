// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts-upgradeable/contracts/token/ERC721/ERC721Upgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/common/ERC2981Upgradeable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title SeedPass
 * @dev This contract implements an ERC721 NFT with royalty support using ERC2981.
 * It allows for minting a limited number of NFTs, with a maximum supply and per-wallet limit.
 * The contract is upgradeable and owned by a single owner.
 */
contract SeedPass is
    Initializable,
    ERC721Upgradeable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC2981Upgradeable
{
    using SafeERC20 for IERC20;
    // --- State Variables ---
    uint256 public constant MAX_SUPPLY = 400;
    uint256 public constant MAX_PER_WALLET = 3;

    struct SaleConfig {
        uint256 wlPrice; // Price for whitelisted users
        uint256 publicPrice; // Price for public sale
        uint256 wlStartTime; // Start time for whitelisted sale
        uint256 wlEndTime; // End time for whitelisted sale
        uint256 maxSupply; // Maximum supply of NFTs
        uint256 maxPerWallet; // Maximum NFTs per wallet
    }

    SaleConfig public saleConfig;
    IERC20 public usdtToken;
    bytes32 public whitelistMerkleRoot;

    // --- Errors ---

    // ----- Events -----

    // --- Initialization ---

    function initialize(
        string memory name,
        string memory symbol,
        address owner,
        address usdtAddress,
        bytes32 initialMerkleRoot,
        SaleConfig memory config
    ) public initializer {
        __ERC721_init(name, symbol);
        __Ownable_init(owner);
        __UUPSUpgradeable_init();
        __ERC2981_init();

        usdtToken = IERC20(usdtAddress);
        whitelistMerkleRoot = initialMerkleRoot;
        saleConfig = config;
    }

    // --- Public Functions ---
     function mint(uint256 amount, bytes32[] calldata merkleProof) external {
        require(amount > 0, "Amount must be greater than zero");

        uint256 currentSupply = totalSupply();
        require(currentSupply + amount <= saleConfig.maxSupply, "Exceeds max supply");
        require(_numberMinted(msg.sender) + amount <= saleConfig.maxPerWallet, "Exceeds wallet limit");

        uint256 paymentAmount = 0;
        bool isWhitelisted = _verifyMerkleProof(merkleProof);

        if (block.timestamp >= saleConfig.wlStartTime && block.timestamp <= saleConfig.wlEndTime) {
            require(isWhitelisted, "Not whitelisted");
            paymentAmount = amount * saleConfig.wlPrice;
        } else {
            // Public sale
            require(block.timestamp > saleConfig.wlEndTime, "Public sale not started");
            paymentAmount = amount * saleConfig.publicPrice;
        }

        usdtToken.safeTransferFrom(msg.sender, owner(), paymentAmount);
        _safeMint(msg.sender, amount);
    }

    // --- Internal Helper Functions ---
    function _verifyMerkleProof(bytes32[] memory merkleProof) internal view returns (bool) {
        // Your Merkle proof verification logic here.
        // It would check against the whitelistMerkleRoot.
        return true; // Simplified for the sketch
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
        override(ERC721Upgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    // total Minted NFT by wallet
    // total Minted NFTs  
}
