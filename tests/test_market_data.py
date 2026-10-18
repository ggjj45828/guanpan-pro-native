import json,time,tempfile,unittest,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'nas-sync-server'))
from market_data import MarketArchive
from market_runtime import MarketRuntime,configured_book
from channel_store import ChannelStore,ChannelError
T=1792375200000
def row(kind='quote',at=T,available=T,**data):return dict(symbol='510300',asset='etf',kind=kind,at=at,availableAt=available,source='fixture',data=data or {'price':10000})
class MarketTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.path=Path(self.temp.name);self.archive=MarketArchive(self.path/'market-v2.sqlite3');self.channels=ChannelStore(self.path/'channels-v2.sqlite3')
 def tearDown(self):self.temp.cleanup()
 def test_permanent_dedup_and_corrections_as_of(self):
  self.assertEqual(self.archive.ingest([row()],T)['inserted'],1)
  self.assertEqual(self.archive.ingest([row(available=T+100)],T+100)['unchanged'],1)
  self.archive.ingest([row(available=T+200,price=11000)],T+200)
  self.assertEqual(self.archive.query('510300','quote',before=T+100)[0]['data']['price'],10000)
  self.assertEqual(self.archive.query('510300','quote',before=T+200)[0]['data']['price'],11000)
 def test_future_price_and_crossed_depth_rejected(self):
  for r in [row(available=T+1),row(price=-1),row('daily',open=10,close=10,low=20,high=30),row('book',bids=[{'price':11,'quantity':100}],asks=[{'price':10,'quantity':100}],quantityUnit='shares')]:
   with self.assertRaises(ChannelError):self.archive.ingest([r],T)
 def test_book_volume_units_must_be_explicit(self):
  with self.assertRaises(ChannelError):self.archive.ingest([row('book',bids=[],asks=[])],T)
 def test_ingest_atomic_no_partial_invalid_batch(self):
  with self.assertRaises(ChannelError):self.archive.ingest([row(),row(at=T+1,available=T+1,price=-1)],T+1)
  self.assertEqual(self.archive.query('510300','quote'),[])
 def test_gap_retry_does_not_mark_empty_range_complete(self):
  self.archive.enqueue_gap('510300','daily',T-100,T)
  r=self.archive.repair(lambda *args:[],T);self.assertEqual(r[0]['status'],'retry')
  self.assertEqual(self.archive.repair(lambda *args:[],T+1),[])
 def test_snapshot_with_evidence_and_no_invented_book(self):
  self.archive.ingest([row()],T)
  snap=self.archive.snapshot([{'symbol':'510300','asset':'etf'}],T)
  self.assertEqual(snap['books'],[]);self.assertEqual(snap['instruments'][0]['quote']['price'],10000)
 def test_runtime_normalized_feed_publishes_only_market_channel(self):
  self.channels.put('quant',dict(schemaVersion=2,expectedRevision=0,requestID='seed',data={'lab':{'seed':{'positions':[{'symbol':'510300','asset':'etf'}]}}}))
  runtime=MarketRuntime(self.channels,self.archive)
  runtime.poll_feed('https://configured.example/quotes',fetch=lambda *_:{'records':[row()]},now=T)
  self.assertEqual(self.channels.get('market')['revision'],1);self.assertEqual(self.channels.get('assets')['revision'],0)
  runtime.poll_feed('https://configured.example/quotes',fetch=lambda *_:{'records':[row()]},now=T)
  self.assertEqual(self.channels.get('market')['revision'],1)
 def test_original_minute_bridge_does_not_smear_iopv(self):
  self.channels.put('quant',dict(schemaVersion=2,expectedRevision=0,requestID='seed',data={'lab':{'seed':{'positions':[{'symbol':'510300','asset':'etf'}]}}}))
  runtime=MarketRuntime(self.channels,self.archive);runtime.ingest_minutes('510300',[{'timestamp':T//1000-60,'price':1},{'timestamp':T//1000,'price':1.01,'iopv':1.005}],T)
  rows=self.archive.query('510300','intraday');self.assertNotIn('iopv',rows[0]['data']);self.assertEqual(rows[1]['data']['iopv'],10050)
 def test_unregistered_symbol_not_imported_by_minute_bridge(self):
  MarketRuntime(self.channels,self.archive).ingest_minutes('000001',[{'timestamp':T//1000,'price':1}],T)
  self.assertEqual(self.archive.query('000001','quote'),[])
 def test_collector_persists_daily_and_source_quote_timestamp(self):
  self.channels.put('quant',dict(schemaVersion=2,expectedRevision=0,requestID='seed',data={'lab':{'seed':{'positions':[{'symbol':'510300','asset':'etf'}]}}}))
  fields=['']*31;fields[3]='1.234';fields[30]='20261019100000'
  raw=('v_sh510300="'+'~'.join(fields)+'";').encode()
  daily=json.dumps({'data':{'sh510300':{'day':[['2026-10-16','1','1.1','1.2','.9','1000']]}}}).encode()
  runtime=MarketRuntime(self.channels,self.archive,lambda *args,**kwargs:(raw,''),lambda *_:(daily,''));runtime.collect_registered(T)
  self.assertEqual(self.archive.query('510300','quote')[0]['data']['price'],12340)
  self.assertEqual(len(self.archive.query('510300','daily')),1)
 def test_lease_fencing_rejects_late_executor_and_active_client(self):
  lease=self.channels.acquire_execution('worker1');body=dict(schemaVersion=2,expectedRevision=0,requestID='write',data={'strategies':[]})
  with self.assertRaises(ChannelError):self.channels.put('quant',body)
  with self.assertRaises(ChannelError):self.channels.acquire_execution('worker2')
  self.channels.release_execution('worker1',lease['fence']);new=self.channels.acquire_execution('worker2')
  with self.assertRaises(ChannelError):self.channels.put('quant',dict(body,executionLease={'owner':'worker1','fence':lease['fence']}))
  self.assertEqual(self.channels.put('quant',dict(body,executionLease={'owner':'worker2','fence':new['fence']}))['revision'],1)
 def test_lease_expires_and_fence_increments(self):
  one=self.channels.acquire_execution('w1',now=1000,ttl=1);two=self.channels.acquire_execution('w2',now=2001,ttl=1)
  self.assertGreater(two['fence'],one['fence'])
 def test_configured_provider_book_requires_confirmed_volume_multiplier(self):
  fields=['']*31
  for start in (9,19):
   for i in range(5):fields[start+2*i]=str(.99-i*.001 if start==9 else 1+i*.001);fields[start+2*i+1]='2'
  definition={'symbol':'510300','asset':'etf'}
  with self.assertRaises(ValueError):configured_book(fields,definition,T,T,None)
  result=configured_book(fields,definition,T,T,100)
  self.assertEqual(result['data']['asks'][0]['quantity'],200);self.archive.ingest([result],T)
 def test_verified_daily_backup_does_not_overwrite_an_existing_backup(self):
  self.archive.ingest([row()],T);runtime=MarketRuntime(self.channels,self.archive)
  first=runtime.backup_daily(T);before=first.read_bytes()
  self.archive.ingest([row(at=T+1,available=T+1,price=11000)],T+1)
  self.assertEqual(runtime.backup_daily(T+1).read_bytes(),before)
  self.assertEqual(len(MarketArchive(first.parent/'market-v2.sqlite3').query('510300','quote')),1)
 def test_gap_can_only_complete_with_explicit_matching_coverage(self):
  self.archive.enqueue_gap('510300','quote',T-1,T+1)
  result=self.archive.repair(lambda *_:{'records':[row()],'coverage':{'start':T-1,'end':T+1,'expectedTimes':[T],'source':'synthetic certificate','complete':True}},T)
  self.assertEqual(result[0]['status'],'complete')
  self.assertEqual(self.archive.repair(lambda *_:[],T+100000),[])
 def test_failure_for_one_registered_symbol_does_not_block_the_others(self):
  defs=[{'symbol':'510300','asset':'etf'},{'symbol':'159919','asset':'etf'}]
  self.channels.put('quant',dict(schemaVersion=2,expectedRevision=0,requestID='seed',data={'lab':{'seed':{'positions':defs}}}))
  fields=['']*31;fields[3]='1';fields[30]='20261019100000'
  def fetch(url,**kwargs):
   if 'sh510300'in url:raise ValueError('fixture failure')
   return ('v_sz159919="'+'~'.join(fields)+'";').encode(),''
  errors=MarketRuntime(self.channels,self.archive,fetch).collect_registered(T)
  self.assertEqual(len(errors),1);self.assertEqual(len(self.archive.query('159919','quote')),1)
