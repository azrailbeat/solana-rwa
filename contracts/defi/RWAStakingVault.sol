// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title RWAStakingVault
 * @dev Enables RWA NFT staking for stable yield generation
 * Supports multiple yield strategies and reward distribution
 */
contract RWAStakingVault is 
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IERC721Receiver
{
    struct StakedAsset {
        address nftContract;
        uint256 tokenId;
        address owner;
        uint256 stakedAmount; // For fractional staking
        uint256 stakingTime;
        uint256 lastRewardClaim;
        uint256 accumulatedRewards;
        uint256 yieldRate; // Annual percentage yield (APY)
        bool isActive;
        bytes32 poolId;
    }

    struct YieldPool {
        string name;
        address rewardToken;
        uint256 totalStaked;
        uint256 totalRewards;
        uint256 rewardRate; // Rewards per second per staked unit
        uint256 lastUpdateTime;
        uint256 accRewardPerShare;
        uint256 minStakingPeriod;
        uint256 lockupPeriod;
        bool isActive;
        address[] allowedNFTs;
    }

    struct UserStaking {
        bytes32[] stakedAssets;
        uint256 totalStaked;
        uint256 totalRewards;
        uint256 lastActivity;
    }

    struct RewardDistribution {
        address token;
        uint256 amount;
        uint256 timestamp;
        uint256 totalRecipients;
        mapping(address => bool) claimed;
    }

    // State variables
    mapping(bytes32 => StakedAsset) public stakedAssets;
    mapping(address => mapping(uint256 => bytes32)) public nftToStakeId;
    mapping(address => UserStaking) public userStaking;
    mapping(bytes32 => YieldPool) public yieldPools;
    mapping(uint256 => RewardDistribution) public rewardDistributions;
    
    bytes32[] public activePoolIds;
    address public rewardToken;
    address public treasury;
    uint256 public totalValueLocked;
    uint256 public totalRewardsDistributed;
    uint256 public platformFee; // Basis points
    uint256 public distributionCounter;
    
    // Yield strategies
    mapping(bytes32 => address) public yieldStrategies;
    mapping(address => bool) public authorizedStrategies;
    
    // Events
    event AssetStaked(
        bytes32 indexed stakeId,
        address indexed user,
        address indexed nftContract,
        uint256 tokenId,
        bytes32 poolId,
        uint256 amount
    );
    
    event AssetUnstaked(
        bytes32 indexed stakeId,
        address indexed user,
        uint256 rewards
    );
    
    event RewardsClaimed(
        address indexed user,
        uint256 amount,
        address token
    );
    
    event YieldPoolCreated(
        bytes32 indexed poolId,
        string name,
        address rewardToken,
        uint256 rewardRate
    );
    
    event RewardsDistributed(
        uint256 indexed distributionId,
        address token,
        uint256 amount,
        uint256 recipients
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _rewardToken,
        address _treasury
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        rewardToken = _rewardToken;
        treasury = _treasury;
        platformFee = 1000; // 10%
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Create a new yield pool
     */
    function createYieldPool(
        string memory name,
        address _rewardToken,
        uint256 rewardRate,
        uint256 minStakingPeriod,
        uint256 lockupPeriod,
        address[] memory allowedNFTs
    ) external onlyOwner returns (bytes32 poolId) {
        poolId = keccak256(abi.encodePacked(name, block.timestamp));
        
        yieldPools[poolId] = YieldPool({
            name: name,
            rewardToken: _rewardToken,
            totalStaked: 0,
            totalRewards: 0,
            rewardRate: rewardRate,
            lastUpdateTime: block.timestamp,
            accRewardPerShare: 0,
            minStakingPeriod: minStakingPeriod,
            lockupPeriod: lockupPeriod,
            isActive: true,
            allowedNFTs: allowedNFTs
        });
        
        activePoolIds.push(poolId);
        
        emit YieldPoolCreated(poolId, name, _rewardToken, rewardRate);
        
        return poolId;
    }

    /**
     * @dev Stake RWA NFT for yield
     */
    function stakeAsset(
        address nftContract,
        uint256 tokenId,
        bytes32 poolId,
        uint256 stakingAmount
    ) external nonReentrant whenNotPaused returns (bytes32 stakeId) {
        require(yieldPools[poolId].isActive, "Pool not active");
        require(_isNFTAllowed(poolId, nftContract), "NFT not allowed in pool");
        require(IERC721(nftContract).ownerOf(tokenId) == msg.sender, "Not NFT owner");
        
        // Transfer NFT to vault
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);
        
        // Update pool rewards before staking
        _updatePool(poolId);
        
        // Generate unique stake ID
        stakeId = keccak256(abi.encodePacked(
            nftContract,
            tokenId,
            msg.sender,
            block.timestamp
        ));
        
        // Get current yield rate for this asset type
        uint256 yieldRate = _calculateYieldRate(nftContract, tokenId, poolId);
        
        // Create staked asset
        stakedAssets[stakeId] = StakedAsset({
            nftContract: nftContract,
            tokenId: tokenId,
            owner: msg.sender,
            stakedAmount: stakingAmount,
            stakingTime: block.timestamp,
            lastRewardClaim: block.timestamp,
            accumulatedRewards: 0,
            yieldRate: yieldRate,
            isActive: true,
            poolId: poolId
        });
        
        // Update mappings and state
        nftToStakeId[nftContract][tokenId] = stakeId;
        userStaking[msg.sender].stakedAssets.push(stakeId);
        userStaking[msg.sender].totalStaked += stakingAmount;
        userStaking[msg.sender].lastActivity = block.timestamp;
        
        yieldPools[poolId].totalStaked += stakingAmount;
        totalValueLocked += stakingAmount;
        
        emit AssetStaked(stakeId, msg.sender, nftContract, tokenId, poolId, stakingAmount);
        
        return stakeId;
    }

    /**
     * @dev Unstake asset and claim rewards
     */
    function unstakeAsset(bytes32 stakeId) external nonReentrant whenNotPaused {
        StakedAsset storage asset = stakedAssets[stakeId];
        require(asset.owner == msg.sender, "Not asset owner");
        require(asset.isActive, "Asset not staked");
        
        YieldPool storage pool = yieldPools[asset.poolId];
        
        // Check lockup period
        require(
            block.timestamp >= asset.stakingTime + pool.lockupPeriod,
            "Asset still locked"
        );
        
        // Update pool and calculate rewards
        _updatePool(asset.poolId);
        uint256 pendingRewards = _calculatePendingRewards(stakeId);
        
        // Update state
        asset.isActive = false;
        pool.totalStaked -= asset.stakedAmount;
        totalValueLocked -= asset.stakedAmount;
        userStaking[msg.sender].totalStaked -= asset.stakedAmount;
        
        // Return NFT to owner
        IERC721(asset.nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            asset.tokenId
        );
        
        // Distribute rewards
        if (pendingRewards > 0) {
            _distributeRewards(msg.sender, pendingRewards, pool.rewardToken);
            userStaking[msg.sender].totalRewards += pendingRewards;
        }
        
        emit AssetUnstaked(stakeId, msg.sender, pendingRewards);
    }

    /**
     * @dev Claim accumulated rewards without unstaking
     */
    function claimRewards(bytes32 stakeId) external nonReentrant whenNotPaused {
        StakedAsset storage asset = stakedAssets[stakeId];
        require(asset.owner == msg.sender, "Not asset owner");
        require(asset.isActive, "Asset not staked");
        
        _updatePool(asset.poolId);
        uint256 pendingRewards = _calculatePendingRewards(stakeId);
        
        require(pendingRewards > 0, "No rewards to claim");
        
        // Update last claim time
        asset.lastRewardClaim = block.timestamp;
        asset.accumulatedRewards += pendingRewards;
        
        YieldPool storage pool = yieldPools[asset.poolId];
        _distributeRewards(msg.sender, pendingRewards, pool.rewardToken);
        
        userStaking[msg.sender].totalRewards += pendingRewards;
        
        emit RewardsClaimed(msg.sender, pendingRewards, pool.rewardToken);
    }

    /**
     * @dev Batch claim rewards for multiple assets
     */
    function batchClaimRewards(bytes32[] calldata stakeIds) external nonReentrant whenNotPaused {
        uint256 totalRewards = 0;
        address rewardTokenAddr = rewardToken;
        
        for (uint256 i = 0; i < stakeIds.length; i++) {
            StakedAsset storage asset = stakedAssets[stakeIds[i]];
            require(asset.owner == msg.sender, "Not asset owner");
            require(asset.isActive, "Asset not staked");
            
            _updatePool(asset.poolId);
            uint256 pendingRewards = _calculatePendingRewards(stakeIds[i]);
            
            if (pendingRewards > 0) {
                asset.lastRewardClaim = block.timestamp;
                asset.accumulatedRewards += pendingRewards;
                totalRewards += pendingRewards;
            }
        }
        
        if (totalRewards > 0) {
            _distributeRewards(msg.sender, totalRewards, rewardTokenAddr);
            userStaking[msg.sender].totalRewards += totalRewards;
            
            emit RewardsClaimed(msg.sender, totalRewards, rewardTokenAddr);
        }
    }

    /**
     * @dev Compound rewards back into staking
     */
    function compoundRewards(bytes32 stakeId) external nonReentrant whenNotPaused {
        StakedAsset storage asset = stakedAssets[stakeId];
        require(asset.owner == msg.sender, "Not asset owner");
        require(asset.isActive, "Asset not staked");
        
        _updatePool(asset.poolId);
        uint256 pendingRewards = _calculatePendingRewards(stakeId);
        
        require(pendingRewards > 0, "No rewards to compound");
        
        // Add rewards to staked amount
        asset.stakedAmount += pendingRewards;
        asset.lastRewardClaim = block.timestamp;
        asset.accumulatedRewards += pendingRewards;
        
        // Update pool and user totals
        yieldPools[asset.poolId].totalStaked += pendingRewards;
        userStaking[msg.sender].totalStaked += pendingRewards;
        totalValueLocked += pendingRewards;
    }

    /**
     * @dev Update pool reward calculations
     */
    function _updatePool(bytes32 poolId) internal {
        YieldPool storage pool = yieldPools[poolId];
        
        if (block.timestamp <= pool.lastUpdateTime) {
            return;
        }
        
        if (pool.totalStaked == 0) {
            pool.lastUpdateTime = block.timestamp;
            return;
        }
        
        uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
        uint256 reward = timeElapsed * pool.rewardRate;
        
        pool.accRewardPerShare += (reward * 1e18) / pool.totalStaked;
        pool.lastUpdateTime = block.timestamp;
        pool.totalRewards += reward;
    }

    /**
     * @dev Calculate pending rewards for a staked asset
     */
    function _calculatePendingRewards(bytes32 stakeId) internal view returns (uint256) {
        StakedAsset memory asset = stakedAssets[stakeId];
        YieldPool memory pool = yieldPools[asset.poolId];
        
        uint256 timeStaked = block.timestamp - asset.lastRewardClaim;
        uint256 annualReward = (asset.stakedAmount * asset.yieldRate) / 10000;
        uint256 reward = (annualReward * timeStaked) / 365 days;
        
        return reward;
    }

    /**
     * @dev Calculate yield rate based on asset characteristics
     */
    function _calculateYieldRate(
        address nftContract,
        uint256 tokenId,
        bytes32 poolId
    ) internal view returns (uint256) {
        // Base yield rate from pool
        uint256 baseRate = yieldPools[poolId].rewardRate;
        
        // Asset-specific multipliers could be added here
        // For now, return base rate
        return baseRate;
    }

    /**
     * @dev Check if NFT is allowed in pool
     */
    function _isNFTAllowed(bytes32 poolId, address nftContract) internal view returns (bool) {
        address[] memory allowedNFTs = yieldPools[poolId].allowedNFTs;
        
        for (uint256 i = 0; i < allowedNFTs.length; i++) {
            if (allowedNFTs[i] == nftContract) {
                return true;
            }
        }
        
        return false;
    }

    /**
     * @dev Distribute rewards to user
     */
    function _distributeRewards(address user, uint256 amount, address token) internal {
        uint256 platformFeeAmount = (amount * platformFee) / 10000;
        uint256 userReward = amount - platformFeeAmount;
        
        // Transfer rewards to user
        IERC20(token).transfer(user, userReward);
        
        // Transfer fee to treasury
        if (platformFeeAmount > 0) {
            IERC20(token).transfer(treasury, platformFeeAmount);
        }
        
        totalRewardsDistributed += amount;
    }

    /**
     * @dev Add rewards to pool
     */
    function addRewardsToPool(bytes32 poolId, uint256 amount) external {
        require(yieldPools[poolId].isActive, "Pool not active");
        
        YieldPool storage pool = yieldPools[poolId];
        IERC20(pool.rewardToken).transferFrom(msg.sender, address(this), amount);
        
        pool.totalRewards += amount;
    }

    /**
     * @dev Get user's staked assets
     */
    function getUserStakedAssets(address user) external view returns (bytes32[] memory) {
        return userStaking[user].stakedAssets;
    }

    /**
     * @dev Get pending rewards for user
     */
    function getPendingRewards(address user) external view returns (uint256 totalPending) {
        bytes32[] memory userAssets = userStaking[user].stakedAssets;
        
        for (uint256 i = 0; i < userAssets.length; i++) {
            if (stakedAssets[userAssets[i]].isActive) {
                totalPending += _calculatePendingRewards(userAssets[i]);
            }
        }
        
        return totalPending;
    }

    /**
     * @dev Get staking statistics
     */
    function getStakingStats() external view returns (
        uint256 totalStaked,
        uint256 totalRewards,
        uint256 activeStakers,
        uint256 activePools
    ) {
        return (
            totalValueLocked,
            totalRewardsDistributed,
            0, // Would need to track active stakers
            activePoolIds.length
        );
    }

    /**
     * @dev Get pool information
     */
    function getPoolInfo(bytes32 poolId) external view returns (
        string memory name,
        address rewardTokenAddr,
        uint256 totalStaked,
        uint256 rewardRate,
        uint256 minStakingPeriod,
        bool isActive
    ) {
        YieldPool memory pool = yieldPools[poolId];
        return (
            pool.name,
            pool.rewardToken,
            pool.totalStaked,
            pool.rewardRate,
            pool.minStakingPeriod,
            pool.isActive
        );
    }

    /**
     * @dev Admin functions
     */
    function updatePoolRewardRate(bytes32 poolId, uint256 newRate) external onlyOwner {
        _updatePool(poolId);
        yieldPools[poolId].rewardRate = newRate;
    }

    function pausePool(bytes32 poolId) external onlyOwner {
        yieldPools[poolId].isActive = false;
    }

    function unpausePool(bytes32 poolId) external onlyOwner {
        yieldPools[poolId].isActive = true;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setPlatformFee(uint256 _platformFee) external onlyOwner {
        require(_platformFee <= 2000, "Fee too high"); // Max 20%
        platformFee = _platformFee;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency withdrawal
     */
    function emergencyWithdraw(bytes32 stakeId) external nonReentrant {
        StakedAsset storage asset = stakedAssets[stakeId];
        require(asset.owner == msg.sender, "Not asset owner");
        require(asset.isActive, "Asset not staked");
        
        // Return NFT without rewards
        asset.isActive = false;
        yieldPools[asset.poolId].totalStaked -= asset.stakedAmount;
        totalValueLocked -= asset.stakedAmount;
        
        IERC721(asset.nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            asset.tokenId
        );
    }

    /**
     * @dev Handle NFT transfers
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @dev Withdraw accumulated fees
     */
    function withdrawFees(address token, address to) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(to, balance);
    }
}
