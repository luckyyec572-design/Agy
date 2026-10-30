"""Explicit live gateway probe: two text-only turns; consumes model quota."""
import argparse
import json
from pathlib import Path
import time
import urllib.request
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--url', default='http://127.0.0.1:8766')
parser.add_argument('--key-file', required=True)
parser.add_argument('--workspace', required=True)
parser.add_argument('--report', required=True)
args = parser.parse_args()
key = Path(args.key_file).read_text().strip()
def api(path, body=None, method='GET'):
    request = urllib.request.Request(args.url+'/v1/'+path, data=json.dumps(body).encode() if body is not None else None,
                                     headers={'Authorization':'Bearer '+key,'Content-Type':'application/json','User-Agent':'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 AGY-iPhone/1.0'}, method=method)
    with urllib.request.urlopen(request, timeout=50) as response:
        return json.load(response)

session = api('sessions', {'cwd':args.workspace,'mode':'plan'}, 'POST')
sid = session['id']
report = {'timestamp':time.time(), 'scope':'live AGY CLI via authenticated gateway', 'endpoint':args.url, 'turns':[]}
try:
    for text in ['Remember the marker AGY_NATIVE_20261027. Reply with exactly that marker and nothing else. Do not use tools.',
                 'What exact marker did I ask you to remember in the previous message? Reply with only that marker. Do not use tools.']:
        body = {'text':text,'requestID':str(uuid.uuid4())}
        start = time.monotonic()
        first = api(f'sessions/{sid}/messages',body,'POST')
        duplicate = api(f'sessions/{sid}/messages',body,'POST')
        assert len(first['messages']) == len(duplicate['messages']), 'Duplicate admission'
        request = urllib.request.Request(args.url+f'/v1/sessions/{sid}/events',headers={'Authorization':'Bearer '+key,'User-Agent':'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 AGY-iPhone/1.0'})
        with urllib.request.urlopen(request,timeout=35) as stream:
            first_event = None
            for line in stream:
                if not line.startswith(b'data: '): continue
                if first_event is None: first_event = time.monotonic()-start
                current = json.loads(line[6:])
                if not current['running']: break
        deadline = time.monotonic()+80
        while current['running'] and time.monotonic()<deadline:
            time.sleep(.5)
            current=api(f'sessions/{sid}')
        assert not current['running'] and not current['error'], current.get('error','timeout')
        reply=current['messages'][-1]['text'].strip()
        assert reply=='AGY_NATIVE_20261027',reply
        report['turns'].append({'reply':reply,'firstSnapshotSeconds':round(first_event,3),'durationSeconds':round(time.monotonic()-start,3),'conversationID':current['conversationID']})
    assert report['turns'][0]['conversationID'] == report['turns'][1]['conversationID'], 'Conversation identity changed'
    report['passed']=True
finally:
    current=api(f'sessions/{sid}')
    if current['running']: api(f'sessions/{sid}/stop',{},'POST')
    else: api(f'sessions/{sid}',method='DELETE')
    Path(args.report).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
