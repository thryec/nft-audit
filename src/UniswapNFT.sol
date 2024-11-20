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

interface IUniswapNFTReceiver {
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

contract UniswapNFT is AccessControlEnumerable, Pausable, ReentrancyGuard {
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

    IWETH public immutable WETH;

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

    enum DEX {
        Uniswap,
        Sushiswap,
        Pancakeswap
    }

    bool private initialized;

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
        address _wethAddress
    ) {
        name = _name;
        version = _version;
        WETH = IWETH(_wethAddress);

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
        revert("Invalid DEX");
    }

    function _getQuoter(DEX dex) internal pure returns (IQuoterV2) {
        if (dex == DEX.Uniswap) return IQuoterV2(UNISWAP_V3_QUOTER);
        if (dex == DEX.Sushiswap) return IQuoterV2(SUSHISWAP_V3_QUOTER);
        if (dex == DEX.Pancakeswap) return IQuoterV2(PANCAKESWAP_V3_QUOTER);
        revert("Invalid DEX");
    }

    function _getFee(DEX dex) internal pure returns (uint24) {
        if (dex == DEX.Uniswap) return UNIV3_FEE;
        if (dex == DEX.Sushiswap) return SUSHIV3_FEE;
        if (dex == DEX.Pancakeswap) return CAKEV3_FEE;
        revert("Invalid DEX");
    }

    function _swapTokensForETH(
        IERC20 token,
        uint256 amountIn,
        uint256 amountOutMinimum,
        DEX dex
    ) internal returns (uint256 amountOut) {
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

    function calculateAmountOutMinimum(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 slippageTolerance,
        DEX dex
    ) public returns (uint256) {
        require(slippageTolerance <= 10000, "Slippage tolerance too high");

        IQuoterV2 quoter = _getQuoter(dex);

        (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        ) = quoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    amountIn: amountIn,
                    sqrtPriceLimitX96: 0
                })
            );

        // Calculate the minimum amount out based on the slippage tolerance
        // Slippage tolerance is in basis points (1 bp = 0.01%)
        uint256 amountOutMinimum = amountOut.mulDiv(
            10000 - slippageTolerance,
            10000
        );

        return amountOutMinimum;
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
            uint24 feeTier = _getFee(dex);
            uint256 amountOutMin = calculateAmountOutMinimum(
                address(asset),
                address(WETH),
                feeTier,
                amount,
                750, // higher slippage tolerance to accomodate pancakeswap pool
                dex
            );
            ethAmount = _swapTokensForETH(asset, amount, amountOutMin, dex);
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
                IUniswapNFTReceiver.receiveApproval.selector,
                approveData
            ),
            "UniswapNFT: rejected"
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
        require(block.timestamp <= deadline, "UniswapNFT: expired deadline");
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, tokenId, spender, nextNonce, deadline)
        );
        bytes32 signingHash = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        address signer = ecrecover(signingHash, v, r, s);
        require(isOwner(tokenId, signer), "UniswapNFT: invalid signature");
        require(!canceledNonces[nextNonce], "UniswapNFT: nonce replay");
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
            "UniswapNFT: transfer to the zero address"
        );
        address msgSender = _msgSender();
        require(isApproved(tokenId, msgSender), "UniswapNFT: not approved");
        require(
            _check(
                tokenId,
                receiver,
                IUniswapNFTReceiver.receiveNFT.selector,
                transferData
            ),
            "UniswapNFT: rejected"
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
            require(success, "UniswapNFT: transfer failed");
        } else {
            console.log("collecting ERC20");
            require(
                asset.transfer(receiver, amount),
                "UniswapNFT: transfer failed"
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
