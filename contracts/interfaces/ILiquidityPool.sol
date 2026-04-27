// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ICrossChainHTLC } from "./ICrossChainHTLC.sol";

/**
 * @title ILiquidityPool
 */
interface ILiquidityPool {
    struct LiquidityThresholds {
        uint256 X;
        uint256 Y;
        uint256 Z;
    }

    struct SwapLocal {
        uint256 amountIn;
        address tokenIn;
        address tokenOut;
        uint64 chainId;
        address recipient;
        uint64 deadline;
        uint256 nonce;
    }

    struct SwapLocalWithPermit {
        SwapLocal base;
        address user;
        PermitData permit;
    }

    struct SwapLocalWithPermit2 {
        SwapLocal base;
        address user;
        Permit2Data permit2;
    }

    struct PermitData {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 fee;
        bytes userSignature;
    }

    struct Permit2Data {
        bytes permit2Data;
        bytes permit2Signature;
        uint256 fee;
        bytes userSignature;
    }

    struct SignatureData {
        address user;
        uint256 fee;
        bytes userSignature;
    }

    function setupToken(
        address token,
        bool status,
        uint256 X,
        uint256 Y,
        uint256 Z,
        uint256 protocolFee
    ) external;

    function depositLiquidity(address token, uint256 amount) external;

    function withdrawLiquidity(address token, uint256 amount) external;

    function setRebalanceWhitelist(address destination, bool allowed) external;
    function rebalancePool(address token, uint256 amount, address to) external;
    function rebalanceWhitelist(address destination) external view returns (bool);

    function getReserves(address token) external view returns (uint256 amount);

    function isWhitelisted(address token) external view returns (bool);

    function singleChainSwap(SwapLocal calldata params, bytes calldata maintainerSig, uint256 executionFeeNative) external payable;

    function singleChainSwapWithPermit(
        SwapLocalWithPermit calldata params,
        bytes calldata maintainerSig
    ) external;

    function singleChainSwapWithPermit2(
        SwapLocalWithPermit2 calldata params,
        bytes calldata maintainerSig
    ) external;

    function singleChainSwapWithSignature(
        SwapLocal calldata base,
        SignatureData calldata signatureData,
        bytes calldata maintainerSig
    ) external;

    function lockDestination(
        bytes32 secretHash,
        address token,
        uint256 amount,
        uint64 untilTs
    ) external;

    function lockSource(ICrossChainHTLC.Base calldata base, uint256 nonce, uint64 untilTs) external;

    function lockSourceWithPermit(
        ICrossChainHTLC.Base calldata base,
        uint256 nonce,
        uint64 untilTs,
        PermitData calldata permitData,
        address sessionAddress
    ) external;

    function lockSourceWithPermit2(
        ICrossChainHTLC.Base calldata base,
        uint256 nonce,
        uint64 untilTs,
        Permit2Data calldata permit2Data,
        address sessionAddress
    ) external;

    function lockSourceWithSignature(
        ICrossChainHTLC.Base calldata base,
        uint256 nonce,
        uint64 untilTs,
        SignatureData calldata signatureData,
        address sessionAddress
    ) external;

    function transfer(bytes32 secretHash, address token, address to, uint256 amount) external;

    function unlock(bytes32 secretHash, address token, uint256 amount) external;

    function transferForRefund(
        bytes32 secretHash,
        address token,
        address to,
        uint256 amount
    ) external;

    function getAvailableLiquidity(address token) external view returns (uint256);
}
