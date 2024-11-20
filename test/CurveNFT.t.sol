// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/CurveNFT.sol";
import "../src/ICurvePool.sol";
import "../src/ICurveRegistry.sol";
import "../src/MockWETH.sol";
import "../src/MockToken.sol";

contract MockCurvePool is ICurvePool {
    using SafeERC20 for IERC20;

    address[2] public override coins;
    mapping(address => uint256) public balance;
    uint256 public constant DECIMALS = 18;
    uint24 public constant FEE = 4; // 0.04% fee

    constructor(address _token0, address _token1) {
        coins[0] = _token0;
        coins[1] = _token1;
    }

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external payable override returns (uint256) {
        return _exchange(uint256(uint128(i)), uint256(uint128(j)), dx, min_dy);
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external payable override returns (uint256) {
        return _exchange(i, j, dx, min_dy);
    }

    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external override returns (uint256) {
        return _exchange(uint256(uint128(i)), uint256(uint128(j)), dx, min_dy);
    }

    function _exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) internal returns (uint256) {
        require(i < 2 && j < 2 && i != j, "Invalid indices");
        uint256 dy = _get_dy(i, j, dx);
        require(dy >= min_dy, "Slippage too high");

        IERC20(coins[i]).safeTransferFrom(msg.sender, address(this), dx);
        IERC20(coins[j]).safeTransfer(msg.sender, dy);

        balance[coins[i]] += dx;
        balance[coins[j]] -= dy;

        return dy;
    }

    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view override returns (uint256) {
        return _get_dy(uint256(uint128(i)), uint256(uint128(j)), dx);
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view override returns (uint256) {
        return _get_dy(i, j, dx);
    }

    function _get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) internal view returns (uint256) {
        require(i < 2 && j < 2 && i != j, "Invalid indices");
        uint256 xy = balance[coins[i]] * balance[coins[j]];
        uint256 y_new = balance[coins[j]] - (xy / (balance[coins[i]] + dx));
        uint256 dy = balance[coins[j]] - y_new;
        return dy - ((dy * FEE) / 10000); // Apply fee
    }

    function balances(uint256 i) external view override returns (uint256) {
        require(i < 2, "Invalid index");
        return balance[coins[i]];
    }

    function decimals() external pure override returns (uint256) {
        return DECIMALS;
    }

    // Function to add initial liquidity to the mock pool
    function addInitialLiquidity(uint256 amount0, uint256 amount1) external {
        IERC20(coins[0]).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(coins[1]).safeTransferFrom(msg.sender, address(this), amount1);
        balance[coins[0]] = amount0;
        balance[coins[1]] = amount1;
    }

    function fee() external pure override returns (uint24) {
        return FEE;
    }
}
// contract MockCurveRegistry is ICurveRegistry {
//     mapping(address => address) public poolForPair;
//     mapping(address => uint256) public nCoins;

//     function setPoolForPair(
//         address token,
//         address weth,
//         address pool
//     ) external {
//         poolForPair[token] = pool;
//     }

//     function setNCoins(address pool, uint256 _nCoins) external {
//         nCoins[pool] = _nCoins;
//     }

//     function find_pool_for_coins(
//         address from,
//         address to
//     ) external view override returns (address) {
//         return poolForPair[from];
//     }

//     function get_n_coins(
//         address pool
//     ) external view override returns (uint256) {
//         return nCoins[pool];
//     }

//     function pool_count() external view override returns (uint256) {
//         revert("Not implemented");
//     }

//     function pool_list(uint256 i) external view override returns (address) {
//         revert("Not implemented");
//     }

//     function get_coins(
//         address pool
//     ) external view override returns (address[8] memory) {
//         revert("Not implemented");
//     }

//     function get_underlying_coins(
//         address pool
//     ) external view override returns (address[8] memory) {
//         revert("Not implemented");
//     }

//     function get_lp_token(
//         address pool
//     ) external view override returns (address) {
//         revert("Not implemented");
//     }

//     function is_registered(address pool) external view override returns (bool) {
//         revert("Not implemented");
//     }
// }

