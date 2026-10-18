/* Offline JSON engine, used unchanged by Node tests and iOS JavaScriptCore.
 * Money/price units: 1/10000 CNY; quantity: whole shares; time: UTC milliseconds.
 * No I/O, real ledger access, broker calls, network or automatic strategy execution.
 */
(function (root) {
  'use strict';
  const UNIT = 10000, DAY = 86400000;
  const clone = x => JSON.parse(JSON.stringify(x));
  const fail = message => { throw new Error(message); };
  const check = (ok, message) => { if (!ok) fail(message); };
  const integer = (n, min = 0) => Number.isSafeInteger(n) && n >= min;
  const sum = xs => xs.reduce((a, b) => a + b, 0);
  const key = x => typeof x === 'string' && /^[A-Za-z0-9_.:-]{1,100}$/.test(x);
  const own = (x, k) => Object.prototype.hasOwnProperty.call(x, k);
  const sessionOf = at => new Date(at + 8*3600000).toISOString().slice(0,10);
  const strategies = {
    A: '原始持仓不卖，新增资金保留现金',
    B: '原始持仓不卖，新增资金按初始权重买入',
    C: '原始持仓不卖，新增资金按已确认目标配置',
    D: '定期再平衡', E: '红利价值动态调仓', F: '趋势与风险控制', G: 'AI 多因子模拟'
  };
  function policy(p) {
    check(p && key(p.version), '费用版本无效');
    check(p.etfFee === 1000 && integer(p.stockMinimum) && integer(p.extraSlippageTicks), '费用规则无效');
    for (const k of ['stockRatePPM', 'stockSellTaxPPM'])
      check(p[k] === null || (integer(p[k]) && p[k] <= 1000000), '股票费率无效');
    return clone(p);
  }
  function defaultPolicy() {
    return { version: 'user-2026-10-v1', etfFee: 1000, stockMinimum: 50000,
      stockRatePPM: null, stockSellTaxPPM: null, extraSlippageTicks: 0 };
  }
  function fee(p, asset, side, gross) {
    check(integer(gross), '成交金额溢出');
    if (asset === 'etf') return { amount: p.etfFee, estimated: false };
    const ppm = rate => Math.floor(gross/1000000)*rate + Math.ceil((gross%1000000)*rate/1000000);
    const commission = Math.max(p.stockMinimum, ppm(p.stockRatePPM || 0));
    const tax = side === 'sell' ? ppm(p.stockSellTaxPPM || 0) : 0;
    return { amount: commission + tax, estimated: p.stockRatePPM === null || (side === 'sell' && p.stockSellTaxPPM === null) };
  }
  function instrument(p) {
    check(p && key(p.symbol) && ['etf', 'stock'].includes(p.asset), '仅支持已确认类型的 ETF/股票');
    check(integer(p.tick, 1) && integer(p.lot, 1) && typeof p.tPlusOne === 'boolean', '必须显式确认证券交易规则');
    check(integer(p.quantity) && Number.isSafeInteger(p.cost) && integer(p.price, 1), '初始持仓数据无效');
    return { symbol: p.symbol, asset: p.asset, tick: p.tick, lot: p.lot, tPlusOne: p.tPlusOne,
      originalQuantity: p.quantity, cost: p.cost, lots: [] };
  }
  const quantity = p => p.originalQuantity + sum(p.lots.map(l => l.quantity));
  function create(snapshot, id, p = defaultPolicy()) {
    check(snapshot && key(id) && integer(snapshot.at, 1) && integer(snapshot.cash), '初始快照无效');
    check(Array.isArray(snapshot.positions), '缺少持仓');
    const positions = snapshot.positions.map(instrument);
    positions.forEach(p => { p.seedSession = sessionOf(snapshot.at); });
    check(new Set(positions.map(p => p.symbol)).size === positions.length, '初始持仓代码重复');
    const initialValue = snapshot.cash + sum(snapshot.positions.map(p => p.quantity * p.price));
    check(integer(initialValue), '账户金额溢出');
    const accounts = {};
    for (const code of Object.keys(strategies)) {
      accounts[code] = { id: id + ':' + code, strategy: code, cash: snapshot.cash, positions: clone(positions),
        salePolicy: ['A', 'B', 'C'].includes(code) ? 'lockOriginal' : 'all',
        orders: [], fills: [], flows: [], incomes: [], events: [], marks: [], lastAt: snapshot.at };
    }
    return { schema: 2, id, seed: clone(snapshot), initialValue, policies: [policy(p)], activePolicy: p.version,
      accounts, flowIDs: [], monthlyPlan: {}, lastFlowAt: snapshot.at, targets: null,
      channels: {
        assets: { mode: 'manual', status: 'notConnected', progress: 0, revision: 0, baseline: null },
        market: { mode: 'automatic', status: 'notConnected', progress: 0, revision: 0, baseline: null },
        quant: { mode: 'automatic', status: 'notConnected', progress: 0, revision: 0, baseline: null }
      } };
  }
  function validate(s) {
    check(s && s.schema === 2 && key(s.id), '不支持的实验账本版本');
    check(integer(s.initialValue) && s.seed && integer(s.seed.at, 1), '实验快照损坏');
    check(Array.isArray(s.policies) && s.policies.length > 0, '费用版本缺失');
    s.policies.forEach(policy);
    check(new Set(s.policies.map(p => p.version)).size === s.policies.length, '费用版本重复');
    check(s.policies.some(p => p.version === s.activePolicy), '活动费用版本不存在');
    check(s.accounts && Object.keys(s.accounts).sort().join('') === 'ABCDEFG', '策略账户不完整');
    for (const k of Object.keys(s.accounts)) {
      const a = s.accounts[k];
      check(a.id === s.id + ':' + k && a.strategy === k && integer(a.cash), '独立账户无效');
      check(['lockOriginal', 'aiOnly', 'all'].includes(a.salePolicy), '卖出权限无效');
      check(Array.isArray(a.positions) && Array.isArray(a.orders) && Array.isArray(a.fills) && Array.isArray(a.flows), '账本字段缺失');
      check(Array.isArray(a.events) && Array.isArray(a.marks), '事件或估值记录缺失');
      check(integer(a.lastAt, 1), '账户时间无效');
      for (const p of a.positions) {
        check(key(p.symbol) && ['etf', 'stock'].includes(p.asset) && integer(p.originalQuantity) && Number.isSafeInteger(p.cost), '持仓损坏');
        check(integer(p.tick, 1) && integer(p.lot, 1) && typeof p.tPlusOne === 'boolean', '交易规则损坏');
        check(p.lots.every(l => integer(l.quantity) && typeof l.session === 'string'), '虚拟买入批次损坏');
      }
      check(new Set(a.positions.map(p => p.symbol)).size === a.positions.length, '重复持仓');
      for (const o of a.orders) {
        check(key(o.id) && ['buy', 'sell'].includes(o.side) && integer(o.quantity, 1) && integer(o.remaining) && o.remaining <= o.quantity, '订单损坏');
        check(integer(o.limit, 1) && integer(o.reservedCash) && s.policies.some(p => p.version === o.feeVersion), '订单费用或冻结金额损坏');
      }
      check(new Set(a.orders.map(o => o.id)).size === a.orders.length, '重复订单');
      for (const f of a.flows) check(key(f.id) && integer(f.at, s.seed.at + 1) && integer(Math.abs(f.amount), 1), '资金流损坏');
      for (const f of a.fills) check(integer(f.quantity, 1) && integer(f.gross) && integer(f.fee) && ['buy','sell'].includes(f.side) && key(f.symbol), '成交记录损坏');
      check((a.incomes||[]).every(i=>integer(i.amount)&&integer(i.at,1)&&key(i.id)), '收益流水损坏');
      const ledgerCash = s.seed.cash + sum(a.flows.map(f=>f.amount)) + sum((a.incomes||[]).map(i=>i.amount)) + sum(a.fills.map(f=>f.side==='buy' ? -f.gross-f.fee : f.gross-f.fee));
      check(integer(ledgerCash) && a.cash === ledgerCash, '现金与资金流/成交流水不一致');
      for (const p of a.positions) {
        const initial = s.seed.positions.find(x=>x.symbol===p.symbol)||(s.catalog||{})[p.symbol];
        check(initial && p.originalQuantity <= initial.quantity, '原始持仓来源损坏');
        const balance = initial.quantity + sum(a.fills.filter(f=>f.symbol===p.symbol).map(f=>f.side==='buy'?f.quantity:-f.quantity));
        check(quantity(p) === balance, '持仓与成交流水不一致');
      }
      check(a.cash >= reserved(a), '冻结金额超过现金');
    }
    return true;
  }
  const open = o => ['waiting', 'partial'].includes(o.status);
  const reserved = a => sum(a.orders.filter(open).map(o => o.reservedCash));
  function account(s, code) { check(own(s.accounts, code), '策略账户不存在'); return s.accounts[code]; }
  function position(a, symbol) { const p = a.positions.find(p => p.symbol === symbol); check(p, '标的未确认交易规则'); return p; }
  function advance(a, at) { check(integer(at, 1) && at >= a.lastAt, '禁止时间倒退'); a.lastAt = at; }
  function event(a, type, at, data) { a.events.push(Object.assign({ type, at }, data)); }
  function flow(s, f) {
    check(key(f.id) && integer(f.at, 1) && integer(Math.abs(f.amount), 1), '资金流无效');
    check(!s.flowIDs.includes(f.id), '资金流重复');
    check(f.at >= s.lastFlowAt, '资金流日期倒退');
    for (const a of Object.values(s.accounts)) {
      check(f.at > s.seed.at && (!a.marks.length || f.at > a.marks[a.marks.length-1].at), '资金流必须晚于已有估值；先入金再记录当时估值');
      advance(a, f.at);
      check(a.cash - reserved(a) + f.amount >= 0, '某策略可用现金不足，整组资金流未执行');
      a.cash += f.amount;
      a.flows.push({ id: f.id, at: f.at, amount: f.amount, note: String(f.note || '') });
      event(a, 'externalFlow', f.at, { id: f.id, amount: f.amount });
    }
    s.flowIDs.push(f.id); s.lastFlowAt = f.at;
  }
  function sellable(a, p, session, excluding) {
    // Acquisition dates are absent in old snapshots: lock T+1 original shares
    // until a later session instead of assuming they are already settled.
    let n = a.salePolicy === 'all' && (!p.tPlusOne || session > p.seedSession) ? p.originalQuantity : 0;
    n += sum(p.lots.filter(l => (!p.tPlusOne || l.session < session) && (a.salePolicy!=='aiOnly'||l.origin==='ai')).map(l => l.quantity));
    n -= sum(a.orders.filter(o => o.id !== excluding && open(o) && o.side === 'sell' && o.symbol === p.symbol).map(o => o.remaining));
    return n;
  }
  function submit(s, a, x) {
    advance(a, x.at);
    check(key(x.id) && !a.orders.some(o => o.id === x.id), '订单 ID 无效或重复');
    const p = position(a, x.symbol);
    check(x.origin===undefined||['ai','manual'].includes(x.origin),'订单来源无效');
    check(['buy', 'sell'].includes(x.side) && integer(x.quantity, 1) && x.quantity % p.lot === 0, '订单数量或方向无效');
    check(integer(x.limit, 1) && x.limit % p.tick === 0 && integer(x.expiresAt, x.at + 1), '限价/有效期无效');
    check(/^\d{4}-\d{2}-\d{2}$/.test(x.session || '') && x.session === sessionOf(x.at), '缺少或不匹配的交易所交易日');
    const fp = s.policies.find(p => p.version === s.activePolicy);
    const hold = x.side === 'buy' ? x.quantity * x.limit + fee(fp, p.asset, x.side, x.quantity * x.limit).amount : 0;
    check(integer(hold) && a.cash - reserved(a) >= hold, '虚拟可用现金不足');
    if (x.side === 'sell') check(sellable(a, p, x.session) >= x.quantity, '原始持仓受保护/股份未交收/已冻结');
    const order = { id: x.id, symbol: x.symbol, side: x.side, quantity: x.quantity, remaining: x.quantity,
      limit: x.limit, at: x.at, expiresAt: x.expiresAt, feeVersion: fp.version, reservedCash: hold,
      status: 'waiting', seenBooks: [], lastBookAt: x.at, evidence: clone(x.evidence || []),
      reassess: String(x.reassess || '到期撤单，重新获取证据后评估'), session: x.session, origin:x.origin||'manual' };
    a.orders.push(order); event(a, 'orderSubmitted', x.at, { orderID: order.id });
  }
  function release(a, o, status, at) {
    o.reservedCash = 0; o.status = status; event(a, status, at, { orderID: o.id, remaining: o.remaining });
  }
  function consumePosition(a, p, qty, session) {
    let left = qty;
    // AI lots first, original holdings last. Preserve original provenance.
    for (const l of p.lots) {
      if (p.tPlusOne && l.session >= session) continue;
      if (a.salePolicy==='aiOnly' && l.origin!=='ai') continue;
      const n = Math.min(left, l.quantity); l.quantity -= n; left -= n;
    }
    if (left && a.salePolicy === 'all' && (!p.tPlusOne || session > p.seedSession)) { p.originalQuantity -= left; left = 0; }
    check(left === 0, '卖出权限或交收限制'); p.lots = p.lots.filter(l => l.quantity > 0);
  }
  // One snapshot is processed across ALL active orders of one strategy exactly once;
  // each scenario is an independent counterfactual and has its own liquidity budget.
  function match(s, a, b, now) {
    advance(a, now);
    check(b && key(b.id) && key(b.symbol) && integer(b.at, 1) && b.at <= now && now - b.at <= 5000, '盘口过期或未来数据');
    check(typeof b.session === 'string' && b.session === sessionOf(b.at) && b.isTrading === true, '非有效交易时段或日期不匹配');
    const local = new Date(b.at+8*3600000), weekday=local.getUTCDay(), minute=local.getUTCHours()*60+local.getUTCMinutes();
    check(weekday!==0&&weekday!==6&&((minute>=570&&minute<690)||(minute>=780&&minute<897)), '不在场内连续竞价时段');
    check(!((s.seed.marketCalendar||{}).closedDays||[]).includes(b.session), '已登记的交易所休市日');
    check(['fiveLevel', 'simplified'].includes(b.model), '成交模型必须明确');
    const p = position(a, b.symbol);
    for (const side of ['bids', 'asks']) {
      check(Array.isArray(b[side]) && b[side].length <= 5 && b[side].every(l => integer(l.price, 1) && l.price % p.tick === 0 && integer(l.quantity)), '盘口档位无效');
      check(new Set(b[side].map(l => l.price)).size === b[side].length, '重复价位');
    }
    if (b.model === 'fiveLevel') check(b.bids.length === 5 && b.asks.length === 5, '五档模型必须提供双边五档');
    if (b.bids.length && b.asks.length)
      check(Math.max(...b.bids.map(l => l.price)) < Math.min(...b.asks.map(l => l.price)), '交叉盘口');
    if (b.model === 'simplified') check(typeof b.source === 'string' && b.source.length > 0, '简化模型须标明来源');
    const previous = a.events.filter(e => e.type === 'bookProcessed' && e.symbol === b.symbol);
    check(!previous.some(e => e.bookID === b.id) && previous.every(e => e.bookAt < b.at), '盘口重复或时序倒退');
    const bids = clone(b.bids).sort((x,y) => y.price - x.price), asks = clone(b.asks).sort((x,y) => x.price - y.price);
    const orders = a.orders.filter(o => open(o) && o.symbol === b.symbol).sort((x,y) =>
      x.side === y.side ? (x.side === 'buy' ? y.limit - x.limit : x.limit - y.limit) || x.at - y.at : x.at - y.at);
    for (const o of orders) {
      if (now >= o.expiresAt) { release(a, o, 'expired', now); continue; }
      if (b.at < o.at) continue;
      const fp = s.policies.find(p => p.version === o.feeVersion);
      const levels = o.side === 'buy' ? asks : bids;
      let qty = 0, gross = 0; const taken = [];
      for (const l of levels) {
        const px = l.price + (o.side === 'buy' ? 1 : -1) * p.tick * fp.extraSlippageTicks;
        if (px <= 0 || (o.side === 'buy' ? px > o.limit : px < o.limit)) break;
        const n = Math.min(o.remaining - qty, Math.floor(l.quantity / p.lot) * p.lot);
        if (!n) continue;
        taken.push({ l, n }); qty += n; gross += px * n;
        if (qty === o.remaining) break;
      }
      if (!qty) { event(a, 'waiting', now, { orderID: o.id, bookID: b.id, confidence: b.model === 'fiveLevel' ? 'depthEstimate' : 'low' }); continue; }
      const charge = fee(fp, p.asset, o.side, gross);
      const remaining = o.remaining - qty;
      const nextReserve = o.side === 'buy' && remaining ? o.limit * remaining + fee(fp, p.asset, 'buy', o.limit * remaining).amount : 0;
      if (o.side === 'buy' && a.cash - (reserved(a) - o.reservedCash) < gross + charge.amount + nextReserve) {
        event(a, 'insufficientCashForPartialFees', now, { orderID: o.id }); continue;
      }
      if (o.side === 'sell') {
        if (sellable(a, p, b.session, o.id) < qty || a.cash + gross < charge.amount) continue;
        consumePosition(a, p, qty, b.session); a.cash += gross - charge.amount;
      } else { a.cash -= gross + charge.amount; p.lots.push({ quantity: qty, session: b.session, origin:o.origin||'manual' }); }
      taken.forEach(t => { t.l.quantity -= t.n; });
      o.remaining = remaining; o.reservedCash = nextReserve; o.status = remaining ? 'partial' : 'filled';
      o.seenBooks.push(b.id); o.lastBookAt = b.at;
      const fill = { orderID: o.id, at: now, bookID: b.id, quantity: qty, gross, fee: charge.amount,
        symbol: o.symbol, side: o.side,
        estimatedFee: charge.estimated, feeVersion: fp.version, model: b.model,
        confidence: b.model === 'fiveLevel' ? 'depthEstimate' : 'low', source: String(b.source || '') };
      a.fills.push(fill); event(a, 'fill', now, fill);
    }
    event(a, 'bookProcessed', now, { symbol: b.symbol, bookID: b.id, bookAt: b.at });
  }
  function mark(s, a, x) {
    advance(a, x.at);
    check(x.at > s.seed.at, '估值时间须晚于起点');
    check(x.prices && Object.keys(x.prices).every(k => integer(x.prices[k], 1)), '估值价格无效');
    check(a.positions.filter(p => quantity(p) > 0).every(p => integer(x.prices[p.symbol], 1)), '估值缺少持仓行情');
    check(a.marks.length === 0 || x.at > a.marks[a.marks.length-1].at, '估值日期须递增');
    const equity = a.cash + sum(a.positions.map(p => quantity(p) * (x.prices[p.symbol] || 0)));
    check(integer(equity), '估值溢出');
    a.marks.push({ at: x.at, equity, prices: clone(x.prices) });
  }
  function dispatch(input, action) {
    validate(input); const s = clone(input), x = action;
    check(x && typeof x.type === 'string', '操作无效');
    let a;
    if (x.account !== undefined) a = account(s, x.account);
    switch (x.type) {
      case 'instrument': {
        check(integer(x.at,s.seed.at),'证券登记时间无效');
        const definition=clone(x.definition);check(definition.quantity===0&&definition.cost===0,'新增证券不能注入虚拟持仓或成本');
        const p=instrument(definition);check(!s.seed.positions.some(i=>i.symbol===p.symbol)&&!(s.catalog||{})[p.symbol],'证券已登记');
        s.catalog=s.catalog||{};s.catalog[p.symbol]=definition;p.seedSession=sessionOf(x.at);
        for(const acc of Object.values(s.accounts))acc.positions.push(clone(p));break;
      }
      case 'autonomy': {
        check(typeof x.enabled==='boolean'&&integer(x.intervalMs,60000),'模拟自动执行配置无效');
        s.autonomous={enabled:x.enabled,intervalMs:x.intervalMs,rules:clone(x.rules||{})};break;
      }
      case 'memory': {
        check(key(x.id)&&integer(x.at,1)&&typeof x.text==='string'&&x.text.length<=4000,'偏好记录无效');
        s.memory=s.memory||[];check(!s.memory.some(m=>m.id===x.id),'偏好记录重复');s.memory.push({id:x.id,at:x.at,text:x.text});break;
      }
      case 'recordDividend': {
        check(key(x.id)&&key(x.symbol)&&integer(x.at,s.seed.at+1)&&integer(x.netPerShare)&&integer(x.paymentAt,x.at+1)&&integer(x.publishedAt,1)&&x.publishedAt<=x.at,'登记日分红条款无效');
        s.dividendRecords=s.dividendRecords||{};check(!s.dividendRecords[x.id],'分红登记重复');
        const entitlements={};
        for(const [code,acc] of Object.entries(s.accounts)) { advance(acc,x.at);entitlements[code]=quantity(position(acc,x.symbol)); }
        s.dividendRecords[x.id]={symbol:x.symbol,recordAt:x.at,paymentAt:x.paymentAt,netPerShare:x.netPerShare,entitlements,paid:false};break;
      }
      case 'dividend': {
        const record=(s.dividendRecords||{})[x.id];check(record&&!record.paid&&integer(x.at,record.paymentAt),'分红未登记、未到付款日或重复');
        for(const [code,acc] of Object.entries(s.accounts)) {advance(acc,x.at);const amount=record.entitlements[code]*record.netPerShare;
          check(integer(amount),'分红金额溢出');acc.cash+=amount;acc.incomes=acc.incomes||[];acc.incomes.push({id:x.id,at:x.at,amount,symbol:record.symbol,type:'netDividend'});event(acc,'netDividend',x.at,{id:x.id,amount});}
        record.paid=true;break;
      }
      case 'flow': flow(s, x); break;
      case 'plan':
        check(/^\d{4}-(0[1-9]|1[0-2])$/.test(x.month || '') && integer(x.amount) && typeof x.paused === 'boolean', '月度安排无效');
        s.monthlyPlan[x.month] = { amount: x.amount, paused: x.paused }; break;
      case 'executePlan': {
        check(/^\d{4}-(0[1-9]|1[0-2])$/.test(x.month || '') && new Date(x.at + 8*3600000).toISOString().slice(0,7) === x.month, '执行日期与入金月份不符');
        const plan = s.monthlyPlan[x.month]; check(plan, '月度计划不存在');
        check(!plan.paused && plan.amount > 0, '该月暂停或无入金');
        flow(s, { id: 'monthly:' + x.month, at: x.at, amount: plan.amount, note: '月度计划' }); break;
      }
      case 'salePolicy':
        check(a && ['lockOriginal','aiOnly','all'].includes(x.value), '卖出权限无效');
        check(!a.orders.some(open), '先撤销挂单再更改卖出权限');
        if (['A','B','C'].includes(a.strategy)) check(x.value !== 'all', 'A/B/C 定义禁止卖出原始持仓');
        a.salePolicy = x.value; break;
      case 'feePolicy': {
        const p = policy(x.policy); check(!s.policies.some(q => q.version === p.version), '费用版本不可覆盖');
        s.policies.push(p); s.activePolicy = p.version; break;
      }
      case 'targets':
        check(x.confirmed === true && x.weights && Object.keys(x.weights).every(k => key(k) && integer(x.weights[k])) && sum(Object.values(x.weights)) === 10000, '目标权重须经用户确认且合计 100%');
        check(Object.keys(x.weights).every(k => k==='cash'||s.seed.positions.some(p => p.symbol === k)||(s.catalog||{})[k]), '目标标的尚未确认交易规则');
        s.targets = { weights: clone(x.weights), at: x.at, confirmed: true }; break;
      case 'order': check(a, '缺少策略账户'); submit(s, a, x); break;
      case 'cancel': {
        check(a, '缺少策略账户'); advance(a, x.at); const o = a.orders.find(o => o.id === x.id);
        check(o && open(o), '无可撤销订单'); release(a, o, 'cancelled', x.at); break;
      }
      case 'expire':
        check(a, '缺少策略账户'); advance(a, x.at);
        a.orders.filter(o => open(o) && o.expiresAt <= x.at).forEach(o => release(a, o, 'expired', x.at)); break;
      case 'book': check(a, '缺少策略账户'); match(s, a, x.book, x.at); break;
      case 'mark': check(a, '缺少策略账户'); mark(s, a, x); break;
      default: fail('操作未实现');
    }
    validate(s); return s;
  }
  // Returns proposals only. Never submits orders, even for strategy G.
  function proposals(s, code, at, prices) {
    validate(s); const a = account(s, code);
    check(integer(at, s.seed.at), '建议时间无效');
    if (code === 'A') return { status: 'cashOnly', proposals: [] };
    if (['E','F','G'].includes(code)) return { status: 'needsEvidenceAndStrategyImplementation', proposals: [] };
    if (code === 'C' && !s.targets) return { status: 'needsUserConfirmedTargets', proposals: [] };
    check(a.positions.every(p => integer(prices[p.symbol], 1)||(quantity(p)===0&&!(s.targets?.weights[p.symbol]>0))), '建议缺少估值行情');
    const base = sum(s.seed.positions.map(p => p.quantity * p.price));
    if (!base && !s.targets) return { status: 'needsAllocation', proposals: [] };
    const weights = code === 'B' ? Object.fromEntries(s.seed.positions.map(p => [p.symbol, p.quantity * p.price / base])) :
      s.targets ? Object.fromEntries(Object.entries(s.targets.weights).map(([k,v]) => [k,v/10000])) :
        Object.fromEntries(s.seed.positions.map(p => [p.symbol,p.quantity * p.price / base]));
    const cash = a.cash - reserved(a);
    const equity = a.cash + sum(a.positions.map(p => quantity(p) * (prices[p.symbol]||0)));
    const fp = s.policies.find(p => p.version === s.activePolicy);
    const rows = [];
    for (const p of a.positions) {
      const px = prices[p.symbol], weight = weights[p.symbol] || 0;
      if(!integer(px,1))continue;
      let budget = code === 'D' ? equity * weight - quantity(p) * px : Math.min(cash, Math.max(0, sum(a.flows.map(f => f.amount)))) * weight;
      if (code !== 'D') {
        const contribution = Math.max(0, sum(a.flows.map(f=>f.amount)));
        const spent = sum(a.fills.filter(f=>f.symbol===p.symbol && f.side==='buy').map(f=>f.gross+f.fee));
        const pending = sum(a.orders.filter(o=>o.symbol===p.symbol && o.side==='buy' && open(o)).map(o=>o.reservedCash));
        budget = Math.min(cash, Math.max(0, contribution*weight-spent-pending));
      }
      const side = budget < 0 ? 'sell' : 'buy';
      let q = Math.floor(Math.abs(budget) / px / p.lot) * p.lot;
      if (side === 'buy') while (q > 0 && q * px + fee(fp, p.asset, side, q * px).amount > Math.abs(budget)) q -= p.lot;
      if (q) rows.push({ symbol: p.symbol, side, quantity: q, referencePrice: px,
        requiresUserReview: true, strategy: code, evidenceAt: at });
    }
    return { status: 'proposalsOnly', proposals: rows, note: '需明确限价、有效期和规则；不会自动挂单。D 的卖出建议仍受交收和权限约束。' };
  }
  function metrics(s, code) {
    validate(s); return calculateMetrics(s.initialValue, s.seed.at, account(s, code));
  }
  function metricsSeries(initialValue, initialAt, marks, flows) {
    check(integer(initialValue,1)&&integer(initialAt,1)&&Array.isArray(marks)&&Array.isArray(flows),'绩效输入无效');
    check(marks.every((m,i)=>integer(m.at,initialAt+1)&&integer(m.equity)&&(i===0||m.at>marks[i-1].at)),'估值序列无效');
    check(flows.every(f=>integer(f.at,initialAt+1)&&Number.isSafeInteger(f.amount)&&f.amount!==0),'资金流序列无效');
    return calculateMetrics(initialValue,initialAt,{marks,flows});
  }
  function calculateMetrics(initialValue, initialAt, a) {
    if (!a.marks.length || initialValue <= 0) return { status: 'insufficientValuations' };
    const end = a.marks[a.marks.length-1];
    let prevAt = initialAt, prevValue = initialValue, growth = 1, peak = 1, drawdown = 0;
    const returns = [];
    for (const m of a.marks) {
      const fs = a.flows.filter(f => f.at > prevAt && f.at <= m.at);
      // Exact chain-link TWR requires a valuation immediately before every external flow.
      if (fs.some(f => f.at !== m.at)) return { status: 'needsPreFlowValuations', netContributions: sum(a.flows.filter(f => f.at <= end.at).map(f => f.amount)) };
      const external = sum(fs.map(f => f.amount));
      const r = (m.equity - external) / prevValue - 1;
      if (!Number.isFinite(r) || r < -1 || prevValue <= 0) return { status: 'undefinedReturn' };
      growth *= 1+r; peak = Math.max(peak, growth); drawdown = Math.min(drawdown, growth/peak - 1);
      returns.push(r); prevAt = m.at; prevValue = m.equity;
    }
    const flows = a.flows.filter(f => f.at <= end.at);
    const cf = [{ at: initialAt, amount: -initialValue }, ...flows.map(f => ({at:f.at, amount:-f.amount})), {at:end.at,amount:end.equity}];
    const roots = xirr(cf);
    const mean = sum(returns)/returns.length;
    const sd = returns.length > 1 ? Math.sqrt(sum(returns.map(r => (r-mean)**2))/(returns.length-1)) : null;
    return { status: 'ok', asOf: end.at, initialValue: initialValue, equity: end.equity,
      netContributions: sum(flows.map(f => f.amount)), profit: end.equity - initialValue - sum(flows.map(f => f.amount)),
      timeWeightedReturn: growth-1, moneyWeightedAnnualReturn: roots.length === 1 ? roots[0] : null,
      moneyWeightedStatus: roots.length === 1 ? 'uniqueInSearchRange' : roots.length ? 'ambiguous' : 'noRoot',
      maxDrawdown: drawdown, periodVolatility: sd,
      riskNote: '波动为估值区间收益标准差，未年化；回撤仅覆盖采样估值点。TWR 要求资金流前估值。' };
  }
  // Scan log(1+r), bracket ALL observed roots in a declared finite range.
  function xirr(flows) {
    if (flows.length < 2) return [];
    const start = Math.min(...flows.map(f=>f.at)), span = Math.max(...flows.map(f=>f.at))-start;
    if (span < DAY) return [];
    const f = y => sum(flows.map(c => c.amount * Math.exp(-y * (c.at-start)/(365*DAY))));
    const roots = []; let lo = -13.815510557964274, flo = f(lo);
    for (let n = 1; n <= 1000; n++) {
      const hi = -13.815510557964274 + n*(23.025850929940457/1000), fhi = f(hi);
      if (flo*fhi < 0 || flo === 0) {
        let l=lo, h=hi, fl=flo;
        for(let i=0;i<80;i++) { const mid=(l+h)/2, fm=f(mid); if(fl*fm<=0) h=mid; else {l=mid;fl=fm;} }
        const r=Math.expm1((l+h)/2);
        if(!roots.some(old=>Math.abs(old-r)<1e-7)) roots.push(r);
      }
      lo=hi;flo=fhi;
    }
    return roots;
  }
  function compare(s) {
    const a = Object.values(s.accounts), dates = a.map(a => a.marks.map(m => m.at).join(','));
    const flows = a.map(a => JSON.stringify(a.flows));
    check(new Set(dates).size === 1 && new Set(flows).size === 1, '比较日期或外部资金流不一致');
    return Object.fromEntries(Object.keys(s.accounts).map(k => [k, metrics(s,k)]));
  }
  function opportunity(s, code, orderID, price, at) {
    validate(s); const a=account(s,code), o=a.orders.find(o=>o.id===orderID);
    check(o && integer(price,1) && integer(at,o.at), '机会成本输入无效');
    return { remaining: o.remaining, status:o.status, referenceAt:at,
      signedOpportunityCost: (o.side==='buy' ? price-o.limit : o.limit-price)*o.remaining,
      note:'相对于限价的事后价格差，不是已实现损益，也未声称限价必定可成交。' };
  }
  const api = { create, dispatch, validate, defaultPolicy, fee, strategies, proposals, metrics, metricsSeries, compare, opportunity, xirr, UNIT };
  root.LabCore=api;
  // Swift bridge uses a single string boundary, avoiding implicit JS NSNumber conversions.
  root.labCall=function(json) {
    try { const r=JSON.parse(json); check(own(api,r.method),'未知调用'); const fn=api[r.method]; check(typeof fn==='function','未知调用');
      return JSON.stringify({ok:true,value:fn.apply(null,r.args)}); }
    catch(e) { return JSON.stringify({ok:false,error:String(e.message||e)}); }
  };
  if(typeof module!=='undefined' && module.exports) module.exports=api;
})(typeof globalThis!=='undefined' ? globalThis : this);
