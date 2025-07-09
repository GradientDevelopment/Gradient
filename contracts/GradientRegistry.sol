// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title GradientRegistry
 * @notice Central registry for storing and managing Gradient protocol contract addresses
 * @dev This contract uses role-based access control and timelock to reduce centralization risk
 */
contract GradientRegistry is AccessControl {
    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TIMELOCK_ROLE = keccak256("TIMELOCK_ROLE");

    // Contract addresses
    address public marketMakerPool;
    address public gradientToken;
    address public orderbook;
    address public fallbackExecutor;
    address public router; // Uniswap V2 Router address

    bool public isContractsInitialized;

    // Timelock configuration
    uint256 public timelockDuration = 24 hours;
    mapping(bytes32 => uint256) public pendingChanges;
    mapping(bytes32 => bool) public executedChanges;
    mapping(string => bool) public isInitialized; // Track if each contract has been initialized

    // Mapping for blocked tokens
    mapping(address => bool) public blockedTokens;
    mapping(address => bool) public isRewardDistributor;

    // Mapping for authorized fulfillers
    mapping(address => bool) public authorizedFulfillers;

    // Events
    event ContractAddressUpdated(
        string indexed contractName,
        address indexed oldAddress,
        address indexed newAddress
    );
    event RewardDistributorSet(address indexed rewardDistributor);
    event RewardDistributorRemoved(address indexed rewardDistributor);
    event FulfillerAuthorized(address indexed fulfiller, bool status);
    event RegistryChangeScheduled(
        string indexed contractName,
        address indexed newAddress,
        bytes32 indexed changeId,
        uint256 executionTime
    );
    event RegistryChangeExecuted(bytes32 indexed changeId);
    event RegistryChangeCancelled(bytes32 indexed changeId);
    event TimelockDurationUpdated(uint256 oldDuration, uint256 newDuration);

    constructor() {
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(TIMELOCK_ROLE, msg.sender);
    }

    /**
     * @notice Schedule a registry change with timelock
     * @param contractName Name of the contract to update
     * @param newAddress New address for the contract
     * @dev Only callable by ADMIN_ROLE, requires timelock delay
     */
    function scheduleContractAddressChange(
        string calldata contractName,
        address newAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(newAddress != address(0), "Invalid address");

        // If this is the first time setting this contract, allow immediate execution
        if (!isInitialized[contractName]) {
            _executeContractAddressChange(contractName, newAddress);
            isInitialized[contractName] = true;
            return;
        }

        // For subsequent changes, require timelock
        bytes32 changeId = keccak256(
            abi.encodePacked(contractName, newAddress, block.timestamp)
        );
        require(pendingChanges[changeId] == 0, "Change already scheduled");

        uint256 executionTime = block.timestamp + timelockDuration;
        pendingChanges[changeId] = executionTime;

        emit RegistryChangeScheduled(
            contractName,
            newAddress,
            changeId,
            executionTime
        );
    }

    /**
     * @notice Execute a scheduled registry change after timelock expires
     * @param contractName Name of the contract to update
     * @param newAddress New address for the contract
     * @param timestamp Timestamp when the change was scheduled
     * @dev Only callable by TIMELOCK_ROLE after delay expires
     */
    function executeContractAddressChange(
        string calldata contractName,
        address newAddress,
        uint256 timestamp
    ) external onlyRole(TIMELOCK_ROLE) {
        bytes32 changeId = keccak256(
            abi.encodePacked(contractName, newAddress, timestamp)
        );

        require(pendingChanges[changeId] > 0, "No pending change found");
        require(!executedChanges[changeId], "Change already executed");
        require(
            block.timestamp >= pendingChanges[changeId],
            "Timelock not expired"
        );
        require(
            block.timestamp <= pendingChanges[changeId] + 24 hours,
            "Execution window expired"
        );

        executedChanges[changeId] = true;
        delete pendingChanges[changeId];

        _executeContractAddressChange(contractName, newAddress);
        emit RegistryChangeExecuted(changeId);
    }

    /**
     * @notice Internal function to execute contract address changes
     * @param contractName Name of the contract to update
     * @param newAddress New address for the contract
     */
    function _executeContractAddressChange(
        string memory contractName,
        address newAddress
    ) internal {
        bytes32 nameHash = keccak256(bytes(contractName));
        address oldAddress;

        if (nameHash == keccak256(bytes("MarketMakerPool"))) {
            oldAddress = marketMakerPool;
            marketMakerPool = newAddress;
        } else if (nameHash == keccak256(bytes("GradientToken"))) {
            oldAddress = gradientToken;
            gradientToken = newAddress;
        } else if (nameHash == keccak256(bytes("Orderbook"))) {
            oldAddress = orderbook;
            orderbook = newAddress;
        } else if (nameHash == keccak256(bytes("FallbackExecutor"))) {
            oldAddress = fallbackExecutor;
            fallbackExecutor = newAddress;
        } else if (nameHash == keccak256(bytes("Router"))) {
            oldAddress = router;
            router = newAddress;
        } else {
            revert("Invalid contract name");
        }

        emit ContractAddressUpdated(contractName, oldAddress, newAddress);
    }

    /**
     * @notice Cancel a scheduled registry change (emergency only)
     * @param contractName Name of the contract
     * @param newAddress New address for the contract
     * @param timestamp Timestamp when the change was scheduled
     * @dev Only callable by ADMIN_ROLE
     */
    function cancelContractAddressChange(
        string calldata contractName,
        address newAddress,
        uint256 timestamp
    ) external onlyRole(ADMIN_ROLE) {
        bytes32 changeId = keccak256(
            abi.encodePacked(contractName, newAddress, timestamp)
        );

        require(pendingChanges[changeId] > 0, "No pending change found");
        require(!executedChanges[changeId], "Change already executed");

        delete pendingChanges[changeId];
        emit RegistryChangeCancelled(changeId);
    }

    /**
     * @notice Check if a scheduled change is ready for execution
     * @param contractName Name of the contract
     * @param newAddress New address for the contract
     * @param timestamp Timestamp when the change was scheduled
     * @return ready Whether the change is ready for execution
     * @return executionTime When the change can be executed
     */
    function isChangeReady(
        string calldata contractName,
        address newAddress,
        uint256 timestamp
    ) external view returns (bool ready, uint256 executionTime) {
        bytes32 changeId = keccak256(
            abi.encodePacked(contractName, newAddress, timestamp)
        );
        executionTime = pendingChanges[changeId];

        if (executionTime == 0 || executedChanges[changeId]) {
            return (false, 0);
        }

        ready =
            block.timestamp >= executionTime &&
            block.timestamp <= executionTime + 24 hours;
    }

    /**
     * @notice Update the timelock duration
     * @param newDuration New timelock duration in seconds
     * @dev Only callable by ADMIN_ROLE, requires minimum duration
     */
    function updateTimelockDuration(
        uint256 newDuration
    ) external onlyRole(ADMIN_ROLE) {
        require(newDuration >= 2 hours, "Duration too short");
        require(newDuration <= 7 days, "Duration too long");

        uint256 oldDuration = timelockDuration;
        timelockDuration = newDuration;

        emit TimelockDurationUpdated(oldDuration, newDuration);
    }

    /**
     * @notice Set the main contract addresses (legacy function, requires timelock)
     * @param _marketMakerPool Address of the MarketMakerPool contract
     * @param _gradientToken Address of the Gradient token contract
     * @param _orderbook Address of the Orderbook contract
     * @param _fallbackExecutor Address of the FallbackExecutor contract
     * @param _router Address of the Uniswap V2 Router contract
     * @dev This function now schedules changes instead of executing immediately
     */
    function setMainContracts(
        address _marketMakerPool,
        address _gradientToken,
        address _orderbook,
        address _fallbackExecutor,
        address _router
    ) external onlyRole(ADMIN_ROLE) {
        require(
            _marketMakerPool != address(0),
            "Invalid market maker pool address"
        );
        require(_gradientToken != address(0), "Invalid gradient token address");
        require(_orderbook != address(0), "Invalid orderbook address");
        require(
            _fallbackExecutor != address(0),
            "Invalid fallback executor address"
        );
        require(_router != address(0), "Invalid router address");

        if (!isContractsInitialized) {
            _executeContractAddressChange("MarketMakerPool", _marketMakerPool);
            isInitialized["MarketMakerPool"] = true;
            _executeContractAddressChange("GradientToken", _gradientToken);
            isInitialized["GradientToken"] = true;
            _executeContractAddressChange("Orderbook", _orderbook);
            isInitialized["Orderbook"] = true;
            _executeContractAddressChange(
                "FallbackExecutor",
                _fallbackExecutor
            );
            isInitialized["FallbackExecutor"] = true;
            _executeContractAddressChange("Router", _router);
            isInitialized["Router"] = true;

            isContractsInitialized = true;
            return;
        }

        // Set each contract address (first-time setup will be immediate)
        this.scheduleContractAddressChange("MarketMakerPool", _marketMakerPool);
        this.scheduleContractAddressChange("GradientToken", _gradientToken);
        this.scheduleContractAddressChange("Orderbook", _orderbook);
        this.scheduleContractAddressChange(
            "FallbackExecutor",
            _fallbackExecutor
        );
        this.scheduleContractAddressChange("Router", _router);
    }

    /**
     * @notice Set the block status of a token
     * @param token The address of the token to set the block status of
     * @param blocked Whether the token should be blocked
     */
    function setTokenBlockStatus(
        address token,
        bool blocked
    ) external onlyRole(OPERATOR_ROLE) {
        blockedTokens[token] = blocked;
    }

    /**
     * @notice Set a reward distributor address
     * @param rewardDistributor The address of the reward distributor to authorize
     * @dev Only callable by the contract owner
     */
    function setRewardDistributor(
        address rewardDistributor
    ) external onlyRole(ADMIN_ROLE) {
        require(rewardDistributor != address(0), "Invalid distributor address");
        isRewardDistributor[rewardDistributor] = true;
        emit RewardDistributorSet(rewardDistributor);
    }

    function removeRewardDistributor(
        address rewardDistributor
    ) external onlyRole(ADMIN_ROLE) {
        require(rewardDistributor != address(0), "Invalid distributor address");
        isRewardDistributor[rewardDistributor] = false;
        emit RewardDistributorRemoved(rewardDistributor);
    }

    /**
     * @notice Set an individual main contract address (first-time setup is immediate, subsequent changes require timelock)
     * @param contractName Name of the contract to update
     * @param newAddress New address for the contract
     * @dev First-time setup is immediate, subsequent changes require timelock
     */
    function setContractAddress(
        string calldata contractName,
        address newAddress
    ) external onlyRole(OPERATOR_ROLE) {
        this.scheduleContractAddressChange(contractName, newAddress);
    }

    /**
     * @notice Get all main contract addresses
     * @return _marketMakerPool Address of the MarketMakerPool contract
     * @return _gradientToken Address of the Gradient token contract
     * @return _orderbook Address of the Orderbook contract
     * @return _fallbackExecutor Address of the FallbackExecutor contract
     * @return _router Address of the Uniswap V2 Router contract
     */
    function getAllMainContracts()
        external
        view
        returns (
            address _marketMakerPool,
            address _gradientToken,
            address _orderbook,
            address _fallbackExecutor,
            address _router
        )
    {
        return (
            marketMakerPool,
            gradientToken,
            orderbook,
            fallbackExecutor,
            router
        );
    }

    /**
     * @notice Get the orderbook contract address
     * @return address The orderbook contract address
     */
    function getOrderbook() external view returns (address) {
        return orderbook;
    }

    /**
     * @notice Get the fallback executor contract address
     * @return address The fallback executor contract address
     */
    function getFallbackExecutor() external view returns (address) {
        return fallbackExecutor;
    }

    /**
     * @notice Get the router contract address
     * @return address The router contract address
     */
    function getRouter() external view returns (address) {
        return router;
    }

    /**
     * @notice Authorize or deauthorize a fulfiller
     * @param fulfiller The address of the fulfiller to authorize
     * @param status The status of the fulfiller
     */
    function authorizeFulfiller(
        address fulfiller,
        bool status
    ) external onlyRole(ADMIN_ROLE) {
        require(fulfiller != address(0), "Invalid fulfiller address");
        authorizedFulfillers[fulfiller] = status;
        emit FulfillerAuthorized(fulfiller, status);
    }

    /**
     * @notice Check if an address is an authorized fulfiller
     * @param fulfiller The address to check
     * @return bool Whether the address is an authorized fulfiller
     */
    function isAuthorizedFulfiller(
        address fulfiller
    ) external view returns (bool) {
        return authorizedFulfillers[fulfiller];
    }

    /**
     * @notice Grant role to address
     * @param role Role to grant
     * @param account Account to grant role to
     */
    function grantRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        super.grantRole(role, account);
    }

    /**
     * @notice Revoke role from address
     * @param role Role to revoke
     * @param account Account to revoke role from
     */
    function revokeRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        super.revokeRole(role, account);
    }

    /**
     * @notice Renounce role
     * @param role Role to renounce
     * @param account Account to renounce role from
     */
    function renounceRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        super.renounceRole(role, account);
    }
}
