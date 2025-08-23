// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGradientRegistry
 * @notice Interface for the GradientRegistry contract
 */
interface IGradientRegistry {
    /**
     * @notice Set all main contract addresses at once
     * @param _marketMakerFactory Address of the MarketMakerFactory contract
     * @param _gradientToken Address of the Gradient token contract
     * @param _orderbook Address of the Orderbook contract
     * @param _fallbackExecutor Address of the FallbackExecutor contract
     * @param _router Address of the Uniswap V2 Router contract
     */
    function setMainContracts(
        address _marketMakerFactory,
        address _gradientToken,
        address _orderbook,
        address _fallbackExecutor,
        address _router
    ) external;

    /**
     * @notice Set an individual main contract address
     * @param contractName Name of the contract to update
     * @param newAddress New address for the contract
     */
    function setContractAddress(
        string calldata contractName,
        address newAddress
    ) external;

    /**
     * @notice Set an additional contract address using a key
     * @param key The key to identify the contract
     * @param contractAddress The address of the contract
     */
    function setAdditionalContract(
        bytes32 key,
        address contractAddress
    ) external;

    /**
     * @notice Set the block status of a token
     * @param token The address of the token to set the block status of
     * @param blocked Whether the token should be blocked
     */
    function setTokenBlockStatus(address token, bool blocked) external;

    /**
     * @notice Set a reward distributor address
     * @param rewardDistributor The address of the reward distributor to authorize
     */
    function setRewardDistributor(address rewardDistributor) external;

    /**
     * @notice Authorize or deauthorize a fulfiller
     * @param fulfiller The address of the fulfiller to authorize
     * @param status The status of the fulfiller
     */
    function authorizeFulfiller(address fulfiller, bool status) external;

    /**
     * @notice Check if an address is an authorized fulfiller
     * @param fulfiller The address to check
     * @return bool Whether the address is an authorized fulfiller
     */
    function isAuthorizedFulfiller(
        address fulfiller
    ) external view returns (bool);

    /**
     * @notice Get all main contract addresses
     * @return _marketMakerFactory Address of the MarketMakerFactory contract
     * @return _gradientToken Address of the Gradient token contract
     * @return _orderbook Address of the Orderbook contract
     * @return _fallbackExecutor Address of the FallbackExecutor contract
     * @return _router Address of the Uniswap V2 Router contract
     */
    function getAllMainContracts()
        external
        view
        returns (
            address _marketMakerFactory,
            address _gradientToken,
            address _orderbook,
            address _fallbackExecutor,
            address _router
        );

    // View functions for individual contract addresses
    function marketMakerFactory() external view returns (address);

    // Legacy function for backward compatibility (returns factory address)
    function marketMakerPool() external view returns (address);

    // New function to get pool for specific token
    function getMarketMakerPool(address token) external view returns (address);

    // New function to check if pool exists for token
    function poolExists(address token) external view returns (bool);

    function gradientToken() external view returns (address);

    function orderbook() external view returns (address);

    function fallbackExecutor() external view returns (address);

    function router() external view returns (address);

    // View functions for mappings
    function blockedTokens(address token) external view returns (bool);

    function isRewardDistributor(
        address rewardDistributor
    ) external view returns (bool);

    function authorizedFulfillers(
        address fulfiller
    ) external view returns (bool);
}