contract CurveNFTTestBase is Test {
    CurveNFT nft;
    ICurveMetaRegistry public curveMetaRegistry;

    IWETH public weth;
    IERC20 public usdc;

    address public constant WETH_ADDRESS =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC_ADDRESS =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant CURVE_META_REGISTRY =
        0xF98B45FA17DE75FB1aD0e7aFD971b0ca00e379fC;

    address owner = address(this);
    address user1 = address(0x2);
    address user2 = address(0x3);

    function setUp() public {
        // Create a fork of mainnet

        vm.createSelectFork(
            "https://eth-mainnet.g.alchemy.com/v2/hTrg7XqwRN1bcPJ-_h2cw16DrHjYP4Hm"
        );

        curveMetaRegistry = ICurveMetaRegistry(CURVE_META_REGISTRY);
        weth = IWETH(WETH_ADDRESS);
        usdc = IERC20(USDC_ADDRESS);

        vm.startPrank(owner);

        nft = new CurveNFT(
            "TestNFT",
            "TNFT",
            WETH_ADDRESS,
            CURVE_META_REGISTRY
        );
        nft.initialize();

        // hardcode as tricrypto pool first for testing
        address curvePool = 0x7F86Bf177Dd4F3494b841a37e810A34dD56c829B;

        require(
            curvePool != address(0),
            "No Curve pool found for USDC-WETH pair"
        );

        // Set Curve pool for USDC in the NFT contract
        nft.setCurvePool(IERC20(USDC_ADDRESS), curvePool);

        vm.stopPrank();
    }

    function mintUSDC(address to, uint256 amount) internal {
        uint256 balanceBefore = usdc.balanceOf(to);

        address whale = 0x7713974908Be4BEd47172370115e8b1219F4A5f0; // Example USDC whale

        vm.startPrank(whale);
        usdc.transfer(to, amount); // Transfer USDC from the whale to the target address

        vm.stopPrank();

        uint256 balanceAfter = usdc.balanceOf(to);
        assertEq(balanceAfter, balanceBefore + amount, "USDC minting failed");
    }
}

// contract CurveNFTInitializeTest is CurveNFTTestBase {
//     function testInitialize() public {
//         assertTrue(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), owner));
//         assertTrue(nft.hasRole(nft.PAUSER_ROLE(), owner));
//     }
//     function testCannotInitializeTwice() public {
//         vm.expectRevert("Contract is already initialized");
//         nft.initialize();
//     }
// }

// contract CurveNFTPauseTest is CurveNFTTestBase {
//     function testPause() public {
//         nft.pause();
//         assertTrue(nft.paused());
//     }
//     function testUnpause() public {
//         nft.pause();
//         nft.unpause();
//         assertFalse(nft.paused());
//     }
//     function testCannotPauseWhenNotPauser() public {
//         vm.prank(user1);
//         vm.expectRevert();
//         nft.pause();
//     }
// }

contract CurveNFTMintTest is CurveNFTTestBase {
    function testMintWithETH() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        uint256 tokenId = nft.mint{value: 1 ether}(
            IERC20(address(weth)),
            1 ether,
            CurveNFT.DEX.Curve
        );

        assertTrue(nft.isOwner(tokenId, user1));
        assertEq(nft.lastPrice(tokenId), 0.995 ether); // Accounting for 5% protocol fee
    }

    // function testMintWithToken() public {
    //     uint256 amount = 1000e6;
    //     mintUSDC(user1, amount);

    //     vm.deal(address(nft), 1 ether);

    //     vm.startPrank(user1);
    //     usdc.approve(address(nft), amount);

    //     uint256 tokenId = nft.mint(
    //         IERC20(address(usdc)),
    //         amount,
    //         CurveNFT.DEX.Curve
    //     );
    //     console.log("minted");
    //     vm.stopPrank();

    //     assertTrue(nft.isOwner(tokenId, user1));
    //     // assertEq(nft.lastPrice(tokenId), 0.931 ether); // Accounting for 5% protocol fee and 2% Curve slippage
    // }
}

