import React, { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import {
    CONTRACT_ADDRESSES,
    MARKET_MAKER_POOL_ABI,
    createContractInstance,
    getPoolInfo,
    getUserInfo,
    getUserSharePercentage,
    parseTokenAmount,
    handleTransactionError,
    waitForTransaction
} from '../utils/contractHelpers';

interface LiquidityManagerProps {
    provider: ethers.BrowserProvider | null;
    signer: ethers.JsonRpcSigner | null;
    account: string;
}

interface PoolInfo {
    totalEth: string;
    totalToken: string;
    totalLiquidity: string;
    totalLPShares: string;
    accRewardPerShare: string;
    rewardBalance: string;
    uniswapPair: string;
    exists: boolean;
}

interface UserInfo {
    tokenAmount: string;
    ethAmount: string;
    lpShares: string;
    rewardDebt: string;
    pendingReward: string;
}

const LiquidityManager: React.FC<LiquidityManagerProps> = ({ provider, signer, account }) => {
    const [poolInfo, setPoolInfo] = useState<PoolInfo | null>(null);
    const [userInfo, setUserInfo] = useState<UserInfo | null>(null);
    const [selectedToken, setSelectedToken] = useState('0xA0b86a33E6441b8c4C8C8C8C8C8C8C8C8C8C8C8'); // USDC
    const [loading, setLoading] = useState(false);
    const [liquidityForm, setLiquidityForm] = useState({
        tokenAmount: '',
        ethAmount: ''
    });
    const [withdrawForm, setWithdrawForm] = useState({
        shares: '1000' // 10% by default
    });
    const [error, setError] = useState<string>('');

    const marketMakerPoolContract = signer ? createContractInstance(
        CONTRACT_ADDRESSES.MARKET_MAKER_POOL,
        MARKET_MAKER_POOL_ABI,
        signer
    ) : null;

    // Load pool and user data
    const loadData = async () => {
        if (!marketMakerPoolContract || !selectedToken) return;

        try {
            setLoading(true);
            setError('');

            // Get pool info
            const pool = await getPoolInfo(marketMakerPoolContract, selectedToken);
            setPoolInfo(pool);

            // Get user info
            const user = await getUserInfo(marketMakerPoolContract, selectedToken, account);
            setUserInfo(user);

        } catch (error) {
            console.error('Error loading data:', error);
            setError('Failed to load pool data');
        } finally {
            setLoading(false);
        }
    };

    // Load data when component mounts or when token/signer changes
    useEffect(() => {
        loadData();
    }, [selectedToken, signer, account]);

    const handleAddLiquidity = async () => {
        if (!marketMakerPoolContract || !liquidityForm.tokenAmount || !liquidityForm.ethAmount) {
            setError('Please fill in all fields');
            return;
        }

        setLoading(true);
        setError('');

        try {
            const tokenAmount = parseTokenAmount(liquidityForm.tokenAmount);
            const ethAmount = parseTokenAmount(liquidityForm.ethAmount);

            // Note: You'll need to approve the token transfer first
            // This is a simplified version - you may need to add token approval logic

            const tx = await marketMakerPoolContract.provideLiquidity(
                selectedToken,
                tokenAmount,
                { value: ethAmount }
            );

            await waitForTransaction(tx);

            // Reload data after successful transaction
            await loadData();

            setLiquidityForm({ tokenAmount: '', ethAmount: '' });

        } catch (error: any) {
            console.error('Error adding liquidity:', error);
            setError(handleTransactionError(error));
        } finally {
            setLoading(false);
        }
    };

    const handleRemoveLiquidity = async () => {
        if (!marketMakerPoolContract || !withdrawForm.shares) {
            setError('Please enter withdrawal percentage');
            return;
        }

        setLoading(true);
        setError('');

        try {
            const shares = parseInt(withdrawForm.shares);
            if (shares <= 0 || shares > 10000) {
                setError('Shares must be between 1 and 10000 (100% = 10000)');
                return;
            }

            const tx = await marketMakerPoolContract.withdrawLiquidity(
                selectedToken,
                shares
            );

            await waitForTransaction(tx);

            // Reload data after successful transaction
            await loadData();

        } catch (error: any) {
            console.error('Error removing liquidity:', error);
            setError(handleTransactionError(error));
        } finally {
            setLoading(false);
        }
    };

    const handleClaimReward = async () => {
        if (!marketMakerPoolContract) return;

        setLoading(true);
        setError('');

        try {
            const tx = await marketMakerPoolContract.claimReward(selectedToken);

            await waitForTransaction(tx);

            // Reload data after successful transaction
            await loadData();

        } catch (error: any) {
            console.error('Error claiming reward:', error);
            setError(handleTransactionError(error));
        } finally {
            setLoading(false);
        }
    };

    const formatTime = (timestamp: number) => {
        return new Date(timestamp).toLocaleString();
    };

    const getTokenSymbol = (address: string) => {
        const tokenMap: { [key: string]: string } = {
            '0x0000000000000000000000000000000000000000': 'ETH',
            '0xA0b86a33E6441b8c4C8C8C8C8C8C8C8C8C8C8C8': 'USDC',
            '0xdAC17F958D2ee523a2206206994597C13D831ec7': 'USDT',
        };
        return tokenMap[address.toLowerCase()] || 'Unknown';
    };

    const tokenSymbol = getTokenSymbol(selectedToken);

    return (
        <div className="liquidity-manager">
            <div className="liquidity-header">
                <h2>Liquidity Management</h2>
                <div className="token-selector">
                    <label>Token: </label>
                    <select
                        value={selectedToken}
                        onChange={(e) => setSelectedToken(e.target.value)}
                    >
                        <option value="0x0000000000000000000000000000000000000000">ETH</option>
                        <option value="0xA0b86a33E6441b8c4C8C8C8C8C8C8C8C8C8C8C8">USDC</option>
                        <option value="0xdAC17F958D2ee523a2206206994597C13D831ec7">USDT</option>
                    </select>
                </div>
            </div>

            {error && (
                <div className="error-message" style={{
                    background: '#fee',
                    color: '#c33',
                    padding: '1rem',
                    borderRadius: '8px',
                    marginBottom: '1rem'
                }}>
                    {error}
                </div>
            )}

            <div className="liquidity-content">
                <div className="pool-info-section">
                    <h3>Pool Information - {tokenSymbol}</h3>
                    {poolInfo ? (
                        <div className="pool-stats">
                            <div className="stat">
                                <label>Total ETH:</label>
                                <span>{poolInfo.totalEth} ETH</span>
                            </div>
                            <div className="stat">
                                <label>Total {tokenSymbol}:</label>
                                <span>{poolInfo.totalToken} {tokenSymbol}</span>
                            </div>
                            <div className="stat">
                                <label>Total Liquidity:</label>
                                <span>{poolInfo.totalLiquidity}</span>
                            </div>
                            <div className="stat">
                                <label>Total LP Shares:</label>
                                <span>{poolInfo.totalLPShares}</span>
                            </div>
                            <div className="stat">
                                <label>Reward Balance:</label>
                                <span>{poolInfo.rewardBalance} ETH</span>
                            </div>
                        </div>
                    ) : (
                        <p>Loading pool information...</p>
                    )}
                </div>

                <div className="add-liquidity-section">
                    <h3>Add Liquidity</h3>
                    <div className="liquidity-form">
                        <div className="form-row">
                            <div className="form-group">
                                <label>Token Amount ({tokenSymbol}):</label>
                                <input
                                    type="number"
                                    value={liquidityForm.tokenAmount}
                                    onChange={(e) => setLiquidityForm(prev => ({ ...prev, tokenAmount: e.target.value }))}
                                    placeholder="Amount of tokens to add"
                                    step="0.000001"
                                />
                            </div>
                            <div className="form-group">
                                <label>ETH Amount:</label>
                                <input
                                    type="number"
                                    value={liquidityForm.ethAmount}
                                    onChange={(e) => setLiquidityForm(prev => ({ ...prev, ethAmount: e.target.value }))}
                                    placeholder="Amount of ETH to add"
                                    step="0.000001"
                                />
                            </div>
                        </div>
                        <button
                            onClick={handleAddLiquidity}
                            disabled={loading || !liquidityForm.tokenAmount || !liquidityForm.ethAmount}
                            className="add-liquidity-btn"
                        >
                            {loading ? 'Adding...' : 'Add Liquidity'}
                        </button>
                    </div>
                </div>

                <div className="my-liquidity-section">
                    <h3>My Liquidity Position</h3>
                    {userInfo && parseFloat(userInfo.lpShares) > 0 ? (
                        <div className="position-info">
                            <div className="position-stats">
                                <div className="stat">
                                    <label>My Token Amount:</label>
                                    <span>{userInfo.tokenAmount} {tokenSymbol}</span>
                                </div>
                                <div className="stat">
                                    <label>My ETH Amount:</label>
                                    <span>{userInfo.ethAmount} ETH</span>
                                </div>
                                <div className="stat">
                                    <label>My LP Shares:</label>
                                    <span>{userInfo.lpShares}</span>
                                </div>
                                <div className="stat">
                                    <label>Pending Rewards:</label>
                                    <span>{userInfo.pendingReward} ETH</span>
                                </div>
                            </div>

                            <div className="withdraw-section">
                                <h4>Withdraw Liquidity</h4>
                                <div className="form-row">
                                    <div className="form-group">
                                        <label>Withdrawal Percentage (basis points):</label>
                                        <input
                                            type="number"
                                            value={withdrawForm.shares}
                                            onChange={(e) => setWithdrawForm(prev => ({ ...prev, shares: e.target.value }))}
                                            placeholder="1000 = 10%, 10000 = 100%"
                                            min="1"
                                            max="10000"
                                        />
                                    </div>
                                </div>
                                <div className="position-actions">
                                    <button
                                        onClick={handleRemoveLiquidity}
                                        className="remove-liquidity-btn"
                                        disabled={loading}
                                    >
                                        {loading ? 'Withdrawing...' : 'Withdraw Liquidity'}
                                    </button>
                                    <button
                                        onClick={handleClaimReward}
                                        className="claim-fees-btn"
                                        disabled={loading || parseFloat(userInfo.pendingReward) === 0}
                                    >
                                        {loading ? 'Claiming...' : 'Claim Rewards'}
                                    </button>
                                </div>
                            </div>
                        </div>
                    ) : (
                        <p className="no-position">No liquidity position found for this token</p>
                    )}
                </div>
            </div>
        </div>
    );
};

export default LiquidityManager; 