// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICurveRegistry {
    // Get the number of pools in the registry
    function pool_count() external view returns (uint256);

    // Get the address of a pool by its index
    function pool_list(uint256 i) external view returns (address);

    // Get the number of coins in a pool
    function get_n_coins(address pool) external view returns (uint256);

    // Get the coins in a pool
    function get_coins(address pool) external view returns (address[8] memory);

    // Get the underlying coins in a pool (for metapools)
    function get_underlying_coins(
        address pool
    ) external view returns (address[8] memory);

    // Find a pool for given coins
    function find_pool_for_coins(
        address from,
        address to
    ) external view returns (address);

    // Get the LP token address for a pool
    function get_lp_token(address pool) external view returns (address);

    // Check if a pool is registered
    function is_registered(address pool) external view returns (bool);
}
