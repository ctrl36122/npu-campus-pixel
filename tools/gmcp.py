#!/usr/bin/env python
"""Godot AI MCP 命令行客户端。

直接走 godot-ai server 的 streamable-http 端点（127.0.0.1:8000/mcp），
不依赖 WorkBuddy 的 MCP 集成。server 需要先跑起来：

    godot-ai.exe attach --port 8000 --ws-port 9500 --disable-telemetry

用法：
    python tools/gmcp.py list                 # 列出工具
    python tools/gmcp.py state                # editor_state
    python tools/gmcp.py call <tool> '<json>' # 调任意工具
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8000"
CAP = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~/AppData/Local")),
    "godot-ai", "capabilities", "http-8000.json",
)
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _token() -> str:
    with open(CAP, encoding="utf-8") as fh:
        return json.load(fh)["http"]


def _parse(resp) -> tuple[dict | None, str | None]:
    ctype = (resp.headers.get("content-type") or "").lower()
    raw = resp.read().decode("utf-8", errors="replace")
    sid = resp.headers.get("mcp-session-id")
    if "text/event-stream" in ctype:
        payloads = [ln[5:].strip() for ln in raw.splitlines() if ln.startswith("data:")]
        raw = payloads[-1] if payloads else ""
    return (json.loads(raw) if raw.strip() else None), sid


def _post(payload: dict, sid: str | None, timeout: float = 180.0):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(BASE + "/mcp", data=data, method="POST")
    req.add_header("Authorization", "Bearer " + _token())
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    if sid:
        req.add_header("Mcp-Session-Id", sid)
    with _OPENER.open(req, timeout=timeout) as resp:
        return _parse(resp)


class Client:
    def __init__(self) -> None:
        self.sid: str | None = None
        body, sid = _post({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05", "capabilities": {},
                "clientInfo": {"name": "gmcp", "version": "1"},
            },
        }, None)
        self.sid = sid
        _post({"jsonrpc": "2.0", "method": "notifications/initialized"}, self.sid)
        self.info = (body or {}).get("result", {})

    def rpc(self, method: str, params: dict | None = None, rid: int = 2) -> dict:
        payload = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            payload["params"] = params
        body, _ = _post(payload, self.sid)
        if not body:
            raise RuntimeError(f"empty response for {method}")
        if "error" in body:
            raise RuntimeError(json.dumps(body["error"], ensure_ascii=False))
        return body["result"]

    def list_tools(self) -> list[dict]:
        return self.rpc("tools/list").get("tools", [])

    def call(self, name: str, args: dict | None = None) -> str:
        res = self.rpc("tools/call", {"name": name, "arguments": args or {}})
        parts = []
        for item in res.get("content", []):
            if item.get("type") == "text":
                parts.append(item.get("text", ""))
            else:
                parts.append(json.dumps(item, ensure_ascii=False))
        return "\n".join(parts) if parts else json.dumps(res, ensure_ascii=False)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 1
    cmd = argv[0]
    cli = Client()
    if cmd == "list":
        for tool in cli.list_tools():
            print(f"- {tool['name']}: {(tool.get('description') or '').splitlines()[0][:110]}")
        return 0
    if cmd == "state":
        print(cli.call("editor_state"))
        return 0
    if cmd == "call":
        if len(argv) < 2:
            print("用法: gmcp.py call <tool> '<json args>'")
            return 1
        args = json.loads(argv[2]) if len(argv) > 2 else {}
        print(cli.call(argv[1], args))
        return 0
    print(f"未知命令: {cmd}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
