// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IComplianceManager
 * @dev Interface for the ComplianceManager contract
 */
interface IComplianceManager {
    
    // ============ Enums ============
    
    enum ComplianceLevel {
        NONE,
        BASIC,
        ENHANCED,
        INSTITUTIONAL,
        RESTRICTED
    }

    enum Region {
        UNRESTRICTED,
        US,
        EU,
        ASIA_PACIFIC,
        RESTRICTED,
        SANCTIONED
    }

    enum RiskLevel {
        LOW,
        MEDIUM,
        HIGH,
        CRITICAL
    }

    // ============ Structs ============

    struct ComplianceStatus {
        bool isCompliant;
        ComplianceLevel requiredLevel;
        Region allowedRegions;
        uint256 lastUpdated;
        uint256 expiryTimestamp;
        RiskLevel riskLevel;
        string[] tags;
    }

    struct RegionalPolicy {
        bool isRestricted;
        ComplianceLevel minComplianceLevel;
        uint256 maxTransactionAmount;
        uint256 dailyLimit;
        bool requiresAdditionalVerification;
        string[] restrictedAssetTypes;
    }

    struct AMLData {
        uint256 totalVolume24h;
        uint256 totalVolume30d;
        uint256 transactionCount24h;
        uint256 suspiciousActivityScore;
        uint256 lastRiskAssessment;
        bool flaggedForReview;
    }

    // ============ Events ============

    event ComplianceStatusUpdated(address indexed user, bool isCompliant, ComplianceLevel level);
    event AddressBlacklisted(address indexed user, string reason);
    event AddressWhitelisted(address indexed user, string reason);
    event RegionalPolicyUpdated(Region region, bool isRestricted);
    event SuspiciousActivityDetected(address indexed user, uint256 score, string reason);

    // ============ Core Functions ============

    function isCompliant(address user) external view returns (bool);
    
    function isCompliant(
        address user,
        ComplianceLevel requiredLevel,
        string memory assetType
    ) external view returns (bool);

    function requireKYC(address user) external view;

    function enforceRegionPolicy(address user, Region userRegion) external view;

    function isBlacklisted(address user) external view returns (bool);

    function isWhitelisted(address user) external view returns (bool);

    // ============ Admin Functions ============

    function updateComplianceStatus(
        address user,
        bool isCompliant_,
        ComplianceLevel level,
        Region region,
        uint256 expiryTimestamp
    ) external;

    function addToBlacklist(address user, string calldata reason) external;

    function removeFromBlacklist(address user) external;

    function addToWhitelist(address user, string calldata reason) external;

    function removeFromWhitelist(address user) external;

    // ============ View Functions ============

    function getComplianceStatus(address user) external view returns (ComplianceStatus memory);

    function getAMLData(address user) external view returns (AMLData memory);

    function getRegionalPolicy(Region region) external view returns (RegionalPolicy memory);
}
