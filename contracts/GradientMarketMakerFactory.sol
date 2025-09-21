// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IGradientRegistry} from "./interfaces/IGradientRegistry.sol";
import {GradientMarketMakerPoolV3} from "./GradientMarketMakerPoolV3.sol";
import {IEventAggregator} from "./interfaces/IEventAggregator.sol";
import {IGradientMarketMakerPoolV3} from "./interfaces/IGradientMarketMakerPoolV3.sol";

// Custom errors to save gas and reduce contract size
error InvalidRegistry();
error InvalidEventAggregator();
error InvalidTokenAddress();
error PoolAlreadyExists();
error TokenBlocked();
error EthAmountMismatch();
error TokenAmountZero();

/**
 * @title GradientMarketMakerFactory
 * @notice Factory contract for deploying individual token market maker pools
 * @dev Similar to Uniswap V2 Factory pattern - one pool per token
 */
contract GradientMarketMakerFactory is Ownable {
    using SafeERC20 for IERC20;
    IGradientRegistry public immutable gradientRegistry;
    IEventAggregator public eventAggregator;

    // Mapping from token address to pool address
    mapping(address => address) public getPool;

    // Reverse mapping from pool address to token address
    mapping(address => address) public getToken;

    // Array of all pools
    address[] public allPools;

    // Events
    event PoolCreated(
        address indexed token,
        address indexed pool,
        uint256 poolIndex
    );
    event EventAggregatorUpdated(
        address indexed oldEventAggregator,
        address indexed newEventAggregator
    );

    constructor(
        IGradientRegistry _gradientRegistry,
        IEventAggregator _eventAggregator
    ) Ownable(msg.sender) {
        if (address(_gradientRegistry) == address(0)) revert InvalidRegistry();
        gradientRegistry = _gradientRegistry;
        eventAggregator = _eventAggregator;
    }

    /**
     * @notice Set the EventAggregator address
     * @param _eventAggregator New EventAggregator address
     */
    function setEventAggregator(
        IEventAggregator _eventAggregator
    ) external onlyOwner {
        if (address(_eventAggregator) == address(0))
            revert InvalidEventAggregator();
        address oldEventAggregator = address(eventAggregator);
        eventAggregator = _eventAggregator;
        emit EventAggregatorUpdated(
            oldEventAggregator,
            address(_eventAggregator)
        );
    }

    /**
     * @notice Calculate the salt for CREATE2 deployment
     * @param token Address of the token
     * @return salt The calculated salt
     */
    function _calculateSalt(
        address token
    ) internal pure returns (bytes32 salt) {
        return keccak256(abi.encodePacked(token));
    }

    /**
     * @notice Get the bytecode for GradientMarketMakerPool with constructor arguments
     * @param token Address of the token
     * @return bytecode The complete bytecode for deployment
     */
    function _getPoolBytecode(
        address token
    ) internal view returns (bytes memory bytecode) {
        bytecode = abi.encodePacked(
            type(GradientMarketMakerPoolV3).creationCode,
            abi.encode(IERC20(token), owner())
        );
    }

    /**
     * @notice Predict the address where a pool will be deployed for a given token
     * @param token Address of the token
     * @return predictedAddress The predicted pool address
     */
    function predictPoolAddress(
        address token
    ) external view returns (address predictedAddress) {
        bytes32 salt = _calculateSalt(token);
        bytes memory bytecode = _getPoolBytecode(token);
        predictedAddress = Create2.computeAddress(salt, keccak256(bytecode));
    }

    /**
     * @notice Get the number of pools created
     * @return Number of pools
     */
    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    /**
     * @notice Create a new market maker pool for a token using CREATE2
     * @param token Address of the token
     * @return pool Address of the created pool
     */
    function createPool(address token) external returns (address pool) {
        if (token == address(0)) revert InvalidTokenAddress();
        if (getPool[token] != address(0)) revert PoolAlreadyExists();
        if (gradientRegistry.blockedTokens(token)) revert TokenBlocked();

        // Calculate salt and bytecode for CREATE2
        bytes32 salt = _calculateSalt(token);
        bytes memory bytecode = _getPoolBytecode(token);

        // Deploy pool using CREATE2
        pool = Create2.deploy(0, salt, bytecode);

        // Store pool address
        getPool[token] = pool;
        getToken[pool] = token;
        allPools.push(pool);

        emit PoolCreated(token, pool, allPools.length - 1);
        eventAggregator.emitPoolCreated(token, pool);
    }

    /**
     * @notice Create a new market maker pool for a token with initial liquidity
     * @param token Address of the token
     * @param initialEthAmount Amount of ETH to add as initial liquidity
     * @param initialTokenAmount Amount of tokens to add as initial liquidity
     * @param minPrice Minimum price for liquidity range
     * @param maxPrice Maximum price for liquidity range
     * @return pool Address of the created pool
     */
    function createPoolWithLiquidity(
        address token,
        uint256 initialEthAmount,
        uint256 initialTokenAmount,
        uint256 minPrice,
        uint256 maxPrice
    ) external payable returns (address pool) {
        if (token == address(0)) revert InvalidTokenAddress();
        if (getPool[token] != address(0)) revert PoolAlreadyExists();
        if (gradientRegistry.blockedTokens(token)) revert TokenBlocked();
        if (msg.value != initialEthAmount) revert EthAmountMismatch();

        // Create the pool using CREATE2
        bytes32 salt = _calculateSalt(token);
        bytes memory bytecode = _getPoolBytecode(token);
        pool = Create2.deploy(0, salt, bytecode);

        // Store pool address
        getPool[token] = pool;
        getToken[pool] = token;
        allPools.push(pool);

        // Emit pool created event
        emit PoolCreated(token, pool, allPools.length - 1);

        // Add initial liquidity for the specified user
        if (initialEthAmount > 0) {
            IGradientMarketMakerPoolV3(pool).addETHLiquidityForUser{
                value: initialEthAmount
            }(msg.sender, minPrice, maxPrice);
        }

        if (initialTokenAmount > 0) {
            // Transfer tokens from caller to factory first
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                initialTokenAmount
            );
            // Approve pool to spend tokens
            IERC20(token).approve(pool, initialTokenAmount);
            // Add token liquidity for the specified user
            IGradientMarketMakerPoolV3(pool).addTokenLiquidityForUser(
                msg.sender,
                initialTokenAmount,
                minPrice,
                maxPrice
            );
        }

        // Emit event to EventAggregator
        eventAggregator.emitPoolCreated(token, pool);
    }

    /**
     * @notice Check if a pool exists for a token
     * @param token Address of the token
     * @return exists True if pool exists
     */
    function poolExists(address token) external view returns (bool exists) {
        return getPool[token] != address(0);
    }

    /**
     * @notice Get all deployed pools
     * @return allPoolAddresses Array of all pool addresses
     */
    function getAllPools()
        external
        view
        returns (address[] memory allPoolAddresses)
    {
        return allPools;
    }

    /**
     * @notice Check if a given address is a valid pool
     * @param poolAddress Address to check
     * @return isValid True if the address is a valid pool
     */
    function isValidPool(
        address poolAddress
    ) external view returns (bool isValid) {
        return getToken[poolAddress] != address(0);
    }

    /**
     * @notice Get the registry address
     * @return registryAddress Address of the GradientRegistry
     */
    function getRegistry() external view returns (address) {
        return address(gradientRegistry);
    }

    /**
     * @notice Get the event aggregator address
     * @return eventAggregatorAddress Address of the EventAggregator
     */
    function getEventAggregator() external view returns (address) {
        return address(eventAggregator);
    }

    // =============================== EMERGENCY FUNCTIONS ===============================

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
