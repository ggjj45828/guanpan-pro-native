import concurrent.futures
import importlib.util
import json
import hashlib
import sqlite3
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from http.server import ThreadingHTTPServer

NAS = Path(__file__).resolve().parents[1] / 'nas-sync-server'
sys.path.insert(0, str(NAS))
from channel_store import ChannelStore, ChannelError
import server


def request(channel='assets', revision=0, key='req1', **kwargs):
    return dict(schemaVersion=2, requestID=key, expectedRevision=revision,
                intent='manual', data={'cash': 100000, 'holdings': []}, **kwargs)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = ChannelStore(self.root / 'channels-v2.sqlite3')

    def tearDown(self):
        self.temp.cleanup()

    def test_initial_separate_channels(self):
        for c in ('assets', 'market', 'quant'):
            self.assertEqual(self.store.get(c)['revision'], 0)
        self.assertFalse((self.root / 'sync.sqlite3').exists())

    def test_manual_assets_enforced(self):
        body = request();body['intent'] = 'automatic'
        with self.assertRaises(ChannelError) as result:self.store.put('assets', body)
        self.assertEqual(result.exception.status, 403)

    def test_cas_and_independent_revisions(self):
        self.store.put('assets', request())
        with self.assertRaises(ChannelError) as result:self.store.put('assets', request(key='different'))
        self.assertEqual(result.exception.status, 409)
        self.assertEqual(self.store.get('market')['revision'], 0)

    def test_idempotent_retry_and_payload_reuse(self):
        first = self.store.put('assets', request())
        self.assertEqual(first, self.store.put('assets', request()))
        body = request();body['data']['cash'] = 200
        with self.assertRaises(ChannelError):self.store.put('assets', body)
        self.assertEqual(self.store.get('assets')['revision'], 1)

    def test_unchanged_content_does_not_increment_revision(self):
        self.store.put('assets', request())
        result = self.store.put('assets', request(revision=1, key='same-content'))
        self.assertTrue(result['unchanged']);self.assertEqual(result['revision'], 1)

    def test_empty_guard_inside_transaction(self):
        self.store.put('assets', request())
        body = request(revision=1, key='empty');body['data'] = {'cash': 0, 'holdings': []}
        with self.assertRaises(ChannelError):self.store.put('assets', body)
        body['allowEmptyOverwrite'] = True
        self.assertEqual(self.store.put('assets', body)['revision'], 2)

    def test_cross_channel_fields_rejected(self):
        for channel in ('market','quant'):
            with self.assertRaises(ChannelError):self.store.put(channel, request())
        body = request();body['data'] = {'orders': []}
        with self.assertRaises(ChannelError):self.store.put('assets', body)

    def test_automatic_market_quant_do_not_require_manual(self):
        for channel, data in [('market',{'quotes':[]}),('quant',{'strategies':[]})]:
            body=request();body['intent']='automatic';body['data']=data
            self.assertEqual(self.store.put(channel,body)['revision'],1)

    def test_revision_boolean_and_float_rejected(self):
        for rev in (True, 1.5, -1, None):
            with self.assertRaises(ChannelError):self.store.put('assets',request(revision=rev))

    def test_restore_adds_revision_and_keeps_history(self):
        self.store.put('assets',request())
        body=request(revision=1,key='req2');body['data']['cash']=200000
        self.store.put('assets',body)
        restored=self.store.restore('assets',dict(schemaVersion=2,expectedRevision=2,requestID='restore',intent='manual',restoreRevision=1))
        self.assertEqual(restored['revision'],3)
        self.assertEqual(self.store.get('assets')['data']['cash'],100000)
        self.assertEqual(len(self.store.history('assets')['versions']),3)

    def test_two_concurrent_writers_only_one_succeeds(self):
        self.store.get('assets')
        def attempt(i):
            try:return self.store.put('assets',request(key=f'concurrent-{i}'))['revision']
            except ChannelError as error:return error.code
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            values=list(pool.map(attempt,[1,2]))
        self.assertCountEqual(values,[1,'revision_conflict'])

    def test_backup_uses_consistent_sqlite_backup(self):
        self.store.put('assets',request())
        backup=self.store.backup(self.root/'backup.sqlite3')
        self.assertEqual(ChannelStore(backup).get('assets')['revision'],1)
        with self.assertRaises(ValueError):self.store.backup(backup)

    def test_cannot_target_legacy_filename(self):
        with self.assertRaises(ValueError):ChannelStore(self.root/'sync.sqlite3')

    def test_invalid_numeric_and_nested_json(self):
        for value in [float('nan'),True,-1,'100']:
            body=request();body['data']['cash']=value
            with self.assertRaises(ChannelError):self.store.put('assets',body)

    def test_nonfinite_nested_market_data_is_rejected(self):
        body=request();body['data']={'quotes':[{'price':float('nan')}]}
        with self.assertRaises(ChannelError):self.store.put('market',body)


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.root=Path(cls.temp.name)
        cls.old_db,cls.old_dir,cls.old_token=server.DB_PATH,server.DATA_DIR,server.SYNC_TOKEN
        server.DB_PATH=cls.root/'sync.sqlite3';server.DATA_DIR=cls.root;server.SYNC_TOKEN='test-only-token'
        cls.http=ThreadingHTTPServer(('127.0.0.1',0),server.Handler)
        cls.http.channel_store=ChannelStore(cls.root/'channels-v2.sqlite3')
        cls.thread=threading.Thread(target=cls.http.serve_forever,daemon=True);cls.thread.start()
        cls.base='http://127.0.0.1:'+str(cls.http.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown();cls.http.server_close();cls.thread.join()
        server.DB_PATH,server.DATA_DIR,server.SYNC_TOKEN=cls.old_db,cls.old_dir,cls.old_token
        cls.temp.cleanup()

    def call(self,path,body=None,token=True):
        headers={'Content-Type':'application/json'}
        if token:headers['Authorization']='Bearer test-only-token'
        req=urllib.request.Request(self.base+path,data=json.dumps(body).encode() if body is not None else None,headers=headers)
        try:
            with urllib.request.urlopen(req,timeout=5) as r:return r.status,json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code,json.loads(e.read())

    def test_v2_requires_auth(self):
        self.assertEqual(self.call('/api/v2/channels',token=False)[0],401)

    def test_v2_full_roundtrip_does_not_change_legacy_db(self):
        before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.glob('sync.sqlite3*')}
        status,_=self.call('/api/v2/channels/market',dict(schemaVersion=2,requestID='http1',expectedRevision=0,data={'quotes':[{'symbol':'510300'}]}))
        self.assertEqual(status,200)
        status,body=self.call('/api/v2/channels/market');self.assertEqual(status,200)
        self.assertEqual(body['revision'],1)
        after = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.glob('sync.sqlite3*')}
        self.assertEqual(before, after)

    def test_native_ping_does_not_disclose_payload(self):
        self.assertEqual(self.call('/api/native/ping',token=False)[0],401)
        server.write_snapshot('native',{'data':{'cash':123,'holdings':[{'code':'fixture'}]}})
        status,body=self.call('/api/native/ping');self.assertEqual(status,200)
        self.assertIsNone(body['data'])

    def test_unknown_channel_and_bad_json_schema(self):
        self.assertEqual(self.call('/api/v2/channels/funds')[0],404)
        self.assertEqual(self.call('/api/v2/channels/assets',{'schemaVersion':2})[0],422)

    def test_legacy_web_revision_conflict_and_nested_empty_protection(self):
        current=server.read_snapshot('legacy')['revision']
        code,result=self.call('/api/data',{'data':{'db':{'hold':[{'code':'510300','num':100}]}},'expectedRevision':current})
        self.assertEqual(code,200)
        self.assertEqual(self.call('/api/data',{'data':{'cash':1},'expectedRevision':current})[0],409)
        self.assertEqual(self.call('/api/data',{'data':{'db':{'hold':[]}},'expectedRevision':result['revision']})[0],409)

    def test_native_boolean_revision_rejected(self):
        self.assertEqual(self.call('/api/native/data',{'data':{'data':{'cash':1}},'expectedRevision':True})[0],400)

    def test_http_assets_auto_write_and_history_restore(self):
        body=request();body['intent']='automatic'
        self.assertEqual(self.call('/api/v2/channels/assets',body)[0],403)
        status,listing=self.call('/api/v2/channels/market/history')
        self.assertEqual(status,200);self.assertIn('versions',listing)


if __name__ == '__main__':
    unittest.main(verbosity=2)
