// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GradientVesting} from "../GradientVesting.sol";

/// @title ReentrantTester
/// @notice A test contract for testing reentrancy protection
/// @dev This contract attempts to test reentrancy vulnerabilities in a controlled manner
contract ReentrantTester {
    using SafeERC20 for IERC20;

    GradientVesting public vesting;
    IERC20 public token;
    bool public hasReentered = false;

    constructor(address _vesting, address _token) {
        vesting = GradientVesting(payable(_vesting));
        token = IERC20(_token);
    }

    function testReentrancy() external {
        // Approve the vesting contract to spend tokens
        token.approve(address(vesting), type(uint256).max);
        vesting.depositToken(100 * 10 ** 18);
    }

    // This would be called during the deposit if reentrancy was possible
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        if (!hasReentered) {
            hasReentered = true;
            vesting.depositToken(100 * 10 ** 18);
        }
        return this.onERC721Received.selector;
    }
}
