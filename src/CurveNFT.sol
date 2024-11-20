// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import "forge-std/console.sol";

import "./ICurvePool.sol";
import "./ICurveRegistry.sol";

interface ICurveMetaRegistry {
    function find_pool_for_coins(
        address from,
        address to
    ) external view returns (address);

    function find_pools_for_coins(
        address from,
        address to
    ) external view returns (address[] memory);

    function get_coins(address pool) external view returns (address[8] memory);
    function get_balances(
        address pool
    ) external view returns (uint256[8] memory);
}

interface ICurveNFTReceiver {
    function receiveApproval(
        uint256 tokenId,
        address owner
    ) external returns (bytes4);
    function receiveNFT(
        uint256 tokenId,
        address owner
    ) external returns (bytes4);
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract CurveNFT is AccessControlEnumerable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using Math for uint256;

    uint256 public nextNonce;
    mapping(IERC20 => uint256) public feesCollected;
    mapping(uint256 => uint256) public lastPrice;
    mapping(uint256 => bool) public canceledNonces;
    mapping(uint256 => bool) public tokenExists;

    uint256 public constant PROTOCOL_FEE = 5;
    uint256 public constant PROTOCOL_FEE_BASIS = 1000;
    uint256 public constant PRICE_INCREMENT = 1;
    uint256 public constant PRICE_INCREMENT_BASIS = 10;
    uint256 public constant SELLER_FEE = 1;
    uint256 public constant SELLER_FEE_BASIS = 5;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32 public DOMAIN_SEPARATOR;

    event Mint(uint256 indexed tokenId, address indexed owner);
    event Burn(uint256 indexed tokenId, address indexed owner);
    event Transfer(
        address indexed owner,
        address indexed receiver,
        uint256 indexed tokenId
    );
    event Approve(uint256 indexed tokenId, address indexed spender);
    event Collect(
        IERC20 indexed asset,
        address indexed receiver,
        uint256 amount
    );

    address private constant UNISWAP_V3_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address private constant SUSHISWAP_V3_ROUTER =
        0x2E6cd2d30aa43f40aa81619ff4b6E0a41479B13F;
    address private constant PANCAKESWAP_V3_ROUTER =
        0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    address private constant UNISWAP_V3_QUOTER =
        0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address private constant SUSHISWAP_V3_QUOTER =
        0x64e8802FE490fa7cc61d3463958199161Bb608A7;
    address private constant PANCAKESWAP_V3_QUOTER =
        0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    ISwapRouter private constant uniswapRouter = ISwapRouter(UNISWAP_V3_ROUTER);
    ISwapRouter private constant sushiswapRouter =
        ISwapRouter(SUSHISWAP_V3_ROUTER);
    ISwapRouter private constant pancakeswapRouter =
        ISwapRouter(PANCAKESWAP_V3_ROUTER);

    uint24 public constant UNIV3_FEE = 3000;
    uint24 public constant SUSHIV3_FEE = 3000;
    uint24 public constant CAKEV3_FEE = 500;

    string public name;
    string public version;

    bool private initialized;

    IWETH public immutable WETH;

    ICurveMetaRegistry public immutable curveMetaRegistry;
    mapping(IERC20 => address) public curvePoolForToken;

    enum DEX {
        Uniswap,
        Sushiswap,
        Pancakeswap,
        Curve
    }

    struct PoolInfo {
        address poolAddress;
        uint256 wethBalance;
        uint256 usdcBalance;
    }

    modifier initializer() {
        require(!initialized, "Contract is already initialized");
        _;
        initialized = true;
    }

    modifier whenInitialized() {
        require(initialized, "Contract is not initialized");
        _;
    }

    constructor(
        string memory _name,
        string memory _version,
        address _wethAddress,
        address _curveMetaRegistryAddress
    ) {
        name = _name;
        version = _version;
        WETH = IWETH(_wethAddress);
        curveMetaRegistry = ICurveMetaRegistry(_curveMetaRegistryAddress);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _updateDomainSeparator();
    }

