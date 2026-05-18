from __future__ import annotations

import hashlib
import json
from typing import Any, Optional


class FakeMCPServer:
    def __init__(self, tools: Optional[list[dict[str, Any]]] = None):
        self.tools = tools or []
        self.calls: list[dict[str, Any]] = []

    def handle(self, request: dict[str, Any]) -> dict[str, Any]:
        self.calls.append(request)
        method = request["method"]
        if method == "initialize":
            return {"jsonrpc": "2.0", "id": request["id"], "result": {"protocolVersion": "2024-11-05"}}
        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": request["id"], "result": {"tools": self.tools}}
        if method == "tools/call":
            return {"jsonrpc": "2.0", "id": request["id"], "result": {"content": [{"type": "text", "text": "ok"}]}}
        return {"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "not found"}}


def schema_hash(tools: list[dict[str, Any]]) -> str:
    payload = json.dumps(tools, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


class MCPClient:
    def __init__(self, server: FakeMCPServer):
        self.server = server
        self.next_id = 1
        self.degraded = False
        self.last_schema_hash: Optional[str] = None

    def _rpc(self, method: str, params: Optional[dict[str, Any]] = None) -> Any:
        request = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        self.next_id += 1
        if params is not None:
            request["params"] = params
        response = self.server.handle(request)
        if "error" in response:
            self.degraded = True
            raise RuntimeError(response["error"]["message"])
        return response["result"]

    def initialize(self) -> dict[str, Any]:
        return self._rpc("initialize", {"clientInfo": {"name": "GitCodeMonitor"}})

    def list_tools(self) -> list[dict[str, Any]]:
        result = self._rpc("tools/list")
        tools = list(result.get("tools", []))
        current_hash = schema_hash(tools)
        if self.last_schema_hash is not None and self.last_schema_hash != current_hash:
            self.degraded = True
        self.last_schema_hash = current_hash
        return tools

    def call_tool(self, name: str, arguments: dict[str, Any]) -> Any:
        return self._rpc("tools/call", {"name": name, "arguments": arguments})
