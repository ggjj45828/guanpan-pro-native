const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const C=require('../guanpan-pro-native/Sources/Lab/LabCore.js'),R=require('../guanpan-pro-native/Sources/Lab/LabResearch.js');
const W=require('../nas-sync-server/lab-worker.cjs');
const T=Date.parse('2026-10-19T02:00:00Z'),DAY=86400000;
function model(decisions){return JSON.stringify({schemaVersion:1,model:'synthetic-test',decisions});}
function decision(extra={}){return {symbol:'510300',side:'buy',quantity:100,limit:9900,expiresAt:T+DAY,evidenceIDs:['fixture:quote'],reason:'synthetic evidence',...extra};}
test('model proposal creates only virtual G orders and preserves original caller',()=>{
 const s=state(),before=JSON.stringify(s),r=R.reviewModel(s,data(),model([decision()]),T+10000);
 assert.equal(r.accepted.length,1);assert.equal(r.realTrades,false);assert.equal(JSON.stringify(s),before);
 assert.equal(r.state.accounts.A.orders.length,0);assert.equal(r.state.accounts.G.orders.length,1);
 assert.deepEqual(r.state.seed,s.seed);
});
test('model review rejects fabricated evidence, stale data, null orders and invalid quantities',()=>{
 const cases=[decision({evidenceIDs:['invented']}),null,decision({quantity:-100}),decision({symbol:'999999'}),decision({expiresAt:T})];
 for(const row of cases){const r=R.reviewModel(state(),data(),model([row]),T+10000);assert.equal(r.accepted.length,0);assert.equal(r.rejected.length,1);}
 const d=data();d.instruments[0].quote.at=T-900000;assert.equal(R.reviewModel(state(),d,model([decision()]),T+10000).accepted.length,0);
});
test('model review accumulates pending exposure and protects cash reserve',()=>{
 const r=R.reviewModel(state(),data(),model([decision({quantity:300}),decision({quantity:300})]),T+10000);
 assert.equal(r.accepted.length,1);assert.equal(r.rejected.length,1);
 assert.equal(R.reviewModel(state(),data(),model([decision()]),T+10000,{minCash:.95}).accepted.length,0);
 const s=state();s.researchOnly=true;assert.throws(()=>R.reviewModel(s,data(),model([decision()]),T+10000),/研究副本/);
});
test('T+0 allows same-day AI acquisitions to be sold, T+1 prevents it',()=>{
 for(const tPlusOne of [false,true]){
  let s=C.dispatch(state(),{type:'tradingRule',symbol:'510300',id:'confirmed',at:T,tPlusOne});
  s=C.dispatch(s,{type:'salePolicy',account:'G',value:'aiOnly'});
  s=C.dispatch(s,{type:'order',account:'G',id:'buy',symbol:'510300',side:'buy',quantity:100,limit:10000,at:T+1000,expiresAt:T+DAY,session:'2026-10-19',origin:'ai'});
  s=C.dispatch(s,{type:'book',account:'G',book:book(),at:T+20000});
  const sell={type:'order',account:'G',id:'sell',symbol:'510300',side:'sell',quantity:100,limit:9800,at:T+21000,expiresAt:T+DAY,session:'2026-10-19'};
  if(tPlusOne)assert.throws(()=>C.dispatch(s,sell),/未交收/);
  else {s=C.dispatch(s,sell);const b={...book(T+22000),id:'new-sell-book'};s=C.dispatch(s,{type:'book',account:'G',book:b,at:T+22000});assert.equal(s.accounts.G.fills.length,2);}
 }
});
test('trading rule correction preserves seed and rejects pending orders',()=>{
 const s=state(),next=C.dispatch(s,{type:'tradingRule',symbol:'510300',id:'t0',at:T,tPlusOne:false});
 assert.deepEqual(next.seed,s.seed);assert.equal(next.ruleChanges.length,1);assert.ok(Object.values(next.accounts).every(a=>a.positions[0].tPlusOne===false));
 const pending=C.dispatch(s,{type:'order',account:'A',id:'pending',symbol:'510300',side:'buy',quantity:100,limit:9900,at:T+1,expiresAt:T+DAY,session:'2026-10-19'});
 assert.throws(()=>C.dispatch(pending,{type:'tradingRule',symbol:'510300',id:'t0',at:T+2,tPlusOne:false}),/撤销/);
});
test('scheduled virtual funding requires explicit enablement and never runs twice',()=>{
 let s=C.dispatch(state(),{type:'plan',month:'2026-10',amount:10000,paused:false,executeAt:T+10000});
 assert.equal(W.cycle({data:{lab:s}},{data:{}},T+20000).changed,false);
 s=C.dispatch(s,{type:'fundingSchedule',enabled:true});
 const first=W.cycle({data:{lab:s}},{data:{}},T+20000);assert.equal(first.data.lab.accounts.A.cash,s.accounts.A.cash+10000);
 const second=W.cycle({data:first.data},{data:{}},T+21000);assert.equal(second.changed,false);
 assert.ok(Object.values(second.data.lab.accounts).every(a=>a.flows.length===1));
});
test('announced dividend catches up with historical record-day quantity and is not capital',()=>{
 let s=C.dispatch(state(),{type:'order',account:'G',id:'buy',symbol:'510300',side:'buy',quantity:100,limit:10000,at:T+1000,expiresAt:T+DAY,session:'2026-10-19'});
 s=C.dispatch(s,{type:'book',account:'G',book:book(),at:T+20000});
 const event={id:'dividend:test',symbol:'510300',recordAt:T+5000,paymentAt:T+25000,publishedAt:T-1,netPerShare:10};
 const m={data:{quality:{researchSnapshot:{dividendEvents:[event]}}}},result=W.cycle({data:{lab:s}},m,T+30000);
 assert.equal(result.data.lab.dividendRecords[event.id].entitlements.G,100);
 assert.equal(result.data.lab.accounts.G.incomes[0].amount,1000);assert.equal(result.data.lab.accounts.G.flows.length,0);
 assert.equal(W.cycle({data:result.data},m,T+31000).changed,false);
});
function state(cash=10000000){return C.create({at:T,cash,positions:[{symbol:'510300',asset:'etf',quantity:100,cost:10000,price:10000,tick:10,lot:100,tPlusOne:false}]},'research-test');}
function data(at=T+10000){return {asOf:at,scope:'registered-etf-stock',instruments:[{symbol:'510300',asset:'etf',source:'synthetic',quote:{at,price:10000},
  bars:Array.from({length:65},(_,i)=>({at:T-(65-i)*DAY,availableAt:T-(65-i)*DAY+1,close:8000+i*30})),
  fundamentals:{publishedAt:T-1,dividendYield:.06,valuationPercentile:.1,dividendStability:.9,cashFlowQuality:.9,payoutRatio:.5,freeCashFlow:100},evidenceIDs:['fixture:quote','fixture:fundamental']}]};}
