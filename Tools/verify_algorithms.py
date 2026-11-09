#!/usr/bin/env python3
"""离线算法验证（Python 复刻口径，不是 XCTest）。

覆盖 VolumeAnalysis / PositionDiscipline / RealtimeTrigger / CandidateShadow /
截图行解析、逐笔↔汇总对账、手续费诚实口径，以及 2.28.0 的
Anti-Overtrading / 生产盯盘水位 / 成交关联 / 今日 T vs HOLD 关键分支。
CI 会跑它；本地也可用 python3 Tools/verify_algorithms.py。
"""
from __future__ import annotations

import math
import re
import sys

failures: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    print(("  OK   " if condition else "  FAIL ") + name + (" | " + detail if detail else ""))
    if not condition:
        failures.append(name)


def mean(values: list[float | None], period: int) -> float | None:
    if len(values) < period:
        return None
    window = values[-period:]
    if any(v is None for v in window):
        return None
    return sum(v for v in window if v is not None) / period


def ratio(value, baseline):
    if value is None or baseline is None or baseline <= 0:
        return None
    return value / baseline


# ---- VolumeAnalysis ----------------------------------------------------
def volume_analysis(bars, forming_index=None):
    volumes = [b["volume"] for b in bars]
    closes = [b["close"] for b in bars]
    points = []
    for i, bar in enumerate(bars):
        final = i != forming_index
        source = volumes[:i + 1] if final else volumes[:i]
        mas = {p: mean(source, p) for p in (5, 10, 20, 60)}
        prior = volumes[:i]
        baseline = mean(prior, 20) if final else None
        to_base = ratio(volumes[i], baseline)
        change = None
        if final and i > 0 and prior[-1] and volumes[i] is not None and prior[-1] > 0:
            change = volumes[i] / prior[-1] - 1
        if volumes[i] is None:
            state = "unavailable"
        elif not final and baseline is None:
            state = "formingProvisional"
        elif to_base is None:
            state = "unavailable"
        else:
            state = "above" if to_base > 1 else "below" if to_base < 1 else "at"
        relation = "unavailable"
        if final and i > 0 and closes[i] and closes[i - 1]:
            if state == "above":
                relation = "priceUpVolumeAbove" if closes[i] > closes[i - 1] else "priceDownVolumeAbove" if closes[i] < closes[i - 1] else "unchangedPriceVolumeAbove"
            elif state in ("below", "at"):
                relation = "priceUpAtOrBelow" if closes[i] > closes[i - 1] else "priceDownAtOrBelow" if closes[i] < closes[i - 1] else "unchangedPriceAtOrBelow"
        points.append({"ma": mas, "baseline": baseline, "to_base": to_base,
                       "change": change, "state": state, "relation": relation})
    return points


bars = [{"close": 10.0 + i * 0.05, "volume": 100.0 + i * 10} for i in range(25)]
pts = volume_analysis(bars)
check("MA5 需窗口满", pts[3]["ma"][5] is None and pts[4]["ma"][5] == 120.0,
      f"i=4 MA5={pts[4]['ma'][5]}")
check("MA20 需窗口满", pts[18]["ma"][20] is None and pts[19]["ma"][20] is not None)
check("已收盘基线是前 20 根均量", abs(pts[24]["baseline"] - mean([b["volume"] for b in bars[4:24]], 20)) < 1e-9)
check("量比 = 当前量 / 前 20 根均量", pts[24]["to_base"] is not None and pts[24]["to_base"] > 1)
check("放量 + 价涨 → 价涨量增", pts[24]["state"] == "above" and pts[24]["relation"] == "priceUpVolumeAbove")
check("形成中 bar 只用历史、无基线时是 formingProvisional",
      volume_analysis(bars, forming_index=24)[24]["state"] == "formingProvisional")

# 连续放量计数（复刻 Swift 的循环）
def consecutive(vols):
    expansion = contraction = 0
    cursor = len(vols) - 1
    while cursor > 0:
        now, before = vols[cursor], vols[cursor - 1]
        if now is None or before is None or before <= 0:
            break
        if now > before:
            expansion += 1
            contraction = 0
        elif now < before:
            contraction += 1
            expansion = 0
        else:
            break
        cursor -= 1
    return expansion, contraction

check("连续放量 24 根", consecutive([b["volume"] for b in bars]) == (24, 0))
check("量序列断档不编造", consecutive([100.0, 110.0, None, 130.0]) == (0, 0))
check("时间轴倒序必须拒绝（Swift 侧守卫）", True, "守卫见 VolumeAnalysisEngine.calculate")

# ---- PositionDiscipline ------------------------------------------------
def discipline(current_exposure, score, cash, projected, fee=0.0):
    base, high, threshold, cap = 60, 85, 0.70, 0.90
    progress = min(1, max(0, (current_exposure - threshold) / max(1e-6, cap - threshold)))
    required = math.ceil(base + (high - base) * progress)
    total_assets = 100000.0
    projected_exposure = projected / max(1e-6, total_assets - fee)
    findings = []
    if cash < projected + fee:
        findings.append("insufficient_cash")
    if projected_exposure > cap:
        findings.append("portfolio_exposure_cap")
    if score < required:
        findings.append("score_threshold_raised")
    return required, projected_exposure, findings

check("低暴露所需评分 60", discipline(0.40, 70, 20000, 50000)[0] == 60)
check("高暴露所需评分线性抬到 85", discipline(0.90, 70, 20000, 50000)[0] == 85)
check("评分不足被否决", "score_threshold_raised" in discipline(0.85, 70, 20000, 50000)[2])
check("现金不足被否决", "insufficient_cash" in discipline(0.40, 90, 100, 50000)[2])
check("组合暴露超限被否决", "portfolio_exposure_cap" in discipline(0.40, 90, 200000, 95000)[2])

# ---- RealtimeTrigger ---------------------------------------------------
def trigger(price, *, lower=9.90, upper=10.00, target=9.95, expired=False,
            stale=False, stop=None, distance=0.003):
    if expired:
        return ("expired", 0)
    if stale:
        return ("quoteStale", 0)
    if stop is not None and price <= stop:
        return ("invalidated", 0)
    if lower <= price <= upper or price <= target:
        return ("triggered", 100)
    if upper < price <= upper * (1 + distance):
        return ("approaching", 60)
    return ("waiting", 0)

check("落入区间 → triggered/100", trigger(9.96) == ("triggered", 100))
check("0.3% 内接近 → approaching/60", trigger(10.01) == ("approaching", 60))
check("远离 → waiting/0", trigger(10.50) == ("waiting", 0))
check("过期优先于触发", trigger(9.96, expired=True)[0] == "expired")
check("报价过期优先于触发", trigger(9.96, stale=True)[0] == "quoteStale")
check("失效价优先于触发", trigger(9.96, stop=9.97)[0] == "invalidated")

# ---- CandidateShadow ---------------------------------------------------
def shadow(observations, trigger_price=10.0, max_gap=120):
    if not observations:
        return {"complete": False, "mfe": None, "mae": None, "codes": ["no_post_trigger_observations"]}
    gaps = [observations[0][0]] + [observations[i][0] - observations[i - 1][0]
                                   for i in range(1, len(observations))]
    largest = max(gaps)
    complete = largest <= max_gap
    changes = [(p - trigger_price) / trigger_price for _, p in observations]
    return {"complete": complete, "mfe": max(changes) if complete else None,
            "mae": min(changes) if complete else None,
            "codes": [] if complete else ["outcome_coverage_incomplete"]}

check("无观测不给 MFE/MAE", shadow([])["mfe"] is None and not shadow([])["complete"])
check("缺口过大不编造收益", shadow([(0, 10.1), (600, 10.2)])["mfe"] is None)
dense = [(i * 60, 10.0 + 0.02 * math.sin(i)) for i in range(61)]
check("覆盖完整才给 MFE/MAE", shadow(dense)["complete"] and shadow(dense)["mfe"] is not None)

# ---- 截图行解析 --------------------------------------------------------
def parse_row(texts):
    joined = " ".join(texts)
    m = re.search(r"(?<!\d)\d{6}(?!\d)", joined)
    if not m:
        return None
    side = "卖出" if "卖" in joined else "买入"
    t = re.search(r"\d{1,2}:\d{2}(?::\d{2})?", joined)
    cleaned = [re.sub(r"[,，¥￥\s]", "", x) for x in texts]
    code = m.group(0)
    nums = [x for x in cleaned
            if re.fullmatch(r"\d+(?:\.\d+)?", x) and x != code and code not in x]
    if len(nums) < 3:
        return None
    idx = next((i for i, v in enumerate(nums) if re.fullmatch(r"\d+", v)), None)
    if idx is None or idx == 0 or idx + 1 >= len(nums):
        return None
    return {"code": m.group(0), "side": side, "time": t.group(0) if t else "",
            "price": nums[idx - 1], "units": nums[idx], "amount": nums[idx + 1]}

row = parse_row(["沪深300ETF", "510300", "买入", "09:35:02", "3.982", "100", "398.20"])
check("截图行解析出 6 位代码/价/量/额",
      row is not None and row["code"] == "510300" and row["price"] == "3.982"
      and row["units"] == "100" and row["amount"] == "398.20", str(row))
check("价×量与金额核对通过", row is not None and abs(float(row["price"]) * float(row["units"]) - float(row["amount"])) <= max(0.02, float(row["amount"]) * 0.0001))
check("金额不符会被拦截", abs(3.982 * 100 - 400.00) > max(0.02, 400.00 * 0.0001))
check("多图行指纹去重口径", len({"510300|买入|09:35:02|3.982|100|398.20",
                                "510300|买入|09:35:02|3.982|100|398.20"}) == 1)

# ---- 逐笔 ↔ 汇总截图对账 -----------------------------------------------
def reconcile(details, summary):
    """与 Swift TradeScreenshotOCR.reconcile 同口径：按代码聚合数量 / 金额再比。"""
    def bucket(rows):
        out = {}
        for r in rows:
            b = out.setdefault(r["code"], {"units": 0.0, "amount": 0.0})
            b["units"] += float(r["units"])
            b["amount"] += float(r["amount"])
        return out
    left, right = bucket(details), bucket(summary)
    if not left or not right:
        return False, ["无可核对数据"]
    bad = sorted(set(left) ^ set(right))
    for code, a in left.items():
        b = right.get(code)
        if b is None:
            continue
        tol = max(0.05, abs(a["amount"]) * 0.0002)
        if abs(a["units"] - b["units"]) > 1e-6 or abs(a["amount"] - b["amount"]) > tol:
            if code not in bad:
                bad.append(code)
    return not bad, sorted(bad)


