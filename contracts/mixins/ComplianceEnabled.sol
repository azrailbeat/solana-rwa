// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IComplianceManager.sol";

/**
 * @title ComplianceEnabled
 * @dev Mixin contract to add compliance functionality to any contract
 * @notice Inherit from this contract to add compliance checks to your functions
 */
abstract contract ComplianceEnabled {
    
    // ============ State Variables ============
    
    IComplianceManager public complianceManager;
    
    // ============ Events ============
    
    event ComplianceManagerUpdated(address indexed oldManager, address indexed newManager);
    event ComplianceCheckFailed(address indexed user, string reason);
    
    // ============ Modifiers ============
    
    /**
     * @dev Require basic compliance for user
     * @param user Address to check compliance for
     */
    modifier requireCompliance(address user) {
        _requireCompliance(user, IComplianceManager.ComplianceLevel.BASIC, "");
        _;
    }
    
    /**
     * @dev Require specific compliance level for user
     * @param user Address to check compliance for
     * @param level Required compliance level
     */
    modifier requireComplianceLevel(address user, IComplianceManager.ComplianceLevel level) {
        _requireCompliance(user, level, "");
        _;
    }
    
    /**
     * @dev Require compliance for specific asset type
     * @param user Address to check compliance for
     * @param assetType Asset type being accessed
     */
    modifier requireAssetCompliance(address user, string memory assetType) {
        _requireCompliance(user, IComplianceManager.ComplianceLevel.BASIC, assetType);
        _;
    }
    
    /**
     * @dev Require KYC compliance
     * @param user Address to check KYC for
     */
    modifier requireKYC(address user) {
        if (address(complianceManager) != address(0)) {
            complianceManager.requireKYC(user);
        }
        _;
    }
    
    /**
     * @dev Require regional compliance
     * @param user Address to check
     * @param region User's region
     */
    modifier requireRegion(address user, IComplianceManager.Region region) {
        if (address(complianceManager) != address(0)) {
            complianceManager.enforceRegionPolicy(user, region);
        }
        _;
    }
    
    /**
     * @dev Ensure user is not blacklisted
     * @param user Address to check
     */
    modifier notBlacklisted(address user) {
        if (address(complianceManager) != address(0)) {
            require(!complianceManager.isBlacklisted(user), "ComplianceEnabled: Address blacklisted");
        }
        _;
    }
    
    // ============ Constructor ============
    
    /**
     * @dev Initialize compliance manager
     * @param _complianceManager Address of compliance manager contract
     */
    constructor(address _complianceManager) {
        complianceManager = IComplianceManager(_complianceManager);
    }
    
    // ============ Internal Functions ============
    
    /**
     * @dev Internal compliance check function
     * @param user Address to check
     * @param level Required compliance level
     * @param assetType Asset type (empty string if not applicable)
     */
    function _requireCompliance(
        address user,
        IComplianceManager.ComplianceLevel level,
        string memory assetType
    ) internal view {
        if (address(complianceManager) == address(0)) {
            return; // No compliance manager set, skip checks
        }
        
        bool isCompliant;
        if (bytes(assetType).length > 0) {
            isCompliant = complianceManager.isCompliant(user, level, assetType);
        } else {
            isCompliant = complianceManager.isCompliant(user, level, "");
        }
        
        require(isCompliant, "ComplianceEnabled: User not compliant");
    }
    
    /**
     * @dev Check if user is compliant (view function)
     * @param user Address to check
     * @return bool True if compliant
     */
    function _isCompliant(address user) internal view returns (bool) {
        if (address(complianceManager) == address(0)) {
            return true; // No compliance manager, assume compliant
        }
        return complianceManager.isCompliant(user);
    }
    
    /**
     * @dev Check if user is compliant for specific level and asset
     * @param user Address to check
     * @param level Required compliance level
     * @param assetType Asset type
     * @return bool True if compliant
     */
    function _isCompliant(
        address user,
        IComplianceManager.ComplianceLevel level,
        string memory assetType
    ) internal view returns (bool) {
        if (address(complianceManager) == address(0)) {
            return true; // No compliance manager, assume compliant
        }
        return complianceManager.isCompliant(user, level, assetType);
    }
    
    // ============ Admin Functions ============
    
    /**
     * @dev Update compliance manager (must be implemented by inheriting contract)
     * @param newManager New compliance manager address
     */
    function _updateComplianceManager(address newManager) internal {
        address oldManager = address(complianceManager);
        complianceManager = IComplianceManager(newManager);
        emit ComplianceManagerUpdated(oldManager, newManager);
    }
    
    // ============ View Functions ============
    
    /**
     * @dev Get compliance status for user
     * @param user Address to check
     * @return ComplianceStatus Compliance status struct
     */
    function getComplianceStatus(address user) 
        external 
        view 
        returns (IComplianceManager.ComplianceStatus memory) 
    {
        if (address(complianceManager) == address(0)) {
            // Return default compliant status if no manager
            return IComplianceManager.ComplianceStatus({
                isCompliant: true,
                requiredLevel: IComplianceManager.ComplianceLevel.NONE,
                allowedRegions: IComplianceManager.Region.UNRESTRICTED,
                lastUpdated: 0,
                expiryTimestamp: 0,
                riskLevel: IComplianceManager.RiskLevel.LOW,
                tags: new string[](0)
            });
        }
        return complianceManager.getComplianceStatus(user);
    }
    
    /**
     * @dev Check if user is compliant (external view)
     * @param user Address to check
     * @return bool True if compliant
     */
    function isUserCompliant(address user) external view returns (bool) {
        return _isCompliant(user);
    }
    
    /**
     * @dev Check if user is compliant for specific requirements
     * @param user Address to check
     * @param level Required compliance level
     * @param assetType Asset type
     * @return bool True if compliant
     */
    function isUserCompliant(
        address user,
        IComplianceManager.ComplianceLevel level,
        string memory assetType
    ) external view returns (bool) {
        return _isCompliant(user, level, assetType);
    }
}
