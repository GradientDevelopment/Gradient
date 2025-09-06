// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEventAggregator {
    // Event types
    function ETH_ADD() external view returns (uint8);

    function ETH_REMOVE() external view returns (uint8);

    function TOKEN_ADD() external view returns (uint8);

    function TOKEN_REMOVE() external view returns (uint8);

    function REWARDS_CLAIMED() external view returns (uint8);

    function TRADE_EXECUTED() external view returns (uint8);

    // Main functions
    function emitLiquidityEvent(
        address user,
        address token,
        uint8 eventType,
        uint256 amount
    ) external;

    function emitETHRewardsClaimed(
        address user,
        address token,
        uint256 amount
    ) external;

    function emitTokenRewardsClaimed(
        address user,
        address token,
        uint256 amount
    ) external;

    function emitTradeExecuted(
        address user,
        uint8 tradeType,
        uint256 ethAmount,
        uint256 tokenAmount
    ) external;

    function emitMerkleRootUpdated(
        uint256 version,
        bytes32 merkleRoot
    ) external;

    function emitPoolCreated(address token, address pool) external;

    // View functions
    function getEventTypeName(
        uint8 eventType
    ) external pure returns (string memory name);

    function getTradeTypeName(
        uint8 tradeType
    ) external pure returns (string memory name);
}
