// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { IInvoiceVault } from "./IInvoiceVault.sol";

/// @title PayoutRelay
/// @notice Destination contract. Reactive Omni delivers settle() through the Base Sepolia callback proxy.
///         This contract does not hold invoice funds. It checks escrow, then tells the vault to pay.
contract PayoutRelay is AbstractCallback {
    IInvoiceVault public immutable vault;

    event SplitSkipped(bytes32 indexed invoiceId, string reason);

    error VaultUnset();

    constructor(IPayable callbackProxy_, address callbackSender_, IInvoiceVault vault_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        if (address(vault_) == address(0)) revert VaultUnset();
        vault = vault_;
    }

    /// @notice Callback entry. The proxy overwrites `reactive_` with the reactive contract that requested it.
    /// @dev Does not revert on a duplicate or on short funds. A revert would still be billed and would not
    ///      clear the reactive ledger's payout flag. retrySettle on the ledger can call this again.
    function settle(address reactive_, bytes32 invoiceId, address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        if (vault.isSettled(invoiceId)) {
            emit SplitSkipped(invoiceId, "duplicate");
            return;
        }

        uint256 n = recipients.length;
        if (n == 0 || n != amounts.length) {
            emit SplitSkipped(invoiceId, "shape");
            return;
        }

        uint256 total;
        for (uint256 i; i < n; ++i) {
            total += amounts[i];
        }

        uint256 escrow = vault.escrowOf(invoiceId);
        if (total == 0 || total > escrow || total > address(vault).balance) {
            emit SplitSkipped(invoiceId, "funds");
            return;
        }

        vault.distribute(invoiceId, recipients, amounts);
    }

    /// @notice Anyone can settle callback debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
