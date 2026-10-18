import unittest,tempfile,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'nas-sync-server'))
from fundamentals import derive
from market_universe import UniverseStore
from market_data import MarketArchive
from market_runtime import MarketRuntime
from channel_store import ChannelStore,ChannelError
T=1792375200000
DAY=86400000
def financials():
 return dict(symbol='600000',asset='stock',source='synthetic-audited-reports',price=2,
  reports=[dict(period='annual',periodEnd=T-(4-i)*365*DAY,publishedAt=T-(4-i)*365*DAY+DAY,dividendPerShare=.1,eps=.2,netProfit=100,operatingCashFlow=90,freeCashFlow=50)for i in range(3)],
  valuations=[dict(at=T-(21-i)*DAY,availableAt=T-(21-i)*DAY+1,pe=20-i*.5)for i in range(20)])
def manifest():return dict(asOf=T,source='synthetic-provider',scope='provided',expectedCount=2,instruments=[dict(symbol='510300',asset='etf'),dict(symbol='600000',asset='stock')])
class ResearchInputTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
  self.archive=MarketArchive(self.root/'market-v2.sqlite3');self.universe=UniverseStore(self.archive)
  self.runtime=MarketRuntime(ChannelStore(self.root/'channels-v2.sqlite3'),self.archive)
 def tearDown(self):self.temp.cleanup()
 def test_annual_factors_have_explainable_units_and_full_inputs(self):
  f=derive(financials(),T)
  self.assertEqual(f['missing'],[]);self.assertAlmostEqual(f['dividendYield'],.05)
  self.assertAlmostEqual(f['dividendStability'],1);self.assertAlmostEqual(f['cashFlowQuality'],.9)
  self.assertEqual(f['valuationObservations'],20)
 def test_future_reports_and_valuations_do_not_enter_factors(self):
  b=financials();b['reports'][2]['publishedAt']=T+1;b['valuations'][-1]['availableAt']=T+1
  f=derive(b,T);self.assertIn('dividendStability',f['missing']);self.assertIn('valuationPercentile',f['missing'])
 def test_missing_annuals_and_etf_company_eps_are_never_fabricated(self):
  b=financials();b['reports']=[];self.assertIn('dividendYield',derive(b,T)['missing'])
  b['asset']='etf'
  with self.assertRaises(ValueError):derive(b,T)
 def test_universe_is_independent_of_holdings_and_survives_restart(self):
  self.universe.put(manifest(),T)
  again=UniverseStore(MarketArchive(self.archive.path));self.assertEqual(len(again.get(T)['instruments']),2)
  self.assertFalse(again.coverage(T)['isFullMarket']);self.assertIsNone(again.get(T-1))
 def test_full_market_requires_explicit_manifest_and_fresh_data_coverage(self):
  m=manifest();m.update(scope='full-market',providerConfirmsComplete=True)
  self.universe.put(m,T);self.assertFalse(self.universe.coverage(T)['isFullMarket'])
  rows=[dict(symbol=p['symbol'],asset=p['asset'],kind='quote',at=T,availableAt=T,source='synthetic',data={'price':10000})for p in m['instruments']]
  self.archive.ingest(rows,T);self.assertTrue(self.universe.coverage(T)['isFullMarket'])
  self.assertFalse(self.universe.coverage(T+300001)['isFullMarket'])
 def test_universe_version_cannot_silently_change(self):
  m=manifest();self.universe.put(m,T);m['source']='other'
  with self.assertRaises(ChannelError):self.universe.put(m,T)
 def test_offline_bundle_produces_factors_and_paged_research_without_real_db(self):
  self.runtime.ingest_bundle({'records':[],'universe':manifest(),'financials':[financials()]},T)
  page=self.runtime.research_page(1,1,T)
  self.assertEqual(page['research']['instruments'][0]['symbol'],'600000')
  self.assertEqual(page['research']['instruments'][0]['fundamentals']['missing'],[])
  self.assertIsNone(page['nextOffset']);self.assertFalse((self.root/'sync.sqlite3').exists())
 def test_announced_future_dividend_is_visible_but_future_quote_is_not_accepted(self):
  event=dict(id='div:test',recordAt=T+1000,paymentAt=T+2000,publishedAt=T-1,netPerShare=10)
  row=dict(symbol='510300',asset='etf',kind='dividend',at=T+1000,availableAt=T,source='synthetic-announcement',data=event)
  self.archive.ingest([row],T)
  data=self.archive.snapshot([dict(symbol='510300',asset='etf')],T)
  self.assertEqual(data['dividendEvents'][0]['id'],'div:test')
  row.update(kind='quote',data={'price':10000})
  with self.assertRaises(ChannelError):self.archive.ingest([row],T)
 def test_invalid_factor_and_future_publication_are_rejected(self):
  for data in [{'cashFlowQuality':2},{'publishedAt':T+1},{'dividendYield':float('nan')}]:
   row=dict(symbol='510300',asset='etf',kind='fundamentals',at=T,availableAt=T,source='synthetic',data=data)
   with self.assertRaises(ChannelError):self.archive.ingest([row],T)
