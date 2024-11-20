// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import "forge-std/console.sol";

interface IBuggyNFTReceiver {
    function receiveApproval(
        uint256 tokenId,
        address owner
    ) external returns (bytes4);
    function receiveNFT(
        uint256 tokenId,
        address owner
    ) external returns (bytes4);
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IUniswapV3Callback {
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}

interface IUniswapV3Quoter {
    function quoteExactInputSingle(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

// NOTE: quoter can be set as immutable
IUniswapV3Quoter constant QUOTER = IUniswapV3Quoter(
    0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6
);

uint24 constant UNIV3_FEE = 3000;

interface IWeth is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}
IWeth constant WETH = IWeth(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // BUG: should ideally set this in constructor as it may be differ for different chains

// BUG: address(0) is not a real contract, any interaction with it will revert because there is no code in address(0)
IERC20 constant ETHER = IERC20(address(0));

contract BuggyNFT is AccessControlEnumerable, Pausable, IUniswapV3Callback {
    uint256 public nextNonce;
    mapping(IERC20 => uint256) public feesCollected;
    mapping(uint256 => uint256) public lastPrice;
    mapping(uint256 => bool) public canceledNonces;

    uint256 public constant PROTOCOL_FEE = 5;
    uint256 public constant PROTOCOL_FEE_BASIS = 1000;
    uint256 public constant PRICE_INCREMENT = 1;
    uint256 public constant PRICE_INCREMENT_BASIS = 10;
    uint256 public constant SELLER_FEE = 1;
    uint256 public constant SELLER_FEE_BASIS = 5;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bytes32 public immutable DOMAIN_SEPARATOR;

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

    // BUG: Domain Separator should ideally be dynamic to accomodate multiple chains, and not set as an immutable variable in the constructor
    constructor() {
        // EIP712-compatible domain separator. Used for `permit`
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 nameHash = keccak256("BuggyNFT"); // BUG: ideally name should not be hardcoded
        bytes32 versionHash = keccak256("1"); // BUG: version also should not be hardcoded
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                typeHash,
                nameHash,
                versionHash,
                block.chainid,
                address(this)
            )
        );
    }

    // BUG: no access control for initializer function. anyone can call this function and access will be granted to them
    function initialize() external {
        // we have to call AccessControl.revokeRole by this.revokeRole to get the msg.sender correct
        _grantRole(DEFAULT_ADMIN_ROLE, address(this)); // TODO: should the contract itself be its own admin address?
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    function _ownerRole(uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("OWNER_ROLE", tokenId));
    }

    function _approvedRole(uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("APPROVED_ROLE", tokenId));
    }

