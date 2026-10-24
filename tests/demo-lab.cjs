// Fixed synthetic data only. No real quotes, assets, NAS or investment advice.
const c = require('../guanpan-pro-native/Sources/Lab/LabCore.js');
const t = Date.parse('2026-10-12T02:00:00Z');
let state = c.create({at:t,cash:10000000,positions:[
  {symbol:'510300',asset:'etf',quantity:1000,cost:10000,price:10000,tick:10,lot:100,tPlusOne:false}
]},'synthetic-demo');
const apply = action => {state=c.dispatch(state,action);};
apply({type:'flow',id:'extra',at:t+60000,amount:5000000});
for(const account of Object.keys(state.accounts)) apply({type:'mark',account,at:t+60000,prices:{'510300':10000}});
apply({type:'order',account:'G',id:'synthetic-order',symbol:'510300',side:'buy',quantity:200,limit:10000,at:t+61000,expiresAt:t+300000,session:'2026-10-12'});
for(let i=0;i<2;i++) {
  const at=t+62000+i*1000;
  apply({type:'book',account:'G',at,book:{id:'synthetic-book-'+i,symbol:'510300',at,session:'2026-10-12',isTrading:true,model:'fiveLevel',source:'synthetic fixture',
    bids:Array.from({length:5},(_,j)=>({price:9900-j*10,quantity:1000})),
    asks:Array.from({length:5},(_,j)=>({price:10000+j*10,quantity:j===0?100:0}))}});
}
for(const account of Object.keys(state.accounts)) apply({type:'mark',account,at:t+86400000,prices:{'510300':9000}});
console.log(JSON.stringify({
  notice:'固定样本演示。G 的两次成交为手动测试指令；不是 AI 策略运行结果。E/F/G 策略引擎未实现。',
  feeUnits:'金额以 1/10000 元存储',
  fills:state.accounts.G.fills,
  metrics:c.compare(state)
},null,2));
