"""Incremental bridge for original minute collector + optional normalized feed.
No assumed order book units: depth must come from an explicitly configured feed.
"""
import json
import os
import threading
import time
import uuid
import urllib.request
import re
from datetime import datetime,timezone,timedelta
from decimal import Decimal,ROUND_HALF_UP
from urllib.parse import urlparse,parse_qs
from market_data import MarketArchive
from channel_store import ChannelError
from market_universe import UniverseStore,validate_manifest
from market_data import valid
from fundamentals import derive

def units(value):
    number=Decimal(str(value))
    if not number.is_finite() or number<=0:raise ValueError('invalid price')
    return int((number*10000).quantize(Decimal('1'),rounding=ROUND_HALF_UP))

def configured_book(fields,definition,at,available,volume_multiplier):
    # Fixed existing-provider quote layout, gated by explicit unit confirmation.
    # No positive quantity is inferred from a price touch or last traded volume.
    if type(volume_multiplier)is not int or volume_multiplier<=0:raise ValueError('book volume units unconfirmed')
    bids=[];asks=[]
    for start,target in ((9,bids),(19,asks)):
        for i in range(5):
            price=units(fields[start+2*i]);quantity=Decimal(fields[start+2*i+1])*volume_multiplier
            if not quantity.is_finite()or quantity<0 or quantity!=quantity.to_integral_value():raise ValueError('invalid provider book quantity')
            target.append(dict(price=price,quantity=int(quantity)))
    local=datetime.fromtimestamp(at/1000,timezone(timedelta(hours=8)))
    minute=local.hour*60+local.minute
    return dict(symbol=definition['symbol'],asset=definition['asset'],kind='book',at=at,availableAt=available,
        source='configured-existing-quote-book-layout',data=dict(bids=bids,asks=asks,quantityUnit='shares',model='fiveLevel',
        session=local.strftime('%Y-%m-%d'),isTrading=local.weekday()<5 and(570<=minute<690 or 780<=minute<897)))

