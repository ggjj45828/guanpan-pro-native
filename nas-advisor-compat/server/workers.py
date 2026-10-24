"""Independent NAS workers. No worker reads the mobile sync preference."""
import json
import re
import threading
import time
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo
from market import (symbol_for, fetch_daily, fetch_quotes, fetch_dividend_events,
                    fetch_eastmoney_cross_market_minute, CROSS_MARKET_EASTMONEY_SECIDS)

SHANGHAI = ZoneInfo("Asia/Shanghai")
# Collection follows explicitly tracked symbols and the real book.  The old
# preview's hard-coded demo symbols must not start a parallel research account.
DEFAULT_CODES = ()
CROSS_MARKET_TENCENT_SYMBOLS = {
    "CN_SSE": "sh000001", "CN_SZSE": "sz399001", "CN_CHINEXT": "sz399006",
    "CN_STAR50": "sh000688", "CN_CSI300": "sh000300", "CN_CSI500": "sh000905",
    "CN_A500": "sh000510", "CN_SEMICONDUCTOR": "sz399989",
}
CROSS_MARKET_SERIES = tuple(CROSS_MARKET_TENCENT_SYMBOLS) + tuple(CROSS_MARKET_EASTMONEY_SECIDS)
EXTERNAL_MARKET_SESSIONS = {
    "JP_N225": ("Asia/Tokyo", (("09:00", "11:30"), ("12:30", "15:30"))),
    "KR_KOSPI": ("Asia/Seoul", (("09:00", "15:30"),)),
    "HK_HSI": ("Asia/Hong_Kong", (("09:30", "12:00"), ("13:00", "16:00"))),
    "US_NDX": ("America/New_York", (("09:30", "16:00"),)),
    "US_SPX": ("America/New_York", (("09:30", "16:00"),)),
}


def market_session_open(market_id, now=None):
    """Nominal weekday session gate; the provider timestamp still decides freshness."""
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise ValueError("market session time must be timezone-aware")
    if market_id in CROSS_MARKET_TENCENT_SYMBOLS:
        local = now.astimezone(SHANGHAI)
        minute = local.hour * 60 + local.minute
        return local.weekday() < 5 and ((570 <= minute <= 690) or (780 <= minute <= 900))
    timezone_name, sessions = EXTERNAL_MARKET_SESSIONS[market_id]
    local = now.astimezone(ZoneInfo(timezone_name))
    minute = local.hour * 60 + local.minute
    return local.weekday() < 5 and any(
        int(start[:2]) * 60 + int(start[3:]) <= minute <= int(end[:2]) * 60 + int(end[3:])
        for start, end in sessions)


def market_session_key(market_id, now):
    if market_id in CROSS_MARKET_TENCENT_SYMBOLS:
        timezone_name, sessions = "Asia/Shanghai", (("09:30", "11:30"), ("13:00", "15:00"))
    else:
        timezone_name, sessions = EXTERNAL_MARKET_SESSIONS[market_id]
    local = now.astimezone(ZoneInfo(timezone_name))
    minute = local.hour * 60 + local.minute
    period = next((index for index, (start, end) in enumerate(sessions)
                   if int(start[:2]) * 60 + int(start[3:]) <= minute <=
                   int(end[:2]) * 60 + int(end[3:])), 0)
    return f"{local.date().isoformat()}-{period}"


def fetch_cross_market_series(market_id):
    if market_id in CROSS_MARKET_TENCENT_SYMBOLS:
        return fetch_cross_market_minute(market_id)
    if market_id in CROSS_MARKET_EASTMONEY_SECIDS:
        return fetch_eastmoney_cross_market_minute(market_id)
    raise ValueError("unsupported cross-market series")


