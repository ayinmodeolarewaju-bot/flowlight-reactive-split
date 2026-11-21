#!/usr/bin/env bash
# Deploy InvoiceVault and PayoutRelay on Base Sepolia, and SplitLedger on Reactive Lasna.
# The key file stays outside the repo. This script never prints it.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="${HOME}/.foundry/bin:${PATH}"

KEY_FILE="${DEPLOYER_KEY_FILE:-${HOME}/.config/flowlight-split/deployer.key}"
if [[ ! -f "${KEY_FILE}" ]]; then
  echo "Missing deployer key file: ${KEY_FILE}" >&2
  exit 1
fi
KEY="$(tr -d '[:space:]' < "${KEY_FILE}")"
ADDR="$(cast wallet address --private-key "${KEY}")"

BASE_RPC="${BASE_RPC:-https://sepolia.base.org}"
LASNA_RPC="${LASNA_RPC:-https://lasna-rpc.rnk.dev/}"
PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
SYSTEM="0x8888888888888888888888888888888888888888"
FAUCET="0x2afaFD298b23b62760711756088F75B7409f5967"
# 0.005 ETH -> 0.5 lREACT. Leaves the rest of the deployer balance on Base.
FUND_ETH="${FUND_ETH:-0.005}"
LEDGER_VALUE="${LEDGER_VALUE:-0.12ether}"
RELAY_RESERVE="${RELAY_RESERVE:-0.00008ether}"

echo "Deployer ${ADDR}"

parse_create() {
  python3 -c '
import json,sys
raw=sys.stdin.read()
start=raw.find("{")
end=raw.rfind("}")
if start<0 or end<start:
    sys.stderr.write(raw)
    raise SystemExit("forge create did not return JSON")
data=json.loads(raw[start:end+1])
print(data.get("deployedTo") or data.get("deployed_to") or "")
print(data.get("transactionHash") or data.get("transaction_hash") or "")
'
}

echo "Base balance: $(cast balance "${ADDR}" --rpc-url "${BASE_RPC}" --ether) ETH"
echo "Lasna balance before funding: $(cast balance "${ADDR}" --rpc-url "${LASNA_RPC}" --ether) lREACT"

if [[ "${SKIP_FAUCET:-0}" != "1" ]]; then
  echo "Requesting lREACT from the Base Sepolia Reactive faucet (${FUND_ETH} ETH)"
  cast send "${FAUCET}" "request(address)" "${ADDR}" \
    --value "${FUND_ETH}ether" \
    --rpc-url "${BASE_RPC}" \
    --private-key "${KEY}" \
    --json > /tmp/flowlight-faucet.json
  python3 -c 'import json; d=json.load(open("/tmp/flowlight-faucet.json")); print("faucet tx", d.get("transactionHash"))'
  echo "Waiting for lREACT on Lasna"
  for _ in $(seq 1 40); do
    BAL="$(cast balance "${ADDR}" --rpc-url "${LASNA_RPC}")"
    if [[ "${BAL}" != "0" ]]; then
      echo "Lasna balance: $(cast --to-unit "${BAL}" ether) lREACT"
      break
    fi
    sleep 3
  done
fi

BASE_BLOCK="$(cast block-number --rpc-url "${BASE_RPC}")"
LASNA_BLOCK="$(cast block-number --rpc-url "${LASNA_RPC}")"

echo "Deploying InvoiceVault on Base Sepolia"
VAULT_OUT="$(forge create src/InvoiceVault.sol:InvoiceVault \
  --rpc-url "${BASE_RPC}" --private-key "${KEY}" --broadcast --json --legacy)"
mapfile -t VAULT_PARSED < <(printf '%s' "${VAULT_OUT}" | parse_create)
VAULT="${VAULT_PARSED[0]}"
VAULT_TX="${VAULT_PARSED[1]}"
echo "InvoiceVault ${VAULT} tx ${VAULT_TX}"

