// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IGradientFeeManager
 * @notice Interface for the GradientFeeManager contract
 * @dev Handles partner fee distribution and platform fee management
 */
interface IGradientFeeManager {
    // ========================== Events ==========================

    /// @notice Emitted when ETH fees are withdrawn
    event EthFeesWithdrawn(address indexed recipient, uint256 amount);

    /// @notice Emitted when token fees are withdrawn
    event TokenFeesWithdrawn(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    /// @notice Emitted when partner ETH fees are claimed
    event PartnerEthFeesClaimed(
        address indexed token,
        address indexed partnerWallet,
        uint256 amount
    );

    /// @notice Emitted when partner token fees are claimed
    event PartnerTokenFeesClaimed(
        address indexed token,
        address indexed partnerWallet,
        uint256 amount
    );

    /// @notice Emitted when fees are distributed to teams (market maker only)
    event FeeDistributedToTeams(
        address indexed token,
        uint256 grayTeamFee,
        uint256 partnerTeamFee,
        uint256 totalTeamFee
    );

    /// @notice Emitted when fees are distributed to market maker pool
    event FeeDistributedToPool(
        address indexed marketMakerPool,
        address indexed token,
        uint256 amount,
        uint256 totalFee
    );

    // ========================== Fee Distribution Functions ==========================

    /// @notice Distributes market maker token fees according to partner split logic
    /// @param totalFee Total fee amount to distribute
    /// @param token Token address for partner token check
    /// @param marketMakerPool Market maker pool address for distribution
    function distributeMarketMakerTokenFees(
        uint256 totalFee,
        address token,
        address marketMakerPool
    ) external;

    /// @notice Distributes market maker ETH fees according to partner split logic
    /// @param totalFee Total ETH fee amount to distribute
    /// @param token Token address for partner token check
    /// @param marketMakerPool Market maker pool address for distribution
    function distributeMarketMakerEthFees(
        uint256 totalFee,
        address token,
        address marketMakerPool
    ) external payable;

    // ========================== Fee Collection Functions ==========================

    /// @notice Collects ETH fees and updates totals
    /// @param amount Amount in ETH to collect
    /// @param token Token address for potential token-specific fee tracking
    function collectEthFee(uint256 amount, address token) external payable;

    /// @notice Collects token fees and updates totals
    /// @param amount Amount in tokens to collect
    /// @param token Token address
    function collectTokenFee(uint256 amount, address token) external;

    // ========================== Fee Withdrawal Functions ==========================

    /// @notice Withdraws collected ETH fees to the specified address
    /// @param recipient Address to receive the ETH fees
    function withdrawEthFees(address payable recipient) external;

    /// @notice Withdraws collected token fees to the specified address
    /// @param token Address of the token to withdraw fees for
    /// @param recipient Address to receive the token fees
    function withdrawTokenFees(address token, address recipient) external;

    /// @notice Claim partner ETH fees for a specific token
    /// @param token Address of the partner token to claim fees for
    function claimPartnerEthFees(address token) external;

    /// @notice Claim partner token fees for a specific token
    /// @param token Address of the partner token to claim fees for
    function claimPartnerTokenFees(address token) external;

    // ========================== View Functions ==========================

    /// @notice Gets total ETH fees collected
    /// @return uint256 Total ETH fees collected
    function totalEthFeesCollected() external view returns (uint256);

    /// @notice Gets total token fees collected for a specific token
    /// @param token Token address
    /// @return uint256 Total token fees collected
    function totalTokenFeesCollected(
        address token
    ) external view returns (uint256);

    /// @notice Gets partner ETH fees collected for a specific token
    /// @param token Token address
    /// @return uint256 Partner ETH fees collected
    function partnerEthFeesCollected(
        address token
    ) external view returns (uint256);

    /// @notice Gets partner token fees collected for a specific token
    /// @param token Token address
    /// @return uint256 Partner token fees collected
    function partnerTokenFeesCollected(
        address token
    ) external view returns (uint256);

    /// @notice Gets platform ETH fees claimed
    /// @return uint256 Platform ETH fees claimed
    function platformEthFeesClaimed() external view returns (uint256);

    /// @notice Gets platform token fees claimed for a specific token
    /// @param token Token address
    /// @return uint256 Platform token fees claimed
    function platformTokenFeesClaimed(
        address token
    ) external view returns (uint256);

    /// @notice Gets partner ETH fees claimed for a specific token
    /// @param token Token address
    /// @return uint256 Partner ETH fees claimed
    function partnerEthFeesClaimed(
        address token
    ) external view returns (uint256);

    /// @notice Gets partner token fees claimed for a specific token
    /// @param token Token address
    /// @return uint256 Partner token fees claimed
    function partnerTokenFeesClaimed(
        address token
    ) external view returns (uint256);
}
