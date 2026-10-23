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
      ranked:items.map(i=>({symbol:i.symbol,...score(i),trend:i.trend,health:i.health,trap:i.trap,source:i.source,quoteAt:i.quote?.at??null,evidenceIDs:i.evidenceIDs})).sort((a,b)=>(b.score??-1)-(a.score??-1))};
  }
  function intradayStats(data,at,config={}){
    ok(data&&Array.isArray(data.instruments)&&Number.isSafeInteger(at),'分时统计输入无效');
    const maxAge=config.maxQuoteAgeMs??300000,rows=[];
    for(const item of data.instruments){
      const points=(item.intradayBars||[]).filter(b=>Number.isSafeInteger(b.at)&&b.at<=at&&
        Number.isSafeInteger(b.availableAt)&&b.availableAt<=at&&finite(b.price)&&b.price>0&&
        (!finite(b.volume)||b.volume>=0)).sort((a,b)=>a.at-b.at);
      const byDay=new Map();
      for(const b of points){const day=String(b.day||new Date(b.at+8*3600000).toISOString().slice(0,10));if(!byDay.has(day))byDay.set(day,[]);byDay.get(day).push(b);}
      const sessions=[...byDay.entries()].sort((a,b)=>a[0].localeCompare(b[0])).map(([day,ps])=>{
        const vols=ps.filter(p=>finite(p.volume)&&p.volume>0),volume=total(vols.map(p=>p.volume));
        const vwap=volume?total(vols.map(p=>p.price*p.volume))/volume:null;
        return {day,points:ps,open:ps[0].price,close:ps[ps.length-1].price,high:Math.max(...ps.map(p=>p.price)),
          low:Math.min(...ps.map(p=>p.price)),vwap,volume,volumeCoverage:ps.length?vols.length/ps.length:0};
      }).slice(-120);
      const quote=item.quote&&Number.isSafeInteger(item.quote.at)&&item.quote.at<=at?item.quote:null;
      const fresh=!!quote&&at-quote.at<=maxAge;
      const windows={};
      for(const n of [5,20,60,120]){
        const chosen=sessions.slice(-n);
        windows[n]=chosen.length<n?{available:false,sessions:chosen.length}:{available:true,sessions:n,
          meanRangePct:mean(chosen.map(s=>(s.high-s.low)/s.open)),
          high:Math.max(...chosen.map(s=>s.high)),low:Math.min(...chosen.map(s=>s.low)),
          vwapCoverage:mean(chosen.map(s=>s.volumeCoverage))};
      }
      const last20=sessions.slice(-20),trend20=last20.length>=20?last20[last20.length-1].close/last20[0].open-1:null;
      const ranges20=last20.map(s=>(s.high-s.low)/s.open),medianRange20=ranges20.length?([...ranges20].sort((a,b)=>a-b)[Math.floor(ranges20.length/2)]):null;
      const recentRange=last20.length?(last20[last20.length-1].high-last20[last20.length-1].low)/last20[last20.length-1].open:null;
      let regime='证据不足';
      if(last20.length>=20&&recentRange!==null&&medianRange20>0&&recentRange>=medianRange20*2.5)regime='异常波动';
      else if(trend20!==null&&trend20>=.05)regime='趋势上涨';
      else if(trend20!==null&&trend20<=-.05)regime='趋势下跌';
      else if(medianRange20!==null&&medianRange20<.01)regime='窄幅震荡';
      else if(medianRange20!==null)regime='宽幅震荡';
      const totalPoints=sessions.reduce((n,s)=>n+s.points.length,0),vwapCoverage=sessions.length?mean(sessions.map(s=>s.volumeCoverage)):0;
      const localCompleteDays=sessions.filter(s=>s.points.length>=200&&s.volumeCoverage>=.8).length;
      const blockers=[];
      const nas=item.intradayResearch;
      const useNAS=nas&&nas.status==='ready-for-statistical-review'&&
        Number.isSafeInteger(nas.sessions)&&nas.sessions>sessions.length&&
        Number.isSafeInteger(nas.lastAt)&&nas.lastAt<=at&&at-nas.lastAt<=3*86400000;
      let selectedTrend20=trend20,selectedMedianRange20=medianRange20,selectedRegime=regime;
      if(useNAS&&Array.isArray(nas.dailyEvidence)){
        const daily=nas.dailyEvidence.filter(d=>finite(d.open)&&d.open>0&&finite(d.close)&&
          finite(d.high)&&finite(d.low)&&d.high>=d.low).slice(-20);
        if(daily.length===20){
          selectedTrend20=daily[19].close/daily[0].open-1;
          const sorted=daily.map(d=>(d.high-d.low)/d.open).sort((a,b)=>a-b);
          selectedMedianRange20=sorted[Math.floor(sorted.length/2)];
          const recent=(daily[19].high-daily[19].low)/daily[19].open;
          selectedRegime=recent>=selectedMedianRange20*2.5&&selectedMedianRange20>0?'异常波动':
            selectedTrend20>=.05?'趋势上涨':selectedTrend20<=-.05?'趋势下跌':
            selectedMedianRange20<.01?'窄幅震荡':'宽幅震荡';
        }
      }
      const chosenWindows=useNAS?(nas.windows||windows):windows;
      const chosenSessions=useNAS?nas.sessions:sessions.length,chosenPoints=useNAS?(nas.samplePoints||totalPoints):totalPoints;
      const chosenCoverage=useNAS?(nas.volumeCoverage||0):vwapCoverage;
      const completeDays=useNAS?(nas.completeMinuteDays||0):localCompleteDays;
      const lastAt=useNAS?nas.lastAt:(sessions[sessions.length-1]?.points.at(-1)?.at??null);
      if(chosenSessions<60)blockers.push('少于60个交易日分时');
      if(completeDays<60)blockers.push('达到至少200分钟点覆盖的交易日不足60天');
      if(chosenCoverage<.8)blockers.push('成交量覆盖不足，不能计算可靠VWAP');
      if(!fresh)blockers.push('最新行情缺失或超过时效');
      if(!Number.isSafeInteger(lastAt)||lastAt>at||at-lastAt>3*86400000)blockers.push('长期分时研究超过3天或截至时间无效');
      if(!finite(useNAS?nas.latestSessionVWAP:(sessions[sessions.length-1]?.vwap??null)))blockers.push('没有可用成交量加权VWAP');
      rows.push({symbol:item.symbol,source:useNAS?(nas.source||'NAS归档统计'):item.intradaySource||'来源未核验的本机分时缓存',samplePoints:chosenPoints,
        sessions:chosenSessions,completeMinuteDays:completeDays,firstDay:useNAS?nas.firstDay:(sessions[0]?.day??null),lastDay:useNAS?nas.lastDay:(sessions[sessions.length-1]?.day??null),
        windows:chosenWindows,trend20:selectedTrend20,medianRange20:selectedMedianRange20,
        regime:selectedRegime,quoteAt:quote?.at??null,quoteAgeMs:fresh?at-quote.at:null,
        vwapCoverage:chosenCoverage,latestSessionVWAP:useNAS?nas.latestSessionVWAP:(sessions[sessions.length-1]?.vwap??null),
        eligibleForPricePlan:!blockers.length&&['窄幅震荡','宽幅震荡'].includes(selectedRegime),
        blockers:[...new Set(blockers)]});
    }
    return {at,requiredSessions:60,rows};
  }
  function candidateTPlan(data,holding,item,stat,at){
    const reasons=[],rules=(data.realPortfolio?.verifiedTradingRules||[]).filter(r=>r.symbol===holding.symbol);
    const rule=rules.length===1?rules[0]:null;
    const nas=item?.intradayResearch,quote=item?.quote;
    const books=(data.books||[]).filter(b=>b.symbol===holding.symbol&&Number.isSafeInteger(b.at)&&b.at<=at)
      .sort((a,b)=>b.at-a.at),book=books[0];
    if(!stat?.eligibleForPricePlan)reasons.push(...(stat?.blockers||['分时统计不满足震荡与覆盖要求']));
    if(!nas||nas.status!=='ready-for-statistical-review'||!Number.isSafeInteger(nas.lastAt)||
       nas.lastAt>at||at-nas.lastAt>3*86400000||!Array.isArray(nas.minuteEvidence)||nas.minuteEvidence.length<60)
      reasons.push('NAS缺少60天可核验的分钟价格顺序');
    if(!rule||!['sameDay','nextDay'].includes(rule.settlement)||!Number.isSafeInteger(rule.lotSize)||
       rule.lotSize<=0||!Number.isSafeInteger(rule.tickUnits)||rule.tickUnits<=0||
       !finite(rule.feePerFillYuan)||rule.feePerFillYuan<0||!rule.confirmationSource||
       !Number.isSafeInteger(rule.confirmedAt)||rule.confirmedAt>at||at-rule.confirmedAt>30*86400000)
      reasons.push('逐只ETF交易规则或手续费未由用户核对');
    if(!quote||!Number.isSafeInteger(quote.price)||quote.price<=0||!Number.isSafeInteger(quote.at)||at-quote.at>60000||quote.at>at)
      reasons.push('最新报价超过60秒或无效');
    if(!book||book.quantityUnit!=='shares'||book.isTrading!==true||!Number.isSafeInteger(book.at)||
       at-book.at>30000||!Array.isArray(book.bids)||!Array.isArray(book.asks)||!book.bids.length||!book.asks.length)
      reasons.push('30秒内可核验的交易盘口和份额深度缺失');
    if(!finite(holding.quantity)||holding.quantity<=0||!finite(holding.cost)||holding.cost<=0)
      reasons.push('真实持仓份额或成本无效');
    if(reasons.length)return {plan:null,blockers:reasons};
    const bid=Math.max(...book.bids.map(x=>x.price)),ask=Math.min(...book.asks.map(x=>x.price));
    const bidDepth=total(book.bids.map(x=>x.quantity)),askDepth=total(book.asks.map(x=>x.quantity));
    if(!Number.isSafeInteger(bid)||!Number.isSafeInteger(ask)||bid<=0||ask<=bid||
       !book.bids.concat(book.asks).every(x=>Number.isSafeInteger(x.price)&&Number.isSafeInteger(x.quantity)&&x.quantity>=0)||
       (ask-bid)/bid>.003||Math.min(bidDepth,askDepth)<rule.lotSize*10)
      return {plan:null,blockers:['盘口价差过大、交叉或有效份额深度不足']};
    const window=nas.windows?.['20'],vwap=nas.latestSessionVWAP;
    const high=window?.vwapHighDeviationMedian,low=window?.vwapLowDeviationMedian;
    if(window?.available!==true||window?.sessions!==20||!finite(vwap)||vwap<=0||!finite(high)||!finite(low)||high<.002||low>-.002)
      return {plan:null,blockers:['完整20日VWAP窗口或两侧震荡统计不足，不能推算候选价差']};
    const sell=roundTick(Math.max(quote.price,vwap*(1+high*.65)),rule.tickUnits,'sell');
    const buy=roundTick(vwap*(1+low*.65),rule.tickUnits,'buy');
    if(buy<=0||sell<=buy||sell/Math.max(1,quote.price)>1.02)
      return {plan:null,blockers:['候选价格偏离现价过远或扣除档位后无有效价差']};
    const sellOffset=sell/vwap-1,buyOffset=buy/vwap-1;
    const paths=nas.minuteEvidence.slice(-60);
    if(paths.length<60||paths.some(day=>!finite(day.vwap)||day.vwap<=0||
       !Array.isArray(day.points)||day.points.length<200||day.points.length>260||
       day.points.some(p=>!Array.isArray(p)||p.length!==2||!Number.isSafeInteger(p[0])||
         !Number.isSafeInteger(p[1])||p[1]<=0)||
       day.points.some((p,index)=>index>0&&p[0]<=day.points[index-1][0])))
      return {plan:null,blockers:['历史分钟路径不完整，不能检验先后触及']};
    function touches(firstHigh){
      let first=0,ordered=0,wait=0;
      for(const day of paths){
        const firstLimit=day.vwap*(1+(firstHigh?sellOffset:buyOffset));
        const secondLimit=day.vwap*(1+(firstHigh?buyOffset:sellOffset));
        const index=day.points.findIndex(p=>firstHigh?p[1]>=firstLimit:p[1]<=firstLimit);
        if(index<0)continue;
        first++;
        const next=day.points.slice(index+1).find(p=>firstHigh?p[1]<=secondLimit:p[1]>=secondLimit);
        if(next){ordered++;wait+=(next[0]-day.points[index][0])/60000;}
      }
      return {days:paths.length,firstTouched:first,orderedRoundTrips:ordered,
        observedRoundTripRate:ordered/paths.length,meanWaitMinutes:ordered?wait/ordered:null};
    }
    const reverseHistory=touches(true),positiveHistory=touches(false);
    const maxDepth=Math.floor(Math.min(bidDepth,askDepth)*.1/rule.lotSize)*rule.lotSize;
    const sellable=finite(rule.brokerSellableShares)&&Number.isSafeInteger(rule.sellableCheckedAt)&&
      rule.sellableCheckedAt<=at&&at-rule.sellableCheckedAt<=300000
      ?Math.min(holding.quantity,rule.brokerSellableShares):0;
    const reverseQuantity=Math.floor(Math.min(sellable,holding.quantity*.25,maxDepth)/rule.lotSize)*rule.lotSize;
    const cash=data.realPortfolio?.cash,spendable=finite(cash)?Math.max(0,cash-Math.max(1000,cash*.1)):0;
    const weight=finite(data.realPortfolio?.equity)&&data.realPortfolio.equity>0&&finite(holding.marketValue)
      ?100*holding.marketValue/data.realPortfolio.equity:null;
    const atPositionLimit=weight!==null&&finite(holding.maxPositionPercent)&&weight>=holding.maxPositionPercent;
    const positionRoom=weight!==null&&finite(holding.maxPositionPercent)
      ?Math.max(0,data.realPortfolio.equity*holding.maxPositionPercent/100-holding.marketValue):Infinity;
    // For T+1 the second leg must sell broker-confirmed old shares; newly bought
    // shares are never assumed sellable on the same day.
    const positiveSellCapacity=rule.settlement==='sameDay'?holding.quantity:sellable;
    const positiveQuantity=!atPositionLimit
      ?Math.floor(Math.min(Math.max(0,spendable-rule.feePerFillYuan)/(buy/10000),
        positionRoom/(buy/10000),positiveSellCapacity,
        holding.quantity*.25,maxDepth)/rule.lotSize)*rule.lotSize:0;
    const candidates=[];
    for(const [type,quantity,history] of [['reverseT',reverseQuantity,reverseHistory],['positiveT',positiveQuantity,positiveHistory]]){
      if(quantity<rule.lotSize||history.firstTouched<20||history.orderedRoundTrips<15)continue;
      const gross=(sell-buy)*quantity/10000,fees=rule.feePerFillYuan*2,net=gross-fees;
      if(net<Math.max(1,fees*3))continue;
      const expiry=Math.min(at+30000,book.at+60000,quote.at+60000,
        type==='reverseT'?rule.sellableCheckedAt+300000:at+30000);
      if(expiry<=at)continue;
      candidates.push({type,symbol:holding.symbol,quantity,
        sellLimitYuan:sell/10000,buyLimitYuan:buy/10000,
        grossYuan:gross,feesYuan:fees,netYuan:net,
        equivalentCostReductionYuanPerShare:net/holding.quantity,
        historicalTouches:history,quoteAt:quote.at,bookAt:book.at,
        researchLastAt:nas.lastAt,source:nas.source,ruleSource:rule.confirmationSource,
        ruleConfirmedAt:rule.confirmedAt,
        intradaySessions:nas.sessions,completeMinuteDays:nas.completeMinuteDays,
        volumeCoverage:nas.volumeCoverage,
        confidenceLabel:(nas.sessions>=120&&nas.completeMinuteDays>=100&&nas.volumeCoverage>=.95
          ?'较高':'中等')+'：仅指证据覆盖，不代表成交概率',
        validUntil:expiry,automatesTrades:false,
        evidence:['60日分钟先后触及','20日VWAP偏离中位数','实时五档盘口与份额深度','用户核对的ETF规则与可卖余额'],
        risks:['第一笔成交后第二笔可能不触及，反T会踏空、正T会继续下跌',
          '历史触及率不是未来成交概率，盘口和新闻变化须重新计算'],
        invalidation:['超过有效期或报价/盘口过期','突破近期震荡区间或转为单边趋势',
          '重大相关事件、交易规则或券商可卖余额改变']});
    }
    candidates.sort((a,b)=>b.historicalTouches.observedRoundTripRate*b.netYuan-
      a.historicalTouches.observedRoundTripRate*a.netYuan);
    return candidates.length?{plan:candidates[0],blockers:[]}:
      {plan:null,blockers:['历史先后触及、可卖份额、现金或扣费净收益未达到保守门槛']};
  }
  function candidateGridPlan(data,holding,item,stat,at,tCandidate){
    // A grid is a different presentation of the same verified market evidence, not a
    // second account or a set of pending orders. Refuse it if the T quality gate fails.
    if(stat?.regime!=='宽幅震荡'||!tCandidate?.plan)return {plan:null,blockers:['未满足宽幅震荡或可靠分钟/盘口门槛']};
    const base=tCandidate.plan,nas=item.intradayResearch,
      rule=(data.realPortfolio?.verifiedTradingRules||[]).find(r=>r.symbol===holding.symbol),
      book=(data.books||[]).filter(b=>b.symbol===holding.symbol&&b.at<=at).sort((a,b)=>b.at-a.at)[0];
    if(!rule||!book)return {plan:null,blockers:['ETF交易规则或盘口已失效']};
    const window=nas.windows?.['20'],vwap=nas.latestSessionVWAP;
    if(window?.available!==true||window?.sessions!==20||!finite(vwap)||!finite(window?.vwapHighDeviationMedian)||!finite(window?.vwapLowDeviationMedian))
      return {plan:null,blockers:['完整20日VWAP区间统计缺失']};
    const lower=roundTick(vwap*(1+window.vwapLowDeviationMedian),rule.tickUnits,'buy');
    const upper=roundTick(vwap*(1+window.vwapHighDeviationMedian),rule.tickUnits,'sell');
    const width=upper-lower,feeUnits=rule.feePerFillYuan*2*10000/base.quantity;
    const minStep=Math.max(rule.tickUnits*2,Math.ceil((feeUnits*4)/rule.tickUnits)*rule.tickUnits);
    if(width<minStep*2||!finite(width))return {plan:null,blockers:['区间宽度扣费后不足以容纳可靠网格']};
    const volatilityStep=roundTick(vwap*Math.max(.003,(stat.medianRange20||0)*.28),rule.tickUnits,'sell');
    const step=Math.max(minStep,volatilityStep);
    const bestBid=Math.max(...book.bids.map(x=>x.price)),bestAsk=Math.min(...book.asks.map(x=>x.price));
    const buyLevels=[],sellLevels=[];
    for(let price=lower;price<bestBid&&buyLevels.length<8;price+=step)buyLevels.push(price);
    for(let price=upper;price>bestAsk&&sellLevels.length<8;price-=step)sellLevels.push(price);
    const levels=Math.min(buyLevels.length,sellLevels.length);
    if(levels<2)return {plan:null,blockers:['波动与费用约束下无法形成两档以上网格']};
    const weight=finite(data.realPortfolio?.equity)&&data.realPortfolio.equity>0&&finite(holding.marketValue)
      ?100*holding.marketValue/data.realPortfolio.equity:null;
    if(weight!==null&&finite(holding.maxPositionPercent)&&weight>=holding.maxPositionPercent)
      return {plan:null,blockers:['该持仓已达到配置仓位上限，不新增网格买档']};
    const positionRoom=weight!==null&&finite(holding.maxPositionPercent)
      ?Math.max(0,data.realPortfolio.equity*holding.maxPositionPercent/100-holding.marketValue):Infinity;
    const cash=Math.max(0,data.realPortfolio?.cash||0),reserve=Math.max(1000,cash*.1);
    const sellable=Math.min(holding.quantity,rule.brokerSellableShares||0);
    if(!Number.isSafeInteger(rule.sellableCheckedAt)||at-rule.sellableCheckedAt>300000||rule.sellableCheckedAt>at)
      return {plan:null,blockers:['券商可卖份额已超过5分钟']};
    const maxPerLevel=Math.floor(Math.min(holding.quantity*.15,sellable/levels,
      positionRoom/(upper/10000)/levels,
      Math.min(total(book.bids.map(x=>x.quantity)),total(book.asks.map(x=>x.quantity)))*.1)/rule.lotSize)*rule.lotSize;
    const buyBudget=Math.max(0,cash-reserve),perBuyBudget=buyBudget/levels;
    const quantity=Math.floor(Math.min(maxPerLevel,perBuyBudget/(upper/10000))/rule.lotSize)*rule.lotSize;
    if(quantity<rule.lotSize)return {plan:null,blockers:['实际可卖份额、盘口深度或现金不足以支持动态档位']};
    const bands=[];
    for(let i=0;i<levels;i++){
      const buy=buyLevels[i],sell=sellLevels[i];
      const net=(sell-buy)*quantity/10000-rule.feePerFillYuan*2;
      if(net<=Math.max(1,rule.feePerFillYuan*3))continue;
      bands.push({buyLimitYuan:buy/10000,sellLimitYuan:sell/10000,quantity,
        buyCapitalYuan:buy*quantity/10000+rule.feePerFillYuan,
        buyFeeYuan:rule.feePerFillYuan,expectedNetYuan:net});
    }
    if(bands.length<2)return {plan:null,blockers:['各档扣费净收益不足']};
    const maxBuyCapitalYuan=total(bands.map(b=>b.buyCapitalYuan));
    const remainingSharesAfterAllSells=holding.quantity-bands.length*quantity;
    if(maxBuyCapitalYuan>buyBudget||remainingSharesAfterAllSells<0)
      return {plan:null,blockers:['组合现金或可卖份额无法覆盖全部档位']};
    return {plan:{type:'grid',symbol:holding.symbol,lowerYuan:lower/10000,upperYuan:upper/10000,
      levels:bands.length,stepYuan:step/10000,bands,maxBuyCapitalYuan,
      remainingSharesAfterAllSells,quoteAt:base.quoteAt,bookAt:base.bookAt,
      researchLastAt:base.researchLastAt,source:base.source,ruleSource:base.ruleSource,
      ruleConfirmedAt:base.ruleConfirmedAt,
      validUntil:base.validUntil,
      intradaySessions:base.intradaySessions,completeMinuteDays:base.completeMinuteDays,
      volumeCoverage:base.volumeCoverage,confidenceLabel:base.confidenceLabel,automatesTrades:false,
      evidence:['20日VWAP上下偏离中位数','60日分钟顺序与覆盖','ATR代理日内振幅','实时盘口深度','实际持仓、现金与已核对手续费'],
      risks:['多档买入后继续下跌会扩大仓位；多档卖出后上涨会踏空','档位净收益假设买卖两腿均在券商真实成交'],
      invalidation:['价格突破网格上下限','市场由宽幅震荡转为单边或异常波动','盘口、行情、重大新闻或券商可卖余额改变','超过短时有效期']},blockers:[]};
  }
  function recoveryPath(portfolio,holding,quote,plan){
    if(!quote||!Number.isSafeInteger(quote.price)||quote.price<=0||!finite(holding.cost)||
       holding.cost<=0||!finite(holding.quantity)||holding.quantity<=0)return null;
    const marketPrice=quote.price/10000,basisCost=finite(holding.displayedCost)
      ?holding.displayedCost:holding.cost,loss=marketPrice<basisCost;
    if(!loss)return {status:'not-in-loss',marketPriceYuan:marketPrice};
    const rule=(portfolio.verifiedTradingRules||[]).find(r=>r.symbol===holding.symbol);
    const estimatedExitFee=finite(rule?.feePerFillYuan)?rule.feePerFillYuan:.1;
    const cash=finite(portfolio.cash)?Math.max(0,portfolio.cash):0;
    const equity=finite(portfolio.equity)?portfolio.equity:null;
    const limit=finite(holding.maxPositionPercent)?holding.maxPositionPercent:null;
    const positionCapacity=equity!==null&&limit!==null
      ?Math.max(0,equity*limit/100-(holding.marketValue||holding.quantity*marketPrice)):Infinity;
    const lot=rule?.lotSize;
    const maxShares=Number.isSafeInteger(lot)&&lot>0
      ?Math.floor(Math.min(holding.quantity*.25,(cash-Math.max(1000,cash*.1))/marketPrice,
        positionCapacity/marketPrice)/lot)*lot:0;
    const addShares=Math.max(0,maxShares);
    const fee=addShares?(finite(rule?.feePerFillYuan)?rule.feePerFillYuan:.1):0;
    const addCost=addShares*marketPrice+fee;
    const afterAdd=addShares?(basisCost*holding.quantity+addCost)/(holding.quantity+addShares):null;
    const cycleNet=plan?.type==='grid'?Math.min(...plan.bands.map(b=>b.expectedNetYuan)):
      finite(plan?.netYuan)?plan.netYuan:null;
    const theoreticalThree=cycleNet!==null&&cycleNet>0?cycleNet*3:null;
    return {status:'in-loss',marketPriceYuan:marketPrice,
      breakEvenRisePct:(basisCost+estimatedExitFee/holding.quantity)/marketPrice-1,
      breakEvenExitFeeYuan:estimatedExitFee,exitFeeEstimated:!finite(rule?.feePerFillYuan),
      threeCompletedCycles:theoreticalThree===null?null:{netYuan:theoreticalThree,
        equivalentCostYuanPerShare:basisCost-theoreticalThree/holding.quantity},
      cautiousAdd:addShares?{quantity:addShares,requiredCashYuan:addCost,
        newAverageCostYuan:afterAdd,additionalMarketExposureYuan:addShares*marketPrice}:null,
      trimQuarter:{shares:Math.floor(holding.quantity*.25),remainingShares:holding.quantity-Math.floor(holding.quantity*.25),
        exposureReductionYuan:Math.floor(holding.quantity*.25)*marketPrice},
      caveat:'补仓增加下跌敞口；三次做T仅在全部真实成交且价差重现时成立，不应为回本无限加仓'};
  }
  function decisionContext(data,at,config={}){
    const portfolio=data.realPortfolio||{},holdings=portfolio.holdings||[],stats=intradayStats(data,at,config),
      statBy=Object.fromEntries(stats.rows.map(x=>[x.symbol,x])),marketBy=Object.fromEntries((data.instruments||[]).map(x=>[x.symbol,x])),
      radarRows=new Map(radar(data,at).ranked.map(x=>[x.symbol,x])),nas=data.nasOpportunityScan||{},nasRows=new Set((nas.opportunities||[]).map(x=>x.symbol));
    const roles=new Map((portfolio.holdingRoles||[]).map(r=>[r.symbol,r.role]));
    const temporaryPauses=new Set(data.profileState?.temporaryPauses||[]);
    const decisions=holdings.map(h=>{
      const symbol=h.symbol,s=statBy[symbol]||{},m=marketBy[symbol]||{},q=m.quote,
        age=q?at-q.at:null,regime=s.regime||'证据不足',relatedNews=(data.news||[]).filter(n=>
          (n.symbol===symbol||(n.symbol==='MARKET'&&
            (n.eventScope==='market'||n.eventScope==='industry'&&Array.isArray(n.affectedSymbols)&&
             n.affectedSymbols.includes(symbol))))&&
          Number.isSafeInteger(n.at)&&Number.isSafeInteger(n.availableAt)&&
          n.at<=n.availableAt&&n.availableAt<=at&&at-n.at<=7*86400000&&
          typeof n.sourceURL==='string'&&n.sourceURL.startsWith('https://')),
        majorNews=relatedNews.filter(n=>n.importance==='major'&&at-n.at<=86400000);
      let action='不交易',reason='缺少足够证据，等待数据补齐',priority=10,plan=null,planBlockers=[];
      if(!q||!Number.isSafeInteger(q.at)||age<0||age>(config.maxQuoteAgeMs??300000)){reason='最新行情缺失、过期或时间异常';priority=100;}
      else if(temporaryPauses.has(symbol)){reason='你最近反馈该持仓暂不交易，短期偏好暂停新候选计划';priority=99;}
      else if(majorNews.length){reason='持仓相关重大事件可能使历史震荡区间失效；暂停旧计划并重新核对行情与事件';priority=98;}
      else if(regime==='异常波动'){reason='近期振幅显著高于常态，暂停原有做T/网格计划';priority=95;}
      else if(roles.get(symbol)==='core'){
        action='长期持有';reason='你明确将这只持仓设为核心仓；暂不以短线限价计划动用核心份额';priority=90;
      }
      else if(regime==='趋势下跌'){action='暂停加仓';reason='中短期分时呈下行趋势，防止网格持续接刀';priority=85;}
      else if(regime==='趋势上涨'){action='长期持有';reason='趋势向上，优先避免频繁做T踏空';priority=70;}
      else if(regime==='窄幅震荡'||regime==='宽幅震荡'){
        const candidate=candidateTPlan(data,h,m,s,at);
        plan=candidate.plan;planBlockers=candidate.blockers;
        if(plan){
          const grid=candidateGridPlan(data,h,m,s,at,candidate);
          if(grid.plan && grid.plan.bands.length>=2 && candidate.plan.historicalTouches.observedRoundTripRate<.45)
            plan=grid.plan;
          action=plan.type==='grid'?'网格候选':plan.type==='reverseT'?'反T候选':'正T候选';
          reason='长期分钟先后触及与VWAP震荡支持候选计划；已扣除两笔手续费，仍须在有效期内核对券商盘口与相关新闻';
          priority=75+Math.min(15,candidate.plan.historicalTouches.observedRoundTripRate*15);
        }else{
          reason='震荡观察中，但'+planBlockers.join('、')+'；当前不提供精确挂单价';priority=60;
        }
      }
      const r=radarRows.get(symbol),nasFresh=Number.isSafeInteger(nas.at)&&nas.at<=at&&at-nas.at<=86400000&&nasRows.has(symbol);
      return {symbol,name:h.name||symbol,action,reason,priority,marketRegime:regime,
        factorScore:r?.score??null,quoteAt:q?.at??null,quotePriceUnits:q?.price??null,
        quoteAgeMs:age,source:m.source||'unknown',
        intraday:s, nasScreened:nasFresh,relatedNews:relatedNews.map(n=>({headline:n.headline,
          publisher:n.publisher,sourceURL:n.sourceURL,importance:n.importance,eventScope:n.eventScope,at:n.at})),
        plan,planBlockers,recovery:recoveryPath(portfolio,h,q,plan),automatesTrades:false};
    }).sort((a,b)=>b.priority-a.priority||((b.factorScore??-1)-(a.factorScore??-1)));
    const availablePlans=decisions.filter(d=>d.plan);
    return {asOf:at,version:'real-holdings-decision-context-v1',accountSource:'realPortfolio',
      holdingsCount:holdings.length,cash:portfolio.cash??null,equity:portfolio.equity??null,
      decisions,todayStatus:availablePlans.length
        ?'发现'+availablePlans.length+'条有历史与盘口依据的做T候选；请在券商手工核对'
        :'今天不建议交易；当前没有通过数据、规则、费用和先后触及校验的候选计划',
      pricePlansAllowed:availablePlans.length>0,
      reason:availablePlans.length?'候选只在短时有效，不是委托或成交保证':'证据不足时不输出限价和份额',
      newsStatus:data.news?.length?'available':'unavailable',nasStatus:nasFreshStatus(nas,at),automatesTrades:false};
  }
  function nasFreshStatus(nas,at){return Number.isSafeInteger(nas.at)&&nas.at<=at&&at-nas.at<=86400000?'fresh':'unavailable-or-stale';}
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
    const max=state.investmentProfile?.maxPositionPercent;
    const items=evidence(data,at),f=risk(state,'A',items,{maxWeight:finite(max)&&max>0&&max<=100?max/100:.4});
    const monthly=future.monthly??0,months=future.months??12;
    ok(Number.isSafeInteger(monthly)&&monthly>=0&&Number.isSafeInteger(months)&&months>=0&&months<=600,'未来资金计划无效');
    const cash=state.accounts.A.cash;
    const priorities=[];
    if(f.blocked)priorities.push('先补齐持仓行情，再确认目标仓位。');
    else if(f.breaches.length)priorities.push('集中度超出规则：'+f.breaches.map(b=>b.symbol).join('、')+'；新增资金优先分散。');
    if(!cash)priorities.push('当前现金为零仍可研究；未来入金到账前不提交虚拟买单。');
    priorities.push(state.targets?'目标仓位已有用户确认；按可投入资金分阶段复核。':state.allocationTargets?.length?'长期目标已保存；将其用于模拟前还需确认证券规则并导入 C 策略。':'先调整并确认长期目标仓位，C 策略尚不自动配置。');
    if(state.investmentProfile?.goal)priorities.push('你的目标：'+state.investmentProfile.goal);
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
  const api={evidence,score,dividendValue,risk,research,patientPlan,decide,replay,radar,intradayStats,decisionContext,stress,dividendForecast,scorecard,executionQuality,evolve,advisor,alerts,calendar,timeMachine,dividendCompare,observedComparison,riskHistory,reviewModel};
  root.LabResearch=api;
  root.labResearchCall=json=>{try{const r=JSON.parse(json);ok(Object.prototype.hasOwnProperty.call(api,r.method),'未知研究调用');return JSON.stringify({ok:true,value:api[r.method](...r.args)});}catch(e){return JSON.stringify({ok:false,error:String(e.message||e)});}};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
})(typeof globalThis!=='undefined'?globalThis:this);
