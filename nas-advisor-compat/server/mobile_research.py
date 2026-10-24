"""Read-only bridge from the existing NAS archive to phone-side research.

This never reads or writes virtual accounts and never computes an order price.
The Tencent minute cumulative-volume unit has not been verified, so volume and
VWAP are intentionally absent from the mobile evidence.
"""
from __future__ import annotations

import json
import math
from collections import defaultdict
from datetime import datetime, time, timezone, timedelta
from decimal import Decimal, InvalidOperation
from zoneinfo import ZoneInfo

CN = ZoneInfo("Asia/Shanghai")


def milliseconds(stamp):
    try:
        value = datetime.fromisoformat(stamp)
        if value.tzinfo is None:
            return None
        return int(value.timestamp() * 1000)
    except (TypeError, ValueError, OverflowError):
        return None


def price_units(value):
    try:
        number = Decimal(str(value)) * 10000
        if not number.is_finite() or number <= 0 or number != number.to_integral_value():
            return None
        result = int(number)
        return result if result < 2**53 else None
    except (InvalidOperation, TypeError, ValueError, OverflowError):
        return None


def minute_summary(rows, now_ms):
    by_day = defaultdict(set)
    for raw in rows:
        try:
            row = json.loads(raw[0]); stamp = datetime.fromisoformat(row["timestamp"])
            if stamp.tzinfo is None or not price_units(row.get("price")):
                continue
            local = stamp.astimezone(CN); clock = local.time()
            if (int(stamp.timestamp() * 1000) > now_ms or local.weekday() >= 5 or
                    not (time(9, 30) <= clock < time(11, 30) or time(13) <= clock < time(15))):
                continue
            by_day[local.date().isoformat()].add(local.strftime("%H:%M"))
        except (KeyError, TypeError, ValueError, OverflowError):
            continue
    sessions = sorted(by_day)[-120:]
    complete = sum(len(by_day[day]) >= 200 for day in sessions)
    return {"source": "guanpan2 archived Tencent minute prices", "sessions": len(sessions),
            "samplePoints": sum(len(by_day[day]) for day in sessions),
            "firstDay": sessions[0] if sessions else None,
            "lastDay": sessions[-1] if sessions else None,
            "completeMinuteDays": complete,
            "volumeCoverage": 0, "minuteEvidence": [],
            "windows": {str(n): {"available": len(sessions) >= n,
                                   "sessions": min(n, len(sessions))} for n in (5, 20, 60, 120)},
            "status": "insufficient-history-or-coverage", "pricePlansAllowed": False,
            "limitations": ["分钟成交量单位未经供应商核验，不能计算可靠 VWAP 或具体挂单价"]}


def snapshot(database, market_fetcher, now=None):
    now = now or datetime.now(timezone.utc)
    now_ms = int(now.timestamp() * 1000)
    with database.connect() as db:
        codes = [row[0] for row in db.execute(
            "SELECT code FROM tracked_instruments UNION SELECT code FROM daily_bars "
            "UNION SELECT DISTINCT code FROM minute_archive ORDER BY code LIMIT 60").fetchall()]
    try:
        quotes = {row["code"]: row for row in market_fetcher(codes)} if codes else {}
    except Exception:
        quotes = {}
    instruments = []
    for code in codes:
        bars = []
        stored = database.get_daily(code)
        for item in (stored or {}).get("bars", [])[-640:]:
            day = item.get("date")
            at = milliseconds(day + "T15:00:00+08:00") if isinstance(day, str) else None
            values = {key: price_units(item.get(key)) for key in ("open", "high", "low", "close")}
            if at is None or at > now_ms or any(value is None for value in values.values()):
                continue
            bars.append({"at": at, "availableAt": now_ms, **values})
        quote = quotes.get(code)
        quote_at = milliseconds(quote.get("time")) if isinstance(quote, dict) else None
        quote_price = price_units(quote.get("price")) if isinstance(quote, dict) else None
        with database.connect() as db:
            minutes = db.execute("SELECT body FROM minute_archive WHERE code=? ORDER BY stamp DESC LIMIT 30000", (code,)).fetchall()
        asset = "etf" if code.startswith(("15", "16", "50", "51", "52", "56", "58", "59")) and not code.startswith("508") else "stock"
        row = {"symbol": code, "asset": asset, "source": "guanpan2 NAS archive",
               "evidenceIDs": ["guanpan2:" + code], "bars": bars,
               "intradayResearch": minute_summary(minutes, now_ms)}
        # Eastmoney fallback currently stamps reception time, not the exchange
        # event time.  It must not become apparently fresh trading evidence.
        if (quote_at is not None and 0 < quote_at <= now_ms and quote_price is not None
                and quote.get("source") == "Tencent qt.gtimg.cn"):
            row["quote"] = {"at": quote_at, "price": quote_price}
        instruments.append(row)
    research = {"asOf": now_ms, "scope": "NAS archived tracked symbols; phone filters to real holdings",
                "universeComplete": False, "instruments": instruments, "books": [],
                "news": [], "availabilityNote": "只读历史证据；成交量单位未核验，不提供 VWAP 或限价"}
    return {"ok": True, "source": "guanpan2-read-only-adapter", "generatedAt": now.isoformat(),
            "revision": 0, "data": {"quality": {"researchSnapshot": research}}}
