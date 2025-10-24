// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title aYieldToken
 * @dev Yield-bearing token representing shares in RWA yield vaults
 * Similar to Aave's aTokens, automatically accrues yield over time
 */
contract aYieldToken is ERC20, ERC20Permit, Ownable, Pausable {
    
    // The underlying RWA token
    address public immutable underlyingAsset;
    
    // The vault that manages this aYield token
    address public vault;
    
    // Yield tracking
    mapping(address => uint256) private _lastUpdateTime;
    mapping(address => uint256) private _accruedYield;
    
    uint256 public yieldRate; // Annual yield rate in basis points
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    // Events
    event YieldAccrued(address indexed user, uint256 amount, uint256 timestamp);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event YieldRateUpdated(uint256 oldRate, uint256 newRate);
    
    modifier onlyVault() {
        require(msg.sender == vault, "Only vault can call");
        _;
    }
    
    constructor(
        string memory name,
        string memory symbol,
        address _underlyingAsset,
        address _vault,
        uint256 _yieldRate
    ) ERC20(name, symbol) ERC20Permit(name) {
        require(_underlyingAsset != address(0), "Invalid underlying asset");
        require(_vault != address(0), "Invalid vault");
        require(_yieldRate <= BASIS_POINTS, "Yield rate too high");
        
        underlyingAsset = _underlyingAsset;
        vault = _vault;
        yieldRate = _yieldRate;
    }
    
    /**
     * @dev Mint aYield tokens (only vault can call)
     */
    function mint(address to, uint256 amount) external onlyVault whenNotPaused {
        _updateYield(to);
        _mint(to, amount);
        _lastUpdateTime[to] = block.timestamp;
    }
    
    /**
     * @dev Burn aYield tokens (only vault can call)
     */
    function burn(address from, uint256 amount) external onlyVault {
        _updateYield(from);
        _burn(from, amount);
        _lastUpdateTime[from] = block.timestamp;
    }
    
    /**
     * @dev Get accrued yield for user
     */
    function getAccruedYield(address user) external view returns (uint256) {
        return _calculateAccruedYield(user);
    }
    
    /**
     * @dev Get balance including accrued yield
     */
    function balanceOfWithYield(address account) external view returns (uint256) {
        return balanceOf(account) + _calculateAccruedYield(account);
    }
    
    /**
     * @dev Update yield for user
     */
    function updateYield(address user) external {
        _updateYield(user);
    }
    
    /**
     * @dev Calculate accrued yield for user
     */
    function _calculateAccruedYield(address user) internal view returns (uint256) {
        uint256 balance = balanceOf(user);
        if (balance == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - _lastUpdateTime[user];
        uint256 annualYield = balance * yieldRate / BASIS_POINTS;
        uint256 accruedYield = annualYield * timeElapsed / SECONDS_PER_YEAR;
        
        return _accruedYield[user] + accruedYield;
    }
    
    /**
     * @dev Update accrued yield for user
     */
    function _updateYield(address user) internal {
        if (_lastUpdateTime[user] == 0) {
            _lastUpdateTime[user] = block.timestamp;
            return;
        }
        
        uint256 newYield = _calculateAccruedYield(user);
        _accruedYield[user] = newYield;
        _lastUpdateTime[user] = block.timestamp;
        
        if (newYield > 0) {
            emit YieldAccrued(user, newYield, block.timestamp);
        }
    }
    
    /**
     * @dev Override transfer to update yield
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        if (from != address(0)) {
            _updateYield(from);
        }
        if (to != address(0)) {
            _updateYield(to);
        }
        super._beforeTokenTransfer(from, to, amount);
    }
    
    /**
     * @dev Admin functions
     */
    function setVault(address _vault) external onlyOwner {
        require(_vault != address(0), "Invalid vault");
        address oldVault = vault;
        vault = _vault;
        emit VaultUpdated(oldVault, _vault);
    }
    
    function setYieldRate(uint256 _yieldRate) external onlyOwner {
        require(_yieldRate <= BASIS_POINTS, "Yield rate too high");
        uint256 oldRate = yieldRate;
        yieldRate = _yieldRate;
        emit YieldRateUpdated(oldRate, _yieldRate);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
}
