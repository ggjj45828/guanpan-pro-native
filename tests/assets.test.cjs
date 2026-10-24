const test=require('node:test'),assert=require('node:assert/strict');
const A=require('../guanpan-pro-native/Sources/Lab/AssetChannel.js');
function native(){return {cash:100.01,holdings:[{code:'510300',kind:'etf',name:'fixture',cost:1,quantity:100,current:1.2,marketUpdatedAt:123},{code:'000001',kind:'fund',cost:2,quantity:50,current:2.1}],
 ledger:[{id:'exchange',kind:'etf',date:2,code:'510300',quantity:100,price:1,fee:.1,side:'buy'},{id:'archived',kind:'fund',date:1,code:'000001',quantity:50,price:2,fee:1,side:'buy'}],cashFlows:[],
 fundTransactions:[{id:'old',amount:101}],fundNAVHistory:[{date:'2026-10-12',nav:2}],fundDCAPlans:[{enabled:true}],quotes:[{price:1.2}],appearance:'dark',unknownLegacy:{preserve:true},aiAnalysisConfig:{model:'existing'}};}
test('asset projection excludes market, virtual and archived fund fields',()=>{
 const d=A.project(native(),123);assert.equal(d.cash,1000100);assert.equal(d.holdings.length,1);assert.equal(d.ledger.length,1);
 assert.equal('current'in d.holdings[0],false);assert.equal('marketUpdatedAt'in d.holdings[0],false);
 for(const k of ['quotes','fundTransactions','unknownLegacy','lab','aiAnalysisConfig'])assert.equal(k in d,false);
});
test('manual merge changes only real asset fields, preserves all archived data and market prices',()=>{
 const local=native(),before=structuredClone(local),remote=A.project(local,123);remote.cash=5000000;remote.holdings[0].cost=-.5;remote.holdings[0].quantity=200;
 const next=A.merge(local,remote);assert.equal(next.cash,500);assert.equal(next.holdings.find(h=>h.kind==='etf').cost,-.5);
 assert.equal(next.holdings.find(h=>h.kind==='etf').current,1.2);
 assert.deepEqual(next.holdings.find(h=>h.kind==='fund'),before.holdings.find(h=>h.kind==='fund'));
 for(const key of ['fundTransactions','fundNAVHistory','fundDCAPlans','quotes','unknownLegacy','aiAnalysisConfig'])assert.deepEqual(next[key],before[key]);
 assert.deepEqual(local,before);
});
test('wrong encoding, corrupt money, fund injection and market overwrite are refused',()=>{
 let d=A.project(native(),123);d.costs.encoding='wrong';assert.throws(()=>A.merge(native(),d));
 d=A.project(native(),123);d.cash=NaN;assert.throws(()=>A.validate(d));
 d=A.project(native(),123);d.holdings[0].kind='fund';assert.throws(()=>A.validate(d));
 d=A.project(native(),123);d.holdings[0].current=100;assert.throws(()=>A.validate(d));
});
test('real and archived ledger UUID collision cannot delete or replace history',()=>{
 const d=A.project(native(),123);d.ledger[0].id='archived';assert.throws(()=>A.merge(native(),d),/历史冲突/);
});
test('empty new portfolio does not clear historical data when explicitly merged',()=>{
 const d=A.project({cash:0,holdings:[],ledger:[],cashFlows:[]},123);const next=A.merge(native(),d);
 assert.equal(next.holdings.length,1);assert.equal(next.holdings[0].kind,'fund');assert.equal(next.ledger[0].id,'archived');assert.deepEqual(next.fundTransactions,native().fundTransactions);
});
