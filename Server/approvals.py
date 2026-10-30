"""One-run capabilities over a private Unix socket; native decisions are single-use."""
import hmac
import json
import os
from pathlib import Path
import secrets
import socketserver
import threading
import time
import uuid


class ApprovalBridge:
    def __init__(self, path, changed, timeout=540):
        self.path = str(path)
        self.changed = changed
        self.timeout = timeout
        self.lock = threading.RLock()
        self.tokens = {}
        self.requests = {}
        bridge = self
        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                self.request.settimeout(20)
                try:
                    line = self.rfile.readline(256 * 1024 + 1)
                    if len(line) > 256 * 1024: raise ValueError()
                    value = json.loads(line)
                    reply = bridge.wait(value.get("token", ""), value.get("payload", {}))
                except Exception:
                    reply = "deny"
                self.wfile.write(json.dumps({"decision": reply}).encode() + b"\n")
        class Server(socketserver.ThreadingUnixStreamServer):
            daemon_threads = True
        # A unique socket per process prevents a second gateway stealing a live gate.
        self.server = Server(self.path, Handler)
        os.chmod(self.path, 0o600)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def begin(self, sid):
        token = secrets.token_urlsafe(32)
        with self.lock: self.tokens[token] = sid
        return token

    def wait(self, token, payload):
        with self.lock:
            sid = self.tokens.get(token)
            tool = payload.get("toolCall", {}) if isinstance(payload, dict) else {}
            if sid is None or not isinstance(tool, dict) or not isinstance(tool.get("name"), str):
                return "deny"
            rid = str(uuid.uuid4())
            record = {"id": rid, "sessionID": sid, "tool": tool["name"], "parameters": tool.get("args", {}),
                      "createdAt": time.time(), "expiresAt": time.time() + self.timeout}
            request = {"record": record, "event": threading.Event(), "decision": None, "token": token}
            self.requests[rid] = request
        self.publish(sid)
        request["event"].wait(self.timeout)
        with self.lock:
            allowed = request["decision"] == "allow" and self.tokens.get(token) == sid
            self.requests.pop(rid, None)
        self.publish(sid)
        return "allow" if allowed else "deny"

    def publish(self, sid):
        with self.lock:
            records = [r["record"] for r in self.requests.values() if r["record"]["sessionID"] == sid and r["decision"] is None]
        self.changed(sid, records)

    def answer(self, sid, rid, decision):
        if decision not in ("allow", "deny"): raise ValueError("审批结果无效")
        with self.lock:
            request = self.requests.get(rid)
            if request is None or request["record"]["sessionID"] != sid or request["decision"] is not None or time.time() >= request["record"]["expiresAt"]:
                raise ValueError("审批已失效或已处理，请刷新会话")
            request["decision"] = decision
            request["event"].set()
        self.publish(sid)

    def finish(self, token):
        with self.lock:
            sid = self.tokens.pop(token, None)
            for request in self.requests.values():
                if request["token"] == token:
                    request["decision"] = "deny"; request["event"].set()
        if sid: self.publish(sid)

    def cancel(self, sid):
        with self.lock: tokens = [token for token, value in self.tokens.items() if value == sid]
        for token in tokens: self.finish(token)

    def close(self):
        with self.lock: tokens = list(self.tokens)
        for token in tokens: self.finish(token)
        self.server.shutdown(); self.server.server_close()
        Path(self.path).unlink(missing_ok=True)
