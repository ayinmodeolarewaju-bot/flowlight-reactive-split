// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { InvoiceVault } from "../src/InvoiceVault.sol";
import { PayoutRelay } from "../src/PayoutRelay.sol";
import { SplitLedger } from "../src/SplitLedger.sol";
import { MockSystem } from "./MockSystem.sol";

contract RejectingRecipient {
    receive() external payable {
        revert("no");
    }
}

contract SplitFlowTest is Test {
    receive() external payable {}

    uint256 internal constant BASE = 84532;
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    bytes32 internal constant CALLBACK_TOPIC = keccak256("CallbackCaptured(uint256,address,uint64,bytes)");

    InvoiceVault internal vault;
    PayoutRelay internal relay;
    SplitLedger internal ledger;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal callbacks;
    bytes internal lastPayload;

    function setUp() public {
        MockSystem deployed = new MockSystem();
        vm.etch(SYSTEM, address(deployed).code);

        MockSystem proxy = new MockSystem();
        vault = new InvoiceVault();
        ledger = new SplitLedger(BASE, BASE, address(vault));
        relay = new PayoutRelay(IPayable(payable(address(proxy))), address(ledger), vault);
        vault.setRelay(address(relay));
        ledger.setDestination(address(relay));

        vm.deal(address(this), 10 ether);
    }

    function test_partialPaymentDoesNotSettle() public {
        bytes32 id = _open(10_000, _hourFromNow());
        _payAndReact(id, 4_000);

        (,, uint256 paid,,,, bool payoutRequested) = ledger.invoices(id);
        assertEq(paid, 4_000);
        assertFalse(payoutRequested);
        assertFalse(vault.isSettled(id));
        assertEq(callbacks, 0);
        assertEq(alice.balance, 0);
    }

    function test_fullPaymentRequestsExactSplitAndPaysOnce() public {
        bytes32 id = _open(10_000, _hourFromNow());
        _payAndReact(id, 4_000);
        _payAndReact(id, 6_000);

        (,, uint256 paid,,,, bool payoutRequested) = ledger.invoices(id);
        assertEq(paid, 10_000);
        assertTrue(payoutRequested);
        assertEq(callbacks, 1);

        _deliverLatest();

        assertTrue(vault.isSettled(id));
        assertEq(alice.balance, 5_000);
        assertEq(bob.balance, 3_000);
        assertEq(carol.balance, 2_000);
        assertEq(address(vault).balance, 0);

        _deliverLatest();
        assertEq(alice.balance, 5_000, "duplicate callback paid again");
    }

    function test_duplicateLogDoesNotDoubleCount() public {
        bytes32 id = _open(10_000, _hourFromNow());
        vm.recordLogs();
        vault.pay{ value: 4_000 }(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IReactive.LogRecord memory rec = _toRecord(logs[0], 11, 0);
        _react(rec);
        uint256 seen = callbacks;
        _react(rec);
        assertEq(callbacks, seen);
        (,, uint256 paid,,,,) = ledger.invoices(id);
        assertEq(paid, 4_000);
    }

    function test_paymentBeforeOpenIsBuffered() public {
        bytes32 id = keccak256("early");
        address[] memory recipients = _recipients();
        uint16[] memory bps = _bps();

        vm.recordLogs();
        vault.createInvoice(id, 1_000, _hourFromNow(), recipients, bps);
        Vm.Log[] memory opened = vm.getRecordedLogs();

        vm.recordLogs();
        vault.pay{ value: 1_000 }(id);
        Vm.Log[] memory paid = vm.getRecordedLogs();

        _react(_toRecord(paid[0], 21, 0));
        (,,,,, bool configured,) = ledger.invoices(id);
        assertFalse(configured);

        _react(_toRecord(opened[0], 22, 0));
        (,, uint256 total,,,, bool payoutRequested) = ledger.invoices(id);
        assertEq(total, 1_000);
        assertTrue(payoutRequested);
        assertEq(callbacks, 1);
    }

    function test_roundingDustGoesToFirstRecipient() public {
        bytes32 id = keccak256("dust");
        address[] memory recipients = _recipients();
        uint16[] memory bps = new uint16[](3);
        bps[0] = 3_333;
        bps[1] = 3_333;
        bps[2] = 3_334;
        _create(id, 100, _hourFromNow(), recipients, bps);
        _payAndReact(id, 100);
        _deliverLatest();
        assertEq(alice.balance, 34);
        assertEq(bob.balance, 33);
        assertEq(carol.balance, 33);
    }

    function test_overpaymentStaysForIssuer() public {
        bytes32 id = _open(10_000, _hourFromNow());
        _payAndReact(id, 12_000);
        _deliverLatest();
        assertEq(address(vault).balance, 2_000);
        uint256 before = address(this).balance;
        vault.withdrawSurplus(id);
        assertEq(address(this).balance, before + 2_000);
        assertEq(address(vault).balance, 0);
    }

    function test_shortFundsAreSkippedAndNotSettled() public {
        bytes32 id = _open(10_000, _hourFromNow());
        address[] memory recipients = _recipients();
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 9_000;
        amounts[1] = 2_000;
        amounts[2] = 1;

        vm.prank(address(relay._SERVICE_PROVIDER()));
        relay.settle(address(ledger), id, recipients, amounts);

        assertFalse(vault.isSettled(id));
        assertEq(alice.balance, 0);
    }

    function test_directCallbackIsRejected() public {
        bytes32 id = _open(10_000, 0);
        address[] memory recipients = _recipients();
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5_000;
        amounts[1] = 3_000;
        amounts[2] = 2_000;

        vm.expectRevert();
        relay.settle(address(ledger), id, recipients, amounts);

        vm.prank(address(relay._SERVICE_PROVIDER()));
        vm.expectRevert();
        relay.settle(alice, id, recipients, amounts);

        vm.expectRevert(InvoiceVault.NotRelay.selector);
        vault.distribute(id, recipients, amounts);
    }

    function test_refundUsesTimestampNotBlockNumber() public {
        uint64 dueAt = uint64(block.timestamp + 100);
        bytes32 id = _open(10_000, dueAt);
        _payAndReact(id, 4_000);

        vm.roll(block.number + 1_000_000);
        vault.pay{ value: 1 }(id);

        vm.expectRevert();
        vault.refund(id);

        vm.warp(uint256(dueAt) + 1);
        vm.expectRevert(abi.encodeWithSelector(InvoiceVault.PastDue.selector, dueAt, uint256(dueAt) + 1));
        vault.pay{ value: 1 }(id);

        vm.recordLogs();
        uint256 before = address(this).balance;
        vault.refund(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(address(this).balance, before + 4_001);
        assertEq(vault.escrowOf(id), 0);

        _react(_toRecord(logs[0], 41, 0));
        (,, uint256 paid,,,,) = ledger.invoices(id);
        assertEq(paid, 0);
        assertEq(callbacks, 0);
    }

    function test_fundedInvoiceCannotBeRefundedAfterDeadline() public {
        uint64 dueAt = uint64(block.timestamp + 50);
        bytes32 id = _open(1_000, dueAt);
        _payAndReact(id, 1_000);
        vm.warp(block.timestamp + 51);
        vm.expectRevert(InvoiceVault.AlreadyFunded.selector);
        vault.refund(id);
    }

    function test_blockAdvanceDoesNotExpireInvoice() public {
        bytes32 id = _open(1_000, uint64(block.timestamp + 3600));
        vm.roll(block.number + 5_000_000);
        vault.pay{ value: 1_000 }(id);
        assertEq(vault.escrowOf(id), 1_000);
    }

    function test_topic0MatchesEmittedLog() public {
        vm.recordLogs();
        vault.createInvoice(keccak256("topic-open"), 1, 0, _recipients(), _bps());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], bytes32(ledger.INVOICE_OPENED_TOPIC0()));

        vm.recordLogs();
        vault.pay{ value: 1 }(keccak256("topic-open"));
        logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], bytes32(ledger.PAYMENT_RECEIVED_TOPIC0()));
    }

    function test_rawLogOpcodeIsAccepted() public {
        bytes32 id = _open(1_000, 0);
        vm.recordLogs();
        vault.pay{ value: 400 }(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IReactive.LogRecord memory rec = _toRecord(logs[0], 51, 0);
        rec.opCode = 0xA3;
        _react(rec);
        (,, uint256 paid,,,,) = ledger.invoices(id);
        assertEq(paid, 400);
    }

    function test_rejectingRecipientBecomesClaimable() public {
        RejectingRecipient bad = new RejectingRecipient();
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = address(bad);
        uint16[] memory bps = new uint16[](2);
        bps[0] = 6_000;
        bps[1] = 4_000;
        bytes32 id = keccak256("reject");
        _create(id, 1_000, 0, recipients, bps);
        _payAndReact(id, 1_000);
        _deliverLatest();
        assertEq(alice.balance, 600);
        assertEq(vault.claimable(address(bad)), 400);
        assertTrue(vault.isSettled(id));
        assertEq(address(bad).balance, 0);
    }

    function test_strangerCannotReact() public {
        bytes32 id = _open(1_000, 0);
        vm.recordLogs();
        vault.pay{ value: 1_000 }(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.expectRevert();
        ledger.react(_toRecord(logs[0], 1, 0));
    }

    function test_retrySettleEmitsAnotherCallback() public {
        bytes32 id = _open(1_000, 0);
        _payAndReact(id, 1_000);
        assertEq(callbacks, 1);
        vm.recordLogs();
        ledger.retrySettle(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 extra;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == CALLBACK_TOPIC) extra += 1;
        }
        assertEq(extra, 1);
    }

    function test_badBpsRejected() public {
        uint16[] memory bps = _bps();
        bps[0] = 4_000;
        vm.expectRevert(abi.encodeWithSelector(InvoiceVault.BpsSum.selector, uint256(9_000)));
        vault.createInvoice(keccak256("bad"), 1, 0, _recipients(), bps);
    }

    function test_pokeRetriesUntilAck() public {
        bytes32 id = _open(1_000, 0);
        _payAndReact(id, 1_000);
        assertEq(callbacks, 1);

        uint256 extra = _countCallbacks(address(ledger), abi.encodeWithSelector(SplitLedger.poke.selector, id));
        assertEq(extra, 1, "poke before ack");

        extra = _countCallbacks(address(ledger), abi.encodeWithSelector(SplitLedger.poke.selector, id));
        assertEq(extra, 0, "cooldown");

        vm.warp(block.timestamp + ledger.POKE_COOLDOWN());
        vm.recordLogs();
        _deliverLatest();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool saw;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == bytes32(ledger.SPLIT_SETTLED_TOPIC0())) {
                _react(_toRecord(logs[i], 90, i));
                saw = true;
            }
        }
        assertTrue(saw);
        assertTrue(ledger.acked(id));

        vm.warp(block.timestamp + ledger.POKE_COOLDOWN());
        extra = _countCallbacks(address(ledger), abi.encodeWithSelector(SplitLedger.poke.selector, id));
        assertEq(extra, 0, "acked poke is silent");
    }

    function test_settleSelectorMatchesRelay() public view {
        assertEq(ledger.SETTLE_SELECTOR(), PayoutRelay.settle.selector);
    }

    function _open(uint256 amount, uint64 dueAt) internal returns (bytes32 id) {
        id = keccak256(abi.encode("invoice", amount, dueAt));
        _create(id, amount, dueAt, _recipients(), _bps());
    }

    function _create(
        bytes32 id,
        uint256 amount,
        uint64 dueAt,
        address[] memory recipients,
        uint16[] memory bps
    ) internal {
        vm.recordLogs();
        vault.createInvoice(id, amount, dueAt, recipients, bps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault)) {
                _react(_toRecord(logs[i], uint256(keccak256(abi.encode("open", id))), i));
            }
        }
    }

    function _recipients() internal view returns (address[] memory recipients) {
        recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = carol;
    }

    function _bps() internal pure returns (uint16[] memory bps) {
        bps = new uint16[](3);
        bps[0] = 5_000;
        bps[1] = 3_000;
        bps[2] = 2_000;
    }

    function _hourFromNow() internal view returns (uint64) {
        return uint64(block.timestamp + 3600);
    }

    function _payAndReact(bytes32 id, uint256 amount) internal {
        vm.recordLogs();
        vault.pay{ value: amount }(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault)) {
                _react(_toRecord(logs[i], uint256(keccak256(abi.encode(id, amount, i))), i));
            }
        }
    }

    function _react(IReactive.LogRecord memory rec) internal {
        vm.recordLogs();
        vm.prank(SYSTEM);
        ledger.react(rec);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == CALLBACK_TOPIC) {
                callbacks += 1;
                (,,, lastPayload) = abi.decode(logs[i].data, (uint256, address, uint64, bytes));
            }
        }
    }

    function _toRecord(Vm.Log memory log, uint256 txHash, uint256 logIndex)
        internal
        view
        returns (IReactive.LogRecord memory rec)
    {
        rec.chainId = BASE;
        rec.contractAddress = log.emitter;
        rec.topic0 = uint256(log.topics[0]);
        if (log.topics.length > 1) rec.topic1 = uint256(log.topics[1]);
        if (log.topics.length > 2) rec.topic2 = uint256(log.topics[2]);
        if (log.topics.length > 3) rec.topic3 = uint256(log.topics[3]);
        rec.data = log.data;
        rec.opCode = log.topics.length;
        rec.txHash = txHash;
        rec.logIndex = logIndex;
        rec.blockNumber = block.number;
    }

    function _countCallbacks(address to, bytes memory data) internal returns (uint256 extra) {
        vm.recordLogs();
        (bool ok, bytes memory err) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == CALLBACK_TOPIC) extra += 1;
        }
    }

    function _deliverLatest() internal {
        bytes memory payload = lastPayload;
        require(payload.length >= 36, "no callback");
        bytes20 sender = bytes20(address(ledger));
        for (uint256 i; i < 20; ++i) {
            payload[16 + i] = sender[i];
        }
        vm.prank(address(relay._SERVICE_PROVIDER()));
        (bool ok, bytes memory err) = address(relay).call(payload);
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }
}
