/* NAS-only virtual executor. Uses v2 quant, never legacy/native/assets routes. */
const path=require('node:path'),crypto=require('node:crypto');
const directory=process.env.LAB_CORE_DIR||path.join(__dirname,'../guanpan-pro-native/Sources/Lab');
const C=require(path.join(directory,'LabCore.js')),R=require(path.join(directory,'LabResearch.js'));
function cycle(quant,market,now){
  const data=JSON.parse(JSON.stringify(quant.data||{}));if(!data.lab)return {data,changed:false,status:'no-laboratory'};
  let state=data.lab;C.validate(state);const start=JSON.stringify(state),diagnostics=[];let traded=false;
  if(Object.values(state.accounts).some(a=>a.lastAt>now))throw Error('laboratory clock is ahead of NAS; no mutation');
  for(const account of Object.keys(state.accounts))if(state.accounts[account].orders.some(o=>['waiting','partial'].includes(o.status)&&o.expiresAt<=now))state=C.dispatch(state,{type:'expire',account,at:now});
  for(const b of (market.data?.books||[])){
    if(!Number.isSafeInteger(b.at)||now-b.at>5000||b.at>now)continue;
    for(const account of Object.keys(state.accounts)){
      const a=state.accounts[account];
      if(!a.orders.some(o=>o.symbol===b.symbol&&['waiting','partial'].includes(o.status)))continue;
      if(a.events.some(e=>e.type==='bookProcessed'&&e.symbol===b.symbol&&e.bookAt>=b.at))continue;
      try{const before=state.accounts[account].fills.length;state=C.dispatch(state,{type:'book',account,book:b,at:now});if(state.accounts[account].fills.length>before)traded=true;}catch(e){diagnostics.push({account,symbol:b.symbol,error:e.message});}
    }
  }
  const research=market.data?.quality?.researchSnapshot;
  const executor=data.executor||{};let reviewed=false;
  if(state.autonomous?.enabled===true&&research&&now-(executor.lastResearchAt||0)>=(state.autonomous.intervalMs||86400000)){
    const d=R.decide(state,research,now,state.autonomous.rules||{});state=d.state;
    data.reviews=[...(data.reviews||[]),...d.reviews];executor.lastResearchAt=now;
    reviewed=true;
  }
  // Do not invent valuations when current prices for ANY held position are missing.
  const prices=Object.fromEntries((market.data?.quotes||[]).filter(q=>q.at<=now&&now-q.at<=300000&&Number.isSafeInteger(q.price)&&q.price>0).map(q=>[q.symbol,q.price]));
  if(Object.values(state.accounts).every(a=>a.positions.every(p=>p.originalQuantity+p.lots.reduce((n,l)=>n+l.quantity,0)===0||prices[p.symbol]))){
    // No periodic mark unless a new source timestamp arrives. Repeated polls do not create artificial observations.
    const sourceAt=Math.max(0,...(market.data?.quotes||[]).map(q=>q.at||0));
    if((sourceAt>(executor.lastValuationSourceAt||0)||traded)&&now>state.seed.at){
      for(const account of Object.keys(state.accounts))if(!state.accounts[account].marks.some(m=>m.at===now))state=C.dispatch(state,{type:'mark',account,at:now,prices});
      executor.lastValuationSourceAt=sourceAt;
    }
  }
  const changed=JSON.stringify(state)!==start||reviewed;
  if(changed){data.lab=state;data.executor={...executor,lastCycleAt:now,model:'NAS-virtual-executor-v1',diagnostics};}
  return {data,changed,status:diagnostics.length?'processed-with-diagnostics':'processed',diagnostics};
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
  const base=(process.env.SYNC_URL||'http://guanpan-nas-sync:8787').replace(/\/$/,'');
  const owner='NAS-'+crypto.randomUUID(),token=process.env.SYNC_TOKEN||'';
  while(true){try{const r=await tick({base,token,owner});console.log(JSON.stringify({at:Date.now(),status:r.status,changed:r.changed}));}
    catch(e){console.error(JSON.stringify({at:Date.now(),status:'paused',reason:e.message}));}
    await new Promise(resolve=>setTimeout(resolve,Number(process.env.LAB_POLL_MS)||2000));}
}
module.exports={cycle,tick};if(require.main===module)main();