function book(at=T+20000){return {id:'test-book',symbol:'510300',at,session:'2026-10-19',isTrading:true,model:'fiveLevel',source:'synthetic',quantityUnit:'shares',
  bids:Array.from({length:5},(_,i)=>({price:9800-i*10,quantity:1000})),asks:Array.from({length:5},(_,i)=>({price:9900+i*10,quantity:1000}))};}
test('E/F/G implement transparent rule strategies from point-in-time evidence',()=>{
 for(const code of ['E','F','G']){const r=R.research(state(),code,data(),T+10000);assert.ok(r.decisions.length>0,code);assert.equal(r.automatesRealTrades,false);assert.match(r.decisions[0].model,/local-/);}
});
test('no fundamentals does not fabricate a dividend-value decision',()=>{
 const d=data();delete d.instruments[0].fundamentals;const r=R.research(state(),'E',d,T+10000);assert.equal(r.decisions.length,0);assert.match(r.warnings.join(''),/证据不足/);
});
test('future published fundamentals and bars cannot enter scores',()=>{
 const d=data();d.instruments[0].fundamentals.publishedAt=T+99999;d.instruments[0].bars.forEach(b=>b.availableAt=T+99999);
 const rows=R.evidence(d,T+10000);assert.equal(rows[0].f,null);assert.equal(rows[0].bars.length,0);
 assert.equal(R.research(state(),'G',d,T+10000).decisions.length,0);
});
test('stale or halted quotes do not generate orders',()=>{
 const d=data();d.instruments[0].quote.at=T-1000000;assert.equal(R.research(state(),'G',d,T+10000).decisions.length,0);
 d.instruments[0].quote.at=T+10000;d.instruments[0].halted=true;assert.equal(R.research(state(),'G',d,T+10000).decisions.length,0);
});
test('A never sells originals and C waits for target confirmation',()=>{
 assert.equal(R.research(state(),'A',data(),T+10000).decisions.length,0);
 assert.match(R.research(state(),'C',data(),T+10000).warnings[0],/确认/);
});
test('risk firewall caps concentration and keeps reserve cash',()=>{
 const s=state(),r=R.research(s,'G',data(),T+10000,{maxWeight:.2,minCash:.2});
 const buying=r.decisions.filter(d=>d.side==='buy').reduce((n,d)=>n+d.quantity*d.referencePrice,0);
 assert.ok(buying+1000000<=11000000*.2);assert.ok(buying<10000000*.8);
});
test('locked originals cannot be sold by trend strategy',()=>{
 let s=C.dispatch(state(),{type:'salePolicy',account:'F',value:'aiOnly'}),d=data();d.instruments[0].bars.forEach((b,i)=>b.close=12000-i*30);
 assert.equal(R.research(s,'F',d,T+10000).decisions.filter(d=>d.side==='sell').length,0);
});
test('patience plans split lots, target lower prices, and specify expiry',()=>{
 const d=R.research(state(),'G',data(),T+10000).decisions[0];const plans=R.patientPlan(state(),'G',d,T+10000);
 assert.equal(plans.reduce((n,p)=>n+p.quantity,0),d.quantity);assert.ok(plans.every(p=>p.limit<d.referencePrice&&p.expiresAt>p.at));
});
test('zero cash still produces research and future funding discussion',()=>{
 const reply=R.advisor(state(0),data(),T+10000,'没有现金还可以研究吗',{monthly:30000000,months:12});
 assert.equal(reply.availableResearch,true);assert.equal(reply.futureContributions,360000000);assert.match(reply.text,/现金为零/);assert.equal(reply.isLanguageModel,false);
});
test('radar reports actual coverage, not a fake full market',()=>{
 assert.equal(R.radar(data(),T+10000).coverage.isFullMarket,false);assert.equal(R.radar(data(),T+10000).ranked.length,1);
});
test('dividend trap reduces value and blocks fresh allocation',()=>{
 const d=data();d.instruments[0].fundamentals.freeCashFlow=-1;
 const row=R.evidence(d,T+10000)[0];assert.equal(row.trap,true);assert.ok(R.dividendValue(row)<.5);
 assert.equal(R.research(state(),'E',d,T+10000).decisions.filter(d=>d.side==='buy').length,0);
});
test('stress test uses disclosed look-through coverage and cash is not shocked',()=>{
 const r=R.stress(state(),'A',{'510300':10000},{bank:-.2},{'510300':{bank:.5}});
 assert.equal(r.change,-100000);assert.equal(r.lines[0].coverage,.5);
 assert.throws(()=>R.stress(state(),'A',{},{}),/缺行情/);
});
test('only announced future dividends enter forecast',()=>{
 const r=R.dividendForecast(state(),'A',[{id:'d1',symbol:'510300',publishedAt:T-1,paymentAt:T+DAY,netPerShare:100},{id:'future',symbol:'510300',publishedAt:T+99999,paymentAt:T+DAY,netPerShare:1000}],T+10000);
 assert.equal(r.rows.length,1);assert.equal(r.rows[0].expectedNet,10000);
});
test('dividend entitlement uses record-day holdings and is not external capital',()=>{
 let s=state();s=C.dispatch(s,{type:'recordDividend',id:'div1',symbol:'510300',at:T+1000,publishedAt:T-1,netPerShare:100,paymentAt:T+DAY});
 s=C.dispatch(s,{type:'dividend',id:'div1',at:T+DAY});assert.equal(s.accounts.A.cash,10010000);assert.equal(s.accounts.A.flows.length,0);
 assert.throws(()=>C.dispatch(s,{type:'dividend',id:'div1',at:T+DAY+1}),/重复/);
 for(const account of Object.keys(s.accounts))s=C.dispatch(s,{type:'mark',account,at:T+DAY+1,prices:{'510300':10000}});
 assert.equal(C.metrics(s,'A').profit,10000);
});
test('scorecard stays pending until observable outcome; execution benchmark is decision price',()=>{
 const d=R.research(state(),'G',data(),T+10000).decisions[0];
 assert.equal(R.scorecard([d],[],T+20000)[0].status,'pending');
 assert.equal(R.executionQuality(d,{at:T+20000,price:10100}).implementationShortfallBps.toFixed(3),'100.000');
});
test('parameter evolution selects train only and refuses overlapping validation',()=>{
 const train=Array.from({length:20},(_,i)=>({at:T+i,signal:.7,nextReturn:.01})),valid=Array.from({length:10},(_,i)=>({at:T+100+i,signal:.9,nextReturn:-.1}));
 const r=R.evolve([{threshold:.5,riskBuffer:0},{threshold:.8,riskBuffer:0}],train,valid);
 assert.equal(r.candidate.threshold,.5);assert.equal(r.autoPromoted,false);assert.ok(r.outOfSampleScore<0);
 assert.throws(()=>R.evolve([r.candidate],train,train),/重叠/);
});
test('research bridge executes in a JS-only context',()=>{
 const context=vm.createContext({});for(const name of ['LabCore','LabResearch'])vm.runInContext(fs.readFileSync(require.resolve('../guanpan-pro-native/Sources/Lab/'+name+'.js'),'utf8'),context);
 const r=JSON.parse(context.labResearchCall(JSON.stringify({method:'radar',args:[data(),T+10000]})));assert.equal(r.ok,true);
});
test('NAS executor processes fresh virtual book and restart never reuses depth',()=>{
 let s=C.dispatch(state(),{type:'order',account:'G',id:'manual',symbol:'510300',side:'buy',quantity:100,limit:10000,at:T+1000,expiresAt:T+DAY,session:'2026-10-19'});
 const m={data:{books:[book()],quotes:[]}};const first=W.cycle({data:{lab:s},revision:0},m,T+20000);
 assert.equal(first.data.lab.accounts.G.fills.length,1);
 const restarted=W.cycle({data:first.data,revision:1},m,T+21000);assert.equal(restarted.data.lab.accounts.G.fills.length,1);assert.equal(restarted.changed,false);
});
test('idle NAS polling does not increment lab time or create dirty snapshots',()=>{
 const s=state(),r=W.cycle({data:{lab:s}},{data:{}},T+20000);assert.equal(r.changed,false);assert.deepEqual(r.data.lab,s);
});
test('NAS executor does not fill stale book after downtime',()=>{
 const s=C.dispatch(state(),{type:'order',account:'G',id:'manual',symbol:'510300',side:'buy',quantity:100,limit:10000,at:T+1000,expiresAt:T+DAY,session:'2026-10-19'});
 const r=W.cycle({data:{lab:s}},{data:{books:[book()]}},T+200000);assert.equal(r.data.lab.accounts.G.fills.length,0);
});
test('NAS rejects clock reversal without modifying caller data',()=>{
 const s=state();assert.throws(()=>W.cycle({data:{lab:s}},{data:{}},T-1),/clock/);assert.equal(s.accounts.A.cash,10000000);
});
test('uniform replay honors flows, valuation dates and no touched-low fills',()=>{
 const s=state();const result=R.replay(s,[{type:'flow',id:'deposit',at:T+1000,amount:1001000},{type:'mark',at:T+1000,prices:{'510300':10000}},
 {type:'research',at:T+10000,data:data()},{type:'book',at:T+20000,book:book()},{type:'mark',at:T+DAY,prices:{'510300':10000}}]);
 assert.equal(result.state.accounts.A.fills.length,0);assert.ok(result.state.accounts.G.fills.length>0);assert.equal(result.comparison.A.netContributions,1001000);
 assert.throws(()=>R.replay(s,[{type:'mark',at:T+20000,prices:{'510300':10000}},{type:'mark',at:T+1000,prices:{'510300':10000}}]),/倒退/);
});
test('hierarchical alerts dedupe within cooldown and explicitly retain severity',()=>{
 const d=data();d.instruments[0].quote.at=T-999999;const first=R.alerts(state(),d,T+10000);
 assert.ok(first.alerts.some(a=>a.level==='warning'));assert.equal(R.alerts(state(),d,T+20000,first.seen).alerts.length,0);
});
test('calendar includes only known future events with real source attribution',()=>{
 const events=[{id:'known',at:T+DAY,publishedAt:T-1,source:'fixture'},{id:'unknown',at:T+DAY,publishedAt:T+20000,source:'fixture'}];
 assert.deepEqual(R.calendar(events,T+10000).map(e=>e.id),['known']);
});
test('time machine truncates future events and preserves caller snapshot',()=>{
 const s=state(),events=[{type:'mark',at:T+DAY,prices:{'510300':10000}},{type:'mark',at:T+2*DAY,prices:{'510300':20000}}];
 const r=R.timeMachine(s,events,[T+DAY]);assert.equal(r[0].state.accounts.A.marks.length,1);assert.equal(s.accounts.A.marks.length,0);
});
test('observed real-vs-sim comparison demands the same start, dates and cash flows',()=>{
 let s=state();for(const account of Object.keys(s.accounts))s=C.dispatch(s,{type:'mark',account,at:T+DAY,prices:{'510300':10000}});
 const report=R.observedComparison(s,structuredClone(s.seed),[{at:T+DAY,equity:s.initialValue}],[]);
 assert.equal(report.actual.profit,0);assert.equal(report.realLedgerMutated,false);
 assert.throws(()=>R.observedComparison(s,{...s.seed,cash:1},[{at:T+DAY,equity:1}],[]),/初始/);
 assert.throws(()=>R.observedComparison(s,s.seed,[{at:T+2*DAY,equity:s.initialValue}],[]),/日期/);
});
test('historical risk estimate requires common dates and reports sample coverage',()=>{
 const r=R.riskHistory(state(),'A',data(),T+10000);assert.equal(r.status,'ok');assert.equal(r.sampleSize,64);assert.ok(r.historicalVaR95>=0);
});
test('registering a new target instrument never changes original snapshot or wealth',()=>{
 const original=state();let s=C.dispatch(original,{type:'instrument',at:T+100,definition:{symbol:'159919',asset:'etf',quantity:0,cost:0,price:1,tick:10,lot:100,tPlusOne:true}});
 assert.deepEqual(s.seed,original.seed);assert.equal(s.initialValue,original.initialValue);assert.equal(s.accounts.G.positions[1].originalQuantity,0);
 s=C.dispatch(s,{type:'targets',confirmed:true,at:T+1000,weights:{'510300':4000,'159919':5000,cash:1000}});assert.equal(s.targets.weights.cash,1000);
 assert.throws(()=>C.dispatch(original,{type:'instrument',at:T+100,definition:{symbol:'159919',asset:'etf',quantity:100,cost:0,price:1,tick:10,lot:100,tPlusOne:true}}),/不能注入/);
});
test('autonomous empty-evidence review is recorded once per configured interval',()=>{
 const s=C.dispatch(state(),{type:'autonomy',enabled:true,intervalMs:60000});
 const m={data:{quality:{researchSnapshot:{asOf:T+10000,instruments:[]}}}};
 const first=W.cycle({data:{lab:s}},m,T+10000);assert.equal(first.changed,true);assert.equal(first.data.reviews.length,7);
 assert.equal(W.cycle({data:first.data},m,T+11000).changed,false);
});
test('AI-only sell permission excludes manually acquired virtual lots',()=>{
 let s=C.dispatch(state(),{type:'order',account:'G',id:'manual-lot',symbol:'510300',side:'buy',quantity:100,limit:10000,at:T+1000,expiresAt:T+DAY,session:'2026-10-19'});
 s=C.dispatch(s,{type:'book',account:'G',at:T+20000,book:book()});s=C.dispatch(s,{type:'salePolicy',account:'G',value:'aiOnly'});
 assert.throws(()=>C.dispatch(s,{type:'order',account:'G',id:'sell-manual',symbol:'510300',side:'sell',quantity:100,limit:9800,at:T+30000,expiresAt:T+DAY,session:'2026-10-19'}),/保护/);
});
