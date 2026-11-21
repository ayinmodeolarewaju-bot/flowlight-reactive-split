// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Escrow surface the payout relay is allowed to call.
interface IInvoiceVault {
    function escrowOf(bytes32 invoiceId) external view returns (uint256);

    function isSettled(bytes32 invoiceId) external view returns (bool);

    function distribute(bytes32 invoiceId, address[] calldata recipients, uint256[] calldata amounts) external;
}
