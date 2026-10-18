// Called only by the disposable Python HTTP integration test.
const assert=require('node:assert/strict'),C=require('../guanpan-pro-native/Sources/Lab/LabCore.js'),W=require('../nas-sync-server/lab-worker.cjs');
const T=Date.parse('2026-10-19T02:00:00Z'),base=process.argv[2],token='integration-test-only';
async function req(channel,body){const r=await fetch(base+'/api/v2/channels/'+channel,{method:body?'POST':'GET',headers:{'Authorization':'Bearer '+token,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});const v=await r.json();assert.equal(r.status,200,JSON.stringify(v));return v;}
function b(at,id){return {id,symbol:'510300',at,session:'2026-10-19',isTrading:true,model:'fiveLevel',source:'synthetic',quantityUnit:'shares',
 bids:Array.from({length:5},(_,i)=>({price:9900-i*10,quantity:1000})),asks:Array.from({length:5},(_,i)=>({price:10000+i*10,quantity:i?0:100}))};}
async function main(){
 let s=C.create({at:T,cash:10000000,positions:[{symbol:'510300',asset:'etf',quantity:100,cost:10000,price:10000,tick:10,lot:100,tPlusOne:false}]},'http-probe');
 s=C.dispatch(s,{type:'order',account:'G',id:'probe-order',symbol:'510300',side:'buy',quantity:200,limit:10000,at:T+1000,expiresAt:T+100000,session:'2026-10-19'});
 await req('assets',{schemaVersion:2,expectedRevision:0,requestID:'actual',intent:'manual',data:{cash:7770000,holdings:[],ledger:[]}});
 const originalAsset=await req('assets');
 await req('quant',{schemaVersion:2,expectedRevision:0,requestID:'seed',data:{lab:s,preferences:{preserve:true}}});
 await req('market',{schemaVersion:2,expectedRevision:0,requestID:'m1',data:{books:[b(T+2000,'b1')],quotes:[{symbol:'510300',at:T+2000,price:10000}]}});
 await W.tick({base,token,owner:'worker-a',now:()=>T+2000});
 let q=await req('quant');assert.equal(q.data.lab.accounts.G.fills.length,1);assert.equal(q.data.preferences.preserve,true);
 const firstRevision=q.revision;
 await W.tick({base,token,owner:'restarted-worker',now:()=>T+2100});q=await req('quant');assert.equal(q.revision,firstRevision);
 await req('market',{schemaVersion:2,expectedRevision:1,requestID:'m2',data:{books:[b(T+3000,'b2')],quotes:[{symbol:'510300',at:T+3000,price:10000}]}});
 await W.tick({base,token,owner:'restarted-worker',now:()=>T+3000});q=await req('quant');
 assert.equal(q.data.lab.accounts.G.fills.length,2);assert.equal(q.data.lab.accounts.G.orders[0].status,'filled');
 assert.equal(q.data.lab.accounts.G.cash,7998000);assert.deepEqual(await req('assets'),originalAsset);
 console.log('PASS: real HTTP -> lease -> virtual partial fills -> restart -> CAS; real asset document unchanged');
}
main().catch(e=>{console.error(e.stack);process.exitCode=1;});
