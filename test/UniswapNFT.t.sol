// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/UniswapNFT.sol";
import "../src/MockWETH.sol";

contract MockSwapRouter {
    IERC20 public immutable WETH;

    constructor(address _weth) {
        WETH = IERC20(_weth);
    }

    function exactInputSingle(
        ISwapRouter.ExactInputSingleParams calldata params
    ) external returns (uint256 amountOut) {
        IERC20(params.tokenIn).transferFrom(
            msg.sender,
            address(this),
            params.amountIn
        );
        amountOut = params.amountIn * 2; // Mock implementation: output is double the input
        WETH.transfer(params.recipient, amountOut);
        return amountOut;
    }
}

contract UniswapNFTTestBase is Test {
    IWETH public weth;
    IERC20 public usdc;

    address public constant WETH_ADDRESS =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC_ADDRESS =
        0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 public forkId;

    UniswapNFT public nft;

    address public admin;
    address public user1;
    address public user2;

    function setUp() public virtual {
        admin = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        // Create a fork of mainnet
        forkId = vm.createFork(
            "https://eth-mainnet.g.alchemy.com/v2/hTrg7XqwRN1bcPJ-_h2cw16DrHjYP4Hm"
        );
        vm.selectFork(forkId);

        weth = IWETH(WETH_ADDRESS);
        usdc = IERC20(USDC_ADDRESS);

        vm.startPrank(admin);
        nft = new UniswapNFT("UniswapNFT", "1.0", address(weth));
        nft.initialize();
        vm.stopPrank();

        vm.label(address(nft), "UniswapNFT");
        vm.label(address(weth), "WETH");

        vm.label(user1, "User1");
        vm.label(user2, "User2");
    }

    function mintToken(
        address to,
        uint256 amount,
        UniswapNFT.DEX dex
    ) internal returns (uint256) {
        vm.deal(to, amount);
        vm.prank(to);
        uint256 tokenId = nft.mint{value: amount}(
            IERC20(address(weth)),
            amount,
            dex
        );
        assertEq(nft.isOwner(tokenId, to), true);
        return tokenId;
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

contract UniswapNFTInitializeTest is UniswapNFTTestBase {
    function testInitialize() public {
        assertTrue(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(nft.hasRole(nft.PAUSER_ROLE(), admin));
    }
    function testCannotInitializeTwice() public {
        vm.expectRevert("Contract is already initialized");
        nft.initialize();
    }
}

contract UniswapNFTPauseTest is UniswapNFTTestBase {
    function testPause() public {
        nft.pause();
        assertTrue(nft.paused());
    }
    function testUnpause() public {
        nft.pause();
        nft.unpause();
        assertFalse(nft.paused());
    }
    function testCannotPauseWhenNotPauser() public {
        vm.prank(user1);
        vm.expectRevert();
        nft.pause();
    }
}

contract UniswapNFTMintTest is UniswapNFTTestBase {
    function testMintWithEther() public {
        uint256 amount = 1 ether;
        vm.deal(user1, amount);
        vm.prank(user1);
        uint256 tokenId = nft.mint{value: amount}(
            IERC20(address(weth)),
            amount,
            UniswapNFT.DEX.Uniswap
        );
        assertTrue(nft.isOwner(tokenId, user1));
        assertEq(
            nft.lastPrice(tokenId),
            (amount * (1000 - nft.PROTOCOL_FEE())) / 1000
        );
    }
    function testMintWithToken() public {
        uint256 amount = 1000e6;
        mintUSDC(user1, amount);
        vm.startPrank(user1);
        usdc.approve(address(nft), amount);
        uint256 tokenId = nft.mint(
            IERC20(address(usdc)),
            amount,
            UniswapNFT.DEX.Uniswap
        );
        vm.stopPrank();
        assertTrue(nft.isOwner(tokenId, user1));
    }

    function testETHMintWithDifferentDEXes() public {
        uint256 amount = 1 ether;
        vm.deal(user1, amount * 3);
        vm.startPrank(user1);
        uint256 tokenId1 = nft.mint{value: amount}(
            IERC20(address(weth)),
            amount,
            UniswapNFT.DEX.Uniswap
        );
        uint256 tokenId2 = nft.mint{value: amount}(
            IERC20(address(weth)),
            amount,
            UniswapNFT.DEX.Sushiswap
        );
        uint256 tokenId3 = nft.mint{value: amount}(
            IERC20(address(weth)),
            amount,
            UniswapNFT.DEX.Pancakeswap
        );
        vm.stopPrank();
        assertTrue(nft.isOwner(tokenId1, user1));
        assertTrue(nft.isOwner(tokenId2, user1));
        assertTrue(nft.isOwner(tokenId3, user1));
    }

    function testTokenMintWithDifferentDEXes() public {
        uint256 amount = 1000e6;
        mintUSDC(user1, amount * 3);
        vm.startPrank(user1);
        usdc.approve(address(nft), amount * 3);
        uint256 tokenId1 = nft.mint(
            IERC20(address(usdc)),
            amount,
            UniswapNFT.DEX.Uniswap
        );
        uint256 tokenId2 = nft.mint(
            IERC20(address(usdc)),
            amount,
            UniswapNFT.DEX.Sushiswap
        );
        uint256 tokenId3 = nft.mint(
            IERC20(address(usdc)),
            amount,
            UniswapNFT.DEX.Pancakeswap
        );

        vm.stopPrank();
        assertTrue(nft.isOwner(tokenId1, user1));
        assertTrue(nft.isOwner(tokenId2, user1));
        assertTrue(nft.isOwner(tokenId3, user1));
    }
}

contract UniswapNFTBuyTest is UniswapNFTTestBase {
    uint256 public tokenId;

    function setUp() public override {
        super.setUp();
        tokenId = mintToken(user1, 1 ether, UniswapNFT.DEX.Uniswap);
    }

    function testBuyWithEther() public {
        uint256 buyAmount = 1.2 ether; // price is slightly more than 10% higher than the mint price due to fees
        vm.deal(user2, buyAmount);
        vm.prank(user2);
        nft.buy{value: buyAmount}(
            tokenId,
            IERC20(address(weth)),
            buyAmount,
            UniswapNFT.DEX.Uniswap
        );
        assertTrue(nft.isOwner(tokenId, user2));
    }

    function testBuyWithToken() public {
        uint256 buyAmount = 4000e6;
        mintUSDC(user2, buyAmount);

        vm.startPrank(user2);
        usdc.approve(address(nft), buyAmount);
        nft.buy(
            tokenId,
            IERC20(address(usdc)),
            buyAmount,
            UniswapNFT.DEX.Sushiswap
        );
        vm.stopPrank();
        assertTrue(nft.isOwner(tokenId, user2));
    }

    function testETHBuyWithDifferentDEXes() public {
        uint256 buyAmount = 1.2 ether;
        vm.deal(user2, buyAmount * 3);

        uint256 tokenId1 = mintToken(user1, 1000e6, UniswapNFT.DEX.Uniswap);
        uint256 tokenId2 = mintToken(user1, 1000e6, UniswapNFT.DEX.Sushiswap);
        uint256 tokenId3 = mintToken(user1, 1000e6, UniswapNFT.DEX.Pancakeswap);

        vm.startPrank(user2);
        nft.buy{value: buyAmount}(
            tokenId1,
            IERC20(address(weth)),
            buyAmount,
            UniswapNFT.DEX.Uniswap
        );

        nft.buy{value: buyAmount}(
            tokenId2,
            IERC20(address(weth)),
            buyAmount,
            UniswapNFT.DEX.Sushiswap
        );

        nft.buy{value: buyAmount}(
            tokenId3,
            IERC20(address(weth)),
            buyAmount,
            UniswapNFT.DEX.Pancakeswap
        );
        vm.stopPrank();

        assertTrue(nft.isOwner(tokenId1, user2));
        assertTrue(nft.isOwner(tokenId2, user2));
        assertTrue(nft.isOwner(tokenId3, user2));
    }

    function testTokenBuyWithDifferentDEXes() public {
        uint256 buyAmount = 3000e6;
        mintUSDC(user2, buyAmount * 3);

        uint256 tokenId1 = mintToken(user1, 1000e6, UniswapNFT.DEX.Uniswap);
        uint256 tokenId2 = mintToken(user1, 1000e6, UniswapNFT.DEX.Sushiswap);
        uint256 tokenId3 = mintToken(user1, 1000e6, UniswapNFT.DEX.Pancakeswap);

        vm.startPrank(user2);
        usdc.approve(address(nft), buyAmount * 3);
        nft.buy(
            tokenId1,
            IERC20(address(usdc)),
            buyAmount,
            UniswapNFT.DEX.Uniswap
        );
        nft.buy(
            tokenId2,
            IERC20(address(usdc)),
            buyAmount,
            UniswapNFT.DEX.Sushiswap
        );
        nft.buy(
            tokenId3,
            IERC20(address(usdc)),
            buyAmount,
            UniswapNFT.DEX.Pancakeswap
        );
        vm.stopPrank();

        assertTrue(nft.isOwner(tokenId1, user2));
        assertTrue(nft.isOwner(tokenId2, user2));
        assertTrue(nft.isOwner(tokenId3, user2));
    }
}

contract UniswapNFTBurnTest is UniswapNFTTestBase {
    uint256 public tokenId;

    function setUp() public override {
        super.setUp();
        tokenId = mintToken(user1, 1 ether, UniswapNFT.DEX.Uniswap);
    }

    function testBurn() public {
        uint256 initialBalance = user1.balance;
        vm.prank(user1);
        nft.burn(tokenId);
        assertFalse(nft.isOwner(tokenId, user1));
        assertGt(user1.balance, initialBalance);
    }

    function testCannotBurnIfNotOwner() public {
        vm.prank(user2);
        vm.expectRevert();
        nft.burn(tokenId);
    }
}

contract UniswapNFTApproveTest is UniswapNFTTestBase {
    uint256 public tokenId;

    function setUp() public override {
        super.setUp();
        tokenId = mintToken(user1, 1 ether, UniswapNFT.DEX.Uniswap);
    }

    function testApprove() public {
        vm.prank(user1);
        nft.approve(tokenId, user2, "");
        assertTrue(nft.isApproved(tokenId, user2));
    }

    function testCannotApproveIfNotOwner() public {
        vm.prank(user2);
        vm.expectRevert();
        nft.approve(tokenId, user2, "");
    }
}

contract UniswapNFTPermitTest is UniswapNFTTestBase {
    uint256 public tokenId;
    uint256 private ownerPrivateKey;
    address public owner;

    function setUp() public override {
        super.setUp();
        ownerPrivateKey = 0xA11CE;
        owner = vm.addr(ownerPrivateKey);
        tokenId = mintToken(owner, 1 ether, UniswapNFT.DEX.Uniswap);
    }

    function testPermit() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                nft.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        nft.PERMIT_TYPEHASH(),
                        tokenId,
                        user2,
                        nft.nextNonce(),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        nft.permit(tokenId, user2, deadline, v, r, s);
        assertTrue(nft.isApproved(tokenId, user2));
    }

    function testPermitExpired() public {
        uint256 deadline = block.timestamp - 1 hours; // Expired deadline
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                nft.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        nft.PERMIT_TYPEHASH(),
                        tokenId,
                        user2,
                        nft.nextNonce(),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);
        vm.expectRevert("UniswapNFT: expired deadline");
        nft.permit(tokenId, user2, deadline, v, r, s);
    }

    function testPermitInvalidSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                nft.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        nft.PERMIT_TYPEHASH(),
                        tokenId,
                        user2,
                        nft.nextNonce(),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest); // Different private key
        vm.expectRevert("UniswapNFT: invalid signature");
        nft.permit(tokenId, user2, deadline, v, r, s);
    }
}

contract UniswapNFTTransferTest is UniswapNFTTestBase {
    uint256 public tokenId;

    function setUp() public override {
        super.setUp();
        tokenId = mintToken(user1, 1 ether, UniswapNFT.DEX.Uniswap);
        vm.prank(user1);
        nft.approve(tokenId, user2, "");
    }

    function testTransfer() public {
        vm.prank(user2);
        nft.transfer(tokenId, user2, "");
        assertTrue(nft.isOwner(tokenId, user2));
        assertFalse(nft.isApproved(tokenId, user2));
    }

    function testCannotTransferIfNotApproved() public {
        address user3 = address(0x3);
        vm.prank(user3);
        vm.expectRevert("UniswapNFT: not approved");
        nft.transfer(tokenId, user3, "");
    }

    function testTransferToZeroAddress() public {
        vm.prank(user2);
        vm.expectRevert("UniswapNFT: transfer to the zero address");
        nft.transfer(tokenId, address(0), "");
    }
}
