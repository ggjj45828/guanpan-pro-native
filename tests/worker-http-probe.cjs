// Disposable HTTP integration probe. NAS screens evidence and never fills orders.
const assert=require('node:assert/strict');
const C=require('../guanpan-pro-native/Sources/Lab/LabCore.js');
const W=require('../nas-sync-server/lab-worker.cjs');
const T=Date.parse('2026-10-19T02:00:00Z'),DAY=86400000;
const base=process.argv[2],token='integration-test-only';
async function req(channel,body){
 const r=await fetch(base+'/api/v2/channels/'+channel,{method:body?'POST':'GET',
  headers:{'Authorization':'Bearer '+token,'Content-Type':'application/json'},
  body:body?JSON.stringify(body):undefined});
 const v=await r.json();assert.equal(r.status,200,JSON.stringify(v));return v;
}
function research(at){
 return {asOf:at,scope:'registered-etf-stock',instruments:[{symbol:'510300',asset:'etf',
  source:'HTTP integration observed fixture',evidenceIDs:['fixture:quote'],quote:{at,price:10000},
  bars:Array.from({length:65},(_,i)=>({at:T-(65-i)*DAY,availableAt:at,close:9500+i*8})),
  intradayResearch:{status:'ready-for-statistical-review',sessions:60,
   completeMinuteDays:60,samplePoints:13200,volumeCoverage:.95}}]};
}
async function main(){
 const lab=C.create({at:T,cash:10000000,positions:[{symbol:'510300',asset:'etf',
  quantity:100,cost:10000,price:10000,tick:10,lot:100,tPlusOne:false}]},'http-probe');
 await req('assets',{schemaVersion:2,expectedRevision:0,requestID:'actual',intent:'manual',
  data:{cash:7770000,holdings:[],ledger:[]}});
 const originalAsset=await req('assets');
 await req('quant',{schemaVersion:2,expectedRevision:0,requestID:'seed',
  data:{lab,preferences:{preserve:true}}});
 await req('market',{schemaVersion:2,expectedRevision:0,requestID:'m1',
  data:{quality:{researchSnapshot:research(T+2000)}}});
 const first=await W.tick({base,token,owner:'worker-a',now:()=>T+2000});
 assert.equal(first.status,'screened');
 let quant=await req('quant');
 assert.equal(quant.data.opportunityScan.opportunities.length,1);
 assert.equal(quant.data.opportunityScan.action,'screen-only');
 assert.deepEqual(quant.data.lab,lab);
 assert.equal(quant.data.preferences.preserve,true);
 const firstRevision=quant.revision;
 const repeat=await W.tick({base,token,owner:'restarted-worker',now:()=>T+2100});
 assert.equal(repeat.changed,false);
 assert.equal((await req('quant')).revision,firstRevision);
 await req('market',{schemaVersion:2,expectedRevision:1,requestID:'m2',
  data:{quality:{researchSnapshot:research(T+302000)}}});
 const later=await W.tick({base,token,owner:'restarted-worker',now:()=>T+302000});
 assert.equal(later.status,'screened');
 quant=await req('quant');
 assert.equal(quant.data.opportunityScan.opportunities.length,1);
 assert.deepEqual(quant.data.lab,lab);
 assert.deepEqual(await req('assets'),originalAsset);
 console.log('PASS: local HTTP -> lease -> research-only scan -> restart -> CAS; real assets and legacy lab untouched');
}
main().catch(error=>{console.error(error.stack);process.exitCode=1;});
