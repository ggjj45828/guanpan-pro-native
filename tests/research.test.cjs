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
test('NAS scanner never runs scheduled funding, even when legacy simulation state has it enabled',()=>{
 let s=C.dispatch(state(),{type:'plan',month:'2026-10',amount:10000,paused:false,executeAt:T+10000});
 assert.equal(W.cycle({data:{lab:s}},{data:{}},T+20000).changed,false);
 s=C.dispatch(s,{type:'fundingSchedule',enabled:true});
 const m={data:{quality:{researchSnapshot:data()}}};
 const first=W.cycle({data:{lab:s}},m,T+20000);assert.deepEqual(first.data.lab,s);
 assert.ok(Object.values(first.data.lab.accounts).every(a=>a.flows.length===0));
});
test('NAS scanner never writes virtual dividend or fill records',()=>{
 let s=C.dispatch(state(),{type:'order',account:'G',id:'buy',symbol:'510300',side:'buy',quantity:100,limit:10000,at:T+1000,expiresAt:T+DAY,session:'2026-10-19'});
 s=C.dispatch(s,{type:'book',account:'G',book:book(),at:T+20000});
 const event={id:'dividend:test',symbol:'510300',recordAt:T+5000,paymentAt:T+25000,publishedAt:T-1,netPerShare:10};
 const before=JSON.stringify(s),m={data:{quality:{researchSnapshot:{...data(),dividendEvents:[event]}}}},result=W.cycle({data:{lab:s}},m,T+30000);
 assert.equal(JSON.stringify(result.data.lab),before);
 assert.equal(result.data.lab.dividendRecords,undefined);
 assert.equal(result.data.lab.accounts.G.fills.length,1);
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
test('intraday statistics report window coverage and refuse precise plans without long history or VWAP',()=>{
 const d=data(),bars=[];
 for(let day=0;day<65;day++)for(let point=0;point<12;point++)bars.push({
  at:T-(65-day)*DAY+point*60000,availableAt:T+10000,day:`D${String(day).padStart(3,'0')}`,
  price:10000+day*2+(point%4)*10,volume:1000});
 d.instruments[0].intradayBars=bars;
 const full=R.intradayStats(d,T+10000).rows[0];assert.equal(full.sessions,65);assert.equal(full.samplePoints,780);
 assert.equal(full.windows['5'].available,true);assert.equal(full.windows['20'].available,true);
 assert.equal(full.windows['60'].available,true);assert.equal(full.windows['120'].available,false);
 assert.equal(full.eligibleForPricePlan,false);assert.equal(full.latestSessionVWAP>0,true);
 assert.ok(full.blockers.some(x=>x.includes('分钟点覆盖')));
 const short={...d,instruments:[{...d.instruments[0],intradayBars:bars.slice(-120)}]};
 const blocked=R.intradayStats(short,T+10000).rows[0];assert.equal(blocked.eligibleForPricePlan,false);assert.ok(blocked.blockers.some(x=>x.includes('少于60')));
 const noVolume={...d,instruments:[{...d.instruments[0],intradayBars:bars.map(({volume,...b})=>b)}]};
 const missing=R.intradayStats(noVolume,T+10000).rows[0];assert.equal(missing.eligibleForPricePlan,false);assert.ok(missing.blockers.some(x=>x.includes('VWAP')));
});
test('NAS coverage can satisfy history gate but stale NAS research remains blocked',()=>{
 const d=data(),at=T+10000;
 d.instruments[0].intradayResearch={status:'ready-for-statistical-review',sessions:65,samplePoints:16000,completeMinuteDays:65,
  volumeCoverage:.95,latestSessionVWAP:10000,lastAt:at-DAY,source:'NAS archived observed minute records',
  windows:{'60':{available:true,sessions:60,meanRangePct:.02}}};
 const fresh=R.intradayStats(d,at).rows[0];
 assert.equal(fresh.sessions,65);assert.equal(fresh.completeMinuteDays,65);
 assert.equal(fresh.blockers.some(x=>x.includes('少于60')),false);
 assert.equal(fresh.blockers.some(x=>x.includes('超过3天')),false);
 d.instruments[0].intradayResearch.lastAt=at-9*DAY;
 const stale=R.intradayStats(d,at).rows[0];
 assert.ok(stale.blockers.some(x=>x.includes('超过3天')));
 assert.equal(stale.eligibleForPricePlan,false);
});
test('real holding T candidate uses verified rules, ordered minute touches, book depth and 0.10 fee',()=>{
 const at=T+10000,d=data(at),paths=[];
 for(let day=0;day<60;day++){
  const start=at-(60-day)*DAY;
  paths.push({day:String(day),vwap:10000,
   points:Array.from({length:200},(_,i)=>[start+i*60000,[9960,10000,10040,10000][i%4]])});
 }
 d.instruments[0].quote={at,price:10000};
 d.instruments[0].intradayResearch={
  source:'NAS archived observed minute records',status:'ready-for-statistical-review',
  sessions:60,completeMinuteDays:60,samplePoints:12000,volumeCoverage:.95,
  lastAt:at-DAY,latestSessionVWAP:10000,minuteEvidence:paths,
  dailyEvidence:Array.from({length:60},(_,i)=>({day:String(i),open:10000,close:10000,high:10040,low:9960})),
  windows:{'20':{available:true,sessions:20,meanRangePct:.008,
    vwapHighDeviationMedian:.004,vwapLowDeviationMedian:-.004}}};
 d.books=[{symbol:'510300',at,quantityUnit:'shares',isTrading:true,
  bids:[{price:9990,quantity:10000}],asks:[{price:10000,quantity:10000}]}];
 d.realPortfolio={cash:200000,equity:220000,holdings:[{symbol:'510300',name:'真实ETF',quantity:2000,cost:1,marketValue:2000}],
  verifiedTradingRules:[{symbol:'510300',settlement:'nextDay',lotSize:100,tickUnits:10,
   feePerFillYuan:.1,confirmedAt:at,confirmationSource:'券商核对',brokerSellableShares:1500,sellableCheckedAt:at}]};
 const originalAccount=JSON.stringify(d.realPortfolio);
 const decision=R.decisionContext(d,at).decisions[0],plan=decision.plan;
 assert.equal(JSON.stringify(d.realPortfolio),originalAccount,'AI候选计划不得修改真实账户');
 assert.equal(decision.action,'反T候选');assert.ok(plan);
 assert.equal(plan.quantity%100,0);assert.ok(plan.sellLimitYuan>plan.buyLimitYuan);
 assert.equal(plan.feesYuan,.2);
 assert.ok(Math.abs(plan.netYuan-(plan.grossYuan-.2))<1e-10);
 assert.ok(Math.abs(plan.equivalentCostReductionYuanPerShare-plan.netYuan/2000)<1e-10);
 assert.equal(plan.historicalTouches.orderedRoundTrips,60);
 assert.equal(plan.automatesTrades,false);
 d.realPortfolio.holdings[0].cost=1.2;
 d.realPortfolio.holdings[0].maxPositionPercent=35;
 const recovery=R.decisionContext(d,at).decisions[0].recovery;
 assert.equal(recovery.status,'in-loss');
 assert.ok(recovery.breakEvenRisePct>.2&&recovery.breakEvenRisePct<.201);
 assert.ok(recovery.threeCompletedCycles.equivalentCostYuanPerShare<1.2);
 assert.ok(recovery.cautiousAdd.requiredCashYuan<=d.realPortfolio.cash);
 assert.ok(recovery.trimQuarter.remainingShares<2000);
 const positive=structuredClone(d);
 positive.instruments[0].intradayResearch.minuteEvidence.forEach(day=>{
  day.points.forEach((point,i)=>{point[1]=i===0?9960:i===2?10040:10000;});
 });
 const positiveDecision=R.decisionContext(positive,at).decisions[0];
 assert.equal(positiveDecision.plan.type,'positiveT');
 assert.equal(positiveDecision.action,'正T候选');
 assert.equal(positiveDecision.plan.quantity%100,0);
 const noRule=structuredClone(d);noRule.realPortfolio.verifiedTradingRules=[];
 assert.equal(R.decisionContext(noRule,at).decisions[0].plan,null);
 const unordered=structuredClone(d);unordered.instruments[0].intradayResearch.minuteEvidence[0].points[1][0]=
  unordered.instruments[0].intradayResearch.minuteEvidence[0].points[0][0];
 assert.equal(R.decisionContext(unordered,at).decisions[0].plan,null);
 const oldRule=structuredClone(d);oldRule.realPortfolio.verifiedTradingRules[0].confirmedAt=at-31*DAY;
 assert.equal(R.decisionContext(oldRule,at).decisions[0].plan,null);
 const oldBook=structuredClone(d);oldBook.books[0].at=at-31000;
 assert.equal(R.decisionContext(oldBook,at).decisions[0].plan,null);
 const oldResearch=structuredClone(d);oldResearch.instruments[0].intradayResearch.lastAt=at-4*DAY;
 assert.equal(R.decisionContext(oldResearch,at).decisions[0].plan,null);
 assert.match(R.decisionContext(oldResearch,at).decisions[0].intraday.blockers.join('、'),/超过3天/);
 const partialWindow=structuredClone(d);partialWindow.instruments[0].intradayResearch.windows['20'].sessions=19;
 assert.equal(R.decisionContext(partialWindow,at).decisions[0].plan,null);
 const noSellable=structuredClone(d);delete noSellable.realPortfolio.verifiedTradingRules[0].brokerSellableShares;
 assert.equal(R.decisionContext(noSellable,at).decisions[0].plan,null);
 const wide=structuredClone(d);
 wide.instruments[0].intradayResearch.dailyEvidence.forEach(day=>{day.high=10080;day.low=9920;});
 wide.instruments[0].intradayResearch.windows['20']={available:true,sessions:20,meanRangePct:.016,
  vwapHighDeviationMedian:.008,vwapLowDeviationMedian:-.008};
 wide.instruments[0].intradayResearch.minuteEvidence.forEach((day,index)=>{
  day.points.forEach((point,i)=>{point[1]=index<24?[9920,10000,10080,9920][i%4]:10000;});
 });
 const grid=R.decisionContext(wide,at).decisions[0];
 assert.equal(grid.action,'网格候选');
 assert.equal(grid.plan.type,'grid');
 assert.ok(grid.plan.levels>=2&&grid.plan.levels<=8);
 assert.equal(grid.plan.levels,grid.plan.bands.length);
 assert.ok(grid.plan.bands.every(b=>b.expectedNetYuan>0&&b.quantity%100===0));
 assert.ok(grid.plan.bands.every(b=>b.buyFeeYuan===.1));
 assert.ok(Math.abs(grid.plan.maxBuyCapitalYuan-grid.plan.bands.reduce((sum,b)=>sum+b.buyCapitalYuan,0))<1e-8);
 assert.ok(grid.plan.bands.every(b=>b.buyLimitYuan<.999&&b.sellLimitYuan>1));
 assert.ok(grid.plan.maxBuyCapitalYuan<=wide.realPortfolio.cash);
 assert.ok(grid.plan.remainingSharesAfterAllSells>=0);
 const overLimit=structuredClone(wide);
 overLimit.realPortfolio.holdings[0].marketValue=150000;
 overLimit.realPortfolio.holdings[0].maxPositionPercent=35;
 overLimit.realPortfolio.equity=220000;
 const protectedPlan=R.decisionContext(overLimit,at).decisions[0].plan;
 assert.ok(protectedPlan && protectedPlan.type==='reverseT');
 const nearLimit=structuredClone(wide);
 nearLimit.realPortfolio.holdings[0].marketValue=76900;
 nearLimit.realPortfolio.holdings[0].maxPositionPercent=35;
 nearLimit.realPortfolio.equity=220000;
 assert.equal(R.decisionContext(nearLimit,at).decisions[0].plan.type,'reverseT');
 const core=structuredClone(wide);
 core.realPortfolio.holdingRoles=[{symbol:'510300',role:'core'}];
 assert.equal(R.decisionContext(core,at).decisions[0].action,'长期持有');
 assert.equal(R.decisionContext(core,at).decisions[0].plan,null);
 const pausedByUser=structuredClone(wide);
 pausedByUser.profileState={temporaryPauses:['510300']};
 assert.equal(R.decisionContext(pausedByUser,at).decisions[0].plan,null);
 assert.match(R.decisionContext(pausedByUser,at).decisions[0].reason,/暂不交易/);
 const event=structuredClone(wide);
 event.news=[{symbol:'510300',at:at-60000,availableAt:at-30000,importance:'major',
  eventScope:'security',headline:'已核实的基金公告',publisher:'基金公司',sourceURL:'https://example.org/notice'}];
 const paused=R.decisionContext(event,at).decisions[0];
 assert.equal(paused.plan,null);assert.equal(paused.action,'不交易');
 assert.match(paused.reason,/重大事件/);assert.equal(paused.relatedNews.length,1);
 event.news[0].availableAt=at+1;
 assert.equal(R.decisionContext(event,at).decisions[0].action,'网格候选');
 const industry=structuredClone(wide);
 industry.news=[{symbol:'MARKET',at:at-60000,availableAt:at-30000,importance:'major',
  eventScope:'industry',affectedSymbols:['510300'],headline:'行业事件',publisher:'交易所',
  sourceURL:'https://example.org/industry'}];
 assert.equal(R.decisionContext(industry,at).decisions[0].plan,null);
 industry.news[0].affectedSymbols=['159919'];
 assert.equal(R.decisionContext(industry,at).decisions[0].action,'网格候选');
 const trend=structuredClone(wide);trend.instruments[0].intradayResearch.dailyEvidence.forEach((day,i)=>{
  day.open=10000+i*40;day.close=day.open+10;day.high=day.open+80;day.low=day.open-80;
 });
 assert.equal(R.decisionContext(trend,at).decisions[0].plan,null);
});
test('unified decision context only includes real holdings and never fabricates a limit plan',()=>{
 const d=data(),bars=[];
 for(let day=0;day<65;day++)for(let point=0;point<12;point++)bars.push({at:T-(65-day)*DAY+point*60000,availableAt:T+10000,day:`D${String(day).padStart(3,'0')}`,price:10000+day*100+point,volume:1000});
 d.instruments[0].intradayBars=bars;d.realPortfolio={asOf:T+10000,cash:200000,equity:1200000,holdings:[{symbol:'510300',name:'沪深300ETF',quantity:1000,cost:4.2,marketValue:10000}]};
 const c=R.decisionContext(d,T+10000);assert.equal(c.version,'real-holdings-decision-context-v1');
 assert.equal(c.holdingsCount,1);assert.equal(c.decisions.length,1);assert.equal(c.decisions[0].symbol,'510300');
 assert.equal(c.decisions[0].action,'长期持有');assert.equal(c.decisions[0].plan,null);assert.equal(c.automatesTrades,false);
 const stale=structuredClone(d);stale.instruments[0].quote.at=T-900000;
 assert.equal(R.decisionContext(stale,T+10000).decisions[0].action,'不交易');
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
test('NAS opportunity scanner records research only and never mutates portfolio or virtual orders',()=>{
 const s=state(),before=JSON.stringify(s),snapshot=data();snapshot.instruments[0].intradayResearch={status:'ready-for-statistical-review',sessions:60,samplePoints:1200};
 const m={data:{quality:{researchSnapshot:snapshot}}};
 const first=W.cycle({data:{lab:s} },m,T+20000);
 assert.equal(first.status,'screened');assert.equal(JSON.stringify(first.data.lab),before);
 assert.equal(first.data.opportunityScan.action,'screen-only');assert.equal(first.data.opportunityScan.automatesRealTrades,false);
 assert.ok(first.data.opportunityScan.opportunities.length>0);
 assert.equal(first.data.opportunityScan.opportunities[0].limit,undefined);
 const again=W.cycle({data:first.data},m,T+21000);assert.equal(again.changed,false);
});
test('NAS HTTP client writes only the research scan while preserving legacy quant data',async()=>{
 const legacyLab=state(),preferences={keep:true};let written=null;
 const snapshot=data();snapshot.instruments[0].intradayResearch={status:'ready-for-statistical-review',sessions:60,samplePoints:1200};
 const fetcher=async(url,options)=>{
  const route=url.split('/').at(-1);
  let result;
  if(route==='lease')result={ok:true,fence:3};
  else if(route==='release')result={ok:true};
  else if(route==='market')result={ok:true,data:{quality:{researchSnapshot:snapshot}}};
  else if(route==='quant'&&options.method==='GET')result={ok:true,revision:4,data:{lab:legacyLab,preferences}};
  else if(route==='quant'){
   written=JSON.parse(options.body);result={ok:true,revision:5};
  }else throw Error('unexpected route '+route);
  return {ok:true,json:async()=>result};
 };
 const scanned=await W.tick({base:'https://fixture.invalid',token:'test',owner:'worker-test',fetcher,now:()=>T+20000});
 assert.equal(scanned.status,'screened');assert.equal(written.expectedRevision,4);
 assert.equal(written.executionLease.owner,'worker-test');
 assert.equal(JSON.stringify(written.data.lab),JSON.stringify(legacyLab));
 assert.deepEqual(written.data.preferences,preferences);
 assert.equal(written.data.opportunityScan.action,'screen-only');
 assert.equal(written.data.opportunityScan.automatesRealTrades,false);
});
test('NAS scanner pauses when quote or research snapshot is stale/missing',()=>{
 const d=data();d.instruments[0].quote.at=T-999999;
 const r=W.cycle({data:{lab:state()}},{data:{quality:{researchSnapshot:d}}},T+20000);
 assert.equal(r.data.opportunityScan.opportunities.length,0);
 const none=W.cycle({data:{}},{data:{}},T+20000);assert.equal(none.status,'paused-data-unavailable');assert.equal(none.changed,false);
});
test('NAS scanner does not produce a second recommendation during its interval',()=>{
 const snapshot=data();snapshot.instruments[0].intradayResearch={status:'ready-for-statistical-review',sessions:60,samplePoints:1200};
 const m={data:{quality:{researchSnapshot:snapshot}}},first=W.cycle({data:{}},m,T+20000);
 const next=W.cycle({data:first.data},m,T+21000);assert.equal(next.changed,false);assert.equal(next.status,'waiting-interval');
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
test('NAS scanner rejects future-dated snapshots without changing quant data',()=>{
 const snapshot=data();snapshot.asOf=T+50000;const before={lab:state()};
 const first=W.cycle({data:before},{data:{quality:{researchSnapshot:snapshot}}},T+20000);
 assert.equal(first.changed,false);assert.equal(first.status,'paused-data-unavailable');assert.deepEqual(first.data,before);
});
test('AI-only sell permission excludes manually acquired virtual lots',()=>{
 let s=C.dispatch(state(),{type:'order',account:'G',id:'manual-lot',symbol:'510300',side:'buy',quantity:100,limit:10000,at:T+1000,expiresAt:T+DAY,session:'2026-10-19'});
 s=C.dispatch(s,{type:'book',account:'G',at:T+20000,book:book()});s=C.dispatch(s,{type:'salePolicy',account:'G',value:'aiOnly'});
 assert.throws(()=>C.dispatch(s,{type:'order',account:'G',id:'sell-manual',symbol:'510300',side:'sell',quantity:100,limit:9800,at:T+30000,expiresAt:T+DAY,session:'2026-10-19'}),/保护/);
});
