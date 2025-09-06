// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGradientMarketMakerFactory} from "./interfaces/IGradientMarketMakerFactory.sol";

/**
 * @title EventAggregator
 * @notice Centralized event emission for all Gradient pools
 * @dev Reduces RPC calls by aggregating events from multiple pools into one contract
 */
contract EventAggregator {
    // Factory address to verify pool calls
    address public immutable factory;

    // Event types
    uint8 public constant ETH_ADD = 0;
    uint8 public constant ETH_REMOVE = 1;
    uint8 public constant TOKEN_ADD = 2;
    uint8 public constant TOKEN_REMOVE = 3;
    uint8 public constant ETH_REWARDS_CLAIMED = 4;
    uint8 public constant TOKEN_REWARDS_CLAIMED = 5;
    uint8 public constant TRADE_EXECUTED = 6;

    // Main liquidity event - emitted for all pool operations
    event LiquidityEvent(
        address indexed pool,
        address indexed user,
        address indexed token,
        uint8 eventType,
        uint256 amount,
        uint256 timestamp
    );

    // Pool creation event
    event PoolCreated(
        address indexed token,
        address indexed pool,
        uint256 timestamp
    );

    // Trade execution event
    event TradeExecuted(
        address indexed pool,
        address indexed user,
        uint8 tradeType, // 0=BUY, 1=SELL
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 timestamp
    );

    // Merkle root update event
    event MerkleRootUpdated(
        address indexed pool,
        uint256 indexed version,
        bytes32 merkleRoot,
        uint256 timestamp
    );

    // Constructor
    constructor(address _factory) {
        require(_factory != address(0), "Invalid factory address");
        factory = _factory;
    }

    // Modifiers
    modifier onlyPool() {
        require(
            IGradientMarketMakerFactory(factory).isValidPool(msg.sender),
            "Not a valid pool"
        );
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory can call");
        _;
    }

    // =============================== LIQUIDITY EVENTS ===============================

    /**
     * @notice Emit liquidity event (called by pools)
     * @param user User address
     * @param token Token address
     * @param eventType Type of liquidity event
     * @param amount Amount involved
     */
    function emitLiquidityEvent(
        address user,
        address token,
        uint8 eventType,
        uint256 amount
    ) external onlyPool {
        require(eventType <= TOKEN_REWARDS_CLAIMED, "Invalid event type");
        require(user != address(0), "Invalid user address");
        require(token != address(0), "Invalid token address");

        emit LiquidityEvent(
            msg.sender, // pool address
            user,
            token,
            eventType,
            amount,
            block.timestamp
        );
    }

    /**
     * @notice Emit ETH rewards claimed event
     * @param user User address
     * @param token Token address
     * @param amount Amount of ETH rewards claimed
     */
    function emitETHRewardsClaimed(
        address user,
        address token,
        uint256 amount
    ) external onlyPool {
        require(user != address(0), "Invalid user address");
        require(token != address(0), "Invalid token address");

        emit LiquidityEvent(
            msg.sender, // pool address
            user,
            token,
            ETH_REWARDS_CLAIMED,
            amount,
            block.timestamp
        );
    }

    /**
     * @notice Emit token provider rewards claimed event
     * @param user User address
     * @param token Token address
     * @param amount Amount of token provider rewards claimed
     */
    function emitTokenRewardsClaimed(
        address user,
        address token,
        uint256 amount
    ) external onlyPool {
        require(user != address(0), "Invalid user address");
        require(token != address(0), "Invalid token address");

        emit LiquidityEvent(
            msg.sender, // pool address
            user,
            token,
            TOKEN_REWARDS_CLAIMED,
            amount,
            block.timestamp
        );
    }

    // =============================== TRADE EVENTS ===============================

    /**
     * @notice Emit trade execution event
     * @param user User address (orderbook)
     * @param tradeType Type of trade (0=BUY, 1=SELL)
     * @param ethAmount ETH amount involved
     * @param tokenAmount Token amount involved
     */
    function emitTradeExecuted(
        address user,
        uint8 tradeType,
        uint256 ethAmount,
        uint256 tokenAmount
    ) external onlyPool {
        require(tradeType <= 1, "Invalid trade type");
        require(user != address(0), "Invalid user address");

        emit TradeExecuted(
            msg.sender, // pool address
            user,
            tradeType,
            ethAmount,
            tokenAmount,
            block.timestamp
        );
    }

    // =============================== MERKLE ROOT EVENTS ===============================

    /**
     * @notice Emit merkle root update event
     * @param version New version number
     * @param merkleRoot New merkle root
     */
    function emitMerkleRootUpdated(
        uint256 version,
        bytes32 merkleRoot
    ) external onlyPool {
        require(merkleRoot != bytes32(0), "Invalid merkle root");

        emit MerkleRootUpdated(
            msg.sender, // pool address
            version,
            merkleRoot,
            block.timestamp
        );
    }

    // =============================== POOL CREATION EVENTS ===============================

    /**
     * @notice Emit pool creation event (called by factory)
     * @param token Token address
     * @param pool Pool address
     */
    function emitPoolCreated(address token, address pool) external onlyFactory {
        require(token != address(0), "Invalid token address");
        require(pool != address(0), "Invalid pool address");

        emit PoolCreated(token, pool, block.timestamp);
    }

    // =============================== VIEW FUNCTIONS ===============================

    /**
     * @notice Get event type name for human readability
     * @param eventType Event type number
     * @return name Human readable event type name
     */
    function getEventTypeName(
        uint8 eventType
    ) external pure returns (string memory name) {
        if (eventType == ETH_ADD) return "ETH_ADD";
        if (eventType == ETH_REMOVE) return "ETH_REMOVE";
        if (eventType == TOKEN_ADD) return "TOKEN_ADD";
        if (eventType == TOKEN_REMOVE) return "TOKEN_REMOVE";
        if (eventType == ETH_REWARDS_CLAIMED) return "ETH_REWARDS_CLAIMED";
        if (eventType == TOKEN_REWARDS_CLAIMED) return "TOKEN_REWARDS_CLAIMED";
        if (eventType == TRADE_EXECUTED) return "TRADE_EXECUTED";
        return "UNKNOWN";
    }

    /**
     * @notice Get trade type name for human readability
     * @param tradeType Trade type number
     * @return name Human readable trade type name
     */
    function getTradeTypeName(
        uint8 tradeType
    ) external pure returns (string memory name) {
        if (tradeType == 0) return "BUY";
        if (tradeType == 1) return "SELL";
        return "UNKNOWN";
    }
}
