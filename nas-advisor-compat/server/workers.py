"""Independent NAS workers. No worker reads the mobile sync preference."""
import json
import threading
import time
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo
from market import symbol_for, fetch_daily, fetch_quotes, fetch_dividend_events

SHANGHAI = ZoneInfo("Asia/Shanghai")
# Collection follows explicitly tracked symbols and the real book.  The old
# preview's hard-coded demo symbols must not start a parallel research account.
DEFAULT_CODES = ()


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


def start_workers(database, daily_fetcher=fetch_daily, minute_fetcher=fetch_minute, quote_fetcher=fetch_quotes):
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

    for name, target in (("daily-archive", daily_loop), ("minute-archive", minute_loop), ("dividend-research", dividend_loop), ("factor-research", research_loop)):
        threading.Thread(target=target, name=name, daemon=True).start()
