import io
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid

from gateway import Gateway, Server, Failure
from test_gateway import FAKE


class FilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        binary = self.root/'agy'; binary.write_text(FAKE); binary.chmod(0o700)
        self.g = Gateway(self.root/'state', 'k'*48, str(binary), [self.root])
        self.session = self.g.create({})

    def tearDown(self):
        for sid in list(self.g.active): self.g.stop(sid)
        deadline = time.monotonic()+4
        while self.g.active and time.monotonic()<deadline: time.sleep(.02)
        self.g.db.close(); self.temp.cleanup()

    def test_browser_preserves_names_and_rejects_links_and_traversal(self):
        folder = self.root/'中文 资料'; folder.mkdir()
        (folder/'合同 空格.pdf').write_bytes(b'\x00\xffpdf')
        (self.root/'shortcut').symlink_to(folder, target_is_directory=True)
        (self.root/'.ssh').mkdir(); (self.root/'.ssh/private').write_text('secret')
        entries = self.g.list_files(self.session['id'])['entries']
        self.assertIn('中文 资料', [e['name'] for e in entries])
        self.assertNotIn('shortcut', [e['name'] for e in entries])
        self.assertNotIn('.ssh', [e['name'] for e in entries])
        entry = self.g.list_files(self.session['id'], path=folder.name)['entries'][0]
        self.assertEqual(entry['path'], str(folder/'合同 空格.pdf'))
        self.assertFalse(entry['directory'])
        for path in ['../', '/etc', 'shortcut', '.ssh']:
            with self.subTest(path=path), self.assertRaises(Failure): self.g.list_files(self.session['id'], path=path)
        with self.assertRaises(Failure): self.g.open_file(self.session['id'], '.ssh/private')
        with self.assertRaises(Failure): self.g.list_files(cwd=str(self.root/'.ssh'))

    def test_uploaded_files_are_listed_without_sending_and_keep_original_names(self):
        sid = self.session['id']; name = '图片 空格.png'; data = b'\x00\xffimage'
        uploaded = self.g.upload(sid, name, 'image/png', io.BytesIO(data), len(data))
        entry = self.g.list_files(sid, 'uploads')['entries'][0]
        self.assertEqual(entry['name'], name)
        self.assertEqual(entry['path'], uploaded['path'])
        self.assertEqual(self.g.get(sid)['messages'], [])
        stream, _, _ = self.g.open_file(sid, entry['path'])
        with stream: self.assertEqual(stream.read(), data)
        other = self.g.create({})
        self.assertEqual(self.g.list_files(other['id'], 'uploads')['entries'], [])

    def test_folder_and_file_references_deliver_full_paths_without_preloading(self):
        folder = self.root/'项目 空格'; folder.mkdir()
        file = folder/'中文 合同\nsecond-line.txt'; file.write_text('not-preloaded-secret')
        captures = []
        def capture(sid, prompt):
            captures.append(prompt)
            with self.g.lock:
                s = self.g.get(sid); s['running'] = False; self.g.save(s); self.g.active.discard(sid)
        self.g.run = capture
        sid = self.session['id']; rid = str(uuid.uuid4())
        body = {'text':'分析这些内容', 'requestID':rid, 'references':[str(folder),str(file)]}
        self.g.submit(sid, body)
        deadline = time.monotonic()+3
        while self.g.active and time.monotonic()<deadline: time.sleep(.01)
        self.assertEqual(len(captures), 1)
        records = [json.loads(line) for line in captures[0].splitlines() if line.startswith('{')]
        self.assertEqual([r['path'] for r in records], [str(folder), str(file)])
        self.assertEqual([r['type'] for r in records], ['directory','file'])
        self.assertNotIn('not-preloaded-secret', captures[0])
        self.assertEqual(self.g.get(sid)['messages'][0]['attachments'][0]['mime'], 'inode/directory')
        self.g.submit(sid, body)
        self.assertEqual(len(self.g.get(sid)['messages']), 2)
        with self.assertRaises(Failure) as error: self.g.submit(sid, {**body, 'references':[str(folder)]})
        self.assertEqual(error.exception.status, 409)
        self.g.submit(sid, {'text':'', 'requestID':str(uuid.uuid4()), 'references':[str(self.root)]})

    def test_reference_refusals_do_not_admit_messages(self):
        sid = self.session['id']
        (self.root/'link').symlink_to('/etc', target_is_directory=True)
        for refs in [['/etc'], ['link'], ['../escape'], ['missing'], 'bad', [None], ['same','same']]:
            with self.subTest(refs=refs), self.assertRaises(Failure):
                self.g.submit(sid, {'text':'inspect', 'requestID':str(uuid.uuid4()), 'references':refs})
        self.assertEqual(self.g.get(sid)['messages'], [])

    def test_scopes_confine_artifacts_and_refuse_upload_parent_links(self):
        sid = self.session['id']
        self.assertEqual(self.g.list_files(sid, 'artifacts')['entries'], [])
        (self.root/'.agy-uploads').symlink_to('/etc', target_is_directory=True)
        with self.assertRaises(Failure): self.g.list_files(sid, 'uploads')
        (self.root/'.agy-uploads').unlink()
        # Use a dedicated profile for artifact scope; never a real account.
        profile = self.root/'profile'; profile.mkdir()
        self.g.profile_home = profile
        cid = str(uuid.uuid4()); s = self.g.get(sid); s['conversationID'] = cid; self.g.save(s)
        brain = profile/'.gemini/antigravity-cli/brain'/cid; brain.mkdir(parents=True)
        artifact = brain/'结果 中文.md'; artifact.write_text('result')
        self.assertEqual(self.g.list_files(sid, 'artifacts')['entries'][0]['path'], str(artifact))
        stream, _, _ = self.g.open_file(sid, str(artifact))
        with stream: self.assertEqual(stream.read(), b'result')
        other = self.g.create({})
        # Different session with a narrower cwd cannot read this brain path.
        project = self.root/'other-project'; project.mkdir()
        other['cwd'] = str(project); self.g.save(other)
        with self.assertRaises(Failure): self.g.open_file(other['id'], str(artifact))
        artifact.unlink(); brain.rmdir(); brain.symlink_to('/etc', target_is_directory=True)
        with self.assertRaises(Failure): self.g.list_files(sid, 'artifacts')
        with self.assertRaises(Failure): self.g.open_file(sid, str(brain/'passwd'))

    def test_http_browse_upload_reference_and_binary_download(self):
        server = Server(('127.0.0.1', 0), self.g)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        base = 'http://127.0.0.1:'+str(server.server_address[1])
        def request(path, data=None, mime='application/json', auth=True):
            headers = {'Content-Type':mime}
            if auth: headers['Authorization'] = 'Bearer '+self.g.key
            return urllib.request.urlopen(urllib.request.Request(base+path, data=data, headers=headers), timeout=4)
        sid = self.session['id']
        try:
            with self.assertRaises(urllib.error.HTTPError) as error: request('/v1/workspace', auth=False)
            self.assertEqual(error.exception.code,401); error.exception.close()
            query = urllib.parse.urlencode({'cwd':str(self.root)})
            with request('/v1/workspace?'+query) as response: self.assertEqual(json.load(response)['root'],str(self.root))
            data = b'\x00\xffdownload'; query = urllib.parse.urlencode({'name':'产物 空格.bin'})
            with request('/v1/sessions/'+sid+'/attachments?'+query, data, 'application/octet-stream') as response:
                uploaded = json.load(response)
            with request('/v1/sessions/'+sid+'/entries?scope=uploads') as response:
                self.assertEqual(json.load(response)['entries'][0]['name'],'产物 空格.bin')
            with request('/v1/sessions/'+sid+'/files?'+urllib.parse.urlencode({'path':uploaded['path']})) as response:
                self.assertEqual(response.read(),data)
            body = json.dumps({'text':'', 'requestID':str(uuid.uuid4()), 'references':[str(self.root)]}).encode()
            with request('/v1/sessions/'+sid+'/messages',body) as response:
                self.assertEqual(response.status,202)
                self.assertEqual(json.load(response)['messages'][0]['attachments'][0]['mime'],'inode/directory')
        finally:
            server.shutdown(); server.server_close(); thread.join(3)


if __name__ == '__main__': unittest.main()
