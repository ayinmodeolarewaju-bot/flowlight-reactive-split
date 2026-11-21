export const vaultAbi = [
  {
    type: "function",
    name: "createInvoice",
    stateMutability: "nonpayable",
    inputs: [
      { name: "invoiceId", type: "bytes32" },
      { name: "amountDue", type: "uint256" },
      { name: "dueAt", type: "uint64" },
      { name: "recipients", type: "address[]" },
      { name: "bps", type: "uint16[]" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "pay",
    stateMutability: "payable",
    inputs: [{ name: "invoiceId", type: "bytes32" }],
    outputs: [],
  },
  {
    type: "function",
    name: "invoices",
    stateMutability: "view",
    inputs: [{ name: "invoiceId", type: "bytes32" }],
    outputs: [
      { name: "issuer", type: "address" },
      { name: "amountDue", type: "uint256" },
      { name: "paid", type: "uint256" },
      { name: "dueAt", type: "uint64" },
      { name: "exists", type: "bool" },
      { name: "settled", type: "bool" },
      { name: "settledAmount", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "recipientsOf",
    stateMutability: "view",
    inputs: [{ name: "invoiceId", type: "bytes32" }],
    outputs: [
      { name: "recipients", type: "address[]" },
      { name: "bps", type: "uint16[]" },
    ],
  },
  {
    type: "event",
    name: "PaymentReceived",
    inputs: [
      { name: "invoiceId", type: "bytes32", indexed: true },
      { name: "payer", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "totalPaid", type: "uint256", indexed: false },
      { name: "amountDue", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "SplitSettled",
    inputs: [
      { name: "invoiceId", type: "bytes32", indexed: true },
      { name: "recipients", type: "address[]", indexed: false },
      { name: "amounts", type: "uint256[]", indexed: false },
    ],
  },
] as const;

export const ledgerAbi = [
  {
    type: "function",
    name: "invoices",
    stateMutability: "view",
    inputs: [{ name: "invoiceId", type: "bytes32" }],
    outputs: [
      { name: "issuer", type: "address" },
      { name: "amountDue", type: "uint256" },
      { name: "paid", type: "uint256" },
      { name: "dueAt", type: "uint64" },
      { name: "recipients", type: "uint8" },
      { name: "configured", type: "bool" },
      { name: "payoutRequested", type: "bool" },
    ],
  },
  {
    type: "function",
    name: "acked",
    stateMutability: "view",
    inputs: [{ name: "invoiceId", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "event",
    name: "InvoiceTracked",
    inputs: [
      { name: "invoiceId", type: "bytes32", indexed: true },
      { name: "issuer", type: "address", indexed: true },
      { name: "amountDue", type: "uint256", indexed: false },
      { name: "recipients", type: "uint8", indexed: false },
    ],
  },
  {
    type: "event",
    name: "PaymentApplied",
    inputs: [
      { name: "invoiceId", type: "bytes32", indexed: true },
      { name: "totalPaid", type: "uint256", indexed: false },
      { name: "amountDue", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "SplitRequested",
    inputs: [
      { name: "invoiceId", type: "bytes32", indexed: true },
      { name: "total", type: "uint256", indexed: false },
      { name: "recipients", type: "uint8", indexed: false },
    ],
  },
] as const;
