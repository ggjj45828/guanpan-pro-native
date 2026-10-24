"""组合网格「档位计划」引擎（NAS 后台按真实持仓算）。

**这里没有虚拟账户**：不记虚拟现金、不记虚拟持仓、不算模拟盈亏。
网格只做一件事——按你真实持仓与真实现金，算出「价格走到某个位置该挂多少买卖单」，
并把「价格触及过哪一档」记成观察日志。它永远不改账本，也不产生任何"模拟成交收益"。

设计取舍：
1. 每只真实持仓一份计划，新增标的自动纳入、清仓自动移出（sync_with_book）。
2. 参数从数据来，不拍脑袋：锚点=上一交易日收盘；步长=近 20 日日内振幅中位数×0.25
   与「手续费地板」的较大者，限在 0.25%–1%；档数由「可用手数」反推（不是固定 4 档）。
3. 触达按报价逐次比较，只记观察日志（touches），不改现金、不改持仓。
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

CASH_TOLERANCE = Decimal("0.01")
DEFAULT_FEE = Decimal("0.10")
LEVELS = 3
MAX_TOUCHES = 400
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
    """网格状态里只有「计划 + 触达日志」，没有任何虚拟资金/虚拟持仓字段。"""
    return {"version": 2, "createdAt": None, "day": None,
            "deployableCash": Decimal("0"), "reservedCash": Decimal("0"),
            "plans": {}, "touches": [], "skipped": []}


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
    """按真实账本算一份网格计划（**不建虚拟账户**）。

    只读：持仓份额、账本现金、行情、日 K。产出每只标的的锚点/步长/档数/每档份额，
    外加「计划占用多少现金、最多卖出多少份额」。不写任何虚拟资金、虚拟持仓。
    """
    now = now or datetime.now(timezone.utc)
    state = empty_state()
    state["createdAt"] = now.isoformat()
    cash_total = _d(book.get("cash"))
    reserved = (cash_total * CASH_RESERVE_RATIO).quantize(Decimal("0.01"))
    plans, skipped = {}, []
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
        plan.update({"units": units, "baseUnits": units, "lastPrice": price})
        plans[code] = plan
    state["deployableCash"] = cash_total - reserved
    state["reservedCash"] = reserved
    state["plans"] = plans
    state["skipped"] = skipped
    state["day"] = now.astimezone().date().isoformat()
    return state


def tick(state, quotes, now=None):
    """推进一次：只记录「价格触及了哪一档」，不改现金、不改持仓、不产生收益。

    返回 (state, 本次新记的触达)。真正的成交只发生在券商，用户自己回 App 确认。
    """
    now = now or datetime.now(timezone.utc)
    touches = []
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
        previous_price = _d(plan.get("lastPrice")) or price
        if anchor <= 0 or shares_per_rung <= 0:
            plan["lastPrice"] = price
            continue
        for level in range(1, levels + 1):
            buy_level = anchor * (Decimal(1) - step) ** level
            sell_level = anchor * (Decimal(1) + step) ** level
            # 只有「上一笔价格在这一档之上、现在跌到档位」才算一次触达，
            # 避免价格在档位附近来回抖动时同一档重复记录。
            if previous_price > buy_level >= price:
                touches.append({"code": code, "side": "buy", "level": level, "price": str(price),
                                "units": shares_per_rung, "at": now.isoformat()})
            elif previous_price < sell_level <= price:
                touches.append({"code": code, "side": "sell", "level": level, "price": str(price),
                                "units": shares_per_rung, "at": now.isoformat()})
        plan["lastPrice"] = price
    if touches:
        state["touches"] = (list(state.get("touches") or []) + touches)[-MAX_TOUCHES:]
    return state, touches


def plan_metrics(plan, fee=DEFAULT_FEE):
    """单只标的的计划口径：计划占用现金、最多卖出份额、单档往返净收益。"""
    anchor = _d(plan.get("anchor"))
    step = _d(plan.get("step")) or STEP_MIN
    levels = int(plan.get("levels") or 0)
    shares = int(plan.get("sharesPerRung") or 0)
    fee = _d(plan.get("fee"), str(fee))
    buy_capital = Decimal("0")
    for level in range(1, levels + 1):
        buy_capital += anchor * (Decimal(1) - step) ** level * Decimal(shares)
    sell_units = levels * shares
    sell_value = Decimal("0")
    for level in range(1, levels + 1):
        sell_value += anchor * (Decimal(1) + step) ** level * Decimal(shares)
    # 单档往返：买入一档、再卖出一档（相邻档）扣掉两次手续费后的净收益。
    gross = anchor * step * Decimal(shares)
    net = gross - fee * 2
    return {"buyCapital": buy_capital.quantize(Decimal("0.01")),
            "sellUnits": sell_units,
            "sellValue": sell_value.quantize(Decimal("0.01")),
            "grossPerRung": gross.quantize(Decimal("0.01")),
            "netPerRung": net.quantize(Decimal("0.01")),
            "feePerRung": (fee * 2).quantize(Decimal("0.01"))}


def summary(state, quotes):
    """网格计划的整体口径。**没有任何"累计盈亏/虚拟本金"字段。**"""
    plans = state.get("plans") or {}
    cash = _d(state.get("deployableCash"))
    reserved = _d(state.get("reservedCash"))
    touches = state.get("touches") or []
    today = datetime.now(timezone.utc).astimezone().date().isoformat()
    buy_capital = Decimal("0")
    sell_units = 0
    net_per_rung = Decimal("0")
    fee_per_rung = Decimal("0")
    rows = []
    for code, plan in plans.items():
        metrics = plan_metrics(plan)
        buy_capital += metrics["buyCapital"]
        sell_units += metrics["sellUnits"]
        net_per_rung += metrics["netPerRung"]
        fee_per_rung += metrics["feePerRung"]
        quote = quotes.get(code) or {}
        price = _d(quote.get("price")) or _d(plan.get("lastPrice"))
        rows.append({"code": code,
                     "anchor": str(_d(plan.get("anchor"))),
                     "stepPercent": str(_d(plan.get("step")) * 100),
                     "levels": int(plan.get("levels") or 0),
                     "sharesPerRung": int(plan.get("sharesPerRung") or 0),
                     "units": int(plan.get("units") or 0),
                     "price": str(price),
                     "buyCapital": str(metrics["buyCapital"]),
                     "sellUnits": metrics["sellUnits"],
                     "netPerRung": str(metrics["netPerRung"])})
    return {
        "mode": "plan-only",
        "holdingsCovered": len(plans),
        "plannedBuyCapital": str(buy_capital.quantize(Decimal("0.01"))),
        "plannedSellUnits": sell_units,
        "deployableCash": str(cash),
        "reservedCash": str(reserved),
        "netPerRungTotal": str(net_per_rung.quantize(Decimal("0.01"))),
        "feePerRungTotal": str(fee_per_rung.quantize(Decimal("0.01"))),
        "todayTouches": sum(1 for t in touches if (t.get("at") or "")[:10] == today),
        "cashEnoughForAllBuys": cash >= buy_capital,
        "skipped": state.get("skipped") or [],
        "plans": rows,
    }


def sync_with_book(state, book, quotes, bars_by_code, fee=DEFAULT_FEE):
    """让网格计划跟上真实账本的持仓变化（新增标的、加仓、清仓、现金变动）。

    只同步「有哪些标的、各有多少份额、可用现金多少」；不保存任何虚拟持仓/虚拟现金。
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
            built.update({"units": units, "baseUnits": units, "lastPrice": price})
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

    # 现金：账本全部现金，按预留比例拆成可部署 + 预留（只是额度，不是虚拟资金账户）。
    cash_total = _d(book.get("cash"))
    reserved = (cash_total * CASH_RESERVE_RATIO).quantize(Decimal("0.01"))
    state["deployableCash"] = cash_total - reserved
    state["reservedCash"] = reserved
    state["plans"] = plans
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
    cash = _d(state.get("deployableCash"))
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
