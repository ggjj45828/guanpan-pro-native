"""Permanent, de-duplicated v2 records. Source timestamps are not backfilled
with capture time. Never opens the real-asset database or synthesizes liquidity.
"""
import hashlib
import json
import math
import sqlite3
import time
from contextlib import closing,nullcontext
from pathlib import Path
from channel_store import ChannelError, canonical

KINDS={'quote','intraday','daily','book','fundamentals','dividend'}

def valid(record):
    if not isinstance(record,dict) or record.get('kind') not in KINDS or record.get('asset') not in ('etf','stock'):
        raise ChannelError(422,'unsupported_market_record')
    if not isinstance(record.get('symbol'),str) or not record['symbol'] or len(record['symbol'])>30:
        raise ChannelError(422,'invalid_market_symbol')
    if type(record.get('at')) is not int or record['at']<=0 or type(record.get('availableAt')) is not int or record['availableAt']<=0 or (record['kind']!='dividend'and record['availableAt']<record['at']):
        raise ChannelError(422,'invalid_market_timestamps')
    if not isinstance(record.get('source'),str) or not record['source'] or not isinstance(record.get('data'),dict):
        raise ChannelError(422,'source_and_data_required')
    r=record['data']
    if record['kind']=='dividend':
        if any(type(r.get(k))is not int or r[k]<0 for k in ('publishedAt','recordAt','paymentAt','netPerShare'))or not r['publishedAt']<=record['availableAt']<=r['recordAt']<r['paymentAt']or record['at']!=r['recordAt']:
            raise ChannelError(422,'invalid_announced_dividend')
        if not isinstance(r.get('id'),str)or not __import__('re').fullmatch(r'[A-Za-z0-9_.:-]{1,100}',r['id']):raise ChannelError(422,'invalid_dividend_id')
    if record['kind']=='fundamentals':
        for key in ('dividendYield','valuationPercentile','dividendStability','cashFlowQuality'):
            if key in r and(type(r[key])not in(int,float)or not math.isfinite(r[key])or not 0<=r[key]<=1):raise ChannelError(422,'invalid_fundamental_factor')
        if 'publishedAt'in r and(type(r['publishedAt'])is not int or r['publishedAt']>record['availableAt']):raise ChannelError(422,'invalid_fundamental_publication')
    if record['kind'] in ('quote','intraday') and 'price' not in r:raise ChannelError(422,'price_required')
    for key in ('price','close','open','high','low','iopv','previousClose'):
        if key in r and (type(r[key]) is not int or r[key]<=0):raise ChannelError(422,'invalid_market_price_units')
    if record['kind']=='daily':
        if not all(k in r for k in ('open','high','low','close')) or not r['low']<=min(r['open'],r['close'])<=max(r['open'],r['close'])<=r['high']:
            raise ChannelError(422,'invalid_ohlc')
    if record['kind']=='book':
        if r.get('quantityUnit')!='shares':raise ChannelError(422,'book_quantity_unit_must_be_confirmed_shares')
        for side in ('bids','asks'):
            if not isinstance(r.get(side),list) or len(r[side])>5:raise ChannelError(422,'invalid_book')
            if any(not isinstance(x,dict)or type(x.get('price')) is not int or x['price']<=0 or type(x.get('quantity')) is not int or x['quantity']<0 for x in r[side]):raise ChannelError(422,'invalid_depth')
        if r['bids'] and r['asks'] and max(l['price'] for l in r['bids'])>=min(l['price'] for l in r['asks']):raise ChannelError(422,'crossed_book')
    try:canonical(record)
    except (TypeError,ValueError):raise ChannelError(422,'nonfinite_market_data') from None

