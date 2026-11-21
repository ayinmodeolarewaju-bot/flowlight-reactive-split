import { useEffect, useMemo, useRef, useState } from "react";
import {
  createPublicClient,
  createWalletClient,
  custom,
  decodeEventLog,
  formatEther,
  http,
  keccak256,
  parseEther,
  toHex,
  type Address,
  type Hex,
  type Log,
} from "viem";
import { baseSepolia } from "viem/chains";
import addresses from "./addresses.json";
import { ledgerAbi, vaultAbi } from "./abi";
import { drawStage, type FlowArc, type FlowNode } from "./flow";

const ZERO = "0x0000000000000000000000000000000000000000";
const vault = addresses.baseSepolia.invoiceVault as Address;
const ledger = addresses.lasna.splitLedger as Address;
const deployed = vault !== ZERO && ledger !== ZERO;

const lasna = {
  id: addresses.lasna.chainId,
  name: "Reactive Lasna",
  nativeCurrency: { name: "lREACT", symbol: "lREACT", decimals: 18 },
  rpcUrls: { default: { http: [addresses.lasna.rpc] } },
} as const;

const baseClient = createPublicClient({ chain: baseSepolia, transport: http(addresses.baseSepolia.rpc) });
const lasnaClient = createPublicClient({ chain: lasna, transport: http(addresses.lasna.rpc) });

type Row = { address: string; percent: string };
type TxLink = { label: string; href: string };

type EthereumProvider = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
};

declare global {
  interface Window {
    ethereum?: EthereumProvider;
  }
}

const previewNodes = (): FlowNode[] => [
  { id: "payer", label: "Client", sub: "pays the invoice", x: 0.16, y: 0.62, color: "#9db4ff", live: true },
  { id: "vault", label: "Invoice vault", sub: "Base Sepolia", x: 0.42, y: 0.58, color: "#6ecbff", live: true },
  { id: "reactive", label: "Reactive Omni", sub: "Lasna ledger", x: 0.48, y: 0.22, color: "#d2b4ff", live: true },
  { id: "a", label: "You", sub: "50%", x: 0.78, y: 0.3, color: "#7dffe8", live: true },
  { id: "b", label: "Collab", sub: "30%", x: 0.8, y: 0.52, color: "#7dffe8", live: true },
  { id: "c", label: "Collab", sub: "20%", x: 0.76, y: 0.74, color: "#c6ff73", live: true },
];

