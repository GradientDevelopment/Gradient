// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title GradientVesting
/// @notice A secure vesting contract for depositing and withdrawing GRAY tokens and ETH
/// @dev Uses OpenZeppelin's ReentrancyGuard and Ownable for security
contract GradientVesting is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable grayToken;

    // Track total ETH and tokens deposited
    uint256 public totalEthDeposited;
    uint256 public totalTokensDeposited;

    // Mapping to track user's GRAY token balances
    mapping(address => uint256) public userTokenBalances;

    // Mapping to track user's ETH balances
    mapping(address => uint256) public userEthBalances;

    // Events
    event TokenDeposited(address indexed user, uint256 amount);
    event TokenWithdrawn(address indexed user, uint256 amount);
    event EthDeposited(address indexed user, uint256 amount);
    event EthWithdrawn(address indexed user, uint256 amount);
    event ExcessETHRecovered(address indexed owner, uint256 amount);
    event ExcessTokensRecovered(
        address indexed owner,
        address indexed token,
        uint256 amount
    );
    event ExcessGrayTokensRecovered(address indexed owner, uint256 amount);

    /// @notice Constructor that sets the GRAY token address
    /// @param _grayToken Address of the GRAY token contract
    /// @dev Uses Ownable for simpler ownership
    constructor(address _grayToken) Ownable(msg.sender) {
        require(_grayToken != address(0), "Invalid token address");
        grayToken = IERC20(_grayToken);
    }

    /// @notice Allows users to deposit GRAY tokens into the vesting contract
    /// @param _amount Amount of GRAY tokens to deposit
    /// @dev Uses nonReentrant modifier to prevent reentrancy attacks
    function depositToken(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");

        // Use SafeERC20 for safer token transfer
        grayToken.safeTransferFrom(msg.sender, address(this), _amount);

        userTokenBalances[msg.sender] += _amount;
        totalTokensDeposited += _amount;
        emit TokenDeposited(msg.sender, _amount);
    }

    /// @notice Allows users to withdraw GRAY tokens from the vesting contract
    /// @param _amount Amount of GRAY tokens to withdraw
    /// @dev Uses nonReentrant modifier to prevent reentrancy attacks
    function withdrawToken(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(
            userTokenBalances[msg.sender] >= _amount,
            "Insufficient balance"
        );

        userTokenBalances[msg.sender] -= _amount;
        totalTokensDeposited -= _amount;

        // Use SafeERC20 for safer token transfer
        grayToken.safeTransfer(msg.sender, _amount);
        emit TokenWithdrawn(msg.sender, _amount);
    }

    /// @notice Allows users to deposit ETH into the vesting contract
    /// @dev Uses nonReentrant modifier to prevent reentrancy attacks
    function depositEth() external payable nonReentrant {
        require(msg.value > 0, "Amount must be greater than 0");

        userEthBalances[msg.sender] += msg.value;
        totalEthDeposited += msg.value;
        emit EthDeposited(msg.sender, msg.value);
    }

    /// @notice Allows users to withdraw ETH from the vesting contract
    /// @param _amount Amount of ETH to withdraw
    /// @dev Uses nonReentrant modifier to prevent reentrancy attacks
    function withdrawEth(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Amount must be greater than 0");
        require(userEthBalances[msg.sender] >= _amount, "Insufficient balance");

        userEthBalances[msg.sender] -= _amount;
        totalEthDeposited -= _amount;

        (bool sent, ) = payable(msg.sender).call{value: _amount}("");
        require(sent, "Failed to send ETH");

        emit EthWithdrawn(msg.sender, _amount);
    }

    /// @notice Allows the owner to recover excess ETH not assigned to users
    /// @dev Only callable by owner
    function recoverExcessETH() external onlyOwner {
        uint256 excess = address(this).balance - totalEthDeposited;
        require(excess > 0, "No excess ETH to recover");

        (bool success, ) = owner().call{value: excess}("");
        require(success, "ETH transfer failed");

        emit ExcessETHRecovered(owner(), excess);
    }

    /// @notice Allows the owner to recover excess ERC20 tokens not assigned to users
    /// @param tokenAddress Address of the token to recover
    /// @dev Only callable by owner
    function recoverExcessTokens(address tokenAddress) external onlyOwner {
        require(
            tokenAddress != address(grayToken),
            "Use recoverExcessGrayTokens instead"
        );

        uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
        require(balance > 0, "No tokens to recover");

        // Use SafeERC20 for safer token transfer
        IERC20(tokenAddress).safeTransfer(owner(), balance);
        emit ExcessTokensRecovered(owner(), tokenAddress, balance);
    }

    /// @notice Allows the owner to recover excess GRAY tokens not assigned to users
    /// @dev Only callable by owner
    function recoverExcessGrayTokens() external onlyOwner {
        uint256 excess = grayToken.balanceOf(address(this)) -
            totalTokensDeposited;
        require(excess > 0, "No excess GRAY tokens to recover");

        // Use SafeERC20 for safer token transfer
        grayToken.safeTransfer(owner(), excess);
        emit ExcessGrayTokensRecovered(owner(), excess);
    }

    /// @notice Get vesting contract statistics
    /// @return totalEth Total ETH deposited
    /// @return totalTokens Total tokens deposited
    /// @return contractEthBalance Contract's ETH balance
    /// @return contractTokenBalance Contract's token balance
    function getVestingStats()
        external
        view
        returns (
            uint256 totalEth,
            uint256 totalTokens,
            uint256 contractEthBalance,
            uint256 contractTokenBalance
        )
    {
        return (
            totalEthDeposited,
            totalTokensDeposited,
            address(this).balance,
            grayToken.balanceOf(address(this))
        );
    }

    /// @notice Receive function to accept ETH
    /// @dev Allows the contract to receive ETH
    receive() external payable {}

    /// @notice Fallback function
    /// @dev Reverts direct function calls
    fallback() external payable {
        revert("Direct function calls not allowed");
    }
}