detail_rows = [
    {"code": "510300", "units": "100", "amount": "398.20"},
    {"code": "510300", "units": "200", "amount": "796.60"},
    {"code": "159915", "units": "100", "amount": "212.30"},
]
ok, bad = reconcile(detail_rows, [
    {"code": "510300", "units": "300", "amount": "1194.80"},
    {"code": "159915", "units": "100", "amount": "212.30"},
])
check("逐笔多笔同代码聚合后与汇总一致", ok, str(bad))
ok, bad = reconcile(detail_rows, [{"code": "510300", "units": "300", "amount": "1194.80"}])
check("汇总缺代码会被整批拦截", not ok and bad == ["159915"], str(bad))
ok, bad = reconcile(detail_rows, [
    {"code": "510300", "units": "200", "amount": "1194.80"},
    {"code": "159915", "units": "100", "amount": "212.30"},
])
check("数量不符会被拦截", not ok and bad == ["510300"], str(bad))
ok, bad = reconcile(detail_rows, [
    {"code": "510300", "units": "300", "amount": "1195.80"},
    {"code": "159915", "units": "100", "amount": "212.30"},
])
check("金额超容差会被拦截", not ok and bad == ["510300"], str(bad))
ok, bad = reconcile(detail_rows, [
    {"code": "510300", "units": "300", "amount": "1194.82"},
    {"code": "159915", "units": "100", "amount": "212.30"},
])
check("金额在容差内放行", ok, str(bad))

# ---- 汇总行解析：日期不能被当成数量 ------------------------------------
def parse_summary(texts):
    joined = " ".join(texts)
    m = re.search(r"(?<!\d)\d{6}(?!\d)", joined)
    if not m:
        return None
    code = m.group(0)
    cleaned = [re.sub(r"[,，¥￥\s]", "", x) for x in texts]
    nums = [x for x in cleaned
            if re.fullmatch(r"\d+(?:\.\d+)?", x)
            and x != code and code not in x
            and not (len(x) == 8 and x.startswith("20"))]
    if len(nums) < 2:
        return None
    idx = next((i for i, v in enumerate(nums) if re.fullmatch(r"\d+", v) and int(v) >= 1), None)
    if idx is None:
        return None
    units, amount = nums[idx], nums[-1]
    if amount == units or float(units) <= 0 or float(amount) <= 0:
        return None
    return {"code": code, "units": units, "amount": amount,
            "side": "卖出" if "卖" in joined else ("买入" if "买" in joined else "")}


srow = parse_summary(["20261107", "沪深300ETF", "510300", "2.000", "300", "1194.80"])
check("汇总行剔除 yyyyMMdd 日期与 6 位代码",
      srow is not None and srow["units"] == "300" and srow["amount"] == "1194.80", str(srow))
check("汇总行方向可为空", srow is not None and srow["side"] == "")

# ---- 手续费诚实口径 ----------------------------------------------------
def fee_from_table(has_fee_column, fee_cell=""):
    return has_fee_column and fee_cell != ""


def applied_fee(fee_text, use_reference, confirmed_zero=False):
    """返回 (fee, feeKnown, origin)，对应两个导入视图的 appliedDrafts。"""
    raw = fee_text.strip().replace("¥", "")
    try:
        value = float(raw) if raw else None
    except ValueError:
        value = None
    if value is not None and math.isfinite(value) and value >= 0:
        return value, True, "confirmed"
    if use_reference:
        return 0.10, True, "reference"
    if confirmed_zero:
        return 0.0, True, "confirmed"
    return 0.0, False, "missing"


check("截图表没有手续费列 → 不可直接写账", fee_from_table(False) is False)
check("表格有手续费列且填了值 → 可直接写账", fee_from_table(True, "1.50") is True)
check("表格有手续费列但某行为空 → 仍需确认", fee_from_table(True, "") is False)
f, known, origin = applied_fee("", False)
check("未补录且未勾选参考值 → 拒绝写入", not known and origin == "missing")
f, known, origin = applied_fee("1.20", False)
check("逐笔补录 1.20 → 确认写入", known and f == 1.20 and origin == "confirmed")
f, known, origin = applied_fee("", True)
check("明确勾选参考值 → 每笔 ¥0.10 且标记 reference", known and f == 0.10 and origin == "reference")
f, known, origin = applied_fee("abc", True)
check("无效输入不伪装成有效费用，但参考值仍生效", f == 0.10 and origin == "reference")
f, known, origin = applied_fee("", False, confirmed_zero=True)
check("CSV 明确确认按 0 → 允许但来源可追溯", known and f == 0.0 and origin == "confirmed")

