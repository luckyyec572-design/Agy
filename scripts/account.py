#!/usr/bin/env python3
"""Self-service account profiles. Never reads, copies or removes shared credentials."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/"Server"))
import profiles

parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["create", "login", "check", "serve"])
parser.add_argument("name")
parser.add_argument("--agy", default=str(Path.home()/".local/share/agy-iphone/runtime/agy"))
parser.add_argument("--accounts", default=str(Path.home()/".local/share/agy-iphone/accounts"))
parser.add_argument("--key-file")
parser.add_argument("--root", action="append")
args = parser.parse_args()
if not re.fullmatch(r"[a-zA-Z0-9_-]{1,32}", args.name): parser.error("Use a short account label, not an email or a path")
folder = Path(args.accounts).expanduser().resolve()/args.name
home = folder/"home"
identity = profiles.prepare(home)
env = profiles.environment(home)
if args.action == "create":
    print("Created isolated account profile:", args.name)
    print("Login next: python3 scripts/account.py login " + args.name)
elif args.action == "login":
    profiles.check_runtime(args.agy)
    token = home/".gemini/antigravity-cli/antigravity-oauth-token"
    if token.exists():
        raise SystemExit("This profile already has a login. Create a new label for a different Google account; shared or existing credentials will not be deleted.")
    print("Open the CLI authorization URL in a private browser window, choose the NEW Google account, paste the browser code into this SSH terminal, then /exit.", flush=True)
    raise SystemExit(subprocess.call([args.agy], env=env))
elif args.action == "check":
    profiles.check_runtime(args.agy)
    model = subprocess.run([args.agy, "models"], env=env, capture_output=True, text=True, timeout=50)
    quota = subprocess.run([args.agy, "-p", "/usage", "--output-format", "json"], env=env, capture_output=True, text=True, timeout=50)
    try:
        value = json.loads(quota.stdout)
        assert model.returncode == 0 and quota.returncode == 0 and value["status"] == "SUCCESS"
        groups = value["command"]["data"]["groups"]
    except (ValueError, KeyError, AssertionError):
        raise SystemExit("Login verification failed. Complete the CLI OAuth flow first; no existing profile was changed.")
    print("Authenticated profile:", args.name)
    print("Available model variants:", sum("\t" in line for line in model.stdout.splitlines()))
    print("Quota groups:", ", ".join(g["name"] for g in groups))
    print("Profile identifier:", identity)
else:
    if not args.key_file or not args.root: parser.error("serve requires --key-file and one or more --root")
    command = [sys.executable, str(ROOT/"Server/gateway.py"), "--data", str(folder/"data"), "--profile-home", str(home),
               "--agy", args.agy, "--key-file", str(Path(args.key_file).expanduser().resolve())]
    for root in args.root: command += ["--root", root]
    os.execv(sys.executable, command)