    // Just in case I wrote a bug, we can pause the contract to make sure nobody
    // loses money. But I know I didn't write any bugs.
    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
    }

    // BUG: modifier should be whenPaused instead. you can't unpause when not paused
    function unpause() external whenNotPaused onlyRole(PAUSER_ROLE) {
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

    // increments the price by 10% of the last price
    // BUG: does not conduct input validation to check that tokenId is valid. may return false values.
    function _nextPrice(uint256 tokenId) internal view returns (uint256) {
        return
            (lastPrice[tokenId] * (PRICE_INCREMENT + PRICE_INCREMENT_BASIS)) /
            PRICE_INCREMENT_BASIS;
    }

    function _univ3PriceLimit(bool zeroForOne) internal pure returns (uint160) {
        return
            zeroForOne
                ? 4295128740
                : 1461446703485210103287273052203988822378723970341; // BUG: hardcoded values may not be accurate
    }

    function _ethValue(
        IERC20 asset,
        bool zeroForOne,
        uint256 amount
    ) internal returns (uint256) {
        return
            QUOTER.quoteExactInputSingle(
                asset,
                WETH,
                UNIV3_FEE,
                amount,
                _univ3PriceLimit(zeroForOne)
            );
    }

    // BUG: does not check for slippage tolerance, i.e. amountOutMin
    function _swap(
        IERC20 asset,
        bool zeroForOne,
        uint256 amount
    ) internal returns (uint256 ethAmount) {
        // BUG: input validation for amount and asset
        // BUG: should ideally call Uniswap Factory contract directly to get accurate pool address
        address poolAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            0x1F98431c8aD98523631AE4a59f267346ea31F984, // Uniswap V3 Factory address
                            zeroForOne
                                ? keccak256(abi.encode(asset, WETH, UNIV3_FEE))
                                : keccak256(abi.encode(WETH, asset, UNIV3_FEE)),
                            bytes32(
                                0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54
                            )
                        )
                    )
                )
            )
        );
        console.log("pool address:", poolAddress);

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            zeroForOne,
            int256(amount),
            _univ3PriceLimit(zeroForOne), // TODO: check slippage limits
            abi.encode(asset)
        );
        console.log("called swap");
        // BUG: casting from int256 to uint256 may cause serious inaccuracies, e.g. negative value may result in huge positive value in uint256. Solidity 0.8.0 does not check for casting undeflows/overflows
        // Solution: use SafeCast from OZ or check for negative values before casting
        ethAmount = uint256(zeroForOne ? amount1 : amount0);
    }

    // A token with higher `level` is rarer, and therefore more valuable
    function level(uint256 tokenId) external pure returns (uint256 i) {
        for (; tokenId & 1 == 0 && i < 256; i++) {
            tokenId >>= 1;
        }
    }

    // A token can be purchased by paying at least 10% more than the price the
    // current owner paid. Don't be too sad, though. The original owner gets a
    // cut.
    function buy(
        uint256 tokenId,
        IERC20 asset,
        uint256 amount
    ) external payable whenNotPaused {
        // BUG: should check that tokenId is valid, amount > 0, and asset is not address(0)
        address oldOwner = getRoleMember(_ownerRole(tokenId), 0);
        uint256 oldPrice = lastPrice[tokenId];
        address msgSender = _msgSender();
        if (asset == ETHER) {
            require(msg.value == amount, "BuggyNFT: amount/value mismatch");
            // BUG: potential integer overflow/underflow, no checks that amount is greater than oldPrice
            uint256 fee = ((amount - oldPrice) * PROTOCOL_FEE) /
                PROTOCOL_FEE_BASIS;
            feesCollected[asset] += fee;
            amount -= fee;
        } else {
            require(msgSender.code.length != 0, "BuggyNFT: no flash loan"); // BUG: should check that code length = 0. This is requiring that the sender is a contract instead, which is not the intention according to the error message
            bool zeroForOne = asset < IERC20(WETH); // to get output token as WETH for swap direction

            uint256 ethAmount = _ethValue(asset, zeroForOne, amount);
            uint256 ethFee = ((ethAmount - oldPrice) * PROTOCOL_FEE) /
                PROTOCOL_FEE_BASIS;
            uint256 assetFee = (amount * ethFee) / ethAmount;
            feesCollected[asset] += assetFee;
            amount -= assetFee;

            amount = _swap(asset, zeroForOne, amount);

            WETH.withdraw(amount);
        }
        uint256 sellerFee = ((amount - oldPrice) * SELLER_FEE) /
            SELLER_FEE_BASIS;
        amount -= sellerFee;
        require(amount >= _nextPrice(oldPrice), "BuggyNFT: not enough"); // BUG: should pass in token ID instead of old price as parameter. Attacker will be able to pass in less than the required amount and still buy the token.
        // BUG: should not use .transfer, function might use more than 2300 gas and cause revert. use .call{value: amount}("") instead
        // BUG: should check that contract has sufficient balance to make the transfer
        // BUG: oldOwner may be a malicious contract, calling transfer may cause potential reentrancy attack
        payable(oldOwner).transfer(oldPrice + sellerFee);
        bytes32 ownerRole = _ownerRole(tokenId);
        this.revokeRole(ownerRole, oldOwner);
        this.grantRole(ownerRole, msgSender);
        lastPrice[tokenId] += amount; // BUG: should be set as new amount instead of adding to old price(?)
    }

    // The tokenId is chosen randomly, but the amount of money to be paid has to
    // be chosen beforehand. Make sure you spend a lot otherwise somebody else
    // might buy your rare token out from under you!
    // BUG: may have reentrancy vulnerability with external calls such as _swap. move to the end of the function if possible
    function mint(
        IERC20 asset,
        uint256 amount
    ) external payable whenNotPaused returns (uint256 mintedTokenId) {
        address msgSender = _msgSender();
        uint256 tokenId = uint256(
            keccak256(
                abi.encodePacked(
                    address(this),
                    blockhash(block.number - 1), // BUG: blockhash should not be used as source of randomness because anything onchain is not random
                    msgSender,
                    nextNonce
                )
            )
        );
        this.grantRole(_ownerRole(tokenId), msgSender); // BUG: should not use this.grantRole, this simluates an external call instead, which may not have permissions to grantRole
        uint256 fee = (amount * PROTOCOL_FEE) / PROTOCOL_FEE_BASIS;

        feesCollected[asset] += fee;
        if (asset == ETHER) {
            require(msg.value == amount, "BuggyNFT: amount/value mismatch");
            amount -= fee;
        } else {
            require(msgSender.code.length != 0, "BuggyNFT: no flash loan"); // BUG: should check that code length = 0. This is requiring that the sender is a contract instead, which is not the intention according to the error message
            amount -= fee;
            amount = _swap(asset, asset < IERC20(WETH), amount);
        }

        lastPrice[tokenId] = amount;
        nextNonce++;
        emit Mint(tokenId, msgSender);
        return tokenId;
    }

    // If you're unhappy with your token, you can burn it to get back the money
    // you spent... minus a small fee, of course.
    function burn(
        uint256 tokenId
    ) external onlyRole(_ownerRole(tokenId)) whenNotPaused {
        address msgSender = _msgSender();
        this.revokeRole(_ownerRole(tokenId), msgSender);
        (bool success, ) = payable(msgSender).call{value: lastPrice[tokenId]}(
            ""
        );
        require(success, "BuggyNFT: transfer failed");
        emit Burn(tokenId, msgSender);
    }

    function approve(
        uint256 tokenId,
        address spender,
        bytes calldata approveData
    ) external onlyRole(_ownerRole(tokenId)) whenNotPaused {
        require(
            _check(
                tokenId,
                spender,
                IBuggyNFTReceiver.receiveApproval.selector,
                approveData
            ),
            "BuggyNFT: rejected"
        );
        this.grantRole(_approvedRole(tokenId), spender);
        emit Approve(tokenId, spender);
    }

    // BUG: should include deadline
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256(
            "Permit(uint256 tokenId,address spender,uint256 nonSequentialNonce)"
        );

    // Allows other addresses to set approval without the owner spending gas. This
    // is EIP712 compatible.
    // BUG: no deadline, permit can be exploited
    function permit(
        uint256 tokenId,
        address spender,
        uint256 nonSequentialNonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, tokenId, spender) // BUG: should include deadline in the struct hash
        );
        bytes32 signingHash = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        address signer = ecrecover(signingHash, v, r, s);
        require(isOwner(tokenId, signer), "BuggyNFT: not owner");
        nonSequentialNonce = uint256(keccak256(abi.encodePacked(v, r, s))); // BUG: nonce derived from signature values, may not be unique for the same message and signing address
        require(!canceledNonces[nonSequentialNonce], "BuggyNFT: nonce replay"); // BUG: does not actually update the boolean in the canceledNonce mapping anywhere?
        this.grantRole(_approvedRole(tokenId), spender);
    }

    function transfer(
        uint256 tokenId,
        address receiver,
        bytes calldata transferData
    ) external whenNotPaused {
        address msgSender = _msgSender();
        this.grantRole(_ownerRole(tokenId), receiver);
        require(
            _check(
                tokenId,
                receiver,
                IBuggyNFTReceiver.receiveNFT.selector,
                transferData
            ),
            "BuggyNFT: rejected"
        );
        require(isApproved(tokenId, msgSender), "BuggyNFT: not approved");
        this.revokeRole(_approvedRole(tokenId), msgSender);
        emit Transfer(msgSender, receiver, tokenId);
    }

    // The guy who wrote this contract has to eat too. The fee is taken in
    // whatever token is paid, not just ETH.
    function collect(
        address payable receiver,
        IERC20 asset
    ) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == ETHER) {
            (bool success, ) = receiver.call{value: feesCollected[asset]}("");
            require(success, "BuggyNFT: transfer failed");
        } else {
            asset.transfer(receiver, feesCollected[asset]);
        }
        emit Collect(asset, receiver, feesCollected[asset]);
        delete feesCollected[asset];
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        IERC20 sellToken = abi.decode(data, (IERC20));
        if (amount0Delta > 0) {
            assert(sellToken < IERC20(WETH));
            sellToken.transferFrom(
                tx.origin, // BUG: should use msg.sender instead of tx.origin
                msg.sender,
                uint256(amount0Delta)
            );
        } else {
            assert(sellToken > IERC20(WETH));
            assert(amount1Delta > 0);
            sellToken.transferFrom(
                tx.origin,
                msg.sender,
                uint256(amount1Delta)
            );
        }
    }

    receive() external payable {}
}
