// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title SplitLedger
/// @notice Reactive contract on Reactive Omni. It is the book of record for an invoice:
///         allocations, partial payments, refunds, and the single decision to pay a split.
/// @dev Subscriptions are live filters, not historical reads. Deploy and call watch() before the
///      first invoice event. react() must not revert on data it merely wants to ignore: a revert
///      is caught, billed, and logged as ReactiveContractReverted.
contract SplitLedger is AbstractReactive {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant MAX_RECIPIENTS = 8;
    uint64 public constant MIN_CALLBACK_GAS = 100_000;
    uint64 public constant MAX_CALLBACK_GAS = 1_500_000;

    uint256 public constant INVOICE_OPENED_TOPIC0 =
        uint256(keccak256("InvoiceOpened(bytes32,address,uint256,uint64,address[],uint16[])"));
    uint256 public constant PAYMENT_RECEIVED_TOPIC0 =
        uint256(keccak256("PaymentReceived(bytes32,address,uint256,uint256,uint256)"));
    uint256 public constant PAYMENT_REFUNDED_TOPIC0 =
        uint256(keccak256("PaymentRefunded(bytes32,address,uint256,uint256,uint256)"));
    uint256 public constant SPLIT_SETTLED_TOPIC0 =
        uint256(keccak256("SplitSettled(bytes32,address[],uint256[])"));

    /// @dev Minimum gap between permissionless retries. A timestamp, not a block count.
    uint256 public constant POKE_COOLDOWN = 30;

    bytes4 public constant SETTLE_SELECTOR = bytes4(keccak256("settle(address,bytes32,address[],uint256[])"));

    struct Invoice {
        address issuer;
        uint256 amountDue;
        uint256 paid;
        uint64 dueAt;
        uint8 recipients;
        bool configured;
        bool payoutRequested;
    }

    struct Allocation {
        address recipient;
        uint16 bps;
    }

    uint256 public immutable originChainId;
    uint256 public immutable destinationChainId;

    address public owner;
    address public origin;
    address public destination;
    bool public watching;
    uint64 public callbackGasLimit = 800_000;

    mapping(bytes32 => Invoice) public invoices;
    mapping(bytes32 => Allocation[8]) private _alloc;
    mapping(bytes32 => uint256) private _pendingPaid;
    mapping(bytes32 => bool) public seenLog;
    mapping(bytes32 => bool) public acked;
    mapping(bytes32 => uint256) public lastPokeAt;

    event Watching(address indexed origin, address indexed destination);
    event InvoiceTracked(bytes32 indexed invoiceId, address indexed issuer, uint256 amountDue, uint8 recipients);
    event InvoiceRejected(bytes32 indexed invoiceId, string reason);
    event PaymentBuffered(bytes32 indexed invoiceId, uint256 totalPaid);
    event PaymentApplied(bytes32 indexed invoiceId, uint256 totalPaid, uint256 amountDue);
    event SplitRequested(bytes32 indexed invoiceId, uint256 total, uint8 recipients);
    event SplitDeferred(bytes32 indexed invoiceId, string reason);
    event SplitAcknowledged(bytes32 indexed invoiceId);

    error NotOwner();
    error OriginUnset();
    error BadGasLimit();
    error NotReady();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param origin_ Vault to subscribe to. Pass address(0) and call watch() later.
    constructor(uint256 originChainId_, uint256 destinationChainId_, address origin_) payable {
        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
        owner = msg.sender;
        if (origin_ != address(0)) {
            origin = origin_;
            _subscribe();
            watching = true;
            emit Watching(origin_, destination);
        }
    }

    function setDestination(address destination_) external onlyOwner {
        if (destination_ == address(0)) revert OriginUnset();
        destination = destination_;
        emit Watching(origin, destination_);
    }

    function setCallbackGasLimit(uint64 gasLimit_) external onlyOwner {
        if (gasLimit_ < MIN_CALLBACK_GAS || gasLimit_ > MAX_CALLBACK_GAS) revert BadGasLimit();
        callbackGasLimit = gasLimit_;
    }

    function watch(address origin_) external onlyOwner {
        if (origin_ == address(0)) revert OriginUnset();
        if (watching) _unsubscribe();
        origin = origin_;
        _subscribe();
        watching = true;
        emit Watching(origin_, destination);
    }

    function pause() external onlyOwner {
        if (watching) {
            _unsubscribe();
            watching = false;
        }
    }

    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Ask again after a callback was skipped or reverted. The relay no-ops if the invoice is already settled.
    function retrySettle(bytes32 invoiceId) external onlyOwner {
        _reRequest(invoiceId, true);
    }

    /// @notice Permissionless retry. Reactive does not retry a failed callback on its own, so anyone
    ///         can poke until the vault's SplitSettled log is acknowledged. A 30s timestamp cooldown
    ///         stops a loop from draining the destination reserve.
    function poke(bytes32 invoiceId) external {
        if (acked[invoiceId]) return;
        if (lastPokeAt[invoiceId] != 0 && block.timestamp < lastPokeAt[invoiceId] + POKE_COOLDOWN) return;
        lastPokeAt[invoiceId] = block.timestamp;
        _reRequest(invoiceId, false);
    }

    function _reRequest(bytes32 invoiceId, bool strict_) internal {
        Invoice storage invoice = invoices[invoiceId];
        if (!invoice.configured || invoice.paid < invoice.amountDue || destination == address(0)) {
            if (strict_) revert NotReady();
            return;
        }
        invoice.payoutRequested = false;
        _maybeSettle(invoiceId);
    }

    function allocationsOf(bytes32 invoiceId)
        external
        view
        returns (address[] memory recipients, uint16[] memory bps)
    {
        uint8 n = invoices[invoiceId].recipients;
        recipients = new address[](n);
        bps = new uint16[](n);
        for (uint8 i; i < n; ++i) {
            recipients[i] = _alloc[invoiceId][i].recipient;
            bps[i] = _alloc[invoiceId][i].bps;
        }
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external override onlySystem {
        if (log_.chainId != originChainId || log_.contractAddress != origin) return;

        bytes32 seenKey = keccak256(abi.encode(log_.chainId, log_.txHash, log_.logIndex));
        if (seenLog[seenKey]) return;
        seenLog[seenKey] = true;

        if (log_.topic0 == INVOICE_OPENED_TOPIC0) {
            if (!_topicCountOk(log_.opCode, 3)) return;
            _onOpened(log_);
        } else if (log_.topic0 == PAYMENT_RECEIVED_TOPIC0) {
            if (!_topicCountOk(log_.opCode, 3)) return;
            _onPayment(log_, false);
        } else if (log_.topic0 == PAYMENT_REFUNDED_TOPIC0) {
            if (!_topicCountOk(log_.opCode, 3)) return;
            _onPayment(log_, true);
        } else if (log_.topic0 == SPLIT_SETTLED_TOPIC0) {
            if (!_topicCountOk(log_.opCode, 2)) return;
            acked[bytes32(log_.topic1)] = true;
            emit SplitAcknowledged(bytes32(log_.topic1));
        }
    }

    function _onOpened(LogRecord calldata log_) internal {
        bytes32 invoiceId = bytes32(log_.topic1);
        Invoice storage invoice = invoices[invoiceId];
        if (invoice.configured) return;

        address issuer = address(uint160(log_.topic2));
        (uint256 amountDue, uint64 dueAt, address[] memory recipients, uint16[] memory bps) =
            abi.decode(log_.data, (uint256, uint64, address[], uint16[]));

        uint256 n = recipients.length;
        if (amountDue == 0 || n == 0 || n > MAX_RECIPIENTS || n != bps.length) {
            emit InvoiceRejected(invoiceId, "shape");
            return;
        }

        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (recipients[i] == address(0) || bps[i] == 0) {
                emit InvoiceRejected(invoiceId, "recipient");
                return;
            }
            sum += bps[i];
        }
        if (sum != BPS_DENOMINATOR) {
            emit InvoiceRejected(invoiceId, "bps");
            return;
        }

        for (uint256 i; i < n; ++i) {
            _alloc[invoiceId][i] = Allocation({ recipient: recipients[i], bps: bps[i] });
        }

        invoice.issuer = issuer;
        invoice.amountDue = amountDue;
        invoice.paid = _pendingPaid[invoiceId];
        invoice.dueAt = dueAt;
        invoice.recipients = uint8(n);
        invoice.configured = true;

        emit InvoiceTracked(invoiceId, issuer, amountDue, uint8(n));
        _maybeSettle(invoiceId);
    }

    function _onPayment(LogRecord calldata log_, bool refund_) internal {
        bytes32 invoiceId = bytes32(log_.topic1);
        (, uint256 totalPaid,) = abi.decode(log_.data, (uint256, uint256, uint256));

        Invoice storage invoice = invoices[invoiceId];
        if (!invoice.configured) {
            _pendingPaid[invoiceId] = totalPaid;
            emit PaymentBuffered(invoiceId, totalPaid);
            return;
        }
        if (invoice.payoutRequested) return;

        if (refund_) {
            if (totalPaid < invoice.paid) invoice.paid = totalPaid;
        } else if (totalPaid > invoice.paid) {
            invoice.paid = totalPaid;
        } else {
            return;
        }

        emit PaymentApplied(invoiceId, invoice.paid, invoice.amountDue);
        if (!refund_) _maybeSettle(invoiceId);
    }

    function _maybeSettle(bytes32 invoiceId) internal {
        Invoice storage invoice = invoices[invoiceId];
        if (!invoice.configured || invoice.payoutRequested) return;
        if (invoice.paid < invoice.amountDue) return;
        if (destination == address(0)) {
            emit SplitDeferred(invoiceId, "destination");
            return;
        }

        uint8 n = invoice.recipients;
        address[] memory recipients = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 allocated;
        uint256 amountDue = invoice.amountDue;
        for (uint8 i; i < n; ++i) {
            recipients[i] = _alloc[invoiceId][i].recipient;
            amounts[i] = (amountDue * _alloc[invoiceId][i].bps) / BPS_DENOMINATOR;
            allocated += amounts[i];
        }
        // Integer division dust goes to the first recipient so the vault pays amountDue exactly.
        amounts[0] += amountDue - allocated;

        invoice.payoutRequested = true;

        bytes memory payload = abi.encodeWithSelector(SETTLE_SELECTOR, address(0), invoiceId, recipients, amounts);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: destination,
                gasLimit: callbackGasLimit,
                payload: payload
            })
        );

        emit SplitRequested(invoiceId, amountDue, n);
    }

    /// @dev Docs report a 3-topic log as opCode 3. Also accept the raw LOG opcode and 0 when a trace omitted it.
    function _topicCountOk(uint256 opCode, uint256 expected) internal pure returns (bool) {
        if (opCode == 0 || opCode == expected) return true;
        if (opCode >= 0xA0 && opCode <= 0xA4) return opCode - 0xA0 == expected;
        return false;
    }

    function _subscribe() internal {
        _sub(INVOICE_OPENED_TOPIC0, true);
        _sub(PAYMENT_RECEIVED_TOPIC0, true);
        _sub(PAYMENT_REFUNDED_TOPIC0, true);
        _sub(SPLIT_SETTLED_TOPIC0, true);
    }

    function _unsubscribe() internal {
        _sub(INVOICE_OPENED_TOPIC0, false);
        _sub(PAYMENT_RECEIVED_TOPIC0, false);
        _sub(PAYMENT_REFUNDED_TOPIC0, false);
        _sub(SPLIT_SETTLED_TOPIC0, false);
    }

    function _sub(uint256 topic0, bool on) internal {
        if (on) {
            SYSTEM.subscribe(originChainId, origin, topic0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        } else {
            SYSTEM.unsubscribe(originChainId, origin, topic0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }
}
