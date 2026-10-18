/* Explainable local research and replay. Not a remote language model, broker,
 * return promise or substitute for unavailable point-in-time evidence. */
(function(root){
  'use strict';
  const C = root.LabCore || (typeof require === 'function' ? require('./LabCore.js') : null);
  const ok=(v,m)=>{if(!v)throw Error(m);}, copy=x=>JSON.parse(JSON.stringify(x));
  const total=xs=>xs.reduce((a,b)=>a+b,0), mean=xs=>total(xs)/xs.length;
  const qty=p=>p.originalQuantity+total(p.lots.map(l=>l.quantity));
  const finite=x=>typeof x==='number'&&Number.isFinite(x);
  const active=o=>['waiting','partial'].includes(o.status);
  const roundTick=(price,tick,side)=>Math.max(tick,(side==='buy'?Math.floor(price/tick):Math.ceil(price/tick))*tick);
  function evidence(data, at) {
    ok(data&&Number.isSafeInteger(data.asOf)&&data.asOf<=at,'数据快照来自未来或无时间戳');
    ok(Array.isArray(data.instruments),'缺少证券数据');
    ok(new Set(data.instruments.map(i=>i.symbol)).size===data.instruments.length,'标的重复');
    const items=[];
    for(const row of data.instruments){
      ok(row.asset==='etf'||row.asset==='stock','只支持 ETF/股票');
      const bars=(row.bars||[]).filter(b=>Number.isSafeInteger(b.availableAt)&&b.availableAt<=at&&b.at<=at).sort((a,b)=>a.at-b.at);
      ok(new Set(bars.map(b=>b.at)).size===bars.length,'重复日线时间');
      ok(bars.every(b=>Number.isSafeInteger(b.close)&&b.close>0),'日线价格无效');
      const quote=row.quote && row.quote.at<=at && Number.isSafeInteger(row.quote.at) && Number.isSafeInteger(row.quote.price)&&row.quote.price>0 ? row.quote:null;
      const f=row.fundamentals&&Number.isSafeInteger(row.fundamentals.publishedAt)&&row.fundamentals.publishedAt<=at?row.fundamentals:null;
      const health={fresh:!!quote&&at-quote.at<=(data.maxAgeMs||300000),bars:bars.length,
        missing:[]};
      if(!quote)health.missing.push('quote');if(bars.length<60)health.missing.push('60 bars');if(!f)health.missing.push('point-in-time fundamentals');
      const close=bars.map(b=>b.close), last=close[close.length-1];
      const ma=n=>close.length>=n?mean(close.slice(-n)):null;
      const returns=close.slice(1).map((x,i)=>x/close[i]-1);
      const vol=returns.length>1?Math.sqrt(mean(returns.slice(-60).map(r=>(r-mean(returns.slice(-60)))**2))):null;
      const momentum=close.length>=21?last/close[close.length-21]-1:null;
      const trend=ma(60)&&ma(20)?(last>ma(20)&&ma(20)>ma(60)?'up':last<ma(20)&&ma(20)<ma(60)?'down':'range'):'unknown';
      const trap=f?finite(f.dividendYield)&&f.dividendYield>0.10||finite(f.payoutRatio)&&f.payoutRatio>1||finite(f.freeCashFlow)&&f.freeCashFlow<0:false;
      items.push({symbol:row.symbol,asset:row.asset,quote,bars,f,health,ma20:ma(20),ma60:ma(60),momentum,vol,trend,trap,
        source:String(row.source||'unspecified'),evidenceIDs:[...(row.evidenceIDs||[])],halted:row.halted===true});
    }
    return items;
  }
  function dividendValue(item){
    const f=item.f;
    if(!f||![f.dividendYield,f.valuationPercentile,f.dividendStability,f.cashFlowQuality].every(finite))return null;
    if(f.dividendYield<0||f.dividendYield>1||[f.valuationPercentile,f.dividendStability,f.cashFlowQuality].some(x=>x<0||x>1))return null;
    return Math.max(0,Math.min(1,0.3*Math.min(1,f.dividendYield/0.06)+0.3*(1-f.valuationPercentile)+0.2*f.dividendStability+0.2*f.cashFlowQuality-(item.trap?0.6:0)));
  }
  function score(item,variant='multifactor'){
    const parts=[];const value=dividendValue(item);
    if(item.momentum!==null)parts.push({name:'momentum20',value:Math.max(0,Math.min(1,0.5+item.momentum*5))});
    if(item.trend!=='unknown')parts.push({name:'trend20_60',value:item.trend==='up'?1:item.trend==='down'?0:0.5});
    if(item.vol!==null)parts.push({name:'lowVolatility',value:Math.max(0,1-item.vol/0.05)});
    if(value!==null)parts.push({name:'dividendValue',value});
    const sufficient=variant==='dividendValue'?value!==null:parts.length>=3;
    return {available:sufficient,score:!sufficient?null:variant==='dividendValue'?value:mean(parts.map(p=>p.value)),parts,
      model:variant==='dividendValue'?'local-dividend-value-v1':'local-multifactor-v1'};
  }
  function risk(state,account,items,config={}){
    C.validate(state);const a=state.accounts[account];ok(a,'账户不存在');
    const prices=Object.fromEntries(items.filter(i=>i.quote).map(i=>[i.symbol,i.quote.price]));
    const missing=a.positions.filter(p=>qty(p)>0&&!prices[p.symbol]).map(p=>p.symbol);
    if(missing.length)return {blocked:true,reason:'缺少持仓估值',missing};
    const equity=a.cash+total(a.positions.map(p=>qty(p)*(prices[p.symbol]||0)));
    const maxWeight=config.maxWeight??0.4,minCash=config.minCash??0.05;
    ok(maxWeight>0&&maxWeight<=1&&minCash>=0&&minCash<1,'风险规则无效');
    ok(finite(config.maxDrawdown??.2)&&(config.maxDrawdown??.2)>0&&(config.maxDrawdown??.2)<=1,'回撤规则无效');
    const breaches=a.positions.filter(p=>equity>0&&qty(p)*(prices[p.symbol]||0)/equity>maxWeight).map(p=>({symbol:p.symbol,weight:qty(p)*prices[p.symbol]/equity}));
    return {blocked:false,equity,cashRatio:equity?a.cash/equity:1,maxWeight,minCash,breaches,
      maxDrawdown:C.metrics(state,account).maxDrawdown??null,source:'observed-position-risk'};
  }
  function research(state,code,data,at,config={}){
    C.validate(state);ok(state.accounts[code],'账户不存在');
    const items=evidence(data,at), a=state.accounts[code], firewall=risk(state,code,items,config);
    const availableCash=a.cash-total(a.orders.filter(active).map(o=>o.reservedCash));
    const coverage={count:items.length,scope:data.scope||'provided-universe',isFullMarket:data.scope==='full-market'&&data.universeComplete===true};
    const output={at,account:code,model:'local-explainable-research-v1',automatesRealTrades:false,
      coverage,firewall,decisions:[],warnings:[],requiresUserConfirmationForRealTrades:true};
    if(firewall.blocked){output.warnings.push(firewall.reason);return output;}
    let raw=[];
    if(['A','B','C','D'].includes(code)){
      if(code==='A')return {...output,summary:'原持仓不卖，新增资金留现金'};
      if(code==='C'&&!state.targets){output.warnings.push('长期目标仓位尚未获用户确认');return output;}
      const prices=Object.fromEntries(items.filter(i=>i.quote).map(i=>[i.symbol,i.quote.price]));
      if(!a.positions.every(p=>qty(p)===0&&!state.targets?.[p.symbol]||prices[p.symbol])){output.warnings.push('配置建议缺少行情');return output;}
      raw=C.proposals(state,code,at,prices).proposals;
    }else{
      let ranked=items.map(i=>({i,score:score(i,code==='E'?'dividendValue':'multifactor')}))
        .filter(x=>x.i.health.fresh&&!x.i.halted&&x.score.available&&!x.i.trap);
      if(code==='F'||code==='E'&&config.dividendMode==='trend')ranked=ranked.filter(x=>x.i.trend==='up');
      const threshold=config.threshold??(code==='E'?0.55:0.60);
      const picked=ranked.filter(x=>x.score.score>=threshold).sort((a,b)=>b.score.score-a.score.score).slice(0,config.maxNames||5);
      const weight=picked.length?Math.min((1-firewall.minCash)/picked.length,firewall.maxWeight):0;
      for(const p of a.positions){
        const item=items.find(i=>i.symbol===p.symbol);if(!item||!item.quote||!item.health.fresh||item.halted)continue;
        const chosen=picked.find(x=>x.i.symbol===p.symbol);
        const target=chosen?weight:0;
        // A missing valuation is NOT a sell signal. E also requires fundamentals to sell.
        const sc=score(item,code==='E'?'dividendValue':'multifactor');
        if(!sc.available)continue;
        if(code==='F'&&item.trend==='unknown')continue;
        const diff=firewall.equity*target-qty(p)*item.quote.price;
        const n=Math.floor(Math.abs(diff)/item.quote.price/p.lot)*p.lot;
        if(n)raw.push({symbol:p.symbol,side:diff>0?'buy':'sell',quantity:n,referencePrice:item.quote.price});
      }
      if(!ranked.length)output.warnings.push('证据不足，不生成交易；没有估值不会伪造红利因子');
    }
    let budget=Math.max(0,availableCash-Math.ceil(firewall.equity*firewall.minCash));
    const fees=state.policies.find(p=>p.version===state.activePolicy);
    for(const r of raw.sort((a,b)=>(a.side==='sell'?-1:1)-(b.side==='sell'?-1:1))){
      const item=items.find(i=>i.symbol===r.symbol),p=a.positions.find(p=>p.symbol===r.symbol);
      if(!item||!item.quote||!item.health.fresh||item.halted||!p)continue;
      if(a.orders.some(o=>active(o)&&o.symbol===r.symbol))continue;
      let n=r.quantity;
      if(r.side==='sell'){
        let allowed=a.salePolicy==='all'&&(!p.tPlusOne||new Date(at+8*3600000).toISOString().slice(0,10)>p.seedSession)?p.originalQuantity:0;
        allowed+=total(p.lots.filter(l=>(!p.tPlusOne||l.session<new Date(at+8*3600000).toISOString().slice(0,10))&&(a.salePolicy!=='aiOnly'||l.origin==='ai')).map(l=>l.quantity));
        n=Math.min(n,Math.floor(allowed/p.lot)*p.lot);
      }else{
        if(firewall.maxDrawdown!==null&&firewall.maxDrawdown<=-(config.maxDrawdown??0.20)){
          output.warnings.push('组合回撤防火墙触发，暂停新增买入');continue;
        }
        const room=Math.max(0,firewall.equity*firewall.maxWeight-qty(p)*item.quote.price);
        n=Math.min(n,Math.floor(Math.min(budget,room)/item.quote.price/p.lot)*p.lot);
        while(n>0&&n*item.quote.price+C.fee(fees,p.asset,'buy',n*item.quote.price).amount>budget)n-=p.lot;
        if(n>0)budget-=n*item.quote.price+C.fee(fees,p.asset,'buy',n*item.quote.price).amount;
      }
      if(n<=0)continue;
      const sc=score(item,code==='E'?'dividendValue':'multifactor');
      const confidence=Math.min(0.95,(item.health.fresh?0.35:0)+(Math.min(item.bars.length,60)/60)*0.35+(item.f?0.2:0));
      output.decisions.push({id:`decision:${code}:${r.symbol}:${at}`,symbol:r.symbol,side:r.side,quantity:n,referencePrice:item.quote.price,
        model:code==='E'?'local-dividend-value-v1':code==='F'?'local-trend-risk-v1':code==='G'?'local-multifactor-v1':`allocation-${code}-v1`,
        confidence,confidenceMeaning:'数据完整性评分，不是盈利概率',evidenceIDs:item.evidenceIDs,
        evidenceAt:item.quote.at,factorScore:sc.score,factors:sc.parts,feeVersion:fees.version,
        cancellation:'到期、证据过期、停牌、风险规则变化时取消并重新评估',
        note:code==='G'?'本机可解释多因子规则，自主模拟；没有调用大语言模型':'条件化模拟研究'});
    }
    if(availableCash===0)output.warnings.push('当前无可用现金，研究仍继续；买入计划需匹配未来入金');
    return output;
  }
  function patientPlan(state,code,decision,at,config={}){
    const a=state.accounts[code],p=a.positions.find(p=>p.symbol===decision.symbol);
    ok(p,'缺少交易规则');ok(Number.isSafeInteger(at)&&decision.evidenceAt<=at,'未来决策证据');
    const parts=config.parts||3,wait=config.waitMs||86400000,discount=config.discountBps??25;
    ok(Number.isSafeInteger(parts)&&parts>0&&parts<=10&&discount>=0&&discount<=2000&&wait>0,'分档参数无效');
    let remaining=decision.quantity;
    const result=[];
    for(let i=0;i<parts;i++){
      let n=i===parts-1?remaining:Math.floor(decision.quantity/parts/p.lot)*p.lot;
      remaining-=n;if(!n)continue;
      const price=decision.referencePrice*(decision.side==='buy'?1-(discount+i*(config.stepBps??25))/10000:1);
      result.push({type:'order',account:code,id:`plan:${code}:${decision.symbol}:${at}:${i}`,symbol:p.symbol,
        side:decision.side,quantity:n,limit:roundTick(price,p.tick,decision.side),at,expiresAt:at+wait,origin:'ai',
        session:new Date(at+8*3600000).toISOString().slice(0,10),evidence:copy(decision),reassess:decision.cancellation});
    }
    return result;
  }
  function decide(state,data,at,config={}){
    let next=copy(state);const reviews=[];
    for(const code of Object.keys(next.accounts)){
      const r=research(next,code,data,at,config);reviews.push(r);
      for(const decision of r.decisions){
        for(const plan of patientPlan(next,code,decision,at,config)){
          try{next=C.dispatch(next,plan);}catch(e){r.warnings.push(`${decision.symbol}: ${e.message}`);}
        }
      }
    }
    return {state:next,reviews};
  }
  function replay(initial,events,config={}){
    let s=copy(initial),at=initial.seed.at;const reviews=[];
    ok(Array.isArray(events),'缺少事件序列');
    for(const e of events){
      ok(Number.isSafeInteger(e.at)&&e.at>initial.seed.at&&e.at>=at,'回放时间倒退');at=e.at;
      if(e.type==='flow')s=C.dispatch(s,e);
      else if(e.type==='mark')for(const account of Object.keys(s.accounts))s=C.dispatch(s,{...e,account});
      else if(e.type==='book')for(const account of Object.keys(s.accounts))s=C.dispatch(s,{...e,account});
      else if(e.type==='research'){const d=decide(s,e.data,e.at,config);s=d.state;reviews.push(...d.reviews);}
      else if(e.type==='expire')for(const account of Object.keys(s.accounts))s=C.dispatch(s,{...e,account});
      else if(e.type==='dividend'||e.type==='recordDividend')s=C.dispatch(s,e);
      else throw Error('未知回放事件');
    }
    return {state:s,reviews,comparison:C.compare(s),rules:{fees:copy(s.policies),initialAt:initial.seed.at,externalFlows:copy(s.accounts.A.flows)}};
  }
  function radar(data,at){
    const items=evidence(data,at);
    return {at,coverage:{count:items.length,scope:data.scope||'provided-universe',isFullMarket:data.scope==='full-market'&&data.universeComplete===true},
      ranked:items.map(i=>({symbol:i.symbol,...score(i),health:i.health,trap:i.trap,source:i.source})).sort((a,b)=>(b.score??-1)-(a.score??-1))};
  }
  function stress(state,code,prices,shocks,exposures={}){
    const a=state.accounts[code];ok(a,'账户不存在');
    ok(a.positions.filter(p=>qty(p)>0).every(p=>finite(prices[p.symbol])&&prices[p.symbol]>0),'压力测试缺行情');
    ok(Object.values(shocks).every(x=>finite(x)&&x>=-1&&x<=5),'冲击无效');
    const lines=a.positions.map(p=>{
      const exposure=exposures[p.symbol];
      if(exposure){ok(Object.values(exposure).every(w=>finite(w)&&w>=0)&&total(Object.values(exposure))<=1.000001,'穿透权重无效');}
      const shock=shocks[p.symbol]??(exposure?total(Object.entries(exposure).map(([k,w])=>(shocks[k]||0)*w)):0);
      const value=qty(p)*(prices[p.symbol]||0);return {symbol:p.symbol,value,change:Math.round(value*shock),coverage:exposure?total(Object.values(exposure)):null};
    });
    return {equity:a.cash+total(lines.map(l=>l.value)),change:total(lines.map(l=>l.change)),lines,uncoveredExposureIsZeroAssumption:true};
  }
  function dividendForecast(state,code,records,at){
    const a=state.accounts[code];ok(a,'账户不存在');
    const rows=records.filter(r=>Number.isSafeInteger(r.publishedAt)&&r.publishedAt<=at&&r.paymentAt>=at);
    ok(rows.every(r=>Number.isSafeInteger(r.netPerShare)&&r.netPerShare>=0),'分红金额无效');
    return {at,source:'announced-events-only',rows:rows.map(r=>({symbol:r.symbol,paymentAt:r.paymentAt,
      expectedNet:(a.positions.find(p=>p.symbol===r.symbol)?qty(a.positions.find(p=>p.symbol===r.symbol)):0)*r.netPerShare,
      dependsOnRecordDateHoldings:true,evidenceID:r.id})),note:'只计算已公布事件；未来分红不保证，需登记日持仓确认。'};
  }
  function scorecard(decisions,outcomes,at){
    return decisions.map(d=>{const out=outcomes.find(o=>o.decisionID===d.id&&o.at<=at&&o.at>d.evidenceAt);
      return {decisionID:d.id,model:d.model,evidenceIDs:d.evidenceIDs,status:!out?'pending':'observed',
        directionalReturn:!out?null:(out.price/d.referencePrice-1)*(d.side==='buy'?1:-1),
        note:'方向成绩不是已实现收益；真实执行还需扣费并核对资金占用'};});
  }
  function executionQuality(plan,fill){
    ok(fill.at>=plan.evidenceAt&&finite(fill.price)&&fill.price>0,'成交/决策时间无效');
    return {decisionID:plan.id,delayMs:fill.at-plan.evidenceAt,
      implementationShortfallBps:(fill.price/plan.referencePrice-1)*10000*(plan.side==='buy'?1:-1),
      label:'正值为相对决策参考价的不利执行；未把事后最低价当可成交基准'};
  }
  function evolve(candidates,train,validation){
    ok(Array.isArray(candidates)&&candidates.length&&train.length>=20&&validation.length>=10,'进化样本不足');
    ok(Math.max(...train.map(x=>x.at))<Math.min(...validation.map(x=>x.at)),'训练验证时段重叠');
    const perf=(p,data)=>total(data.map(r=>r.signal>=p.threshold?r.nextReturn*(1-p.riskBuffer):0))/data.length;
    ok([...train,...validation].every(r=>finite(r.signal)&&finite(r.nextReturn)),'进化样本无效');
    const ranked=candidates.map(p=>{ok(finite(p.threshold)&&p.threshold>=0&&p.threshold<=1&&finite(p.riskBuffer)&&p.riskBuffer>=0&&p.riskBuffer<1,'候选参数无效');return {params:copy(p),trainScore:perf(p,train)};}).sort((a,b)=>b.trainScore-a.trainScore);
    const winner=ranked[0];
    return {candidate: winner.params,trainScore:winner.trainScore,outOfSampleScore:perf(winner.params,validation),
      autoPromoted:false,method:'offline-parameter-search-v1',note:'只按训练期选候选，验证期只报告；标签收益须由无前视的独立流程提供，成本未包含时不能当净收益。'};
  }
  function advisor(state,data,at,question,future={}){
    const items=evidence(data,at),f=risk(state,'A',items,{});
    const monthly=future.monthly??0,months=future.months??12;
    ok(Number.isSafeInteger(monthly)&&monthly>=0&&Number.isSafeInteger(months)&&months>=0&&months<=600,'未来资金计划无效');
    const cash=state.accounts.A.cash;
    const priorities=[];
    if(f.blocked)priorities.push('先补齐持仓行情，再确认目标仓位。');
    else if(f.breaches.length)priorities.push('集中度超出规则：'+f.breaches.map(b=>b.symbol).join('、')+'；新增资金优先分散。');
    if(!cash)priorities.push('当前现金为零仍可研究；未来入金到账前不提交虚拟买单。');
    priorities.push(state.targets?'目标仓位已有用户确认；按可投入资金分阶段复核。':'先调整并确认长期目标仓位，C 策略尚不自动配置。');
    const remembered=(state.memory||[]).map(m=>m.text).slice(-20);
    if(remembered.length)priorities.push('已记录偏好：'+remembered.join('；')+'。自然语言偏好不自动改写已确认仓位。');
    if(/红利|分红/.test(String(question)))priorities.push(items.some(i=>i.f)?'红利研究同时核对估值、分红稳定性与现金流，避开高股息陷阱。':'缺少时点可用的分红与估值证据，暂不对红利标的排序。');
    if(/风险|回撤/.test(String(question)))priorities.push('先复核集中度、现金缓冲与采样回撤；压力测试是给定冲击，不是行情预测。');
    return {model:'offline-rule-advisor-v1',isLanguageModel:false,question:String(question),at,priorities,rememberedRules:remembered,
      futureContributions:monthly*months,currentCash:cash,availableResearch:true,evidence:items.map(i=>({symbol:i.symbol,at:i.quote?.at||null,source:i.source})),
      text:priorities.join('\n')+`\n未来 ${months} 个月计划投入 ${(monthly*months/10000).toFixed(2)} 元（本金安排，不是收益）。\n愿意等待较低价格时采用分档限价、到期取消并复核证据。真实交易由你决定。`};
  }
  function alerts(state,data,at,previous={},config={}){
    const items=evidence(data,at),r=risk(state,'G',items,config),out=[];
    const add=(id,level,text)=>{
      if(!previous[id]||at-previous[id]>(config.cooldownMs||3600000))out.push({id,level,text,at,action:'review',automatesRealTrades:false});
    };
    if(r.blocked)add('missing-valuation','critical',r.reason);
    for(const i of items){if(!i.health.fresh)add('stale:'+i.symbol,'warning','行情过期或缺少来源时间：'+i.symbol);if(i.trap)add('dividend-trap:'+i.symbol,'warning','红利质量规则触发：'+i.symbol);}
    for(const b of r.breaches||[])add('concentration:'+b.symbol,'warning','单标的集中度超出配置：'+b.symbol);
    if(r.maxDrawdown!==null&&r.maxDrawdown<-(config.maxDrawdown||.2))add('drawdown','critical','组合采样回撤超出规则');
    return {alerts:out,seen:{...previous,...Object.fromEntries(out.map(x=>[x.id,at]))},requiresNotificationPermission:true};
  }
  function calendar(events,at,days=30){
    ok(Array.isArray(events)&&Number.isSafeInteger(days)&&days>0&&days<=366,'事件日历输入无效');
    const end=at+days*86400000;
    return events.filter(e=>Number.isSafeInteger(e.publishedAt)&&e.publishedAt<=at&&Number.isSafeInteger(e.at)&&e.at>=at&&e.at<=end)
      .map(e=>{ok(typeof e.id==='string'&&typeof e.source==='string'&&e.source.length>0,'事件须有来源');return copy(e);}).sort((a,b)=>a.at-b.at);
  }
  function timeMachine(initial,events,cutoffs,config={}){
    ok(Array.isArray(cutoffs)&&cutoffs.every(t=>Number.isSafeInteger(t)&&t>initial.seed.at),'回溯时点无效');
    return cutoffs.map(at=>({at,...replay(initial,events.filter(e=>e.at<=at),config)}));
  }
  function dividendCompare(initial,events,config={}){
    const value=replay(initial,events,{...config,dividendMode:'value'}),trend=replay(initial,events,{...config,dividendMode:'trend'});
    return {value:value.comparison.E,trend:trend.comparison.E,initialAt:initial.seed.at,
      externalFlows:value.rules.externalFlows,feeVersions:value.rules.fees,
      valueResult:value,trendResult:trend,assumption:'两次同源反事实回放，仅红利趋势过滤条件不同'};
  }
  function observedComparison(state,baseline,observations,flows){
    ok(JSON.stringify(baseline)===JSON.stringify(state.seed),'真实观察的初始状态与实验不同，拒绝直接比较');
    const expected=state.accounts.A.flows.map(f=>({at:f.at,amount:f.amount}));
    ok(JSON.stringify(flows.map(f=>({at:f.at,amount:f.amount})))===JSON.stringify(expected),'真实与模拟外部资金流不一致');
    const dates=state.accounts.A.marks.map(m=>m.at);
    ok(JSON.stringify(observations.map(m=>m.at))===JSON.stringify(dates),'真实与模拟观察日期不一致');
    return {actual:C.metricsSeries(state.initialValue,state.seed.at,observations,flows),simulated:C.compare(state),source:'user-supplied-observations',realLedgerMutated:false};
  }
  function riskHistory(state,code,data,at){
    const items=evidence(data,at),r=risk(state,code,items,{});if(r.blocked)return r;
    const a=state.accounts[code],bySymbol=Object.fromEntries(items.map(i=>[i.symbol,i]));
    const series=a.positions.filter(p=>qty(p)>0).map(p=>{
      const i=bySymbol[p.symbol],weight=qty(p)*i.quote.price/r.equity,rows=i.bars;
      return new Map(rows.slice(1).map((b,n)=>[b.at,(b.close/rows[n].close-1)*weight]));
    });
    const dates=series.length?[...series[0].keys()].filter(t=>series.every(m=>m.has(t))):[];
    if(dates.length<20)return {status:'insufficientCommonObservations',count:dates.length};
    const returns=dates.map(t=>total(series.map(m=>m.get(t)))),sorted=[...returns].sort((a,b)=>a-b);
    return {status:'ok',sampleSize:returns.length,historicalVaR95:Math.max(0,-sorted[Math.floor((sorted.length-1)*.05)]),
      note:'固定当前权重、共同历史日期的经验分位；不是未来损失上限，未保证相关性稳定。'};
  }
  function reviewModel(state,data,text,at,config={}){
    ok(state.researchOnly!==true,'真实资产研究副本不能写入模拟或真实订单');
    C.validate(state);const items=evidence(data,at),firewall=risk(state,'G',items,config);
    ok(!firewall.blocked,'缺少组合估值，不能批准模型订单');
    const json=JSON.parse(String(text).trim().replace(/^```(?:json)?\s*/,'').replace(/\s*```$/,''));
    ok(json.schemaVersion===1&&Array.isArray(json.decisions)&&json.decisions.length<=10,'模型提案结构无效');
    let next=copy(state);const accepted=[],rejected=[];
    for(const [n,d]of json.decisions.entries()){
      try{
        ok(d&&typeof d==='object'&&!Array.isArray(d),'模型订单必须是对象');
        const item=items.find(i=>i.symbol===d.symbol),p=next.accounts.G.positions.find(p=>p.symbol===d.symbol);
        ok(item&&p&&item.health.fresh&&!item.halted&&score(item).available,'标的缺少当前多因子证据');
        ok(typeof d.reason==='string'&&d.reason.length>0&&d.reason.length<2000,'缺少建议依据');
        ok(Array.isArray(d.evidenceIDs)&&d.evidenceIDs.length>0&&d.evidenceIDs.every(id=>item.evidenceIDs.includes(id)),'模型引用了未提供的证据');
        ok(Number.isSafeInteger(d.expiresAt)&&d.expiresAt>at&&d.expiresAt<=at+30*86400000,'模型有效期无效');
        if(d.side==='buy'){
          ok(firewall.maxDrawdown===null||firewall.maxDrawdown>-(config.maxDrawdown??.2),'回撤防火墙触发');
          const pending=total(next.accounts.G.orders.filter(o=>active(o)&&o.side==='buy'&&o.symbol===d.symbol).map(o=>o.remaining));
          ok((qty(p)+pending+d.quantity)*item.quote.price<=firewall.equity*firewall.maxWeight,'模型提案超出集中度上限');
          const before=next.accounts.G.cash-total(next.accounts.G.orders.filter(active).map(o=>o.reservedCash));
          const fees=next.policies.find(p=>p.version===next.activePolicy);
          ok(before-d.quantity*d.limit-C.fee(fees,p.asset,'buy',d.quantity*d.limit).amount>=firewall.equity*firewall.minCash,'模型提案侵占现金缓冲');
        }
        const order={type:'order',account:'G',id:`model:G:${d.symbol}:${at}:${n}`,origin:'ai',symbol:d.symbol,side:d.side,
          quantity:d.quantity,limit:d.limit,at,expiresAt:d.expiresAt,session:new Date(at+8*3600000).toISOString().slice(0,10),
          evidence:{model:String(json.model||'configured-online-model'),reason:d.reason,evidenceIDs:d.evidenceIDs,quoteAt:item.quote.at},reassess:'到期或证据失效后重新研究'};
        next=C.dispatch(next,order);accepted.push(order);
      }catch(e){rejected.push({symbol:d?.symbol||'',reason:e.message});}
    }
    return {state:next,accepted,rejected,model:String(json.model||'configured-online-model'),realTrades:false};
  }
  const api={evidence,score,dividendValue,risk,research,patientPlan,decide,replay,radar,stress,dividendForecast,scorecard,executionQuality,evolve,advisor,alerts,calendar,timeMachine,dividendCompare,observedComparison,riskHistory,reviewModel};
  root.LabResearch=api;
  root.labResearchCall=json=>{try{const r=JSON.parse(json);ok(Object.prototype.hasOwnProperty.call(api,r.method),'未知研究调用');return JSON.stringify({ok:true,value:api[r.method](...r.args)});}catch(e){return JSON.stringify({ok:false,error:String(e.message||e)});}};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:this);
