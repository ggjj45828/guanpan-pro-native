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
 def test_intraday_volume_is_used_only_with_confirmed_share_units(self):
  with self.assertRaises(ChannelError):self.archive.ingest([row('intraday',price=10000,volume=300)],T)
  self.archive.ingest([row('intraday',price=10000,volume=300,volumeUnit='shares')],T)
  self.assertEqual(self.archive.query('510300','intraday')[0]['data']['volume'],300)
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
  self.assertEqual(snap['instruments'][0]['quoteSource'],'fixture')
 def test_attributed_news_maps_to_held_symbol_only_after_publication(self):
  news=row('news',at=T-100,available=T,headline='基金重大公告',publisher='基金公司',
           sourceURL='https://example.org/notice',importance='major',eventScope='security')
  self.archive.ingest([news],T)
  self.assertEqual(self.archive.snapshot([{'symbol':'510300','asset':'etf'}],T-1)['news'],[])
  snapshot=self.archive.snapshot([{'symbol':'510300','asset':'etf'}],T)
  self.assertEqual(snapshot['news'][0]['symbol'],'510300')
  self.assertEqual(snapshot['news'][0]['publisher'],'基金公司')
  self.assertEqual(self.archive.snapshot([{'symbol':'159919','asset':'etf'}],T)['news'],[])
  invalid=dict(news,data=dict(news['data'],sourceURL='http://unverified.example/notice'))
  with self.assertRaises(ChannelError):self.archive.ingest([invalid],T)
 def test_market_and_industry_events_require_explicit_scope_mapping(self):
  industry=dict(row('news',at=T-100,available=T,headline='行业公告',publisher='交易所',
                    sourceURL='https://example.org/industry',importance='major',
                    eventScope='industry',affectedSymbols=['510300']),symbol='MARKET')
  self.archive.ingest([industry],T)
  self.assertEqual(self.archive.snapshot([{'symbol':'510300','asset':'etf'}],T)['news'][0]['affectedSymbols'],['510300'])
  missing=dict(industry,data={k:v for k,v in industry['data'].items() if k!='affectedSymbols'})
  with self.assertRaises(ChannelError):self.archive.ingest([missing],T)
  market=dict(industry,at=T-50,data=dict(industry['data'],eventScope='market',affectedSymbols=[]))
  self.archive.ingest([market],T)
  self.assertEqual(len(self.archive.snapshot([{'symbol':'159919','asset':'etf'}],T)['news']),2)
 def test_snapshot_summarizes_only_observed_intraday_history_and_window_coverage(self):
  now=T+66*86400000;records=[]
  for day in range(65):
   for minute in range(10):
    at=T+day*86400000+minute*60000
    records.append(row('intraday',at=at,available=now,price=10000+day*10+minute,volume=100,volumeUnit='shares'))
  self.archive.ingest(records,now)
  item=self.archive.snapshot([{'symbol':'510300','asset':'etf'}],now)['instruments'][0]['intradayResearch']
  self.assertEqual(item['sessions'],65);self.assertEqual(item['samplePoints'],650)
  self.assertTrue(item['windows']['60']['available']);self.assertFalse(item['windows']['120']['available'])
  self.assertIsNotNone(item['latestSessionVWAP']);self.assertFalse(item['pricePlansAllowed'])
  self.assertEqual(item['completeMinuteDays'],0)
  self.assertEqual(item['status'],'insufficient-history-or-coverage')
 def test_long_intraday_research_uses_real_minute_sequence_and_share_volume(self):
  records=[]
  for day in range(65):
   for minute,price in ((0,9960),(30,10000),(180,10040),(280,10000)):
    at=T+day*86400000+minute*60000
    records.append(row('intraday',at=at,available=at,price=price,volume=100,volumeUnit='shares'))
  report=MarketArchive.intraday_summary(records,T+66*86400000)
  window=report['windows']['60']
  self.assertTrue(window['available'])
  self.assertEqual(window['vwapDays'],60)
  self.assertEqual(window['medianPointsPerDay'],4)
  self.assertGreater(window['vwapReversion']['returned'],0)
  self.assertGreater(window['roundTrips'],0)
  self.assertEqual(sum(window['highTimeBuckets'].values()),60)
  self.assertEqual(len(report['dailyEvidence']),65)
  no_volume=[dict(r,data={'price':r['data']['price']}) for r in records]
  absent=MarketArchive.intraday_summary(no_volume,T+66*86400000)['windows']['60']
  self.assertEqual(absent['vwapDays'],0)
  self.assertIsNone(absent['vwapReversion']['observedRate'])
  self.assertIsNone(absent['vwapHighDeviationMedian'])
 def test_complete_minute_history_exports_ordered_price_paths_for_touch_checks(self):
  records=[]
  for day in range(60):
   for minute in range(220):
    offset=minute if minute<110 else minute+100
    at=T-30*60000+day*86400000+offset*60000
    records.append(row('intraday',at=at,available=at,
                       price=(9960,10000,10040,10000)[minute%4],
                       volume=100,volumeUnit='shares'))
  report=MarketArchive.intraday_summary(records,T+60*86400000)
  self.assertEqual(report['status'],'ready-for-statistical-review')
  self.assertEqual(report['completeMinuteDays'],60)
  self.assertEqual(len(report['minuteEvidence']),60)
  self.assertEqual(len(report['minuteEvidence'][0]['points']),220)
  self.assertLess(report['minuteEvidence'][0]['points'][0][0],report['minuteEvidence'][0]['points'][-1][0])
 def test_all_four_research_windows_need_observed_sessions(self):
  records=[]
  for day in range(120):
   for minute in range(220):
    offset=minute if minute<110 else minute+100
    at=T-30*60000+day*86400000+offset*60000
    records.append(row('intraday',at=at,available=at,
                       price=10000+(minute%5)*10,volume=100,volumeUnit='shares'))
  report=MarketArchive.intraday_summary(records,T+121*86400000)
  self.assertEqual(report['completeMinuteDays'],120)
  self.assertEqual(len(report['minuteEvidence']),60)
  for span in ('5','20','60','120'):
   self.assertTrue(report['windows'][span]['available'])
   self.assertEqual(report['windows'][span]['sessions'],int(span))
  self.assertIsNotNone(report['windows']['120']['vwapHighDeviationMedian'])
 def test_two_hundred_points_without_open_and_close_are_not_a_complete_day(self):
  records=[row('intraday',at=T+minute*60000,available=T+minute*60000,
               price=10000,volume=100,volumeUnit='shares') for minute in range(200)]
  report=MarketArchive.intraday_summary(records,T+86400000)
  self.assertEqual(report['completeMinuteDays'],0)
  self.assertEqual(report['minuteEvidence'],[])
 def test_runtime_normalized_feed_publishes_only_market_channel(self):
  runtime=MarketRuntime(self.channels,self.archive)
  runtime.poll_feed('https://configured.example/quotes',fetch=lambda *_:{'records':[row()]},now=T)
  self.assertEqual(self.channels.get('market')['revision'],1);self.assertEqual(self.channels.get('assets')['revision'],0)
  runtime.poll_feed('https://configured.example/quotes',fetch=lambda *_:{'records':[row()]},now=T)
  self.assertEqual(self.channels.get('market')['revision'],1)
 def test_configured_news_feed_reaches_real_holding_research_snapshot(self):
  runtime=MarketRuntime(self.channels,self.archive,
                        holdings_provider=lambda:[{'symbol':'510300','asset':'etf'}])
  event=row('news',at=T-100,available=T,headline='基金重大公告',publisher='基金公司',
            sourceURL='https://example.org/notice',importance='major',eventScope='security')
  runtime.poll_feed('https://configured.example/news',fetch=lambda *_:{'records':[event]},now=T)
  market=self.channels.get('market')['data']
  self.assertEqual(market['quality']['researchSnapshot']['news'][0]['headline'],'基金重大公告')
  self.assertEqual(self.channels.get('assets')['revision'],0)
 def test_original_minute_bridge_does_not_smear_iopv(self):
  runtime=MarketRuntime(self.channels,self.archive,holdings_provider=lambda:[{'symbol':'510300','asset':'etf'}]);runtime.ingest_minutes('510300',[{'timestamp':T//1000-60,'price':1},{'timestamp':T//1000,'price':1.01,'iopv':1.005}],T)
  rows=self.archive.query('510300','intraday');self.assertNotIn('iopv',rows[0]['data']);self.assertEqual(rows[1]['data']['iopv'],10050)
 def test_unregistered_symbol_not_imported_by_minute_bridge(self):
  MarketRuntime(self.channels,self.archive).ingest_minutes('000001',[{'timestamp':T//1000,'price':1}],T)
  self.assertEqual(self.archive.query('000001','quote'),[])
 def test_nas_collection_uses_only_explicit_real_holding_provider(self):
  with self.assertRaises(ChannelError):self.channels.put('quant',dict(schemaVersion=2,expectedRevision=0,requestID='legacy',data={'lab':{'seed':{'positions':[{'symbol':'510300','asset':'etf'}]}}}))
  runtime=MarketRuntime(self.channels,self.archive,holdings_provider=lambda:[{'symbol':'159919','asset':'etf'}])
  self.assertEqual([item['symbol'] for item in runtime.definitions()],['159919'])
 def test_collector_persists_daily_and_source_quote_timestamp(self):
  fields=['']*31;fields[3]='1.234';fields[30]='20261019100000'
  raw=('v_sh510300="'+'~'.join(fields)+'";').encode()
  daily=json.dumps({'data':{'sh510300':{'day':[['2026-10-16','1','1.1','1.2','.9','1000']]}}}).encode()
  runtime=MarketRuntime(self.channels,self.archive,lambda *args,**kwargs:(raw,''),lambda *_:(daily,''),holdings_provider=lambda:[{'symbol':'510300','asset':'etf'}]);runtime.collect_registered(T)
  self.assertEqual(self.archive.query('510300','quote')[0]['data']['price'],12340)
  self.assertEqual(len(self.archive.query('510300','daily')),1)
  minute=self.archive.query('510300','intraday')
  self.assertEqual(len(minute),1)
  self.assertEqual(minute[0]['data']['price'],12340)
  self.assertNotIn('volume',minute[0]['data'])
 def test_stale_provider_quote_is_not_archived_as_fresh_minute(self):
  fields=['']*31;fields[3]='1.234';fields[30]='20261019093000'
  raw=('v_sh510300="'+'~'.join(fields)+'";').encode()
  runtime=MarketRuntime(self.channels,self.archive,lambda *args,**kwargs:(raw,''),holdings_provider=lambda:[{'symbol':'510300','asset':'etf'}])
  runtime.collect_registered(T)
  self.assertEqual(len(self.archive.query('510300','quote')),1)
  self.assertEqual(self.archive.query('510300','intraday'),[])
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
  fields=['']*31;fields[3]='1';fields[30]='20261019100000'
  def fetch(url,**kwargs):
   if 'sh510300'in url:raise ValueError('fixture failure')
   return ('v_sz159919="'+'~'.join(fields)+'";').encode(),''
  errors=MarketRuntime(self.channels,self.archive,fetch,holdings_provider=lambda:defs).collect_registered(T)
  self.assertEqual(len(errors),1);self.assertEqual(len(self.archive.query('159919','quote')),1)
