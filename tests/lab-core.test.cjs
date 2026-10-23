const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const corePath = path.join(__dirname, '../guanpan-pro-native/Sources/Lab/LabCore.js');
const c = require(corePath);
const T = Date.parse('2026-10-19T02:00:00Z'), D = 86400000;
function seed(cash = 100000000) {
  return { at:T, cash, positions:[{symbol:'510300',asset:'etf',quantity:1000,cost:9000,price:10000,tick:10,lot:100,tPlusOne:false}] };
}
const create = cash => c.create(seed(cash),'run1');
const op = (s, x) => c.dispatch(s,x);
function order(s, overrides = {}) {
  return op(s, Object.assign({type:'order',account:'G',id:'o1',symbol:'510300',side:'buy',quantity:200,limit:10000,at:T+1000,expiresAt:T+10000,session:'2026-10-19'},overrides));
}
function book(at = T+2000, id='b1', qty=100, price=10000) {
  return {id,symbol:'510300',at,session:'2026-10-19',isTrading:true,model:'fiveLevel',source:'fixture',
    bids:Array.from({length:5},(_,i)=>({price:9900-i*10,quantity:1000})),
    asks:Array.from({length:5},(_,i)=>({price:price+i*10,quantity:i===0?qty:0}))};
}
const fill = (s,b=book(),account='G') => op(s,{type:'book',account,book:b,at:b.at});
test('initial snapshot and all seven accounts are independent values',()=>{
  const snap=seed(); const s=c.create(snap,'run1'); snap.cash=1;
  assert.equal(s.seed.cash,100000000); assert.equal(s.accounts.A.cash,100000000);
  const updated=order(s); assert.equal(s.accounts.G.orders.length,0);assert.equal(updated.accounts.A.orders.length,0);
});
test('JSON bridge runs without Node APIs (same offline iOS asset)',()=>{
  const context=vm.createContext({}); vm.runInContext(fs.readFileSync(corePath,'utf8'),context);
  const result=JSON.parse(context.labCall(JSON.stringify({method:'create',args:[seed(),'run2']})));
  assert.equal(result.ok,true);assert.equal(result.value.accounts.G.cash,100000000);
  assert.equal(JSON.parse(context.labCall('{broken')).ok,false);
});
test('variable deposits and withdrawal applied identically across accounts',()=>{
  let s=op(create(),{type:'flow',id:'f1',at:T+1000,amount:10000});
  s=op(s,{type:'flow',id:'f2',at:T+2000,amount:-5000});
  Object.values(s.accounts).forEach(a=>assert.equal(a.cash,100005000));
  assert.throws(()=>op(s,{type:'flow',id:'f2',at:T+3000,amount:100}),/重复/);
});
test('withdrawal is atomic across scenarios and respects reserved cash',()=>{
  const s=order(create(3001000));const before=JSON.stringify(s);
  assert.throws(()=>op(s,{type:'flow',id:'out',at:T+2000,amount:-2000000}),/现金不足/);
  assert.equal(JSON.stringify(s),before);
});
test('monthly differing plan, pause and exactly once execution',()=>{
  let s=op(create(),{type:'plan',month:'2026-10',amount:20000,paused:true});
  assert.throws(()=>op(s,{type:'executePlan',month:'2026-10',at:T+1000}),/暂停/);
  s=op(s,{type:'plan',month:'2026-10',amount:30000,paused:false});
  s=op(s,{type:'executePlan',month:'2026-10',at:T+1000});
  assert.equal(s.accounts.A.cash,100030000);
  assert.throws(()=>op(s,{type:'executePlan',month:'2026-10',at:T+2000}),/重复/);
});
test('partial fills each charge ETF 0.10; default extra slippage zero',()=>{
  let s=fill(order(create()));const a=s.accounts.G;
  assert.equal(a.orders[0].status,'partial');assert.equal(a.fills[0].gross,1000000);
  assert.equal(a.fills[0].fee,1000);assert.equal(a.orders[0].remaining,100);
  s=fill(s,book(T+3000,'b2'));
  assert.equal(s.accounts.G.orders[0].status,'filled');assert.equal(s.accounts.G.cash,97998000);
  assert.equal(s.accounts.A.cash,100000000);
});
test('repeated liquidity and older snapshots cannot fill again',()=>{
  const s=fill(order(create()));
  assert.throws(()=>fill(s),/重复|倒退/);
  assert.throws(()=>fill(s,book(T+1500,'old')),/倒退/);
});
test('two orders share the same snapshot depth within a strategy',()=>{
  let s=order(create(),{id:'o1',quantity:100});
  s=order(s,{id:'o2',quantity:100});s=fill(s);
  assert.equal(s.accounts.G.fills.length,1);assert.equal(s.accounts.G.orders[1].status,'waiting');
});
test('price priority before time priority for same-side orders',()=>{
  let s=order(create(),{id:'low',quantity:100,limit:10000});
  s=order(s,{id:'high',quantity:100,limit:10010});s=fill(s);
  assert.equal(s.accounts.G.fills[0].orderID,'high');
});
test('no touched-low fill and no fabricated depth',()=>{
  const s=fill(order(create()),book(T+2000,'far',100,10100));
  assert.equal(s.accounts.G.fills.length,0);
  const b=book();b.asks=[];assert.throws(()=>fill(order(create()),b),/五档/);
});
test('simplified model explicitly low confidence',()=>{
  const b=book();b.model='simplified';b.asks=b.asks.slice(0,1);b.bids=b.bids.slice(0,1);
  const s=fill(order(create()),b);assert.equal(s.accounts.G.fills[0].confidence,'low');
});
test('stale, future and crossed snapshots rejected transactionally',()=>{
  const s=order(create()),b=book();
  assert.throws(()=>op(s,{type:'book',account:'G',book:b,at:T+9000}),/过期/);
  assert.throws(()=>op(s,{type:'book',account:'G',book:b,at:T+1000}),/未来/);
  b.bids[0].price=10010;assert.throws(()=>fill(s,b),/交叉/);
  assert.equal(s.accounts.G.fills.length,0);
});
test('expiry/cancellation releases cash and preserves missed quantity',()=>{
  let s=order(create());s=op(s,{type:'expire',account:'G',at:T+10000});
  assert.equal(s.accounts.G.orders[0].status,'expired');assert.equal(s.accounts.G.orders[0].reservedCash,0);
  assert.equal(c.opportunity(s,'G','o1',11000,T+10001).signedOpportunityCost,200000);
  let other=order(create());other=op(other,{type:'cancel',account:'G',id:'o1',at:T+2000});
  assert.equal(other.accounts.G.orders[0].status,'cancelled');
});
test('ETF sell also fixed 0.10 with protected original policy',()=>{
  assert.throws(()=>order(create(),{account:'A',side:'sell'}),/保护/);
  let s=order(create(),{side:'sell',limit:9900,quantity:100});s=fill(s);
  assert.equal(s.accounts.G.fills[0].fee,1000);assert.equal(s.accounts.G.positions[0].originalQuantity,900);
});
test('AI-only permission cannot sell original lots, can sell simulated acquisitions',()=>{
  let s=op(create(),{type:'salePolicy',account:'G',value:'aiOnly'});
  assert.throws(()=>order(s,{side:'sell',limit:9900}),/保护/);
  s=fill(order(s,{quantity:100,origin:'ai'}));
  s=order(s,{id:'sell',at:T+3000,side:'sell',limit:9900,quantity:100});
  s=fill(s,book(T+4000,'sellbook'));
  assert.equal(s.accounts.G.positions[0].originalQuantity,1000);
});
test('T+1 blocks same-day acquired shares; rule must be explicit',()=>{
  const ss=seed();ss.positions[0].tPlusOne=true;
  let s=op(c.create(ss,'run1'),{type:'salePolicy',account:'G',value:'aiOnly'});
  s=fill(order(s,{quantity:100}));
  assert.throws(()=>order(s,{id:'sell',at:T+3000,side:'sell',limit:9900,quantity:100}),/交收/);
});
test('fee versions immutable and pending order keeps original version',()=>{
  let s=order(create());const p={...c.defaultPolicy(),version:'v2',extraSlippageTicks:1};
  s=op(s,{type:'feePolicy',policy:p});s=fill(s);
  assert.equal(s.accounts.G.fills[0].feeVersion,'user-2026-10-v1');
  assert.throws(()=>op(s,{type:'feePolicy',policy:p}),/不可覆盖/);
});
test('new slippage cannot violate limit',()=>{
  let s=op(create(),{type:'feePolicy',policy:{...c.defaultPolicy(),version:'v2',extraSlippageTicks:1}});
  s=fill(order(s));assert.equal(s.accounts.G.fills.length,0);
});
test('unknown stock rate uses editable 5 yuan floor and estimated flag',()=>{
  const p=c.defaultPolicy();const f=c.fee(p,'stock','buy',1000000);
  assert.equal(f.amount,50000);assert.equal(f.estimated,true);
  assert.equal(c.fee({...p,stockMinimum:30000},'stock','buy',1000000).amount,30000);
});
test('numeric invalids, duplicate symbols and fee corruption rejected',()=>{
  assert.throws(()=>c.create({...seed(),cash:NaN},'run1'));
  assert.throws(()=>c.create({...seed(),positions:[seed().positions[0],seed().positions[0]]},'run1'));
  assert.throws(()=>c.create(seed(),'run1',{...c.defaultPolicy(),etfFee:0}));
  assert.throws(()=>order(create(),{quantity:101}));
});
test('insufficient cash cannot overdraw even when partial fill has extra fee',()=>{
  let s=order(create(2001000));s=fill(s);
  assert.equal(s.accounts.G.fills.length,0);assert.equal(s.accounts.G.cash,2001000);
});
test('zero cash does not block research proposals or snapshot creation',()=>{
  const s=create(0);assert.equal(c.proposals(s,'G',T,{'510300':10000}).status,'needsEvidenceAndStrategyImplementation');
  assert.equal(c.proposals(s,'B',T,{'510300':10000}).status,'proposalsOnly');
});
test('A cash-only; C requires user confirmed targets; E/F/G do not fake strategies',()=>{
  const s=create();assert.equal(c.proposals(s,'A',T,{}).status,'cashOnly');
  assert.equal(c.proposals(s,'C',T,{}).status,'needsUserConfirmedTargets');
  for(const x of ['E','F','G']) assert.equal(c.proposals(s,x,T,{}).proposals.length,0);
  assert.throws(()=>op(s,{type:'targets',confirmed:false,weights:{'510300':10000}}));
});
test('contribution is not return; TWR/IRR and drawdown use net flows',()=>{
  const ss={at:T,cash:1000000,positions:[]};let s=c.create(ss,'cashRun');
  s=op(s,{type:'flow',id:'add',amount:1000000,at:T+365*D});
  for(const account of Object.keys(s.accounts)) s=op(s,{type:'mark',account,at:T+365*D,prices:{}});
  const m=c.compare(s).A;assert.equal(m.profit,0);assert.equal(m.timeWeightedReturn,0);assert.equal(m.maxDrawdown,0);
  assert.ok(Math.abs(m.moneyWeightedAnnualReturn)<1e-7);
});
test('missing valuation at flow boundary refuses exact TWR',()=>{
  let s=op(create(),{type:'flow',id:'add',amount:10000,at:T+D});
  s=op(s,{type:'mark',account:'A',at:T+2*D,prices:{'510300':10000}});
  assert.equal(c.metrics(s,'A').status,'needsPreFlowValuations');
});
test('known one-year gain and sampled maximum drawdown',()=>{
  const ss=seed(0);let s=c.create(ss,'run1');
  s=op(s,{type:'mark',account:'A',at:T+180*D,prices:{'510300':8000}});
  s=op(s,{type:'mark',account:'A',at:T+365*D,prices:{'510300':11000}});
  const m=c.metrics(s,'A');assert.ok(Math.abs(m.timeWeightedReturn-.1)<1e-10);
  assert.ok(Math.abs(m.maxDrawdown+.2)<1e-10);assert.ok(Math.abs(m.moneyWeightedAnnualReturn-.1)<1e-7);
});
test('comparison refuses unequal valuation dates',()=>{
  const s=op(create(),{type:'mark',account:'A',at:T+D,prices:{'510300':10000}});
  assert.throws(()=>c.compare(s),/日期/);
});
test('XIRR multiple roots are not reported as a unique result',()=>{
  const roots=c.xirr([{at:T,amount:-100},{at:T+365*D,amount:230},{at:T+730*D,amount:-132}]);
  assert.equal(roots.length,2);assert.ok(Math.abs(roots[0]-.1)<1e-7);assert.ok(Math.abs(roots[1]-.2)<1e-7);
});
test('save/reload JSON preserves live orders and independent accounts',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'guanpan-lab-'));
  try {
    const s=order(create());fs.writeFileSync(path.join(dir,'lab.json'),JSON.stringify(s));
    const restored=JSON.parse(fs.readFileSync(path.join(dir,'lab.json')));assert.equal(c.validate(restored),true);
    const next=fill(restored);assert.equal(next.accounts.G.fills.length,1);assert.equal(next.accounts.A.orders.length,0);
  } finally {fs.rmSync(dir,{recursive:true,force:true});}
});
test('channel modes are independent and do not claim a connection',()=>{
  const s=create();assert.equal(s.channels.assets.mode,'manual');
  assert.equal(s.channels.market.mode,'automatic');assert.equal(s.channels.quant.mode,'automatic');
  Object.values(s.channels).forEach(c=>assert.equal(c.status,'notConnected'));
});
test('cash and holdings corruption cannot be accepted after reload',()=>{
  const s=create();s.accounts.G.cash+=1;assert.throws(()=>c.validate(s),/流水不一致/);
  const other=create();other.accounts.G.positions[0].originalQuantity+=1;assert.throws(()=>c.validate(other),/来源损坏|流水不一致/);
});
test('negative diluted cost is preserved rather than silently rewritten',()=>{
  const ss=seed();ss.positions[0].cost=-100;
  const s=c.create(ss,'run1');assert.equal(s.accounts.A.positions[0].cost,-100);
});
test('B proposals do not repeatedly spend the same external contributions',()=>{
  let s=op(create(),{type:'flow',id:'newmoney',at:T+1,amount:1001000});
  assert.equal(c.proposals(s,'B',T+2,{'510300':10000}).proposals[0].quantity,100);
  s=order(s,{account:'B',quantity:100});s=fill(s,book(),'B');
  assert.equal(c.proposals(s,'B',T+3000,{'510300':10000}).proposals.length,0);
});
test('funding after a valuation cannot be backdated into that valuation',()=>{
  let s=op(create(),{type:'mark',account:'A',at:T+1000,prices:{'510300':10000}});
  assert.throws(()=>op(s,{type:'flow',id:'backdated',at:T+1000,amount:10000}),/已有估值/);
});
test('T+1 original holdings are conservatively locked on seed day',()=>{
  const ss=seed();ss.positions[0].tPlusOne=true;
  let s=c.create(ss,'run1');
  assert.throws(()=>order(s,{side:'sell',quantity:100,limit:9900}),/交收/);
  s=order(s,{side:'sell',quantity:100,limit:9900,at:T+D,expiresAt:T+D+10000,session:'2026-10-20'});
  assert.equal(s.accounts.G.orders[0].status,'waiting');
});
test('fake future settlement date cannot bypass T+1',()=>{
  const ss=seed();ss.positions[0].tPlusOne=true;
  assert.throws(()=>order(c.create(ss,'run1'),{side:'sell',quantity:100,limit:9900,session:'2026-10-20'}),/交易日/);
});