class MarketArchive:
    def __init__(self,path):
        self.path=Path(path)
        self.generation=0
        if self.path.name=='sync.sqlite3':raise ValueError('market archive must be separate')
    def connect(self):
        self.path.parent.mkdir(parents=True,exist_ok=True)
        db=sqlite3.connect(self.path,timeout=15,isolation_level=None);db.row_factory=sqlite3.Row
        db.execute('PRAGMA journal_mode=WAL');db.execute('PRAGMA synchronous=FULL')
        db.executescript('''
        CREATE TABLE IF NOT EXISTS records(symbol TEXT,kind TEXT,at INTEGER,available INTEGER,digest TEXT,payload TEXT,PRIMARY KEY(symbol,kind,at));
        CREATE TABLE IF NOT EXISTS corrections(symbol TEXT,kind TEXT,at INTEGER,digest TEXT,payload TEXT,PRIMARY KEY(symbol,kind,at,digest));
        CREATE TABLE IF NOT EXISTS gaps(id TEXT PRIMARY KEY,symbol TEXT,kind TEXT,start INTEGER,end INTEGER,attempts INTEGER DEFAULT 0,next_at INTEGER DEFAULT 0,status TEXT DEFAULT 'pending');
        ''');return db
    def ingest(self,records,now=None):
        now=int(time.time()*1000) if now is None else now
        if not isinstance(records,list) or len(records)>10000:raise ChannelError(422,'invalid_record_batch')
        for r in records:
            valid(r)
            if r['availableAt']>now:raise ChannelError(422,'future_market_evidence')
        inserted=0;unchanged=0
        with closing(self.connect()) as db:
            db.execute('BEGIN IMMEDIATE')
            try:
                for r in records:
                    text=canonical(r);digest=hashlib.sha256(text.encode()).hexdigest()
                    args=(r['symbol'],r['kind'],r['at'])
                    old=db.execute('SELECT digest,payload FROM records WHERE symbol=? AND kind=? AND at=?',args).fetchone()
                    prior=json.loads(old['payload'])if old else None
                    if old and (old['digest']==digest or prior['data']==r['data'] and prior['source']==r['source'] and prior['asset']==r['asset']):unchanged+=1;continue
                    if old:db.execute('INSERT OR IGNORE INTO corrections VALUES(?,?,?,?,?)',(*args,old['digest'],old['payload']))
                    db.execute('INSERT INTO records VALUES(?,?,?,?,?,?) ON CONFLICT(symbol,kind,at) DO UPDATE SET available=excluded.available,digest=excluded.digest,payload=excluded.payload',(*args,r['availableAt'],digest,text));inserted+=1
                db.commit()
            except BaseException:db.rollback();raise
        if inserted:self.generation+=1
        return dict(ok=True,inserted=inserted,unchanged=unchanged)
    def query(self,symbol,kind,start=0,end=2**63-1,limit=1000,before=None,_db=None):
        if kind not in KINDS or type(limit) is not int or not 1<=limit<=10000:raise ChannelError(422,'invalid_market_query')
        with (nullcontext(_db)if _db is not None else closing(self.connect())) as db:
            rows=db.execute('SELECT payload FROM records WHERE symbol=? AND kind=? AND at>=? AND at<=? AND available<=? ORDER BY at DESC LIMIT ?',
                (symbol,kind,start,end,before if before is not None else 2**63-1,limit)).fetchall()
            # Include prior versions that were actually available at the queried time.
            corrections=[] if before is None else db.execute('SELECT payload FROM corrections WHERE symbol=? AND kind=? AND at>=? AND at<=?',(symbol,kind,start,end)).fetchall()
        values=[json.loads(r['payload']) for r in [*rows,*corrections]]
        if before is not None:values=[r for r in values if r['availableAt']<=before]
        by_time={}
        for r in sorted(values,key=lambda r:r['availableAt']):by_time[r['at']]=r
        return sorted(by_time.values(),key=lambda r:r['at'])[-limit:]
    def snapshot(self,definitions,now):
        instruments=[];books=[];dividends=[]
        for p in definitions:
            symbol=p['symbol'];item=dict(symbol=symbol,asset=p['asset'],bars=[],evidenceIDs=[],source='NAS-v2-archive')
            for r in self.query(symbol,'daily',limit=640,before=now):item['bars'].append(dict(r['data'],at=r['at'],availableAt=r['availableAt']))
            q=self.query(symbol,'quote',limit=1,before=now)
            if q:item['quote']=dict(q[-1]['data'],at=q[-1]['at']);item['evidenceIDs'].append(f"quote:{symbol}:{q[-1]['at']}")
            f=self.query(symbol,'fundamentals',limit=1,before=now)
            if f:item['fundamentals']=dict(f[-1]['data'],publishedAt=f[-1]['availableAt']);item['evidenceIDs'].append(f"fundamentals:{symbol}:{f[-1]['availableAt']}")
            for r in self.query(symbol,'dividend',limit=1000,before=now):dividends.append(dict(r['data'],symbol=symbol,source=r['source']))
            for r in self.query(symbol,'book',limit=1,before=now):
                b=dict(r['data'],id=f"book:{symbol}:{r['at']}",symbol=symbol,at=r['at'],source=r['source']);books.append(b)
            instruments.append(item)
        return dict(asOf=now,scope='registered-etf-stock',instruments=instruments,books=books,dividendEvents=dividends)
    def enqueue_gap(self,symbol,kind,start,end):
        if kind not in KINDS or type(start) is not int or type(end) is not int or start>=end:raise ChannelError(422,'invalid_gap')
        key=f'{symbol}:{kind}:{start}:{end}'
        with closing(self.connect()) as db:db.execute('INSERT OR IGNORE INTO gaps(id,symbol,kind,start,end) VALUES(?,?,?,?,?)',(key,symbol,kind,start,end))
        return key
    def repair(self,fetch,now):
        # Fetch outside transactions; the immutable time range makes retries idempotent.
        with closing(self.connect()) as db:jobs=db.execute("SELECT * FROM gaps WHERE status='pending' AND next_at<=? ORDER BY start LIMIT 10",(now,)).fetchall()
        outcomes=[]
        for job in jobs:
            try:
                response=fetch(job['symbol'],job['kind'],job['start'],job['end'])
                coverage=response.get('coverage')if isinstance(response,dict)else None
                rows=response.get('records')if isinstance(response,dict)else response
                if not rows:raise ValueError('provider returned no evidence; gap remains pending')
                if any(r['symbol']!=job['symbol'] or r['kind']!=job['kind'] or not job['start']<=r['at']<=job['end'] for r in rows):raise ValueError('range mismatch')
                self.ingest(rows,now)
                # A provider must explicitly confirm complete coverage to finish a gap.
                verified=False
                if isinstance(coverage,dict)and coverage.get('complete')is True and coverage.get('start')==job['start']and coverage.get('end')==job['end']and isinstance(coverage.get('expectedTimes'),list)and coverage.get('source'):
                    expected=set(coverage['expectedTimes'])
                    actual={r['at']for r in self.query(job['symbol'],job['kind'],job['start'],job['end'],10000,before=now)}
                    verified=bool(expected)and expected<=actual and all(type(t)is int and job['start']<=t<=job['end']for t in expected)
                outcomes.append(dict(id=job['id'],ingested=len(rows),status='complete'if verified else'coverageNeedsVerification'))
                with closing(self.connect()) as db:db.execute('UPDATE gaps SET attempts=attempts+1,next_at=?,status=? WHERE id=?',(now+60000,'complete'if verified else'pending',job['id']))
            except Exception as e:
                delay=min(86400000,1000*2**min(job['attempts']+1,16))
                with closing(self.connect()) as db:db.execute('UPDATE gaps SET attempts=attempts+1,next_at=? WHERE id=?',(now+delay,job['id']))
                outcomes.append(dict(id=job['id'],status='retry',error=str(e)[:120]))
        return outcomes

    def backup(self,destination):
        destination=Path(destination)
        if destination.exists()or destination.resolve()==self.path.resolve():raise ValueError('backup destination must be new')
        destination.parent.mkdir(parents=True,exist_ok=True)
        with closing(self.connect())as db,closing(sqlite3.connect(destination))as out:db.backup(out)
        return destination
