// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "../interfaces/IERC20Permit.sol";
import { IAllowanceTransfer } from "../interfaces/IAllowanceTransfer.sol";

/**
 * @title SafePermit
 * @notice Library for safe permit execution using try-catch pattern
 */
library SafePermit {
    /**
     * @notice Safely execute permit - will not revert if permit fails
     * @param token The token address
     * @param owner The token owner
     * @param spender The approved spender
     * @param value The approval amount
     * @param deadline The permit deadline
     * @param v Signature v component
     * @param r Signature r component
     * @param s Signature s component
     */
    function safePermit(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        try token.permit(owner, spender, value, deadline, v, r, s) {
        } catch {
            uint256 currentAllowance = IERC20(address(token)).allowance(owner, spender);
            require(
                currentAllowance >= value,
                "SafePermit: permit failed and insufficient allowance"
            );
        }
    }

    /**
     * @notice Safely execute Permit2 permit - will not revert if permit fails
     * @param permit2 The Permit2 contract address
     * @param owner The token owner
     * @param permitSingle The permit data structure
     * @param signature The permit signature
     */
    function safePermit2(
        IAllowanceTransfer permit2,
        address owner,
        IAllowanceTransfer.PermitSingle memory permitSingle,
        bytes calldata signature
    ) internal {
        try permit2.permit(owner, permitSingle, signature) {
        } catch {
            (uint160 amount, uint48 expiration, ) = permit2.allowance(
                owner,
                permitSingle.details.token,
                permitSingle.spender
            );
            require(
                amount >= permitSingle.details.amount && block.timestamp <= expiration,
                "SafePermit: Permit2 failed and insufficient allowance"
            );
        }
    }
}
