# Buggy NFT coding challenge

This repository is a [Foundry](https://github.com/foundry-rs/foundry)
project. Use `forge` to interact.

The sole file in `src/` is the world's worst\* NFT contract. It's not even
ERC721 compatible. But more importantly, it has a huge number of critical
security vulnerabilities. While it does _kinda_ work the way the comments
suggest that it should, there are many ways to get rekt.

## Your task

Your task is 4-fold:

1. Identify some of the ways that you could get rekt (you won't have time to
   identify all of them). Document them with comments in the code.

2. Write unit tests (using Foundry) to exploit 3 bugs. You choose which
   bugs. Choose interesting ones.

3. Improve the NFT so that we can use some forks of UniswapV3 can be used to
   swap tokens for ETH (e.g. PancakeSwapV3, SushiSwapV3, SolidlyV3,
   AlgebraSwap). Do this in a secure way. You may have to fix some bugs to get
   it to work.

4. Improve the NFT so that we can use Curve pools to swap tokens for
   ETH. Remember that pool discovery on-chain for Curve pools is difficult. Also
   remember that Curve pools do not have a homogenous interface for swapping.

\* worstness is subjective