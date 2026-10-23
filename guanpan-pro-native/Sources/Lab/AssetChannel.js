/* Pure real-asset projection/merge. It cannot read storage or submit trades.
 * CNY floats inside legacy Holding/Ledger are retained; only channel cash is 1e4.
 */
(function(root){'use strict';
 const cp=x=>JSON.parse(JSON.stringify(x)),ok=(v,m)=>{if(!v)throw Error(m);};
 const number=x=>typeof x==='number'&&Number.isFinite(x);
 function validate(d){
  ok(d&&d.costs?.encoding==='guanpan-native-asset-v1','真实资产编码不匹配');
  ok(Number.isSafeInteger(d.cash)&&d.cash>=0&&Array.isArray(d.holdings)&&Array.isArray(d.ledger)&&Array.isArray(d.cashFlows),'真实资产字段无效');
  ok(d.holdings.every(h=>h.kind==='etf'&&typeof h.code==='string'&&number(h.quantity)&&h.quantity>=0&&number(h.cost)&&!('current'in h)&&!('marketUpdatedAt'in h)),'持仓格式无效或混入场外/行情');
  ok(new Set(d.holdings.map(h=>h.code)).size===d.holdings.length,'重复真实持仓');
  ok(d.ledger.every(l=>(l.kind===undefined||l.kind==='etf')&&typeof l.id==='string'&&typeof l.code==='string'&&number(l.date)&&number(l.quantity)&&l.quantity>0&&number(l.price)&&l.price>0&&number(l.fee)&&l.fee>=0&&['buy','sell'].includes(l.side)),'真实流水格式无效');
  ok(new Set(d.ledger.map(l=>l.id)).size===d.ledger.length,'重复真实流水');
  return true;
 }
 function project(native,at){
  ok(native&&number(native.cash)&&native.cash>=0&&Number.isSafeInteger(Math.round(native.cash*10000)),'真实现金无效');
  const holdings=(native.holdings||[]).filter(h=>h.kind==='etf').map(h=>{const r=cp(h);delete r.current;delete r.marketUpdatedAt;return r;});
  const d={holdings,cash:Math.round(native.cash*10000),ledger:(native.ledger||[]).filter(l=>l.kind===undefined||l.kind==='etf').map(cp),cashFlows:cp(native.cashFlows||[]),costs:{encoding:'guanpan-native-asset-v1',holdingAndLedgerCurrency:'CNY',cashUnit:'1/10000 CNY'},asOf:at};
  validate(d);return d;
 }
 function merge(native,remote){
  validate(remote);const next=cp(native);
  const history=(native.holdings||[]).filter(h=>h.kind==='fund');
  next.holdings=[...cp(history),...remote.holdings.map(h=>{
   const market=(native.holdings||[]).find(x=>x.code===h.code&&x.kind==='etf');
   const value={...cp(h),current:market?.current||0};if(market?.marketUpdatedAt!==undefined)value.marketUpdatedAt=market.marketUpdatedAt;return value;
  })];
  next.cash=remote.cash/10000;
  const historicalLedger=(native.ledger||[]).filter(l=>l.kind==='fund');
  next.ledger=[...cp(historicalLedger),...cp(remote.ledger)].sort((a,b)=>a.date-b.date);
  ok(new Set(next.ledger.map(l=>l.id)).size===next.ledger.length,'远端流水 ID 与只读历史冲突');
  next.cashFlows=cp(remote.cashFlows);
  // All other native keys (historical funds, quotes, chart caches, snapshots,
  // themes, AI config and unknown legacy fields) remain unchanged.
  return next;
 }
 const api={project,merge,validate};root.LabAssets=api;
 root.labAssetsCall=json=>{try{const r=JSON.parse(json);ok(Object.prototype.hasOwnProperty.call(api,r.method),'未知资产操作');return JSON.stringify({ok:true,value:api[r.method](...r.args)});}catch(e){return JSON.stringify({ok:false,error:String(e.message||e)});}};
 if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:this);
