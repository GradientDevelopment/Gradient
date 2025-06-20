// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGradientRegistry
 * @notice Interface for the GradientRegistry contract
 */
interface IGradientRegistry {
    // Events
    event ContractAddressUpdated(
        string indexed contractName,
        address indexed oldAddress,
        address indexed newAddress
    );
    event AdditionalContractSet(
        bytes32 indexed key,
        address indexed contractAddress
    );
    event ContractAuthorized(address indexed contractAddress, bool authorized);
    event RewardDistributorSet(address indexed rewardDistributor);

    /**
     * @notice Set the main contract addresses
     * @param _marketMakerPool Address of the MarketMakerPool contract
     * @param _uniswapPair Address of the UniswapV2Pair contract
     * @param _gradientToken Address of the Gradient token contract
     * @param _rewardDistributor Address of the reward distributor contract
     * @param _feeCollector Address of the fee collector contract
     */
    function setMainContracts(
        address _marketMakerPool,
        address _uniswapPair,
        address _gradientToken,
        address _rewardDistributor,
        address _feeCollector
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
     * @notice Authorize or deauthorize a contract
     * @param contractAddress The address of the contract
     * @param authorized Whether the contract should be authorized
     */
    function setContractAuthorization(
        address contractAddress,
        bool authorized
    ) external;

    /**
     * @notice Set the block status of a token
     * @param token The address of the token to set the block status of
     * @param blocked Whether the token should be blocked
     */
    function setTokenBlockStatus(address token, bool blocked) external;

    /**
     * @notice Check if a contract is authorized
     * @param contractAddress The address to check
     * @return bool Whether the contract is authorized
     */
    function isContractAuthorized(
        address contractAddress
    ) external view returns (bool);

    /**
     * @notice Get all main contract addresses
     * @return _marketMakerPool Address of the MarketMakerPool contract
     * @return _uniswapPair Address of the UniswapV2Pair contract
     * @return _gradientToken Address of the Gradient token contract
     * @return _rewardDistributor Address of the reward distributor contract
     * @return _feeCollector Address of the fee collector contract
     */
    function getAllMainContracts()
        external
        view
        returns (
            address _marketMakerPool,
            address _uniswapPair,
            address _gradientToken,
            address _rewardDistributor,
            address _feeCollector
        );

    // View functions for individual contract addresses
    function marketMakerPool() external view returns (address);

    function uniswapPair() external view returns (address);

    function gradientToken() external view returns (address);

    function rewardDistributor() external view returns (address);

    function feeCollector() external view returns (address);

    function getOrderbook() external view returns (address);

    function getFallbackExecutor() external view returns (address);

    // View functions for mappings
    function blockedTokens(address token) external view returns (bool);

    function additionalContracts(bytes32 key) external view returns (address);

    function authorizedContracts(
        address contractAddress
    ) external view returns (bool);

    function isRewardDistributor(
        address rewardDistributor
    ) external view returns (bool);
}