echo "Deploying SplitLedger on Lasna (subscribes to the vault)"
# forge create's gas estimate rejects this init code ("code storage out of gas").
# Send the creation transaction with an explicit limit instead. 3.2M covers the
# ~2.1M actually used, and at 100 gwei it fits in a 0.5 lREACT balance alongside --value.
BYTECODE="$(forge inspect src/SplitLedger.sol:SplitLedger bytecode)"
ARGS="$(cast abi-encode "constructor(uint256,uint256,address)" 84532 84532 "${VAULT}")"
LEDGER_OUT="$(cast send --rpc-url "${LASNA_RPC}" --private-key "${KEY}" --json \
  --value "${LEDGER_VALUE}" --gas-limit 3200000 --gas-price 100gwei \
  --create "${BYTECODE}${ARGS#0x}")"
LEDGER="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["contractAddress"])' <<< "${LEDGER_OUT}")"
LEDGER_TX="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])' <<< "${LEDGER_OUT}")"
echo "SplitLedger ${LEDGER} tx ${LEDGER_TX}"

echo "Deploying PayoutRelay on Base Sepolia"
RELAY_OUT="$(forge create src/PayoutRelay.sol:PayoutRelay \
  --rpc-url "${BASE_RPC}" --private-key "${KEY}" --broadcast --json --legacy \
  --constructor-args "${PROXY}" "${LEDGER}" "${VAULT}")"
mapfile -t RELAY_PARSED < <(printf '%s' "${RELAY_OUT}" | parse_create)
RELAY="${RELAY_PARSED[0]}"
RELAY_TX="${RELAY_PARSED[1]}"
echo "PayoutRelay ${RELAY} tx ${RELAY_TX}"

echo "Linking relay and destination"
SET_RELAY="$(cast send "${VAULT}" "setRelay(address)" "${RELAY}" --rpc-url "${BASE_RPC}" --private-key "${KEY}" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
SET_DEST="$(cast send "${LEDGER}" "setDestination(address)" "${RELAY}" --rpc-url "${LASNA_RPC}" --private-key "${KEY}" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
echo "setRelay ${SET_RELAY}"
echo "setDestination ${SET_DEST}"

echo "Reserving callback gas on the Base Sepolia proxy"
RESERVE_TX="$(cast send "${PROXY}" "depositTo(address)" "${RELAY}" --value "${RELAY_RESERVE}" --rpc-url "${BASE_RPC}" --private-key "${KEY}" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
echo "depositTo ${RESERVE_TX}"

LEFT="$(cast balance "${ADDR}" --rpc-url "${LASNA_RPC}")"
KEEP="10000000000000000"
if [[ "${LEFT}" -gt "$((KEEP * 3))" ]]; then
  TOPUP="$((LEFT - KEEP))"
  echo "Moving spare lREACT into the ledger reserves"
  TOPUP_TX="$(cast send "${SYSTEM}" "depositTo(address)" "${LEDGER}" --value "${TOPUP}" --rpc-url "${LASNA_RPC}" --private-key "${KEY}" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionHash"])')"
  echo "ledger depositTo ${TOPUP_TX}"
fi

python3 - << PY
import json
from pathlib import Path
doc = {
  "deployer": "${ADDR}",
  "track": "Set It and Forget It",
  "baseSepolia": {
    "chainId": 84532,
    "name": "Base Sepolia",
    "rpc": "${BASE_RPC}",
    "explorer": "https://sepolia.basescan.org",
    "callbackProxy": "${PROXY}",
    "invoiceVault": "${VAULT}",
    "payoutRelay": "${RELAY}",
    "startBlock": int("${BASE_BLOCK}"),
    "deployTx": {"invoiceVault": "${VAULT_TX}", "payoutRelay": "${RELAY_TX}", "setRelay": "${SET_RELAY}", "reserve": "${RESERVE_TX}"}
  },
  "lasna": {
    "chainId": 5318007,
    "name": "Reactive Lasna",
    "rpc": "${LASNA_RPC}",
    "explorer": "https://lasna.reactscan.net",
    "system": "${SYSTEM}",
    "splitLedger": "${LEDGER}",
    "startBlock": int("${LASNA_BLOCK}"),
    "deployTx": {"splitLedger": "${LEDGER_TX}", "setDestination": "${SET_DEST}"}
  },
  "loop": {}
}
Path("deployments/addresses.json").write_text(json.dumps(doc, indent=2) + "\n")
print("wrote deployments/addresses.json")
PY
cp deployments/addresses.json web/src/addresses.json

echo "Done."
