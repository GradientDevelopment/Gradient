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
error InvalidRecipient();
error NoETHToWithdraw();
error InsufficientETHBalance();
error ETHWithdrawalFailed();
error NoTokensToWithdraw();
error InsufficientTokenBalance();

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
        if (
            address(_eventAggregator) != address(0) &&
            address(_eventAggregator).code.length == 0
        ) {
            revert InvalidEventAggregator();
        }
        eventAggregator = _eventAggregator;
    }

    function setEventAggregator(
        IEventAggregator _eventAggregator
    ) external onlyOwner {
        if (
            address(_eventAggregator) == address(0) ||
            address(_eventAggregator).code.length == 0
        ) {
            revert InvalidEventAggregator();
        }
        address oldEventAggregator = address(eventAggregator);
        eventAggregator = _eventAggregator;
        emit EventAggregatorUpdated(
            oldEventAggregator,
            address(_eventAggregator)
        );
    }

    function _calculateSalt(address token) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token));
    }

    function _getPoolBytecode(
        address token
    ) internal view returns (bytes memory) {
        return
            abi.encodePacked(
                type(GradientMarketMakerPoolV3).creationCode,
                abi.encode(IERC20(token), address(this))
            );
    }

    function predictPoolAddress(address token) external view returns (address) {
        bytes32 salt = _calculateSalt(token);
        bytes memory bytecode = _getPoolBytecode(token);
        return Create2.computeAddress(salt, keccak256(bytecode));
    }

    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    function createPool(address token) external returns (address) {
        if (token == address(0) || token.code.length == 0)
            revert InvalidTokenAddress();
        if (getPool[token] != address(0)) revert PoolAlreadyExists();
        if (gradientRegistry.blockedTokens(token)) revert TokenBlocked();

        bytes32 salt = _calculateSalt(token);
        bytes memory bytecode = _getPoolBytecode(token);
        address pool = Create2.deploy(0, salt, bytecode);

        getPool[token] = pool;
        getToken[pool] = token;
        allPools.push(pool);

        try eventAggregator.emitPoolCreated(token, pool) {} catch {}

        return pool;
    }

    function createPoolWithLiquidity(
        address token,
        uint256 initialEthAmount,
        uint256 initialTokenAmount,
        uint256 minPrice,
        uint256 maxPrice
    ) external payable returns (address) {
        if (token == address(0) || token.code.length == 0)
            revert InvalidTokenAddress();
        if (getPool[token] != address(0)) revert PoolAlreadyExists();
        if (gradientRegistry.blockedTokens(token)) revert TokenBlocked();
        if (msg.value != initialEthAmount) revert EthAmountMismatch();

        bytes32 salt = _calculateSalt(token);
        bytes memory bytecode = _getPoolBytecode(token);
        address pool = Create2.deploy(0, salt, bytecode);

        getPool[token] = pool;
        getToken[pool] = token;
        allPools.push(pool);

        if (initialEthAmount > 0) {
            IGradientMarketMakerPoolV3(pool).addETHLiquidityForUser{
                value: initialEthAmount
            }(msg.sender, minPrice, maxPrice);
        }

        if (initialTokenAmount > 0) {
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                initialTokenAmount
            );
            IERC20(token).forceApprove(pool, initialTokenAmount);
            IGradientMarketMakerPoolV3(pool).addTokenLiquidityForUser(
                msg.sender,
                initialTokenAmount,
                minPrice,
                maxPrice
            );
            IERC20(token).forceApprove(pool, 0);
        }

        try eventAggregator.emitPoolCreated(token, pool) {} catch {}
        return pool;
    }

    function poolExists(address token) external view returns (bool) {
        return getPool[token] != address(0);
    }

    function getAllPools() external view returns (address[] memory) {
        return allPools;
    }

    function isValidPool(address poolAddress) external view returns (bool) {
        return getToken[poolAddress] != address(0);
    }

    function getRegistry() external view returns (address) {
        return address(gradientRegistry);
    }

    function getEventAggregator() external view returns (address) {
        return address(eventAggregator);
    }

    function emergencyWithdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();
        if (address(this).balance == 0) revert NoETHToWithdraw();
        uint256 withdrawAmount = amount == 0 ? address(this).balance : amount;
        if (withdrawAmount > address(this).balance)
            revert InsufficientETHBalance();
        (bool success, ) = recipient.call{value: withdrawAmount}("");
        if (!success) revert ETHWithdrawalFailed();
        emit EmergencyWithdrawETH(recipient, withdrawAmount);
    }

    function emergencyWithdrawToken(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0)) revert InvalidTokenAddress();
        if (recipient == address(0)) revert InvalidRecipient();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NoTokensToWithdraw();
        uint256 withdrawAmount = amount == 0 ? balance : amount;
        if (withdrawAmount > balance) revert InsufficientTokenBalance();
        IERC20(token).safeTransfer(recipient, withdrawAmount);
        emit EmergencyWithdrawToken(token, recipient, withdrawAmount);
    }

    event EmergencyWithdrawETH(address indexed recipient, uint256 amount);
    event EmergencyWithdrawToken(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
}