class MarketRuntime:
    def __init__(self,channels,archive,http_get=None,fetch_daily=None):
        self.channels=channels;self.archive=archive;self.lock=threading.Lock();self.last_error=None
        self.http_get=http_get;self.fetch_daily=fetch_daily;self.last_daily={};self.last_quote={};self.daily_attempt={};self.cursor=0
        self.universe=UniverseStore(archive)
    def definitions(self,include_universe=False):
        lab=(self.channels.get('quant').get('data')or{}).get('lab')or{}
        rows=[p for p in [*(lab.get('seed')or{}).get('positions',[]),*(lab.get('catalog')or{}).values()] if p.get('asset') in ('etf','stock')]
        if include_universe:rows+=((self.universe.get(int(time.time()*1000))or{}).get('instruments',[]))
        return list({p['symbol']:p for p in rows}.values())
    def ingest_bundle(self,body,now=None):
        now=int(time.time()*1000)if now is None else now
        if not isinstance(body,dict)or not isinstance(body.get('records'),list):raise ChannelError(422,'invalid_market_bundle')
        if not isinstance(body.get('financials',[]),list):raise ChannelError(422,'invalid_financial_bundle')
        records=list(body['records'])
        for bundle in body.get('financials',[]):
            factors=derive(bundle,now)
            records.append(dict(symbol=bundle['symbol'],asset='stock',kind='fundamentals',at=now,availableAt=now,source=bundle['source'],data=factors))
        for record in records:
            valid(record)
            if record['availableAt']>now:raise ChannelError(422,'future_market_evidence')
        if 'universe'in body:
            validate_manifest(body['universe'],now)
            old=self.universe.get(body['universe']['asOf'])
            if old and old['asOf']==body['universe']['asOf']and old!=body['universe']:raise ChannelError(409,'universe_version_is_immutable')
        result=self.ingest(records,now)
        if 'universe'in body:self.universe.put(body['universe'],now)
        return result
    def research_page(self,offset,limit,now):
        if type(offset)is not int or offset<0 or type(limit)is not int or not 1<=limit<=100:raise ChannelError(422,'invalid_research_page')
        manifest=self.universe.get(now)
        rows=(manifest or {}).get('instruments',[])
        data=self.archive.snapshot(rows[offset:offset+limit],now)
        return dict(ok=True,offset=offset,nextOffset=offset+limit if offset+limit<len(rows)else None,
            coverage=self.universe.coverage(now),research=data)
    def ingest_minutes(self,code,bars,now=None):
        now=int(time.time()*1000) if now is None else now
        p=next((p for p in self.definitions() if p['symbol'].lower().removeprefix('sh').removeprefix('sz').removeprefix('bj')==code.lower().removeprefix('sh').removeprefix('sz').removeprefix('bj')),None)
        if not p:return
        rows=[]
        for b in bars:
            at=int(b['timestamp'])*1000
            if at>now:continue
            data={'price':units(b['price'])}
            if b.get('iopv') is not None:data['iopv']=units(b['iopv'])
            rows.append(dict(symbol=p['symbol'],asset=p['asset'],kind='intraday',at=at,availableAt=now,source='original-NAS-minute-collector',data=data))
        if rows:
            latest=max(rows,key=lambda r:r['at']);rows.append(dict(latest,kind='quote',source='minute-price-fallback'))
            result=self.archive.ingest(rows,now)
            if result['inserted']:self.publish(now)
    def ingest(self,rows,now=None):
        result=self.archive.ingest(rows,now)
        if result['inserted']:self.publish(int(time.time()*1000) if now is None else now)
        return result
    def collect_registered(self,now=None):
        now=int(time.time()*1000)if now is None else now
        errors=[]
        definitions=self.definitions(include_universe=True)
        batch=(definitions+definitions)[self.cursor:self.cursor+20]if len(definitions)>20 else definitions
        self.cursor=(self.cursor+len(batch))%len(definitions)if definitions else 0
        for p in batch:
            try:self._collect_one(p,now)
            except Exception:errors.append('registered source failed for '+str(p.get('symbol','unknown')))
        return errors
    def _collect_one(self,p,now):
        code=p['symbol'];symbol=code.lower()
        if re.fullmatch(r'\d{6}',symbol):symbol=('sh'if symbol[0]in '569'else 'bj'if symbol[0]in '48'else 'sz')+symbol
        if not re.fullmatch(r'(sh|sz|bj)\d{6}',symbol):return
        local=datetime.fromtimestamp(now/1000,timezone(timedelta(hours=8)))
        minute=local.hour*60+local.minute
        live=local.weekday()<5 and (570<=minute<=690 or 780<=minute<=900)
        quote_interval=60000 if live else 600000
        if self.http_get and now-self.last_quote.get(code,0)>=quote_interval:
            self.last_quote[code]=now
            raw,_=self.http_get('https://qt.gtimg.cn/q='+symbol,timeout=8)
            text=raw.decode('gb18030',errors='replace');match=re.search(r'="([^"\r\n]+)"',text)
            fields=match.group(1).split('~')if match else []
            if len(fields)>30 and re.fullmatch(r'\d{14}',fields[30]):
                at=int(datetime.strptime(fields[30],'%Y%m%d%H%M%S').replace(tzinfo=timezone(timedelta(hours=8))).timestamp()*1000)
                if at<=now:
                    quote={'price':units(fields[3])}
                    if len(fields)>4 and fields[4]:quote['previousClose']=units(fields[4])
                    if p['asset']=='etf'and len(fields)>78 and fields[78]:
                        try:quote['iopv']=units(fields[78])
                        except ValueError:pass
                    self.ingest([dict(symbol=code,asset=p['asset'],kind='quote',at=at,availableAt=now,source='existing-Tencent-price-adapter',data=quote)],now)
                    multiplier=os.environ.get('V2_BOOK_VOLUME_MULTIPLIER','')
                    if multiplier:
                        try:self.ingest([configured_book(fields,p,at,now,int(multiplier))],now)
                        except (ValueError,IndexError,ChannelError):self.last_error='book validation failed; no fabricated liquidity'
        if self.fetch_daily and now-self.last_daily.get(code,0)>=6*3600000 and now-self.daily_attempt.get(code,0)>=60000:
            self.daily_attempt[code]=now
            raw,_=self.fetch_daily({'code':symbol,'n':'640','period':'day','fq':'qfq'})
            text=raw.decode('utf-8',errors='replace');body=json.loads(text[text.find('{'):text.rfind('}')+1])
            entry=(body.get('data')or{}).get(symbol)or{}
            bars=entry.get('qfqday')or entry.get('day')or[];records=[]
            for b in bars:
                at=int(datetime.strptime(b[0],'%Y-%m-%d').replace(hour=15,tzinfo=timezone(timedelta(hours=8))).timestamp()*1000)
                if at>now:continue
                records.append(dict(symbol=code,asset=p['asset'],kind='daily',at=at,availableAt=now,source='existing-Tencent-daily-adapter',data=dict(open=units(b[1]),close=units(b[2]),high=units(b[3]),low=units(b[4]),adjustment='provider-qfq'if entry.get('qfqday')else'none')))
            if records:self.ingest(records,now)
            self.last_daily[code]=now
    def publish(self,now):
        with self.lock:
            definitions=self.definitions();snap=self.archive.snapshot(definitions,now)
            for attempt in range(3):
                current=self.channels.get('market');old=current['data']or{}
                quotes=[dict(i['quote'],symbol=i['symbol'],source=i['source']) for i in snap['instruments'] if i.get('quote')]
                intraday=[]
                for p in definitions:
                    for r in self.archive.query(p['symbol'],'intraday',limit=1000,before=now):intraday.append(dict(r['data'],symbol=p['symbol'],at=r['at'],source=r['source']))
                payload=dict(old,quotes=quotes,books=snap['books'],intraday=intraday,quality={'researchSnapshot':snap,'lastError':self.last_error,'knownSymbols':len(definitions)},asOf=now)
                try:return self.channels.put('market',dict(schemaVersion=2,expectedRevision=current['revision'],requestID=uuid.uuid4().hex,data=payload))
                except ChannelError as e:
                    if e.code!='revision_conflict':raise
            raise ChannelError(409,'market_publish_conflict')
    def poll_feed(self,url,token='',fetch=None,now=None):
        parsed=urlparse(url)
        if parsed.scheme not in ('http','https') or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError('invalid configured feed URL')
        if parsed.scheme=='http' and parsed.hostname not in ('127.0.0.1','localhost'):
            raise ValueError('external feeds require HTTPS')
        if fetch is None:
            def fetch(url,token):
                req=urllib.request.Request(url,headers={'Authorization':'Bearer '+token} if token else {})
                with urllib.request.urlopen(req,timeout=10)as r:
                    raw=r.read(16*1024*1024+1)
                    if len(raw)>16*1024*1024:raise ValueError('feed too large')
                    return json.loads(raw)
        body=fetch(url,token)
        return self.ingest_bundle(body,now)
    def backup_daily(self,now=None):
        import hashlib
        now=int(time.time()*1000)if now is None else now
        day=datetime.fromtimestamp(now/1000,timezone.utc).strftime('%Y-%m-%d')
        folder=self.archive.path.parent/'backups-v2'/day
        folder.mkdir(parents=True,exist_ok=True)
        manifest=folder/'manifest.json'
        if manifest.exists():return manifest
        channel=folder/'channels-v2.sqlite3';market=folder/'market-v2.sqlite3'
        if not channel.exists():self.channels.backup(channel)
        if not market.exists():self.archive.backup(market)
        record={'capturedAt':now,'scope':'independent v2 database snapshots','files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in (channel,market)}}
        manifest.write_text(json.dumps(record,indent=2),encoding='utf8')
        return manifest
    def loop(self):
        while True:
            errors=[]
            try:
                url=os.environ.get('V2_FEED_URL','')
                if url:self.poll_feed(url,os.environ.get('V2_FEED_TOKEN',''))
            except Exception:errors.append('normalized feed unavailable or failed validation')
            if os.environ.get('V2_UPSTREAM_ENABLED','1')=='1':errors+=self.collect_registered()
            try:self.backup_daily()
            except Exception:errors.append('v2 daily backup failed')
            self.last_error='; '.join(errors)or None
            time.sleep(2 if os.environ.get('V2_FEED_URL') else 30)


def route(handler,method,path):
    if not path.startswith('/api/v2/market/'):return False
    if not handler.authorized():handler.close_connection=True;handler.send_json(401,{'ok':False,'err':'unauthorized'});return True
    try:
        runtime=handler.server.market_runtime
        if method=='POST' and path=='/api/v2/market/ingest':
            if int(handler.headers.get('Content-Length','0'))>16*1024*1024:raise ChannelError(413,'market_batch_too_large')
            body=handler.read_body();result=runtime.ingest_bundle(body)
        elif method=='GET'and path=='/api/v2/market/research-page':
            q=parse_qs(urlparse(handler.path).query)
            result=runtime.research_page(int(q.get('offset',['0'])[0]),int(q.get('limit',['50'])[0]),int(time.time()*1000))
        elif method=='GET'and path=='/api/v2/market/universe':
            result={'ok':True,'coverage':runtime.universe.coverage(int(time.time()*1000))}
        elif method=='GET'and path=='/api/v2/market/records':
            q=parse_qs(urlparse(handler.path).query)
            result={'ok':True,'records':runtime.archive.query(q.get('symbol',[''])[0],q.get('kind',[''])[0],start=int(q.get('start',['0'])[0]),end=int(q.get('end',[str(2**63-1)])[0]),limit=int(q.get('limit',['1000'])[0]),before=int(q['before'][0])if 'before'in q else None)}
        else:raise ChannelError(404,'route_not_found')
        handler.send_json(200,result)
    except ChannelError as e:handler.send_json(e.status,{'ok':False,'err':e.code})
    except (ValueError,TypeError,KeyError):handler.close_connection=True;handler.send_json(400,{'ok':False,'err':'invalid_market_request'})
    return True

