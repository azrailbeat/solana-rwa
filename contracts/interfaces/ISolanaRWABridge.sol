// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISolanaRWABridge
 * @dev Interface for Solana RWA Bridge operations
 */
interface ISolanaRWABridge {
    enum AssetType {
        RealEstate,
        CarbonCredits,
        PreciousMetals,
        Commodities,
        Artwork,
        Collectibles,
        Other
    }
    
    enum KYCLevel {
        None,
        Basic,
        Enhanced,
        Institutional
    }
    
    struct SolanaAssetInfo {
        uint64 assetId;
        AssetType assetType;
        address owner;
        string metadataUri;
        KYCLevel kycLevel;
        uint256 totalValue;
        uint256 totalSupply;
        uint256 circulatingSupply;
        bool isActive;
        uint256 createdAt;
    }
    
    // Events
    event SolanaAssetRegistered(
        uint64 indexed assetId,
        address indexed owner,
        AssetType assetType,
        string metadataUri,
        KYCLevel kycLevel,
        uint256 totalValue,
        uint256 totalSupply
    );
    
    event CrossChainTransferInitiated(
        bytes32 indexed transferId,
        uint64 indexed assetId,
        uint256 amount,
        uint16 sourceChain,
        uint16 targetChain,
        address sender,
        bytes32 recipient
    );
    
    event CrossChainTransferCompleted(
        bytes32 indexed transferId,
        uint64 indexed assetId,
        uint256 amount,
        uint16 sourceChain,
        address recipient
    );
    
    // Functions
    function processSolanaAssetRegistration(
        uint64 assetId,
        address owner,
        AssetType assetType,
        string calldata metadataUri,
        KYCLevel kycLevel,
        uint256 totalValue,
        uint256 totalSupply,
        bytes calldata proof
    ) external;
    
    function initiateTransferToSolana(
        uint64 assetId,
        uint256 amount,
        bytes32 solanaRecipient
    ) external;
    
    function completeTransferFromSolana(
        bytes32 transferId,
        uint64 assetId,
        uint256 amount,
        address recipient,
        bytes calldata proof
    ) external;
    
    function getSolanaAsset(uint64 assetId) external view returns (SolanaAssetInfo memory);
    
    function isTransferProcessed(bytes32 transferId) external view returns (bool);
}
