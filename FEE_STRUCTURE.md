# Gradient Protocol Fee Structure

## Table of Contents
1. [Current Fee Structure (With FeeManager)](#current-fee-structure)
2. [Previous Fee Structure (Before FeeManager Upgrade)](#previous-fee-structure)
3. [Migration Changes](#migration-changes)

---

## Current Fee Structure (With FeeManager)

### Overview
As of the latest upgrade, the platform uses a centralized `GradientFeeManager` contract to handle all fee collection, distribution, and withdrawal. This separation of concerns provides better security, transparency, and management of protocol fees.

### Trading Fees

#### Default Fee Rate
- **Platform Fee**: **1%** (100 basis points) on all trades
- **Divisor**: 10,000 (1 basis point = 0.01%)
- **Fee Limits**:
  - Minimum allowed fee: 0.5% (50 basis points)
  - Maximum allowed fee: 5% (500 basis points)
  - Maximum token-specific fee: 3% (300 basis points)

#### Fee Calculation
Fees are calculated using the formula:
```
feeAmount = (tradeAmount × feePercentage) / 10000
```

### Fee Distribution

#### For Regular Tokens (Non-Partner)
```
Total Fee (1%)
│
├── 50% → Market Makers
│   └── Distributed immediately to MM pool proportionally
│
└── 50% → GRAY Team
    └── Accumulated in FeeManager for later withdrawal
```

#### For Partner Tokens
```
Total Fee (1%)
│
├── 50% → Market Makers
│   └── Distributed immediately to MM pool proportionally
│
└── 50% → Teams
    ├── 25% (of total) → GRAY Team
    │   └── Accumulated in FeeManager
    │
    └── 25% (of total) → Partner Team
        └── Accumulated in FeeManager (per-token)
```

### Fee Flow Architecture

#### 1. Order Matching (Limit Orders)
```
User Trade
    ↓
GradientOrderbook (calculates 1% fee)
    ↓
GradientFeeManager.collectEthFee() or collectTokenFee()
    ↓
Fee accumulated in FeeManager
    ↓
Later claimed by:
  - Platform Owner (owner address)
  - Partner Teams (per-token partner wallets)
```

#### 2. Market Maker Pool Trading
```
User Trade with MM Pool
    ↓
GradientOrderbook (calculates 1% fee)
    ↓
GradientFeeManager.distributeMarketMakerEthFees() or distributeMarketMakerTokenFees()
    ↓
50% → Market Maker Pool (immediate distribution)
50% → Teams (accumulated in FeeManager)
```

### Fee Collection Points

#### ETH Fees
Called in `GradientOrderbook._collectEthFee()`:
```solidity
feeAmount = (amount * feePercentage) / DIVISOR;
feeManager.collectEthFee{value: feeAmount}(feeAmount, token);
```

#### Token Fees
Called in `GradientOrderbook._collectTokenFee()`:
```solidity
feeAmount = (amount * feePercentage) / DIVISOR;
IERC20(token).safeTransfer(address(feeManager), feeAmount);
feeManager.collectTokenFee(feeAmount, token);
```

### Fee Withdrawal

#### Platform Owner
```solidity
FeeManager.withdrawEthFees(amount)  // Withdraw accumulated ETH fees
FeeManager.withdrawTokenFees(token, amount)  // Withdraw accumulated token fees
```

#### Partner Teams
```solidity
FeeManager.claimPartnerEthFees(token, amount)  // Claim partner ETH share
FeeManager.claimPartnerTokenFees(token, amount)  // Claim partner token share
```

### Key Contracts

1. **GradientOrderbook**: Calculates fees and delegates to FeeManager
2. **GradientFeeManager**: Centralized fee collection and distribution
3. **GradientMarketMakerPoolV3**: Receives MM fee distributions
4. **GradientRegistry**: Stores partner token configuration

### Current Configuration
```solidity
defaultFeePercentage = 100 (1%)
minOrderSize = 0.000001 ETH
maxOrderSize = 1000 ETH
maxOrderTtl = 30 days
```

---

## Previous Fee Structure (Before FeeManager Upgrade)

### Overview
Before the FeeManager upgrade, fee logic was centralized in the `GradientOrderbook` contract. Fees were calculated, collected, and distributed all within the orderbook, making the contract more complex and harder to upgrade.

### Trading Fees

#### Default Fee Rate
- **Platform Fee**: **1%** (100 basis points) on all trades
- **Same divisor**: 10,000 (1 basis point = 0.01%)
- **Same fee limits** as current structure

### Fee Distribution Logic

#### For Regular Tokens
```
Total Fee (1%)
│
├── Percentage to Market Makers (variable)
│   └── Distributed to MM pool
│
└── Percentage to Platform Team (variable)
    └── Tracked in orderbook internal variables
```

#### For Partner Tokens
```
Total Fee (1%)
│
├── Percentage to Market Makers (variable)
│   └── Distributed to MM pool
│
└── Percentage to Teams (variable)
    ├── Platform Team Share
    └── Partner Team Share
```

### Key Differences

#### 1. Fee Claiming in Orderbook
**Old Approach**:
- `claimEthFees()` function in `GradientOrderbook`
- `claimTokenFees()` function in `GradientOrderbook`
- Platform owner had direct access to claim fees from orderbook

**Problem**: Mixed responsibilities in single contract

#### 2. Fee Tracking Variables in Orderbook
**Old Variables**:
```solidity
uint256 public platformEthFeesCollected;
uint256 public platformTokenFeesCollected;
mapping(address => uint256) public partnerTokenFeesCollected;
uint256 public mmFeeDistributionPercentage;
```

**Problem**: Increased orderbook contract size and complexity

#### 3. Manual Fee Collection in Orderbook
**Old Flow**:
```solidity
// Fees calculated and tracked internally
platformEthFeesCollected += ethFee;
partnerTokenFeesCollected[token] += tokenFee;

// Distribution logic mixed with order fulfillment
uint256 mmFee = (totalFee * mmFeeDistributionPercentage) / 10000;
```

**Problem**: Harder to audit, modify, or upgrade fee logic

#### 4. No Centralized Fee Manager
- All fee logic in one contract
- Harder to upgrade fee structure
- Risk of affecting order matching logic when updating fees
- Mixed access control and business logic

### Migration Differences

| Aspect | Old (Pre-FeeManager) | New (With FeeManager) |
|--------|---------------------|----------------------|
| **Fee Collection** | Internal tracking in Orderbook | Delegated to FeeManager |
| **Fee Claiming** | `claimEthFees()` in Orderbook | `withdrawEthFees()` in FeeManager |
| **Fee Distribution** | Logic in Orderbook | Separate distribution functions in FeeManager |
| **Partner Fees** | Tracked in Orderbook | Tracked in FeeManager |
| **Upgradeability** | Required Orderbook upgrade | Independent FeeManager upgrade |
| **Security** | Single contract risk | Separated concerns |
| **Audit Complexity** | High (mixed logic) | Lower (focused contracts) |

### Old Fee Collection Flow (Before Upgrade)

#### In Orderbook
```solidity
// Old internal collection
function _collectEthFee(uint256 amount, address token) internal {
    uint256 feeAmount = (amount * feePercentage) / DIVISOR;
    
    // Track internally
    if (isPartnerToken(token)) {
        platformEthFeesCollected += (feeAmount * platformShare) / 10000;
        partnerTokenFeesCollected[token] += (feeAmount * partnerShare) / 10000;
    } else {
        platformEthFeesCollected += feeAmount;
    }
}

// Old claim function (removed)
function claimEthFees() external onlyOwner {
    payable(owner()).transfer(platformEthFeesCollected);
    platformEthFeesCollected = 0;
}
```

---

## Migration Changes

### What Changed

1. **Removed from Orderbook**:
   - `claimEthFees()` function
   - `claimTokenFees()` function
   - Internal fee tracking variables
   - `mmFeeDistributionPercentage` variable
   - Manual fee accumulation logic

2. **Added FeeManager Contract**:
   - Centralized fee collection
   - Secure fee distribution logic
   - Separate withdrawal functions for owner and partners
   - Better access control with `onlyOrderbook` modifier

3. **Updated Orderbook Functions**:
   - `_collectEthFee()` now delegates to FeeManager
   - `_collectTokenFee()` now delegates to FeeManager
   - Removed redundant `collect` calls before distribution

4. **Registry Integration**:
   - Added `feeManager` storage in `GradientRegistry`
   - Updated `setMainContracts()` to include feeManager parameter
   - Orderbook retrieves feeManager from registry

### Benefits of New Structure

1. **Separation of Concerns**: Trading logic separate from fee management
2. **Upgradeability**: Fee logic can be upgraded independently
3. **Security**: Reduced attack surface on Orderbook contract
4. **Auditability**: Easier to verify fee logic in dedicated contract
5. **Flexibility**: Can add new fee types without modifying Orderbook
6. **Gas Efficiency**: Streamlined fee distribution paths

### Deployment Order

```
1. Deploy GradientRegistry
2. Deploy GradientFeeManager
3. Deploy GradientOrderbook
4. Call Registry.setMainContracts(...feeManager...)
5. Call Orderbook.setGradientRegistry(registry)
6. Configuration complete ✅
```

---

## Summary

The FeeManager upgrade represents a significant architectural improvement, separating fee management concerns from the core trading logic. This provides better security, maintainability, and flexibility for future protocol enhancements.

**Current Fee Structure**: 1% trading fee with 50/50 split to MM and teams (or 50/25/25 for partner tokens)

**Fee Distribution**: Half to market makers immediately, half accumulated for team withdrawals

**Management**: Centralized in `GradientFeeManager` contract with secure withdrawal mechanisms

