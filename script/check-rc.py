#!/usr/bin/env python3
"""Ask the public Reactive MCP to check SplitLedger and PayoutRelay before a deploy."""

import json
import urllib.request
from pathlib import Path

URL = "https://mcp.rnk.dev/mcp"
ROOT = Path(__file__).resolve().parents[1]


def rpc(method: str, params: dict | None, req_id: int) -> dict:
    payload = {"jsonrpc": "2.0", "id": req_id, "method": method}
    if params is not None:
        payload["params"] = params
    request = urllib.request.Request(
        URL,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        raw = response.read().decode()
    if raw.startswith("event:") or "\ndata:" in raw:
        data_lines = [line[5:].strip() for line in raw.splitlines() if line.startswith("data:")]
        raw = data_lines[-1]
    return json.loads(raw)


def tool(name: str, arguments: dict, req_id: int) -> dict:
    return rpc("tools/call", {"name": name, "arguments": arguments}, req_id)


def text_of(result: dict) -> str:
    content = result.get("result", {}).get("content", [])
    return "\n".join(part.get("text", "") for part in content if part.get("type") == "text")


def main() -> None:
    rpc(
        "initialize",
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "flowlight-split", "version": "0.1.0"},
        },
        1,
    )
    checks = [
        ("SplitLedger", ROOT / "src" / "SplitLedger.sol", "reactive"),
        ("PayoutRelay", ROOT / "src" / "PayoutRelay.sol", "callback"),
    ]
    failed = False
    for index, (label, path, kind) in enumerate(checks, start=2):
        result = tool("check_rc_source", {"source": path.read_text(), "kind": kind}, index)
        summary = text_of(result).strip() or json.dumps(result)[:500]
        print(f"{label}: {summary.splitlines()[0]}")
        verdict = result.get("result", {}).get("structuredContent", {}).get("verdict", "")
        if verdict and not str(verdict).startswith("OK"):
            failed = True
            print(summary)
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
