// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../security/CircuitBreaker.sol";

/**
 * @title RWAYieldVault
 * @dev Yield-generating vault for fractional RWA tokens following Aave/Yearn patterns
 * Users deposit RWA ERC20 tokens and receive aYield tokens representing their share
 * Implements automatic compounding and configurable yield strategies
 */
contract RWAYieldVault is ERC20, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // Vault configuration
    struct VaultConfig {
        IERC20 asset;              // Underlying RWA token
        uint256 baseAPY;           // Base annual percentage yield (in basis points)
        uint256 performanceFee;    // Performance fee (in basis points)
        uint256 managementFee;     // Management fee (in basis points)
        uint256 withdrawalFee;     // Withdrawal fee (in basis points)
        uint256 minDeposit;        // Minimum deposit amount
        uint256 maxDeposit;        // Maximum deposit amount (0 = no limit)
        bool emergencyShutdown;    // Emergency shutdown flag
    }

    // User deposit information
    struct UserDeposit {
        uint256 shares;            // aYield tokens owned
        uint256 depositTime;       // Last deposit timestamp
        uint256 lastYieldClaim;    // Last yield claim timestamp
        uint256 totalDeposited;    // Total amount deposited
        uint256 totalYieldClaimed; // Total yield claimed
    }

    // Yield calculation data
    struct YieldData {
        uint256 totalAssets;       // Total underlying assets
        uint256 totalShares;       // Total aYield tokens
        uint256 lastUpdateTime;    // Last yield update timestamp
        uint256 accumulatedYield;  // Total accumulated yield
        uint256 yieldPerShare;     // Yield per share (scaled by 1e18)
        uint256 pricePerShare;     // Current price per share
    }

    // State variables
    VaultConfig public vaultConfig;
    YieldData public yieldData;
    
    mapping(address => UserDeposit) public userDeposits;
    mapping(address => bool) public authorizedYieldSources;
    
    address public treasury;
    address public yieldStrategy;
    CircuitBreaker public circuitBreaker;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant PRECISION = 1e18;

    // Events
    event Deposit(
        address indexed user,
        uint256 assets,
        uint256 shares,
        uint256 timestamp
    );
    
    event Withdraw(
        address indexed user,
        uint256 assets,
        uint256 shares,
        uint256 timestamp
    );
    
    event YieldClaimed(
        address indexed user,
        uint256 yieldAmount,
        uint256 timestamp
    );
    
    event YieldAccrued(
        uint256 totalYield,
        uint256 newPricePerShare,
        uint256 timestamp
    );
    
    event FeesCollected(
        address indexed treasury,
        uint256 performanceFee,
        uint256 managementFee,
        uint256 timestamp
    );

    event VaultConfigUpdated(
        uint256 newBaseAPY,
        uint256 newPerformanceFee,
        uint256 newManagementFee
    );

    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _treasury,
        uint256 _baseAPY
    ) ERC20(_name, _symbol) {
        require(_asset != address(0), "Invalid asset");
        require(_treasury != address(0), "Invalid treasury");
        require(_baseAPY <= 10000, "APY too high"); // Max 100%

        vaultConfig = VaultConfig({
            asset: IERC20(_asset),
            baseAPY: _baseAPY,
            performanceFee: 1000,    // 10%
            managementFee: 200,      // 2%
            withdrawalFee: 50,       // 0.5%
            minDeposit: 1e18,        // 1 token minimum
            maxDeposit: 0,           // No maximum
            emergencyShutdown: false
        });

        yieldData = YieldData({
            totalAssets: 0,
            totalShares: 0,
            lastUpdateTime: block.timestamp,
            accumulatedYield: 0,
            yieldPerShare: 0,
            pricePerShare: PRECISION
        });

        treasury = _treasury;
    }

    /**
     * @dev Deposit RWA tokens and receive aYield tokens
     * @param assets Amount of underlying tokens to deposit
     * @return shares Amount of aYield tokens minted
     */
    function deposit(uint256 assets) external nonReentrant whenNotPaused returns (uint256 shares) {
        require(assets >= vaultConfig.minDeposit, "Below minimum deposit");
        require(!vaultConfig.emergencyShutdown, "Vault shutdown");

        if (vaultConfig.maxDeposit > 0) {
            require(assets <= vaultConfig.maxDeposit, "Exceeds maximum deposit");
        }

        // Circuit breaker check
        if (address(circuitBreaker) != address(0)) {
            (bool allowed, string memory reason) = circuitBreaker.checkTransaction(msg.sender, assets);
            require(allowed, reason);
        }

        // Update yield before deposit
        _updateYield();

        // Calculate shares to mint
        shares = _convertToShares(assets);
        require(shares > 0, "Zero shares");

        // Update user data
        UserDeposit storage user = userDeposits[msg.sender];
        user.shares = user.shares + shares;
        user.depositTime = block.timestamp;
        user.totalDeposited = user.totalDeposited + assets;
        
        if (user.lastYieldClaim == 0) {
            user.lastYieldClaim = block.timestamp;
        }

        // Update vault data
        yieldData.totalAssets = yieldData.totalAssets + assets;
        yieldData.totalShares = yieldData.totalShares + shares;

        // Transfer tokens and mint shares
        vaultConfig.asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(msg.sender, shares);

        emit Deposit(msg.sender, assets, shares, block.timestamp);
        return shares;
    }

    /**
     * @dev Withdraw underlying tokens by burning aYield tokens
     * @param shares Amount of aYield tokens to burn
     * @return assets Amount of underlying tokens withdrawn
     */
    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "Zero shares");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");

        // Update yield before withdrawal
        _updateYield();

        // Calculate assets first for circuit breaker check
        uint256 assetsBeforeFee = _convertToAssets(shares);

        // Circuit breaker check
        if (address(circuitBreaker) != address(0)) {
            (bool allowed, string memory reason) = circuitBreaker.checkTransaction(msg.sender, assetsBeforeFee);
            require(allowed, reason);
        }

        // Calculate assets to return
        assets = _convertToAssets(shares);
        require(assets > 0, "Zero assets");

        // Calculate withdrawal fee
        uint256 withdrawalFee = assets * vaultConfig.withdrawalFee / BASIS_POINTS;
        uint256 assetsAfterFee = assets - withdrawalFee;

        // Update user data
        UserDeposit storage user = userDeposits[msg.sender];
        user.shares = user.shares - shares;

        // Update vault data
        yieldData.totalAssets = yieldData.totalAssets - assets;
        yieldData.totalShares = yieldData.totalShares - shares;

        // Burn shares and transfer tokens
        _burn(msg.sender, shares);
        vaultConfig.asset.safeTransfer(msg.sender, assetsAfterFee);
        
        // Send withdrawal fee to treasury
        if (withdrawalFee > 0) {
            vaultConfig.asset.safeTransfer(treasury, withdrawalFee);
        }

        emit Withdraw(msg.sender, assetsAfterFee, shares, block.timestamp);
        return assetsAfterFee;
    }

    /**
     * @dev Claim accumulated yield without withdrawing principal
     * @return yieldAmount Amount of yield claimed
     */
    function claimYield() external nonReentrant whenNotPaused returns (uint256 yieldAmount) {
        _updateYield();

        UserDeposit storage user = userDeposits[msg.sender];
        require(user.shares > 0, "No deposits");

        yieldAmount = calculateYield(msg.sender);
        require(yieldAmount > 0, "No yield to claim");

        // Circuit breaker check
        if (address(circuitBreaker) != address(0)) {
            (bool allowed, string memory reason) = circuitBreaker.checkTransaction(msg.sender, yieldAmount);
            require(allowed, reason);
        }

        // Check vault solvency before claiming
        require(
            vaultConfig.asset.balanceOf(address(this)) >= yieldAmount,
            "Insufficient vault balance"
        );

        // Update user's last claim time
        user.lastYieldClaim = block.timestamp;
        user.totalYieldClaimed = user.totalYieldClaimed + yieldAmount;

        // Transfer yield (minted from accumulated yield)
        vaultConfig.asset.safeTransfer(msg.sender, yieldAmount);

        emit YieldClaimed(msg.sender, yieldAmount, block.timestamp);
        return yieldAmount;
    }

    /**
     * @dev Calculate pending yield for a user
     * @param user Address of the user
     * @return yieldAmount Pending yield amount
     */
    function calculateYield(address user) public view returns (uint256 yieldAmount) {
        UserDeposit memory userDeposit = userDeposits[user];
        if (userDeposit.shares == 0) return 0;

        // Calculate time-based yield
        uint256 timeElapsed = block.timestamp - userDeposit.lastYieldClaim;
        uint256 userAssets = _convertToAssets(userDeposit.shares);

        // Simple interest calculation: Principal * Rate * Time / Year
        uint256 annualYield = userAssets * vaultConfig.baseAPY / BASIS_POINTS;
        yieldAmount = annualYield * timeElapsed / SECONDS_PER_YEAR;

        return yieldAmount;
    }

    /**
     * @dev Get total assets under management
     */
    function totalAssets() public view returns (uint256) {
        return yieldData.totalAssets;
    }

    /**
     * @dev Get current price per share
     */
    function pricePerShare() public view returns (uint256) {
        if (yieldData.totalShares == 0) return PRECISION;
        return yieldData.totalAssets * PRECISION / yieldData.totalShares;
    }

    /**
     * @dev Convert assets to shares
     */
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets);
    }

    /**
     * @dev Convert shares to assets
     */
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares);
    }

    /**
     * @dev Get user's total deposited assets
     */
    function getUserAssets(address user) external view returns (uint256) {
        return _convertToAssets(userDeposits[user].shares);
    }

    /**
     * @dev Get user's pending yield
     */
    function getPendingYield(address user) external view returns (uint256) {
        return calculateYield(user);
    }

    /**
     * @dev Get vault statistics
     */
    function getVaultStats() external view returns (
        uint256 totalDeposits,
        uint256 totalSharesOutstanding,
        uint256 currentAPY,
        uint256 totalYieldGenerated,
        uint256 sharePrice
    ) {
        return (
            yieldData.totalAssets,
            yieldData.totalShares,
            vaultConfig.baseAPY,
            yieldData.accumulatedYield,
            pricePerShare()
        );
    }

    /**
     * @dev Internal function to convert assets to shares
     */
    function _convertToShares(uint256 assets) internal view returns (uint256) {
        if (yieldData.totalShares == 0) {
            return assets;
        }
        return assets * yieldData.totalShares / yieldData.totalAssets;
    }

    /**
     * @dev Internal function to convert shares to assets
     */
    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        if (yieldData.totalShares == 0) {
            return shares;
        }
        return shares * yieldData.totalAssets / yieldData.totalShares;
    }

    /**
     * @dev Update yield calculations
     */
    function _updateYield() internal {
        if (block.timestamp <= yieldData.lastUpdateTime) {
            return;
        }

        if (yieldData.totalAssets == 0) {
            yieldData.lastUpdateTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - yieldData.lastUpdateTime;

        // Calculate yield based on base APY
        uint256 annualYield = yieldData.totalAssets * vaultConfig.baseAPY / BASIS_POINTS;
        uint256 periodYield = annualYield * timeElapsed / SECONDS_PER_YEAR;

        if (periodYield > 0) {
            // Calculate fees
            uint256 performanceFee = periodYield * vaultConfig.performanceFee / BASIS_POINTS;
            uint256 managementFee = yieldData.totalAssets * vaultConfig.managementFee * timeElapsed / BASIS_POINTS / SECONDS_PER_YEAR;

            uint256 totalFees = performanceFee + managementFee;
            uint256 netYield = periodYield - Math.min(periodYield, totalFees);

            // Update yield data
            yieldData.accumulatedYield = yieldData.accumulatedYield + netYield;
            yieldData.totalAssets = yieldData.totalAssets + netYield;
            yieldData.pricePerShare = pricePerShare();

            // Collect fees
            if (totalFees > 0) {
                // In a real implementation, fees would be collected from yield strategy
                emit FeesCollected(treasury, performanceFee, managementFee, block.timestamp);
            }

            emit YieldAccrued(netYield, yieldData.pricePerShare, block.timestamp);
        }

        yieldData.lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Emergency functions
     */
    function emergencyShutdown() external onlyOwner {
        vaultConfig.emergencyShutdown = true;
        _pause();
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        require(token != address(vaultConfig.asset), "Cannot withdraw vault asset");
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @dev Admin functions
     */
    function updateVaultConfig(
        uint256 _baseAPY,
        uint256 _performanceFee,
        uint256 _managementFee,
        uint256 _withdrawalFee
    ) external onlyOwner {
        require(_baseAPY <= 10000, "APY too high");
        require(_performanceFee <= 2000, "Performance fee too high");
        require(_managementFee <= 1000, "Management fee too high");
        require(_withdrawalFee <= 1000, "Withdrawal fee too high");

        _updateYield(); // Update yield with current config first

        vaultConfig.baseAPY = _baseAPY;
        vaultConfig.performanceFee = _performanceFee;
        vaultConfig.managementFee = _managementFee;
        vaultConfig.withdrawalFee = _withdrawalFee;

        emit VaultConfigUpdated(_baseAPY, _performanceFee, _managementFee);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
    }

    function setYieldStrategy(address _yieldStrategy) external onlyOwner {
        yieldStrategy = _yieldStrategy;
    }

    function setCircuitBreaker(address _circuitBreaker) external onlyOwner {
        circuitBreaker = CircuitBreaker(_circuitBreaker);
    }

    function setDepositLimits(uint256 _minDeposit, uint256 _maxDeposit) external onlyOwner {
        vaultConfig.minDeposit = _minDeposit;
        vaultConfig.maxDeposit = _maxDeposit;
    }

    function addYieldSource(address source) external onlyOwner {
        authorizedYieldSources[source] = true;
    }

    function removeYieldSource(address source) external onlyOwner {
        authorizedYieldSources[source] = false;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Yield strategy integration (for future use)
     */
    function executeYieldStrategy() external {
        require(authorizedYieldSources[msg.sender] || msg.sender == yieldStrategy, "Unauthorized");
        _updateYield();
    }

    /**
     * @dev Compound yield back into vault
     */
    function compoundYield() external nonReentrant whenNotPaused {
        uint256 yieldAmount = calculateYield(msg.sender);
        require(yieldAmount > 0, "No yield to compound");

        UserDeposit storage user = userDeposits[msg.sender];

        // Convert yield to shares and add to user's position
        uint256 newShares = _convertToShares(yieldAmount);
        user.shares = user.shares + newShares;
        user.lastYieldClaim = block.timestamp;
        user.totalYieldClaimed = user.totalYieldClaimed + yieldAmount;

        // Update vault totals
        yieldData.totalShares = yieldData.totalShares + newShares;

        // Mint new shares for compounded yield
        _mint(msg.sender, newShares);

        emit YieldClaimed(msg.sender, yieldAmount, block.timestamp);
    }

    // NOTE: batchClaimYield function removed for security and privacy reasons
    // Users must claim their own yield via claimYield() or compoundYield()
}
