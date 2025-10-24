// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/**
 * @title DocumentVerification
 * @dev Smart contract for decentralized document verification and authenticity proofs
 * @author OmniFlow Team
 */
contract DocumentVerification is 
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // Document structure
    struct Document {
        bytes32 documentHash;
        string ipfsHash;
        string arweaveId;
        address owner;
        address issuer;
        uint256 timestamp;
        DocumentType docType;
        DocumentStatus status;
        bool isNotarized;
        bytes32 zkProofHash;
        uint256 expiryDate;
        string jurisdiction;
    }

    // Notarization record
    struct NotarizationRecord {
        address notary;
        string notaryLicense;
        uint256 timestamp;
        bytes signature;
        bytes32 sealHash;
        uint8 witnessCount;
        bool isValid;
    }

    // ZK Proof structure
    struct ZKProof {
        bytes32 proofHash;
        bytes32[] publicInputs;
        bytes32 verificationKey;
        string circuit;
        uint256 timestamp;
        bool verified;
    }

    // Verification result
    struct VerificationResult {
        bytes32 documentId;
        bool isAuthentic;
        uint256 confidence; // Confidence score (0-10000 basis points)
        uint256 timestamp;
        address verifiedBy;
        string[] verificationMethods;
    }

    // Enums
    enum DocumentType {
        PROPERTY_DEED,
        TITLE_CERTIFICATE,
        APPRAISAL_REPORT,
        INSURANCE_POLICY,
        TAX_DOCUMENT,
        LEGAL_CONTRACT,
        IDENTITY_DOCUMENT,
        FINANCIAL_STATEMENT,
        COMPLIANCE_CERTIFICATE,
        AUDIT_REPORT,
        OTHER
    }

    enum DocumentStatus {
        PENDING,
        VERIFIED,
        REJECTED,
        EXPIRED,
        REVOKED
    }

    // State variables
    mapping(bytes32 => Document) public documents;
    mapping(bytes32 => NotarizationRecord) public notarizations;
    mapping(bytes32 => ZKProof) public zkProofs;
    mapping(bytes32 => VerificationResult) public verificationResults;
    mapping(address => bool) public authorizedNotaries;
    mapping(address => bool) public trustedIssuers;
    mapping(string => bool) public supportedJurisdictions;

    // Counters
    uint256 public totalDocuments;
    uint256 public totalVerifications;
    uint256 public totalNotarizations;

    // Events
    event DocumentRegistered(
        bytes32 indexed documentId,
        address indexed owner,
        address indexed issuer,
        DocumentType docType,
        string ipfsHash
    );

    event DocumentVerified(
        bytes32 indexed documentId,
        bool isAuthentic,
        uint256 confidence,
        address verifiedBy
    );

    event DocumentNotarized(
        bytes32 indexed documentId,
        address indexed notary,
        uint256 timestamp
    );

    event ZKProofSubmitted(
        bytes32 indexed documentId,
        bytes32 proofHash,
        string circuit
    );

    event NotaryAuthorized(address indexed notary, string license);
    event NotaryRevoked(address indexed notary);
    event IssuerTrusted(address indexed issuer);
    event IssuerUntrusted(address indexed issuer);

    // Modifiers
    modifier onlyAuthorizedNotary() {
        require(authorizedNotaries[msg.sender], "Not authorized notary");
        _;
    }

    modifier onlyTrustedIssuer() {
        require(trustedIssuers[msg.sender], "Not trusted issuer");
        _;
    }

    modifier documentExists(bytes32 documentId) {
        require(documents[documentId].timestamp != 0, "Document does not exist");
        _;
    }

    modifier onlyDocumentOwner(bytes32 documentId) {
        require(documents[documentId].owner == msg.sender, "Not document owner");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract
     */
    function initialize() public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Initialize supported jurisdictions
        supportedJurisdictions["US"] = true;
        supportedJurisdictions["EU"] = true;
        supportedJurisdictions["UK"] = true;
        supportedJurisdictions["GLOBAL"] = true;
    }

    /**
     * @dev Register a new document
     */
    function registerDocument(
        bytes32 documentHash,
        string memory ipfsHash,
        string memory arweaveId,
        DocumentType docType,
        uint256 expiryDate,
        string memory jurisdiction
    ) external whenNotPaused returns (bytes32) {
        require(documentHash != bytes32(0), "Invalid document hash");
        require(bytes(ipfsHash).length > 0 || bytes(arweaveId).length > 0, "No storage location provided");
        require(supportedJurisdictions[jurisdiction], "Unsupported jurisdiction");

        bytes32 documentId = keccak256(abi.encodePacked(documentHash, msg.sender, block.timestamp));
        require(documents[documentId].timestamp == 0, "Document already exists");

        documents[documentId] = Document({
            documentHash: documentHash,
            ipfsHash: ipfsHash,
            arweaveId: arweaveId,
            owner: msg.sender,
            issuer: msg.sender,
            timestamp: block.timestamp,
            docType: docType,
            status: DocumentStatus.PENDING,
            isNotarized: false,
            zkProofHash: bytes32(0),
            expiryDate: expiryDate,
            jurisdiction: jurisdiction
        });

        totalDocuments++;

        emit DocumentRegistered(documentId, msg.sender, msg.sender, docType, ipfsHash);
        return documentId;
    }

    /**
     * @dev Submit ZK proof for document authenticity
     */
    function submitZKProof(
        bytes32 documentId,
        bytes32 proofHash,
        bytes32[] memory publicInputs,
        bytes32 verificationKey,
        string memory circuit
    ) external documentExists(documentId) onlyDocumentOwner(documentId) whenNotPaused {
        require(proofHash != bytes32(0), "Invalid proof hash");
        require(publicInputs.length > 0, "No public inputs provided");

        zkProofs[documentId] = ZKProof({
            proofHash: proofHash,
            publicInputs: publicInputs,
            verificationKey: verificationKey,
            circuit: circuit,
            timestamp: block.timestamp,
            verified: false
        });

        documents[documentId].zkProofHash = proofHash;

        emit ZKProofSubmitted(documentId, proofHash, circuit);
    }

    /**
     * @dev Verify ZK proof (called by verification service)
     */
    function verifyZKProof(bytes32 documentId, bool isValid) 
        external 
        documentExists(documentId) 
        onlyOwner 
        whenNotPaused 
    {
        require(zkProofs[documentId].timestamp != 0, "No ZK proof submitted");
        zkProofs[documentId].verified = isValid;
    }

    /**
     * @dev Notarize a document
     */
    function notarizeDocument(
        bytes32 documentId,
        string memory notaryLicense,
        bytes memory signature,
        bytes32 sealHash,
        uint8 witnessCount
    ) external documentExists(documentId) onlyAuthorizedNotary whenNotPaused {
        require(bytes(notaryLicense).length > 0, "Invalid notary license");
        require(signature.length > 0, "Invalid signature");
        require(sealHash != bytes32(0), "Invalid seal hash");

        notarizations[documentId] = NotarizationRecord({
            notary: msg.sender,
            notaryLicense: notaryLicense,
            timestamp: block.timestamp,
            signature: signature,
            sealHash: sealHash,
            witnessCount: witnessCount,
            isValid: true
        });

        documents[documentId].isNotarized = true;
        totalNotarizations++;

        emit DocumentNotarized(documentId, msg.sender, block.timestamp);
    }

    /**
     * @dev Verify document authenticity
     */
    function verifyDocument(bytes32 documentId) 
        external 
        documentExists(documentId) 
        whenNotPaused 
        returns (bool isAuthentic, uint256 confidence) 
    {
        Document storage doc = documents[documentId];
        
        // Check if document is expired
        if (doc.expiryDate != 0 && block.timestamp > doc.expiryDate) {
            doc.status = DocumentStatus.EXPIRED;
            return (false, 0);
        }

        confidence = 5000; // Base confidence 50%

        // Check hash integrity
        if (doc.documentHash != bytes32(0)) {
            confidence += 1000; // +10%
        }

        // Check notarization
        if (doc.isNotarized && notarizations[documentId].isValid) {
            confidence += 2000; // +20%
        }

        // Check ZK proof
        if (doc.zkProofHash != bytes32(0) && zkProofs[documentId].verified) {
            confidence += 1500; // +15%
        }

        // Check trusted issuer
        if (trustedIssuers[doc.issuer]) {
            confidence += 500; // +5%
        }

        // Cap confidence at 100%
        if (confidence > 10000) {
            confidence = 10000;
        }

        isAuthentic = confidence >= 7000; // 70% threshold for authenticity

        // Update document status
        doc.status = isAuthentic ? DocumentStatus.VERIFIED : DocumentStatus.REJECTED;

        // Store verification result
        string[] memory methods = new string[](4);
        methods[0] = "hash_verification";
        methods[1] = "notary_verification";
        methods[2] = "zk_proof";
        methods[3] = "issuer_verification";

        verificationResults[documentId] = VerificationResult({
            documentId: documentId,
            isAuthentic: isAuthentic,
            confidence: confidence,
            timestamp: block.timestamp,
            verifiedBy: msg.sender,
            verificationMethods: methods
        });

        totalVerifications++;

        emit DocumentVerified(documentId, isAuthentic, confidence, msg.sender);
        return (isAuthentic, confidence);
    }

    /**
     * @dev Authorize a notary
     */
    function authorizeNotary(address notary, string memory license) external onlyOwner {
        require(notary != address(0), "Invalid notary address");
        require(bytes(license).length > 0, "Invalid license");
        
        authorizedNotaries[notary] = true;
        emit NotaryAuthorized(notary, license);
    }

    /**
     * @dev Revoke notary authorization
     */
    function revokeNotary(address notary) external onlyOwner {
        authorizedNotaries[notary] = false;
        emit NotaryRevoked(notary);
    }

    /**
     * @dev Add trusted issuer
     */
    function addTrustedIssuer(address issuer) external onlyOwner {
        require(issuer != address(0), "Invalid issuer address");
        trustedIssuers[issuer] = true;
        emit IssuerTrusted(issuer);
    }

    /**
     * @dev Remove trusted issuer
     */
    function removeTrustedIssuer(address issuer) external onlyOwner {
        trustedIssuers[issuer] = false;
        emit IssuerUntrusted(issuer);
    }

    /**
     * @dev Add supported jurisdiction
     */
    function addJurisdiction(string memory jurisdiction) external onlyOwner {
        supportedJurisdictions[jurisdiction] = true;
    }

    /**
     * @dev Remove supported jurisdiction
     */
    function removeJurisdiction(string memory jurisdiction) external onlyOwner {
        supportedJurisdictions[jurisdiction] = false;
    }

    /**
     * @dev Revoke document (emergency function)
     */
    function revokeDocument(bytes32 documentId, string memory reason) 
        external 
        documentExists(documentId) 
        onlyOwner 
    {
        documents[documentId].status = DocumentStatus.REVOKED;
        // Note: In a real implementation, you might want to emit an event with the reason
    }

    /**
     * @dev Get document details
     */
    function getDocument(bytes32 documentId) 
        external 
        view 
        returns (Document memory) 
    {
        return documents[documentId];
    }

    /**
     * @dev Get notarization record
     */
    function getNotarization(bytes32 documentId) 
        external 
        view 
        returns (NotarizationRecord memory) 
    {
        return notarizations[documentId];
    }

    /**
     * @dev Get ZK proof
     */
    function getZKProof(bytes32 documentId) 
        external 
        view 
        returns (ZKProof memory) 
    {
        return zkProofs[documentId];
    }

    /**
     * @dev Get verification result
     */
    function getVerificationResult(bytes32 documentId) 
        external 
        view 
        returns (VerificationResult memory) 
    {
        return verificationResults[documentId];
    }

    /**
     * @dev Check if document is authentic
     */
    function isDocumentAuthentic(bytes32 documentId) 
        external 
        view 
        documentExists(documentId) 
        returns (bool) 
    {
        return verificationResults[documentId].isAuthentic;
    }

    /**
     * @dev Get document confidence score
     */
    function getDocumentConfidence(bytes32 documentId) 
        external 
        view 
        documentExists(documentId) 
        returns (uint256) 
    {
        return verificationResults[documentId].confidence;
    }

    /**
     * @dev Pause contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Authorize upgrade (UUPS)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Get contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
