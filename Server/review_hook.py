#!/usr/bin/env python3
"""Official PreToolUse bridge; every failure denies, never silently proceeds."""
import json
import os
import socket
import sys


def decision():
    mode = os.environ.get("AGY_IPHONE_PERMISSION", "")
    if mode == "turbo":
        return {"decision": "allow", "reason": "User selected Turbo Mode for this turn; CLI deny/ask rules still apply."}
    if mode != "review":
        return {"decision": "deny", "reason": "This isolated profile requires the AGY iPhone gateway for tool execution."}
    payload = json.loads(sys.stdin.buffer.read(256 * 1024 + 1))
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(580)
        connection.connect(os.environ["AGY_IPHONE_REVIEW_SOCKET"])
        wire = {"token": os.environ["AGY_IPHONE_RUN_TOKEN"], "payload": payload}
        connection.sendall(json.dumps(wire).encode() + b"\n")
        with connection.makefile("rb") as stream:
            reply = json.loads(stream.readline(4096))
    return {"decision": "auto_approve" if reply.get("decision") == "allow" else "deny",
            "reason": "Explicit one-time decision from AGY iPhone; no permission grant is cached."}


if __name__ == "__main__":
    try:
        result = decision()
    except BaseException:
        result = {"decision": "deny", "reason": "Native approval unavailable, expired, interrupted or invalid. Tool blocked."}
    print(json.dumps(result))