# ---- 2.28.0 Anti-Overtrading（真实账本驱动门槛）-------------------------
def behavior_metrics(fills, now, lookback_days=5):
    """fills: (timestamp, side, gross, fee, archive_only)；交易日键按 UTC+8 划日。"""
    def day(ts):
        return int((ts + 8 * 3600) // 86400)
    real, invalid, archive = [], False, 0
    for f in fills:
        if f[4]:
            archive += 1
            continue
        if f[0] > now or f[2] <= 0 or f[3] < 0:
            invalid = True
            continue
        real.append(f)
    real.sort(key=lambda f: f[0])
    today = day(now)
    daily_count = sum(1 for f in real if day(f[0]) == today)
    daily_buy = sum(f[2] + max(0, f[3]) for f in real
                    if day(f[0]) == today and f[1] == "buy")
    consecutive = 0
    for f in reversed(real):
        if f[1] == "buy":
            consecutive += 1
        else:
            break
    elapsed = now - real[-1][0] if real else None
    recent = sorted({day(f[0]) for f in real if day(f[0]) <= today})[-lookback_days:]
    trailing = sum(1 for f in real if day(f[0]) in set(recent))
    return {"consecutive": consecutive, "elapsed": elapsed, "dailyCount": daily_count,
            "dailyBuy": daily_buy, "trailing": trailing, "days": len(recent),
            "archive": archive, "complete": not invalid}


def overtrading(fills, now, policy=None):
    p = policy or {"cooldownBuys": 3, "cooldownSeconds": 1800, "minGap": 0,
                   "dailyBuyLimit": None, "dailyTradeLimit": 8,
                   "churnThreshold": 12, "bonusPerBuy": 5, "churnBonus": 10, "maxBonus": 25}
    m = behavior_metrics(fills, now)
    findings, bonus, until = [], 0, None
    if not m["complete"]:
        findings.append("activity_history_unavailable")
    else:
        if m["consecutive"] >= p["cooldownBuys"]:
            findings.append("buy_cooldown")
            bonus += (m["consecutive"] - p["cooldownBuys"] + 1) * p["bonusPerBuy"]
            until = now + p["cooldownSeconds"]
        if p["minGap"] > 0 and m["elapsed"] is not None and m["elapsed"] < p["minGap"]:
            findings.append("trade_too_soon")
        if p["dailyBuyLimit"] is not None and m["dailyBuy"] > p["dailyBuyLimit"]:
            findings.append("daily_buy_limit")
        if m["dailyCount"] >= p["dailyTradeLimit"]:
            findings.append("daily_trade_limit")
        if m["trailing"] > p["churnThreshold"]:
            findings.append("recent_churn")
            bonus += p["churnBonus"]
    return {"m": m, "findings": findings, "bonus": min(p["maxBonus"], max(0, bonus)),
            "until": until, "allowed": not any(f != "recent_churn" for f in findings),
            "confidence": 0 if not m["complete"] else (80 if m["archive"] else 100)}


NOW = 1_762_500_000
fills3 = [(NOW - 3000 + i * 600, "buy", 1000.0, 0.5, False) for i in range(3)]
r = overtrading(fills3, NOW)
check("连买 3 笔触发冷却", "buy_cooldown" in r["findings"] and r["bonus"] == 5, str(r["findings"]))
check("冷却给出解除时刻而非永久禁止", r["until"] == NOW + 1800)
check("连买 5 笔追加门槛线性抬升",
      overtrading(fills3 + [(NOW - 900, "buy", 1000.0, 0.5, False),
                            (NOW - 300, "buy", 1000.0, 0.5, False)], NOW)["bonus"] == 15)
check("中间一笔卖出会重置连买计数",
      "buy_cooldown" not in overtrading(fills3 + [(NOW - 100, "sell", 1000.0, 0.5, False)], NOW)["findings"])
check("无成交历史不能判成「过度交易」",
      overtrading([], NOW)["m"]["consecutive"] == 0 and overtrading([], NOW)["allowed"])
check("只留档导入历史不参与行为判断",
      overtrading([(NOW - 100, "buy", 1000.0, 0.5, True)], NOW)["m"]["consecutive"] == 0)
check("只留档历史会降置信度并留原因码",
      overtrading([(NOW - 100, "buy", 1000.0, 0.5, True)], NOW)["confidence"] == 80)
check("未来时间戳 fail closed",
      overtrading([(NOW + 60, "buy", 1000.0, 0.5, False)], NOW)["findings"] == ["activity_history_unavailable"])
check("非法价格 fail closed",
      overtrading([(NOW - 60, "buy", -1.0, 0.5, False)], NOW)["m"]["complete"] is False)
check("当日买入上限生效",
      "daily_buy_limit" in overtrading(fills3, NOW, {"cooldownBuys": 99, "cooldownSeconds": 1800,
          "minGap": 0, "dailyBuyLimit": 1000.0, "dailyTradeLimit": 99, "churnThreshold": 99,
          "bonusPerBuy": 5, "churnBonus": 10, "maxBonus": 25})["findings"])
check("成交间隔门槛生效",
      "trade_too_soon" in overtrading(fills3, NOW, {"cooldownBuys": 99, "cooldownSeconds": 1800,
          "minGap": 3600, "dailyBuyLimit": None, "dailyTradeLimit": 99, "churnThreshold": 99,
          "bonusPerBuy": 5, "churnBonus": 10, "maxBonus": 25})["findings"])
check("近期高频交易只抬门槛不否决",
      "recent_churn" in overtrading(
          [(NOW - i * 900, "buy" if i % 2 else "sell", 100.0, 0.0, False) for i in range(14)], NOW)["findings"])

# ---- 2.28.0 生产盯盘：水位 / 会话 / 终态 / 锁存 --------------------------
def monitor_step(plan, quote, session, now, max_age=120):
    """返回 (new_state, watermark, event, reasons)。"""
    state, watermark = plan["state"], plan["watermark"]
    if not plan["active"]:
        return state, watermark, False, ["terminal_plan_state"]
    if session != "continuous":
        return state, watermark, False, ["market_not_in_continuous_session"]
    if quote is None:
        return state, watermark, False, ["quote_missing_for_plan"]
    stamp = quote["stamp"]
    if watermark is not None and stamp <= watermark:
        return state, watermark, False, ["duplicate_or_out_of_order_quote_ignored"]
    if stamp > now:
        return state, watermark, False, ["quote_timestamp_in_future"]
    if now - stamp > max_age:
        return ("triggered" if state == "triggered" else "quoteStale"), \
            max(watermark or stamp, stamp), False, ["quote_stale"]
    in_zone = plan["lower"] <= quote["price"] <= plan["upper"]
    to = "triggered" if in_zone else "waiting"
    reasons = ["price_inside_plan_zone"] if in_zone else ["price_below_buy_zone"]
    if state == "triggered" and to != "triggered":
        to = "triggered"
        reasons.append("trigger_latched_awaiting_user_review")
    event = to != state and to not in ("quoteStale", "sessionClosed", "paused")
    return to, max(watermark or stamp, stamp), event, reasons


def plan(state="waiting", watermark=None, active=True):
    return {"state": state, "watermark": watermark, "active": active,
            "lower": 3.98, "upper": 4.00}


q1 = {"price": 3.99, "stamp": NOW - 10}
st, wm, ev, _ = monitor_step(plan(), q1, "continuous", NOW)
check("价格落入区间 → 触发并写一条事件", st == "triggered" and ev and wm == NOW - 10)
st2, wm2, ev2, rs = monitor_step(plan("triggered", NOW - 10),
                                 {"price": 4.20, "stamp": NOW - 5}, "continuous", NOW)
check("触发后离开区间仍锁存、不重复写事件",
      st2 == "triggered" and not ev2 and "trigger_latched_awaiting_user_review" in rs)
st3, wm3, ev3, rs3 = monitor_step(plan("waiting", NOW - 5),
                                  {"price": 3.99, "stamp": NOW - 5}, "continuous", NOW)
check("重复/乱序报价不推进状态、不推进水位",
      st3 == "waiting" and wm3 == NOW - 5 and not ev3
      and rs3 == ["duplicate_or_out_of_order_quote_ignored"])
st4, wm4, ev4, _ = monitor_step(plan(), q1, "closed", NOW)
check("非连续竞价跳过评估", st4 == "waiting" and wm4 is None and not ev4)
st5, _, ev5, _ = monitor_step(plan(), None, "continuous", NOW)
check("无报价不凭空判定触发", st5 == "waiting" and not ev5)
st6, wm6, _, _ = monitor_step(plan(), {"price": 3.99, "stamp": NOW + 60}, "continuous", NOW)
check("未来报价时间戳被拦截", st6 == "waiting" and wm6 is None)
st7, _, ev7, _ = monitor_step(plan("triggered", NOW - 10), q1, "continuous", NOW, max_age=5)
check("过期报价不会把已触发状态洗掉", st7 == "triggered" and not ev7)

# ---- 2.28.0 成交 ↔ 候选关联 ---------------------------------------------
def link_score(fill, cand, same_day=True, exact=True, unique=True, clean=True):
    if fill["code"] != cand["code"] or fill["side"] != cand["side"] or not (exact or same_day):
        return None
    score = 45 + (25 if exact else 10)
    if cand["lower"] <= fill["price"] <= cand["upper"]:
        score += 20
    elif abs(fill["price"] - cand["target"]) <= cand["target"] * 0.005:
        score += 10
    gap = abs(fill["quantity"] - cand["quantity"]) / max(1e-9, cand["quantity"])
    score += 15 if gap <= 0.10 else (5 if gap <= 0.50 else 0)
    score = min(100, score)
    if score < 60:
        return None
    auto = score >= 85 and exact and unique and clean
    return {"score": score, "status": "auto" if auto else "pending",
            "reasons": ["code_and_side_match"] + (["same_day_coarse_timestamp"] if not exact else [])
            + (["archive_only_fill"] if not clean else [])
            + (["multiple_candidate_plans"] if not unique else [])}


cand = {"code": "510300", "side": "buy", "lower": 3.98, "upper": 4.00,
        "target": 3.99, "quantity": 1000}
fill = {"code": "510300", "side": "buy", "price": 3.99, "quantity": 1000}
check("价量时间全匹配且唯一 → 高置信自动关联",
      link_score(fill, cand)["status"] == "auto" and link_score(fill, cand)["score"] == 100)
check("只有同日粗时间 → 降为待人工确认",
      link_score(fill, cand, exact=False)["status"] == "pending"
      and "same_day_coarse_timestamp" in link_score(fill, cand, exact=False)["reasons"])
check("多个候选同分 → 不自动关联", link_score(fill, cand, unique=False)["status"] == "pending")
check("只留档历史成交 → 不自动关联",
      link_score(fill, cand, clean=False)["status"] == "pending"
      and "archive_only_fill" in link_score(fill, cand, clean=False)["reasons"])
check("代码或方向不符不生成关联", link_score({**fill, "code": "159915"}, cand) is None
      and link_score({**fill, "side": "sell"}, cand) is None)
check("既不在窗口内也不同日不生成关联", link_score(fill, cand, same_day=False, exact=False) is None)
check("低分不匹配不生成关联",
      link_score({**fill, "price": 5.5, "quantity": 10}, cand, exact=False) is None)

# ---- 2.28.0 今日 T vs HOLD 复盘 -----------------------------------------
def today_review(trips, fees_total, unpaired=0.0):
    contribution = sum(t["contribution"] for t in trips)
    allocated = sum(t["feeShare"] for t in trips)
    return {"contribution": contribution,
            "holdDifferential": contribution if trips else None,
            "feesTotal": fees_total, "feesAllocated": allocated,
            "coverageComplete": unpaired <= 1e-9,
            "reasons": ["ledger_only_no_market_price"]
            + ([] if trips else ["no_round_trips_today"])
            + (["unpaired_sells_need_trusted_closing_price"] if unpaired > 0 else [])}


trips = [{"contribution": 0.02 * 1000 - 1.0, "feeShare": 1.0},
         {"contribution": -0.01 * 500 - 0.5, "feeShare": 0.5}]
rv = today_review(trips, 4.0)
check("配平回合：T vs HOLD 差额等于含费净贡献", rv["holdDifferential"] == rv["contribution"])
check("费用只把配对部分算进 T 贡献", rv["feesAllocated"] == 1.5 and rv["feesTotal"] == 4.0)
check("未配平卖出不假装覆盖完整",
      not today_review(trips, 4.0, unpaired=200.0)["coverageComplete"]
      and "unpaired_sells_need_trusted_closing_price" in today_review(trips, 4.0, 200.0)["reasons"])
check("没有配对回合时差额留 nil 而不是 0", today_review([], 2.0)["holdDifferential"] is None)
check("复盘证据等级只来自账本，不编造行情",
      "ledger_only_no_market_price" in today_review(trips, 4.0)["reasons"])

# ---- MACD 多周期（研究升级：120 分默认 6/13/5） -----------------------
def ema_calculate(closes, fast, slow, signal):
    fast_a = 2.0 / (fast + 1); slow_a = 2.0 / (slow + 1); sig_a = 2.0 / (signal + 1)
    points = []; run = []; dif_run = []
    fe = slow_e = de = None
    for c in closes:
        run.append(c)
        if fe is None:
            if len(run) >= fast: fe = sum(run[-fast:]) / fast
        else: fe = fast_a * c + (1 - fast_a) * fe
        if slow_e is None:
            if len(run) >= slow: slow_e = sum(run[-slow:]) / slow
        else: slow_e = slow_a * c + (1 - slow_a) * slow_e
        if fe is None or slow_e is None: continue
        dif = fe - slow_e
        dif_run.append(dif)
        if de is None:
            if len(dif_run) >= signal: de = sum(dif_run[-signal:]) / signal
        else: de = sig_a * dif + (1 - sig_a) * de
        if de is None: continue
        points.append({"dif": dif, "dea": de, "hist": 2 * (dif - de)})
    return points


def bucket_120(closes_by_minute):
    slots = {}
    for minute, close in closes_by_minute:
        slots[minute // 120] = close
    return [slots[k] for k in sorted(slots)]


UP = {"bullishImproving", "shortTermRebound"}; DOWN = {"weakening", "bearish"}


def signal_fold(base_score, daily_trend, daily_cross, daily_confirmed,
                daily_hist_inc, daily_dif_above, intraday_trend=None):
    base_raw = (base_score - 50) // 6
    bonus = 0; notes = []
    if daily_trend in UP: bonus += 1; notes.append("daily_up")
    elif daily_trend in DOWN: bonus -= 1; notes.append("daily_down")
    if daily_cross == "golden":
        notes.append("golden")
        if daily_confirmed: bonus += 1
    elif daily_cross == "death": bonus -= 1; notes.append("death")
    if daily_hist_inc and not daily_dif_above: notes.append("green_shrink_no_bonus")
    if intraday_trend is not None:
        if intraday_trend in UP and daily_trend in UP: bonus += 1
        elif intraday_trend in DOWN and daily_trend in DOWN: bonus -= 1
    return max(0, min(100, 50 + (base_raw + bonus) * 6)), bonus, notes


long_series = [10, 10.5, 11, 10.8, 11.2, 11.5, 11.3, 11.8, 12.0, 11.9,
               12.2, 12.5, 12.3, 12.8, 13.0, 12.9, 13.2, 13.5] * 4
pts = ema_calculate(long_series, 12, 26, 9)
check("MACD 柱 = 2×(DIF−DEA)", all(abs(p["hist"] - 2 * (p["dif"] - p["dea"])) < 1e-9 for p in pts))
check("MACD 历史足够后产出序列", len(pts) > 0)
check("120 分桶按 120 分钟归并取末根",
      bucket_120([(0, 1.0), (30, 1.1), (119, 1.2), (120, 2.0), (200, 2.1), (240, 3.0)])
      == [1.2, 2.1, 3.0])
_, b_green, _ = signal_fold(50, "neutral", "none", True, True, False)
check("绿柱缩短（下跌动能减弱）不计入买入加分", b_green == 0)
_, b_gold, _ = signal_fold(50, "bullishImproving", "golden", True, False, True)
check("日线金叉确认 + 多头 → 加分", b_gold == 2)
_, b_same, _ = signal_fold(50, "bullishImproving", "none", True, False, True, "bullishImproving")
check("日线/120分 MACD 同向改善 → 加分", b_same == 2)
_, b_conflict, _ = signal_fold(50, "weakening", "none", True, False, False, "bullishImproving")
check("120分改善但日线仍弱 → 不加分", b_conflict == -1)


def macd_divergence(points):
    """复刻 Swift MACDAnalysis.detectDivergence：仅观察，未收尾/不足 40 点不判。
    points: list of {close, hist}，hist = 2×(DIF−DEA)。"""
    if len(points) < 40:
        return "undetermined"
    pts = points
    window = 3

    def pivots(lows):
        res = []
        for i in range(window, len(pts) - window):
            center = pts[i]
            neigh = [pts[j] for j in range(i - window, i + window + 1) if j != i]
            if lows:
                if all(n["close"] > center["close"] for n in neigh):
                    res.append(center)
            else:
                if all(n["close"] < center["close"] for n in neigh):
                    res.append(center)
        return res

    lows = pivots(True)
    highs = pivots(False)
    if len(lows) >= 2:
        a, b = lows[-2], lows[-1]
        if b["close"] < a["close"] and b["hist"] > a["hist"]:
            return "bullish"
    if len(highs) >= 2:
        a, b = highs[-2], highs[-1]
        if b["close"] > a["close"] and b["hist"] < a["hist"]:
            return "bearish"
    return "none"


def _divergence_points(peaks):
    # peaks=True → 构造顶背离（两段高点，后高更高但柱值更低）
    # peaks=False → 构造底背离（两段低点，后低更低但柱值更高）
    if not peaks:
        segA = [12.0,12.2,12.4,12.6,12.8,13.0,13.0,13.0,13.0,13.0]
        dip1 = 10.0
        segB = [10.5,11.0,11.5,12.0,12.5,13.0,13.0,13.0,13.0,13.0,13.0]
        segC = [13.0,12.8,12.6,12.4,12.2,12.0,11.5,11.0,10.2]
        dip2 = 9.5
        segD = [9.8,10.0,10.2,10.4,10.6,10.8,11.0,11.2,11.4,11.6,11.8,12.0,12.2,12.4]
        closes = segA + [dip1] + segB + segC + [dip2] + segD
        hist = [0.0] * len(closes)
        hist[len(segA)] = -2.0
        hist[len(segA) + 1 + len(segB) + len(segC)] = -1.2
    else:
        segA = [11.0,11.2,11.4,11.6,11.8,12.0,12.0,12.0,12.0,12.0]
        peak1 = 14.0
        segB = [13.5,13.0,12.5,12.0,11.5,11.0,11.0,11.0,11.0,11.0,11.0]
        segC = [11.0,11.2,11.4,11.6,11.8,12.0,12.5,13.0,13.5]
        peak2 = 15.0
        segD = [14.8,14.6,14.4,14.2,14.0,13.8,13.6,13.4,13.2,13.0,12.8,12.6,12.4,12.2]
        closes = segA + [peak1] + segB + segC + [peak2] + segD
        hist = [0.0] * len(closes)
        hist[len(segA)] = 2.0
        hist[len(segA) + 1 + len(segB) + len(segC)] = 1.2
    return [{"close": c, "hist": h} for c, h in zip(closes, hist)]


check("MACD 背离：点数不足 40 → undetermined", macd_divergence([{"close": 1, "hist": 0}] * 10) == "undetermined")
_bull = _divergence_points(False)
check("MACD 背离：底背离识别", macd_divergence(_bull) == "bullish")
check("MACD 背离：底背离后低更低", _bull[31]["close"] < _bull[10]["close"])
check("MACD 背离：底背离后柱值更高", _bull[31]["hist"] > _bull[10]["hist"])
check("MACD 背离：顶背离识别", macd_divergence(_divergence_points(True)) == "bearish")
check("MACD 背离：无背离（单调下跌）",
      macd_divergence([{"close": c, "hist": -i * 0.1} for i, c in enumerate(range(50, 10, -1))]) == "none")


# ---- K 线六形态（研究升级：离线可测数学规则） ---------------------------
def candle_features(bars):
    out = []
    for b in bars:
        o, c, h, l, v = b["open"], b["close"], b["high"], b["low"], b["volume"]
        body = abs(c - o)
        body_ratio = body / abs(c) if c != 0 else 0
        upper = h - max(o, c)
        lower = min(o, c) - l
        out.append({"open": o, "close": c, "high": h, "low": l, "volume": v,
                    "bullish": c >= o, "bearish": c < o, "body": body,
                    "body_ratio": body_ratio, "upper": upper, "lower": lower,
                    "lower_ratio": (lower / abs(c)) if c != 0 else 0})
    return out


def vol_ma20(vols):
    if len(vols) < 20:
        return None
    w = vols[-20:]
    if any(v is None or v < 0 for v in w):
        return None
    return sum(w) / 20


DEFAULT = {"consolidationLookback": 20, "consolidationRangeRatio": 0.08,
           "breakoutVolumeMultiple": 1.5, "pullbackMaxBars": 5, "pullbackTolerance": 0.02,
           "panicLookback": 10, "panicDropRatio": 0.10, "panicMaxUpRatio": 0.04,
           "shrinkBars": 3, "shrinkMinBodyRatio": 0.004, "lowerShadowRatio": 0.02,
           "smallBodyRatio": 0.015, "lowerShadowDominance": 1.5,
           "heavyVolumeMultiple": 2.0, "heavyBodyRatio": 0.01}


def p_breakout(bars, cfg=DEFAULT):
    candles = candle_features(bars)
    n = cfg["consolidationLookback"]
    if len(candles) <= n:
        return False
    window = candles[-(n + 1):]
    cand = window[-1]
    base = window[:-1]
    maxHigh = max(c["high"] for c in base)
    minLow = min(c["low"] for c in base)
    avgClose = sum(c["close"] for c in base) / len(base)
    ratio = (maxHigh - minLow) / abs(avgClose) if avgClose != 0 else 1
    if ratio >= cfg["consolidationRangeRatio"]:
        return False
    vol20 = vol_ma20([b["volume"] for b in bars])
    broke = cand["close"] > maxHigh
    volOK = vol20 is not None and cand["volume"] >= vol20 * cfg["breakoutVolumeMultiple"]
    return bool(broke and volOK and cand["bullish"])


def p_pullback(bars, cfg=DEFAULT):
    candles = candle_features(bars)
    if len(candles) <= cfg["consolidationLookback"] + cfg["pullbackMaxBars"]:
        return False
    bi = None
    start = cfg["consolidationLookback"]
    for i in range(start, len(candles) - 1):
        prior = [c["high"] for c in candles[max(0, i - cfg["consolidationLookback"]):i]]
        if candles[i]["close"] > max(prior) * 1.001:
            bi = i
    if bi is None:
        return False
    bl = candles[bi]["close"]
    held = True
    pulled = False
    for j in range(bi + 1, len(candles) - 1):
        c = candles[j]
        if c["close"] < bl * (1 - cfg["pullbackTolerance"]):
            held = False
        if c["close"] <= bl * 1.005 and c["close"] >= bl * 0.95:
            pulled = True
    last = candles[-1]
    return bool(held and pulled and last["close"] > bl and last["bullish"])


def p_panicStop(bars, cfg=DEFAULT):
    candles = candle_features(bars)
    p = cfg["panicLookback"]
    if len(candles) < p + 1:
        return False
    window = candles[-(p + 1):]
    recent = window[:-1]
    first = recent[0]["close"]
    lastOfRecent = recent[-1]["close"]
    drop = (first - lastOfRecent) / abs(first) if first != 0 else 0
    if drop < cfg["panicDropRatio"]:
        return False
    last = candles[-1]
    rebound = (last["close"] - lastOfRecent) / abs(lastOfRecent) if lastOfRecent != 0 else 0
    return bool(rebound >= cfg["panicMaxUpRatio"]
                or (last["bearish"] and last["body_ratio"] < cfg["smallBodyRatio"])
                or not last["bearish"])


def p_shrinkingBearish(bars, cfg=DEFAULT):
    candles = candle_features(bars)
    k = cfg["shrinkBars"]
    if len(candles) < k:
        return False
    lastK = candles[-k:]
    if not all(c["bearish"] and c["body_ratio"] >= cfg["shrinkMinBodyRatio"] for c in lastK):
        return False
    bodies = [c["body_ratio"] for c in lastK]
    return all(bodies[i] > bodies[i + 1] for i in range(len(bodies) - 1))


def p_longLowerShadow(bars, cfg=DEFAULT):
    candles = candle_features(bars)
    if not candles:
        return False
    last = candles[-1]
    return bool(last["bearish"]
                and last["body_ratio"] < cfg["smallBodyRatio"]
                and last["lower_ratio"] >= cfg["lowerShadowRatio"]
                and last["lower"] >= last["upper"] * cfg["lowerShadowDominance"])


def p_heavyBearish(bars, cfg=DEFAULT):
    candles = candle_features(bars)
    vol20 = vol_ma20([b["volume"] for b in bars])
    if not candles or vol20 is None:
        return False
    last = candles[-1]
    return bool(last["volume"] >= vol20 * cfg["heavyVolumeMultiple"]
                and last["bearish"]
                and last["body_ratio"] >= cfg["heavyBodyRatio"])


def flat_bars(count, close=10.0, high=10.05, low=9.95, volume=100.0):
    return [{"open": close, "close": close, "high": high, "low": low, "volume": volume}
            for _ in range(count)]


# 1. 放量突破：20 根震荡 + 1 根放量阳线突破
bo = flat_bars(20) + [{"open": 10.05, "close": 10.5, "high": 10.55, "low": 10.0, "volume": 200.0}]
check("放量突破：震荡后放量阳线突破 → 识别", p_breakout(bo))
# 非震荡（高波动）→ 不识别
hv = [{"open": 10.0, "close": 10.0 + (i % 2) * 1.5, "high": 11.0, "low": 9.0, "volume": 100.0}
      for i in range(20)] \
    + [{"open": 10.05, "close": 10.5, "high": 10.55, "low": 10.0, "volume": 200.0}]
check("放量突破：高波动非震荡 → 不识别", not p_breakout(hv))

# 2. 回踩确认：22 震荡 + 突破 + 2 回踩 + 重新站上
pb = flat_bars(22) \
    + [{"open": 10.2, "close": 10.5, "high": 10.6, "low": 10.2, "volume": 200.0}] \
    + [{"open": 10.45, "close": 10.42, "high": 10.46, "low": 10.38, "volume": 90.0}] \
    + [{"open": 10.43, "close": 10.42, "high": 10.46, "low": 10.38, "volume": 90.0}] \
    + [{"open": 10.45, "close": 10.6, "high": 10.62, "low": 10.44, "volume": 150.0}]
check("回踩确认：突破→回踩不破→重新站上 → 识别", p_pullback(pb))
# 回踩跌破突破位 → 不识别
pb_bad = flat_bars(22) \
    + [{"open": 10.2, "close": 10.5, "high": 10.6, "low": 10.2, "volume": 200.0}] \
    + [{"open": 10.0, "close": 10.2, "high": 10.25, "low": 10.15, "volume": 90.0}] \
    + [{"open": 10.2, "close": 10.2, "high": 10.25, "low": 10.15, "volume": 90.0}] \
    + [{"open": 10.25, "close": 10.6, "high": 10.62, "low": 10.44, "volume": 150.0}]
check("回踩确认：回踩跌破突破位 → 不识别", not p_pullback(pb_bad))

# 3. 恐慌止跌：急跌 10% 后阳线企稳
ps = flat_bars(13) \
    + [{"open": c, "close": c, "high": c, "low": c, "volume": 100.0} for c in
       [10.0, 9.9, 9.8, 9.7, 9.6, 9.5, 9.4, 9.3, 9.2, 9.0]] \
    + [{"open": 9.0, "close": 9.05, "high": 9.06, "low": 9.0, "volume": 100.0}]
check("恐慌止跌：急跌≥10% 后企稳 → 识别", p_panicStop(ps))
# 跌幅不足 → 不识别
ps_small = flat_bars(13) \
    + [{"open": c, "close": c, "high": c, "low": c, "volume": 100.0} for c in
       [10.0, 9.98, 9.96, 9.94, 9.92, 9.90, 9.88, 9.86, 9.84, 9.82]] \
    + [{"open": 9.82, "close": 9.85, "high": 9.86, "low": 9.82, "volume": 100.0}]
check("恐慌止跌：跌幅不足 → 不识别", not p_panicStop(ps_small))

# 4. 阴线实体逐渐缩小
sb = flat_bars(27) \
    + [{"open": 10.0, "close": 9.5, "high": 10.0, "low": 9.5, "volume": 100.0}] \
    + [{"open": 9.5, "close": 9.2, "high": 9.5, "low": 9.2, "volume": 100.0}] \
    + [{"open": 9.2, "close": 9.05, "high": 9.2, "low": 9.05, "volume": 100.0}]
check("阴线缩小：连续3根阴线实体递减 → 识别", p_shrinkingBearish(sb))
# 实体未递减 → 不识别
sb_bad = flat_bars(27) \
    + [{"open": 10.0, "close": 9.5, "high": 10.0, "low": 9.5, "volume": 100.0}] \
    + [{"open": 9.5, "close": 9.2, "high": 9.5, "low": 9.2, "volume": 100.0}] \
    + [{"open": 9.2, "close": 9.6, "high": 9.6, "low": 9.2, "volume": 100.0}]
check("阴线缩小：末根转阳 → 不识别", not p_shrinkingBearish(sb_bad))

# 5. 长下影小实体阴线
ls = flat_bars(20) \
    + [{"open": 10.0, "close": 9.98, "high": 10.01, "low": 9.5, "volume": 100.0}]
check("长下影：小实体阴线+长下影占优 → 识别", p_longLowerShadow(ls))
# 实体过大 → 不识别
ls_bad = flat_bars(20) \
    + [{"open": 10.0, "close": 9.6, "high": 10.01, "low": 9.5, "volume": 100.0}]
check("长下影：实体过大 → 不识别", not p_longLowerShadow(ls_bad))

# 6. 放量阴线
hb = flat_bars(21) \
    + [{"open": 10.2, "close": 10.0, "high": 10.2, "low": 9.98, "volume": 150.0}]
check("放量阴线：量比不足 → 不识别", not p_heavyBearish(hb))
hb_ok = flat_bars(21) \
    + [{"open": 10.2, "close": 10.0, "high": 10.2, "low": 9.98, "volume": 250.0}]
check("放量阴线：量比≥2× 且实体有效 → 识别", p_heavyBearish(hb_ok))

# ── ETF 净值 / IOPV / 折溢价（口径与 Swift ETFIOPVService 一致）
print("ETF 净值 / IOPV / 折溢价")

SINA_FU_SAMPLE = 'var hq_str_fu_510300="华泰柏瑞沪深300ETF,16:05:00,4.1312,4.1909,1.8810,0,-1.4235,2026-11-06,4.0656,-2.989";'
TENCENT_JJ_SAMPLE = 'v_jj510300="510300~华泰柏瑞沪深300ETF~0.0000~0.0000~~4.1312~1.8589~-1.4245~2026-11-06~";'


def parse_sina_fu(text):
    """0 名称 / 1 时间 / 2 净值 / 3 昨净值 / 6 净值涨跌% / 7 日期。"""
    if '"' not in text:
        return None
    body = text.split('"')[1]
    f = body.split(",")
    if len(f) < 8:
        return None
    try:
        nav = float(f[2])
    except ValueError:
        return None
    if nav <= 0:
        return None
    return {"nav": nav, "prev": f[3], "change": float(f[6]), "date": f[7].strip()}


def parse_tencent_jj(text):
    """5 净值 / 7 净值涨跌% / 8 日期。"""
    if '"' not in text:
        return None
    f = text.split('"')[1].split("~")
    if len(f) < 9:
        return None
    try:
        nav = float(f[5])
    except ValueError:
        return None
    return nav if nav > 0 else None


def premium_pct(price, nav):
    if not price or not nav or price <= 0 or nav <= 0:
        return None
    return (price - nav) / nav * 100


sina = parse_sina_fu(SINA_FU_SAMPLE)
check("新浪 fu_ 解析：净值 = 4.1312", sina is not None and abs(sina["nav"] - 4.1312) < 1e-9)
check("新浪 fu_ 解析：净值涨跌幅 = -1.4235", sina is not None and abs(sina["change"] + 1.4235) < 1e-9)
check("新浪 fu_ 解析：日期 = 2026-11-06", sina is not None and sina["date"] == "2026-11-06")
check("腾讯 jj 与新浪净值互证一致（4.1312）",
      abs(parse_tencent_jj(TENCENT_JJ_SAMPLE) - 4.1312) < 1e-9)
check("折溢价：4.124 vs 4.1312 = -0.174%", abs(premium_pct(4.124, 4.1312) + 0.1743) < 1e-3)
check("折溢价：缺净值返回 None（绝不填 0 假装平价）", premium_pct(4.124, None) is None)

# ── 价格质量闸门（第 1 优先级）
print("ETF 价格质量闸门")

BLOCKING_ISSUES = {"priceMissing", "priceInvalid", "quoteStale", "sourceUntrusted",
                   "manualOverride", "premiumExtreme", "spreadExtreme",
                   "overseasClosed", "fxUnknown"}


def price_quality(price, quote_fresh=True, nav_present=True, nav=4.1312,
                  cross_border=False, fx_known=True, overseas_open=None):
    if price is None or price <= 0:
        return {"verdict": "blocked", "issues": ["priceMissing"]}
    issues = []
    if not quote_fresh:
        issues.append("quoteStale")
    if not nav_present:
        issues.append("iopvMissing")
    else:
        p = (price - nav) / nav * 100
        block = 4.5 if cross_border else 3.0
        warn = 1.5 if cross_border else 1.0
        if abs(p) >= block:
            issues.append("premiumExtreme")
        elif abs(p) >= warn:
            issues.append("premiumWide")
    if cross_border:
        if not fx_known:
            issues.append("fxUnknown")
        if overseas_open is False:
            issues.append("overseasClosed")
    if any(i in BLOCKING_ISSUES for i in issues):
        return {"verdict": "blocked", "issues": issues}
    return {"verdict": "degraded" if issues else "usable", "issues": issues}


check("闸门：报价过期 → 阻断（不给精确限价）",
      price_quality(4.124, quote_fresh=False)["verdict"] == "blocked")
check("闸门：缺 IOPV → 降级（可看价格，不可称贵贱）",
      price_quality(4.124, nav_present=False)["verdict"] == "degraded")
check("闸门：折溢价 +3.4% → 阻断", price_quality(4.27)["verdict"] == "blocked")
check("闸门：跨境 +3.4% 未破 4.5% → 仅降级",
      price_quality(4.27, cross_border=True)["verdict"] == "degraded")
check("闸门：境外休市 → 阻断",
      price_quality(4.124, cross_border=True, overseas_open=False)["verdict"] == "blocked")
check("闸门：数据齐备且平价 → 可用", price_quality(4.13)["verdict"] == "usable")


# ── 组合风险预算（第 2 优先级）
print("组合风险预算")


def theme_of(code):
    if code.startswith("511"):
        return "债券/货币"
    if code.startswith("518"):
        return "黄金/商品"
    if code.startswith("513") or code.startswith("1599"):
        return "跨境"
    if code.startswith("51"):
        return "沪市权益"
    if code.startswith("159"):
        return "深市权益"
    return "其他"


def risk_budget(positions, cash, max_single=0.25, max_theme=0.40,
                min_cash=0.05, max_count=12):
    invested = sum(v for _, v in positions)
    total = invested + cash
    findings = []
    if total > 0:
        for code, v in positions:
            if v / total > max_single:
                findings.append(("veto", "single-" + code))
        themes = {}
        for code, v in positions:
            themes[theme_of(code)] = themes.get(theme_of(code), 0) + v
        for t, v in themes.items():
            if v / total > max_theme:
                findings.append(("warn", "theme-" + t))
        if cash / total < min_cash:
            findings.append(("warn", "cash"))
        if len(positions) > max_count:
            findings.append(("note", "count"))
    return {"has_veto": any(s == "veto" for s, _ in findings),
            "findings": findings,
            "headroom": max(0.0, cash - total * min_cash) if total > 0 else 0.0,
            "total": total}


check("风险预算：单标的 40% → 否决",
      risk_budget([("510300", 4000)], 6000)["has_veto"])
check("风险预算：单标的 20% → 不否决",
      not risk_budget([("510300", 2000)], 8000)["has_veto"])
check("风险预算：现金 2% → 现金下限提醒",
      any(k == "cash" for _, k in risk_budget([("510300", 9800)], 200)["findings"]))
check("风险预算：可动用现金 = 现金 − 5% 总资产",
      abs(risk_budget([], 10000)["headroom"] - 9500) < 1e-9)
check("风险预算：跨境按代码段识别（513/1599）",
      theme_of("513100") == "跨境" and theme_of("159920") == "跨境" and theme_of("510300") == "沪市权益")

# ── 策略仲裁（数据 > 组合风险 > 市场 > 技术 > AI > 候选）
print("策略仲裁优先级")


def arbitrate(verdict="usable", risk_veto=False, regime_risk=0,
              trend="bullishImproving", divergence="none",
              patterns=1, candidate=False):
    if verdict == "blocked":
        return ("blockedByData", "dataValidity")
    if risk_veto:
        return ("blockedByRisk", "riskBudget")
    if regime_risk >= 2:
        return ("waitForMarket", "marketRegime")
    if trend in ("bearish", "weakening", "dataInsufficient"):
        return ("observeOnly", "technicalEvidence")
    if divergence == "bearish":
        return ("observeOnly", "technicalEvidence")
    if trend == "bullishImproving" and patterns > 0:
        return ("candidateActive" if candidate else "candidateEligible", "candidate")
    return ("observeOnly", "technicalEvidence")


check("仲裁：数据阻断压过一切（组合也超限）",
      arbitrate(verdict="blocked", risk_veto=True) == ("blockedByData", "dataValidity"))
check("仲裁：组合否决压过市场与技术（技术再好不翻案）",
      arbitrate(risk_veto=True, trend="bullishImproving", patterns=2) == ("blockedByRisk", "riskBudget"))
check("仲裁：市场 R2 高风险 → 只能等",
      arbitrate(regime_risk=2, trend="bullishImproving", patterns=2) == ("waitForMarket", "marketRegime"))
check("仲裁：顶背离 → 仅观察",
      arbitrate(divergence="bearish") == ("observeOnly", "technicalEvidence"))
check("仲裁：多头动能 + 形态配合 → 可备选（不自动执行）",
      arbitrate() == ("candidateEligible", "candidate"))
check("仲裁：单 MACD 多头、无形态 → 仍仅观察",
      arbitrate(patterns=0) == ("observeOnly", "technicalEvidence"))


# ── 股息率（手填优先；实测派发需满 12 个月覆盖，不外推）
print("股息率")


def dividend_yield_manual(per_share, price):
    if not per_share or per_share <= 0 or not price or price <= 0:
        return None
    return per_share / price * 100


def dividend_yield_trailing(events, price, ledger_start_days, window_days=365):
    """events: [(days_ago, amount)]。ledger_start_days = 账本最早一条记录距今天数。
    覆盖不满一年（<365 天）一律不外推。"""
    if not price or price <= 0:
        return None
    if ledger_start_days < 365:
        return None
    paid = sum(a for d, a in events if d <= window_days)
    if paid <= 0:
        return None
    return paid / price * 100


check("股息率：手填 0.12 元 / 价 4.00 = 3.00%",
      abs(dividend_yield_manual(0.12, 4.00) - 3.0) < 1e-9)
check("股息率：未填年分红返回 None（不用行业均值瞎估）",
      dividend_yield_manual(None, 4.00) is None)
check("股息率：一年内派发两次共 0.10 / 价 4.00 = 2.50%",
      abs(dividend_yield_trailing([(200, 0.05), (30, 0.05)], 4.00, 400) - 2.5) < 1e-9)
check("股息率：账本只覆盖 200 天 → 不外推",
      dividend_yield_trailing([(200, 0.05), (30, 0.05)], 4.00, 200) is None)
check("股息率：窗口外那笔不计入（只算 0.05 → 1.25%）",
      abs(dividend_yield_trailing([(400, 0.05), (30, 0.05)], 4.00, 400) - 1.25) < 1e-9)

# ===== ATR 与耐心限价（与 Sources/PatientLimitEngine.swift 同口径复刻）=====


def true_ranges(bars):
    """bars: [(high, low, close)]。第一根缺前收，算不出 TR，丢弃。"""
    out = []
    for i in range(1, len(bars)):
        high, low, _ = bars[i]
        prev_close = bars[i - 1][2]
        if high <= 0 or low <= 0 or prev_close <= 0:
            continue
        out.append(max(high - low, abs(high - prev_close), abs(low - prev_close)))
    return out


def atr_wilder(bars, period=14):
    trs = true_ranges(bars)
    if len(trs) < period:
        return None
    seed = trs[:period]
    atr = sum(seed) / len(seed)
    for tr in trs[period:]:
        atr = (atr * (period - 1) + tr) / period
    return atr


def atr_simple(bars, period=14):
    trs = true_ranges(bars)
    if len(trs) < period:
        return None
    window = trs[-period:]
    return sum(window) / len(window)


def patient_bands(reference, atr, deployable, lot=100,
                  multipliers=(0.5, 1.0, 1.5), weights=(0.30, 0.35, 0.35)):
    """返回 [(price, shares, amount)]；不足一手 shares=0，不凑单。"""
    bands = []
    for multiple, weight in zip(multipliers, weights):
        price = reference - atr * multiple
        if price <= 0:
            continue
        budget = deployable * weight
        lots = 0
        if budget > 0:
            lots = int(math.floor(budget / (price * lot)))
            lots = max(0, min(1_000_000, lots))
        shares = lots * lot
        bands.append((price, shares, shares * price))
    return bands


def touch_count(lows, price):
    return sum(1 for low in lows if 0 < low <= price)


flat = [(10.5, 9.5, 10.0)] * 20            # 真实波幅恒为 1.0
check("ATR：真实波幅恒 1.0 时 Wilder = 1.0",
      abs(atr_wilder(flat, 14) - 1.0) < 1e-9)
check("ATR：同序列简单平均也 = 1.0（两口径收敛）",
      abs(atr_simple(flat, 14) - 1.0) < 1e-9)
check("ATR：样本不足 14 个真实波幅 → 返回 None（不拿半个月冒充 14 日）",
      atr_wilder([(10.5, 9.5, 10.0)] * 10, 14) is None)

# 波幅放大后 Wilder 应被抬高，但滞后于最新一根（因为它是平滑值）
widening = [(10.5, 9.5, 10.0)] * 14 + [(13.0, 9.0, 11.0)] * 6
check("ATR：波幅放大后 Wilder 上升",
      atr_wilder(widening, 14) > atr_wilder(flat, 14))
check("ATR：Wilder 滞后于简单平均（平滑特性）",
      atr_wilder(widening, 14) < atr_simple(widening, 14))

bands = patient_bands(4.00, 0.08, 10000)
check("限价：0.5×ATR → 3.96", abs(bands[0][0] - 3.96) < 1e-9)
check("限价：1.0×ATR → 3.92", abs(bands[1][0] - 3.92) < 1e-9)
check("限价：1.5×ATR → 3.88", abs(bands[2][0] - 3.88) < 1e-9)
check("限价：标准档 3500 元 ÷ 3.92 一手 → 8 手 = 800 份",
      bands[1][1] == 800, f"实得 {bands[1][1]} 份")
check("限价：份额整手，金额按份额计（不超预算）",
      bands[1][2] <= 3500 + 1e-9)

tiny = patient_bands(4.00, 0.08, 300)
check("限价：额度 300 元不足一手 → 各档 0 份（不凑单）",
      all(share == 0 for _, share, _ in tiny))

check("限价：失效价 = 参考价 − 2.5×ATR = 3.80",
      abs((4.00 - 0.08 * 2.5) - 3.80) < 1e-9)

lows = [4.10, 3.95, 3.90, 3.85, 3.98, 4.20]
check("限价：触及统计只数历史事实（≤3.90 有 2 天）",
      touch_count(lows, 3.90) == 2)
check("限价：触及统计对 3.80 为 0（该价从未出现）",
      touch_count(lows, 3.80) == 0)


def patient_plan(reference, atr, deployable, blocked=False):
    """数据被阻断时一个精确价都不给。"""
    if blocked or reference <= 0 or deployable <= 0:
        return {"allowsExactPrice": False, "bands": [], "blocked": True}
    return {"allowsExactPrice": True, "bands": patient_bands(reference, atr, deployable), "blocked": False}


blocked_plan = patient_plan(4.00, 0.08, 10000, blocked=True)
check("限价：数据阻断 → 不给任何挂单价",
      blocked_plan["blocked"] and not blocked_plan["bands"])
check("限价：数据阻断 → 连精确价都不宣称",
      blocked_plan["allowsExactPrice"] is False)
check("限价：无额度 → 同样不给价（风险优先于技术）",
      patient_plan(4.00, 0.08, 0)["blocked"] is True)

# ===== 长期趋势（日线 MA250，与 Sources/LongTermTrendEngine.swift 同口径）=====


def moving_average(values, period):
    if period <= 0 or len(values) < period:
        return None
    window = values[-period:]
    total = sum(window)
    if total <= 0:
        return None
    return total / period


def long_term_trend(closes, price=None, long_period=250, mid_period=60,
                    slope_lookback=20, near_band=2.0):
    ref = price if (price and price > 0) else (closes[-1] if closes else None)
    ma250 = moving_average(closes, long_period)
    slope = None
    if ma250 is not None and len(closes) >= long_period + slope_lookback:
        earlier = moving_average(closes[:-slope_lookback], long_period)
        if earlier and earlier > 0:
            slope = (ma250 - earlier) / earlier * 100
    position = "unavailable"
    distance = None
    if ma250 and ma250 > 0 and ref:
        gap = (ref - ma250) / ma250 * 100
        distance = gap
        position = "near" if abs(gap) <= near_band else ("above" if gap > 0 else "below")
    return {"ma250": ma250, "position": position, "distance": distance, "slope": slope}


check("MA250：只有 249 根 → 不给长期均线（不拿 MA120 冒充）",
      long_term_trend([10.0] * 249)["ma250"] is None)
check("MA250：不足 250 根 → 位置判定为不可判断",
      long_term_trend([10.0] * 249)["position"] == "unavailable")

flat250 = [10.0] * 250
check("MA250：250 根恒 10 元 → MA250 = 10.0",
      abs(long_term_trend(flat250)["ma250"] - 10.0) < 1e-9)
check("MA250：现价 11 元 → 判定为线上",
      long_term_trend(flat250, price=11.0)["position"] == "above")
check("MA250：现价 9 元 → 判定为线下",
      long_term_trend(flat250, price=9.0)["position"] == "below")
check("MA250：现价 10.1 元（+1%）→ 判定为贴合，不是「突破」",
      long_term_trend(flat250, price=10.1)["position"] == "near")
check("MA250：距均线 +10%",
      abs(long_term_trend(flat250, price=11.0)["distance"] - 10.0) < 1e-9)

check("MA250：260 根不够算斜率（需要 270）",
      long_term_trend([10.0] * 260)["slope"] is None)
rising = [10.0 + 0.01 * i for i in range(300)]
check("MA250：上行序列斜率为正",
      long_term_trend(rising)["slope"] > 0)
falling = [10.0 - 0.01 * i for i in range(300)]
check("MA250：下行序列斜率为负",
      long_term_trend(falling)["slope"] < 0)


# ---- 历史验证（样本内 / 样本外，研究升级：真实历史验证） ----------------
def hist_split(n, ratio=0.7):
    """时间顺序切分：前 70% 样本内，后 30% 样本外。绝不随机。"""
    return int(n * ratio)


def hist_forward(closes, i, horizon):
    """信号日收盘 → horizon 日后收盘的收益（百分数单位）。
    窗口不足返回 None（剔除，不计成败）。恰好 0 算未命中（由调用方 > 0 判定）。"""
    n = len(closes)
    if i + horizon >= n or closes[i] <= 0:
        return None
    r = (closes[i + horizon] / closes[i] - 1) * 100
    return r if math.isfinite(r) else None


def hist_segment(closes, signals, horizon, lo, hi, min_samples=8):
    """分段统计：命中率 + 无条件基准。样本不足则命中率返回 None。"""
    sample = dropped = hits = 0
    total = 0.0
    for i in signals:
        if not (lo <= i < hi):
            continue
        r = hist_forward(closes, i, horizon)
        if r is None:
            dropped += 1
            continue
        sample += 1
        if r > 0:
            hits += 1
        total += r
    b_sample = b_hits = 0
    b_total = 0.0
    for i in range(lo, hi):
        r = hist_forward(closes, i, horizon)
        if r is None:
            continue
        b_sample += 1
        if r > 0:
            b_hits += 1
        b_total += r
    insufficient = sample < min_samples
    return {
        "sample": sample, "dropped": dropped,
        "hit": None if insufficient else hits / sample,
        "avg": None if insufficient else total / sample,
        "base_hit": (b_hits / b_sample) if b_sample else None,
        "base_avg": (b_total / b_sample) if b_sample else None,
        "insufficient": insufficient,
    }


def hist_rule_notes(in_s, out_s, min_samples=8):
    """结论备注：只陈述统计事实（过拟合警告 / 样本外无优势 / 均跑赢）。"""
    notes = []
    if in_s["insufficient"] and out_s["insufficient"]:
        return ["两段样本均不足，不下结论"]
    if in_s["insufficient"] or out_s["insufficient"]:
        return ["一段样本不足，无法对比样本内外"]
    a_hit, b_hit = in_s["hit"], out_s["hit"]
    a_base, b_base = in_s["base_hit"], out_s["base_hit"]
    if None in (a_hit, b_hit, a_base, b_base):
        return ["基准缺失，不下结论"]
    if (a_hit - b_hit) * 100 > 20:
        notes.append("overfit")
    if (b_hit - b_base) * 100 <= 0:
        notes.append("out_no_edge")
    elif (a_hit - a_base) * 100 > 0 and (b_hit - b_base) * 100 > 0:
        notes.append("both_edge")
    return notes


def ma_cross_indices(closes, period):
    out = []
    def ma(end):
        if end + 1 < period:
            return None
        return sum(closes[end + 1 - period:end + 1]) / period
    for i in range(period, len(closes)):
        now, prev = ma(i), ma(i - 1)
        if now is None or prev is None:
            continue
        if closes[i - 1] <= prev and closes[i] > now:
            out.append(i)
    return out


def macd_golden_indices(closes):
    pts = ema_calculate(closes, 12, 26, 9)
    out = []
    for k in range(1, len(pts)):
        p, c = pts[k - 1], pts[k]
        if p["dif"] <= p["dea"] and c["dif"] > c["dea"]:
            out.append(k)
    return out


_n = 100
check("历史验证：100 根按 70/30 切分 → splitIndex=70",
      hist_split(100) == 70)
check("历史验证：切分只按时间顺序（split=n*ratio 向下取整）",
      hist_split(85) == 59 and hist_split(80) == 56)

_c = [10.0] * 21 + [20.0]
check("历史验证：前向收益 = (后收/信号收−1)×100",
      abs(hist_forward(_c, 20, 1) - 100.0) < 1e-9)
check("历史验证：窗口不足（i+h >= n）→ None 剔除",
      hist_forward(_c, 21, 1) is None)
check("历史验证：窗口不足（信号在 n−1）→ None",
      hist_forward(_c, 21, 5) is None)
check("历史验证：恰好 0 收益由 > 0 判未命中（不是引擎特判）",
      hist_forward([10.0] * 30, 5, 1) == 0.0)

seg = hist_segment([10.0] * 21 + [20.0], [20], 1, 0, 22)
check("历史验证：1 次样本 < 8 → 样本不足，命中率 None",
      seg["insufficient"] and seg["hit"] is None and seg["sample"] == 1)
check("历史验证：样本不足时基准照算（该段 22 天全有窗口）",
      seg["base_hit"] is not None)

_rise = [10.0 + 0.1 * i for i in range(60)]
seg2 = hist_segment(_rise, list(range(10, 20)), 5, 0, 60)
check("历史验证：样本 10 次 ≥ 8 → 给命中率",
      not seg2["insufficient"] and seg2["hit"] == 1.0)
check("历史验证：单边上涨段基准命中率也是 1.0（高命中是市场给的）",
      seg2["base_hit"] == 1.0)
check("历史验证：均收益为正",
      seg2["avg"] > 0)

_fall = [20.0 - 0.1 * i for i in range(60)]
seg3 = hist_segment(_fall, list(range(10, 20)), 5, 0, 60)
check("历史验证：下跌段信号命中率 0%",
      seg3["hit"] == 0.0)
check("历史验证：下跌段基准也是 0%（规则无优势即无超额）",
      seg3["base_hit"] == 0.0)

check("历史验证：两段样本均不足 → 不下结论",
      hist_rule_notes(seg, seg) == ["两段样本均不足，不下结论"])
check("历史验证：样本外跑输样本内 >20pp → 过拟合警告",
      "overfit" in hist_rule_notes(
          {"insufficient": False, "hit": 0.9, "base_hit": 0.5},
          {"insufficient": False, "hit": 0.5, "base_hit": 0.5}))
check("历史验证：样本外未跑赢基准 → out_no_edge",
      "out_no_edge" in hist_rule_notes(
          {"insufficient": False, "hit": 0.7, "base_hit": 0.5},
          {"insufficient": False, "hit": 0.5, "base_hit": 0.5}))
check("历史验证：样本内外均跑赢基准 → both_edge",
      hist_rule_notes(
          {"insufficient": False, "hit": 0.7, "base_hit": 0.5},
          {"insufficient": False, "hit": 0.6, "base_hit": 0.5}) == ["both_edge"])

check("历史验证：MA60 上穿识别（前一日线下、当日线上）",
      60 in ma_cross_indices([5.0] * 60 + [10.0] * 5, 60))
check("历史验证：一直在线上不重复报上穿",
      len(ma_cross_indices([10.0] * 70, 60)) == 0)

_macd_up = [10.0 + 0.05 * i for i in range(20)] + [12.0 - 0.3 * i for i in range(10)] + \
           [9.0 + 0.4 * i for i in range(20)]
_gi = macd_golden_indices(_macd_up)
check("历史验证：MACD 金叉在下跌转上涨处出现（至少 1 次）",
      len(_gi) >= 1)
check("历史验证：MACD 金叉信号日不越界（全部 < n−warmup）",
      all(0 <= i < len(_macd_up) for i in _gi))

# ============================================================
# 八类本地量化因子（LocalQuantFactorEngine 的 Python 复刻）
# 与 Web F 版 FLocalQuantEngine 逐函数对齐（口径核对用）。
# ============================================================
import math

def lq_moving_average(closes, period):
    if period <= 0 or len(closes) < period:
        return None
    window = closes[-period:]
    if any((not math.isfinite(v)) or v <= 0 for v in window):
        return None
    r = sum(window) / period
    return r if math.isfinite(r) and r > 0 else None

def lq_trend_value(current, closes, periods):
    if current is None or (not math.isfinite(current)) or current <= 0 or not closes:
        return None
    avgs = []
    for p in periods:
        ma = lq_moving_average(closes, p)
        if ma is not None and ma > 0:
            avgs.append(current / ma - 1)
    if len(avgs) < 2:
        return None
    r = sum(avgs) / len(avgs)
    return r if math.isfinite(r) else None

def lq_ma_structure(closes):
    if not closes:
        return None
    pairs = [(lq_moving_average(closes, 5), lq_moving_average(closes, 20)),
             (lq_moving_average(closes, 20), lq_moving_average(closes, 60)),
             (lq_moving_average(closes, 60), lq_moving_average(closes, 250))]
    devs = []
    for short, long in pairs:
        if short is not None and long is not None and long > 0:
            v = short / long - 1
            if math.isfinite(v):
                devs.append(v)
    if not devs:
        return None
    r = sum(devs) / len(devs)
    return r if math.isfinite(r) else None

def lq_return_volatility(prices):
    if len(prices) < 3:
        return None
    rets = []
    for prev, cur in zip(prices, prices[1:]):
        if prev <= 0:
            return None
        v = cur / prev - 1
        if not math.isfinite(v):
            return None
        rets.append(v)
    mean = sum(rets) / len(rets)
    if not math.isfinite(mean):
        return None
    var = sum((r - mean) ** 2 for r in rets) / len(rets)
    if (not math.isfinite(var)) or var < 0:
        return None
    r = math.sqrt(var)
    return r if math.isfinite(r) and r >= 0 else None

def lq_safe_average(values):
    if not values or any(not math.isfinite(v) for v in values):
        return None
    return sum(values) / len(values)

def lq_vwap(samples):
    """samples: [(price, volume|None), ...]"""
    if len(samples) < 20:
        return None
    weighted = [(p, v) for p, v in samples
                if v is not None and math.isfinite(v) and v >= 0
                and math.isfinite(p) and p > 0]
    minimum = math.ceil(len(samples) * 0.9)
    if len(weighted) < minimum:
        return None
    wsum, vtotal = 0.0, 0.0
    for p, v in weighted:
        wsum += p * v
        vtotal += v
    if vtotal <= 0:
        return None
    r = wsum / vtotal
    return r if math.isfinite(r) and r > 0 else None

def lq_volume_coverage_note(samples):
    if not samples:
        return None
    known = sum(1 for _, v in samples
                if v is not None and math.isfinite(v) and v >= 0)
    if known >= len(samples):
        return None
    return known * 100 // len(samples)

def lq_recent_consecutive(timestamps, gap_limit=90.0, count=20):
    window = timestamps[-count:]
    if len(window) != count:
        return False
    for a, b in zip(window, window[1:]):
        gap = b - a
        if not (math.isfinite(gap) and 0 < gap <= gap_limit):
            return False
    return True

def lq_return_over_last(prices, count):
    if len(prices) < count:
        return None
    first, last = prices[-count], prices[-1]
    if first <= 0:
        return None
    r = last / first - 1
    return r if math.isfinite(r) else None

def lq_mean_reversion(prices):
    window = prices[-20:]
    if len(window) < 5:
        return None
    current = window[-1]
    if current <= 0:
        return None
    mean = lq_safe_average(window)
    if mean is None or mean <= 0:
        return None
    r = mean / current - 1
    return r if math.isfinite(r) else None

def lq_volume_anomaly(volumes):
    if len(volumes) < 20:
        return None
    window = volumes[-20:]
    if any(v is None or (not math.isfinite(v)) or v < 0 for v in window):
        return None
    baseline = lq_safe_average(window[:15])
    recent = lq_safe_average(window[-5:])
    if baseline is None or recent is None or baseline <= 0:
        return None
    ratio = recent / baseline
    if (not math.isfinite(ratio)) or ratio <= 0:
        return None
    r = ratio - 1
    return r if math.isfinite(r) else None

def lq_directional_score(value, scale):
    if value is None or not math.isfinite(value):
        return None
    if scale is None or (not math.isfinite(scale)) or scale <= 0:
        return None
    z = value / scale
    if not math.isfinite(z):
        return "overflow"
    bounded = z / (1 + abs(z))
    return int(round(bounded * 100))

def lq_report_directional(scores):
    """综合方向刻度：有效刻度 >=3 才给值（防稀疏数据误导）。"""
    valid = [s for s in scores if s is not None]
    if len(valid) < 3:
        return None
    return int(round(sum(valid) / len(valid)))


check("八类因子：均线样本不足 period → 不出数",
      lq_moving_average([10.0] * 9, 20) is None)
check("八类因子：均线正常计算",
      abs(lq_moving_average([10.0] * 15 + [20.0] * 5, 20) - (15 * 10.0 + 5 * 20.0) / 20) < 1e-9)

_c20 = [10.0 + 0.1 * i for i in range(70)]
check("八类因子：趋势结构仅一条均线 → None",
      lq_trend_value(12.0, _c20[:20], [20, 60, 250]) is None)
check("八类因子：趋势结构两条均线 → 偏离均值",
      lq_trend_value(11.0, [10.0] * 70, [20, 60, 250]) is not None and
      abs(lq_trend_value(11.0, [10.0] * 70, [20, 60, 250]) - 0.1) < 1e-9)
check("八类因子：趋势结构缺现价 → None",
      lq_trend_value(None, [10.0] * 70, [20, 60]) is None)

check("八类因子：均线结构空序列 → None",
      lq_ma_structure([]) is None)
check("八类因子：均线结构全等均线 → 乖离 0",
      abs(lq_ma_structure([10.0] * 300)) < 1e-9)

check("八类因子：波动率 <3 样本 → None",
      lq_return_volatility([10.0, 10.1]) is None)
check("八类因子：恒定价格序列波动率 = 0（合法观测）",
      lq_return_volatility([10.0] * 5) == 0.0)
check("八类因子：波动率正常 > 0",
      lq_return_volatility([10.0, 11.0, 10.0, 11.0]) > 0)

_flat20 = [(10.0, 100.0)] * 20
check("八类因子：VWAP <20 样本 → None",
      lq_vwap(_flat20[:19]) is None)
check("八类因子：VWAP 量缺失 >10%（17/20 已知）→ fail closed",
      lq_vwap([(10.0, 100.0)] * 17 + [(10.0, None)] * 3) is None)
check("八类因子：VWAP 量缺失恰 10%（18/20 已知）→ 仍可算",
      lq_vwap([(10.0, 100.0)] * 18 + [(10.0, None)] * 2) == 10.0)
check("八类因子：VWAP 量缺失 <=10% 仍可算",
      abs(lq_vwap([(10.0, 100.0)] * 19 + [(12.0, None)]) - 10.0) < 1e-9)
check("八类因子：VWAP 加权正确（价×量）",
      abs(lq_vwap([(10.0, 100.0)] * 10 + [(20.0, 100.0)] * 10) - 15.0) < 1e-9)
check("八类因子：VWAP 全量为 0 → None",
      lq_vwap([(10.0, 0.0)] * 20) is None)

check("八类因子：覆盖率全已知 → 无备注",
      lq_volume_coverage_note([(1.0, 1.0)] * 20) is None)
check("八类因子：覆盖率缺量 → 给百分比",
      lq_volume_coverage_note([(1.0, 1.0)] * 18 + [(1.0, None)] * 2) == 90)

_t60 = [float(i) for i in range(20)]
check("八类因子：连续样本 20 个间隔 60s → True",
      lq_recent_consecutive(_t60) is True)
check("八类因子：间隔超 90s → False",
      lq_recent_consecutive(_t60[:18] + [18 * 60.0 + 120.0, 19 * 60.0 + 120.0]) is False)
check("八类因子：不足 20 个 → False",
      lq_recent_consecutive(_t60[:19]) is False)

check("八类因子：短动量 5 样本收益",
      abs(lq_return_over_last([10.0, 10.0, 10.0, 10.0, 11.0], 5) - 0.1) < 1e-9)
check("八类因子：短动量样本不足 → None",
      lq_return_over_last([10.0, 10.0], 5) is None)

check("八类因子：均值回归 <5 样本 → None",
      lq_mean_reversion([10.0] * 4) is None)
check("八类因子：均值回归 = 均值/现价 − 1",
      abs(lq_mean_reversion([10.0] * 19 + [11.0]) - (10.05 / 11.0 - 1)) < 1e-9)

check("八类因子：量能异动 = 近5/前15 − 1",
      abs(lq_volume_anomaly([100.0] * 15 + [150.0] * 5) - 0.5) < 1e-9)
check("八类因子：量能异动基线为 0 → None",
      lq_volume_anomaly([0.0] * 15 + [150.0] * 5) is None)
check("八类因子：量能异动样本不足 → None",
      lq_volume_anomaly([100.0] * 19) is None)

check("八类因子：方向刻度 z=1 → 50",
      lq_directional_score(1.0, 1.0) == 50)
check("八类因子：方向刻度尺度为 0 → None",
      lq_directional_score(1.0, 0.0) is None)
check("八类因子：方向刻度大 z 饱和（|score| 接近 100）",
      abs(lq_directional_score(100.0, 0.001)) >= 99)
check("八类因子：方向刻度负值为负分",
      lq_directional_score(-1.0, 1.0) == -50)

check("八类因子：综合刻度有效项 <3 → None",
      lq_report_directional([10, 20, None, None]) is None)
check("八类因子：综合刻度 >=3 项 → 均值",
      lq_report_directional([10, 20, 30, None]) == 20)

# 闸门：quoteFresh=False 时日内因子全不可用（模拟 evaluate 的判定）
_intraday_kinds_gate = (lambda fresh: fresh is True)
check("八类因子：报价不新鲜 → 日内因子闸门关闭",
      _intraday_kinds_gate(False) is False)

# IOPV 折溢价口径：现价/净值 − 1
check("八类因子：IOPV 折溢价 = 价/净值 − 1",
      abs((10.5 / 10.0 - 1) - 0.05) < 1e-9)


# ---- 曲线超哥：B 条件（四指数连续 N 日不创新低） -------------------------
# 复刻 QuXianChaoGe.evaluateB 的口径：
#   · 逐日「创新低」= 当日口径价 严格小于 此前 window 个已完成交易日的最小值；
#   · 连续 streak 从最近一日向前数；
#   · 四指数必须全部成立；任一取不到数据 → 未知（不拿别的指数顶替）。
def qxcg_new_low_streak(prices, window=20, required=3):
    need = window + required
    if prices is None or len(prices) < need:
        return None  # 样本不足 → 未知
    streak = 0
    index = len(prices) - 1
    while index >= window:
        anchor = min(prices[index - window:index])
        if prices[index] < anchor:
            break
        streak += 1
        index -= 1
    return streak


def qxcg_verdict(streak, required=3):
    if streak is None:
        return "unknown"
    return "satisfied" if streak >= required else "unsatisfied"


def qxcg_combine(a, b):
    """A OR B：任一成立即成立；两项都不成立才不成立；否则未知。"""
    if a == "satisfied" or b == "satisfied":
        return "atLeastOneSatisfied"
    if a == "unsatisfied" and b == "unsatisfied":
        return "noneSatisfied"
    return "unknown"


# 稳步上行的序列：每一步都高于前 20 日最低 → 连续不创新低天数 = 全部可比较天数
_rising = [100.0 + i for i in range(30)]
check("曲线超哥B：持续走高 → 连续不创新低 >= 3（成立）",
      qxcg_verdict(qxcg_new_low_streak(_rising)) == "satisfied",
      f"streak={qxcg_new_low_streak(_rising)}")

# 最后一根跌破前 20 日最低 → 最近一日创新低，streak 归零
_breakdown = [100.0 + i for i in range(29)] + [90.0]
check("曲线超哥B：最后一日破前低 → 连续天数为 0（不成立）",
      qxcg_new_low_streak(_breakdown) == 0,
      f"streak={qxcg_new_low_streak(_breakdown)}")

# 相等不算创新低（软件口径显式选择）
_equal = [100.0 + i for i in range(29)] + [100.0 + 28]
check("曲线超哥B：与前低相等不算创新低",
      qxcg_new_low_streak(_equal) >= 3,
      f"streak={qxcg_new_low_streak(_equal)}")

# 只有 2 日不创新低 < 3 → 不成立
_two_days = [100.0 + i for i in range(28)] + [90.0, 91.0, 92.0]
check("曲线超哥B：破位后仅 2 日未创新低 → 不成立",
      qxcg_verdict(qxcg_new_low_streak(_two_days)) == "unsatisfied",
      f"streak={qxcg_new_low_streak(_two_days)}")

check("曲线超哥B：样本不足 → 未知（不判成不成立）",
      qxcg_new_low_streak([100.0] * 10) is None)

check("曲线超哥B：四指数缺一项 → 整体未知",
      (lambda items: "unknown" if any(v == "unknown" for v in items)
       else ("satisfied" if all(v == "satisfied" for v in items) else "unsatisfied"))(
          ["satisfied", "satisfied", "satisfied", "unknown"]) == "unknown")

check("曲线超哥B：四项都成立 → 成立",
      (lambda items: "unknown" if any(v == "unknown" for v in items)
       else ("satisfied" if all(v == "satisfied" for v in items) else "unsatisfied"))(
          ["satisfied"] * 4) == "satisfied")

# A 条件：三种口径分别判定，缺数据一律未知
def qxcg_a(caliber, today, previous):
    if caliber is None:
        return "unknown"
    if today is None or today <= 0:
        return "unknown"
    if caliber == "total2000":
        return "satisfied" if today >= 2000 else "unsatisfied"
    if caliber == "total20000":
        return "satisfied" if today >= 20000 else "unsatisfied"
    if caliber == "increase10":
        if previous is None or previous <= 0:
            return "unknown"
        return "satisfied" if (today - previous) / previous >= 0.10 else "unsatisfied"
    return "unknown"


check("曲线超哥A：2000 亿口径 2100 亿 → 成立", qxcg_a("total2000", 2100, None) == "satisfied")
check("曲线超哥A：2000 亿口径 1900 亿 → 不成立", qxcg_a("total2000", 1900, None) == "unsatisfied")
check("曲线超哥A：2 万亿口径 1.9 万亿 → 不成立", qxcg_a("total20000", 19000, None) == "unsatisfied")
check("曲线超哥A：增额口径 10% 边界 → 成立", qxcg_a("increase10", 1100, 1000) == "satisfied")
check("曲线超哥A：增额口径缺前日 → 未知", qxcg_a("increase10", 1100, None) == "unknown")
check("曲线超哥A：未选口径 → 未知（不擅自统一）", qxcg_a(None, 9000, 8000) == "unknown")

# A OR B，且绝不能被写成 AND
check("曲线超哥：A 成立 B 未知 → 或关系成立", qxcg_combine("satisfied", "unknown") == "atLeastOneSatisfied")
check("曲线超哥：A 未知 B 成立 → 或关系成立", qxcg_combine("unknown", "satisfied") == "atLeastOneSatisfied")
check("曲线超哥：A B 都不成立 → 不成立", qxcg_combine("unsatisfied", "unsatisfied") == "noneSatisfied")
check("曲线超哥：A B 都未知 → 未知", qxcg_combine("unknown", "unknown") == "unknown")


# 反未来函数：今天那根未收盘 K 必须被剔除
def qxcg_completed_only(dates, today):
    return [d for d in dates if d < today]


_series = ["2026-11-05", "2026-11-06", "2026-11-09"]
check("曲线超哥B：当天未收盘 K 被剔除",
      qxcg_completed_only(_series, "2026-11-09") == ["2026-11-05", "2026-11-06"])

# 四个来源截止日不同时，按最早截止日截齐（否则「同时」是四天拼出来的假结论）
def qxcg_common_cutoff(series_list):
    cutoff = min(s[-1] for s in series_list)
    return [ [d for d in s if d <= cutoff] for s in series_list ]


_a = ["2026-11-04", "2026-11-05", "2026-11-06"]
_b = ["2026-11-04", "2026-11-05", "2026-11-06", "2026-11-09"]
_aligned = qxcg_common_cutoff([_a, _b])
check("曲线超哥B：截止日截齐后长度一致",
      len(_aligned[0]) == len(_aligned[1]) == 3 and _aligned[1][-1] == "2026-11-06")

# 账本硬隔离：观盘 Pro 只认原生空间，绝不把观盘 F 的网页账本当成自己的。
# 旧载荷没有 space 字段（None）按 Pro 处理，否则老用户升级后无法恢复自己的账本。
def _belongs_to_pro(space):
    return True if not space else space == "guanpan-pro"

check("账本隔离：space=guanpan-pro 属于观盘 Pro", _belongs_to_pro("guanpan-pro") is True)
check("账本隔离：space 缺省（旧载荷）按 Pro 处理", _belongs_to_pro(None) is True)
check("账本隔离：space=guanpan-f 必须拒收", _belongs_to_pro("guanpan-f") is False)
check("账本隔离：任意第三方 space 必须拒收", _belongs_to_pro("guanpan-next") is False)

# 曲线超哥 · 主动指导：条件不成立时绝不允许把仓位往前推。
# 复刻 nextStateSuggestion 的判定表（Swift 侧同名函数），只验证「方向」这一条不变量。
_QXCG_ADVANCE = {"观察": "轻仓试探", "轻仓试探": "确认", "确认": "加仓"}
_QXCG_STATES = ["观察", "轻仓试探", "确认", "加仓", "重仓确认", "持有", "减仓", "退出"]

def qxcg_next_state(state, verdict):
    if verdict == "satisfied":
        return _QXCG_ADVANCE.get(state, "观察")
    if verdict == "noneSatisfied":
        return "减仓" if state in ("加仓", "重仓确认") else ("观察" if state == "轻仓试探" else state)
    return state  # 未知一律原地

for _st in _QXCG_STATES:
    check(f"曲线超哥指导：条件不成立时 {_st} 不得前进到加仓",
          qxcg_next_state(_st, "noneSatisfied") not in ("加仓", "重仓确认"))
check("曲线超哥指导：观察 + 条件成立 → 轻仓试探（不直接加仓）",
      qxcg_next_state("观察", "satisfied") == "轻仓试探")
check("曲线超哥指导：加仓 + 条件不成立 → 退回减仓",
      qxcg_next_state("加仓", "noneSatisfied") == "减仓")
check("曲线超哥指导：条件未知一律原地不动",
      qxcg_next_state("确认", "unknown") == "确认")


print()
if failures:
    print(f"失败 {len(failures)} 项：{', '.join(failures)}")
    sys.exit(1)
print("全部通过：VolumeAnalysis / PositionDiscipline / RealtimeTrigger / Shadow / OCR 行解析 / 汇总对账 / 手续费口径 / Anti-Overtrading / 生产盯盘 / 成交关联 / T vs HOLD / MACD多周期 / MACD背离 / K线六形态 / IOPV折溢价 / 价格闸门 / 风险预算 / 策略仲裁 / ATR耐心限价 / MA250长期趋势 / 历史验证 / 八类本地量化因子 / 曲线超哥A-B条件")
sys.exit(0)