function short(value: string) {
  if (!value || value.length < 12) return value;
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

function explorerTx(base: string, hash: string) {
  return `${base}/tx/${hash}`;
}

export function App() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const nodesRef = useRef<FlowNode[]>(previewNodes());
  const arcsRef = useRef<FlowArc[]>([]);
  const [account, setAccount] = useState<Address | null>(null);
  const [label, setLabel] = useState("April redesign");
  const [amount, setAmount] = useState("0.0001");
  const [noDeadline, setNoDeadline] = useState(false);
  const [rows, setRows] = useState<Row[]>([
    { address: "", percent: "50" },
    { address: "", percent: "30" },
    { address: "", percent: "20" },
  ]);
  const [payAmount, setPayAmount] = useState("0.00004");
  const seeded = (addresses.loop as { invoiceId?: Hex }).invoiceId ?? null;
  const [invoiceId, setInvoiceId] = useState<Hex | null>(seeded);
  const [status, setStatus] = useState(
    deployed
      ? "Create an invoice, pay it in pieces, and leave the tab. The split still settles."
      : "Contracts are not filled in yet. The preview still draws the path the payment will take.",
  );
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [links, setLinks] = useState<TxLink[]>([]);
  const seenRef = useRef(new Set<string>());

  const percentSum = rows.reduce((sum, row) => sum + Number(row.percent || 0), 0);

  const nodes = useMemo(() => previewNodes(), []);

  useEffect(() => {
    nodesRef.current = nodes.map((node, index) => {
      if (index === 0 && account) return { ...node, sub: short(account), live: true };
      return node;
    });
  }, [account, nodes]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    let frame = 0;
    const tick = (now: number) => {
      const rect = canvas.getBoundingClientRect();
      const ratio = window.devicePixelRatio || 1;
      canvas.width = Math.max(1, Math.floor(rect.width * ratio));
      canvas.height = Math.max(1, Math.floor(rect.height * ratio));
      const ctx = canvas.getContext("2d");
      if (ctx) {
        ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
        drawStage(ctx, rect.width, rect.height, nodesRef.current, arcsRef.current, now);
      }
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, []);

  function pushArc(arc: Omit<FlowArc, "born">) {
    if (arcsRef.current.some((item) => item.id === arc.id)) return;
    arcsRef.current = [...arcsRef.current, { ...arc, born: performance.now() }];
  }

  function playPreview() {
    arcsRef.current = [];
    nodesRef.current = previewNodes();
    const now = performance.now();
    const script: FlowArc[] = [
      { id: "pay", from: "payer", to: "vault", color: "#9db4ff", weight: 0.7, born: now },
      { id: "react", from: "vault", to: "reactive", color: "#d2b4ff", weight: 0.45, born: now + 700 },
      { id: "a", from: "vault", to: "a", color: "#7dffe8", weight: 0.55, born: now + 1400 },
      { id: "b", from: "vault", to: "b", color: "#7dffe8", weight: 0.35, born: now + 1500 },
      { id: "c", from: "vault", to: "c", color: "#c6ff73", weight: 0.25, born: now + 1600 },
    ];
    arcsRef.current = script.filter((arc) => arc.born <= now);
    window.setTimeout(() => {
      arcsRef.current = script;
    }, 1600);
    setStatus("Preview only. A live invoice uses the contracts, not this replay.");
  }

  async function connect() {
    const ethereum = window.ethereum;
    if (!ethereum) {
      setError("No wallet found in this browser.");
      return;
    }
    setError("");
    try {
      await ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: "0x14a34" }],
      });
    } catch {
      await ethereum.request({
        method: "wallet_addEthereumChain",
        params: [
          {
            chainId: "0x14a34",
            chainName: "Base Sepolia",
            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
            rpcUrls: [addresses.baseSepolia.rpc],
            blockExplorerUrls: [addresses.baseSepolia.explorer],
          },
        ],
      });
    }
    const accounts = (await ethereum.request({ method: "eth_requestAccounts" })) as string[];
    const next = accounts[0] as Address;
    setAccount(next);
    setRows((current) => current.map((row, index) => (index === 0 && !row.address ? { ...row, address: next } : row)));
  }

  function wallet() {
    if (!window.ethereum || !account) throw new Error("Connect a Base Sepolia wallet first.");
    return createWalletClient({ chain: baseSepolia, transport: custom(window.ethereum), account });
  }

  async function remember(hash: Hex, labelText: string, explorer: string) {
    setLinks((current) => [...current, { label: labelText, href: explorerTx(explorer, hash) }]);
  }

  async function createInvoice() {
    if (!deployed) return;
    if (Math.round(percentSum * 100) !== 10000) {
      setError("Percentages must add up to 100.");
      return;
    }
    setBusy(true);
    setError("");
    try {
      const client = wallet();
      const recipients = rows.map((row) => row.address as Address);
      const bps = rows.map((row) => Math.round(Number(row.percent) * 100));
      const dueSeconds = noDeadline
        ? 0n
        : BigInt(Math.floor(Date.now() / 1000) + 7 * 24 * 3600);
      const id = keccak256(toHex(`${label}:${account}:${Date.now()}`));
      const hash = await client.writeContract({
        address: vault,
        abi: vaultAbi,
        functionName: "createInvoice",
        args: [id, parseEther(amount), dueSeconds, recipients, bps],
      });
      setInvoiceId(id);
      await remember(hash, "Create invoice", addresses.baseSepolia.explorer);
      setStatus("Invoice is on Base Sepolia. Pay any amount up to the total. Reactive is already watching.");
      pushArc({ id: `open-${hash}`, from: "payer", to: "vault", color: "#6ecbff", weight: 0.3 });
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Create failed");
    } finally {
      setBusy(false);
    }
  }

  async function payInvoice() {
    if (!deployed || !invoiceId) return;
    setBusy(true);
    setError("");
    try {
      const client = wallet();
      const value = parseEther(payAmount);
      const hash = await client.writeContract({
        address: vault,
        abi: vaultAbi,
        functionName: "pay",
        args: [invoiceId],
        value,
      });
      await remember(hash, "Payment", addresses.baseSepolia.explorer);
      pushArc({
        id: `pay-${hash}`,
        from: "payer",
        to: "vault",
        color: "#9db4ff",
        weight: Math.min(1, Number(payAmount) / Number(amount || 1)),
      });
      setStatus("Payment sent. The ledger applies it on Lasna. A payout starts only when the invoice is full.");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Payment failed");
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    if (!deployed || !invoiceId) return;
    let stop = false;
    const fromBlock = BigInt(addresses.baseSepolia.startBlock || 0);

    async function refresh() {
      try {
        const invoice = await baseClient.readContract({
          address: vault,
          abi: vaultAbi,
          functionName: "invoices",
          args: [invoiceId!],
        });
        const ledgerInvoice = await lasnaClient.readContract({
          address: ledger,
          abi: ledgerAbi,
          functionName: "invoices",
          args: [invoiceId!],
        });
        const acknowledged = await lasnaClient.readContract({
          address: ledger,
          abi: ledgerAbi,
          functionName: "acked",
          args: [invoiceId!],
        });
        if (stop) return;
        const paid = invoice[2];
        const due = invoice[1];
        const settled = invoice[5];
        const configured = ledgerInvoice[5];
        const requested = ledgerInvoice[6];
        nodesRef.current = nodesRef.current.map((node) => {
          if (node.id === "vault") return { ...node, live: true, sub: `${formatEther(paid)} / ${formatEther(due)} ETH` };
          if (node.id === "reactive") return { ...node, live: configured || requested, sub: acknowledged ? "acked" : requested ? "callback requested" : configured ? "tracking" : "waiting" };
          return node;
        });
        if (configured) {
          pushArc({ id: "tracked", from: "vault", to: "reactive", color: "#d2b4ff", weight: 0.4 });
        }
        if (settled) {
          pushArc({ id: "paid-a", from: "vault", to: "a", color: "#7dffe8", weight: 0.55 });
          pushArc({ id: "paid-b", from: "vault", to: "b", color: "#7dffe8", weight: 0.35 });
          pushArc({ id: "paid-c", from: "vault", to: "c", color: "#c6ff73", weight: 0.25 });
          setStatus("Settled. The callback paid the split from the escrow. No keeper was involved.");
        } else if (requested) {
          setStatus("The ledger requested the callback. Waiting for it to land on Base Sepolia.");
        } else if (paid > 0n) {
          setStatus(`Partial payment recorded: ${formatEther(paid)} of ${formatEther(due)} ETH.`);
        }

        const logs = await baseClient.getLogs({
          address: vault,
          fromBlock,
          toBlock: "latest",
          args: { invoiceId: invoiceId! },
          events: vaultAbi.filter((item) => item.type === "event"),
        } as never);
        const reactiveLogs = await lasnaClient.getLogs({
          address: ledger,
          fromBlock: BigInt(addresses.lasna.startBlock || 0),
          toBlock: "latest",
          args: { invoiceId: invoiceId! },
          events: ledgerAbi.filter((item) => item.type === "event"),
        } as never);
        const fresh: TxLink[] = [];
        for (const log of [...(logs as Log[]), ...(reactiveLogs as Log[])]) {
          const hash = log.transactionHash;
          if (!hash || seenRef.current.has(hash)) continue;
          seenRef.current.add(hash);
          const onLasna = (log as { address?: string }).address?.toLowerCase() === ledger.toLowerCase();
          let name = onLasna ? "Reactive transaction" : "Base transaction";
          try {
            const decoded = decodeEventLog({ abi: onLasna ? ledgerAbi : vaultAbi, data: log.data, topics: log.topics });
            name = decoded.eventName;
          } catch {
            /* keep the generic label */
          }
          fresh.push({
            label: name,
            href: explorerTx(onLasna ? addresses.lasna.explorer : addresses.baseSepolia.explorer, hash),
          });
        }
        if (fresh.length) {
          setLinks((current) => {
            const hrefs = new Set(current.map((item) => item.href));
            return [...current, ...fresh.filter((item) => !hrefs.has(item.href))];
          });
        }
      } catch {
        /* public RPCs occasionally time out; the next poll retries */
      }
    }

    void refresh();
    const timer = window.setInterval(() => void refresh(), 4000);
    return () => {
      stop = true;
      window.clearInterval(timer);
    };
  }, [invoiceId]);

  return (
    <div className="app">
      <section className="panel">
        <p className="kicker">KEEPERLESS</p>
        <h1>Invoice splits</h1>
        <p className="lede">
          You propose the recipients and the percentages. The contracts enforce them: approved addresses, a 100% cap, partial payments over time, and a single payout. The callback only accepts the Base Sepolia proxy and this ledger.
        </p>
        <div className="row">
          <span className={deployed ? "badge" : "badge dim"}>{deployed ? "Live testnet" : "Preview"}</span>
          <span className="hint">Base Sepolia → Lasna → Base Sepolia</span>
        </div>

        <label htmlFor="label">Invoice</label>
        <input id="label" value={label} onChange={(event) => setLabel(event.target.value)} />

        <label htmlFor="amount">Amount due (testnet ETH)</label>
        <input id="amount" value={amount} onChange={(event) => setAmount(event.target.value)} inputMode="decimal" />

        <label className="check">
          <input type="checkbox" checked={noDeadline} onChange={(event) => setNoDeadline(event.target.checked)} /> No deadline
        </label>
        <p className="hint">With a deadline, late payments revert and each payer can reclaim after that timestamp. Deadlines use time, not blocks.</p>

        <label>Split</label>
        {rows.map((row, index) => (
          <div className="split" key={index}>
            <input
              aria-label={`Recipient ${index + 1}`}
              placeholder="0x…"
              value={row.address}
              onChange={(event) =>
                setRows((current) => current.map((item, itemIndex) => (itemIndex === index ? { ...item, address: event.target.value } : item)))
              }
            />
            <input
              aria-label={`Percent ${index + 1}`}
              value={row.percent}
              onChange={(event) =>
                setRows((current) => current.map((item, itemIndex) => (itemIndex === index ? { ...item, percent: event.target.value } : item)))
              }
            />
            <button type="button" onClick={() => setRows((current) => current.filter((_, itemIndex) => itemIndex !== index))} disabled={rows.length <= 1}>
              Remove
            </button>
          </div>
        ))}
        <button type="button" onClick={() => setRows((current) => [...current, { address: "", percent: "0" }])} disabled={rows.length >= 8}>
          Add recipient
        </button>
        <p className={Math.round(percentSum * 100) === 10000 ? "hint" : "error"}>Percents total {percentSum}</p>

        <div className="actions">
          <button type="button" onClick={() => void connect()}>{account ? short(account) : "Connect wallet"}</button>
          <button type="button" className="primary" disabled={!deployed || busy || !account} onClick={() => void createInvoice()}>
            Create invoice
          </button>
          <button type="button" onClick={playPreview}>Play the light</button>
        </div>

        <label htmlFor="pay">Pay this much</label>
        <input id="pay" value={payAmount} onChange={(event) => setPayAmount(event.target.value)} inputMode="decimal" />
        <div className="actions">
          <button type="button" className="primary" disabled={!deployed || busy || !invoiceId} onClick={() => void payInvoice()}>
            Pay invoice
          </button>
        </div>

        <p className="status">{status}</p>
        {error ? <p className="error">{error}</p> : null}
        <div className="links">
          {links.map((link) => (
            <a key={link.href} href={link.href} target="_blank" rel="noreferrer">
              {link.label}
            </a>
          ))}
        </div>
      </section>
      <section className="stage-wrap" aria-label="Payment flow">
        <canvas ref={canvasRef} />
        <div className="legend">
          <span className="key"><i className="dot" style={{ color: "#9db4ff" }} /> payment</span>
          <span className="key"><i className="dot" style={{ color: "#d2b4ff" }} /> reactive</span>
          <span className="key"><i className="dot" style={{ color: "#7dffe8" }} /> split</span>
        </div>
      </section>
    </div>
  );
}
