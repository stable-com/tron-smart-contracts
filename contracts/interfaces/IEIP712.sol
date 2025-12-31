// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IEIP712
/// @notice Interface for EIP-712 functionality
interface IEIP712 {
    /// @notice Returns the domain separator
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
