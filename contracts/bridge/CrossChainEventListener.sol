// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./SolanaRWABridge.sol";

/**
 * @title CrossChainEventListener
 * @dev Listens for cross-chain events and processes them automatically
 * Supports both Wormhole and LayerZero message formats
 */
contract CrossChainEventListener is Ownable, ReentrancyGuard {
    SolanaRWABridge public immutable bridge;
    
    // Wormhole configuration
    address public wormholeCore;
    mapping(uint16 => bytes32) public trustedSources; // chainId => sourceAddress
    
    // LayerZero configuration
    address public layerZeroEndpoint;
    mapping(uint16 => bytes) public trustedRemotes; // chainId => remote address
    
    // Event processing
    mapping(bytes32 => bool) public processedEvents;
    uint256 public eventNonce;
    
    struct CrossChainMessage {
        uint8 messageType; // 1: AssetRegistration, 2: Transfer, 3: MetadataUpdate
        bytes payload;
        uint16 sourceChain;
        bytes32 sourceAddress;
        uint256 timestamp;
    }
    
    // Message types
    uint8 public constant MSG_ASSET_REGISTRATION = 1;
    uint8 public constant MSG_TRANSFER_INITIATION = 2;
    uint8 public constant MSG_TRANSFER_COMPLETION = 3;
    uint8 public constant MSG_METADATA_UPDATE = 4;
    
    // Events
    event CrossChainMessageReceived(
        bytes32 indexed messageId,
        uint8 messageType,
        uint16 sourceChain,
        bytes32 sourceAddress
    );
    
    event CrossChainMessageProcessed(
        bytes32 indexed messageId,
        bool success,
        string reason
    );
    
    event TrustedSourceAdded(uint16 chainId, bytes32 sourceAddress);
    event TrustedRemoteAdded(uint16 chainId, bytes remoteAddress);
    
    constructor(
        address _bridge,
        address _wormholeCore,
        address _layerZeroEndpoint
    ) {
        bridge = SolanaRWABridge(_bridge);
        wormholeCore = _wormholeCore;
        layerZeroEndpoint = _layerZeroEndpoint;
    }
    
    /**
     * @dev Receive and process Wormhole message
     */
    function receiveWormholeMessage(
        bytes memory payload,
        uint16 sourceChain,
        bytes32 sourceAddress
    ) external nonReentrant {
        require(msg.sender == wormholeCore, "Only Wormhole core");
        require(trustedSources[sourceChain] == sourceAddress, "Untrusted source");
        
        bytes32 messageId = _generateMessageId(payload, sourceChain, sourceAddress);
        require(!processedEvents[messageId], "Message already processed");
        
        processedEvents[messageId] = true;
        
        emit CrossChainMessageReceived(messageId, 0, sourceChain, sourceAddress);
        
        // Decode and process message
        bool success = _processWormholeMessage(payload, sourceChain, sourceAddress);
        
        emit CrossChainMessageProcessed(
            messageId,
            success,
            success ? "Success" : "Processing failed"
        );
    }
    
    /**
     * @dev Receive and process LayerZero message
     */
    function lzReceive(
        uint16 sourceChain,
        bytes memory sourceAddress,
        uint64 nonce,
        bytes memory payload
    ) external nonReentrant {
        require(msg.sender == layerZeroEndpoint, "Only LayerZero endpoint");
        require(
            keccak256(trustedRemotes[sourceChain]) == keccak256(sourceAddress),
            "Untrusted remote"
        );
        
        bytes32 messageId = _generateMessageId(payload, sourceChain, bytes32(0));
        require(!processedEvents[messageId], "Message already processed");
        
        processedEvents[messageId] = true;
        
        emit CrossChainMessageReceived(messageId, 0, sourceChain, bytes32(0));
        
        // Decode and process message
        bool success = _processLayerZeroMessage(payload, sourceChain, sourceAddress);
        
        emit CrossChainMessageProcessed(
            messageId,
            success,
            success ? "Success" : "Processing failed"
        );
    }
    
    /**
     * @dev Manually process cross-chain event with proof
     */
    function processManualEvent(
        uint8 messageType,
        bytes calldata payload,
        bytes calldata proof
    ) external onlyOwner {
        bytes32 messageId = keccak256(abi.encodePacked(messageType, payload, block.timestamp, eventNonce++));
        require(!processedEvents[messageId], "Event already processed");
        
        processedEvents[messageId] = true;
        
        bool success = false;
        string memory reason = "";
        
        try this._processEventByType(messageType, payload, proof) {
            success = true;
            reason = "Success";
        } catch Error(string memory err) {
            reason = err;
        } catch {
            reason = "Unknown error";
        }
        
        emit CrossChainMessageProcessed(messageId, success, reason);
    }
    
    /**
     * @dev Process event by type (external for try-catch)
     */
    function _processEventByType(
        uint8 messageType,
        bytes calldata payload,
        bytes calldata proof
    ) external {
        require(msg.sender == address(this), "Internal only");
        
        if (messageType == MSG_ASSET_REGISTRATION) {
            _processAssetRegistration(payload, proof);
        } else if (messageType == MSG_TRANSFER_COMPLETION) {
            _processTransferCompletion(payload, proof);
        } else if (messageType == MSG_METADATA_UPDATE) {
            _processMetadataUpdate(payload, proof);
        } else {
            revert("Unknown message type");
        }
    }
    
    /**
     * @dev Add trusted Wormhole source
     */
    function addTrustedSource(uint16 chainId, bytes32 sourceAddress) external onlyOwner {
        trustedSources[chainId] = sourceAddress;
        emit TrustedSourceAdded(chainId, sourceAddress);
    }
    
    /**
     * @dev Add trusted LayerZero remote
     */
    function addTrustedRemote(uint16 chainId, bytes calldata remoteAddress) external onlyOwner {
        trustedRemotes[chainId] = remoteAddress;
        emit TrustedRemoteAdded(chainId, remoteAddress);
    }
    
    /**
     * @dev Remove trusted source
     */
    function removeTrustedSource(uint16 chainId) external onlyOwner {
        delete trustedSources[chainId];
    }
    
    /**
     * @dev Remove trusted remote
     */
    function removeTrustedRemote(uint16 chainId) external onlyOwner {
        delete trustedRemotes[chainId];
    }
    
    // Internal functions
    function _processWormholeMessage(
        bytes memory payload,
        uint16 sourceChain,
        bytes32 sourceAddress
    ) internal returns (bool) {
        try this._decodeAndProcessWormholeMessage(payload, sourceChain) {
            return true;
        } catch {
            return false;
        }
    }
    
    function _processLayerZeroMessage(
        bytes memory payload,
        uint16 sourceChain,
        bytes memory sourceAddress
    ) internal returns (bool) {
        try this._decodeAndProcessLayerZeroMessage(payload, sourceChain) {
            return true;
        } catch {
            return false;
        }
    }
    
    function _decodeAndProcessWormholeMessage(
        bytes memory payload,
        uint16 sourceChain
    ) external {
        require(msg.sender == address(this), "Internal only");
        
        // Decode Wormhole message format
        (uint8 messageType, bytes memory data) = abi.decode(payload, (uint8, bytes));
        
        if (messageType == MSG_ASSET_REGISTRATION) {
            _processAssetRegistrationFromWormhole(data);
        } else if (messageType == MSG_TRANSFER_COMPLETION) {
            _processTransferCompletionFromWormhole(data);
        }
    }
    
    function _decodeAndProcessLayerZeroMessage(
        bytes memory payload,
        uint16 sourceChain
    ) external {
        require(msg.sender == address(this), "Internal only");
        
        // Decode LayerZero message format
        (uint8 messageType, bytes memory data) = abi.decode(payload, (uint8, bytes));
        
        if (messageType == MSG_ASSET_REGISTRATION) {
            _processAssetRegistrationFromLayerZero(data);
        } else if (messageType == MSG_TRANSFER_COMPLETION) {
            _processTransferCompletionFromLayerZero(data);
        }
    }
    
    function _processAssetRegistration(bytes memory payload, bytes memory proof) internal {
        (
            uint64 assetId,
            address owner,
            SolanaRWABridge.AssetType assetType,
            string memory metadataUri,
            SolanaRWABridge.KYCLevel kycLevel,
            uint256 totalValue,
            uint256 totalSupply
        ) = abi.decode(payload, (uint64, address, SolanaRWABridge.AssetType, string, SolanaRWABridge.KYCLevel, uint256, uint256));
        
        bridge.processSolanaAssetRegistration(
            assetId,
            owner,
            assetType,
            metadataUri,
            kycLevel,
            totalValue,
            totalSupply,
            proof
        );
    }
    
    function _processTransferCompletion(bytes memory payload, bytes memory proof) internal {
        (
            bytes32 transferId,
            uint64 assetId,
            uint256 amount,
            address recipient
        ) = abi.decode(payload, (bytes32, uint64, uint256, address));
        
        bridge.completeTransferFromSolana(
            transferId,
            assetId,
            amount,
            recipient,
            proof
        );
    }
    
    function _processMetadataUpdate(bytes memory payload, bytes memory proof) internal {
        (
            uint64 assetId,
            string memory newMetadataUri
        ) = abi.decode(payload, (uint64, string));
        
        bridge.updateSolanaAssetMetadata(assetId, newMetadataUri, proof);
    }
    
    function _processAssetRegistrationFromWormhole(bytes memory data) internal {
        // Process Wormhole-specific asset registration
        _processAssetRegistration(data, ""); // Empty proof for automated processing
    }
    
    function _processTransferCompletionFromWormhole(bytes memory data) internal {
        // Process Wormhole-specific transfer completion
        _processTransferCompletion(data, ""); // Empty proof for automated processing
    }
    
    function _processAssetRegistrationFromLayerZero(bytes memory data) internal {
        // Process LayerZero-specific asset registration
        _processAssetRegistration(data, ""); // Empty proof for automated processing
    }
    
    function _processTransferCompletionFromLayerZero(bytes memory data) internal {
        // Process LayerZero-specific transfer completion
        _processTransferCompletion(data, ""); // Empty proof for automated processing
    }
    
    function _generateMessageId(
        bytes memory payload,
        uint16 sourceChain,
        bytes32 sourceAddress
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            payload,
            sourceChain,
            sourceAddress,
            block.timestamp,
            eventNonce
        ));
    }
}
