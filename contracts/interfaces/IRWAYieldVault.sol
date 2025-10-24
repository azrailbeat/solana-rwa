// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IRWAYieldVault
 * @dev Interface for RWA yield-generating vault
 */
interface IRWAYieldVault {
    
    // Structs
    struct VaultConfig {
        IERC20 asset;
        uint256 baseAPY;
        uint256 performanceFee;
        uint256 managementFee;
        uint256 withdrawalFee;
        uint256 minDeposit;
        uint256 maxDeposit;
        bool emergencyShutdown;
    }

    struct UserDeposit {
        uint256 shares;
        uint256 depositTime;
        uint256 lastYieldClaim;
        uint256 totalDeposited;
        uint256 totalYieldClaimed;
    }

    struct YieldData {
        uint256 totalAssets;
        uint256 totalShares;
        uint256 lastUpdateTime;
        uint256 accumulatedYield;
        uint256 yieldPerShare;
        uint256 pricePerShare;
    }

    // Events
    event Deposit(address indexed user, uint256 assets, uint256 shares, uint256 timestamp);
    event Withdraw(address indexed user, uint256 assets, uint256 shares, uint256 timestamp);
    event YieldClaimed(address indexed user, uint256 yieldAmount, uint256 timestamp);
    event YieldAccrued(uint256 totalYield, uint256 newPricePerShare, uint256 timestamp);
    event FeesCollected(address indexed treasury, uint256 performanceFee, uint256 managementFee, uint256 timestamp);
    event VaultConfigUpdated(uint256 newBaseAPY, uint256 newPerformanceFee, uint256 newManagementFee);

    // Core functions
    function deposit(uint256 assets) external returns (uint256 shares);
    function withdraw(uint256 shares) external returns (uint256 assets);
    function claimYield() external returns (uint256 yieldAmount);
    function calculateYield(address user) external view returns (uint256 yieldAmount);
    function compoundYield() external;

    // View functions
    function totalAssets() external view returns (uint256);
    function pricePerShare() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function getUserAssets(address user) external view returns (uint256);
    function getPendingYield(address user) external view returns (uint256);
    
    function getVaultStats() external view returns (
        uint256 totalDeposits,
        uint256 totalSharesOutstanding,
        uint256 currentAPY,
        uint256 totalYieldGenerated,
        uint256 sharePrice
    );

    // Admin functions
    function updateVaultConfig(
        uint256 _baseAPY,
        uint256 _performanceFee,
        uint256 _managementFee,
        uint256 _withdrawalFee
    ) external;
    
    function setTreasury(address _treasury) external;
    function setYieldStrategy(address _yieldStrategy) external;
    function emergencyShutdown() external;
}
