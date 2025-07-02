# Gradient OTC Platform UI

A modern, responsive web interface for managing orderbook and liquidity on the Gradient OTC Platform.

## Features

### Orderbook Management
- **Create Orders**: Place buy and sell orders with custom amounts and prices
- **View Orderbook**: Real-time display of buy and sell orders with maker information
- **Cancel Orders**: Cancel your own active orders
- **Order History**: Track your order status (active, filled, cancelled)
- **Token Filtering**: Filter orders by different tokens (ETH, USDC, USDT)

### Liquidity Management
- **Pool Information**: View total liquidity, shares, and accumulated fees for buy/sell pools
- **Add Liquidity**: Provide liquidity to either buy or sell pools
- **Remove Liquidity**: Withdraw your liquidity positions
- **Claim Fees**: Collect accumulated trading fees from your liquidity positions
- **Position Tracking**: Monitor your liquidity shares and earnings

### Wallet Integration
- **MetaMask Support**: Connect your MetaMask wallet
- **Account Display**: Shows connected wallet address
- **Transaction Signing**: Sign transactions directly from the UI

## Getting Started

### Prerequisites
- Node.js (v16 or higher)
- npm or yarn
- MetaMask browser extension

### Installation

1. Navigate to the UI directory:
```bash
cd ui
```

2. Install dependencies:
```bash
npm install
```

3. Start the development server:
```bash
npm start
```

4. Open [http://localhost:3000](http://localhost:3000) in your browser

### Building for Production

```bash
npm run build
```

## Usage

### Connecting Your Wallet

1. Click "Connect Wallet" in the header
2. Approve the MetaMask connection request
3. Your wallet address will be displayed in the header

### Creating Orders

1. Navigate to the "Orderbook Management" tab
2. Fill in the order form:
   - **Token**: Enter token address or symbol
   - **Amount**: Specify the amount to trade
   - **Price**: Set your desired price
   - **Type**: Choose Buy or Sell
3. Click "Create Order"

### Managing Liquidity

1. Navigate to the "Liquidity Management" tab
2. Select a token from the dropdown
3. View pool information for both buy and sell pools
4. Add liquidity by entering an amount and selecting pool type
5. Monitor your positions and claim fees when available

## Technical Details

### Architecture
- **React 18** with TypeScript
- **Ethers.js v6** for blockchain interaction
- **CSS Grid & Flexbox** for responsive design
- **Glassmorphism UI** with modern styling

### Smart Contract Integration
The UI is designed to work with the following smart contracts:
- `GradientOrderbook.sol` - Order management
- `GradientMarketMakerPool.sol` - Liquidity pools
- `GradientRegistry.sol` - Token registry

### State Management
- React hooks for local state management
- Mock data for demonstration (replace with actual contract calls)
- Real-time updates for orderbook and pool information

## Development

### Project Structure
```
src/
├── components/
│   ├── OrderbookManager.tsx    # Orderbook management interface
│   ├── LiquidityManager.tsx    # Liquidity management interface
│   └── WalletConnect.tsx       # Wallet connection component
├── App.tsx                     # Main application component
├── App.css                     # Global styles
└── index.tsx                   # Application entry point
```

### Adding Contract Integration

To integrate with actual smart contracts:

1. **Deploy Contracts**: Deploy the smart contracts to your target network
2. **Update Contract Addresses**: Replace mock data with actual contract calls
3. **Add ABI**: Import contract ABIs for proper interaction
4. **Error Handling**: Add proper error handling for failed transactions

Example contract integration:
```typescript
// In OrderbookManager.tsx
const orderbookContract = new ethers.Contract(
  ORDERBOOK_ADDRESS,
  ORDERBOOK_ABI,
  signer
);

const createOrder = async () => {
  const tx = await orderbookContract.createOrder(
    token,
    ethers.parseEther(amount),
    ethers.parseEther(price),
    isBuy
  );
  await tx.wait();
};
```

### Styling
The UI uses a modern glassmorphism design with:
- Gradient backgrounds
- Glass-like transparency effects
- Smooth animations and transitions
- Responsive grid layouts
- Color-coded order types (green for buy, red for sell)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

MIT License - see the main project LICENSE file for details.

## Support

For issues and questions:
1. Check the main project documentation
2. Review the smart contract interfaces
3. Open an issue in the repository

## Roadmap

- [ ] Real-time orderbook updates
- [ ] Advanced order types (limit, market, stop-loss)
- [ ] Trading history and analytics
- [ ] Mobile app version
- [ ] Multi-chain support
- [ ] Advanced liquidity management features
