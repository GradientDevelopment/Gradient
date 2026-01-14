// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGradientMarketMakerFactory {
    // Events
    event PoolCreated(
        address indexed token,
        address indexed pool,
        uint256 timestamp
    );

    // Pool management
    function createPool(address token) external returns (address pool);

    function createPoolWithLiquidity(
        address token,
        address initialLiquidityProvider,
        uint256 initialEthAmount,
        uint256 initialTokenAmount
    ) external payable returns (address pool);

    function getPool(address token) external view returns (address pool);

    function poolExists(address token) external view returns (bool);

    function getAllPools() external view returns (address[] memory);

    function getPoolCount() external view returns (uint256);

    // Pool info
    function pools(uint256 index) external view returns (address);

    function poolCount() external view returns (uint256);

    // Factory info
    function owner() external view returns (address);

    function getEventAggregator() external view returns (address);

    function setEventAggregator(address _eventAggregator) external;

    /**
     * @notice Get the registry address
     * @return registryAddress Address of the GradientRegistry
     */
    function getRegistry() external view returns (address);

    /**
     * @notice Get the Uniswap V3 helper address (public variable, auto-generated getter)
     */
    function univ3Helper() external view returns (address);

    /**
     * @notice Check if a given address is a valid pool
     * @param poolAddress Address to check
     * @return isValid True if the address is a valid pool
     */
    function isValidPool(
        address poolAddress
    ) external view returns (bool isValid);
}
