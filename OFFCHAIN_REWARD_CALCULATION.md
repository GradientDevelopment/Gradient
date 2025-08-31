# Off-Chain Reward Calculation

## **Reward Calculation Formulas**

### **ETH Provider Rewards (for ETH LP shares):**
```javascript
function calculateETHPendingRewards(userDB, poolStateDB) {
    if (userDB.ethLPShares === 0) return 0;
    
    const userAccumulated = (userDB.ethLPShares * poolStateDB.accRewardPerShare) / SCALE;
    const pendingRewards = userAccumulated - userDB.rewardDebt + userDB.pendingRewards;
    
    return pendingRewards;
}
```

### **Token Provider Rewards (for token LP shares):**
```javascript
function calculateTokenPendingRewards(userDB, poolStateDB) {
    if (userDB.tokenLPShares === 0) return 0;
    
    const userAccumulated = (userDB.tokenLPShares * poolStateDB.accTokenProviderRewardPerShare) / SCALE;
    const pendingRewards = userAccumulated - userDB.rewardDebt + userDB.pendingRewards;
    
    return pendingRewards;
}
```

### **Constants:**
```javascript
const SCALE = 1e18; // 18 decimal precision
```

## **Database Pool State Required:**
- `accRewardPerShare` - Accumulated rewards per ETH LP share (from DB)
- `accTokenProviderRewardPerShare` - Accumulated rewards per token LP share (from DB)

## **Database User State Required:**
- `ethLPShares` - User's ETH LP shares (from DB)
- `tokenLPShares` - User's token LP shares (from DB)
- `rewardDebt` - User's ETH reward debt (from DB)
- `tokenRewardDebt` - User's token reward debt (from DB)
- `pendingRewards` - User's existing pending ETH rewards (from DB)
- `tokenPendingRewards` - User's existing pending token rewards (from DB)


## **Important Notes:**
- All calculations are performed using data stored in the database, not live contract calls
- Database values should be updated periodically from contract events/state changes
- Ensure database consistency by using transactions when updating related records
- Consider indexing on `user_address` and `pool_address` for efficient queries
