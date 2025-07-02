import React from 'react';

interface WalletConnectProps {
    account: string;
    onConnect: () => void;
    onDisconnect: () => void;
    isConnecting?: boolean;
    error?: string;
}

const WalletConnect: React.FC<WalletConnectProps> = ({ account, onConnect, onDisconnect, isConnecting = false, error }) => {
    const formatAddress = (address: string) => {
        return `${address.slice(0, 6)}...${address.slice(-4)}`;
    };

    return (
        <div className="wallet-connect">
            {account ? (
                <div className="wallet-info">
                    <span className="account-address">{formatAddress(account)}</span>
                    <button onClick={onDisconnect} className="disconnect-btn">
                        Disconnect
                    </button>
                </div>
            ) : (
                <div className="wallet-connect-container">
                    <button
                        onClick={onConnect}
                        className="connect-btn"
                        disabled={isConnecting}
                    >
                        {isConnecting ? 'Connecting...' : 'Connect Wallet'}
                    </button>
                    {error && (
                        <div className="wallet-error" style={{
                            fontSize: '0.8rem',
                            color: '#e74c3c',
                            marginTop: '0.5rem',
                            maxWidth: '200px'
                        }}>
                            {error}
                        </div>
                    )}
                </div>
            )}
        </div>
    );
};

export default WalletConnect; 