"""组合网格引擎（NAS 后台按真实持仓自动跑）。

设计取舍写在这里，避免以后又改回去：

1. **不用 A–H 那种抽象策略**。只有一套「按你当前持仓做 T」的网格：每只持仓一份，
   新增标的自动纳入、清仓自动移出。起点权益 = 你账本的总资产，所以两条曲线可比。
2. **只做模拟，不碰真实账本**。它读 real_books 的持仓与现金，写入自己的 grid_state。
3. **参数从数据来，不拍脑袋**：锚点取上一交易日收盘，步长取「近 20 日日内振幅中位数 × 0.25」
   与「手续费地板」的较大者，并限在 0.25%–1%；每边 3 档，每格资金 = 该标的市值 / (2×档数+2)。
4. **触发按报价逐次比较**（不是按分钟 K 线补齐），因为 NAS 上报价是实时的，分时档案有缺采。

数据结构全部放在 grid_state 一行 JSON 里：plans / cash / fills / daily，条数都有上限。
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

CASH_TOLERANCE = Decimal("0.01")
DEFAULT_FEE = Decimal("0.10")
MAX_FILLS = 400
MAX_DAYS = 400
LEVELS = 3
STEP_MIN = Decimal("0.0025")
STEP_MAX = Decimal("0.01")
# 现金预留比例：网格只拿 (1 - 该比例) 的现金去挂买单，剩下永久不部署，作备用弹药。
CASH_RESERVE_RATIO = Decimal("0.20")


def _d(value, default="0"):
    try:
        result = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return Decimal(default)
    return result if result.is_finite() else Decimal(default)


def empty_state():
    return {"version": 1, "createdAt": None, "day": None, "cash": Decimal("0"),
            "reservedCash": Decimal("0"), "startEquity": Decimal("0"), "equity": Decimal("0"),
            "plans": {}, "fills": [], "daily": []}


def _median(values):
    if not values:
        return None
    ordered = sorted(values)
    mid = len(ordered) // 2
    return ordered[mid] if len(ordered) % 2 else (ordered[mid - 1] + ordered[mid]) / 2


def daily_range_median(bars, days=20):
    """近 N 个交易日的日内振幅中位数 (high-low)/mid。bars 需按日期升序。"""
    ranges = []
    for row in bars[-days:]:
        high, low = _d(row.get("high")), _d(row.get("low"))
        if high > 0 and low > 0 and high >= low:
            mid = (high + low) / 2
            if mid > 0:
                ranges.append(float((high - low) / mid))
    return _median(ranges)


def plan_for(anchor, capital, step_hint=None, fee=DEFAULT_FEE, lot=100, levels=LEVELS):
    """给一只标的算网格参数。资金不够一档就不建计划（返回 None）。"""
    anchor = _d(anchor)
    capital = _d(capital)
    if anchor <= 0 or capital <= 0 or lot <= 0:
        return None
    fee_floor = float(2 * _d(fee) / (anchor * lot)) + 0.001
    base = max(step_hint or 0.0, fee_floor)
    step = min(float(STEP_MAX), max(float(STEP_MIN), base))
    share_lot_cost = anchor * lot
    if share_lot_cost <= 0:
        return None
    # 按「手数」而不是「金额平分」定档：小仓位也得能建出可执行的网格。
    # 6 千元以内的单只持仓，通常只够 1 档 × 1 手 —— 这是真实约束，不美化。
    total_lots = int(capital // share_lot_cost)
    if total_lots < 2:
        return None
    levels = max(1, min(levels, (total_lots - 1) // 2))
    per_lots = max(1, total_lots // (levels * 2 + 1))
    shares = per_lots * lot
    return {"anchor": anchor, "step": Decimal(str(round(step, 6))), "levels": levels,
            "sharesPerRung": shares, "fee": _d(fee), "lot": lot}


def build(book, quotes, bars_by_code, now=None, fee=DEFAULT_FEE):
    """按真实账本重建一份网格账户。quotes: {code: {price, previousClose}}。"""
    now = now or datetime.now(timezone.utc)
    state = empty_state()
    state["createdAt"] = now.isoformat()
    cash_total = _d(book.get("cash"))
    reserved = (cash_total * CASH_RESERVE_RATIO).quantize(Decimal("0.01"))
    cash = cash_total - reserved
    plans, equity, skipped = {}, cash, []
    for position in book.get("positions") or []:
        code = position.get("code")
        units = int(position.get("units") or 0)
        if not code or units <= 0:
            continue
        quote = quotes.get(code) or {}
        price = _d(quote.get("price"))
        previous = _d(quote.get("previousClose"))
        if price <= 0:
            price = _d(position.get("bookCost")) / Decimal(units)
        if previous <= 0:
            previous = price
        capital = price * Decimal(units)
        plan = plan_for(previous, capital, daily_range_median(bars_by_code.get(code, [])), fee=fee)
        if not plan:
            # 不够一手（比如 113 元持仓、一手要 120 元）就老实跳过，
            # 不建一个"每档 0 股"的假计划 —— 那种计划在界面上只会让人困惑。
            skipped.append({"code": code,
                            "reason": f"市值 ¥{capital:.2f} 不足一手（100 份约 ¥{previous * 100:.0f}），无法分档"})
            continue
        plan.update({"units": units, "baseUnits": units, "lastPrice": price,
                     "buys": 0, "sells": 0, "fees": Decimal("0")})
        plans[code] = plan
        equity += capital
    state["cash"] = cash
    state["reservedCash"] = reserved
    state["plans"] = plans
    state["equity"] = equity
    # 起点权益 = 账本总资产（持仓市值 + 全部现金），与文件头注释一致；
    # 含预留现金，确保未交易时当日盈亏为 0。
    state["startEquity"] = equity_of(state, quotes) + reserved
    state["skipped"] = skipped
    state["day"] = now.astimezone().date().isoformat()
    return state


def tick(state, quotes, now=None):
    """推进一次：价格跨过档位就成交。返回 (state, 本次成交列表)。"""
    now = now or datetime.now(timezone.utc)
    fills = []
    cash = _d(state.get("cash"))
    plans = state.get("plans") or {}
    for code, plan in plans.items():
        quote = quotes.get(code) or {}
        price = _d(quote.get("price"))
        if price <= 0:
            continue
        anchor = _d(plan.get("anchor"))
        step = _d(plan.get("step")) or STEP_MIN
        levels = int(plan.get("levels") or LEVELS)
        shares_per_rung = int(plan.get("sharesPerRung") or 0)
        fee = _d(plan.get("fee"), str(DEFAULT_FEE))
        previous_price = _d(plan.get("lastPrice")) or price
        units = int(plan.get("units") or 0)
        if anchor <= 0 or shares_per_rung <= 0:
            plan["lastPrice"] = price
            continue
        for level in range(1, levels + 1):
            buy_level = anchor * (Decimal(1) - step) ** level
            sell_level = anchor * (Decimal(1) + step) ** level
            # 只有「上一笔价格在这一档之上、现在跌到档位」才算一次触发，
            # 避免价格在档位附近来回抖动时同一档重复成交。
            if previous_price > buy_level >= price:
                cost = price * shares_per_rung + fee
                if cash >= cost:
                    cash -= cost
                    units += shares_per_rung
                    plan["fees"] = _d(plan.get("fees")) + fee
                    plan["buys"] = int(plan.get("buys") or 0) + 1
                    fills.append({"code": code, "side": "buy", "level": level, "price": price,
                                  "units": shares_per_rung, "fee": fee, "at": now.isoformat()})
            elif previous_price < sell_level <= price:
                if units >= shares_per_rung:
                    cash += price * shares_per_rung - fee
                    units -= shares_per_rung
                    plan["fees"] = _d(plan.get("fees")) + fee
                    plan["sells"] = int(plan.get("sells") or 0) + 1
                    fills.append({"code": code, "side": "sell", "level": level, "price": price,
                                  "units": shares_per_rung, "fee": fee, "at": now.isoformat()})
        plan["units"] = units
        plan["lastPrice"] = price
    state["cash"] = cash
    state["equity"] = equity_of(state, quotes)
    if fills:
        history = list(state.get("fills") or []) + fills
        state["fills"] = history[-MAX_FILLS:]
    return state, fills


def equity_of(state, quotes):
    total = _d(state.get("cash"))
    for code, plan in (state.get("plans") or {}).items():
        quote = quotes.get(code) or {}
        price = _d(quote.get("price")) or _d(plan.get("lastPrice"))
        total += price * Decimal(int(plan.get("units") or 0))
    return total


def mark_day(state, quotes, day=None, now=None):
    """收盘记一条净值。同一天重复调用只更新最后一条。"""
    now = now or datetime.now(timezone.utc)
    day = day or now.astimezone().date().isoformat()
    equity = equity_of(state, quotes)
    state["equity"] = equity
    daily = [row for row in state.get("daily") or [] if row.get("day") != day]
    cash = _d(state.get("cash"))
    holdings = {}
    for code, plan in (state.get("plans") or {}).items():
        quote = quotes.get(code) or {}
        price = _d(quote.get("price")) or _d(plan.get("lastPrice"))
        holdings[code] = {"units": int(plan.get("units") or 0), "price": str(price)}
    daily.append({"day": day, "equity": str(equity), "cash": str(cash + _d(state.get("reservedCash"))), "holdings": holdings})
    daily.sort(key=lambda row: row.get("day") or "")
    state["daily"] = daily[-MAX_DAYS:]
    state["day"] = day
    return state


def summary(state, quotes):
    plans = state.get("plans") or {}
    start = _d(state.get("startEquity"))
    reserved = _d(state.get("reservedCash"))
    equity = equity_of(state, quotes) + reserved  # 含预留现金的总资产
    cash_total = _d(state.get("cash")) + reserved
    fills = state.get("fills") or []
    today = (state.get("daily") or [{}])[-1].get("day")
    today_fills = [f for f in fills if (f.get("at") or "")[:10] == (today or "")]
    return {
        "startEquity": str(start),
        "equity": str(equity),
        "cash": str(cash_total),
        "reservedCash": str(reserved),
        "pnl": str(equity - start),
        "pnlPercent": str((equity - start) / start * 100) if start > 0 else "0",
        "fees": str(sum((_d(p.get("fees")) for p in plans.values()), Decimal("0"))),
        "buys": sum(int(p.get("buys") or 0) for p in plans.values()),
        "sells": sum(int(p.get("sells") or 0) for p in plans.values()),
        "todayFills": len(today_fills),
        "days": len(state.get("daily") or []),
        "plans": [{"code": code,
                   "anchor": str(p.get("anchor")),
                   "stepPercent": str(_d(p.get("step")) * 100),
                   "levels": int(p.get("levels") or 0),
                   "sharesPerRung": int(p.get("sharesPerRung") or 0),
                   "units": int(p.get("units") or 0),
                   "buys": int(p.get("buys") or 0),
                   "sells": int(p.get("sells") or 0),
                   "fees": str(_d(p.get("fees")))} for code, p in plans.items()],
    }


def sync_with_book(state, book, quotes, bars_by_code, fee=DEFAULT_FEE):
    """让网格账户跟上真实账本的持仓变化（新增标的、加仓、清仓）。

    startEquity 始终 = 账本总资产（持仓市值 + 全部现金），由持仓与现金直接重算，
    不再用「注资/提现」增量调整 —— 那样无法区分「用现有现金买入」与「真的存入新钱」，
    会让收益率虚高或虚低。现金按 CASH_RESERVE_RATIO 拆成可部署与预留两部分。
    """
    plans = state.get("plans") or {}
    positions = {}
    for position in book.get("positions") or []:
        code = position.get("code")
        units = int(position.get("units") or 0)
        if code and units > 0:
            positions[code] = units

    added, removed = [], []

    for code, units in positions.items():
        quote = quotes.get(code) or {}
        price = _d(quote.get("price")) or _d(quote.get("previousClose"))
        if price <= 0:
            continue
        plan = plans.get(code)
        if not plan:
            capital = price * Decimal(units)
            built = plan_for(_d(quote.get("previousClose")) or price, capital,
                             daily_range_median(bars_by_code.get(code, [])), fee=fee)
            if not built:
                continue
            built.update({"units": units, "baseUnits": units, "lastPrice": price,
                          "buys": 0, "sells": 0, "fees": Decimal("0")})
            plans[code] = built
            added.append(code)
            continue
        base = int(plan.get("baseUnits") or 0)
        if units != base:
            delta = units - base
            plan["units"] = int(plan.get("units") or 0) + delta
            plan["baseUnits"] = units
            added.append(code)

    for code in list(plans.keys()):
        if code in positions:
            continue
        plans.pop(code, None)
        removed.append(code)

    # 现金：账本全部现金，按预留比例拆成可部署 + 预留。
    cash_total = _d(book.get("cash"))
    reserved = (cash_total * CASH_RESERVE_RATIO).quantize(Decimal("0.01"))
    state["cash"] = cash_total - reserved
    state["reservedCash"] = reserved
    state["plans"] = plans
    # 总资产 = 持仓市值（含可部署现金） + 预留现金
    state["startEquity"] = equity_of(state, quotes) + reserved
    if added or removed:
        state["lastSync"] = {"added": added, "removed": removed}
    return state


def ladder(state, quotes):
    """明天的挂单表 —— 这才是网格真正的"未来指导"。

    网格不预测涨跌，它只回答一件事：**如果明天价格走到某个位置，我该买多少/卖多少**。
    所以这里给出每只标的的完整档位（价格 + 方向 + 数量），以及：
      - 当前价落在第几档（nowLevel）
      - 往下还能买几档（受现金约束）、往上还能卖几档（受持仓约束）
      - 跌破最低买档 / 涨过最高卖档 时的越界提示
    这些是条件单，不是预测；价格不到就不成交。
    """
    rows = []
    cash = _d(state.get("cash"))
    for code, plan in (state.get("plans") or {}).items():
        anchor = _d(plan.get("anchor"))
        step = _d(plan.get("step")) or STEP_MIN
        levels = int(plan.get("levels") or LEVELS)
        per_rung = int(plan.get("sharesPerRung") or 0)
        fee = _d(plan.get("fee"), str(DEFAULT_FEE))
        units = int(plan.get("units") or 0)
        quote = quotes.get(code) or {}
        price = _d(quote.get("price")) or _d(plan.get("lastPrice"))
        if anchor <= 0 or per_rung <= 0:
            continue

        rungs = []
        # 卖档从高到低排，买档从高到低排，合成一条从"最高卖价"到"最低买价"的梯子
        for level in range(levels, 0, -1):
            sell_price = anchor * (Decimal(1) + step) ** level
            rungs.append({"side": "sell", "level": level, "price": sell_price, "units": per_rung,
                          "reachable": units >= per_rung})
        for level in range(1, levels + 1):
            buy_price = anchor * (Decimal(1) - step) ** level
            rungs.append({"side": "buy", "level": level, "price": buy_price, "units": per_rung,
                          "reachable": cash >= buy_price * per_rung + fee})

        # 当前价落在哪一档之间
        position = 0
        for rung in rungs:
            if price < rung["price"]:
                position += 1
            else:
                break
        buys_left = sum(1 for r in rungs if r["side"] == "buy" and r["price"] < price and r["reachable"])
        sells_left = sum(1 for r in rungs if r["side"] == "sell" and r["price"] > price and r["reachable"])

        rows.append({
            "code": code,
            "price": str(price),
            "anchor": str(anchor),
            "stepPercent": str(_d(step) * 100),
            "position": position,
            "buysLeft": buys_left,
            "sellsLeft": sells_left,
            "cashEnoughFor": buys_left,
            "rungs": [{"side": r["side"], "level": r["level"], "price": str(r["price"].quantize(Decimal("0.001"))),
                       "units": r["units"], "reachable": r["reachable"]} for r in rungs],
            "note": ("跌破最低买档，网格会用完现金后停止" if buys_left == 0 and sells_left == 0 else
                     "现金只够再买 %d 档" % buys_left if buys_left < levels else
                     "持仓只够再卖 %d 档" % sells_left if sells_left < levels else "档位充足"),
        })
    rows.sort(key=lambda row: -(float(row["price"]) if row["price"] else 0))
    return rows
