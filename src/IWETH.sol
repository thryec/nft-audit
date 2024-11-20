// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWETH is IERC20 {
    // Deposit ETH and receive an equal amount of WETH
    function deposit() external payable;

    // Burn WETH and receive an equal amount of ETH
    function withdraw(uint256 amount) external;
}