def collect_cross_market_once(database, *, now=None, series_ids=None, fetcher=None,
                              stale_failures=None, suppressed_sessions=None):
    """One testable collection cycle; persist only active-session, validated source rows."""
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise ValueError("collection time must be timezone-aware")
    series_ids = tuple(CROSS_MARKET_SERIES if series_ids is None else series_ids)
    nominal = [market_id for market_id in series_ids if market_session_open(market_id, now)]
    if not nominal:
        return {"state": "idle", "active": [], "collected": 0, "failures": [],
                "detail": "no configured market is in its nominal session; stale or holiday data is not promoted"}
    stale_failures = stale_failures if stale_failures is not None else {}
    suppressed_sessions = suppressed_sessions if suppressed_sessions is not None else {}
    active = [market_id for market_id in nominal
              if suppressed_sessions.get(market_id) != market_session_key(market_id, now)]
    if not active:
        return {"state": "idle", "active": nominal, "collected": 0, "failures": [],
                "detail": "providers returned repeated stale/holiday data; collection paused for this market session"}
    fetcher = fetcher or fetch_cross_market_series
    failures, collected, paused = [], 0, []
    for market_id in active:
        try:
            rows, source = fetcher(market_id)
            database.put_cross_market_minute(market_id, rows, source,
                                             now.astimezone(timezone.utc).isoformat())
            stale_failures.pop(market_id, None)
            collected += 1
        except Exception as error:
            failures.append(f"{market_id}:{type(error).__name__}")
            message = str(error).lower()
            if isinstance(error, ValueError) and ("stale" in message or "non-current session" in message):
                stale_failures[market_id] = stale_failures.get(market_id, 0) + 1
                if stale_failures[market_id] >= 3:
                    suppressed_sessions[market_id] = market_session_key(market_id, now)
                    paused.append(market_id)
            else:
                stale_failures.pop(market_id, None)
    state = "ok" if not failures else "degraded"
    detail = f"{collected}/{len(active)} open-market minute series archived; provider timestamps checked; next attempt in 5m"
    if failures: detail += "; failed " + ", ".join(failures[:8])
    if paused: detail += "; stale source paused until next session: " + ", ".join(paused)
    return {"state": state, "active": nominal, "collected": collected, "failures": failures,
            "paused": paused,
            "detail": detail}


def parse_minute(body, code):
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end < start: raise ValueError("invalid minute response")
    node = json.loads(body[start:end + 1]).get("data", {}).get(symbol_for(code), {}).get("data", {})
    day = node.get("date", "")
    rows = node.get("data") or node.get("items")
    if not isinstance(rows, list) or len(day) != 8 or not day.isdigit(): raise ValueError("minute source missing")
    result = {}
    last_volume = None
    for row in rows:
        parts = row.split() if isinstance(row, str) else []
        if len(parts) < 2 or len(parts[0]) != 4 or not parts[0].isdigit(): continue
        try:
            hour, minute = int(parts[0][:2]), int(parts[0][2:])
            price = Decimal(parts[1]); cumulative = Decimal(parts[2]) if len(parts) > 2 else None
            if not (9 <= hour <= 15 and 0 <= minute <= 59 and price.is_finite() and price > 0): continue
            if cumulative is not None and (not cumulative.is_finite() or cumulative < 0): continue
            stamp = datetime.strptime(day + parts[0], "%Y%m%d%H%M").replace(tzinfo=SHANGHAI)
            if stamp > datetime.now(timezone.utc): continue
            volume = str(cumulative - last_volume) if cumulative is not None and last_volume is not None and cumulative >= last_volume else None
            if cumulative is not None: last_volume = cumulative
            result[stamp.isoformat()] = {"timestamp": stamp.isoformat(), "price": str(price), "volume": volume, "iopv": None}
        except (ValueError, ArithmeticError): continue
    if not result: raise ValueError("no validated minute rows")
    return [result[key] for key in sorted(result)]


def fetch_minute(code):
    symbol = symbol_for(code)
    url = "https://web.ifzq.gtimg.cn/appstock/app/minute/query?" + urlencode({"code": symbol, "_var": "min_data_" + symbol})
    with urlopen(Request(url, headers={"Referer": "https://gu.qq.com/", "User-Agent": "GuanpanProNext/3"}), timeout=12) as response:
        if response.status != 200: raise OSError("minute source unavailable")
        return parse_minute(response.read(2_000_000).decode("utf-8"), code)


