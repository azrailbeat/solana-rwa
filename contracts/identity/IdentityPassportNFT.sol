// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title IdentityPassportNFT
 * @dev Cross-chain compatible identity passport NFT with DID integration
 * Implements ERC-721, ERC-725 (identity), and EIP-4361 (Sign-In with Ethereum) standards
 */
contract IdentityPassportNFT is 
    ERC721, 
    ERC721URIStorage, 
    ERC721Enumerable, 
    Ownable, 
    Pausable, 
    ReentrancyGuard,
    EIP712
{
    using Counters for Counters.Counter;
    using ECDSA for bytes32;

    Counters.Counter private _tokenIdCounter;

    // ERC-725 Identity Key Types
    bytes32 public constant DID_KEY = keccak256("DID");
    bytes32 public constant KYC_LEVEL_KEY = keccak256("KYC_LEVEL");
    bytes32 public constant INVESTOR_TIER_KEY = keccak256("INVESTOR_TIER");
    bytes32 public constant REPUTATION_KEY = keccak256("REPUTATION");
    bytes32 public constant CROSS_CHAIN_ADDRESSES_KEY = keccak256("CROSS_CHAIN_ADDRESSES");
    bytes32 public constant CREDENTIALS_KEY = keccak256("CREDENTIALS");

    // KYC Levels
    enum KYCLevel { None, Basic, Enhanced, Institutional }
    
    // Investor Tiers
    enum InvestorTier { None, Retail, Accredited, Institutional, Qualified }

    // Cross-chain address structure
    struct CrossChainAddress {
        string chain;
        string address;
        bool verified;
        uint256 timestamp;
    }

    // Identity Passport structure
    struct IdentityPassport {
        string did;
        KYCLevel kycLevel;
        InvestorTier investorTier;
        uint256 reputationScore;
        uint256 issuanceDate;
        uint256 expirationDate;
        bool isActive;
        string metadataURI;
        address issuer;
        CrossChainAddress[] crossChainAddresses;
        string[] credentials;
    }

    // Mappings
    mapping(uint256 => IdentityPassport) public passports;
    mapping(address => uint256) public addressToTokenId;
    mapping(string => uint256) public didToTokenId;
    mapping(uint256 => mapping(bytes32 => bytes)) public identityData; // ERC-725 data
    mapping(address => bool) public authorizedIssuers;
    mapping(string => bool) public supportedChains;

    // Cross-chain bridge mappings
    mapping(uint256 => mapping(string => string)) public crossChainTokenIds; // tokenId => chain => remoteTokenId
    mapping(bytes32 => bool) public processedCrossChainMessages;

    // Events
    event PassportIssued(
        uint256 indexed tokenId,
        address indexed holder,
        string did,
        KYCLevel kycLevel,
        InvestorTier investorTier
    );
    
    event PassportUpdated(
        uint256 indexed tokenId,
        KYCLevel kycLevel,
        InvestorTier investorTier,
        uint256 reputationScore
    );
    
    event CrossChainAddressLinked(
        uint256 indexed tokenId,
        string chain,
        string chainAddress
    );
    
    event CrossChainSync(
        uint256 indexed tokenId,
        string targetChain,
        string remoteTokenId,
        bytes32 messageHash
    );
    
    event CredentialAdded(
        uint256 indexed tokenId,
        string credentialId,
        string credentialType
    );

    // ERC-725 Events
    event DataChanged(bytes32 indexed dataKey, bytes dataValue);
    event DataSet(bytes32 indexed dataKey, bytes dataValue);

    constructor(
        string memory name,
        string memory symbol,
        address initialOwner
    ) 
        ERC721(name, symbol) 
        EIP712("IdentityPassportNFT", "1.0.0")
    {
        _transferOwnership(initialOwner);
        
        // Initialize supported chains
        supportedChains["ethereum"] = true;
        supportedChains["polygon"] = true;
        supportedChains["bsc"] = true;
        supportedChains["solana"] = true;
        supportedChains["arbitrum"] = true;
        supportedChains["optimism"] = true;
    }

    /**
     * @dev Issue a new identity passport NFT
     */
    function issuePassport(
        address to,
        string memory did,
        KYCLevel kycLevel,
        InvestorTier investorTier,
        string memory metadataURI,
        uint256 validityPeriod
    ) external onlyAuthorizedIssuer nonReentrant returns (uint256) {
        require(to != address(0), "Invalid recipient");
        require(bytes(did).length > 0, "DID required");
        require(addressToTokenId[to] == 0, "Address already has passport");
        require(didToTokenId[did] == 0, "DID already registered");

        _tokenIdCounter.increment();
        uint256 tokenId = _tokenIdCounter.current();

        // Create passport
        IdentityPassport storage passport = passports[tokenId];
        passport.did = did;
        passport.kycLevel = kycLevel;
        passport.investorTier = investorTier;
        passport.reputationScore = 100; // Starting reputation
        passport.issuanceDate = block.timestamp;
        passport.expirationDate = block.timestamp + validityPeriod;
        passport.isActive = true;
        passport.metadataURI = metadataURI;
        passport.issuer = msg.sender;

        // Mint NFT
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, metadataURI);

        // Update mappings
        addressToTokenId[to] = tokenId;
        didToTokenId[did] = tokenId;

        // Set ERC-725 identity data
        _setData(tokenId, DID_KEY, abi.encode(did));
        _setData(tokenId, KYC_LEVEL_KEY, abi.encode(kycLevel));
        _setData(tokenId, INVESTOR_TIER_KEY, abi.encode(investorTier));
        _setData(tokenId, REPUTATION_KEY, abi.encode(uint256(100)));

        emit PassportIssued(tokenId, to, did, kycLevel, investorTier);
        return tokenId;
    }

    /**
     * @dev Update passport information
     */
    function updatePassport(
        uint256 tokenId,
        KYCLevel newKycLevel,
        InvestorTier newInvestorTier,
        uint256 newReputationScore,
        string memory newMetadataURI
    ) external onlyAuthorizedIssuer {
        require(_exists(tokenId), "Passport does not exist");
        
        IdentityPassport storage passport = passports[tokenId];
        passport.kycLevel = newKycLevel;
        passport.investorTier = newInvestorTier;
        passport.reputationScore = newReputationScore;
        
        if (bytes(newMetadataURI).length > 0) {
            passport.metadataURI = newMetadataURI;
            _setTokenURI(tokenId, newMetadataURI);
        }

        // Update ERC-725 data
        _setData(tokenId, KYC_LEVEL_KEY, abi.encode(newKycLevel));
        _setData(tokenId, INVESTOR_TIER_KEY, abi.encode(newInvestorTier));
        _setData(tokenId, REPUTATION_KEY, abi.encode(newReputationScore));

        emit PassportUpdated(tokenId, newKycLevel, newInvestorTier, newReputationScore);
    }

    /**
     * @dev Link cross-chain address to passport
     */
    function linkCrossChainAddress(
        uint256 tokenId,
        string memory chain,
        string memory chainAddress,
        bytes memory signature
    ) external {
        require(_exists(tokenId), "Passport does not exist");
        require(ownerOf(tokenId) == msg.sender, "Not passport owner");
        require(supportedChains[chain], "Unsupported chain");
        require(bytes(chainAddress).length > 0, "Invalid address");

        // Verify signature for cross-chain address ownership
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, chain, chainAddress, block.timestamp));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedMessageHash.recover(signature);
        require(signer == msg.sender, "Invalid signature");

        // Add cross-chain address
        CrossChainAddress memory newAddress = CrossChainAddress({
            chain: chain,
            address: chainAddress,
            verified: true,
            timestamp: block.timestamp
        });

        passports[tokenId].crossChainAddresses.push(newAddress);

        // Update ERC-725 data
        _setData(tokenId, CROSS_CHAIN_ADDRESSES_KEY, abi.encode(passports[tokenId].crossChainAddresses));

        emit CrossChainAddressLinked(tokenId, chain, chainAddress);
    }

    /**
     * @dev Add verifiable credential to passport
     */
    function addCredential(
        uint256 tokenId,
        string memory credentialId,
        string memory credentialType,
        bytes memory credentialProof
    ) external onlyAuthorizedIssuer {
        require(_exists(tokenId), "Passport does not exist");
        
        // Verify credential proof (simplified for demo)
        // In production, this would verify the credential signature
        
        passports[tokenId].credentials.push(credentialId);
        
        // Update ERC-725 data
        _setData(tokenId, CREDENTIALS_KEY, abi.encode(passports[tokenId].credentials));
        
        emit CredentialAdded(tokenId, credentialId, credentialType);
    }

    /**
     * @dev Sync passport to another chain
     */
    function syncToChain(
        uint256 tokenId,
        string memory targetChain,
        string memory targetContract
    ) external payable onlyOwner {
        require(_exists(tokenId), "Passport does not exist");
        require(supportedChains[targetChain], "Unsupported target chain");
        
        IdentityPassport memory passport = passports[tokenId];
        
        // Create cross-chain message
        bytes memory message = abi.encode(
            tokenId,
            passport.did,
            passport.kycLevel,
            passport.investorTier,
            passport.reputationScore,
            passport.metadataURI,
            passport.crossChainAddresses,
            passport.credentials
        );
        
        bytes32 messageHash = keccak256(message);
        
        // Store cross-chain token mapping
        crossChainTokenIds[tokenId][targetChain] = string(abi.encodePacked("pending-", tokenId));
        
        emit CrossChainSync(tokenId, targetChain, crossChainTokenIds[tokenId][targetChain], messageHash);
    }

    /**
     * @dev Process cross-chain message (called by bridge)
     */
    function processCrossChainMessage(
        bytes32 messageHash,
        bytes memory message,
        bytes memory proof
    ) external onlyOwner {
        require(!processedCrossChainMessages[messageHash], "Message already processed");
        
        // Verify proof (simplified for demo)
        // In production, this would verify Wormhole/LayerZero proof
        
        (
            uint256 sourceTokenId,
            string memory did,
            KYCLevel kycLevel,
            InvestorTier investorTier,
            uint256 reputationScore,
            string memory metadataURI,
            CrossChainAddress[] memory crossChainAddresses,
            string[] memory credentials
        ) = abi.decode(message, (uint256, string, KYCLevel, InvestorTier, uint256, string, CrossChainAddress[], string[]));
        
        // Check if passport already exists for this DID
        uint256 existingTokenId = didToTokenId[did];
        if (existingTokenId == 0) {
            // Create new passport
            _tokenIdCounter.increment();
            uint256 newTokenId = _tokenIdCounter.current();
            
            // Create passport from cross-chain data
            IdentityPassport storage passport = passports[newTokenId];
            passport.did = did;
            passport.kycLevel = kycLevel;
            passport.investorTier = investorTier;
            passport.reputationScore = reputationScore;
            passport.issuanceDate = block.timestamp;
            passport.expirationDate = block.timestamp + 365 days;
            passport.isActive = true;
            passport.metadataURI = metadataURI;
            passport.issuer = address(this);
            
            // Copy cross-chain addresses and credentials
            for (uint i = 0; i < crossChainAddresses.length; i++) {
                passport.crossChainAddresses.push(crossChainAddresses[i]);
            }
            for (uint i = 0; i < credentials.length; i++) {
                passport.credentials.push(credentials[i]);
            }
            
            didToTokenId[did] = newTokenId;
        } else {
            // Update existing passport
            updatePassport(existingTokenId, kycLevel, investorTier, reputationScore, metadataURI);
        }
        
        processedCrossChainMessages[messageHash] = true;
    }

    /**
     * @dev ERC-725 getData implementation
     */
    function getData(uint256 tokenId, bytes32 dataKey) external view returns (bytes memory) {
        require(_exists(tokenId), "Passport does not exist");
        return identityData[tokenId][dataKey];
    }

    /**
     * @dev ERC-725 setData implementation (internal)
     */
    function _setData(uint256 tokenId, bytes32 dataKey, bytes memory dataValue) internal {
        identityData[tokenId][dataKey] = dataValue;
        emit DataSet(dataKey, dataValue);
        emit DataChanged(dataKey, dataValue);
    }

    /**
     * @dev Get passport information
     */
    function getPassport(uint256 tokenId) external view returns (IdentityPassport memory) {
        require(_exists(tokenId), "Passport does not exist");
        return passports[tokenId];
    }

    /**
     * @dev Get passport by address
     */
    function getPassportByAddress(address holder) external view returns (IdentityPassport memory) {
        uint256 tokenId = addressToTokenId[holder];
        require(tokenId != 0, "No passport found");
        return passports[tokenId];
    }

    /**
     * @dev Get passport by DID
     */
    function getPassportByDID(string memory did) external view returns (IdentityPassport memory) {
        uint256 tokenId = didToTokenId[did];
        require(tokenId != 0, "No passport found");
        return passports[tokenId];
    }

    /**
     * @dev Check if address has valid passport
     */
    function hasValidPassport(address holder) external view returns (bool) {
        uint256 tokenId = addressToTokenId[holder];
        if (tokenId == 0) return false;
        
        IdentityPassport memory passport = passports[tokenId];
        return passport.isActive && passport.expirationDate > block.timestamp;
    }

    /**
     * @dev Get cross-chain addresses for passport
     */
    function getCrossChainAddresses(uint256 tokenId) external view returns (CrossChainAddress[] memory) {
        require(_exists(tokenId), "Passport does not exist");
        return passports[tokenId].crossChainAddresses;
    }

    /**
     * @dev Get credentials for passport
     */
    function getCredentials(uint256 tokenId) external view returns (string[] memory) {
        require(_exists(tokenId), "Passport does not exist");
        return passports[tokenId].credentials;
    }

    // Admin functions
    function addAuthorizedIssuer(address issuer) external onlyOwner {
        authorizedIssuers[issuer] = true;
    }

    function removeAuthorizedIssuer(address issuer) external onlyOwner {
        authorizedIssuers[issuer] = false;
    }

    function addSupportedChain(string memory chain) external onlyOwner {
        supportedChains[chain] = true;
    }

    function removeSupportedChain(string memory chain) external onlyOwner {
        supportedChains[chain] = false;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Modifiers
    modifier onlyAuthorizedIssuer() {
        require(authorizedIssuers[msg.sender] || msg.sender == owner(), "Not authorized issuer");
        _;
    }

    // Override functions
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) whenNotPaused {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
        
        // Update address mapping on transfer
        if (from != address(0)) {
            addressToTokenId[from] = 0;
        }
        if (to != address(0)) {
            addressToTokenId[to] = tokenId;
        }
    }

    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
        
        // Clean up mappings
        address owner = ownerOf(tokenId);
        string memory did = passports[tokenId].did;
        
        addressToTokenId[owner] = 0;
        didToTokenId[did] = 0;
        delete passports[tokenId];
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Enumerable, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
