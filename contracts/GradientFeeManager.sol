// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGradientRegistry} from "./interfaces/IGradientRegistry.sol";
import {IGradientMarketMakerPoolV3} from "./interfaces/IGradientMarketMakerPoolV3.sol";
import {IGradientFeeManager} from "./interfaces/IGradientFeeManager.sol";

/**
 * @title GradientFeeManager
 * @author Gradient Protocol
 * @notice Manages fee distribution, partner fee collection, and platform fee withdrawal
 * @dev This contract handles all fee-related logic separated from the main orderbook
 */
contract GradientFeeManager is IGradientFeeManager, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Registry contract for accessing other protocol contracts
    IGradientRegistry public gradientRegistry;

    /// @notice Total ETH fees collected
    uint256 public totalEthFeesCollected;

    /// @notice Total token fees collected per token
    mapping(address => uint256) public totalTokenFeesCollected;

    /// @notice Partner ETH fees collected per partner token
    mapping(address => uint256) public partnerEthFeesCollected;

    /// @notice Partner token fees collected per partner token
    mapping(address => uint256) public partnerTokenFeesCollected;

    /// @notice Partner ETH fees claimed per partner token
    mapping(address => uint256) public partnerEthFeesClaimed;

    /// @notice Partner token fees claimed per partner token
    mapping(address => uint256) public partnerTokenFeesClaimed;

    /// @notice Platform ETH fees claimed
    uint256 public platformEthFeesClaimed;

    /// @notice Platform token fees claimed per token
    mapping(address => uint256) public platformTokenFeesClaimed;

    // Modifiers
    modifier onlyOrderbook() {
        require(
            msg.sender == gradientRegistry.orderbook(),
            "Caller is not the orderbook"
        );
        _;
    }

    constructor(IGradientRegistry _gradientRegistry) Ownable(msg.sender) {
        gradientRegistry = _gradientRegistry;
    }

    receive() external payable {}

    // ========================== Fee Distribution Functions ==========================

    /// @notice Distributes market maker token fees according to partner split logic
    /// @param totalFee Total fee amount to distribute
    /// @param token Token address for partner token check
    /// @param marketMakerPool Market maker pool address for distribution
    function distributeMarketMakerTokenFees(
        uint256 totalFee,
        address token,
        address marketMakerPool
    ) external onlyOrderbook {
        require(totalFee > 0, "Fee amount must be greater than 0");
        require(token != address(0), "Invalid token address");
        require(marketMakerPool != address(0), "Invalid market maker pool");

        // 50% to market makers (proportional distribution)
        uint256 marketMakerFee = totalFee / 2;

        // Distribute to market maker pool
        if (marketMakerFee > 0) {
            IERC20(token).approve(marketMakerPool, marketMakerFee);
            IGradientMarketMakerPoolV3(marketMakerPool).distributeTokenFee(
                marketMakerFee
            );
            emit FeeDistributedToPool(
                marketMakerPool,
                token,
                marketMakerFee,
                totalFee
            );
        }

        // 50% to teams - accumulate in totalTokenFeesCollected for later distribution
        uint256 teamFee = totalFee / 2;

        if (gradientRegistry.checkIsPartnerToken(token)) {
            // Split 50% between GRAY team and partner team (25% each)
            uint256 grayTeamFee = teamFee / 2;
            uint256 partnerTeamFee = teamFee / 2;

            // Accumulate fees for later distribution
            totalTokenFeesCollected[token] += grayTeamFee;
            partnerTokenFeesCollected[token] += partnerTeamFee;

            emit FeeDistributedToTeams(
                token,
                grayTeamFee,
                partnerTeamFee,
                teamFee
            );
        } else {
            // All 50% to GRAY team - accumulate for later distribution
            totalTokenFeesCollected[token] += teamFee;

            emit FeeDistributedToTeams(token, teamFee, 0, teamFee);
        }
    }

    /// @notice Distributes market maker ETH fees according to partner split logic
    /// @param totalFee Total ETH fee amount to distribute
    /// @param token Token address for partner token check
    /// @param marketMakerPool Market maker pool address for distribution
    function distributeMarketMakerEthFees(
        uint256 totalFee,
        address token,
        address marketMakerPool
    ) external payable onlyOrderbook {
        require(totalFee > 0, "Fee amount must be greater than 0");
        require(token != address(0), "Invalid token address");
        require(marketMakerPool != address(0), "Invalid market maker pool");

        // 50% to market makers (proportional distribution)
        uint256 marketMakerFee = totalFee / 2;

        // Distribute to market maker pool
        if (marketMakerFee > 0) {
            IGradientMarketMakerPoolV3(marketMakerPool).distributePoolFee{
                value: marketMakerFee
            }();
            emit FeeDistributedToPool(
                marketMakerPool,
                token,
                marketMakerFee,
                totalFee
            );
        }

        // 50% to teams - accumulate in totalEthFeesCollected for later distribution
        uint256 teamFee = totalFee / 2;

        if (gradientRegistry.checkIsPartnerToken(token)) {
            // Split 50% between GRAY team and partner team (25% each)
            uint256 grayTeamFee = teamFee / 2;
            uint256 partnerTeamFee = teamFee / 2;

            // Accumulate fees for later distribution
            totalEthFeesCollected += grayTeamFee;
            partnerEthFeesCollected[token] += partnerTeamFee;

            emit FeeDistributedToTeams(
                token,
                grayTeamFee,
                partnerTeamFee,
                teamFee
            );
        } else {
            // All 50% to GRAY team - accumulate for later distribution
            totalEthFeesCollected += teamFee;

            emit FeeDistributedToTeams(token, teamFee, 0, teamFee);
        }
    }

    // ========================== Fee Collection Functions ==========================

    /// @notice Collects ETH fees and updates totals
    /// @param amount Amount in ETH to collect
    function collectEthFee(
        uint256 amount,
        address /* token */
    ) external payable onlyOrderbook {
        totalEthFeesCollected += amount;
    }

    /// @notice Collects token fees and updates totals
    /// @param amount Amount in tokens to collect
    /// @param token Token address
    function collectTokenFee(
        uint256 amount,
        address token
    ) external onlyOrderbook {
        totalTokenFeesCollected[token] += amount;
    }

    // ========================== Fee Withdrawal Functions ==========================

    /// @notice Withdraws collected ETH fees to the specified address
    /// @param recipient Address to receive the ETH fees
    function withdrawEthFees(address payable recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        uint256 claimableAmount = totalEthFeesCollected -
            platformEthFeesClaimed;
        require(claimableAmount > 0, "No ETH fees to withdraw");
        require(
            address(this).balance >= claimableAmount,
            "Insufficient contract balance"
        );

        platformEthFeesClaimed += claimableAmount;
        (bool success, ) = recipient.call{value: claimableAmount}("");
        require(success, "ETH fee withdrawal failed");

        emit EthFeesWithdrawn(recipient, claimableAmount);
    }

    /// @notice Withdraws collected token fees to the specified address
    /// @param token Address of the token to withdraw fees for
    /// @param recipient Address to receive the token fees
    function withdrawTokenFees(
        address token,
        address recipient
    ) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(recipient != address(0), "Invalid recipient");
        uint256 claimableAmount = totalTokenFeesCollected[token] -
            platformTokenFeesClaimed[token];
        require(claimableAmount > 0, "No token fees to withdraw");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= claimableAmount, "Insufficient token balance");

        platformTokenFeesClaimed[token] += claimableAmount;
        IERC20(token).safeTransfer(recipient, claimableAmount);

        emit TokenFeesWithdrawn(token, recipient, claimableAmount);
    }

    /// @notice Claim partner ETH fees for a specific token
    /// @param token Address of the partner token to claim fees for
    function claimPartnerEthFees(address token) external {
        require(token != address(0), "Invalid token address");
        require(
            gradientRegistry.checkIsPartnerToken(token),
            "Token is not a partner token"
        );

        address partnerWallet = gradientRegistry.getPartnerWallet(token);
        require(
            msg.sender == partnerWallet,
            "Only partner wallet can claim fees"
        );

        uint256 claimableAmount = partnerEthFeesCollected[token] -
            partnerEthFeesClaimed[token];
        require(claimableAmount > 0, "No partner ETH fees to claim");
        require(
            address(this).balance >= claimableAmount,
            "Insufficient ETH balance"
        );

        partnerEthFeesClaimed[token] += claimableAmount;
        (bool success, ) = payable(msg.sender).call{value: claimableAmount}("");
        require(success, "ETH fee transfer failed");

        emit PartnerEthFeesClaimed(token, msg.sender, claimableAmount);
    }

    /// @notice Claim partner token fees for a specific token
    /// @param token Address of the partner token to claim fees for
    function claimPartnerTokenFees(address token) external {
        require(token != address(0), "Invalid token address");
        require(
            gradientRegistry.checkIsPartnerToken(token),
            "Token is not a partner token"
        );

        address partnerWallet = gradientRegistry.getPartnerWallet(token);
        require(
            msg.sender == partnerWallet,
            "Only partner wallet can claim fees"
        );

        uint256 claimableAmount = partnerTokenFeesCollected[token] -
            partnerTokenFeesClaimed[token];
        require(claimableAmount > 0, "No partner token fees to claim");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= claimableAmount, "Insufficient token balance");

        partnerTokenFeesClaimed[token] += claimableAmount;
        IERC20(token).safeTransfer(msg.sender, claimableAmount);

        emit PartnerTokenFeesClaimed(token, msg.sender, claimableAmount);
    }

    // ========================== Admin Functions ==========================

    /**
     * @notice Sets the gradient registry address
     * @param _gradientRegistry New gradient registry address
     * @dev Only callable by the contract owner
     */
    function setGradientRegistry(
        IGradientRegistry _gradientRegistry
    ) external onlyOwner {
        require(
            address(_gradientRegistry) != address(0),
            "Invalid gradient registry"
        );
        gradientRegistry = _gradientRegistry;
    }

    // ========================== Emergency Functions ==========================

    /**
     * @notice Emergency function to withdraw ETH from the contract
     * @param recipient Address to receive the ETH
     * @param amount Amount of ETH to withdraw (0 = withdraw all)
     * @dev Only callable by contract owner in emergency situations
     */
    function emergencyWithdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(address(this).balance > 0, "No ETH to withdraw");

        uint256 withdrawAmount = amount == 0 ? address(this).balance : amount;
        require(
            withdrawAmount <= address(this).balance,
            "Insufficient ETH balance"
        );

        (bool success, ) = recipient.call{value: withdrawAmount}("");
        require(success, "ETH withdrawal failed");

        emit EmergencyWithdrawETH(recipient, withdrawAmount);
    }

    /**
     * @notice Emergency function to withdraw ERC20 tokens from the contract
     * @param token Address of the token to withdraw
     * @param recipient Address to receive the tokens
     * @param amount Amount of tokens to withdraw (0 = withdraw all)
     * @dev Only callable by contract owner in emergency situations
     */
    function emergencyWithdrawToken(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(recipient != address(0), "Invalid recipient");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");

        uint256 withdrawAmount = amount == 0 ? balance : amount;
        require(withdrawAmount <= balance, "Insufficient token balance");

        IERC20(token).safeTransfer(recipient, withdrawAmount);

        emit EmergencyWithdrawToken(token, recipient, withdrawAmount);
    }

    /**
     * @notice Emergency function to withdraw multiple tokens at once
     * @param tokens Array of token addresses to withdraw
     * @param recipient Address to receive all tokens
     * @dev Only callable by contract owner in emergency situations
     * @dev More gas efficient than calling emergencyWithdrawToken multiple times
     */
    function emergencyWithdrawMultipleTokens(
        address[] calldata tokens,
        address recipient
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(tokens.length > 0, "No tokens specified");
        require(tokens.length <= 20, "Too many tokens to withdraw at once");

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            require(token != address(0), "Invalid token address");

            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(recipient, balance);
                emit EmergencyWithdrawToken(token, recipient, balance);
            }
        }
    }

    // Events for emergency withdrawals
    event EmergencyWithdrawETH(address indexed recipient, uint256 amount);
    event EmergencyWithdrawToken(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
}
