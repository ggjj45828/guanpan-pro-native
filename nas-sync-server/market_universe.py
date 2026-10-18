"""Explicit provider universe, independent of holdings. Never invent completeness."""
import json,re,time
from contextlib import closing
from channel_store import ChannelError,canonical

def validate_manifest(value,now):
    if not isinstance(value,dict)or not value.get('source')or type(value.get('asOf'))is not int or not 0<value['asOf']<=now:raise ChannelError(422,'invalid_universe_source')
    rows=value.get('instruments')
    if not isinstance(rows,list)or not 1<=len(rows)<=20000:raise ChannelError(422,'invalid_universe_size')
    if any(not isinstance(r,dict)or not isinstance(r.get('symbol'),str)for r in rows):raise ChannelError(422,'invalid_universe_instrument')
    if len({r.get('symbol')for r in rows})!=len(rows):raise ChannelError(422,'duplicate_universe_symbol')
    for r in rows:
        if not isinstance(r.get('symbol'),str)or not re.fullmatch(r'(?:sh|sz|bj)?\d{6}',r['symbol'])or r.get('asset')not in ('etf','stock'):raise ChannelError(422,'invalid_universe_instrument')
    if value.get('scope')not in ('provided','full-market')or type(value.get('expectedCount'))is not int or value['expectedCount']<len(rows):raise ChannelError(422,'invalid_universe_coverage')
    if value.get('scope')=='full-market'and(value['expectedCount']!=len(rows)or value.get('providerConfirmsComplete')is not True):raise ChannelError(422,'unconfirmed_full_market_universe')
    canonical(value)

class UniverseStore:
    def __init__(self,archive):self.archive=archive;self._coverage_cache={}
    def _connect(self):
        db=self.archive.connect();db.execute('CREATE TABLE IF NOT EXISTS universe_history(as_of INTEGER PRIMARY KEY,payload TEXT NOT NULL)');return db
    def put(self,value,now):
        validate_manifest(value,now)
        self._coverage_cache={}
        with closing(self._connect())as db:
            old=db.execute('SELECT payload FROM universe_history WHERE as_of=?',(value['asOf'],)).fetchone()
            if old and old[0]!=canonical(value):raise ChannelError(409,'universe_version_is_immutable')
            db.execute('INSERT OR IGNORE INTO universe_history VALUES(?,?)',(value['asOf'],canonical(value)))
        return value
    def get(self,at):
        with closing(self._connect())as db:row=db.execute('SELECT payload FROM universe_history WHERE as_of<=? ORDER BY as_of DESC LIMIT 1',(at,)).fetchone()
        return json.loads(row[0])if row else None
    def coverage(self,at):
        value=self.get(at)
        if not value:return {'scope':'unconfigured','isFullMarket':False,'expected':None,'registered':0,'freshQuotes':0,'fundamentals':0}
        key=(at,value['asOf'],self.archive.generation);cached=self._coverage_cache.get(key)
        if cached and time.monotonic()-cached[0]<30:return dict(cached[1])
        quoted=factors=0
        with closing(self.archive.connect())as db:
            for p in value['instruments']:
                rows=self.archive.query(p['symbol'],'quote',limit=1,before=at,_db=db)
                quoted+=bool(rows and 0<=at-rows[-1]['at']<=300000)
                rows=self.archive.query(p['symbol'],'fundamentals',limit=1,before=at,_db=db)
                factors+=bool(rows and all(k in rows[-1]['data']for k in ('dividendYield','valuationPercentile','dividendStability','cashFlowQuality')))
        result=dict(scope=value['scope'],source=value['source'],asOf=value['asOf'],expected=value['expectedCount'],registered=len(value['instruments']),freshQuotes=quoted,fundamentals=factors,
            isFullMarket=value['scope']=='full-market'and quoted==value['expectedCount'])
        if len(self._coverage_cache)>=16:self._coverage_cache.clear()
        self._coverage_cache[key]=(time.monotonic(),result)
        return result
