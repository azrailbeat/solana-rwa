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
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title RWACollateralManager
 * @dev Manages RWA NFTs as collateral for lending protocols
 * Supports Aave, Compound, and OneChain native lending
 */
contract RWACollateralManager is 
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IERC721Receiver
{
    struct CollateralAsset {
        address nftContract;
        uint256 tokenId;
        address owner;
        uint256 collateralValue;
        uint256 loanAmount;
        uint256 liquidationThreshold; // Percentage (e.g., 80 = 80%)
        uint256 ltv; // Loan-to-Value ratio
        bool isActive;
        uint256 lastValuationTime;
        address lendingProtocol;
        bytes32 loanId;
    }

    struct LendingProtocol {
        string name;
        address protocolAddress;
        address adapter;
        bool isActive;
        uint256 maxLTV;
        uint256 liquidationThreshold;
        uint256 interestRate;
    }

    struct RWAValuation {
        uint256 currentValue;
        uint256 lastUpdated;
        address oracle;
        uint256 confidence;
        bool isValid;
    }

    // State variables
    mapping(bytes32 => CollateralAsset) public collateralAssets;
    mapping(address => mapping(uint256 => bytes32)) public nftToCollateralId;
    mapping(address => bytes32[]) public userCollaterals;
    mapping(address => LendingProtocol) public lendingProtocols;
    mapping(address => mapping(uint256 => RWAValuation)) public rwaValuations;
    
    address[] public supportedProtocols;
    address public priceOracle;
    address public liquidationBot;
    uint256 public totalCollateralValue;
    uint256 public totalLoansOutstanding;
    uint256 public liquidationFee; // Basis points (e.g., 500 = 5%)
    uint256 public platformFee; // Basis points
    
    // Events
    event CollateralDeposited(
        bytes32 indexed collateralId,
        address indexed user,
        address indexed nftContract,
        uint256 tokenId,
        uint256 value
    );
    
    event LoanInitiated(
        bytes32 indexed collateralId,
        address indexed borrower,
        address indexed protocol,
        uint256 loanAmount,
        uint256 interestRate
    );
    
    event CollateralLiquidated(
        bytes32 indexed collateralId,
        address indexed liquidator,
        uint256 liquidationPrice,
        uint256 remainingDebt
    );
    
    event ValuationUpdated(
        address indexed nftContract,
        uint256 indexed tokenId,
        uint256 newValue,
        address oracle
    );
    
    event ProtocolAdded(
        address indexed protocol,
        string name,
        uint256 maxLTV
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _priceOracle,
        address _liquidationBot
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        priceOracle = _priceOracle;
        liquidationBot = _liquidationBot;
        liquidationFee = 500; // 5%
        platformFee = 100; // 1%
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Deposit RWA NFT as collateral
     */
    function depositCollateral(
        address nftContract,
        uint256 tokenId,
        address lendingProtocol
    ) external nonReentrant whenNotPaused returns (bytes32 collateralId) {
        require(lendingProtocols[lendingProtocol].isActive, "Protocol not supported");
        require(IERC721(nftContract).ownerOf(tokenId) == msg.sender, "Not NFT owner");
        
        // Transfer NFT to this contract
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);
        
        // Get current valuation
        uint256 collateralValue = getRWAValuation(nftContract, tokenId);
        require(collateralValue > 0, "Invalid valuation");
        
        // Generate unique collateral ID
        collateralId = keccak256(abi.encodePacked(
            nftContract,
            tokenId,
            msg.sender,
            block.timestamp
        ));
        
        // Create collateral asset
        collateralAssets[collateralId] = CollateralAsset({
            nftContract: nftContract,
            tokenId: tokenId,
            owner: msg.sender,
            collateralValue: collateralValue,
            loanAmount: 0,
            liquidationThreshold: lendingProtocols[lendingProtocol].liquidationThreshold,
            ltv: 0,
            isActive: true,
            lastValuationTime: block.timestamp,
            lendingProtocol: lendingProtocol,
            loanId: bytes32(0)
        });
        
        // Update mappings
        nftToCollateralId[nftContract][tokenId] = collateralId;
        userCollaterals[msg.sender].push(collateralId);
        totalCollateralValue += collateralValue;
        
        emit CollateralDeposited(collateralId, msg.sender, nftContract, tokenId, collateralValue);
        
        return collateralId;
    }

    /**
     * @dev Initiate loan against collateral
     */
    function initiateLoan(
        bytes32 collateralId,
        uint256 loanAmount,
        address borrowToken
    ) external nonReentrant whenNotPaused {
        CollateralAsset storage collateral = collateralAssets[collateralId];
        require(collateral.owner == msg.sender, "Not collateral owner");
        require(collateral.isActive, "Collateral not active");
        require(collateral.loanAmount == 0, "Loan already exists");
        
        LendingProtocol memory protocol = lendingProtocols[collateral.lendingProtocol];
        
        // Calculate maximum loan amount
        uint256 maxLoan = (collateral.collateralValue * protocol.maxLTV) / 100;
        require(loanAmount <= maxLoan, "Loan amount exceeds LTV");
        
        // Update collateral
        collateral.loanAmount = loanAmount;
        collateral.ltv = (loanAmount * 100) / collateral.collateralValue;
        
        // Interact with lending protocol
        _executeLoan(collateral.lendingProtocol, collateralId, loanAmount, borrowToken);
        
        totalLoansOutstanding += loanAmount;
        
        emit LoanInitiated(collateralId, msg.sender, collateral.lendingProtocol, loanAmount, protocol.interestRate);
    }

    /**
     * @dev Repay loan and withdraw collateral
     */
    function repayLoan(
        bytes32 collateralId,
        uint256 repayAmount,
        address repayToken
    ) external nonReentrant whenNotPaused {
        CollateralAsset storage collateral = collateralAssets[collateralId];
        require(collateral.owner == msg.sender, "Not collateral owner");
        require(collateral.loanAmount > 0, "No active loan");
        
        // Calculate total debt including interest
        uint256 totalDebt = _calculateTotalDebt(collateralId);
        require(repayAmount >= totalDebt, "Insufficient repayment");
        
        // Transfer repayment from user
        IERC20(repayToken).transferFrom(msg.sender, address(this), repayAmount);
        
        // Repay to lending protocol
        _repayToProtocol(collateral.lendingProtocol, collateral.loanId, repayAmount, repayToken);
        
        // Update state
        totalLoansOutstanding -= collateral.loanAmount;
        collateral.loanAmount = 0;
        collateral.ltv = 0;
        collateral.loanId = bytes32(0);
        
        // Return NFT to owner
        IERC721(collateral.nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            collateral.tokenId
        );
        
        collateral.isActive = false;
    }

    /**
     * @dev Liquidate undercollateralized position
     */
    function liquidateCollateral(
        bytes32 collateralId,
        address liquidator
    ) external nonReentrant whenNotPaused {
        require(msg.sender == liquidationBot || msg.sender == owner(), "Unauthorized liquidator");
        
        CollateralAsset storage collateral = collateralAssets[collateralId];
        require(collateral.isActive, "Collateral not active");
        require(collateral.loanAmount > 0, "No loan to liquidate");
        
        // Check if liquidation is warranted
        require(_isLiquidatable(collateralId), "Position not liquidatable");
        
        uint256 currentValue = getRWAValuation(collateral.nftContract, collateral.tokenId);
        uint256 totalDebt = _calculateTotalDebt(collateralId);
        
        // Calculate liquidation proceeds
        uint256 liquidationFeeAmount = (currentValue * liquidationFee) / 10000;
        uint256 netProceeds = currentValue - liquidationFeeAmount;
        
        // Update state
        totalLoansOutstanding -= collateral.loanAmount;
        totalCollateralValue -= collateral.collateralValue;
        collateral.isActive = false;
        
        // Transfer NFT to liquidator or auction contract
        IERC721(collateral.nftContract).safeTransferFrom(
            address(this),
            liquidator,
            collateral.tokenId
        );
        
        emit CollateralLiquidated(collateralId, liquidator, currentValue, totalDebt);
    }

    /**
     * @dev Update RWA valuation
     */
    function updateRWAValuation(
        address nftContract,
        uint256 tokenId,
        uint256 newValue,
        uint256 confidence
    ) external {
        require(msg.sender == priceOracle || msg.sender == owner(), "Unauthorized");
        
        rwaValuations[nftContract][tokenId] = RWAValuation({
            currentValue: newValue,
            lastUpdated: block.timestamp,
            oracle: msg.sender,
            confidence: confidence,
            isValid: true
        });
        
        emit ValuationUpdated(nftContract, tokenId, newValue, msg.sender);
    }

    /**
     * @dev Add supported lending protocol
     */
    function addLendingProtocol(
        address protocol,
        string memory name,
        address adapter,
        uint256 maxLTV,
        uint256 liquidationThreshold,
        uint256 interestRate
    ) external onlyOwner {
        lendingProtocols[protocol] = LendingProtocol({
            name: name,
            protocolAddress: protocol,
            adapter: adapter,
            isActive: true,
            maxLTV: maxLTV,
            liquidationThreshold: liquidationThreshold,
            interestRate: interestRate
        });
        
        supportedProtocols.push(protocol);
        
        emit ProtocolAdded(protocol, name, maxLTV);
    }

    /**
     * @dev Get RWA valuation
     */
    function getRWAValuation(address nftContract, uint256 tokenId) public view returns (uint256) {
        RWAValuation memory valuation = rwaValuations[nftContract][tokenId];
        
        if (!valuation.isValid || block.timestamp - valuation.lastUpdated > 24 hours) {
            // Fallback to default valuation logic or revert
            return 0;
        }
        
        return valuation.currentValue;
    }

    /**
     * @dev Check if position is liquidatable
     */
    function _isLiquidatable(bytes32 collateralId) internal view returns (bool) {
        CollateralAsset memory collateral = collateralAssets[collateralId];
        
        uint256 currentValue = getRWAValuation(collateral.nftContract, collateral.tokenId);
        uint256 totalDebt = _calculateTotalDebt(collateralId);
        
        uint256 currentLTV = (totalDebt * 100) / currentValue;
        
        return currentLTV >= collateral.liquidationThreshold;
    }

    /**
     * @dev Calculate total debt including interest
     */
    function _calculateTotalDebt(bytes32 collateralId) internal view returns (uint256) {
        CollateralAsset memory collateral = collateralAssets[collateralId];
        LendingProtocol memory protocol = lendingProtocols[collateral.lendingProtocol];
        
        // Simple interest calculation (should integrate with actual protocol)
        uint256 timeElapsed = block.timestamp - collateral.lastValuationTime;
        uint256 interest = (collateral.loanAmount * protocol.interestRate * timeElapsed) / (365 days * 10000);
        
        return collateral.loanAmount + interest;
    }

    /**
     * @dev Execute loan through lending protocol
     */
    function _executeLoan(
        address protocol,
        bytes32 collateralId,
        uint256 loanAmount,
        address borrowToken
    ) internal {
        // This would integrate with actual lending protocol adapters
        // For now, we'll simulate the loan execution
        CollateralAsset storage collateral = collateralAssets[collateralId];
        collateral.loanId = keccak256(abi.encodePacked(collateralId, block.timestamp));
    }

    /**
     * @dev Repay to lending protocol
     */
    function _repayToProtocol(
        address protocol,
        bytes32 loanId,
        uint256 repayAmount,
        address repayToken
    ) internal {
        // This would integrate with actual lending protocol adapters
        // Implementation depends on specific protocol requirements
    }

    /**
     * @dev Get user's collateral positions
     */
    function getUserCollaterals(address user) external view returns (bytes32[] memory) {
        return userCollaterals[user];
    }

    /**
     * @dev Get collateral details
     */
    function getCollateralDetails(bytes32 collateralId) external view returns (
        address nftContract,
        uint256 tokenId,
        address owner,
        uint256 collateralValue,
        uint256 loanAmount,
        uint256 ltv,
        bool isActive
    ) {
        CollateralAsset memory collateral = collateralAssets[collateralId];
        return (
            collateral.nftContract,
            collateral.tokenId,
            collateral.owner,
            collateral.collateralValue,
            collateral.loanAmount,
            collateral.ltv,
            collateral.isActive
        );
    }

    /**
     * @dev Get platform statistics
     */
    function getPlatformStats() external view returns (
        uint256 totalCollateral,
        uint256 totalLoans,
        uint256 protocolCount,
        uint256 activeCollaterals
    ) {
        uint256 activeCount = 0;
        // This would require iterating through collaterals or maintaining a counter
        
        return (
            totalCollateralValue,
            totalLoansOutstanding,
            supportedProtocols.length,
            activeCount
        );
    }

    /**
     * @dev Emergency functions
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setLiquidationBot(address _liquidationBot) external onlyOwner {
        liquidationBot = _liquidationBot;
    }

    function setPriceOracle(address _priceOracle) external onlyOwner {
        priceOracle = _priceOracle;
    }

    function setFees(uint256 _liquidationFee, uint256 _platformFee) external onlyOwner {
        liquidationFee = _liquidationFee;
        platformFee = _platformFee;
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
