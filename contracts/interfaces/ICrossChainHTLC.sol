// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ILiquidityPool } from "./ILiquidityPool.sol";

interface ICrossChainHTLC {
    struct Base {
        bytes32 secretHash;
        uint256 amount;
        address token;
        address user;
        uint64 chainId;
    }

    struct HtlcLockSource {
        Base base;
        uint256 nonce;
        address sessionAddress;
        uint64 maintainerDeadline;
        bytes maintainerSig;
    }

    struct ClaimSource {
        Base base;
        address sessionAddress;
        bytes32 secret;
        bytes secretHashSignature;
    }

    struct ClaimDestination {
        Base base;
        bytes32 secret;
    }

    struct RefundSource {
        Base base;
        address sessionAddress;
    }

    function lockSource(HtlcLockSource calldata params, uint256 executionFeeNative) external payable;

    function lockDestination(Base calldata params) external;

    function claimSource(ClaimSource calldata params) external;

    function claimDestination(ClaimDestination calldata params) external;

    function refundSource(RefundSource calldata params) external;

    function refundDestination(Base calldata params) external;
}
