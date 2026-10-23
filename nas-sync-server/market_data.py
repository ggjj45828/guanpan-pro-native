"""Permanent, de-duplicated v2 records. Source timestamps are not backfilled
with capture time. Never opens the real-asset database or synthesizes liquidity.
"""
import hashlib
import json
import math
import sqlite3
import time
from datetime import datetime,timezone,timedelta
from contextlib import closing,nullcontext
from pathlib import Path
from channel_store import ChannelError, canonical

KINDS={'quote','intraday','daily','book','fundamentals','dividend','news'}

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
    if record['kind']=='news':
        from urllib.parse import urlparse
        url=r.get('sourceURL')
        parsed=urlparse(url) if isinstance(url,str) else None
        if not isinstance(r.get('headline'),str) or not 1<=len(r['headline'])<=300 or not isinstance(r.get('publisher'),str) or not 1<=len(r['publisher'])<=100 or not parsed or parsed.scheme!='https' or not parsed.hostname or parsed.username or parsed.password or len(url)>2000 or r.get('importance') not in ('normal','major') or r.get('eventScope') not in ('market','industry','security'):
            raise ChannelError(422,'invalid_attributed_news')
        if record['at']>record['availableAt']:raise ChannelError(422,'unpublished_news')
        if record['symbol']=='MARKET':
            if r['eventScope']=='security':raise ChannelError(422,'market_event_scope_mismatch')
            affected=r.get('affectedSymbols',[])
            if r['eventScope']=='industry' and (not isinstance(affected,list) or not affected or len(affected)>300 or any(not isinstance(s,str) or not s or len(s)>30 for s in affected)):
                raise ChannelError(422,'industry_event_requires_explicit_symbols')
        elif r['eventScope']!='security':
            raise ChannelError(422,'security_event_scope_mismatch')
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
    if record['kind']=='intraday' and 'volume'in r:
        if type(r['volume']) not in (int,float) or not math.isfinite(r['volume']) or r['volume']<0 or r.get('volumeUnit')!='shares':
            raise ChannelError(422,'intraday_volume_must_be_confirmed_shares')
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
        if kind not in KINDS or type(limit) is not int or not 1<=limit<=50000:raise ChannelError(422,'invalid_market_query')
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
        instruments=[];books=[];dividends=[];news=[]
        for r in self.query('MARKET','news',limit=30,before=now):
            news.append(dict(r['data'],symbol='MARKET',at=r['at'],availableAt=r['availableAt'],source=r['source']))
        for p in definitions:
            symbol=p['symbol'];item=dict(symbol=symbol,asset=p['asset'],bars=[],evidenceIDs=[],source='NAS-v2-archive')
            for r in self.query(symbol,'daily',limit=640,before=now):item['bars'].append(dict(r['data'],at=r['at'],availableAt=r['availableAt']))
            minutes=self.query(symbol,'intraday',limit=30000,before=now)
            item['intradayResearch']=self.intraday_summary(minutes,now)
            q=self.query(symbol,'quote',limit=1,before=now)
            if q:
                item['quote']=dict(q[-1]['data'],at=q[-1]['at'])
                item['source']='NAS archive / '+q[-1]['source']
                item['quoteSource']=q[-1]['source']
                item['evidenceIDs'].append(f"quote:{symbol}:{q[-1]['at']}")
            f=self.query(symbol,'fundamentals',limit=1,before=now)
            if f:item['fundamentals']=dict(f[-1]['data'],publishedAt=f[-1]['availableAt']);item['evidenceIDs'].append(f"fundamentals:{symbol}:{f[-1]['availableAt']}")
            for r in self.query(symbol,'dividend',limit=1000,before=now):dividends.append(dict(r['data'],symbol=symbol,source=r['source']))
            for r in self.query(symbol,'news',limit=30,before=now):
                news.append(dict(r['data'],symbol=symbol,at=r['at'],availableAt=r['availableAt'],source=r['source']))
            for r in self.query(symbol,'book',limit=1,before=now):
                b=dict(r['data'],id=f"book:{symbol}:{r['at']}",symbol=symbol,at=r['at'],source=r['source']);books.append(b)
            instruments.append(item)
        return dict(asOf=now,scope='registered-etf-stock',instruments=instruments,books=books,
            dividendEvents=dividends,news=news)
    @staticmethod
    def intraday_summary(records,now):
        # Only observed records already available at now participate. Without
        # confirmed share volume, VWAP-dependent measurements stay unavailable.
        def median(values):
            ordered=sorted(values)
            return ordered[len(ordered)//2] if ordered else None
        def bucket(at):
            local=datetime.fromtimestamp(at/1000,timezone(timedelta(hours=8)))
            minute=local.hour*60+local.minute
            if minute<10*60+30:return 'open'
            if minute<11*60+30:return 'lateMorning'
            if minute<14*60:return 'earlyAfternoon'
            return 'close'
        def session_minute(at):
            local=datetime.fromtimestamp(at/1000,timezone(timedelta(hours=8)))
            minute=local.hour*60+local.minute
            return minute if 570<=minute<690 or 780<=minute<900 else None
        groups={}
        for r in records:
            if r.get('at',0)>now or r.get('availableAt',0)>now:continue
            if session_minute(r['at']) is None:continue
            day=datetime.fromtimestamp(r['at']/1000,timezone(timedelta(hours=8))).strftime('%Y-%m-%d')
            groups.setdefault(day,[]).append(r)
        sessions=[];minute_evidence=[]
        for day,items in sorted(groups.items()):
            items.sort(key=lambda x:x['at']);prices=[x['data']['price'] for x in items]
            session_minutes=[session_minute(x['at']) for x in items]
            morning=sum(570<=minute<690 for minute in session_minutes)
            afternoon=sum(780<=minute<900 for minute in session_minutes)
            weighted=[(x['data']['price'],x['data'].get('volume')) for x in items if isinstance(x['data'].get('volume'),(int,float)) and x['data'].get('volume')>0 and x['data'].get('volumeUnit')=='shares']
            volume=sum(v for _,v in weighted);vwap=sum(p*v for p,v in weighted)/volume if volume else None
            high_index=prices.index(max(prices));low_index=prices.index(min(prices))
            reversion_opportunities=0;reversions=0;wait_minutes=[]
            round_trips=0;last_side=None
            if vwap and len(weighted)/len(items)>=0.8:
                pending=None
                for point in items:
                    price=point['data']['price'];at=point['at']
                    deviation=price/vwap-1
                    if pending and (abs(deviation)<=0.001 or deviation*pending[0]<0):
                        reversions+=1;wait_minutes.append((at-pending[1])/60000);pending=None
                    if pending is None and abs(deviation)>=0.003:
                        reversion_opportunities+=1;pending=(deviation,at)
                    side='upper' if deviation>=0.003 else 'lower' if deviation<=-0.003 else None
                    if side and last_side and side!=last_side:round_trips+=1
                    if side:last_side=side
            complete=len(items)>=200 and morning>=90 and afternoon>=90 and min(session_minutes)<=585 and max(session_minutes)>=885 and len(weighted)/len(items)>=0.8
            sessions.append(dict(day=day,points=len(items),complete=complete,open=prices[0],close=prices[-1],high=max(prices),low=min(prices),
                volume=volume if volume else None,vwap=vwap,volumeCoverage=len(weighted)/len(items) if items else 0,
                firstAt=items[0]['at'],lastAt=items[-1]['at'],
                highBucket=bucket(items[high_index]['at']),lowBucket=bucket(items[low_index]['at']),
                vwapDeviationHigh=max(prices)/vwap-1 if vwap else None,
                vwapDeviationLow=min(prices)/vwap-1 if vwap else None,
                reversionOpportunities=reversion_opportunities if vwap else None,
                reversions=reversions if vwap else None,
                meanReversionWaitMinutes=sum(wait_minutes)/len(wait_minutes) if wait_minutes else None,
                roundTrips=round_trips if vwap else None))
            if complete and len(items)<=260 and vwap:
                minute_evidence.append({'day':day,'vwap':vwap,
                    'points':[[p['at'],p['data']['price']] for p in items]})
        sessions=sessions[-120:];windows={}
        for n in (5,20,60,120):
            subset=sessions[-n:]
            weighted=[s for s in subset if s['vwap'] is not None and s['volumeCoverage']>=0.8]
            opportunities=sum(s['reversionOpportunities'] or 0 for s in weighted)
            reversions=sum(s['reversions'] or 0 for s in weighted)
            waits=[s['meanReversionWaitMinutes'] for s in weighted if s['meanReversionWaitMinutes'] is not None]
            highs={name:sum(s['highBucket']==name for s in subset) for name in ('open','lateMorning','earlyAfternoon','close')}
            lows={name:sum(s['lowBucket']==name for s in subset) for name in ('open','lateMorning','earlyAfternoon','close')}
            breaks=0;held_breaks=0
            for s in subset:
                previous=sessions.index(s)
                if previous<20:continue
                prior=sessions[previous-20:previous]
                upper=max(x['high'] for x in prior);lower=min(x['low'] for x in prior)
                if s['high']>upper or s['low']<lower:
                    breaks+=1
                    if s['close']>upper or s['close']<lower:held_breaks+=1
            windows[str(n)]={'available':len(subset)==n,'sessions':len(subset),
                'meanRangePct':sum((x['high']-x['low'])/x['open'] for x in subset)/len(subset) if subset else None,
                'high':max((x['high'] for x in subset),default=None),'low':min((x['low'] for x in subset),default=None),
                'volumeCoverage':sum(x['volumeCoverage'] for x in subset)/len(subset) if subset else 0,
                'vwapDays':len(weighted),'medianPointsPerDay':median([s['points'] for s in subset]),
                'highTimeBuckets':highs,'lowTimeBuckets':lows,
                'vwapHighDeviationMedian':median([s['vwapDeviationHigh'] for s in weighted]),
                'vwapLowDeviationMedian':median([s['vwapDeviationLow'] for s in weighted]),
                'vwapReversion':{'opportunities':opportunities,'returned':reversions,
                    'observedRate':reversions/opportunities if opportunities else None,
                    'meanWaitMinutes':sum(waits)/len(waits) if waits else None},
                'roundTrips':sum(s['roundTrips'] or 0 for s in weighted),
                'breakout':{'observed':breaks,'heldToClose':held_breaks,
                    'observedHoldRate':held_breaks/breaks if breaks else None}}
        points=sum(x['points'] for x in sessions);coverage=sum(x['volumeCoverage'] for x in sessions)/len(sessions) if sessions else 0
        complete_days=sum(s['complete'] for s in sessions)
        return {'source':'NAS archived observed minute records','sessions':len(sessions),'samplePoints':points,
            'firstDay':sessions[0]['day'] if sessions else None,'lastDay':sessions[-1]['day'] if sessions else None,
            'lastAt':sessions[-1]['lastAt'] if sessions else None,'windows':windows,'volumeCoverage':coverage,
            'completeMinuteDays':complete_days,'medianPointsPerDay':median([s['points'] for s in sessions]),
            'latestSessionVWAP':sessions[-1]['vwap'] if sessions else None,
            'dailyEvidence':[{k:s[k] for k in ('day','points','complete','open','close','high','low','vwap','volume','volumeCoverage','firstAt','lastAt')} for s in sessions],
            'minuteEvidence':minute_evidence[-60:],
            'status':'ready-for-statistical-review' if len(sessions)>=60 and complete_days>=60 and coverage>=0.8 else 'insufficient-history-or-coverage',
            'pricePlansAllowed':False,'limitations':['没有明确来源的成交量不计算VWAP','统计结果不是买卖委托或成交概率']}
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
