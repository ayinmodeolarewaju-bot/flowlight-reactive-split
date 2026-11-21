// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IInvoiceVault } from "./IInvoiceVault.sol";

/// @title InvoiceVault
/// @notice Origin contract for a keeperless revenue split. Clients pay invoices here.
///         Collaborators are paid only when PayoutRelay, driven by a Reactive callback, calls distribute.
/// @dev Deadlines use unix timestamps. Base Sepolia blocks are ~200ms, so block counts are not used.
contract InvoiceVault is IInvoiceVault {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant MAX_RECIPIENTS = 8;
    /// @dev Gas forwarded with each collaborator transfer. Enough for an EOA or a small wallet,
    ///      not enough for one recipient to consume the whole callback.
    uint256 public constant PAYOUT_GAS = 50_000;

    struct Invoice {
        address issuer;
        uint256 amountDue;
        uint256 paid;
        uint64 dueAt;
        bool exists;
        bool settled;
        uint256 settledAmount;
    }

    address public owner;
    address public relay;

    mapping(bytes32 => Invoice) public invoices;
    mapping(bytes32 => mapping(address => uint256)) public paidBy;
    mapping(bytes32 => address[]) private _recipients;
    mapping(bytes32 => uint16[]) private _bps;
    mapping(address => uint256) public claimable;

    event InvoiceOpened(
        bytes32 indexed invoiceId,
        address indexed issuer,
        uint256 amountDue,
        uint64 dueAt,
        address[] recipients,
        uint16[] bps
    );
    event PaymentReceived(
        bytes32 indexed invoiceId,
        address indexed payer,
        uint256 amount,
        uint256 totalPaid,
        uint256 amountDue
    );
    event PaymentRefunded(
        bytes32 indexed invoiceId,
        address indexed payer,
        uint256 amount,
        uint256 totalPaid,
        uint256 amountDue
    );
    event SplitSettled(bytes32 indexed invoiceId, address[] recipients, uint256[] amounts);
    event PayoutDeferred(bytes32 indexed invoiceId, address indexed recipient, uint256 amount);
    event SurplusWithdrawn(bytes32 indexed invoiceId, address indexed issuer, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event RelaySet(address indexed relay);

    error InvoiceExists();
    error UnknownInvoice();
    error BadRecipients();
    error BpsSum(uint256 sum);
    error ZeroAmount();
    error PastDue(uint64 dueAt, uint256 nowTs);
    error TooEarly(uint64 dueAt, uint256 nowTs);
    error AlreadySettled();
    error AlreadyFunded();
    error NotIssuer();
    error NotRelay();
    error NotOwner();
    error RelayFrozen();
    error NothingToWithdraw();
    error NotSettled();
    error InsufficientEscrow(uint256 requested, uint256 available);
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice One-time link to the callback relay. Frozen afterwards so escrow cannot be redirected.
    function setRelay(address relay_) external onlyOwner {
        if (relay != address(0)) revert RelayFrozen();
        if (relay_ == address(0)) revert NotRelay();
        relay = relay_;
        emit RelaySet(relay_);
    }

    function createInvoice(
        bytes32 invoiceId,
        uint256 amountDue,
        uint64 dueAt,
        address[] calldata recipients,
        uint16[] calldata bps
    ) external {
        if (invoices[invoiceId].exists) revert InvoiceExists();
        if (amountDue == 0) revert ZeroAmount();
        // dueAt == 0 means no deadline. Any other value must be in the future, measured by timestamp.
        if (dueAt != 0 && dueAt <= block.timestamp) revert PastDue(dueAt, block.timestamp);

        uint256 n = recipients.length;
        if (n == 0 || n > MAX_RECIPIENTS || n != bps.length) revert BadRecipients();

        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (recipients[i] == address(0) || bps[i] == 0) revert BadRecipients();
            sum += bps[i];
        }
        if (sum != BPS_DENOMINATOR) revert BpsSum(sum);

        invoices[invoiceId] = Invoice({
            issuer: msg.sender,
            amountDue: amountDue,
            paid: 0,
            dueAt: dueAt,
            exists: true,
            settled: false,
            settledAmount: 0
        });
        _recipients[invoiceId] = recipients;
        _bps[invoiceId] = bps;

        emit InvoiceOpened(invoiceId, msg.sender, amountDue, dueAt, recipients, bps);
    }

    function pay(bytes32 invoiceId) external payable {
        Invoice storage invoice = invoices[invoiceId];
        if (!invoice.exists) revert UnknownInvoice();
        if (invoice.settled) revert AlreadySettled();
        if (msg.value == 0) revert ZeroAmount();
        if (invoice.dueAt != 0 && block.timestamp > invoice.dueAt) revert PastDue(invoice.dueAt, block.timestamp);

        invoice.paid += msg.value;
        paidBy[invoiceId][msg.sender] += msg.value;

        emit PaymentReceived(invoiceId, msg.sender, msg.value, invoice.paid, invoice.amountDue);
    }

    /// @notice After the timestamp deadline, a payer reclaims what they sent if the invoice is still short.
    function refund(bytes32 invoiceId) external {
        Invoice storage invoice = invoices[invoiceId];
        if (!invoice.exists) revert UnknownInvoice();
        if (invoice.settled) revert AlreadySettled();
        if (invoice.dueAt == 0 || block.timestamp <= invoice.dueAt) revert TooEarly(invoice.dueAt, block.timestamp);
        if (invoice.paid >= invoice.amountDue) revert AlreadyFunded();

        uint256 amount = paidBy[invoiceId][msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        paidBy[invoiceId][msg.sender] = 0;
        invoice.paid -= amount;

        emit PaymentRefunded(invoiceId, msg.sender, amount, invoice.paid, invoice.amountDue);

        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }

    /// @inheritdoc IInvoiceVault
    function escrowOf(bytes32 invoiceId) external view returns (uint256) {
        Invoice storage invoice = invoices[invoiceId];
        if (!invoice.exists || invoice.settled) return 0;
        return invoice.paid;
    }

    /// @inheritdoc IInvoiceVault
    function isSettled(bytes32 invoiceId) external view returns (bool) {
        return invoices[invoiceId].settled;
    }

    function recipientsOf(bytes32 invoiceId) external view returns (address[] memory recipients, uint16[] memory bps) {
        return (_recipients[invoiceId], _bps[invoiceId]);
    }

    /// @inheritdoc IInvoiceVault
    /// @dev Marks the invoice settled before transfers. A recipient that rejects ETH does not roll back the others.
    function distribute(bytes32 invoiceId, address[] calldata recipients, uint256[] calldata amounts) external {
        if (msg.sender != relay) revert NotRelay();

        Invoice storage invoice = invoices[invoiceId];
        if (!invoice.exists || invoice.settled) return;

        uint256 n = recipients.length;
        if (n == 0 || n != amounts.length || n > MAX_RECIPIENTS) revert BadRecipients();

        uint256 total;
        for (uint256 i; i < n; ++i) {
            if (recipients[i] == address(0)) revert BadRecipients();
            total += amounts[i];
        }
        uint256 available = invoice.paid;
        if (total == 0 || total > available || total > address(this).balance) {
            revert InsufficientEscrow(total, available < address(this).balance ? available : address(this).balance);
        }

        invoice.settled = true;
        invoice.settledAmount = total;

        for (uint256 i; i < n; ++i) {
            if (amounts[i] == 0) continue;
            (bool ok,) = recipients[i].call{ value: amounts[i], gas: PAYOUT_GAS }("");
            if (!ok) {
                claimable[recipients[i]] += amounts[i];
                emit PayoutDeferred(invoiceId, recipients[i], amounts[i]);
            }
        }

        emit SplitSettled(invoiceId, recipients, amounts);
    }

    /// @notice Issuer takes anything paid above the settled split. Collaborator funds are not included.
    function withdrawSurplus(bytes32 invoiceId) external {
        Invoice storage invoice = invoices[invoiceId];
        if (msg.sender != invoice.issuer) revert NotIssuer();
        if (!invoice.settled) revert NotSettled();

        uint256 surplus = invoice.paid - invoice.settledAmount;
        if (surplus == 0) revert NothingToWithdraw();
        invoice.paid = invoice.settledAmount;

        emit SurplusWithdrawn(invoiceId, msg.sender, surplus);

        (bool ok,) = msg.sender.call{ value: surplus }("");
        if (!ok) revert TransferFailed();
    }

    function claim() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        claimable[msg.sender] = 0;
        emit Claimed(msg.sender, amount);
        (bool ok,) = msg.sender.call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }
}