def parse_cross_market_minute(body, symbol, now=None, max_age_seconds=600):
    """Parse Tencent minute data for a whitelisted mainland benchmark index."""
    if symbol not in CROSS_MARKET_TENCENT_SYMBOLS.values():
        raise ValueError("unsupported cross-market benchmark")
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end < start: raise ValueError("invalid benchmark minute response")
    node = json.loads(body[start:end + 1]).get("data", {}).get(symbol, {}).get("data", {})
    day, rows = node.get("date", ""), node.get("data") or node.get("items")
    if not isinstance(rows, list) or len(day) != 8 or not day.isdigit():
        raise ValueError("benchmark minute source missing")
    if datetime.strptime(day, "%Y%m%d").date() != now.astimezone(SHANGHAI).date():
        raise ValueError("benchmark minute source returned a non-current session")
    found = {}
    for row in rows:
        parts = row.split() if isinstance(row, str) else []
        if len(parts) < 2 or re.fullmatch(r"\d{4}", parts[0]) is None: continue
        try:
            stamp = datetime.strptime(day + parts[0], "%Y%m%d%H%M").replace(tzinfo=SHANGHAI)
            price = Decimal(parts[1])
            if stamp.astimezone(timezone.utc) > now.astimezone(timezone.utc): continue
            if not price.is_finite() or price <= 0: continue
        except (ValueError, InvalidOperation, TypeError, OverflowError): continue
        found[stamp.isoformat()] = {"timestamp": stamp.isoformat(), "price": str(price),
                                    "volume": None, "iopv": None}
    if not found: raise ValueError("benchmark minute response has no current-session samples")
    rows = [found[stamp] for stamp in sorted(found)]
    latest = datetime.fromisoformat(rows[-1]["timestamp"])
    age = (now.astimezone(timezone.utc) - latest.astimezone(timezone.utc)).total_seconds()
    if age < 0 or age > max_age_seconds:
        raise ValueError("benchmark minute source is stale")
    return rows


def fetch_cross_market_minute(market_id):
    symbol = CROSS_MARKET_TENCENT_SYMBOLS.get(market_id)
    if symbol is None: raise ValueError("unsupported cross-market benchmark")
    url = "https://web.ifzq.gtimg.cn/appstock/app/minute/query?" + urlencode(
        {"code": symbol, "_var": "min_data_" + symbol})
    request = Request(url, headers={"Referer": "https://gu.qq.com/",
                                    "User-Agent": "GuanpanProNext/3"})
    with urlopen(request, timeout=12) as response:
        if response.status != 200: raise OSError("benchmark minute source unavailable")
        body = response.read(2_000_000).decode("utf-8", "strict")
    return parse_cross_market_minute(body, symbol), "Tencent minute " + symbol


def attach_quote_iopv(rows, quote):
    """Attach only a same-session, near-time ETF IOPV to the latest sample."""
    if not rows or not quote or not quote.get("iopv") or quote.get("providerInstrumentType") != "ETF":
        return rows
    quote_time = datetime.fromisoformat(quote["time"])
    last_time = datetime.fromisoformat(rows[-1]["timestamp"])
    if quote_time.astimezone(SHANGHAI).date() == last_time.astimezone(SHANGHAI).date() and abs((quote_time - last_time).total_seconds()) <= 300:
        rows[-1]["iopv"] = quote["iopv"]
    return rows


def research_factors(code, bars):
    """Traceable local factor research; no model-generated claims or real trading."""
    closes = [Decimal(row["close"]) for row in bars]
    if len(closes) < 250: return None
    ma20 = sum(closes[-20:]) / 20
    ma250 = sum(closes[-250:]) / 250
    delta = closes[-1] / closes[-21] - 1
    drawdown = closes[-1] / max(closes[-20:]) - 1
    return {"code": code, "asOf": bars[-1]["date"], "close": str(closes[-1]),
        "ma20": str(ma20), "ma250": str(ma250), "momentum20": str(delta),
        "drawdown20": str(drawdown), "state": "观察" if closes[-1] >= ma250 and delta > 0 else "谨慎",
        "source": "NAS archived Tencent qfqday", "type": "local-factor-research", "realOrder": False}


def tracked_codes(database):
    """Return only explicitly tracked instruments and positive real NAS holdings.

    Archived rows are evidence, not authorization to keep polling an instrument.
    In particular this prevents old preview/demo archives from becoming permanent
    upstream API consumers after upgrading the service.
    """
    holdings = set()
    try:
        stored = database.get_real("main")
        book = json.loads(stored["bookJSON"]) if stored.get("bookJSON") else {}
        for position in book.get("positions", []):
            if position.get("units", 0) > 0:
                code = position.get("code")
                symbol_for(code)
                holdings.add(code)
    except (ValueError, TypeError, KeyError):
        pass
    return sorted(set(DEFAULT_CODES) | set(database.tracked_instruments()) | holdings)


