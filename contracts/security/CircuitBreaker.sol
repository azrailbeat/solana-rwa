// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title CircuitBreaker
 * @dev Protection mechanism for high-value transactions and suspicious activity
 * Implements daily volume limits, per-user rate limiting, and automatic pausing
 */
contract CircuitBreaker is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // Circuit breaker configuration
    struct CircuitBreakerConfig {
        uint256 dailyVolumeLimit;      // Maximum daily transaction volume
        uint256 perUserDailyLimit;     // Maximum per-user daily volume
        uint256 perTxLimit;            // Maximum single transaction
        uint256 txPerUserPer24h;       // Max transactions per user per 24h
        uint256 minTimeBetweenTx;      // Minimum time between transactions (seconds)
        bool enabled;                  // Circuit breaker enabled
    }

    // User activity tracking
    struct UserActivity {
        uint256 dailyVolume;           // User's 24h volume
        uint256 lastTxTimestamp;       // Last transaction time
        uint256 txCount24h;            // Transaction count in 24h
        uint256 lastResetTimestamp;    // Last reset time
        bool isFlagged;                // Flagged for suspicious activity
    }

    // Global state
    CircuitBreakerConfig public config;
    uint256 public dailyVolume;
    uint256 public lastVolumeReset;

    // Per-user tracking
    mapping(address => UserActivity) public userActivity;

    // Whitelisted addresses (bypass limits)
    mapping(address => bool) public whitelisted;

    // Authorized operators
    mapping(address => bool) public operators;

    // Events
    event CircuitBreakerTriggered(
        address indexed user,
        uint256 amount,
        string reason,
        uint256 timestamp
    );

    event UserFlagged(
        address indexed user,
        string reason,
        uint256 timestamp
    );

    event ConfigUpdated(
        uint256 dailyVolumeLimit,
        uint256 perUserDailyLimit,
        uint256 perTxLimit,
        uint256 timestamp
    );

    event UserWhitelisted(address indexed user, bool status);
    event OperatorUpdated(address indexed operator, bool status);

    // Modifiers
    modifier onlyOperator() {
        require(operators[msg.sender] || msg.sender == owner(), "Not operator");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Set conservative default limits
        config = CircuitBreakerConfig({
            dailyVolumeLimit: 10_000_000e18,     // $10M daily
            perUserDailyLimit: 1_000_000e18,     // $1M per user daily
            perTxLimit: 100_000e18,              // $100k per transaction
            txPerUserPer24h: 100,                // 100 tx per user per day
            minTimeBetweenTx: 5,                 // 5 seconds between tx
            enabled: true
        });

        lastVolumeReset = block.timestamp;
        operators[initialOwner] = true;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Check if transaction should be allowed
     * @param user Address initiating transaction
     * @param amount Transaction amount
     * @return allowed Whether transaction passes all checks
     * @return reason Reason if not allowed
     */
    function checkTransaction(
        address user,
        uint256 amount
    ) external onlyOperator returns (bool allowed, string memory reason) {
        // Skip checks for whitelisted users
        if (whitelisted[user]) {
            return (true, "");
        }

        // Skip checks if circuit breaker disabled
        if (!config.enabled) {
            return (true, "");
        }

        // Check if contract is paused
        if (paused()) {
            return (false, "Circuit breaker paused");
        }

        // Check per-transaction limit
        if (amount > config.perTxLimit) {
            emit CircuitBreakerTriggered(user, amount, "Exceeds per-tx limit", block.timestamp);
            return (false, "Transaction exceeds maximum limit");
        }

        // Reset daily volume if 24h passed
        if (block.timestamp > lastVolumeReset + 1 days) {
            dailyVolume = 0;
            lastVolumeReset = block.timestamp;
        }

        // Check global daily volume limit
        if (dailyVolume + amount > config.dailyVolumeLimit) {
            emit CircuitBreakerTriggered(user, amount, "Global daily limit exceeded", block.timestamp);
            _pause(); // Automatically pause on daily limit
            return (false, "Daily volume limit exceeded - circuit breaker triggered");
        }

        // Get user activity
        UserActivity storage activity = userActivity[user];

        // Check if user is flagged
        if (activity.isFlagged) {
            return (false, "User flagged for suspicious activity");
        }

        // Reset user activity if 24h passed
        if (block.timestamp > activity.lastResetTimestamp + 1 days) {
            activity.dailyVolume = 0;
            activity.txCount24h = 0;
            activity.lastResetTimestamp = block.timestamp;
        }

        // Check per-user daily limit
        if (activity.dailyVolume + amount > config.perUserDailyLimit) {
            emit CircuitBreakerTriggered(user, amount, "User daily limit exceeded", block.timestamp);
            return (false, "Your daily transaction limit exceeded");
        }

        // Check transaction frequency
        if (block.timestamp < activity.lastTxTimestamp + config.minTimeBetweenTx) {
            return (false, "Transaction too soon after previous");
        }

        // Check transaction count limit
        if (activity.txCount24h >= config.txPerUserPer24h) {
            emit CircuitBreakerTriggered(user, amount, "User tx count exceeded", block.timestamp);
            return (false, "Daily transaction count exceeded");
        }

        // Update state
        dailyVolume += amount;
        activity.dailyVolume += amount;
        activity.lastTxTimestamp = block.timestamp;
        activity.txCount24h++;

        // Flag user if suspicious pattern detected
        if (_isSuspiciousActivity(user, amount)) {
            activity.isFlagged = true;
            emit UserFlagged(user, "Suspicious activity detected", block.timestamp);
            return (false, "Suspicious activity detected - account flagged");
        }

        return (true, "");
    }

    /**
     * @dev Detect suspicious activity patterns
     */
    function _isSuspiciousActivity(address user, uint256 amount) internal view returns (bool) {
        UserActivity memory activity = userActivity[user];

        // Large transaction from new user
        if (activity.txCount24h == 0 && amount > config.perTxLimit / 2) {
            return true;
        }

        // Rapid succession of large transactions
        if (activity.txCount24h > 20 && activity.dailyVolume > config.perUserDailyLimit / 2) {
            return true;
        }

        // Multiple transactions in very short time
        if (activity.txCount24h > 10 &&
            block.timestamp < activity.lastResetTimestamp + 1 hours) {
            return true;
        }

        return false;
    }

    /**
     * @dev Update circuit breaker configuration
     */
    function updateConfig(
        uint256 _dailyVolumeLimit,
        uint256 _perUserDailyLimit,
        uint256 _perTxLimit,
        uint256 _txPerUserPer24h,
        uint256 _minTimeBetweenTx
    ) external onlyOwner {
        require(_dailyVolumeLimit > 0, "Invalid daily limit");
        require(_perUserDailyLimit > 0, "Invalid user limit");
        require(_perTxLimit > 0, "Invalid tx limit");

        config.dailyVolumeLimit = _dailyVolumeLimit;
        config.perUserDailyLimit = _perUserDailyLimit;
        config.perTxLimit = _perTxLimit;
        config.txPerUserPer24h = _txPerUserPer24h;
        config.minTimeBetweenTx = _minTimeBetweenTx;

        emit ConfigUpdated(_dailyVolumeLimit, _perUserDailyLimit, _perTxLimit, block.timestamp);
    }

    /**
     * @dev Enable/disable circuit breaker
     */
    function setEnabled(bool _enabled) external onlyOwner {
        config.enabled = _enabled;
    }

    /**
     * @dev Whitelist user (bypass limits)
     */
    function setWhitelisted(address user, bool status) external onlyOwner {
        whitelisted[user] = status;
        emit UserWhitelisted(user, status);
    }

    /**
     * @dev Add/remove operator
     */
    function setOperator(address operator, bool status) external onlyOwner {
        operators[operator] = status;
        emit OperatorUpdated(operator, status);
    }

    /**
     * @dev Flag/unflag user
     */
    function setUserFlagged(address user, bool flagged) external onlyOwner {
        userActivity[user].isFlagged = flagged;
        if (flagged) {
            emit UserFlagged(user, "Manually flagged by admin", block.timestamp);
        }
    }

    /**
     * @dev Reset user activity (for false positives)
     */
    function resetUserActivity(address user) external onlyOwner {
        delete userActivity[user];
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

    // View functions
    function getCurrentDailyVolume() external view returns (uint256) {
        if (block.timestamp > lastVolumeReset + 1 days) {
            return 0;
        }
        return dailyVolume;
    }

    function getUserActivity(address user) external view returns (
        uint256 dailyVol,
        uint256 lastTx,
        uint256 txCount,
        bool flagged
    ) {
        UserActivity memory activity = userActivity[user];
        return (
            activity.dailyVolume,
            activity.lastTxTimestamp,
            activity.txCount24h,
            activity.isFlagged
        );
    }

    function isTransactionAllowed(
        address user,
        uint256 amount
    ) external view returns (bool) {
        if (whitelisted[user] || !config.enabled || paused()) {
            return !paused();
        }

        if (amount > config.perTxLimit) {
            return false;
        }

        if (block.timestamp <= lastVolumeReset + 1 days) {
            if (dailyVolume + amount > config.dailyVolumeLimit) {
                return false;
            }
        }

        UserActivity memory activity = userActivity[user];

        if (activity.isFlagged) {
            return false;
        }

        if (block.timestamp <= activity.lastResetTimestamp + 1 days) {
            if (activity.dailyVolume + amount > config.perUserDailyLimit) {
                return false;
            }
            if (activity.txCount24h >= config.txPerUserPer24h) {
                return false;
            }
        }

        return true;
    }
}