// contract CurveNFTBuyTest is CurveNFTTestBase {
//     function testBuyWithETH() public {
//         // First, mint an NFT
//         vm.deal(user1, 1 ether);
//         vm.prank(user1);
//         uint256 tokenId = nft.mint{value: 1 ether}(
//             IERC20(address(weth)),
//             1 ether,
//             CurveNFT.DEX.Curve
//         );

//         // Now, user2 buys the NFT
//         vm.deal(user2, 1.5 ether);
//         vm.prank(user2);
//         nft.buy{value: 1.5 ether}(
//             tokenId,
//             IERC20(address(weth)),
//             1.5 ether,
//             CurveNFT.DEX.Curve
//         );

//         assertTrue(nft.isOwner(tokenId, user2));
//         assertEq(nft.lastPrice(tokenId), 1.425 ether); // Accounting for 5% protocol fee
//     }

//     function testBuyWithToken() public {
//         // First, mint an NFT
//         vm.deal(user1, 1 ether);
//         vm.prank(user1);
//         uint256 tokenId = nft.mint{value: 1 ether}(
//             IERC20(address(weth)),
//             1 ether,
//             CurveNFT.DEX.Curve
//         );

//         // Now, user2 buys the NFT with tokens
//         vm.startPrank(user2);
//         mockToken.mint(user2, 1.5 ether); // Mint tokens for user2
//         mockToken.approve(address(nft), 1.5 ether);
//         nft.buy(
//             tokenId,
//             IERC20(address(mockToken)),
//             1.5 ether,
//             CurveNFT.DEX.Curve
//         );
//         vm.stopPrank();

//         assertTrue(nft.isOwner(tokenId, user2));
//         assertEq(nft.lastPrice(tokenId), 1.3965 ether); // Accounting for 5% protocol fee and 2% Curve slippage
//     }
// }

// contract CurveNFTBurnTest is CurveNFTTestBase {
//     function testBurn() public {
//         vm.deal(user1, 1 ether);
//         vm.startPrank(user1);
//         uint256 tokenId = nft.mint{value: 1 ether}(
//             IERC20(address(weth)),
//             1 ether,
//             CurveNFT.DEX.Curve
//         );
//         uint256 balanceBefore = user1.balance;
//         nft.burn(tokenId);
//         vm.stopPrank();

//         assertFalse(nft.isOwner(tokenId, user1));
//         assertEq(user1.balance, balanceBefore + 0.95 ether); // User gets back the last price
//     }

//     function testFailBuyWithInsufficientAmount() public {
//         vm.deal(user1, 1 ether);
//         vm.prank(user1);
//         uint256 tokenId = nft.mint{value: 1 ether}(
//             IERC20(address(weth)),
//             1 ether,
//             CurveNFT.DEX.Curve
//         );

//         vm.deal(user2, 0.5 ether);
//         vm.prank(user2);
//         nft.buy{value: 0.5 ether}(
//             tokenId,
//             IERC20(address(weth)),
//             0.5 ether,
//             CurveNFT.DEX.Curve
//         );
//     }

//     function testFailBurnNonowner() public {
//         vm.deal(user1, 1 ether);
//         vm.prank(user1);
//         uint256 tokenId = nft.mint{value: 1 ether}(
//             IERC20(address(weth)),
//             1 ether,
//             CurveNFT.DEX.Curve
//         );

//         vm.prank(user2);
//         nft.burn(tokenId);
//     }

//     function testCollectFees() public {
//         vm.deal(user1, 2 ether);
//         vm.startPrank(user1);
//         nft.mint{value: 1 ether}(
//             IERC20(address(weth)),
//             1 ether,
//             CurveNFT.DEX.Curve
//         );
//         nft.mint{value: 1 ether}(
//             IERC20(address(weth)),
//             1 ether,
//             CurveNFT.DEX.Curve
//         );
//         vm.stopPrank();

//         vm.prank(owner);
//         uint256 balanceBefore = owner.balance;
//         nft.collect(payable(owner), IERC20(address(weth)));

//         assertEq(owner.balance, balanceBefore + 0.1 ether); // 5% fee from 2 ETH
//     }
// }
