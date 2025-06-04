//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract Test is ERC20, Ownable {
    using SafeERC20 for IERC20;
    IUniswapV2Router02 public dexRouter;
    address public dexPair;

    uint256 public liqTriggerAmount = 2e4 ether;
    uint256 public maxTxnLimit;
    uint256 public totalTaxRate;

    uint256 public liqFee;
    uint256 public ethFee;

    uint256 private liqPortion;
    uint256 private ethPortion;

    address public treasuryReceiver;
    bool public tradingEnabled;
    bool private swapping;

    mapping(address => bool) private _isTxLimitExempt;

    modifier swapLock() {
        require(!swapping, "Swap in progress");
        swapping = true;
        _;
        swapping = false;
    }

    event TxLimitUpdated(uint256 limit);
    event TaxRateUpdated(uint256 newRate);
    event TreasuryWithdrawn(address to, uint256 amount);
    event TokenRescue(address token, uint256 amount);
    event TradingActivated(bool enabled);
    event LiquidityTriggered(
        uint256 amountSwapped,
        uint256 tokensAdded,
        uint256 ethAdded
    );
    event ExemptionUpdated(address account, bool isExempt);

    constructor(
        address _router,
        uint256 _initialTaxRate,
        uint256 _ethFee,
        uint256 _liqFee,
        uint256 _maxTxn,
        address _treasury
    ) ERC20("Test", "TEST") Ownable(msg.sender) {
        require(_initialTaxRate >= 100, "Tax rate is too low");
        _mint(_msgSender(), 10_000_000 ether);

        dexRouter = IUniswapV2Router02(_router);
        dexPair = IUniswapV2Factory(dexRouter.factory()).createPair(
            address(this),
            dexRouter.WETH()
        );

        totalTaxRate = _initialTaxRate;
        ethFee = _ethFee;
        liqFee = _liqFee;
        maxTxnLimit = _maxTxn;
        treasuryReceiver = _treasury;

        _isTxLimitExempt[address(this)] = true;
        _isTxLimitExempt[msg.sender] = true;
        _isTxLimitExempt[_router] = true;
        _isTxLimitExempt[dexPair] = true;
    }

    receive() external payable {}

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(amount > 0, "Transfer amount must be greater than 0");

        // Enforce trading and purchase limits
        if (!_isTxLimitExempt[from] || !_isTxLimitExempt[to]) {
            require(tradingEnabled, "Trading is not yet enabled");
        }

        uint256 taxAmount = 0;

        // Enforce max transaction size on buys
        if (
            from == dexPair && to != address(dexRouter) && !_isTxLimitExempt[to]
        ) {
            require(
                amount <= (totalSupply() * maxTxnLimit) / 1e4,
                "Txn exceeds limit"
            );
        }

        // Apply tax on buys and sells if not excluded and not internal
        if (
            (!_isTxLimitExempt[from] || !_isTxLimitExempt[to]) &&
            from != address(this) &&
            (from == dexPair || to == dexPair) &&
            totalTaxRate > 0
        ) {
            taxAmount = (amount * totalTaxRate) / 10_000;
            super._transfer(from, address(this), taxAmount);
        }

        // Trigger liquidity if conditions met
        if (!swapping && to == dexPair && !_isTxLimitExempt[from]) {
            uint256 contractBalance = balanceOf(address(this));
            if (contractBalance >= liqTriggerAmount) {
                uint256 maxSwap = liqTriggerAmount + (liqTriggerAmount / 5);
                if (contractBalance >= maxSwap) {
                    _handleLiquidity(maxSwap);
                } else {
                    _handleLiquidity(liqTriggerAmount);
                }
            }
        }

        super._transfer(from, to, amount - taxAmount);
    }

    function _handleLiquidity(uint256 amount) private swapLock {
        if (ethFee == 0 && liqFee == 0) return;

        uint256 initialETH = address(this).balance;
        uint256 combinedFee = totalTaxRate / 100;
        require(combinedFee > 0, "Invalid tax rate");

        uint256 toETH = (amount * ethFee) / combinedFee;
        uint256 toLiq = (amount * liqFee) / combinedFee;

        uint256 tokensToSwap = toETH + (toLiq / 2);
        uint256 tokensToLiq = toLiq - (toLiq / 2);

        _swapTokensForETH(tokensToSwap);
        uint256 ethGained = address(this).balance - initialETH;

        uint256 ethForLiq = (tokensToSwap > 0)
            ? (ethGained * (toLiq / 2)) / tokensToSwap
            : 0;
        uint256 ethForTreasury = ethGained - ethForLiq;

        if (tokensToLiq > 0 && ethForLiq > 0) {
            _addLiquidity(tokensToLiq, ethForLiq);
        }

        if (ethForTreasury > 0) {
            (bool success, ) = payable(treasuryReceiver).call{
                value: ethForTreasury
            }("");
            require(success, "Treasury transfer failed");
        }

        emit LiquidityTriggered(tokensToSwap, tokensToLiq, ethForLiq);
    }

    function _swapTokensForETH(uint256 tokens) private {
        if (tokens == 0) return;

        address[] memory route = new address[](2);
        route[0] = address(this);
        route[1] = dexRouter.WETH();

        _approve(address(this), address(dexRouter), tokens);
        dexRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokens,
            0,
            route,
            address(this),
            block.timestamp
        );
    }

    function _addLiquidity(uint256 tokens, uint256 eth) private {
        if (tokens == 0 || eth == 0) return;

        _approve(address(this), address(dexRouter), tokens);
        dexRouter.addLiquidityETH{value: eth}(
            address(this),
            tokens,
            0,
            0,
            owner(),
            block.timestamp
        );
    }

    function updateTaxRates(
        uint256 newETHFee,
        uint256 newLiqFee
    ) external onlyOwner {
        uint256 newTotal = newETHFee + newLiqFee;
        require(newTotal > 0, "Total tax rate cannot be zero");
        require(newTotal <= (totalTaxRate / 100), "Tax must be reduced");

        ethFee = newETHFee;
        liqFee = newLiqFee;
        totalTaxRate = newTotal * 100;
        emit TaxRateUpdated(totalTaxRate);
    }

    function activateTrading() external onlyOwner {
        require(!tradingEnabled, "Already active");
        tradingEnabled = true;
        emit TradingActivated(true);
    }

    function setTxnLimit(uint256 newLimit) external onlyOwner {
        maxTxnLimit = newLimit;
        emit TxLimitUpdated(newLimit);
    }

    function rescueETH(address payable recipient) external onlyOwner {
        uint256 amt = address(this).balance;
        require(amt > 0, "No ETH available");
        (bool success, ) = recipient.call{value: amt}("");
        require(success, "ETH transfer failed");
        emit TreasuryWithdrawn(recipient, amt);
    }

    function rescueTokens(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "No tokens available");
        IERC20(token).safeTransfer(owner(), bal);
        emit TokenRescue(token, bal);
    }

    function setExemption(address account, bool exempt) external onlyOwner {
        _isTxLimitExempt[account] = exempt;
        emit ExemptionUpdated(account, exempt);
    }
}