    function initialize() external initializer onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    function _updateDomainSeparator() internal {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );
    }

    function _ownerRole(uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("OWNER_ROLE", tokenId));
    }

    function _approvedRole(uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("APPROVED_ROLE", tokenId));
    }

    function pause()
        external
        whenNotPaused
        whenInitialized
        onlyRole(PAUSER_ROLE)
    {
        _pause();
    }

    function unpause()
        external
        whenPaused
        whenInitialized
        onlyRole(PAUSER_ROLE)
    {
        _unpause();
    }

    function isOwner(
        uint256 tokenId,
        address account
    ) public view returns (bool) {
        return hasRole(_ownerRole(tokenId), account);
    }

    function isApproved(
        uint256 tokenId,
        address account
    ) public view returns (bool) {
        return hasRole(_approvedRole(tokenId), account);
    }

    function _check(
        uint256 tokenId,
        address receiver,
        bytes4 selector,
        bytes calldata data
    ) internal returns (bool) {
        if (receiver.code.length == 0) {
            return true;
        }
        if (data.length == 0) {
            (bool success, bytes memory returnData) = receiver.call(
                abi.encodeWithSelector(selector, tokenId, _msgSender())
            );
            return
                success &&
                returnData.length == 4 &&
                abi.decode(returnData, (bytes4)) == selector;
        } else {
            (bool success, ) = receiver.call(data);
            return success;
        }
    }

    function _nextPrice(uint256 tokenId) internal view returns (uint256) {
        require(tokenExists[tokenId], "Token does not exist");
        return
            (lastPrice[tokenId] * (PRICE_INCREMENT + PRICE_INCREMENT_BASIS)) /
            PRICE_INCREMENT_BASIS;
    }

    function _getRouter(DEX dex) internal pure returns (ISwapRouter) {
        if (dex == DEX.Uniswap) return ISwapRouter(UNISWAP_V3_ROUTER);
        if (dex == DEX.Sushiswap) return ISwapRouter(SUSHISWAP_V3_ROUTER);
        if (dex == DEX.Pancakeswap) return ISwapRouter(PANCAKESWAP_V3_ROUTER);
        revert("Invalid DEX for router");
    }

    function _getQuoter(DEX dex) internal pure returns (IQuoterV2) {
        if (dex == DEX.Uniswap) return IQuoterV2(UNISWAP_V3_QUOTER);
        if (dex == DEX.Sushiswap) return IQuoterV2(SUSHISWAP_V3_QUOTER);
        if (dex == DEX.Pancakeswap) return IQuoterV2(PANCAKESWAP_V3_QUOTER);
        revert("Invalid DEX for quoter");
    }

    function _getFee(DEX dex) internal pure returns (uint24) {
        if (dex == DEX.Uniswap) return UNIV3_FEE;
        if (dex == DEX.Sushiswap) return SUSHIV3_FEE;
        if (dex == DEX.Pancakeswap) return CAKEV3_FEE;
        revert("Invalid DEX for fee");
    }

    // New function to set Curve pool for a token
    function setCurvePool(
        IERC20 token,
        address poolAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        curvePoolForToken[token] = poolAddress;
    }

    function getCurvePoolFee(IERC20 token) internal view returns (uint24) {
        address poolAddress = curvePoolForToken[token];
        uint256 fee = ICurvePool(poolAddress).fee();

        // adjust to same fee basis as uniswap v3
        uint24 adjustedFee = uint24((fee * 100) / 1_000_000);
        console.log("adjusted fee: ", adjustedFee);
        return adjustedFee;
    }

    function _swapTokensForETH(
        IERC20 token,
        uint256 amountIn,
        uint256 amountOutMinimum,
        DEX dex
    ) internal returns (uint256 amountOut) {
        if (dex == DEX.Curve) {
            return _swapTokensForETHViaCurve(token, amountIn, amountOutMinimum);
        } else {
            ISwapRouter router = _getRouter(dex);
            uint256 balance = token.balanceOf(address(this));
            require(balance >= amountIn, "Insufficient token balance");

            token.approve(address(router), amountIn);
            uint24 feeTier = _getFee(dex);

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
                .ExactInputSingleParams({
                    tokenIn: address(token),
                    tokenOut: address(WETH),
                    fee: feeTier,
                    recipient: address(this),
                    deadline: block.timestamp + 15 minutes,
                    amountIn: amountIn,
                    amountOutMinimum: amountOutMinimum,
                    sqrtPriceLimitX96: 0
                });
            amountOut = router.exactInputSingle(params);
            WETH.withdraw(amountOut);
            return amountOut;
        }
    }

    // New function to swap tokens for ETH via Curve
    function _swapTokensForETHViaCurve(
        IERC20 token,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) internal returns (uint256 amountOut) {
        address poolAddress = curvePoolForToken[token];

        if (poolAddress == address(0)) {
            poolAddress = curveMetaRegistry.find_pool_for_coins(
                address(token),
                address(WETH)
            );
            require(
                poolAddress != address(0),
                "No Curve pool found for token pair"
            );
            curvePoolForToken[token] = poolAddress;
        }

        ICurvePool pool = ICurvePool(poolAddress);
        uint256 balance = token.balanceOf(address(this));
        require(balance >= amountIn, "Insufficient token balance");

        token.approve(poolAddress, amountIn);

        // check pool balances
        uint256 usdcBalance = pool.balances(0);
        uint256 wethBalance = pool.balances(2);

        console.log("usdc balance: ", usdcBalance);
        console.log("weth balance: ", wethBalance);

        int128 i = -1;
        int128 j = -1;
        uint256 nCoins = 3;
        for (uint256 k = 0; k < nCoins; k++) {
            address coin = pool.coins(k);
            if (coin == address(token)) {
                i = int128(uint128(k));
            }
            if (coin == address(WETH)) {
                j = int128(uint128(k));
            }
        }
        require(i != -1 && j != -1, "Token pair not found in the pool");

        console.log("calling exchange");

        amountOut = pool.exchange_underlying(i, j, amountIn, amountOutMinimum);
        WETH.withdraw(amountOut);
        return amountOut;
    }

    function calculateAmountOutMinimum(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 slippageTolerance,
        DEX dex
    ) public returns (uint256) {
        require(slippageTolerance <= 10000, "Slippage tolerance too high");

        if (dex == DEX.Curve) {
            return
                _calculateCurveAmountOutMinimum(
                    IERC20(tokenIn),
                    amountIn,
                    slippageTolerance,
                    fee
                );
        } else {
            IQuoterV2 quoter = _getQuoter(dex);

            (uint256 amountOut, , , ) = quoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    amountIn: amountIn,
                    sqrtPriceLimitX96: 0
                })
            );

            return amountOut.mulDiv(10000 - slippageTolerance, 10000);
        }
    }

    // New function to calculate amount out minimum for Curve
    function _calculateCurveAmountOutMinimum(
        IERC20 tokenIn,
        uint256 amountIn,
        uint256 slippageTolerance,
        uint24 fee
    ) internal view returns (uint256) {
        address poolAddress = curvePoolForToken[tokenIn];
        if (poolAddress == address(0)) {
            poolAddress = curveMetaRegistry.find_pool_for_coins(
                address(WETH),
                address(tokenIn)
            );

            PoolInfo[] memory pools = getCurveTokenPools(
                address(WETH),
                address(tokenIn)
            );

            poolAddress = pools[3].poolAddress;

            require(
                poolAddress != address(0),
                "No Curve pool found for token pair"
            );
        }

        ICurvePool pool = ICurvePool(poolAddress);
        console.log("pool address:", poolAddress);

        int128 i = -1;
        int128 j = -1;
        uint256 nCoins = 3; // Assuming 2 coins for simplicity, adjust if needed
        for (uint256 k = 0; k < nCoins; k++) {
            address coin = pool.coins(k);
            if (coin == address(tokenIn)) {
                i = int128(uint128(k));
            }
            if (coin == address(WETH)) {
                j = int128(uint128(k));
            }
        }

        uint256 amountOut;
        try
            pool.get_dy(uint256(uint128(i)), uint256(uint128(j)), amountIn)
        returns (uint256 _amountOut) {
            amountOut = _amountOut;
            console.log("get dy amount out:", amountOut);
        } catch {
            try pool.get_dy(i, j, amountIn) returns (uint256 _amountOut) {
                amountOut = _amountOut;
            } catch {
                // Fallback to a simple estimation if both get_dy calls fail
                amountOut = _estimateAmountOut(
                    pool,
                    uint256(uint128(i)),
                    uint256(uint128(j)),
                    amountIn
                );
                console.log("estimated amount out:", amountOut);
            }
        }

        uint256 feeAmount = (amountOut * fee) / 1e6;
        amountOut -= feeAmount;

        return (amountOut * (10000 - slippageTolerance)) / 10000;
    }

    function _estimateAmountOut(
        ICurvePool pool,
        uint256 i,
        uint256 j,
        uint256 amountIn
    ) internal view returns (uint256) {
        uint256 balanceIn = pool.balances(i);
        uint256 balanceOut = pool.balances(j);

        uint256 decimals;
        try pool.decimals() returns (uint256 _decimals) {
            decimals = _decimals;
        } catch {
            decimals = 18;
        }

        balanceIn = balanceIn * 10 ** (18 - decimals);
        balanceOut = balanceOut * 10 ** (18 - decimals);

        // new_y = (x * y) / (x + dx)
        uint256 amountOut = (balanceOut * amountIn) / (balanceIn + amountIn);

        return (amountOut * 98) / 100; // 2% safety margin
    }

    function getCurveTokenPools(
        address weth,
        address token
    ) internal view returns (PoolInfo[] memory) {
        console.log("call get curve token pools");
        address[] memory poolAddresses;

        // address[] memory poolAddresses = curveMetaRegistry.find_pools_for_coins(
        //     weth,
        //     token
        // );

        try curveMetaRegistry.find_pools_for_coins(token, weth) returns (
            address[] memory _poolAddresses
        ) {
            poolAddresses = _poolAddresses;
        } catch {
            console.log("error finding pools");
            return new PoolInfo[](0);
        }

        console.log("found pools");
        PoolInfo[] memory pools = new PoolInfo[](poolAddresses.length);
        uint256 validPoolCount = 0;

        for (uint256 i = 0; i < poolAddresses.length; i++) {
            (
                bool isValid,
                uint256 wethBalance,
                uint256 usdcBalance
            ) = validatePool(poolAddresses[i], weth, token);
            if (isValid) {
                pools[validPoolCount] = PoolInfo(
                    poolAddresses[i],
                    wethBalance,
                    usdcBalance
                );
                validPoolCount++;
            }
        }

        // Create a new array with only the valid pools
        PoolInfo[] memory validPools = new PoolInfo[](validPoolCount);
        for (uint256 i = 0; i < validPoolCount; i++) {
            validPools[i] = pools[i];
        }

        return validPools;
    }

    function validatePool(
        address pool,
        address weth,
        address token
    ) internal view returns (bool, uint256, uint256) {
        console.log("validating pool: ");
        address[8] memory coins = curveMetaRegistry.get_coins(pool);
        uint256[8] memory balances = curveMetaRegistry.get_balances(pool);

        uint256 wethIndex = type(uint256).max;
        uint256 tokenIndex = type(uint256).max;

        for (uint256 i = 0; i < 8; i++) {
            if (coins[i] == weth) wethIndex = i;
            if (coins[i] == token) tokenIndex = i;
            if (
                wethIndex != type(uint256).max &&
                tokenIndex != type(uint256).max
            ) break;
        }

        if (wethIndex == type(uint256).max || tokenIndex == type(uint256).max) {
            return (false, 0, 0);
        }

        uint256 wethBalance = balances[wethIndex];
        uint256 tokenBalance = balances[tokenIndex];

        // Convert token balance to 18 decimals for consistency
        tokenBalance = tokenBalance * 10 ** 12;

        // Check if balances are above a minimum threshold (e.g., 1 WETH and 1000 token)
        if (wethBalance > 1e18 && tokenBalance > 1000e18) {
            return (true, wethBalance, tokenBalance);
        }

        return (false, 0, 0);
    }

    function buy(
        uint256 tokenId,
        IERC20 asset,
        uint256 amount,
        DEX dex
    ) external payable whenNotPaused nonReentrant whenInitialized {
        require(tokenExists[tokenId], "Token does not exist");
        require(address(asset) != address(0) && amount > 0, "Invalid input");

        address oldOwner = getRoleMember(_ownerRole(tokenId), 0);
        uint256 oldPrice = lastPrice[tokenId];
        address msgSender = _msgSender();

        uint256 ethAmount;
        if (address(asset) == address(WETH)) {
            require(msg.value == amount, "Amount/value mismatch");
            ethAmount = amount;
        } else {
            require(msgSender.code.length == 0, "No flash loan");
            asset.safeTransferFrom(msgSender, address(this), amount);
            ethAmount = _swapTokensForETH(asset, amount, oldPrice, dex);
        }

        require(ethAmount > oldPrice, "Amount must be greater than old price");
        uint256 ethFee = ((ethAmount - oldPrice) * PROTOCOL_FEE) /
            PROTOCOL_FEE_BASIS;
        uint256 sellerFee = ((ethAmount - oldPrice) * SELLER_FEE) /
            SELLER_FEE_BASIS;
        uint256 newPrice = ethAmount - ethFee - sellerFee;

        require(newPrice >= _nextPrice(tokenId), "Not enough");

        feesCollected[IERC20(address(WETH))] += ethFee;

        (bool success, ) = payable(oldOwner).call{value: oldPrice + sellerFee}(
            ""
        );
        require(success, "Transfer to old owner failed");

        bytes32 ownerRole = _ownerRole(tokenId);
        _revokeRole(ownerRole, oldOwner);
        _grantRole(ownerRole, msgSender);
        lastPrice[tokenId] = newPrice;
    }

    function mint(
        IERC20 asset,
        uint256 amount,
        DEX dex
    )
        external
        payable
        whenNotPaused
        nonReentrant
        whenInitialized
        returns (uint256 mintedTokenId)
    {
        address msgSender = _msgSender();
        uint256 tokenId = uint256(
            keccak256(
                abi.encodePacked(
                    address(this),
                    block.prevrandao,
                    msgSender,
                    nextNonce
                )
            )
        );

        uint256 ethAmount;
        if (address(asset) == address(WETH)) {
            require(msg.value == amount, "Amount/value mismatch");
            ethAmount = amount;
        } else {
            require(msgSender.code.length == 0, "No flash loan");
            asset.safeTransferFrom(msgSender, address(this), amount);

            uint24 curveFee = getCurvePoolFee(asset);

            uint256 amountOutMin = calculateAmountOutMinimum(
                address(asset),
                address(WETH),
                dex == DEX.Curve ? curveFee : _getFee(dex),
                amount,
                1000, // higher slippage tolerance for curve pool
                dex
            );

            console.log("amount out min: ", amountOutMin);

            if (dex == DEX.Curve) {
                ethAmount = _swapTokensForETHViaCurve(
                    asset,
                    amount,
                    amountOutMin
                );
            } else {
                ethAmount = _swapTokensForETH(asset, amount, amountOutMin, dex);
            }
        }
        uint256 fee = (ethAmount * PROTOCOL_FEE) / PROTOCOL_FEE_BASIS;
        feesCollected[IERC20(address(WETH))] += fee;
        ethAmount -= fee;
        _grantRole(_ownerRole(tokenId), msgSender);
        lastPrice[tokenId] = ethAmount;
        tokenExists[tokenId] = true;
        nextNonce++;
        emit Mint(tokenId, msgSender);
        return tokenId;
    }

    function burn(
        uint256 tokenId
    )
        external
        onlyRole(_ownerRole(tokenId))
        whenNotPaused
        nonReentrant
        whenInitialized
    {
        address msgSender = _msgSender();
        _revokeRole(_ownerRole(tokenId), msgSender);
        (bool success, ) = payable(msgSender).call{value: lastPrice[tokenId]}(
            ""
        );
        require(success, "Transfer failed");
        delete tokenExists[tokenId];
        emit Burn(tokenId, msgSender);
    }

    function approve(
        uint256 tokenId,
        address spender,
        bytes calldata approveData
    ) external onlyRole(_ownerRole(tokenId)) whenNotPaused whenInitialized {
        require(
            _check(
                tokenId,
                spender,
                ICurveNFTReceiver.receiveApproval.selector,
                approveData
            ),
            "CurveNFT: rejected"
        );
        _grantRole(_approvedRole(tokenId), spender);
        emit Approve(tokenId, spender);
    }

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256(
            "Permit(uint256 tokenId,address spender,uint256 nonce,uint256 deadline)"
        );

    function permit(
        uint256 tokenId,
        address spender,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused whenInitialized {
        require(block.timestamp <= deadline, "CurveNFT: expired deadline");
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, tokenId, spender, nextNonce, deadline)
        );
        bytes32 signingHash = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        address signer = ecrecover(signingHash, v, r, s);
        require(isOwner(tokenId, signer), "CurveNFT: invalid signature");
        require(!canceledNonces[nextNonce], "CurveNFT: nonce replay");
        canceledNonces[nextNonce] = true;
        nextNonce++;
        _grantRole(_approvedRole(tokenId), spender);
    }

    function transfer(
        uint256 tokenId,
        address receiver,
        bytes calldata transferData
    ) external whenNotPaused whenInitialized {
        require(
            receiver != address(0),
            "CurveNFT: transfer to the zero address"
        );
        address msgSender = _msgSender();
        require(isApproved(tokenId, msgSender), "CurveNFT: not approved");
        require(
            _check(
                tokenId,
                receiver,
                ICurveNFTReceiver.receiveNFT.selector,
                transferData
            ),
            "CurveNFT: rejected"
        );
        _revokeRole(_ownerRole(tokenId), msgSender);
        _grantRole(_ownerRole(tokenId), receiver);
        _revokeRole(_approvedRole(tokenId), msgSender);
        emit Transfer(msgSender, receiver, tokenId);
    }

    function collect(
        address payable receiver,
        IERC20 asset
    )
        external
        whenNotPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        whenInitialized
    {
        uint256 amount = feesCollected[asset];
        if (address(asset) == address(0)) {
            console.log("collecting ETH");
            (bool success, ) = receiver.call{value: amount}("");
            require(success, "CurveNFT: transfer failed");
        } else {
            console.log("collecting ERC20");
            require(
                asset.transfer(receiver, amount),
                "CurveNFT: transfer failed"
            );
        }
        emit Collect(asset, receiver, amount);
        delete feesCollected[asset];
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        IERC20 sellToken = abi.decode(data, (IERC20));
        if (amount0Delta > 0) {
            require(address(sellToken) < address(WETH), "Invalid token order");
            require(
                sellToken.transferFrom(
                    msg.sender,
                    msg.sender,
                    uint256(amount0Delta)
                ),
                "Transfer failed"
            );
        } else {
            require(address(sellToken) > address(WETH), "Invalid token order");
            require(amount1Delta > 0, "Invalid amount");
            require(
                sellToken.transferFrom(
                    msg.sender,
                    msg.sender,
                    uint256(amount1Delta)
                ),
                "Transfer failed"
            );
        }
    }

    receive() external payable {}
}
