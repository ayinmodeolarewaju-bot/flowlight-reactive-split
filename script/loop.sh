#!/usr/bin/env bash
# Pay an invoice in two transfers and wait until the Reactive callback settles it.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="${HOME}/.foundry/bin:${PATH}"

KEY_FILE="${DEPLOYER_KEY_FILE:-${HOME}/.config/flowlight-split/deployer.key}"
KEY="$(tr -d '[:space:]' < "${KEY_FILE}")"
ADDR="$(cast wallet address --private-key "${KEY}")"
BASE_RPC="${BASE_RPC:-https://sepolia.base.org}"
LASNA_RPC="${LASNA_RPC:-https://lasna-rpc.rnk.dev/}"

eval "$(python3 - << 'PY'
import json
d=json.load(open("deployments/addresses.json"))
print(f'VAULT={d["baseSepolia"]["invoiceVault"]}')
print(f'LEDGER={d["lasna"]["splitLedger"]}')
print(f'BASE_START={d["baseSepolia"].get("startBlock", 0)}')
print(f'LASNA_START={d["lasna"].get("startBlock", 0)}')
PY
)"

R1="${R1:-$(sed -n '1p' "${HOME}/.config/flowlight-split/recipients.txt")}"
R2="${R2:-$(sed -n '2p' "${HOME}/.config/flowlight-split/recipients.txt")}"
DUE="$(($(date +%s) + 7 * 24 * 3600))"
ID="$(cast keccak "flowlight-split-${ADDR}-$(date +%s)")"
# 0.0001 ETH invoice. First payment is 40%, second completes it.
TOTAL="100000000000000"
PART="40000000000000"
REST="60000000000000"

echo "Invoice ${ID}"
echo "Recipients ${ADDR} 50% / ${R1} 30% / ${R2} 20%"

txhash() { python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])'; }

echo "Creating invoice"
CREATE="$(cast send "${VAULT}" \
  "createInvoice(bytes32,uint256,uint64,address[],uint16[])" \
  "${ID}" "${TOTAL}" "${DUE}" \
  "[${ADDR},${R1},${R2}]" "[5000,3000,2000]" \
  --rpc-url "${BASE_RPC}" --private-key "${KEY}" --json | txhash)"
echo "create ${CREATE}"

echo "Paying 40%"
PAY1="$(cast send "${VAULT}" "pay(bytes32)" "${ID}" --value "${PART}" \
  --rpc-url "${BASE_RPC}" --private-key "${KEY}" --json | txhash)"
echo "partial ${PAY1}"

echo "Waiting so the partial payment is a separate reactive transaction"
sleep 8

echo "Paying the rest"
PAY2="$(cast send "${VAULT}" "pay(bytes32)" "${ID}" --value "${REST}" \
  --rpc-url "${BASE_RPC}" --private-key "${KEY}" --json | txhash)"
echo "final ${PAY2}"

SETTLE_TOPIC="$(cast keccak "SplitSettled(bytes32,address[],uint256[])")"
REQUEST_TOPIC="$(cast keccak "SplitRequested(bytes32,uint256,uint8)")"
SETTLE_TX=""
REACT_TX=""

find_log() {
  python3 - "$1" "$2" "$3" "$4" "$5" << 'PY'
import json, sys, urllib.request
rpc, address, topic0, invoice, start = sys.argv[1:]
def call(method, params):
    body=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req=urllib.request.Request(rpc, data=body, headers={"content-type":"application/json"})
    with urllib.request.urlopen(req, timeout=30) as res:
        return json.load(res)["result"]
latest=int(call("eth_blockNumber", []), 16)
begin=int(start)
want=invoice.lower()
while begin <= latest:
    end=min(begin+199, latest)
    logs=call("eth_getLogs", [{
        "fromBlock": hex(begin),
        "toBlock": hex(end),
        "address": address,
        "topics": [topic0, want],
    }])
    if logs:
        print(logs[-1]["transactionHash"])
        return
    begin=end+1
PY
}

echo "Waiting for the callback"
for _ in $(seq 1 40); do
  SETTLE_TX="$(find_log "${BASE_RPC}" "${VAULT}" "${SETTLE_TOPIC}" "${ID}" "${BASE_START}" || true)"
  if [[ -n "${SETTLE_TX}" ]]; then
    break
  fi
  sleep 3
done
REACT_TX="$(find_log "${LASNA_RPC}" "${LEDGER}" "${REQUEST_TOPIC}" "${ID}" "${LASNA_START}" || true)"

python3 - << PY
import json
from pathlib import Path
p=Path("deployments/addresses.json")
doc=json.loads(p.read_text())
doc["loop"]={
  "invoiceId": "${ID}",
  "amountWei": "${TOTAL}",
  "dueAt": ${DUE},
  "recipients": [
    {"address": "${ADDR}", "bps": 5000},
    {"address": "${R1}", "bps": 3000},
    {"address": "${R2}", "bps": 2000}
  ],
  "createInvoice": "${CREATE}",
  "paymentPartial": "${PAY1}",
  "paymentFinal": "${PAY2}",
  "reactiveTx": "${REACT_TX}",
  "callbackTx": "${SETTLE_TX}"
}
p.write_text(json.dumps(doc, indent=2)+"\n")
print(json.dumps(doc["loop"], indent=2))
PY
cp deployments/addresses.json web/src/addresses.json

if [[ -z "${SETTLE_TX}" ]]; then
  echo "Callback not observed yet. Re-run this script's wait, or trace the final payment with Reactive MCP." >&2
  exit 2
fi
echo "Full loop recorded."
