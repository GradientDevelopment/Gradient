import React, { useState, useEffect } from 'react';
import './App.css';
import OrderbookManager from './components/OrderbookManager';
import LiquidityManager from './components/LiquidityManager';
import WalletConnect from './components/WalletConnect';
import { ethers } from 'ethers';

function App() {
  const [provider, setProvider] = useState<ethers.BrowserProvider | null>(null);
  const [signer, setSigner] = useState<ethers.JsonRpcSigner | null>(null);
  const [account, setAccount] = useState<string>('');
  const [activeTab, setActiveTab] = useState<'orderbook' | 'liquidity'>('orderbook');
  const [connectionError, setConnectionError] = useState<string>('');
  const [isConnecting, setIsConnecting] = useState(false);

  // Check if MetaMask is installed
  const isMetaMaskInstalled = typeof window.ethereum !== 'undefined';

  const connectWallet = async () => {
    if (!isMetaMaskInstalled) {
      setConnectionError('MetaMask is not installed. Please install MetaMask extension first.');
      return;
    }

    setIsConnecting(true);
    setConnectionError('');

    try {
      console.log('Attempting to connect to MetaMask...');

      // Request account access
      const accounts = await window.ethereum.request({
        method: 'eth_requestAccounts'
      });

      console.log('Accounts received:', accounts);

      if (!accounts || accounts.length === 0) {
        throw new Error('No accounts found. Please unlock MetaMask.');
      }

      // Create provider and signer
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();

      console.log('Provider and signer created successfully');

      // Get network info
      const network = await provider.getNetwork();
      console.log('Connected to network:', network);

      // Check if we're on the right network (you can customize this)
      const targetChainId = BigInt(31337); // Hardhat local network
      if (network.chainId !== targetChainId) {
        console.log('Wrong network detected. Current:', network.chainId, 'Expected:', targetChainId);
        // You can add network switching logic here if needed
      }

      setProvider(provider);
      setSigner(signer);
      setAccount(accounts[0]);

      console.log('Wallet connected successfully:', accounts[0]);

    } catch (error: any) {
      console.error('Error connecting wallet:', error);

      if (error.code === 4001) {
        setConnectionError('Connection rejected by user. Please try again and approve the connection.');
      } else if (error.code === -32002) {
        setConnectionError('MetaMask is already processing a request. Please check MetaMask and try again.');
      } else if (error.message?.includes('User rejected')) {
        setConnectionError('Connection was rejected. Please approve the connection in MetaMask.');
      } else if (error.message?.includes('No accounts found')) {
        setConnectionError('No accounts found. Please unlock MetaMask and try again.');
      } else {
        setConnectionError(`Connection failed: ${error.message || 'Unknown error'}`);
      }
    } finally {
      setIsConnecting(false);
    }
  };

  const disconnectWallet = () => {
    setProvider(null);
    setSigner(null);
    setAccount('');
    setConnectionError('');
  };

  // Listen for account changes
  useEffect(() => {
    if (!isMetaMaskInstalled) return;

    const handleAccountsChanged = (accounts: string[]) => {
      console.log('Accounts changed:', accounts);
      if (accounts.length === 0) {
        // User disconnected their wallet
        disconnectWallet();
      } else if (account && accounts[0] !== account) {
        // User switched accounts
        setAccount(accounts[0]);
      }
    };

    const handleChainChanged = (chainId: string) => {
      console.log('Chain changed:', chainId);
      // Reload the page when chain changes
      window.location.reload();
    };

    const handleDisconnect = () => {
      console.log('MetaMask disconnected');
      disconnectWallet();
    };

    // Add event listeners
    window.ethereum.on('accountsChanged', handleAccountsChanged);
    window.ethereum.on('chainChanged', handleChainChanged);
    window.ethereum.on('disconnect', handleDisconnect);

    // Cleanup
    return () => {
      window.ethereum.removeListener('accountsChanged', handleAccountsChanged);
      window.ethereum.removeListener('chainChanged', handleChainChanged);
      window.ethereum.removeListener('disconnect', handleDisconnect);
    };
  }, [isMetaMaskInstalled, account]);

  return (
    <div className="App">
      <header className="App-header">
        <h1>Gradient OTC Platform</h1>
        <WalletConnect
          account={account}
          onConnect={connectWallet}
          onDisconnect={disconnectWallet}
          isConnecting={isConnecting}
          error={connectionError}
        />
      </header>

      <main className="App-main">
        {!account ? (
          <div className="connect-prompt">
            <h2>Welcome to Gradient OTC Platform</h2>
            <p>Connect your wallet to start trading and managing liquidity</p>

            {!isMetaMaskInstalled && (
              <div className="metamask-install-prompt" style={{
                background: '#fff3cd',
                color: '#856404',
                padding: '1rem',
                borderRadius: '8px',
                marginBottom: '1rem',
                border: '1px solid #ffeaa7'
              }}>
                <strong>MetaMask Required:</strong> Please install MetaMask browser extension to use this application.
                <br />
                <a
                  href="https://metamask.io/download/"
                  target="_blank"
                  rel="noopener noreferrer"
                  style={{ color: '#007bff', textDecoration: 'underline' }}
                >
                  Download MetaMask
                </a>
              </div>
            )}

            {connectionError && (
              <div className="error-message" style={{
                background: '#fee',
                color: '#c33',
                padding: '1rem',
                borderRadius: '8px',
                marginBottom: '1rem',
                borderLeft: '4px solid #e74c3c'
              }}>
                <strong>Connection Error:</strong> {connectionError}
              </div>
            )}

            <button
              onClick={connectWallet}
              className="connect-btn"
              disabled={!isMetaMaskInstalled || isConnecting}
            >
              {isConnecting ? 'Connecting...' : 'Connect Wallet'}
            </button>

            {isMetaMaskInstalled && (
              <div className="connection-tips" style={{
                marginTop: '1rem',
                padding: '1rem',
                background: '#f8f9fa',
                borderRadius: '8px',
                fontSize: '0.9rem',
                color: '#6c757d'
              }}>
                <strong>Connection Tips:</strong>
                <ul style={{ marginTop: '0.5rem', paddingLeft: '1.5rem' }}>
                  <li>Make sure MetaMask is unlocked</li>
                  <li>Check that you're on the correct network</li>
                  <li>Try refreshing the page if connection fails</li>
                  <li>Ensure MetaMask extension is enabled</li>
                </ul>
              </div>
            )}
          </div>
        ) : (
          <>
            <div className="tab-container">
              <button
                className={`tab ${activeTab === 'orderbook' ? 'active' : ''}`}
                onClick={() => setActiveTab('orderbook')}
              >
                Orderbook Management
              </button>
              <button
                className={`tab ${activeTab === 'liquidity' ? 'active' : ''}`}
                onClick={() => setActiveTab('liquidity')}
              >
                Liquidity Management
              </button>
            </div>

            <div className="content-container">
              {activeTab === 'orderbook' && (
                <OrderbookManager
                  provider={provider}
                  signer={signer}
                  account={account}
                />
              )}
              {activeTab === 'liquidity' && (
                <LiquidityManager
                  provider={provider}
                  signer={signer}
                  account={account}
                />
              )}
            </div>
          </>
        )}
      </main>
    </div>
  );
}

export default App;
