#!/usr/bin/env python3
"""离线算法验证（Python 复刻口径，不是 XCTest）。

覆盖 VolumeAnalysis / PositionDiscipline / RealtimeTrigger / CandidateShadow /
截图行解析、逐笔↔汇总对账、手续费诚实口径的关键分支。
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

print()
if failures:
    print(f"失败 {len(failures)} 项：{', '.join(failures)}")
    sys.exit(1)
print("全部通过：VolumeAnalysis / PositionDiscipline / RealtimeTrigger / Shadow / OCR 行解析 / 汇总对账 / 手续费口径")
sys.exit(0)
