"""NAS 长期分时统计：把一分钟归档变成「可解释的窗口结论」。

为什么单独一个模块：
- 做 T / 网格要的是「这只标的在 1/5/20/60/120 日尺度上到底怎么走」，
  而手机端只能拿到当日分时。长期结论必须在 NAS 上算，算完给手机一个确定的数字，
  而不是让大模型凭感觉描述。
- 每个数字都要能追到来源：窗口内用了几天、多少分钟、缺了多少、最后一条是几点。
  数据不完整就明确标出来，界面据此降级（不给精确挂单价），绝不假装完整。

所有函数都是纯函数（输入分钟行，输出 dict），方便单测。
分钟行结构：{"timestamp": "2026-10-23T09:31:00+08:00", "price": "0.836",
            "volume": "12000", "iopv": "0.835"}（volume/iopv 可为 None）
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from statistics import median, pstdev

WINDOWS = (1, 5, 20, 60, 120)
# 一个正常交易日的主板连续竞价分钟数：上午 120 + 下午 120。
MINUTES_PER_DAY = 240
SHANGHAI_OFFSET = timezone(timedelta(hours=8))


def _d(value, default=None):
    if value is None:
        return default
    try:
        result = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        return default
    return result if result.is_finite() else default


def _quantile(values, q):
    """线性插值分位数。values 需已排序或本函数会排序。"""
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    lower = int(pos)
    upper = min(lower + 1, len(ordered) - 1)
    weight = pos - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def _parse_stamp(text):
    try:
        stamp = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=SHANGHAI_OFFSET)
    return stamp.astimezone(SHANGHAI_OFFSET)


def group_by_day(rows):
    """把分钟行按交易日分组，组内按时间升序，并丢掉无效行（价格缺失/<=0）。"""
    days = {}
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        stamp = _parse_stamp(row.get("timestamp"))
        price = _d(row.get("price"))
        if stamp is None or price is None or price <= 0:
            continue
        days.setdefault(stamp.date().isoformat(), []).append(
            {"at": stamp, "price": price, "volumeObserved": _d(row.get("volume")) is not None,
             "volume": _d(row.get("volume"), Decimal("0")),
             "iopv": _d(row.get("iopv"))})
    for day in days.values():
        day.sort(key=lambda item: item["at"])
    return days


def day_metrics(day_rows, expected=MINUTES_PER_DAY):
    """单日口径：VWAP、日内高低、振幅、往返次数、成交量、完整度。"""
    if not day_rows:
        return None
    prices = [item["price"] for item in day_rows]
    volumes = [item["volume"] or Decimal("0") for item in day_rows]
    total_volume = sum(volumes)
    if total_volume > 0:
        vwap = sum(p * v for p, v in zip(prices, volumes)) / total_volume
    else:  # 没有成交量（部分源不返回）时退化为时间等权均价，并在 complete 里标注
        vwap = sum(prices) / Decimal(len(prices))
    high, low = max(prices), min(prices)
    mid = (high + low) / 2
    # 往返次数：价格穿越当日中位价的次数，衡量"一天来回几次"，是做 T 的可行性依据。
    center = median(prices)
    crossings, side = 0, None
    for price in prices:
        current = 1 if price >= center else -1
        if side is not None and current != side:
            crossings += 1
        side = current
    return {
        "day": day_rows[0]["at"].date().isoformat(),
        "open": prices[0],
        "close": prices[-1],
        "high": high,
        "low": low,
        "vwap": vwap,
        "amplitudePercent": float((high - low) / mid * 100) if mid > 0 else 0.0,
        "roundTrips": crossings,
        "volume": total_volume,
        "turnover": sum(p * v for p, v in zip(prices, volumes)),
        "minutes": len(day_rows),
        "expectedMinutes": expected,
        "completeness": min(1.0, len(day_rows) / expected) if expected else 0.0,
        "firstAt": day_rows[0]["at"],
        "lastAt": day_rows[-1]["at"],
        "hasVolume": total_volume > 0,
        "volumeCoverage": sum(1 for item in day_rows if item.get("volumeObserved")) / len(day_rows),
        "vwapHighDeviation": float((high / vwap - 1) if vwap > 0 else 0),
        "vwapLowDeviation": float((low / vwap - 1) if vwap > 0 else 0),
    }


def window_stats(days, window, now=None):
    """某个窗口（1/5/20/60/120 日）的统计结论。days 为 day_metrics 列表（按日期升序）。"""
    now = now or datetime.now(SHANGHAI_OFFSET)
    if window <= 0 or not days:
        return None
    selected = days[-window:]
    closes = [d["close"] for d in selected]
    vwaps = [d["vwap"] for d in selected]
    volumes = [d["volume"] for d in selected]
    last = selected[-1]
    total_volume = sum(volumes)
    window_vwap = (sum(v * vol for v, vol in zip(vwaps, volumes)) / total_volume
                   if total_volume > 0 else sum(vwaps) / Decimal(len(vwaps)))
    highs = [d["high"] for d in selected]
    lows = [d["low"] for d in selected]
    returns = []
    for previous, current in zip(closes, closes[1:]):
        if previous > 0:
            returns.append(float((current - previous) / previous))
    volume_weighted_prices = []
    for d in selected:
        if d["volume"] > 0:
            volume_weighted_prices.append(float(d["vwap"]))
    return {
        "window": window,
        "daysUsed": len(selected),
        "expectedDays": window,
        "dayCoverage": round(len(selected) / window, 4),
        "minuteCoverage": round(sum(d["completeness"] for d in selected) / len(selected), 4),
        "volumeCoverage": round(sum(d["volumeCoverage"] for d in selected) / len(selected), 4),
        "vwap": str(window_vwap.quantize(Decimal("0.0001"))),
        "closeVsVwapPercent": (round(float((last["close"] - window_vwap) / window_vwap * 100), 3)
                               if window_vwap > 0 else None),
        "amplitudeMedianPercent": round(median([d["amplitudePercent"] for d in selected]), 3),
        "amplitudeP80Percent": round(float(_quantile([d["amplitudePercent"] for d in selected], 0.8) or 0), 3),
        "roundTripsMedian": round(median([d["roundTrips"] for d in selected]), 2),
        "vwapHighDeviationMedian": round(median([d["vwapHighDeviation"] for d in selected]), 5),
        "vwapLowDeviationMedian": round(median([d["vwapLowDeviation"] for d in selected]), 5),
        "support": str(min(lows).quantize(Decimal("0.0001"))),
        "resistance": str(max(highs).quantize(Decimal("0.0001"))),
        "supportP10": str(Decimal(str(round(float(_quantile([float(v) for v in lows], 0.1) or 0), 4)))),
        "resistanceP90": str(Decimal(str(round(float(_quantile([float(v) for v in highs], 0.9) or 0), 4)))),
        "closeBandP20": str(Decimal(str(round(float(_quantile([float(c) for c in closes], 0.2) or 0), 4)))),
        "closeBandP80": str(Decimal(str(round(float(_quantile([float(c) for c in closes], 0.8) or 0), 4)))),
        "volatilityPercent": round(pstdev(returns) * 100, 4) if len(returns) >= 2 else None,
        "avgTurnover": str((total_volume and sum(d["turnover"] for d in selected) / Decimal(len(selected))
                            or Decimal("0")).quantize(Decimal("0.01"))),
        "avgVolume": str((total_volume / Decimal(len(selected))).quantize(Decimal("0.01"))),
        "densePriceLow": str(Decimal(str(round(float(_quantile(volume_weighted_prices, 0.2)), 4)))) if volume_weighted_prices else None,
        "densePriceHigh": str(Decimal(str(round(float(_quantile(volume_weighted_prices, 0.8)), 4)))) if volume_weighted_prices else None,
        "lastDay": last["day"],
    }


def freshness(rows, now=None):
    """数据新鲜度：最后一条分钟距现在多少分钟、最后一天是不是今天。"""
    now = now or datetime.now(SHANGHAI_OFFSET)
    stamps = [_parse_stamp(row.get("timestamp")) for row in rows or [] if isinstance(row, dict)]
    stamps = [s for s in stamps if s is not None]
    if not stamps:
        return {"lastAt": None, "ageMinutes": None, "lastDay": None, "stale": True,
                "reason": "没有分时归档"}
    last = max(stamps)
    age = max(0.0, (now - last).total_seconds() / 60)
    today = now.date().isoformat()
    return {
        "lastAt": last.isoformat(),
        "ageMinutes": round(age, 1),
        "lastDay": last.date().isoformat(),
        "isToday": last.date().isoformat() == today,
        # 隔夜不算过期：开盘前最后一笔是昨天收盘很正常。
        "stale": age > 60 * 24,
        "reason": "" if age <= 60 * 24 else f"最后一条分时是 {last.date().isoformat()}，超过一天",
    }


def minute_stats(rows, now=None, windows=WINDOWS):
    """总入口：分钟行 → {windows: {...}, freshness: {...}, quality: {...}}。"""
    now = now or datetime.now(SHANGHAI_OFFSET)
    days_map = group_by_day(rows)
    days = [day_metrics(days_map[key]) for key in sorted(days_map)]
    days = [d for d in days if d]
    fresh = freshness(rows, now)
    windows_out = {}
    for window in windows:
        stats = window_stats(days, window, now)
        if stats:
            windows_out[str(window)] = stats
    total_minutes = sum(d["minutes"] for d in days)
    volume_coverage = (sum(d["volumeCoverage"] * d["minutes"] for d in days) / total_minutes
                       if total_minutes else 0.0)
    return {
        "source": "NAS 1-minute archive",
        "days": len(days),
        "minutes": total_minutes,
        "firstDay": days[0]["day"] if days else None,
        "lastDay": days[-1]["day"] if days else None,
        "freshness": fresh,
        "quality": {
            "days": len(days),
            "minuteCoverage": round(sum(d["completeness"] for d in days) / len(days), 4) if days else 0.0,
            "volumeCoverage": round(volume_coverage, 4),
            "hasVolume": any(d["hasVolume"] for d in days),
            # 精确候选价需要至少60个有效交易日、分钟与成交量都达到80%覆盖。
            "enoughForLongTerm": len(days) >= 60 and
                (sum(d["completeness"] for d in days) / len(days)) >= 0.8 and volume_coverage >= 0.8 if days else False,
        },
        "windows": windows_out,
        "daily": [
            {"day": d["day"], "close": str(d["close"]), "vwap": str(d["vwap"].quantize(Decimal("0.0001"))),
             "high": str(d["high"]), "low": str(d["low"]),
             "amplitudePercent": round(d["amplitudePercent"], 3), "roundTrips": d["roundTrips"],
             "minutes": d["minutes"], "completeness": round(d["completeness"], 3)}
            for d in days[-20:]
        ],
    }
