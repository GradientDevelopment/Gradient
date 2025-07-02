import React, { useState, useEffect } from 'react';
import { ethers } from 'ethers';

interface OrderbookManagerProps {
    provider: ethers.BrowserProvider | null;
    signer: ethers.JsonRpcSigner | null;
    account: string;
}

interface Order {
    id: string;
    maker: string;
    token: string;
    amount: string;
    price: string;
    isBuy: boolean;
    status: 'active' | 'filled' | 'cancelled';
    timestamp: number;
}

const OrderbookManager: React.FC<OrderbookManagerProps> = ({ provider, signer, account }) => {
    const [orders, setOrders] = useState<Order[]>([]);
    const [newOrder, setNewOrder] = useState({
        token: '',
        amount: '',
        price: '',
        isBuy: true
    });
    const [loading, setLoading] = useState(false);
    const [selectedToken, setSelectedToken] = useState('ETH');

    // Mock data for demonstration
    useEffect(() => {
        const mockOrders: Order[] = [
            {
                id: '1',
                maker: '0x1234...5678',
                token: 'ETH',
                amount: '1.5',
                price: '2000',
                isBuy: true,
                status: 'active',
                timestamp: Date.now() - 3600000
            },
            {
                id: '2',
                maker: '0x8765...4321',
                token: 'ETH',
                amount: '2.0',
                price: '1950',
                isBuy: false,
                status: 'active',
                timestamp: Date.now() - 1800000
            },
            {
                id: '3',
                maker: account,
                token: 'ETH',
                amount: '0.5',
                price: '2050',
                isBuy: true,
                status: 'active',
                timestamp: Date.now() - 900000
            }
        ];
        setOrders(mockOrders);
    }, [account]);

    const handleCreateOrder = async () => {
        if (!signer) return;

        setLoading(true);
        try {
            // Mock order creation - replace with actual contract call
            const newOrderData: Order = {
                id: Date.now().toString(),
                maker: account,
                token: newOrder.token,
                amount: newOrder.amount,
                price: newOrder.price,
                isBuy: newOrder.isBuy,
                status: 'active',
                timestamp: Date.now()
            };

            setOrders(prev => [newOrderData, ...prev]);
            setNewOrder({ token: '', amount: '', price: '', isBuy: true });

            // TODO: Add actual contract interaction here
            console.log('Creating order:', newOrderData);
        } catch (error) {
            console.error('Error creating order:', error);
        } finally {
            setLoading(false);
        }
    };

    const handleCancelOrder = async (orderId: string) => {
        if (!signer) return;

        setLoading(true);
        try {
            // Mock order cancellation - replace with actual contract call
            setOrders(prev => prev.map(order =>
                order.id === orderId
                    ? { ...order, status: 'cancelled' as const }
                    : order
            ));

            // TODO: Add actual contract interaction here
            console.log('Cancelling order:', orderId);
        } catch (error) {
            console.error('Error cancelling order:', error);
        } finally {
            setLoading(false);
        }
    };

    const formatTimestamp = (timestamp: number) => {
        return new Date(timestamp).toLocaleTimeString();
    };

    const filteredOrders = orders.filter(order =>
        selectedToken === 'ALL' || order.token === selectedToken
    );

    const buyOrders = filteredOrders.filter(order => order.isBuy && order.status === 'active');
    const sellOrders = filteredOrders.filter(order => !order.isBuy && order.status === 'active');

    return (
        <div className="orderbook-manager">
            <div className="orderbook-header">
                <h2>Orderbook Management</h2>
                <div className="token-selector">
                    <label>Token: </label>
                    <select
                        value={selectedToken}
                        onChange={(e) => setSelectedToken(e.target.value)}
                    >
                        <option value="ALL">All Tokens</option>
                        <option value="ETH">ETH</option>
                        <option value="USDC">USDC</option>
                        <option value="USDT">USDT</option>
                    </select>
                </div>
            </div>

            <div className="orderbook-content">
                <div className="create-order-section">
                    <h3>Create New Order</h3>
                    <div className="order-form">
                        <div className="form-row">
                            <div className="form-group">
                                <label>Token:</label>
                                <input
                                    type="text"
                                    value={newOrder.token}
                                    onChange={(e) => setNewOrder(prev => ({ ...prev, token: e.target.value }))}
                                    placeholder="Token address or symbol"
                                />
                            </div>
                            <div className="form-group">
                                <label>Amount:</label>
                                <input
                                    type="number"
                                    value={newOrder.amount}
                                    onChange={(e) => setNewOrder(prev => ({ ...prev, amount: e.target.value }))}
                                    placeholder="Amount"
                                    step="0.000001"
                                />
                            </div>
                            <div className="form-group">
                                <label>Price:</label>
                                <input
                                    type="number"
                                    value={newOrder.price}
                                    onChange={(e) => setNewOrder(prev => ({ ...prev, price: e.target.value }))}
                                    placeholder="Price"
                                    step="0.01"
                                />
                            </div>
                            <div className="form-group">
                                <label>Type:</label>
                                <select
                                    value={newOrder.isBuy ? 'buy' : 'sell'}
                                    onChange={(e) => setNewOrder(prev => ({ ...prev, isBuy: e.target.value === 'buy' }))}
                                >
                                    <option value="buy">Buy</option>
                                    <option value="sell">Sell</option>
                                </select>
                            </div>
                        </div>
                        <button
                            onClick={handleCreateOrder}
                            disabled={loading || !newOrder.token || !newOrder.amount || !newOrder.price}
                            className="create-order-btn"
                        >
                            {loading ? 'Creating...' : 'Create Order'}
                        </button>
                    </div>
                </div>

                <div className="orderbook-display">
                    <div className="orderbook-side">
                        <h3>Buy Orders</h3>
                        <div className="order-list">
                            {buyOrders.map(order => (
                                <div key={order.id} className="order-item buy">
                                    <div className="order-info">
                                        <span className="amount">{order.amount} {order.token}</span>
                                        <span className="price">${order.price}</span>
                                        <span className="maker">{order.maker}</span>
                                        <span className="time">{formatTimestamp(order.timestamp)}</span>
                                    </div>
                                    {order.maker === account && (
                                        <button
                                            onClick={() => handleCancelOrder(order.id)}
                                            className="cancel-btn"
                                            disabled={loading}
                                        >
                                            Cancel
                                        </button>
                                    )}
                                </div>
                            ))}
                            {buyOrders.length === 0 && <p className="no-orders">No buy orders</p>}
                        </div>
                    </div>

                    <div className="orderbook-side">
                        <h3>Sell Orders</h3>
                        <div className="order-list">
                            {sellOrders.map(order => (
                                <div key={order.id} className="order-item sell">
                                    <div className="order-info">
                                        <span className="amount">{order.amount} {order.token}</span>
                                        <span className="price">${order.price}</span>
                                        <span className="maker">{order.maker}</span>
                                        <span className="time">{formatTimestamp(order.timestamp)}</span>
                                    </div>
                                    {order.maker === account && (
                                        <button
                                            onClick={() => handleCancelOrder(order.id)}
                                            className="cancel-btn"
                                            disabled={loading}
                                        >
                                            Cancel
                                        </button>
                                    )}
                                </div>
                            ))}
                            {sellOrders.length === 0 && <p className="no-orders">No sell orders</p>}
                        </div>
                    </div>
                </div>

                <div className="my-orders-section">
                    <h3>My Orders</h3>
                    <div className="order-list">
                        {orders.filter(order => order.maker === account).map(order => (
                            <div key={order.id} className={`order-item ${order.isBuy ? 'buy' : 'sell'} ${order.status}`}>
                                <div className="order-info">
                                    <span className="amount">{order.amount} {order.token}</span>
                                    <span className="price">${order.price}</span>
                                    <span className="type">{order.isBuy ? 'BUY' : 'SELL'}</span>
                                    <span className="status">{order.status}</span>
                                    <span className="time">{formatTimestamp(order.timestamp)}</span>
                                </div>
                                {order.status === 'active' && (
                                    <button
                                        onClick={() => handleCancelOrder(order.id)}
                                        className="cancel-btn"
                                        disabled={loading}
                                    >
                                        Cancel
                                    </button>
                                )}
                            </div>
                        ))}
                        {orders.filter(order => order.maker === account).length === 0 && (
                            <p className="no-orders">No orders found</p>
                        )}
                    </div>
                </div>
            </div>
        </div>
    );
};

export default OrderbookManager; 