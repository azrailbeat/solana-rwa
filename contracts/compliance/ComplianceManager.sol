// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IIdentityPassportNFT.sol";

/**
 * @title ComplianceManager
 * @dev Comprehensive compliance module for RWA regulations and DeFi compliance
 * @notice Handles KYC, AML, geographic restrictions, and regulatory compliance
 */
contract ComplianceManager is Ownable, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // ============ State Variables ============

    IIdentityPassportNFT public identityPassport;
    
    // Compliance levels
    enum ComplianceLevel {
        NONE,           // No compliance required
        BASIC,          // Basic KYC required
        ENHANCED,       // Enhanced KYC + AML
        INSTITUTIONAL,  // Institutional grade compliance
        RESTRICTED      // Restricted access
    }

    // Geographic regions
    enum Region {
        UNRESTRICTED,   // No geographic restrictions
        US,             // United States
        EU,             // European Union
        ASIA_PACIFIC,   // Asia Pacific
        RESTRICTED,     // Restricted regions
        SANCTIONED      // Sanctioned countries
    }

    // Risk levels
    enum RiskLevel {
        LOW,
        MEDIUM,
        HIGH,
        CRITICAL
    }

    // Compliance status for addresses
    struct ComplianceStatus {
        bool isCompliant;
        ComplianceLevel requiredLevel;
        Region allowedRegions;
        uint256 lastUpdated;
        uint256 expiryTimestamp;
        RiskLevel riskLevel;
        string[] tags;
    }

    // Regional policy configuration
    struct RegionalPolicy {
        bool isRestricted;
        ComplianceLevel minComplianceLevel;
        uint256 maxTransactionAmount;
        uint256 dailyLimit;
        bool requiresAdditionalVerification;
        string[] restrictedAssetTypes;
    }

    // AML monitoring data
    struct AMLData {
        uint256 totalVolume24h;
        uint256 totalVolume30d;
        uint256 transactionCount24h;
        uint256 suspiciousActivityScore;
        uint256 lastRiskAssessment;
        bool flaggedForReview;
    }

    // ============ Storage ============

    // Blacklisted addresses
    EnumerableSet.AddressSet private blacklistedAddresses;
    
    // Whitelisted addresses (bypass some checks)
    EnumerableSet.AddressSet private whitelistedAddresses;
    
    // Compliance officers
    EnumerableSet.AddressSet private complianceOfficers;
    
    // Sanctioned countries/regions
    EnumerableSet.Bytes32Set private sanctionedRegions;
    
    // Address compliance status
    mapping(address => ComplianceStatus) public complianceStatus;
    
    // Regional policies
    mapping(Region => RegionalPolicy) public regionalPolicies;
    
    // AML monitoring data
    mapping(address => AMLData) public amlData;
    
    // Asset type compliance requirements
    mapping(string => ComplianceLevel) public assetComplianceRequirements;
    
    // Contract-specific compliance requirements
    mapping(address => ComplianceLevel) public contractComplianceRequirements;

    // ============ Events ============

    event ComplianceStatusUpdated(address indexed user, bool isCompliant, ComplianceLevel level);
    event AddressBlacklisted(address indexed user, string reason);
    event AddressWhitelisted(address indexed user, string reason);
    event RegionalPolicyUpdated(Region region, bool isRestricted);
    event SuspiciousActivityDetected(address indexed user, uint256 score, string reason);
    event ComplianceOfficerAdded(address indexed officer);
    event ComplianceOfficerRemoved(address indexed officer);
    event IdentityPassportUpdated(address indexed newPassport);

    // ============ Modifiers ============

    modifier onlyComplianceOfficer() {
        require(
            complianceOfficers.contains(msg.sender) || msg.sender == owner(),
            "ComplianceManager: Not authorized"
        );
        _;
    }

    modifier validAddress(address user) {
        require(user != address(0), "ComplianceManager: Invalid address");
        _;
    }

    // ============ Constructor ============

    constructor(address _identityPassport) {
        identityPassport = IIdentityPassportNFT(_identityPassport);
        
        // Initialize default regional policies
        _initializeRegionalPolicies();
        
        // Add deployer as compliance officer
        complianceOfficers.add(msg.sender);
    }

    // ============ Core Compliance Functions ============

    /**
     * @dev Check if an address is compliant for a specific operation
     * @param user Address to check
     * @param requiredLevel Minimum compliance level required
     * @param assetType Type of asset being accessed
     * @return bool True if compliant
     */
    function isCompliant(
        address user,
        ComplianceLevel requiredLevel,
        string memory assetType
    ) external view returns (bool) {
        return _isCompliant(user, requiredLevel, assetType);
    }

    /**
     * @dev Check basic compliance status
     * @param user Address to check
     * @return bool True if compliant
     */
    function isCompliant(address user) external view returns (bool) {
        return _isCompliant(user, ComplianceLevel.BASIC, "");
    }

    /**
     * @dev Require KYC compliance for an address
     * @param user Address to check
     */
    function requireKYC(address user) external view {
        require(_hasValidKYC(user), "ComplianceManager: KYC required");
    }

    /**
     * @dev Enforce regional policy compliance
     * @param user Address to check
     * @param userRegion User's region
     */
    function enforceRegionPolicy(address user, Region userRegion) external view {
        require(_isRegionAllowed(user, userRegion), "ComplianceManager: Region restricted");
    }

    /**
     * @dev Check if address is blacklisted
     * @param user Address to check
     * @return bool True if blacklisted
     */
    function isBlacklisted(address user) external view returns (bool) {
        return blacklistedAddresses.contains(user);
    }

    /**
     * @dev Check if address is whitelisted
     * @param user Address to check
     * @return bool True if whitelisted
     */
    function isWhitelisted(address user) external view returns (bool) {
        return whitelistedAddresses.contains(user);
    }

    // ============ Internal Compliance Logic ============

    function _isCompliant(
        address user,
        ComplianceLevel requiredLevel,
        string memory assetType
    ) internal view returns (bool) {
        // Check blacklist first
        if (blacklistedAddresses.contains(user)) {
            return false;
        }

        // Whitelisted addresses bypass most checks
        if (whitelistedAddresses.contains(user)) {
            return true;
        }

        // Check compliance status
        ComplianceStatus memory status = complianceStatus[user];
        
        // Check if compliance has expired
        if (status.expiryTimestamp > 0 && block.timestamp > status.expiryTimestamp) {
            return false;
        }

        // Check compliance level
        if (status.requiredLevel < requiredLevel) {
            return false;
        }

        // Check asset-specific requirements
        if (bytes(assetType).length > 0) {
            ComplianceLevel assetRequirement = assetComplianceRequirements[assetType];
            if (status.requiredLevel < assetRequirement) {
                return false;
            }
        }

        // Check risk level
        if (status.riskLevel == RiskLevel.CRITICAL) {
            return false;
        }

        return status.isCompliant;
    }

    function _hasValidKYC(address user) internal view returns (bool) {
        // Check Identity Passport NFT for KYC status
        if (address(identityPassport) != address(0)) {
            try identityPassport.getIdentityData(user) returns (
                IIdentityPassportNFT.IdentityData memory data
            ) {
                return data.kycLevel >= 1; // Basic KYC required
            } catch {
                return false;
            }
        }

        // Fallback to compliance status
        return complianceStatus[user].requiredLevel >= ComplianceLevel.BASIC;
    }

    function _isRegionAllowed(address user, Region userRegion) internal view returns (bool) {
        // Check if region is sanctioned
        if (userRegion == Region.SANCTIONED) {
            return false;
        }

        // Check regional policy
        RegionalPolicy memory policy = regionalPolicies[userRegion];
        if (policy.isRestricted) {
            // Check if user meets minimum compliance for this region
            ComplianceStatus memory status = complianceStatus[user];
            return status.requiredLevel >= policy.minComplianceLevel;
        }

        return true;
    }

    // ============ Admin Functions ============

    /**
     * @dev Update compliance status for an address
     * @param user Address to update
     * @param isCompliant_ Compliance status
     * @param level Required compliance level
     * @param region Allowed region
     * @param expiryTimestamp When compliance expires (0 for no expiry)
     */
    function updateComplianceStatus(
        address user,
        bool isCompliant_,
        ComplianceLevel level,
        Region region,
        uint256 expiryTimestamp
    ) external onlyComplianceOfficer validAddress(user) {
        complianceStatus[user] = ComplianceStatus({
            isCompliant: isCompliant_,
            requiredLevel: level,
            allowedRegions: region,
            lastUpdated: block.timestamp,
            expiryTimestamp: expiryTimestamp,
            riskLevel: RiskLevel.LOW,
            tags: new string[](0)
        });

        emit ComplianceStatusUpdated(user, isCompliant_, level);
    }

    /**
     * @dev Add address to blacklist
     * @param user Address to blacklist
     * @param reason Reason for blacklisting
     */
    function addToBlacklist(
        address user,
        string calldata reason
    ) external onlyComplianceOfficer validAddress(user) {
        blacklistedAddresses.add(user);
        
        // Update compliance status
        complianceStatus[user].isCompliant = false;
        complianceStatus[user].riskLevel = RiskLevel.CRITICAL;
        
        emit AddressBlacklisted(user, reason);
    }

    /**
     * @dev Remove address from blacklist
     * @param user Address to remove from blacklist
     */
    function removeFromBlacklist(address user) external onlyComplianceOfficer validAddress(user) {
        blacklistedAddresses.remove(user);
    }

    /**
     * @dev Add address to whitelist
     * @param user Address to whitelist
     * @param reason Reason for whitelisting
     */
    function addToWhitelist(
        address user,
        string calldata reason
    ) external onlyComplianceOfficer validAddress(user) {
        whitelistedAddresses.add(user);
        emit AddressWhitelisted(user, reason);
    }

    /**
     * @dev Remove address from whitelist
     * @param user Address to remove from whitelist
     */
    function removeFromWhitelist(address user) external onlyComplianceOfficer validAddress(user) {
        whitelistedAddresses.remove(user);
    }

    /**
     * @dev Update regional policy
     * @param region Region to update
     * @param policy New policy configuration
     */
    function updateRegionalPolicy(
        Region region,
        RegionalPolicy calldata policy
    ) external onlyComplianceOfficer {
        regionalPolicies[region] = policy;
        emit RegionalPolicyUpdated(region, policy.isRestricted);
    }

    /**
     * @dev Set asset compliance requirements
     * @param assetType Asset type identifier
     * @param requiredLevel Minimum compliance level
     */
    function setAssetComplianceRequirement(
        string calldata assetType,
        ComplianceLevel requiredLevel
    ) external onlyComplianceOfficer {
        assetComplianceRequirements[assetType] = requiredLevel;
    }

    /**
     * @dev Set contract compliance requirements
     * @param contractAddr Contract address
     * @param requiredLevel Minimum compliance level
     */
    function setContractComplianceRequirement(
        address contractAddr,
        ComplianceLevel requiredLevel
    ) external onlyComplianceOfficer {
        contractComplianceRequirements[contractAddr] = requiredLevel;
    }

    // ============ AML Functions ============

    /**
     * @dev Update AML data for address
     * @param user Address to update
     * @param volume24h 24-hour volume
     * @param transactionCount 24-hour transaction count
     */
    function updateAMLData(
        address user,
        uint256 volume24h,
        uint256 transactionCount
    ) external onlyComplianceOfficer {
        AMLData storage data = amlData[user];
        data.totalVolume24h = volume24h;
        data.transactionCount24h = transactionCount;
        data.lastRiskAssessment = block.timestamp;
        
        // Calculate suspicious activity score
        uint256 suspiciousScore = _calculateSuspiciousScore(user, volume24h, transactionCount);
        data.suspiciousActivityScore = suspiciousScore;
        
        // Flag for review if score is high
        if (suspiciousScore > 80) {
            data.flaggedForReview = true;
            emit SuspiciousActivityDetected(user, suspiciousScore, "High risk score");
        }
    }

    function _calculateSuspiciousScore(
        address user,
        uint256 volume24h,
        uint256 transactionCount
    ) internal view returns (uint256) {
        // Simple scoring algorithm - can be enhanced
        uint256 score = 0;
        
        // High volume in short time
        if (volume24h > 1000000 * 1e18) { // > 1M tokens
            score += 30;
        }
        
        // High transaction frequency
        if (transactionCount > 100) {
            score += 25;
        }
        
        // New address with high activity
        if (complianceStatus[user].lastUpdated == 0 && volume24h > 100000 * 1e18) {
            score += 45;
        }
        
        return score;
    }

    // ============ Compliance Officer Management ============

    /**
     * @dev Add compliance officer
     * @param officer Address to add as compliance officer
     */
    function addComplianceOfficer(address officer) external onlyOwner validAddress(officer) {
        complianceOfficers.add(officer);
        emit ComplianceOfficerAdded(officer);
    }

    /**
     * @dev Remove compliance officer
     * @param officer Address to remove as compliance officer
     */
    function removeComplianceOfficer(address officer) external onlyOwner validAddress(officer) {
        complianceOfficers.remove(officer);
        emit ComplianceOfficerRemoved(officer);
    }

    /**
     * @dev Check if address is compliance officer
     * @param officer Address to check
     * @return bool True if compliance officer
     */
    function isComplianceOfficer(address officer) external view returns (bool) {
        return complianceOfficers.contains(officer);
    }

    // ============ Identity Integration ============

    /**
     * @dev Update Identity Passport contract
     * @param newPassport New Identity Passport contract address
     */
    function updateIdentityPassport(address newPassport) external onlyOwner {
        identityPassport = IIdentityPassportNFT(newPassport);
        emit IdentityPassportUpdated(newPassport);
    }

    // ============ View Functions ============

    /**
     * @dev Get compliance status for address
     * @param user Address to check
     * @return ComplianceStatus Compliance status struct
     */
    function getComplianceStatus(address user) external view returns (ComplianceStatus memory) {
        return complianceStatus[user];
    }

    /**
     * @dev Get AML data for address
     * @param user Address to check
     * @return AMLData AML data struct
     */
    function getAMLData(address user) external view returns (AMLData memory) {
        return amlData[user];
    }

    /**
     * @dev Get regional policy
     * @param region Region to check
     * @return RegionalPolicy Regional policy struct
     */
    function getRegionalPolicy(Region region) external view returns (RegionalPolicy memory) {
        return regionalPolicies[region];
    }

    /**
     * @dev Get blacklisted addresses count
     * @return uint256 Number of blacklisted addresses
     */
    function getBlacklistedCount() external view returns (uint256) {
        return blacklistedAddresses.length();
    }

    /**
     * @dev Get blacklisted address at index
     * @param index Index to check
     * @return address Blacklisted address
     */
    function getBlacklistedAddress(uint256 index) external view returns (address) {
        return blacklistedAddresses.at(index);
    }

    // ============ Emergency Functions ============

    /**
     * @dev Emergency pause
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Emergency unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Internal Initialization ============

    function _initializeRegionalPolicies() internal {
        // US Policy - Enhanced compliance required
        regionalPolicies[Region.US] = RegionalPolicy({
            isRestricted: false,
            minComplianceLevel: ComplianceLevel.ENHANCED,
            maxTransactionAmount: 10000000 * 1e18, // 10M tokens
            dailyLimit: 50000000 * 1e18, // 50M tokens
            requiresAdditionalVerification: true,
            restrictedAssetTypes: new string[](0)
        });

        // EU Policy - Basic compliance required
        regionalPolicies[Region.EU] = RegionalPolicy({
            isRestricted: false,
            minComplianceLevel: ComplianceLevel.BASIC,
            maxTransactionAmount: 5000000 * 1e18, // 5M tokens
            dailyLimit: 25000000 * 1e18, // 25M tokens
            requiresAdditionalVerification: false,
            restrictedAssetTypes: new string[](0)
        });

        // Sanctioned regions - Completely restricted
        regionalPolicies[Region.SANCTIONED] = RegionalPolicy({
            isRestricted: true,
            minComplianceLevel: ComplianceLevel.RESTRICTED,
            maxTransactionAmount: 0,
            dailyLimit: 0,
            requiresAdditionalVerification: true,
            restrictedAssetTypes: new string[](0)
        });
    }
}
