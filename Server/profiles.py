"""Dedicated CLI home: account credentials and hook settings never touch shared AGY."""
import json
import os
from pathlib import Path
import shlex
import sys
import uuid
import subprocess


def check_runtime(binary):
    result = subprocess.run([binary, "--help"], capture_output=True, text=True, timeout=15)
    if result.returncode or "--settings" not in result.stdout + result.stderr:
        raise ValueError("This release requires AGY CLI 1.4.10+ with session-only --settings. Update the gateway runtime first.")


def prepare(home):
    home = Path(home).resolve()
    if home == Path.home().resolve():
        raise ValueError("Use a dedicated --profile-home, not your normal login home")
    config = home / ".gemini/config"
    config.mkdir(parents=True, exist_ok=True, mode=0o700)
    home.chmod(0o700)
    identity = home / "profile.json"
    if not identity.exists():
        identity.write_text(json.dumps({"id": str(uuid.uuid4()), "name": home.parent.name}))
        identity.chmod(0o600)
    hooks_file = config / "hooks.json"
    hooks = json.loads(hooks_file.read_text()) if hooks_file.exists() else {}
    hook = Path(__file__).with_name("review_hook.py").resolve()
    hooks["agy-iphone-native-review"] = {"PreToolUse": [{"matcher": "*", "hooks": [{
        "type": "command", "command": shlex.quote(sys.executable) + " " + shlex.quote(str(hook)), "timeout": 600}]}]}
    hooks_file.write_text(json.dumps(hooks, indent=2))
    hooks_file.chmod(0o600)
    return json.loads(identity.read_text())["id"]


def environment(home):
    result = os.environ.copy()
    if home is not None:
        result["HOME"] = str(Path(home).resolve())
        result["SSH_CONNECTION"] = result.get("SSH_CONNECTION") or "127.0.0.1 0 127.0.0.1 0"
    return result