def start_workers(database, daily_fetcher=fetch_daily, minute_fetcher=fetch_minute,
                  quote_fetcher=fetch_quotes, cross_market_fetcher=fetch_cross_market_minute):
    """Each loop owns its own timer and failure handling; sync APIs never stop them."""
    def tracked():
        return tracked_codes(database)

    def update(name, state, detail):
        database.put_worker_status(name, datetime.now(timezone.utc).isoformat(), state, detail[:500])

    def missing_note(failed):
        """把失败代码与异常类型写进 detail。

        只报 "6/7 codes archived" 时无从下手：不知道是哪一只、也不知道是抓不到
        还是解析失败。这里点名到代码（最多 8 只），排查直接省掉一轮翻日志。
        """
        if not failed:
            return ""
        return "; missing " + ", ".join(failed[:8]) + ("…" if len(failed) > 8 else "")

    def daily_loop():
        update("daily-archive", "starting", "worker starting")
        while True:
            codes = tracked(); failures = []
            for code in codes:
                try: database.put_daily(code, daily_fetcher(code), datetime.now(timezone.utc).isoformat())
                except Exception as error: failures.append(f"{code}:{type(error).__name__}")  # Last verified archive stays available.
            update("daily-archive", "ok" if not failures else "degraded",
                   f"{len(codes) - len(failures)}/{len(codes)} codes archived (Tencent→Eastmoney fallback); next run in 30m{missing_note(failures)}")
            time.sleep(1800)

    def minute_loop():
        update("minute-archive", "starting", "worker starting")
        while True:
            local = datetime.now(SHANGHAI)
            if local.weekday() < 5 and ((9, 15) <= (local.hour, local.minute) <= (11, 35) or (13, 0) <= (local.hour, local.minute) <= (15, 5)):
                codes = tracked(); failures = []
                for code in codes:
                    try:
                        rows = minute_fetcher(code)
                        quote = next(iter(quote_fetcher([code])), None)
                        attach_quote_iopv(rows, quote)
                        database.put_minute(code, rows, datetime.now(timezone.utc).isoformat())
                    except Exception as error: failures.append(f"{code}:{type(error).__name__}")
                update("minute-archive", "ok" if not failures else "degraded",
                       f"{len(codes) - len(failures)}/{len(codes)} codes collected; Tencent minute source; next attempt in 1m{missing_note(failures)}")
            else:
                update("minute-archive", "idle", "outside mainland market collection window; historical archive remains available")
            time.sleep(60)

    def dividend_loop():
        update("dividend-research", "starting", "dividend collector starting")
        while True:
            codes = tracked(); failures = []; collected = 0
            for code in codes:
                try:
                    events = fetch_dividend_events(code)
                    database.put_dividend_events(code, events, datetime.now(timezone.utc).isoformat())
                    collected += 1
                except Exception as error: failures.append(f"{code}:{type(error).__name__}")
            update("dividend-research", "ok" if not failures else "degraded",
                   f"{collected}/{len(codes)} codes checked; ETF F10 events separated from qfq/raw estimates; history retained{missing_note(failures)}")
            time.sleep(86400)

    def research_loop():
        update("factor-research", "starting", "worker starting")
        while True:
            codes = tracked(); failures = []; researched = 0
            for code in codes:
                try:
                    data = database.get_daily(code)
                    result = research_factors(code, data["bars"]) if data else None
                    if result:
                        database.put_research("factors-" + code, result)
                        researched += 1
                except Exception as error: failures.append(f"{code}:{type(error).__name__}")
            update("factor-research", "ok" if not failures else "degraded",
                   f"{researched}/{len(codes)} codes have usable 250-day research; next run in 15m{missing_note(failures)}")
            time.sleep(900)

    def cross_market_loop():
        update("cross-market-minute", "starting", "verified mainland and global index minute collectors starting")
        stale_failures = {}; suppressed_sessions = {}
        while True:
            now = datetime.now(timezone.utc)
            def current_cross_market_fetcher(market_id):
                if market_id in CROSS_MARKET_TENCENT_SYMBOLS:
                    return cross_market_fetcher(market_id)
                return fetch_cross_market_series(market_id)
            result = collect_cross_market_once(database, now=now, fetcher=current_cross_market_fetcher,
                                               stale_failures=stale_failures,
                                               suppressed_sessions=suppressed_sessions)
            update("cross-market-minute", result["state"], result["detail"])
            if result["active"]:
                time.sleep(300)
            else:
                time.sleep(60)

    for name, target in (("daily-archive", daily_loop), ("minute-archive", minute_loop),
                         ("dividend-research", dividend_loop), ("factor-research", research_loop),
                         ("cross-market-minute", cross_market_loop)):
        threading.Thread(target=target, name=name, daemon=True).start()
