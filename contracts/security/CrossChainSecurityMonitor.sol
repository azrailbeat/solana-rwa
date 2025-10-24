// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/**
 * @title CrossChainSecurityMonitor
 * @dev Smart contract for monitoring cross-chain security events and managing threat detection
 * @notice This contract handles security alerts, bridge monitoring, and automated responses
 */
contract CrossChainSecurityMonitor is 
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable 
{
    // Enums
    enum AlertSeverity { LOW, MEDIUM, HIGH, CRITICAL }
    enum AlertStatus { ACTIVE, INVESTIGATING, RESOLVED, FALSE_POSITIVE }
    enum ThreatType { FRAUD_DETECTION, ANOMALY_DETECTION, SUSPICIOUS_ACTIVITY, BRIDGE_EXPLOIT, FLASH_LOAN_ATTACK }

    // Structs
    struct SecurityAlert {
        uint256 id;
        ThreatType threatType;
        AlertSeverity severity;
        AlertStatus status;
        uint256 chainId;
        address targetAddress;
        bytes32 transactionHash;
        uint256 riskScore;
        uint256 timestamp;
        string description;
        address reporter;
        bool automated;
    }

    struct BridgeTransfer {
        uint256 id;
        uint256 sourceChain;
        uint256 targetChain;
        address asset;
        uint256 amount;
        address sender;
        address recipient;
        bytes32 sourceHash;
        bytes32 targetHash;
        uint256 timestamp;
        uint256 riskScore;
        bool flagged;
    }

    struct WalletRisk {
        address wallet;
        uint256 riskScore;
        uint256 transactionCount;
        uint256 totalVolume;
        uint256 firstSeen;
        uint256 lastActivity;
        bool blacklisted;
        string[] flags;
    }

    struct SecurityMetrics {
        uint256 totalAlertsGenerated;
        uint256 criticalThreatsDetected;
        uint256 bridgeTransfersMonitored;
        uint256 walletsAnalyzed;
        uint256 falsePositiveCount;
        uint256 lastUpdated;
    }

    // State Variables
    mapping(uint256 => SecurityAlert) public securityAlerts;
    mapping(uint256 => BridgeTransfer) public bridgeTransfers;
    mapping(address => WalletRisk) public walletRisks;
    mapping(address => bool) public authorizedReporters;
    mapping(address => bool) public blacklistedAddresses;
    mapping(uint256 => bool) public supportedChains;
    
    uint256 public nextAlertId;
    uint256 public nextTransferId;
    SecurityMetrics public metrics;
    
    // Configuration
    uint256 public riskThreshold;
    uint256 public autoResponseThreshold;
    bool public autoResponseEnabled;
    
    // Events
    event SecurityAlertCreated(
        uint256 indexed alertId,
        ThreatType indexed threatType,
        AlertSeverity indexed severity,
        uint256 chainId,
        address targetAddress,
        uint256 riskScore
    );
    
    event AlertStatusUpdated(
        uint256 indexed alertId,
        AlertStatus indexed oldStatus,
        AlertStatus indexed newStatus,
        address updatedBy
    );
    
    event BridgeTransferFlagged(
        uint256 indexed transferId,
        uint256 sourceChain,
        uint256 targetChain,
        address sender,
        uint256 riskScore
    );
    
    event WalletBlacklisted(
        address indexed wallet,
        uint256 riskScore,
        string reason,
        address blacklistedBy
    );
    
    event AutoResponseTriggered(
        uint256 indexed alertId,
        string action,
        address targetAddress
    );
    
    event SecurityMetricsUpdated(
        uint256 totalAlerts,
        uint256 criticalThreats,
        uint256 timestamp
    );

    // Modifiers
    modifier onlyAuthorizedReporter() {
        require(authorizedReporters[msg.sender] || msg.sender == owner(), "Not authorized reporter");
        _;
    }
    
    modifier validChain(uint256 chainId) {
        require(supportedChains[chainId], "Chain not supported");
        _;
    }
    
    modifier alertExists(uint256 alertId) {
        require(alertId < nextAlertId, "Alert does not exist");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        uint256 _riskThreshold,
        uint256 _autoResponseThreshold
    ) public initializer {
        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        _transferOwnership(_owner);
        
        riskThreshold = _riskThreshold;
        autoResponseThreshold = _autoResponseThreshold;
        autoResponseEnabled = true;
        nextAlertId = 1;
        nextTransferId = 1;
        
        // Initialize supported chains
        supportedChains[1] = true;    // Ethereum
        supportedChains[137] = true;  // Polygon
        supportedChains[56] = true;   // BSC
        supportedChains[1000] = true; // OneChain
        supportedChains[43114] = true; // Avalanche
        
        // Set owner as authorized reporter
        authorizedReporters[_owner] = true;
    }

    /**
     * @dev Create a new security alert
     * @param threatType Type of threat detected
     * @param severity Severity level of the alert
     * @param chainId Chain where the threat was detected
     * @param targetAddress Address involved in the threat
     * @param transactionHash Transaction hash related to the threat
     * @param riskScore Risk score (0-100)
     * @param description Description of the threat
     * @param automated Whether this alert was generated automatically
     */
    function createSecurityAlert(
        ThreatType threatType,
        AlertSeverity severity,
        uint256 chainId,
        address targetAddress,
        bytes32 transactionHash,
        uint256 riskScore,
        string memory description,
        bool automated
    ) external onlyAuthorizedReporter validChain(chainId) whenNotPaused {
        require(riskScore <= 100, "Risk score must be <= 100");
        require(bytes(description).length > 0, "Description required");
        
        uint256 alertId = nextAlertId++;
        
        securityAlerts[alertId] = SecurityAlert({
            id: alertId,
            threatType: threatType,
            severity: severity,
            status: AlertStatus.ACTIVE,
            chainId: chainId,
            targetAddress: targetAddress,
            transactionHash: transactionHash,
            riskScore: riskScore,
            timestamp: block.timestamp,
            description: description,
            reporter: msg.sender,
            automated: automated
        });
        
        // Update metrics
        metrics.totalAlertsGenerated++;
        if (severity == AlertSeverity.CRITICAL) {
            metrics.criticalThreatsDetected++;
        }
        metrics.lastUpdated = block.timestamp;
        
        emit SecurityAlertCreated(
            alertId,
            threatType,
            severity,
            chainId,
            targetAddress,
            riskScore
        );
        
        // Trigger auto-response if enabled and threshold met
        if (autoResponseEnabled && riskScore >= autoResponseThreshold) {
            _triggerAutoResponse(alertId, targetAddress, riskScore);
        }
    }

    /**
     * @dev Update the status of a security alert
     * @param alertId ID of the alert to update
     * @param newStatus New status for the alert
     */
    function updateAlertStatus(
        uint256 alertId,
        AlertStatus newStatus
    ) external onlyAuthorizedReporter alertExists(alertId) {
        SecurityAlert storage alert = securityAlerts[alertId];
        AlertStatus oldStatus = alert.status;
        alert.status = newStatus;
        
        // Update false positive count
        if (newStatus == AlertStatus.FALSE_POSITIVE) {
            metrics.falsePositiveCount++;
        }
        
        emit AlertStatusUpdated(alertId, oldStatus, newStatus, msg.sender);
    }

    /**
     * @dev Report a suspicious bridge transfer
     * @param sourceChain Source chain ID
     * @param targetChain Target chain ID
     * @param asset Asset address being transferred
     * @param amount Amount being transferred
     * @param sender Sender address
     * @param recipient Recipient address
     * @param sourceHash Transaction hash on source chain
     * @param riskScore Calculated risk score
     */
    function reportBridgeTransfer(
        uint256 sourceChain,
        uint256 targetChain,
        address asset,
        uint256 amount,
        address sender,
        address recipient,
        bytes32 sourceHash,
        uint256 riskScore
    ) external onlyAuthorizedReporter validChain(sourceChain) validChain(targetChain) {
        require(riskScore <= 100, "Risk score must be <= 100");
        require(sender != address(0) && recipient != address(0), "Invalid addresses");
        
        uint256 transferId = nextTransferId++;
        
        bridgeTransfers[transferId] = BridgeTransfer({
            id: transferId,
            sourceChain: sourceChain,
            targetChain: targetChain,
            asset: asset,
            amount: amount,
            sender: sender,
            recipient: recipient,
            sourceHash: sourceHash,
            targetHash: bytes32(0), // Will be updated when target transaction is confirmed
            timestamp: block.timestamp,
            riskScore: riskScore,
            flagged: riskScore >= riskThreshold
        });
        
        metrics.bridgeTransfersMonitored++;
        
        if (riskScore >= riskThreshold) {
            emit BridgeTransferFlagged(
                transferId,
                sourceChain,
                targetChain,
                sender,
                riskScore
            );
            
            // Create security alert for high-risk bridge transfer
            this.createSecurityAlert(
                ThreatType.BRIDGE_EXPLOIT,
                _getSeverityFromRisk(riskScore),
                sourceChain,
                sender,
                sourceHash,
                riskScore,
                "High-risk bridge transfer detected",
                true
            );
        }
    }

    /**
     * @dev Update wallet risk profile
     * @param wallet Wallet address to update
     * @param riskScore New risk score
     * @param transactionCount Total transaction count
     * @param totalVolume Total volume traded
     * @param flags Risk flags for the wallet
     */
    function updateWalletRisk(
        address wallet,
        uint256 riskScore,
        uint256 transactionCount,
        uint256 totalVolume,
        string[] memory flags
    ) external onlyAuthorizedReporter {
        require(wallet != address(0), "Invalid wallet address");
        require(riskScore <= 100, "Risk score must be <= 100");
        
        WalletRisk storage risk = walletRisks[wallet];
        
        if (risk.wallet == address(0)) {
            // New wallet
            risk.wallet = wallet;
            risk.firstSeen = block.timestamp;
            metrics.walletsAnalyzed++;
        }
        
        risk.riskScore = riskScore;
        risk.transactionCount = transactionCount;
        risk.totalVolume = totalVolume;
        risk.lastActivity = block.timestamp;
        risk.flags = flags;
        
        // Auto-blacklist if risk score is very high
        if (riskScore >= 90 && !risk.blacklisted) {
            risk.blacklisted = true;
            blacklistedAddresses[wallet] = true;
            
            emit WalletBlacklisted(
                wallet,
                riskScore,
                "Auto-blacklisted due to high risk score",
                msg.sender
            );
        }
    }

    /**
     * @dev Manually blacklist a wallet
     * @param wallet Wallet address to blacklist
     * @param reason Reason for blacklisting
     */
    function blacklistWallet(
        address wallet,
        string memory reason
    ) external onlyAuthorizedReporter {
        require(wallet != address(0), "Invalid wallet address");
        require(!blacklistedAddresses[wallet], "Already blacklisted");
        
        blacklistedAddresses[wallet] = true;
        
        WalletRisk storage risk = walletRisks[wallet];
        risk.blacklisted = true;
        
        emit WalletBlacklisted(wallet, risk.riskScore, reason, msg.sender);
    }

    /**
     * @dev Remove wallet from blacklist
     * @param wallet Wallet address to remove from blacklist
     */
    function removeFromBlacklist(address wallet) external onlyOwner {
        require(blacklistedAddresses[wallet], "Not blacklisted");
        
        blacklistedAddresses[wallet] = false;
        walletRisks[wallet].blacklisted = false;
    }

    /**
     * @dev Add or remove authorized reporter
     * @param reporter Reporter address
     * @param authorized Whether to authorize or deauthorize
     */
    function setAuthorizedReporter(
        address reporter,
        bool authorized
    ) external onlyOwner {
        require(reporter != address(0), "Invalid reporter address");
        authorizedReporters[reporter] = authorized;
    }

    /**
     * @dev Add or remove supported chain
     * @param chainId Chain ID to add/remove
     * @param supported Whether the chain is supported
     */
    function setSupportedChain(
        uint256 chainId,
        bool supported
    ) external onlyOwner {
        supportedChains[chainId] = supported;
    }

    /**
     * @dev Update configuration parameters
     * @param _riskThreshold New risk threshold
     * @param _autoResponseThreshold New auto-response threshold
     * @param _autoResponseEnabled Whether auto-response is enabled
     */
    function updateConfiguration(
        uint256 _riskThreshold,
        uint256 _autoResponseThreshold,
        bool _autoResponseEnabled
    ) external onlyOwner {
        require(_riskThreshold <= 100, "Risk threshold must be <= 100");
        require(_autoResponseThreshold <= 100, "Auto-response threshold must be <= 100");
        
        riskThreshold = _riskThreshold;
        autoResponseThreshold = _autoResponseThreshold;
        autoResponseEnabled = _autoResponseEnabled;
    }

    /**
     * @dev Get security alert details
     * @param alertId Alert ID to query
     * @return SecurityAlert struct
     */
    function getSecurityAlert(uint256 alertId) external view alertExists(alertId) returns (SecurityAlert memory) {
        return securityAlerts[alertId];
    }

    /**
     * @dev Get bridge transfer details
     * @param transferId Transfer ID to query
     * @return BridgeTransfer struct
     */
    function getBridgeTransfer(uint256 transferId) external view returns (BridgeTransfer memory) {
        require(transferId < nextTransferId, "Transfer does not exist");
        return bridgeTransfers[transferId];
    }

    /**
     * @dev Get wallet risk profile
     * @param wallet Wallet address to query
     * @return WalletRisk struct
     */
    function getWalletRisk(address wallet) external view returns (WalletRisk memory) {
        return walletRisks[wallet];
    }

    /**
     * @dev Check if address is blacklisted
     * @param wallet Wallet address to check
     * @return bool indicating if blacklisted
     */
    function isBlacklisted(address wallet) external view returns (bool) {
        return blacklistedAddresses[wallet];
    }

    /**
     * @dev Get current security metrics
     * @return SecurityMetrics struct
     */
    function getSecurityMetrics() external view returns (SecurityMetrics memory) {
        return metrics;
    }

    /**
     * @dev Get total number of alerts
     * @return Total alert count
     */
    function getTotalAlerts() external view returns (uint256) {
        return nextAlertId - 1;
    }

    /**
     * @dev Get total number of bridge transfers
     * @return Total transfer count
     */
    function getTotalBridgeTransfers() external view returns (uint256) {
        return nextTransferId - 1;
    }

    // Internal Functions
    function _triggerAutoResponse(
        uint256 alertId,
        address targetAddress,
        uint256 riskScore
    ) internal {
        string memory action;
        
        if (riskScore >= 95) {
            // Critical threat - immediate blacklist
            if (!blacklistedAddresses[targetAddress]) {
                blacklistedAddresses[targetAddress] = true;
                walletRisks[targetAddress].blacklisted = true;
                action = "EMERGENCY_BLACKLIST";
            }
        } else if (riskScore >= autoResponseThreshold) {
            // High threat - flag for investigation
            action = "FLAG_FOR_INVESTIGATION";
        }
        
        emit AutoResponseTriggered(alertId, action, targetAddress);
    }

    function _getSeverityFromRisk(uint256 riskScore) internal pure returns (AlertSeverity) {
        if (riskScore >= 90) return AlertSeverity.CRITICAL;
        if (riskScore >= 70) return AlertSeverity.HIGH;
        if (riskScore >= 40) return AlertSeverity.MEDIUM;
        return AlertSeverity.LOW;
    }

    // Upgrade Functions
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Emergency Functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency function to reset metrics
     * @notice Only use in case of data corruption
     */
    function resetMetrics() external onlyOwner {
        metrics = SecurityMetrics({
            totalAlertsGenerated: 0,
            criticalThreatsDetected: 0,
            bridgeTransfersMonitored: 0,
            walletsAnalyzed: 0,
            falsePositiveCount: 0,
            lastUpdated: block.timestamp
        });
    }
}
