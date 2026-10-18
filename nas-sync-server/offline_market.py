"""Import a user-supplied normalized bundle into separate v2 databases, offline.
Never loads sync.sqlite3 or calls any external provider.
"""
import argparse,json,time
from pathlib import Path
from market_data import MarketArchive
from channel_store import ChannelStore
from market_runtime import MarketRuntime

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',type=Path,required=True)
    parser.add_argument('--data-dir',type=Path,required=True)
    parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--at',type=int)
    parser.add_argument('--offset',type=int,default=0)
    parser.add_argument('--limit',type=int,default=50)
    args=parser.parse_args();now=int(time.time()*1000)if args.at is None else args.at
    if now>int(time.time()*1000)or now<=0:parser.error('as-of time must not be in the future')
    if args.input.stat().st_size>16*1024*1024:parser.error('bundle exceeds 16 MiB; split into batches')
    if args.report.resolve()==args.input.resolve():parser.error('report must not overwrite the input bundle')
    runtime=MarketRuntime(ChannelStore(args.data_dir/'channels-v2.sqlite3'),MarketArchive(args.data_dir/'market-v2.sqlite3'))
    result=runtime.ingest_bundle(json.loads(args.input.read_text(encoding='utf-8-sig')),now)
    report=dict(ingest=result,page=runtime.research_page(args.offset,args.limit,now),realAssetsReadOrWritten=False)
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'inserted':result['inserted'],'report':str(args.report),'networkUsed':False}))

if __name__=='__main__':main()
