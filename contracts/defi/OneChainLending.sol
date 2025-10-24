// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OneChainLending
 * @dev Native lending protocol for OneChain with RWA NFT collateral support
 */
contract OneChainLending is 
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    struct LendingPool {
        address asset;
        uint256 totalSupply;
        uint256 totalBorrow;
        uint256 supplyRate;
        uint256 borrowRate;
        uint256 utilizationRate;
        uint256 reserveFactor;
        uint256 lastUpdateTime;
        bool isActive;
        uint256 supplyCap;
        uint256 borrowCap;
    }

    struct UserPosition {
        uint256 supplied;
        uint256 borrowed;
        uint256 collateralValue;
        uint256 healthFactor;
        uint256 lastInterestUpdate;
        bool canBeLiquidated;
    }

    struct CollateralConfig {
        address nftContract;
        uint256 ltv; // Loan-to-value ratio (basis points)
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        bool isActive;
        address priceOracle;
    }

    struct Loan {
        bytes32 loanId;
        address borrower;
        address asset;
        uint256 principal;
        uint256 interest;
        uint256 collateralTokenId;
        address collateralContract;
        uint256 startTime;
        uint256 lastPayment;
        bool isActive;
        uint256 healthFactor;
    }

    // State variables
    mapping(address => LendingPool) public lendingPools;
    mapping(address => mapping(address => UserPosition)) public userPositions;
    mapping(address => CollateralConfig) public collateralConfigs;
    mapping(bytes32 => Loan) public loans;
    mapping(address => bytes32[]) public userLoans;
    mapping(address => uint256) public totalSupplied;
    mapping(address => uint256) public totalBorrowed;
    
    address[] public supportedAssets;
    address[] public supportedCollaterals;
    address public treasury;
    address public liquidationBot;
    uint256 public platformFee; // Basis points
    uint256 public loanCounter;
    
    // Interest rate model parameters
    uint256 public constant OPTIMAL_UTILIZATION = 8000; // 80%
    uint256 public constant BASE_RATE = 200; // 2%
    uint256 public constant SLOPE1 = 400; // 4%
    uint256 public constant SLOPE2 = 6000; // 60%
    
    // Events
    event Supply(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 newBalance
    );
    
    event Withdraw(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 newBalance
    );
    
    event Borrow(
        bytes32 indexed loanId,
        address indexed borrower,
        address indexed asset,
        uint256 amount,
        address collateralContract,
        uint256 collateralTokenId
    );
    
    event Repay(
        bytes32 indexed loanId,
        address indexed borrower,
        uint256 amount,
        uint256 remainingDebt
    );
    
    event Liquidation(
        bytes32 indexed loanId,
        address indexed liquidator,
        address indexed borrower,
        uint256 debtAmount,
        uint256 collateralValue
    );
    
    event PoolCreated(
        address indexed asset,
        uint256 supplyRate,
        uint256 borrowRate
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _treasury,
        address _liquidationBot
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        treasury = _treasury;
        liquidationBot = _liquidationBot;
        platformFee = 1000; // 10%
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Create a new lending pool
     */
    function createLendingPool(
        address asset,
        uint256 initialSupplyRate,
        uint256 initialBorrowRate,
        uint256 supplyCap,
        uint256 borrowCap
    ) external onlyOwner {
        require(lendingPools[asset].asset == address(0), "Pool already exists");
        
        lendingPools[asset] = LendingPool({
            asset: asset,
            totalSupply: 0,
            totalBorrow: 0,
            supplyRate: initialSupplyRate,
            borrowRate: initialBorrowRate,
            utilizationRate: 0,
            reserveFactor: 1000, // 10%
            lastUpdateTime: block.timestamp,
            isActive: true,
            supplyCap: supplyCap,
            borrowCap: borrowCap
        });
        
        supportedAssets.push(asset);
        
        emit PoolCreated(asset, initialSupplyRate, initialBorrowRate);
    }

    /**
     * @dev Add collateral configuration
     */
    function addCollateralConfig(
        address nftContract,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        address priceOracle
    ) external onlyOwner {
        collateralConfigs[nftContract] = CollateralConfig({
            nftContract: nftContract,
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus,
            isActive: true,
            priceOracle: priceOracle
        });
        
        supportedCollaterals.push(nftContract);
    }

    /**
     * @dev Supply assets to lending pool
     */
    function supply(address asset, uint256 amount) external nonReentrant whenNotPaused {
        require(lendingPools[asset].isActive, "Pool not active");
        require(amount > 0, "Amount must be positive");
        
        LendingPool storage pool = lendingPools[asset];
        require(pool.totalSupply + amount <= pool.supplyCap, "Supply cap exceeded");
        
        // Update interest rates
        _updatePool(asset);
        
        // Transfer tokens from user
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update user position
        UserPosition storage position = userPositions[msg.sender][asset];
        position.supplied += amount;
        position.lastInterestUpdate = block.timestamp;
        
        // Update pool state
        pool.totalSupply += amount;
        totalSupplied[asset] += amount;
        
        // Update utilization and rates
        _updateUtilizationAndRates(asset);
        
        emit Supply(msg.sender, asset, amount, position.supplied);
    }

    /**
     * @dev Withdraw supplied assets
     */
    function withdraw(address asset, uint256 amount) external nonReentrant whenNotPaused {
        UserPosition storage position = userPositions[msg.sender][asset];
        require(position.supplied >= amount, "Insufficient balance");
        
        LendingPool storage pool = lendingPools[asset];
        require(pool.totalSupply >= amount, "Insufficient liquidity");
        
        // Update interest rates
        _updatePool(asset);
        
        // Calculate accrued interest
        uint256 accruedInterest = _calculateSupplyInterest(msg.sender, asset);
        uint256 totalWithdraw = amount + accruedInterest;
        
        // Update user position
        position.supplied -= amount;
        position.lastInterestUpdate = block.timestamp;
        
        // Update pool state
        pool.totalSupply -= amount;
        totalSupplied[asset] -= amount;
        
        // Transfer tokens to user
        IERC20(asset).safeTransfer(msg.sender, totalWithdraw);
        
        // Update utilization and rates
        _updateUtilizationAndRates(asset);
        
        emit Withdraw(msg.sender, asset, totalWithdraw, position.supplied);
    }

    /**
     * @dev Borrow against RWA NFT collateral
     */
    function borrow(
        address asset,
        uint256 amount,
        address collateralContract,
        uint256 collateralTokenId
    ) external nonReentrant whenNotPaused returns (bytes32 loanId) {
        require(lendingPools[asset].isActive, "Pool not active");
        require(collateralConfigs[collateralContract].isActive, "Collateral not supported");
        require(IERC721(collateralContract).ownerOf(collateralTokenId) == msg.sender, "Not NFT owner");
        
        LendingPool storage pool = lendingPools[asset];
        require(pool.totalBorrow + amount <= pool.borrowCap, "Borrow cap exceeded");
        require(pool.totalSupply >= amount, "Insufficient liquidity");
        
        // Get collateral value
        uint256 collateralValue = _getCollateralValue(collateralContract, collateralTokenId);
        CollateralConfig memory config = collateralConfigs[collateralContract];
        
        // Check LTV
        uint256 maxBorrow = (collateralValue * config.ltv) / 10000;
        require(amount <= maxBorrow, "Exceeds LTV limit");
        
        // Transfer NFT to contract
        IERC721(collateralContract).transferFrom(msg.sender, address(this), collateralTokenId);
        
        // Create loan
        loanCounter++;
        loanId = keccak256(abi.encodePacked(msg.sender, asset, collateralContract, collateralTokenId, loanCounter));
        
        loans[loanId] = Loan({
            loanId: loanId,
            borrower: msg.sender,
            asset: asset,
            principal: amount,
            interest: 0,
            collateralTokenId: collateralTokenId,
            collateralContract: collateralContract,
            startTime: block.timestamp,
            lastPayment: block.timestamp,
            isActive: true,
            healthFactor: _calculateHealthFactor(collateralValue, amount, config.liquidationThreshold)
        });
        
        userLoans[msg.sender].push(loanId);
        
        // Update pool state
        pool.totalBorrow += amount;
        totalBorrowed[asset] += amount;
        
        // Update user position
        UserPosition storage position = userPositions[msg.sender][asset];
        position.borrowed += amount;
        position.collateralValue += collateralValue;
        position.lastInterestUpdate = block.timestamp;
        
        // Transfer borrowed amount to user
        IERC20(asset).safeTransfer(msg.sender, amount);
        
        // Update utilization and rates
        _updateUtilizationAndRates(asset);
        
        emit Borrow(loanId, msg.sender, asset, amount, collateralContract, collateralTokenId);
        
        return loanId;
    }

    /**
     * @dev Repay loan
     */
    function repay(bytes32 loanId, uint256 amount) external nonReentrant whenNotPaused {
        Loan storage loan = loans[loanId];
        require(loan.isActive, "Loan not active");
        require(loan.borrower == msg.sender, "Not loan owner");
        
        // Calculate total debt including interest
        uint256 totalDebt = _calculateTotalDebt(loanId);
        require(amount <= totalDebt, "Amount exceeds debt");
        
        // Transfer repayment from user
        IERC20(loan.asset).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update loan
        if (amount >= totalDebt) {
            // Full repayment
            loan.isActive = false;
            
            // Return NFT to borrower
            IERC721(loan.collateralContract).transferFrom(
                address(this),
                msg.sender,
                loan.collateralTokenId
            );
            
            // Update pool state
            lendingPools[loan.asset].totalBorrow -= loan.principal;
            totalBorrowed[loan.asset] -= loan.principal;
            
            // Update user position
            UserPosition storage position = userPositions[msg.sender][loan.asset];
            position.borrowed -= loan.principal;
            
            uint256 collateralValue = _getCollateralValue(loan.collateralContract, loan.collateralTokenId);
            position.collateralValue -= collateralValue;
            
            emit Repay(loanId, msg.sender, amount, 0);
        } else {
            // Partial repayment
            loan.interest = totalDebt - amount - loan.principal;
            loan.lastPayment = block.timestamp;
            
            emit Repay(loanId, msg.sender, amount, totalDebt - amount);
        }
        
        // Update utilization and rates
        _updateUtilizationAndRates(loan.asset);
    }

    /**
     * @dev Liquidate undercollateralized loan
     */
    function liquidate(bytes32 loanId) external nonReentrant whenNotPaused {
        require(msg.sender == liquidationBot || msg.sender == owner(), "Unauthorized");
        
        Loan storage loan = loans[loanId];
        require(loan.isActive, "Loan not active");
        require(_canLiquidate(loanId), "Cannot liquidate");
        
        uint256 totalDebt = _calculateTotalDebt(loanId);
        uint256 collateralValue = _getCollateralValue(loan.collateralContract, loan.collateralTokenId);
        
        CollateralConfig memory config = collateralConfigs[loan.collateralContract];
        uint256 liquidationBonus = (collateralValue * config.liquidationBonus) / 10000;
        
        // Mark loan as inactive
        loan.isActive = false;
        
        // Update pool state
        lendingPools[loan.asset].totalBorrow -= loan.principal;
        totalBorrowed[loan.asset] -= loan.principal;
        
        // Transfer NFT to liquidator
        IERC721(loan.collateralContract).transferFrom(
            address(this),
            msg.sender,
            loan.collateralTokenId
        );
        
        emit Liquidation(loanId, msg.sender, loan.borrower, totalDebt, collateralValue);
    }

    /**
     * @dev Update pool interest rates and state
     */
    function _updatePool(address asset) internal {
        LendingPool storage pool = lendingPools[asset];
        
        if (block.timestamp <= pool.lastUpdateTime) {
            return;
        }
        
        uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
        
        if (pool.totalBorrow > 0) {
            uint256 borrowInterest = (pool.totalBorrow * pool.borrowRate * timeElapsed) / (365 days * 10000);
            pool.totalBorrow += borrowInterest;
            
            uint256 supplyInterest = (borrowInterest * (10000 - pool.reserveFactor)) / 10000;
            pool.totalSupply += supplyInterest;
        }
        
        pool.lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Update utilization rate and interest rates
     */
    function _updateUtilizationAndRates(address asset) internal {
        LendingPool storage pool = lendingPools[asset];
        
        if (pool.totalSupply == 0) {
            pool.utilizationRate = 0;
        } else {
            pool.utilizationRate = (pool.totalBorrow * 10000) / pool.totalSupply;
        }
        
        // Calculate new rates based on utilization
        if (pool.utilizationRate <= OPTIMAL_UTILIZATION) {
            pool.borrowRate = BASE_RATE + (pool.utilizationRate * SLOPE1) / OPTIMAL_UTILIZATION;
        } else {
            uint256 excessUtilization = pool.utilizationRate - OPTIMAL_UTILIZATION;
            pool.borrowRate = BASE_RATE + SLOPE1 + (excessUtilization * SLOPE2) / (10000 - OPTIMAL_UTILIZATION);
        }
        
        pool.supplyRate = (pool.borrowRate * pool.utilizationRate * (10000 - pool.reserveFactor)) / (10000 * 10000);
    }

    /**
     * @dev Calculate supply interest for user
     */
    function _calculateSupplyInterest(address user, address asset) internal view returns (uint256) {
        UserPosition memory position = userPositions[user][asset];
        LendingPool memory pool = lendingPools[asset];
        
        uint256 timeElapsed = block.timestamp - position.lastInterestUpdate;
        return (position.supplied * pool.supplyRate * timeElapsed) / (365 days * 10000);
    }

    /**
     * @dev Calculate total debt for loan
     */
    function _calculateTotalDebt(bytes32 loanId) internal view returns (uint256) {
        Loan memory loan = loans[loanId];
        LendingPool memory pool = lendingPools[loan.asset];
        
        uint256 timeElapsed = block.timestamp - loan.lastPayment;
        uint256 interest = (loan.principal * pool.borrowRate * timeElapsed) / (365 days * 10000);
        
        return loan.principal + loan.interest + interest;
    }

    /**
     * @dev Get collateral value from oracle
     */
    function _getCollateralValue(address nftContract, uint256 tokenId) internal view returns (uint256) {
        // This would integrate with actual price oracle
        // For now, return a mock value
        return 100000 * 10**18; // $100,000
    }

    /**
     * @dev Calculate health factor
     */
    function _calculateHealthFactor(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 liquidationThreshold
    ) internal pure returns (uint256) {
        if (debtValue == 0) return type(uint256).max;
        
        return (collateralValue * liquidationThreshold) / (debtValue * 100);
    }

    /**
     * @dev Check if loan can be liquidated
     */
    function _canLiquidate(bytes32 loanId) internal view returns (bool) {
        Loan memory loan = loans[loanId];
        uint256 collateralValue = _getCollateralValue(loan.collateralContract, loan.collateralTokenId);
        uint256 totalDebt = _calculateTotalDebt(loanId);
        
        CollateralConfig memory config = collateralConfigs[loan.collateralContract];
        uint256 healthFactor = _calculateHealthFactor(collateralValue, totalDebt, config.liquidationThreshold);
        
        return healthFactor < 100; // Health factor below 1.0
    }

    /**
     * @dev Get user's loans
     */
    function getUserLoans(address user) external view returns (bytes32[] memory) {
        return userLoans[user];
    }

    /**
     * @dev Get loan details
     */
    function getLoanDetails(bytes32 loanId) external view returns (
        address borrower,
        address asset,
        uint256 principal,
        uint256 totalDebt,
        address collateralContract,
        uint256 collateralTokenId,
        uint256 healthFactor,
        bool isActive
    ) {
        Loan memory loan = loans[loanId];
        uint256 debt = _calculateTotalDebt(loanId);
        uint256 collateralValue = _getCollateralValue(loan.collateralContract, loan.collateralTokenId);
        CollateralConfig memory config = collateralConfigs[loan.collateralContract];
        uint256 hf = _calculateHealthFactor(collateralValue, debt, config.liquidationThreshold);
        
        return (
            loan.borrower,
            loan.asset,
            loan.principal,
            debt,
            loan.collateralContract,
            loan.collateralTokenId,
            hf,
            loan.isActive
        );
    }

    /**
     * @dev Get platform statistics
     */
    function getPlatformStats() external view returns (
        uint256 totalSupplyValue,
        uint256 totalBorrowValue,
        uint256 totalLoans,
        uint256 activeLoans
    ) {
        uint256 activeCount = 0;
        
        // Calculate totals across all assets
        uint256 supplyValue = 0;
        uint256 borrowValue = 0;
        
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            supplyValue += totalSupplied[asset];
            borrowValue += totalBorrowed[asset];
        }
        
        return (supplyValue, borrowValue, loanCounter, activeCount);
    }

    /**
     * @dev Admin functions
     */
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function setLiquidationBot(address _liquidationBot) external onlyOwner {
        liquidationBot = _liquidationBot;
    }

    function setPlatformFee(uint256 _platformFee) external onlyOwner {
        platformFee = _platformFee;
    }

    function pausePool(address asset) external onlyOwner {
        lendingPools[asset].isActive = false;
    }

    function unpausePool(address asset) external onlyOwner {
        lendingPools[asset].isActive = true;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency withdrawal of fees
     */
    function withdrawFees(address asset, address to) external onlyOwner {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransfer(to, balance);
    }
}
