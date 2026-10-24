/* NAS-only opportunity scanner. It reads market evidence and writes screening
 * results; it never creates accounts, orders, fills, marks, or portfolio events. */
const path=require('node:path'),crypto=require('node:crypto');
const directory=process.env.LAB_CORE_DIR||path.join(__dirname,'../guanpan-pro-native/Sources/Lab');
const R=require(path.join(directory,'LabResearch.js'));
function cycle(quant,market,now){
  const data=JSON.parse(JSON.stringify(quant.data||{}));
  const research=market.data?.quality?.researchSnapshot;
  if(!research||!Number.isSafeInteger(research.asOf)||research.asOf>now)
    return {data,changed:false,status:'paused-data-unavailable',diagnostics:['缺少有效、非未来的研究快照']};
  const executor=data.executor||{};
  const interval=Number.isSafeInteger(executor.intervalMs)?Math.max(60000,executor.intervalMs):300000;
  if(now-(executor.lastScanAt||0)<interval)
    return {data,changed:false,status:'waiting-interval',diagnostics:[]};
  let radar;
  try{radar=R.radar(research,now);}catch(e){
    return {data,changed:false,status:'paused-invalid-evidence',diagnostics:[e.message]};
  }
  const ranked=radar.ranked||[];
  const instruments=new Map((research.instruments||[]).map(x=>[x.symbol,x]));
  const eligible=ranked.filter(x=>x.health?.fresh&&!x.health?.missing?.includes('60 bars')&&!x.trap&&x.score!==null&&
    instruments.get(x.symbol)?.intradayResearch?.status==='ready-for-statistical-review');
  const opportunities=eligible.slice(0,20).map(x=>({symbol:x.symbol,score:x.score,trend:x.trend||'unknown',quoteAt:x.quoteAt,
      intradayResearch:instruments.get(x.symbol).intradayResearch,
      source:x.source,evidenceIDs:x.evidenceIDs||[],status:'待手机结合真实持仓核验',
      limitations:['仅为市场筛查，不含真实持仓、可卖份额与账户现金','不生成方向、委托价格、数量或收益预测']}));
  const scan={at:now,marketAsOf:research.asOf,model:'nas-opportunity-scanner-v1',
    coverage:radar.coverage,opportunities,blocked:ranked.length-eligible.length,
    omittedByDisplayLimit:Math.max(0,eligible.length-opportunities.length),
    action:'screen-only',automatesRealTrades:false};
  const nextExecutor={...executor,lastScanAt:now,lastCycleAt:now,intervalMs:interval,
    model:'nas-opportunity-scanner-v1',diagnostics:[]};
  const changed=JSON.stringify(data.opportunityScan)!==JSON.stringify(scan)||JSON.stringify(data.executor)!==JSON.stringify(nextExecutor);
  if(changed){data.opportunityScan=scan;data.executor=nextExecutor;}
  return {data,changed,status:'screened',diagnostics:[],scan};
}
async function tick({base,token='',owner,fetcher=fetch,now=Date.now}){
  const req=async(route,body)=>{
    const response=await fetcher(base+'/api/v2/channels/'+route,{method:body?'POST':'GET',headers:{'Authorization':'Bearer '+token,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});
    const result=await response.json();if(!response.ok||result.ok!==true)throw Error(result.err||'channel request failed');return result;
  };
  const lease=await req('quant/lease',{owner,ttlSeconds:15});
  try{
    const q=await req('quant'),m=await req('market'),result=cycle(q,m,now());
    if(result.changed)await req('quant',{schemaVersion:2,expectedRevision:q.revision,requestID:crypto.randomUUID(),executionLease:{owner,fence:lease.fence},data:result.data});
    return result;
  }finally{await req('quant/release',{owner,fence:lease.fence}).catch(()=>{});}
}
async function main(){
  const base=(process.env.SYNC_URL||'http://guanpan-nas-sync:8787').replace(/\/$/,''),owner='NAS-'+crypto.randomUUID(),token=process.env.SYNC_TOKEN||'';
  while(true){try{const r=await tick({base,token,owner});console.log(JSON.stringify({at:Date.now(),status:r.status,changed:r.changed}));}
    catch(e){console.error(JSON.stringify({at:Date.now(),status:'paused',reason:e.message}));}
    await new Promise(resolve=>setTimeout(resolve,Number(process.env.LAB_POLL_MS)||2000));}
}
module.exports={cycle,tick};if(require.main===module)main();
