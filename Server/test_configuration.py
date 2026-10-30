import io
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest

import catalog
import profiles
from approvals import ApprovalBridge
from gateway import Gateway, Failure
from test_gateway import FAKE


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        binary = self.root/'agy'; binary.write_text(FAKE); binary.chmod(0o700)
        self.gateway = Gateway(self.root/'data', 'test-key-'*6, str(binary), [self.root])

    def tearDown(self):
        for sid in list(self.gateway.active): self.gateway.stop(sid)
        deadline = time.time()+3
        while self.gateway.active and time.time()<deadline: time.sleep(.02)
        self.gateway.db.close(); self.temp.cleanup()

    def test_model_and_effort_are_independent_and_validated(self):
        models = [{'id':'gemini-4-argon-low','name':'Gemini 4 Argon (Low)'}, {'id':'gemini-4-argon-high','name':'Gemini 4 Argon (High)'}, {'id':'named-high','name':'Named High'}]
        groups = catalog.families(models)
        self.assertEqual(groups[0]['name'], 'Gemini 4 Argon')
        self.assertEqual(groups[0]['efforts'], ['low','high'])
        self.assertEqual(groups[1]['id'], 'named-high')
        self.assertEqual(catalog.resolve(models, 'gemini-4-argon', 'high')[0], 'gemini-4-argon-high')
        self.assertEqual(catalog.resolve(models, 'gemini-4-argon')[2], 'low')
        with self.assertRaises(ValueError): catalog.resolve(models, 'gemini-4-argon', 'max')
        self.gateway.models_cache = (time.monotonic(), models)
        s = self.gateway.create({'baseModel':'gemini-4-argon','effort':'low'})
        changed = self.gateway.configure(s['id'], {'effort':'high'})
        self.assertEqual(changed['baseModel'], 'gemini-4-argon')
        self.assertEqual(changed['effort'], 'high')
        self.assertEqual(changed['conversationID'], s['conversationID'])

    def test_review_cannot_be_claimed_without_backend(self):
        with self.assertRaises(Failure): self.gateway.create({'approvalMode':'review'})
        with self.assertRaises(Failure): self.gateway.create({'approvalMode':'turbo'})

    def test_artifacts_are_confined_and_preserve_unicode_bytes(self):
        s = self.gateway.create({})
        expected = b'\x00\xff\x01file'
        file = self.root/'中文 空格.bin'; file.write_bytes(expected)
        stream, name, size = self.gateway.open_file(s['id'], str(file))
        with stream: self.assertEqual(stream.read(), expected)
        self.assertEqual(name, file.name); self.assertEqual(size, len(expected))
        with self.assertRaises(Failure): self.gateway.open_file(s['id'], '/etc/passwd')
        (self.root/'alias.bin').symlink_to(file)
        with self.assertRaises(Failure): self.gateway.open_file(s['id'], str(self.root/'alias.bin'))
        with self.assertRaises(Failure): self.gateway.open_file(s['id'], '../escape')

    def test_new_profiles_are_isolated_and_do_not_copy_login(self):
        a = self.root/'accounts/new/home'; b = self.root/'accounts/other/home'
        first = profiles.prepare(a); second = profiles.prepare(b)
        self.assertNotEqual(first, second)
        self.assertEqual(first, profiles.prepare(a))
        self.assertFalse((a/'.gemini/antigravity-cli/antigravity-oauth-token').exists())
        hook = json.loads((a/'.gemini/config/hooks.json').read_text())
        self.assertEqual(hook['agy-iphone-native-review']['PreToolUse'][0]['hooks'][0]['timeout'], 600)
        self.assertEqual(profiles.environment(a)['HOME'], str(a))
        with self.assertRaises(ValueError): profiles.prepare(Path.home())


class ApprovalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.records = []
        self.bridge = ApprovalBridge(Path(self.temp.name)/'gate.sock', lambda sid, records: self.records.append((sid, records)), timeout=.5)

    def tearDown(self): self.bridge.close(); self.temp.cleanup()

    def pending(self):
        deadline = time.monotonic()+2
        while time.monotonic()<deadline:
            with self.bridge.lock:
                if self.bridge.requests: return next(iter(self.bridge.requests.values()))['record']
            time.sleep(.005)
        self.fail('No pending request')

    def test_authenticated_private_hook_handshake_and_single_use(self):
        token = self.bridge.begin('one')
        result = []
        def client():
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
                c.connect(self.bridge.path)
                c.sendall(json.dumps({'token':token,'payload':{'toolCall':{'name':'run_command','args':{'CommandLine':'printf test'}}}}).encode()+b'\n')
                with c.makefile('rb') as stream: result.append(json.loads(stream.readline()))
        t = threading.Thread(target=client); t.start()
        request = self.pending()
        self.assertFalse(result, 'Tool must wait for explicit decision')
        with self.assertRaises(ValueError): self.bridge.answer('another-session', request['id'], 'allow')
        self.bridge.answer('one', request['id'], 'allow'); t.join(2)
        self.assertEqual(result, [{'decision':'allow'}])
        with self.assertRaises(ValueError): self.bridge.answer('one', request['id'], 'allow')
        self.bridge.finish(token)
        self.assertEqual(self.bridge.wait(token, {'toolCall':{'name':'run_command'}}), 'deny')

    def test_timeout_stop_and_invalid_capability_deny(self):
        self.assertEqual(self.bridge.wait('invalid', {}), 'deny')
        token = self.bridge.begin('one'); result = []
        thread = threading.Thread(target=lambda: result.append(self.bridge.wait(token, {'toolCall':{'name':'view_file','args':{}}})))
        thread.start(); self.pending(); self.bridge.cancel('one'); thread.join(2)
        self.assertEqual(result, ['deny'])
        token = self.bridge.begin('two')
        self.assertEqual(self.bridge.wait(token, {'toolCall':{'name':'view_file','args':{}}}), 'deny')


if __name__ == '__main__': unittest.main()
