#!/usr/bin/env python3
"""Authenticated iPhone adapter for agy stream-json. Python 3.10+, no dependencies."""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import threading
import time
import uuid
import tempfile
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs, quote
import catalog
import profiles
from approvals import ApprovalBridge

MAX_BODY = 256 * 1024
MAX_FILE = 25 * 1024 * 1024
MAX_ATTACHMENTS = 8
MAX_TOTAL = 50 * 1024 * 1024


class Failure(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


class Gateway:
    def __init__(self, directory, key, binary, roots, default_model="", command_prefix=None, profile_home=None):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.key = key
        if len(key) < 32:
            raise ValueError("Gateway key must contain at least 32 characters")
        self.binary = binary
        self.prefix = command_prefix or []
        self.profile_home = Path(profile_home).resolve() if profile_home else None
        self.account_profile = profiles.prepare(self.profile_home) if self.profile_home else "legacy"
        self.env = profiles.environment(self.profile_home)
        self.roots = [Path(r).resolve(strict=True) for r in roots]
        self.default_model = default_model
        self.lock = threading.RLock()
        self.processes = {}
        self.active = set()
        self.stopping = set()
        self.db = sqlite3.connect(self.directory / "gateway.sqlite", check_same_thread=False)
        os.chmod(self.directory / "gateway.sqlite", 0o600)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        self.db.execute("CREATE TABLE IF NOT EXISTS requests (id TEXT PRIMARY KEY, session TEXT NOT NULL, digest TEXT NOT NULL)")
        self.db.execute("CREATE TABLE IF NOT EXISTS attachments (id TEXT PRIMARY KEY, session TEXT NOT NULL, data TEXT NOT NULL)")
        self.db.commit()
        self.models_cache = None
        self.limits_cache = None
        self.review = None
        self.review_directory = None
        if self.profile_home:
            self.review_directory = tempfile.TemporaryDirectory(prefix="agy-review-")
            self.review = ApprovalBridge(Path(self.review_directory.name)/"gate.sock", self.approvals_changed)
        # Never resubmit an admitted prompt after a crash/restart.
        for s in self.sessions():
            if s["running"]:
                s["running"] = False
                s["approvals"] = []
                s["error"] = "服务器已重启。请检查回复后再发送，未自动重试任务。"
                self.save(s)

    def save(self, session):
        with self.lock:
            session["revision"] = session.get("revision", 0) + 1
            self.db.execute("INSERT OR REPLACE INTO sessions VALUES (?, ?)", (session["id"], json.dumps(session, ensure_ascii=False)))
            self.db.commit()

    def get(self, sid):
        with self.lock:
            row = self.db.execute("SELECT data FROM sessions WHERE id=?", (sid,)).fetchone()
            if not row:
                raise Failure(404, "会话不存在")
            value = json.loads(row[0])
            effort = value["model"].rsplit("-", 1)[-1]
            value.setdefault("effort", effort if effort in catalog.EFFORTS else "")
            value.setdefault("baseModel", value["model"][:-(len(effort)+1)] if value["effort"] else value["model"])
            value.setdefault("approvalMode", "legacy")
            value.setdefault("approvals", [])
            return value

    def sessions(self):
        with self.lock:
            return sorted([json.loads(r[0]) for r in self.db.execute("SELECT data FROM sessions")], key=lambda s: s["modified"], reverse=True)

    def workspace(self, value):
        try:
            p = Path(value).resolve(strict=True)
        except (OSError, ValueError, TypeError):
            raise Failure(400, "工作目录不存在")
        if not p.is_dir() or not any(p == r or r in p.parents for r in self.roots):
            raise Failure(403, "工作目录不在允许范围内")
        if any(part in {".git", ".gemini", ".ssh", ".aws", ".codex", ".agents"}
               for root in self.roots if p == root or root in p.parents for part in p.relative_to(root).parts):
            raise Failure(403, "不能将凭据或内部配置目录作为工作区")
        return str(p)

    def models(self, refresh=False):
        with self.lock:
            if not refresh and self.models_cache and time.monotonic() - self.models_cache[0] < 300:
                return self.models_cache[1]
        try:
            result = subprocess.run(self.prefix + [self.binary, "models"], capture_output=True, text=True, timeout=40, cwd=self.roots[0], env=self.env)
        except (OSError, subprocess.TimeoutExpired):
            raise Failure(502, "无法获取 AGY 模型，请检查服务器登录和网络")
        if result.returncode:
            raise Failure(502, "AGY 登录或模型请求失败，请在服务器检查 agy models")
        models = []
        for line in result.stdout.splitlines():
            if "\t" in line:
                mid, name = line.split("\t", 1)
                if re.fullmatch(r"[a-zA-Z0-9_.:/-]+", mid):
                    models.append({"id": mid, "name": name})
        if not models:
            raise Failure(502, "AGY 没有返回可用模型")
        with self.lock:
            self.models_cache = (time.monotonic(), models)
        return models

    def limits(self, refresh=False):
        with self.lock:
            if not refresh and self.limits_cache and time.monotonic()-self.limits_cache[0] < 30:
                return self.limits_cache[1]
        try:
            p = subprocess.run(self.prefix + [self.binary, "-p", "/usage", "--output-format", "json"],
                               capture_output=True, text=True, timeout=40, cwd=self.roots[0], env=self.env)
            result = json.loads(p.stdout)
            data = result.get("command", {}).get("data", {})
            if p.returncode or result.get("status") != "SUCCESS" or not isinstance(data.get("groups"), list):
                raise ValueError()
            value = {"fetchedAt": time.time(), "source": "agy /usage", "groups": data["groups"],
                     "description": data.get("description", "")}
        except (OSError, subprocess.TimeoutExpired, ValueError, TypeError):
            raise Failure(502, "无法读取 AGY 额度；请检查登录和 CLI 版本。")
        with self.lock:
            self.limits_cache = (time.monotonic(), value)
        return value

    @staticmethod
    def attachment_info(a):
        return {k: a[k] for k in ("id", "name", "mime", "size", "path")}

    def attachment(self, sid, aid):
        with self.lock:
            row = self.db.execute("SELECT data FROM attachments WHERE id=? AND session=?", (aid, sid)).fetchone()
        if not row:
            raise Failure(400, "附件不属于此会话或已失效")
        return json.loads(row[0])

    def upload(self, sid, name, mime, stream, size):
        s = self.get(sid)
        if not isinstance(name, str) or not name or len(name) > 255 or any(c in name for c in ("/", "\\", "\r", "\n", "\0")):
            raise Failure(400, "附件名称无效")
        if not 0 <= size <= MAX_FILE:
            raise Failure(413, "单个附件不能超过 25 MB")
        mime = mime.split(";", 1)[0][:100]
        if not re.fullmatch(r"[\w.+-]+/[\w.+-]+", mime):
            mime = "application/octet-stream"
        cwd = Path(self.workspace(s["cwd"]))
        aid = str(uuid.uuid4())
        suffix = Path(name).suffix.lower()
        if not re.fullmatch(r"\.[a-z0-9]{1,12}", suffix):
            suffix = ""
        filename = aid + suffix
        descriptors = []
        destination = None
        try:
            fd = os.open(cwd, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            descriptors.append(fd)
            for folder in (".agy-uploads", sid):
                try:
                    os.mkdir(folder, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                fd = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                descriptors.append(fd)
            destination = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            digest = hashlib.sha256()
            with os.fdopen(destination, "wb") as output:
                destination = None
                left = size
                while left:
                    chunk = stream.read(min(left, 65536))
                    if not chunk:
                        raise Failure(400, "附件传输中断")
                    output.write(chunk); digest.update(chunk); left -= len(chunk)
            a = {"id": aid, "name": name, "mime": mime, "size": size,
                 "path": str(cwd / ".agy-uploads" / sid / filename), "sha256": digest.hexdigest()}
            with self.lock:
                self.db.execute("INSERT INTO attachments VALUES (?,?,?)", (aid, sid, json.dumps(a, ensure_ascii=False)))
                self.db.commit()
            return self.attachment_info(a)
        except OSError:
            raise Failure(400, "附件目录不可写或含有无效链接")
        except BaseException:
            if descriptors:
                try:
                    os.unlink(filename, dir_fd=descriptors[-1])
                except FileNotFoundError:
                    pass
            raise
        finally:
            if destination is not None:
                os.close(destination)
            for fd in reversed(descriptors):
                os.close(fd)

    def create(self, body):
        cwd = self.workspace(body.get("cwd") or str(self.roots[0]))
        model, base, effort = self.resolve_configuration(body)
        mode = body.get("mode", "plan")
        if mode not in ("plan", "accept-edits"):
            raise Failure(400, "执行模式无效")
        permission = body.get("approvalMode", "legacy")
        if permission not in ("review", "turbo", "legacy"):
            raise Failure(400, "审批策略无效")
        if permission != "legacy" and self.review is None:
            raise Failure(503, "请先按说明启用独立账号配置和新版审批后端")
        session = {"id": str(uuid.uuid4()), "name": "新会话", "cwd": cwd, "model": model, "mode": mode,
                   "baseModel": base, "effort": effort, "approvalMode": permission, "approvals": [],
                   "modified": time.time(), "messages": [], "running": False, "conversationID": "", "error": "", "revision": 0}
        self.save(session)
        return session

    def resolve_configuration(self, body, current=None):
        model = body.get("baseModel") or body.get("model") or (current or {}).get("baseModel" if "effort" in body else "model") or self.default_model or self.models()[0]["id"]
        try:
            return catalog.resolve(self.models(), model, body.get("effort"))
        except (ValueError, TypeError):
            raise Failure(400, "模型或思考强度不可用，请刷新列表")

    def approvals_changed(self, sid, records):
        with self.lock:
            try: s = self.get(sid)
            except Failure: return
            s["approvals"] = records
            self.save(s)

    def answer_approval(self, sid, rid, decision):
        if not self.review: raise Failure(503, "审批后端未启用")
        try: self.review.answer(sid, rid, decision)
        except ValueError as error: raise Failure(409, str(error))
        return self.get(sid)

    def submit(self, sid, body):
        prompt = body.get("text", "")
        rid = body.get("requestID", "")
        attachment_ids = body.get("attachments", [])
        if not isinstance(attachment_ids, list) or len(attachment_ids) > MAX_ATTACHMENTS or any(not isinstance(a, str) for a in attachment_ids) or len(set(attachment_ids)) != len(attachment_ids):
            raise Failure(400, "最多添加 8 个不同附件")
        file_references = body.get("references", [])
        if not isinstance(file_references, list) or len(file_references) > 8 or any(not isinstance(p, str) for p in file_references) or len(set(file_references)) != len(file_references):
            raise Failure(400, "最多引用 8 个不同工作文件")
        if not isinstance(prompt, str) or not (prompt.strip() or attachment_ids or file_references) or len(prompt.encode()) > 200 * 1024:
            raise Failure(400, "消息为空或过长")
        try:
            uuid.UUID(rid)
        except (ValueError, TypeError, AttributeError):
            raise Failure(400, "缺少有效请求编号")
        digest = hashlib.sha256((prompt + (json.dumps(attachment_ids) if attachment_ids else "")).encode()).hexdigest()
        if file_references:
            digest = hashlib.sha256((digest + json.dumps(file_references, ensure_ascii=False)).encode()).hexdigest()
        with self.lock:
            prior = self.db.execute("SELECT session,digest FROM requests WHERE id=?", (rid,)).fetchone()
            if prior:
                if prior != (sid, digest):
                    raise Failure(409, "请求编号已用于另一条消息")
                return self.get(sid)
            s = self.get(sid)
            if s["running"] or sid in self.active:
                raise Failure(409, "任务仍在运行")
            self.workspace(s["cwd"])
            attached = [self.attachment(sid, aid) for aid in attachment_ids]
            if sum(a["size"] for a in attached) > MAX_TOTAL:
                raise Failure(413, "附件合计不能超过 50 MB")
            referenced = []
            for path in file_references:
                is_directory = False
                try:
                    stream, name, size = self.open_file(sid, path, directory=True)
                    is_directory = True
                except Failure:
                    stream, name, size = self.open_file(sid, path)
                    with stream: pass
                referenced.append({"id": path, "name": name, "path": path, "size": size,
                                   "mime": "inode/directory" if is_directory else mimetypes.guess_type(name)[0] or "application/octet-stream"})
            references = "\n".join(json.dumps({"name": a["name"], "path": a["path"], "type": "directory" if a["mime"] == "inode/directory" else "file"}, ensure_ascii=False) for a in attached + referenced)
            cli_prompt = prompt
            if attached or referenced:
                cli_prompt = (prompt or "请查看这些引用的文件或文件夹。") + "\n\nReferenced files and directories (full paths identify the selected context; use reading tools as needed; directory references refer to the whole folder, not a preloaded archive):\n" + references
            s["messages"].append({"id": rid, "role": "user", "text": prompt, "attachments": [self.attachment_info(a) for a in attached] + referenced})
            s["messages"].append({"id": str(uuid.uuid4()), "role": "assistant", "text": "", "tools": []})
            if s["name"] == "新会话":
                s["name"] = prompt.strip()[:40] or (attached + referenced)[0]["name"][:40]
            s["running"], s["error"], s["modified"] = True, "", time.time()
            # One transaction admits both the user message and its deduplication key.
            self.db.execute("INSERT INTO requests VALUES (?,?,?)", (rid, sid, digest))
            self.save(s)
            self.active.add(sid)
            threading.Thread(target=self.run, args=(sid, cli_prompt), daemon=True).start()
            return s

    def ingest(self, sid, event):
        with self.lock:
            s = self.get(sid)
            m = s["messages"][-1]
            kind = event.get("event")
            cid = event.get("conversation_id") or event.get("result", {}).get("conversation_id")
            if cid:
                try:
                    uuid.UUID(cid)
                    s["conversationID"] = cid
                except (ValueError, TypeError):
                    pass
            if kind == "step_update":
                step = event.get("step_update", {})
                if step.get("step_type") == "agent_response":
                    idx = step.get("step_index", 0)
                    parts = m.setdefault("steps", [])
                    item = next((v for v in parts if v["index"] == idx), None)
                    if item is None:
                        item = {"index": idx, "text": ""}; parts.append(item)
                    item["text"] += step.get("text_delta", "")
                    m["text"] = item["text"]
                if step.get("step_type") == "tool":
                    # Tool events may carry ACTIVE followed by DONE: replace by step identity.
                    info = step.get("tool_info", {})
                    tool = {"id": str(step.get("step_index", 0)), "name": step.get("tool_name") or info.get("name", "工具"),
                            "state": step.get("state", ""), "parameters": info.get("parameters", {}), "output": str(info.get("output", ""))[:100000], "isError": bool(info.get("error"))}
                    tools = [t for t in m.setdefault("tools", []) if t["id"] != tool["id"]]
                    m["tools"] = tools + [tool]
            if kind == "result":
                result = event.get("result", {})
                if result.get("response"):
                    m["text"] = result["response"]
                m["usage"] = result.get("usage", {})
                s["error"] = result.get("error", "")
                if result.get("status") != "SUCCESS" and not s["error"]:
                    s["error"] = "AGY 结束状态：" + str(result.get("status", "未知"))
            self.save(s)

    def run(self, sid, prompt):
        process, terminal, failure, run_token = None, False, "", None
        try:
            s = self.get(sid)
            # stdin keeps the prompt out of process listings; no shell interpolation.
            args = self.prefix + [self.binary, "--input-format", "stream-json", "--output-format", "stream-json",
                                  "--model", s["baseModel"], "--mode", s["mode"], "--print-timeout", "30m"]
            if s["effort"]: args += ["--effort", s["effort"]]
            env = self.env.copy()
            if s["approvalMode"] != "legacy":
                if self.review is None: raise Failure(503, "审批后端未启用")
                run_token = self.review.begin(sid)
                env.update(AGY_IPHONE_PERMISSION=s["approvalMode"], AGY_IPHONE_RUN_TOKEN=run_token,
                           AGY_IPHONE_REVIEW_SOCKET=self.review.path)
                args += ["--settings", json.dumps({"toolPermission": "always-proceed" if s["approvalMode"] == "turbo" else "request-review",
                                                  "artifactReviewPolicy": "always-proceed", "enableTerminalSandbox": False})]
            if s["conversationID"]:
                args += ["--conversation", s["conversationID"]]
            with self.lock:
                if sid in self.stopping:
                    raise Failure(409, "任务已停止")
                process = subprocess.Popen(args, cwd=s["cwd"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.DEVNULL, start_new_session=True, env=env)
                self.processes[sid] = process
            process.stdin.write((json.dumps({"event": "user", "message": {"content": prompt}}, ensure_ascii=False) + "\n").encode())
            process.stdin.close()
            while True:
                line = process.stdout.readline(4 * 1024 * 1024 + 1)
                if not line:
                    break
                if len(line) > 4 * 1024 * 1024:
                    raise Failure(502, "AGY 输出事件过大")
                event = json.loads(line)
                self.ingest(sid, event)
                terminal |= event.get("event") == "result"
            code = process.wait(timeout=10)
            if not terminal:
                failure = f"AGY 提前结束（{code}）。请检查服务器登录、模型与执行权限。"
        except Exception as error:
            failure = error.message if isinstance(error, Failure) else "AGY 执行中断，请检查会话后再试。"
        finally:
            if run_token and self.review: self.review.finish(run_token)
            if process and process.poll() is None:
                self.terminate(process)
            if process:
                process.stdout.close()
                if not process.stdin.closed:
                    process.stdin.close()
            with self.lock:
                s = self.get(sid)
                s["running"] = False
                s["approvals"] = []
                s["modified"] = time.time()
                if sid in self.stopping:
                    s["error"] = "任务已停止；已执行的操作不会自动撤销。"
                elif failure:
                    s["error"] = failure
                self.save(s)
                self.processes.pop(sid, None)
                self.active.discard(sid)
                self.stopping.discard(sid)

    @staticmethod
    def terminate(process):
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)
        except ProcessLookupError:
            pass

    def stop(self, sid):
        with self.lock:
            s = self.get(sid)
            if s["running"]:
                self.stopping.add(sid)
            process = self.processes.get(sid)
        if self.review: self.review.cancel(sid)
        if process:
            self.terminate(process)
        return self.get(sid)

    def rename(self, sid, name):
        if not isinstance(name, str) or not name.strip() or len(name) > 120:
            raise Failure(400, "名称无效")
        with self.lock:
            s = self.get(sid)
            s["name"] = name.strip()
            self.save(s)
            return s

    def set_model(self, sid, model):
        return self.configure(sid, {"model": model})

    def configure(self, sid, body):
        current = self.get(sid)
        model, base, effort = self.resolve_configuration(body, current)
        mode = body.get("mode", current["mode"])
        permission = body.get("approvalMode", current["approvalMode"])
        if mode not in ("plan", "accept-edits") or permission not in ("review", "turbo", "legacy"):
            raise Failure(400, "执行方式或审批策略无效")
        if permission != "legacy" and self.review is None:
            raise Failure(503, "新版审批后端未启用")
        with self.lock:
            s = self.get(sid)
            if s["running"] or sid in self.active:
                raise Failure(409, "请等待任务结束再切换模型")
            s["model"] = model
            s.update(baseModel=base, effort=effort, mode=mode, approvalMode=permission)
            self.save(s)
            return s

    def file_root(self, sid=None, scope="workspace", cwd=None):
        session = self.get(sid) if sid else None
        workspace = Path(self.workspace(session["cwd"] if session else cwd))
        if scope == "workspace": return workspace
        if not session: raise Failure(400, "请先选择会话")
        if scope == "uploads": return workspace/".agy-uploads"/sid
        if scope == "artifacts" and self.profile_home and session["conversationID"]:
            try: uuid.UUID(session["conversationID"])
            except (ValueError, TypeError, AttributeError): raise Failure(403, "会话产物标识无效")
            return self.profile_home/".gemini/antigravity-cli/brain"/session["conversationID"]
        if scope == "artifacts": return None
        raise Failure(400, "文件区域无效")

    def list_files(self, sid=None, scope="workspace", path="", cwd=None):
        import stat
        relative = Path(path)
        if relative.is_absolute() or ".." in relative.parts or "\x00" in path:
            raise Failure(403, "目录不在允许范围内")
        root = self.file_root(sid, scope, cwd)
        result = {"root": str(root) if root else "", "path": str(relative) if str(relative) != "." else "", "entries": []}
        if root is None: return result
        descriptors = []
        try:
            anchor = root
            prefix = ()
            if scope == "uploads":
                anchor = Path(self.workspace(self.get(sid)["cwd"]))
                prefix = (".agy-uploads", sid)
            elif scope == "artifacts":
                anchor = self.profile_home
                prefix = (".gemini", "antigravity-cli", "brain", self.get(sid)["conversationID"])
            if any(part in {".git", ".gemini", ".ssh", ".aws", ".codex", ".agents"} for part in relative.parts):
                raise Failure(403, "不能访问凭据或内部配置目录")
            fd = os.open(anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW); descriptors.append(fd)
            for part in prefix + relative.parts:
                fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd); descriptors.append(fd)
            names = {}
            if scope == "uploads":
                with self.lock:
                    names = {a["path"]: a["name"] for (raw,) in self.db.execute("SELECT data FROM attachments WHERE session=?", (sid,)) for a in [json.loads(raw)]}
            entries = []
            with os.scandir(fd) as iterator:
                for entry in iterator:
                    if len(entries) >= 5000: raise Failure(413, "目录超过 5000 项，请选择更小的目录")
                    metadata = entry.stat(follow_symlinks=False)
                    if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)): continue
                    # Credentials and gateway state must never be listed as work files.
                    if entry.name in {".git", ".gemini", ".ssh", ".aws", ".codex", ".agents"}: continue
                    full = root/relative/entry.name
                    entries.append({"name": names.get(str(full), entry.name), "path": str(full), "directory": stat.S_ISDIR(metadata.st_mode),
                                    "size": metadata.st_size, "modified": metadata.st_mtime})
            result["entries"] = sorted(entries, key=lambda e: (not e["directory"], e["name"].casefold()))
            return result
        except FileNotFoundError:
            if not relative.parts and scope != "workspace": return result
            raise Failure(404, "目录不存在")
        except OSError: raise Failure(403, "目录不可读或含有符号链接")
        finally:
            for fd in reversed(descriptors): os.close(fd)

    def open_file(self, sid, raw, directory=False):
        s = self.get(sid)
        cwd = Path(self.workspace(s["cwd"]))
        if not isinstance(raw, str) or "\x00" in raw or len(raw) > 8192:
            raise Failure(400, "文件路径无效")
        requested = Path(raw)
        if ".." in requested.parts:
            raise Failure(403, "文件路径不能包含父目录跳转")
        target = requested if requested.is_absolute() else cwd / requested
        allowed = [cwd]
        if self.profile_home and s["conversationID"]:
            allowed.insert(0, self.file_root(sid, "artifacts"))
        target = Path(os.path.abspath(target))
        base, components = None, None
        for root in allowed:
            if root == target or root in target.parents:
                base, components = root, target.relative_to(root).parts
                break
            # macOS may spell the same root /var/... and /private/var/....
            # Resolve only a ROOT prefix, from outermost to innermost. Once
            # inside that boundary, preserve every child for O_NOFOLLOW.
            # Resolving target itself would silently accept workspace links.
            for prefix in reversed((target,) + tuple(target.parents)):
                try:
                    canonical = prefix.resolve(strict=True)
                except (OSError, RuntimeError):
                    continue
                if canonical == root:
                    base, components = root, target.relative_to(prefix).parts
                    break
                if root in canonical.parents:
                    # We already entered the boundary via a subdirectory.
                    # Do not follow more aliases to manufacture a root match.
                    break
            if base is not None: break
        if base is None: raise Failure(403, "文件不在此会话的允许范围")
        if any(part in {".git", ".gemini", ".ssh", ".aws", ".codex", ".agents"} for part in components):
            raise Failure(403, "不能访问凭据或内部配置目录")
        descriptors = []
        try:
            anchor = base
            prefix = ()
            if base != cwd:
                anchor = self.profile_home
                prefix = base.relative_to(anchor).parts
            fd = os.open(anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW); descriptors.append(fd)
            for part in prefix + components[:-1]:
                fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd); descriptors.append(fd)
            if directory:
                if components:
                    result = os.open(components[-1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    os.close(result)
                return None, target.name, 0
            if not components: raise Failure(400, "请选择普通文件下载")
            result = os.open(components[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            import stat
            metadata = os.fstat(result)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_FILE:
                os.close(result); raise Failure(413, "只支持下载 25 MB 内的普通文件")
            return os.fdopen(result, "rb"), target.name, metadata.st_size
        except OSError: raise Failure(404, "文件不存在、不可读或为符号链接")
        finally:
            for fd in reversed(descriptors): os.close(fd)

    def delete(self, sid):
        with self.lock:
            if self.get(sid)["running"] or sid in self.active:
                raise Failure(409, "请先停止任务")
            self.db.execute("DELETE FROM sessions WHERE id=?", (sid,))
            self.db.commit()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "AGYGateway/1"

    def log_message(self, *args):
        pass  # Never log URLs, messages or Authorization headers.

    def respond(self, code, value):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def route(self):
        self.connection.settimeout(30)
        gateway = self.server.gateway
        try:
            auth = self.headers.get("Authorization", "")
            if not hmac.compare_digest(auth.encode(), ("Bearer " + gateway.key).encode()):
                self.close_connection = True
                raise Failure(401, "连接密钥无效")
            parts = urlsplit(self.path)
            path = parts.path.rstrip("/")
            query = parse_qs(parts.query)
            upload = re.fullmatch(r"/v1/sessions/([a-f0-9-]{36})/attachments", path)
            if self.command == "POST" and upload:
                self.close_connection = True
                try:
                    size = int(self.headers.get("Content-Length", "-1"))
                except ValueError:
                    raise Failure(400, "无效附件长度")
                if not 0 <= size <= MAX_FILE:
                    self.close_connection = True
                    raise Failure(413, "单个附件不能超过 25 MB")
                value = gateway.upload(upload[1], query.get("name", [""])[0], self.headers.get("Content-Type", "application/octet-stream"), self.rfile, size)
                return self.respond(201, value)
            body = {}
            if self.command in ("POST", "PATCH"):
                try:
                    size = int(self.headers.get("Content-Length", "-1"))
                except ValueError:
                    raise Failure(400, "无效请求长度")
                if not 0 <= size <= MAX_BODY:
                    self.close_connection = True
                    raise Failure(413, "请求过大或缺少长度")
                try:
                    body = json.loads(self.rfile.read(size))
                    if not isinstance(body, dict):
                        raise ValueError()
                except (ValueError, UnicodeError):
                    raise Failure(400, "无效 JSON")
            if self.command == "GET" and path == "/v1/status":
                return self.respond(200, {"name": "AGY", "version": 1, "roots": list(map(str, gateway.roots)),
                                          "defaultModel": gateway.default_model, "conversationScope": "gateway",
                                          "accountProfile": gateway.account_profile,
                                          "capabilities": {"separateEffort": True, "nativeApprovals": gateway.review is not None, "artifacts": True, "fileBrowser": True, "directoryMentions": True}})
            if self.command == "GET" and path == "/v1/models":
                models = gateway.models(refresh=query.get("refresh") == ["1"])
                return self.respond(200, {"models": models, "families": catalog.families(models)})
            if self.command == "GET" and path == "/v1/limits":
                return self.respond(200, gateway.limits(refresh=query.get("refresh") == ["1"]))
            if path == "/v1/sessions":
                if self.command == "GET":
                    sessions = [{k: v for k, v in s.items() if k != "messages"} for s in gateway.sessions()]
                    return self.respond(200, {"sessions": sessions})
                if self.command == "POST":
                    return self.respond(201, gateway.create(body))
            approval = re.fullmatch(r"/v1/sessions/([a-f0-9-]{36})/approvals/([a-f0-9-]{36})", path)
            if approval and self.command == "POST":
                return self.respond(200, gateway.answer_approval(approval[1], approval[2], body.get("decision")))
            if self.command == "GET" and path == "/v1/workspace":
                return self.respond(200, gateway.list_files(cwd=query.get("cwd", [str(gateway.roots[0])])[0], path=query.get("path", [""])[0]))
            listing = re.fullmatch(r"/v1/sessions/([a-f0-9-]{36})/entries", path)
            if listing and self.command == "GET":
                return self.respond(200, gateway.list_files(listing[1], query.get("scope", ["workspace"])[0], query.get("path", [""])[0]))
            artifact = re.fullmatch(r"/v1/sessions/([a-f0-9-]{36})/files", path)
            if artifact and self.command == "GET":
                stream, name, size = gateway.open_file(artifact[1], query.get("path", [""])[0])
                with stream:
                    self.send_response(200)
                    self.send_header("Content-Type", mimetypes.guess_type(name)[0] or "application/octet-stream")
                    self.send_header("Content-Length", str(size))
                    self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + quote(name))
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("X-Content-Type-Options", "nosniff")
                    self.end_headers()
                    left = size
                    while left:
                        chunk = stream.read(min(65536, left))
                        if not chunk:
                            self.close_connection = True; break
                        self.wfile.write(chunk)
                        left -= len(chunk)
                return
            match = re.fullmatch(r"/v1/sessions/([a-f0-9-]{36})(?:/(messages|stop|events))?", path)
            if match:
                sid, action = match.groups()
                if self.command == "GET" and action == "events":
                    return self.events(sid, parse_qs(parts.query))
                if self.command == "GET" and action is None:
                    return self.respond(200, gateway.get(sid))
                if self.command == "POST" and action == "messages":
                    return self.respond(202, gateway.submit(sid, body))
                if self.command == "POST" and action == "stop":
                    return self.respond(200, gateway.stop(sid))
                if self.command == "PATCH" and action is None:
                    if any(k in body for k in ("model", "baseModel", "effort", "approvalMode", "mode")):
                        return self.respond(200, gateway.configure(sid, body))
                    return self.respond(200, gateway.rename(sid, body.get("name")))
                if self.command == "DELETE" and action is None:
                    gateway.delete(sid)
                    return self.respond(200, {"deleted": True})
            raise Failure(404, "接口不存在")
        except Failure as error:
            self.respond(error.status, {"error": error.message})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except Exception:
            self.close_connection = True
            self.respond(500, {"error": "服务器内部错误"})

    def events(self, sid, query):
        # Bounded stream connections; clients reconnect with authoritative snapshots.
        gateway = self.server.gateway
        s = gateway.get(sid)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        previous, deadline = -1, time.monotonic() + 25
        while time.monotonic() < deadline:
            if s["revision"] != previous:
                self.wfile.write(("data: " + json.dumps(s, ensure_ascii=False) + "\n\n").encode())
                self.wfile.flush()
                previous = s["revision"]
            if not s["running"]:
                break
            time.sleep(0.3)
            s = gateway.get(sid)

    do_GET = do_POST = do_PATCH = do_DELETE = route


class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, gateway):
        self.gateway = gateway
        super().__init__(address, Handler)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8766, type=int)
    parser.add_argument("--data", default=str(Path.home() / ".local/share/agy-iphone"))
    parser.add_argument("--key-file", required=True)
    parser.add_argument("--agy", default="/opt/pi-agent/agy-runtime/agy")
    parser.add_argument("--root", action="append", required=True)
    parser.add_argument("--default-model", default="")
    parser.add_argument("--profile-home", help="Dedicated CLI login home; never the normal shared login home")
    args = parser.parse_args()
    profiles.check_runtime(args.agy)
    key = Path(args.key_file).read_text().strip()
    gateway = Gateway(args.data, key, args.agy, args.root, args.default_model,
                      profile_home=args.profile_home or str(Path(args.data)/"profile-home"))
    server = Server((args.host, args.port), gateway)
    print(f"AGY iPhone gateway listening on {args.host}:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for sid in list(gateway.active):
            gateway.stop(sid)
        server.server_close()
        if gateway.review: gateway.review.close()
        if gateway.review_directory: gateway.review_directory.cleanup()


if __name__ == "__main__":
    main()
