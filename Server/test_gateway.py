import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
import uuid

from gateway import Gateway, Server, Failure

FAKE = '''#!/usr/bin/env python3
import json,sys,time
if "models" in sys.argv:
 print("test-model\\tTest Model")
 print("gemini-4-argon-medium\\tGemini 4 Argon (Medium)")
 sys.exit(0)
if "/usage" in sys.argv:
 print(json.dumps({"status":"SUCCESS","command":{"data":{"groups":[{"name":"Gemini 4 Argon","buckets":[{"id":"argon-weekly","name":"Weekly","remaining_fraction":0.42,"reset_time":"2026-11-03T06:03:08Z","window":"weekly"}]}]}}}))
 sys.exit(0)
message=json.loads(sys.stdin.readline())["message"]["content"]
cid="12345678-1234-1234-1234-123456789abc"
print(json.dumps({"event":"init","conversation_id":cid}),flush=True)
if message == "slow": time.sleep(20)
for text in ["你好", "，iPhone"]:
 print(json.dumps({"event":"step_update","step_update":{"step_type":"agent_response","text_delta":text}}),flush=True)
 time.sleep(0.03)
for state in ["ACTIVE","DONE"]:
 print(json.dumps({"event":"step_update","step_update":{"step_type":"tool","step_index":4,"state":state,"tool_name":"read_file","tool_info":{"output":"done"}}}),flush=True)
print(json.dumps({"event":"result","result":{"status":"SUCCESS","response":"你好，iPhone","conversation_id":cid}}),flush=True)
'''


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        fake = self.root / "agy"
        fake.write_text(FAKE)
        fake.chmod(0o700)
        self.g = Gateway(self.root / "db", "k" * 48, str(fake), [self.root])

    def tearDown(self):
        for sid in list(self.g.active):
            self.g.stop(sid)
        deadline = time.time() + 4
        while self.g.active and time.time() < deadline:
            time.sleep(.02)
        self.g.db.close()
        self.tmp.cleanup()

    def wait(self, sid):
        deadline = time.time() + 5
        while self.g.get(sid)["running"] and time.time() < deadline:
            time.sleep(.02)
        self.assertFalse(self.g.get(sid)["running"])
        return self.g.get(sid)

    def test_unicode_tools_result_and_resume(self):
        s = self.g.create({})
        self.g.submit(s["id"], {"text": "first", "requestID": str(uuid.uuid4())})
        s = self.wait(s["id"])
        self.assertEqual(s["messages"][-1]["text"], "你好，iPhone")
        self.assertEqual(len(s["messages"][-1]["tools"]), 1)
        self.assertEqual(s["messages"][-1]["tools"][0]["state"], "DONE")
        self.assertTrue(s["conversationID"])
        self.g.submit(s["id"], {"text": "second", "requestID": str(uuid.uuid4())})
        self.assertEqual(len(self.wait(s["id"])["messages"]), 4)

    def test_admission_is_idempotent_and_detects_conflict(self):
        s = self.g.create({})
        body = {"text": "slow", "requestID": str(uuid.uuid4())}
        self.g.submit(s["id"], body)
        self.g.submit(s["id"], body)
        self.assertEqual(len(self.g.get(s["id"])["messages"]), 2)
        with self.assertRaises(Failure) as error:
            self.g.submit(s["id"], {**body, "text": "different"})
        self.assertEqual(error.exception.status, 409)
        with self.assertRaises(Failure):
            self.g.submit(s["id"], {"text": "other", "requestID": str(uuid.uuid4())})
        self.g.stop(s["id"])
        self.assertIn("停止", self.wait(s["id"])["error"])

    def test_cwd_symlink_and_path_escape(self):
        with self.assertRaises(Failure):
            self.g.create({"cwd": "/etc"})
        (self.root / "escape").symlink_to("/etc")
        with self.assertRaises(Failure):
            self.g.create({"cwd": str(self.root / "escape")})
        with self.assertRaises(Failure):
            self.g.create({"model": "--dangerously-skip-permissions"})

    def test_restart_preserves_history_and_does_not_resubmit(self):
        s = self.g.create({})
        s["running"] = True
        self.g.save(s)
        other = Gateway(self.root / "db", "k" * 48, self.g.binary, [self.root])
        try:
            recovered = other.get(s["id"])
            self.assertFalse(recovered["running"])
            self.assertIn("重启", recovered["error"])
            self.assertFalse(other.active)
        finally:
            other.db.close()

    def test_upload_integrity_ownership_and_admission(self):
        s = self.g.create({})
        payload = b'\x00\xffnative file\n'
        a = self.g.upload(s['id'], '中文 file.png', 'image/png', io.BytesIO(payload), len(payload))
        stored = self.g.attachment(s['id'], a['id'])
        self.assertEqual(Path(stored['path']).read_bytes(), payload)
        self.assertEqual(a['size'], len(payload))
        other = self.g.create({})
        with self.assertRaises(Failure):
            self.g.submit(other['id'], {'text':'inspect','requestID':str(uuid.uuid4()),'attachments':[a['id']]})
        body = {'text':'','requestID':str(uuid.uuid4()),'attachments':[a['id']]}
        self.g.submit(s['id'], body)
        self.g.submit(s['id'], body)
        result = self.wait(s['id'])
        self.assertEqual(len(result['messages']), 2)
        self.assertEqual(result['messages'][0]['attachments'][0]['name'], '中文 file.png')
        with self.assertRaises(Failure):
            self.g.submit(s['id'], {**body, 'attachments':[]})

    def test_upload_bounds_partial_transfer_and_symlink(self):
        s = self.g.create({})
        for name, size in [('../escape', 0), ('big.bin', 26*1024*1024)]:
            with self.assertRaises(Failure):
                self.g.upload(s['id'], name, 'application/octet-stream', io.BytesIO(), size)
        with self.assertRaises(Failure):
            self.g.upload(s['id'], 'partial.bin', 'application/octet-stream', io.BytesIO(b'one'), 100)
        folder = self.root/'.agy-uploads'/s['id']
        self.assertEqual(list(folder.iterdir()), [])
        # A workspace-level symlink must never redirect upload writes.
        folder.rmdir(); (self.root/'.agy-uploads').rmdir()
        (self.root/'.agy-uploads').symlink_to('/tmp')
        with self.assertRaises(Failure):
            self.g.upload(s['id'], 'file.txt', 'text/plain', io.BytesIO(b'x'), 1)

    def test_limits_and_existing_conversation_model_switch(self):
        value = self.g.limits()
        self.assertEqual(value['groups'][0]['buckets'][0]['remaining_fraction'], .42)
        self.assertEqual(value['groups'][0]['name'], 'Gemini 4 Argon')
        self.assertEqual(value['source'], 'agy /usage')
        s = self.g.create({})
        self.g.submit(s['id'], {'text':'first','requestID':str(uuid.uuid4())})
        before = self.wait(s['id'])
        after = self.g.set_model(s['id'], 'gemini-4-argon-medium')
        self.assertEqual(before['conversationID'], after['conversationID'])
        self.assertEqual(before['messages'], after['messages'])
        self.assertEqual(after['model'], 'gemini-4-argon-medium')

    def test_http_auth_sse_and_delete(self):
        server = Server(("127.0.0.1", 0), self.g)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = "http://127.0.0.1:" + str(server.server_port)
        def request(path, body=None, method="GET", auth=True):
            headers = {"Authorization": "Bearer " + self.g.key} if auth else {}
            data = json.dumps(body).encode() if body is not None else None
            return urllib.request.urlopen(urllib.request.Request(base + path, data=data, headers=headers, method=method), timeout=4)
        try:
            with self.assertRaises(urllib.error.HTTPError) as error:
                request("/v1/status", auth=False)
            self.assertEqual(error.exception.code, 401)
            error.exception.close()
            with request("/v1/sessions", {}, "POST") as response:
                s = json.load(response)
            binary = bytes(range(256))
            req = urllib.request.Request(base + '/v1/sessions/' + s['id'] + '/attachments?name=fixture.bin',
                                         data=binary, headers={'Authorization':'Bearer '+self.g.key,'Content-Type':'application/octet-stream'})
            with urllib.request.urlopen(req, timeout=4) as response:
                attached = json.load(response)
            self.assertEqual(attached['size'], len(binary))
            self.assertEqual(Path(self.g.attachment(s['id'], attached['id'])['path']).read_bytes(), binary)
            with request('/v1/limits') as response:
                self.assertEqual(json.load(response)['groups'][0]['name'], 'Gemini 4 Argon')
            with request("/v1/sessions/" + s["id"] + "/messages", {"text": "test", "requestID": str(uuid.uuid4())}, "POST") as response:
                self.assertEqual(response.status, 202)
            with request("/v1/sessions/" + s["id"] + "/events") as response:
                self.assertEqual(response.headers.get_content_type(), "text/event-stream")
                lines = response.read().decode().split("\n\n")
                snapshots = [json.loads(line[6:]) for line in lines if line.startswith("data: ")]
            self.assertEqual(snapshots[-1]["messages"][-1]["text"], "你好，iPhone")
            self.assertFalse(snapshots[-1]["running"])
            with request("/v1/sessions/" + s["id"], method="DELETE") as response:
                self.assertTrue(json.load(response)["deleted"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)


if __name__ == "__main__":
    unittest.main()
