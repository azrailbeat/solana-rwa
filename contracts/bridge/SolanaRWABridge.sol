// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../tokens/RWAToken.sol";
import "../core/RWARegistry.sol";

/**
 * @title SolanaRWABridge
 * @dev Bridge contract for cross-chain RWA operations between Solana and Ethereum
 * Supports both Wormhole and LayerZero protocols
 */
contract SolanaRWABridge is Ownable, ReentrancyGuard, Pausable {
    // Solana chain ID
    uint16 public constant SOLANA_CHAIN_ID = 1;
    
    // Bridge protocols
    address public wormholeCore;
    address public layerZeroEndpoint;
    
    // Registry and token contracts
    RWARegistry public rwaRegistry;
    mapping(uint64 => address) public assetTokens; // asset_id => token contract
    
    // Cross-chain transfer tracking
    mapping(bytes32 => bool) public processedTransfers;
    mapping(uint64 => SolanaAssetInfo) public solanaAssets;
    
    // Nonce for unique transfer IDs
    uint256 public transferNonce;
    
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
    
    struct CrossChainTransfer {
        uint64 assetId;
        uint256 amount;
        uint16 sourceChain;
        uint16 targetChain;
        address sender;
        bytes32 recipient; // For Solana addresses
        uint256 timestamp;
        bytes32 transferHash;
    }
    
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
    
    enum CrossChainEventType {
        AssetRegistered,
        TransferInitiated,
        TransferCompleted,
        MetadataUpdated
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
    
    event WormholeMessageReceived(
        uint16 sourceChain,
        bytes32 sourceAddress,
        bytes payload
    );
    
    event LayerZeroMessageReceived(
        uint16 sourceChain,
        bytes sourceAddress,
        bytes payload
    );
    
    constructor(
        address _rwaRegistry,
        address _wormholeCore,
        address _layerZeroEndpoint
    ) {
        rwaRegistry = RWARegistry(_rwaRegistry);
        wormholeCore = _wormholeCore;
        layerZeroEndpoint = _layerZeroEndpoint;
    }
    
    /**
     * @dev Process Solana asset registration event
     */
    function processSolanaAssetRegistration(
        uint64 assetId,
        address owner,
        AssetType assetType,
        string calldata metadataUri,
        KYCLevel kycLevel,
        uint256 totalValue,
        uint256 totalSupply,
        bytes calldata proof
    ) external onlyOwner whenNotPaused {
        require(!solanaAssets[assetId].isActive, "Asset already registered");
        
        // Verify cross-chain proof (simplified for demo)
        require(_verifyProof(proof), "Invalid proof");
        
        // Store Solana asset info
        solanaAssets[assetId] = SolanaAssetInfo({
            assetId: assetId,
            assetType: assetType,
            owner: owner,
            metadataUri: metadataUri,
            kycLevel: kycLevel,
            totalValue: totalValue,
            totalSupply: totalSupply,
            circulatingSupply: 0,
            isActive: true,
            createdAt: block.timestamp
        });
        
        // Deploy corresponding ERC20 token on Ethereum
        address tokenAddress = _deployWrappedToken(assetId, metadataUri, totalSupply);
        assetTokens[assetId] = tokenAddress;
        
        emit SolanaAssetRegistered(
            assetId,
            owner,
            assetType,
            metadataUri,
            kycLevel,
            totalValue,
            totalSupply
        );
    }
    
    /**
     * @dev Initiate transfer from Ethereum to Solana
     */
    function initiateTransferToSolana(
        uint64 assetId,
        uint256 amount,
        bytes32 solanaRecipient
    ) external nonReentrant whenNotPaused {
        require(solanaAssets[assetId].isActive, "Asset not found");
        require(amount > 0, "Amount must be greater than 0");
        
        address tokenContract = assetTokens[assetId];
        require(tokenContract != address(0), "Token contract not found");
        
        // Burn tokens on Ethereum
        IERC20(tokenContract).transferFrom(msg.sender, address(this), amount);
        RWAToken(tokenContract).burn(amount);
        
        // Generate transfer ID
        bytes32 transferId = keccak256(abi.encodePacked(
            block.timestamp,
            msg.sender,
            assetId,
            amount,
            transferNonce++
        ));
        
        // Emit cross-chain event
        emit CrossChainTransferInitiated(
            transferId,
            assetId,
            amount,
            block.chainid,
            SOLANA_CHAIN_ID,
            msg.sender,
            solanaRecipient
        );
        
        // Send message via Wormhole (simplified)
        if (wormholeCore != address(0)) {
            _sendWormholeMessage(transferId, assetId, amount, solanaRecipient);
        }
        
        // Send message via LayerZero (simplified)
        if (layerZeroEndpoint != address(0)) {
            _sendLayerZeroMessage(transferId, assetId, amount, solanaRecipient);
        }
    }
    
    /**
     * @dev Complete transfer from Solana to Ethereum
     */
    function completeTransferFromSolana(
        bytes32 transferId,
        uint64 assetId,
        uint256 amount,
        address recipient,
        bytes calldata proof
    ) external onlyOwner nonReentrant whenNotPaused {
        require(!processedTransfers[transferId], "Transfer already processed");
        require(solanaAssets[assetId].isActive, "Asset not found");
        require(_verifyProof(proof), "Invalid proof");
        
        processedTransfers[transferId] = true;
        
        address tokenContract = assetTokens[assetId];
        require(tokenContract != address(0), "Token contract not found");
        
        // Mint tokens on Ethereum
        RWAToken(tokenContract).mint(recipient, amount);
        
        // Update circulating supply
        solanaAssets[assetId].circulatingSupply += amount;
        
        emit CrossChainTransferCompleted(
            transferId,
            assetId,
            amount,
            SOLANA_CHAIN_ID,
            recipient
        );
    }
    
    /**
     * @dev Receive Wormhole message
     */
    function receiveWormholeMessage(
        bytes memory payload,
        uint16 sourceChain,
        bytes32 sourceAddress
    ) external {
        require(msg.sender == wormholeCore, "Only Wormhole core");
        
        // Decode and process message
        _processWormholeMessage(payload, sourceChain, sourceAddress);
        
        emit WormholeMessageReceived(sourceChain, sourceAddress, payload);
    }
    
    /**
     * @dev Receive LayerZero message
     */
    function lzReceive(
        uint16 sourceChain,
        bytes memory sourceAddress,
        uint64 nonce,
        bytes memory payload
    ) external {
        require(msg.sender == layerZeroEndpoint, "Only LayerZero endpoint");
        
        // Decode and process message
        _processLayerZeroMessage(payload, sourceChain, sourceAddress);
        
        emit LayerZeroMessageReceived(sourceChain, sourceAddress, payload);
    }
    
    /**
     * @dev Update Solana asset metadata
     */
    function updateSolanaAssetMetadata(
        uint64 assetId,
        string calldata newMetadataUri,
        bytes calldata proof
    ) external onlyOwner {
        require(solanaAssets[assetId].isActive, "Asset not found");
        require(_verifyProof(proof), "Invalid proof");
        
        solanaAssets[assetId].metadataUri = newMetadataUri;
        
        // Update corresponding token metadata if exists
        address tokenContract = assetTokens[assetId];
        if (tokenContract != address(0)) {
            RWAToken(tokenContract).updateMetadata(newMetadataUri);
        }
    }
    
    /**
     * @dev Get Solana asset information
     */
    function getSolanaAsset(uint64 assetId) external view returns (SolanaAssetInfo memory) {
        return solanaAssets[assetId];
    }
    
    /**
     * @dev Check if transfer is processed
     */
    function isTransferProcessed(bytes32 transferId) external view returns (bool) {
        return processedTransfers[transferId];
    }
    
    /**
     * @dev Set bridge protocol addresses
     */
    function setBridgeProtocols(
        address _wormholeCore,
        address _layerZeroEndpoint
    ) external onlyOwner {
        wormholeCore = _wormholeCore;
        layerZeroEndpoint = _layerZeroEndpoint;
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // Internal functions
    function _deployWrappedToken(
        uint64 assetId,
        string memory metadataUri,
        uint256 totalSupply
    ) internal returns (address) {
        // Deploy new RWA token contract
        string memory name = string(abi.encodePacked("Solana RWA Asset #", _uint64ToString(assetId)));
        string memory symbol = string(abi.encodePacked("sRWA", _uint64ToString(assetId)));
        
        RWAToken token = new RWAToken(
            name,
            symbol,
            metadataUri,
            totalSupply,
            address(this) // Bridge as minter
        );
        
        return address(token);
    }
    
    function _sendWormholeMessage(
        bytes32 transferId,
        uint64 assetId,
        uint256 amount,
        bytes32 recipient
    ) internal {
        // Encode transfer data
        bytes memory payload = abi.encode(
            transferId,
            assetId,
            amount,
            recipient,
            block.timestamp
        );
        
        // Send via Wormhole (simplified - actual implementation would use Wormhole SDK)
        // IWormhole(wormholeCore).publishMessage(nonce, payload, consistencyLevel);
    }
    
    function _sendLayerZeroMessage(
        bytes32 transferId,
        uint64 assetId,
        uint256 amount,
        bytes32 recipient
    ) internal {
        // Encode transfer data
        bytes memory payload = abi.encode(
            transferId,
            assetId,
            amount,
            recipient,
            block.timestamp
        );
        
        // Send via LayerZero (simplified - actual implementation would use LayerZero SDK)
        // ILayerZeroEndpoint(layerZeroEndpoint).send(SOLANA_CHAIN_ID, payload, payable(msg.sender), address(0), bytes(""));
    }
    
    function _processWormholeMessage(
        bytes memory payload,
        uint16 sourceChain,
        bytes32 sourceAddress
    ) internal {
        // Decode and process Wormhole message
        // Implementation depends on message format
    }
    
    function _processLayerZeroMessage(
        bytes memory payload,
        uint16 sourceChain,
        bytes memory sourceAddress
    ) internal {
        // Decode and process LayerZero message
        // Implementation depends on message format
    }
    
    function _verifyProof(bytes memory proof) internal pure returns (bool) {
        // Simplified proof verification
        // In production, this would verify Merkle proofs, signatures, etc.
        return proof.length > 0;
    }
    
    function _uint64ToString(uint64 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint64 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
