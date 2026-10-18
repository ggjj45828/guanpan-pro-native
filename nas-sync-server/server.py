#!/usr/bin/env python3
"""观盘 Pro 一体化服务器：网页托管 + 行情代理 + 双分区同步（网页版 / App 版）

设计要点
--------
1. 免口令：局域网自用，所有接口直接放行（也仍接受 tok 参数，填了也不会错）。
2. 行情代理：网页版经 NAS 取行情；iOS 优先直连，失败时再用 NAS 兜底。
3. 双分区：网页版走 legacy，App 版走 native，互不干扰，可并存。
4. 防误删：两条通道都拒绝"空数据覆盖已有账本"。
5. SQLite 存储：自动保留最近 10 个历史版本，并永久保存后台采集的分时点。
"""
from __future__ import annotations

import hmac
import json
import os
import re
import socket
import sqlite3
from contextlib import closing
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from channel_store import ChannelStore, route as channel_route
from market_data import MarketArchive
from market_runtime import MarketRuntime, route as market_route

V2_RUNTIME = None

DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
DB_PATH = DATA_DIR / "sync.sqlite3"
WEB_DIR = Path(__file__).resolve().parent / "web"
MAX_BODY = int(os.environ.get("MAX_BODY_BYTES", str(256 * 1024 * 1024)))
WRITE_LOCK = threading.Lock()
UPSTREAM_TIMEOUT = float(os.environ.get("UPSTREAM_TIMEOUT", "12"))

# 同步口令：留空 = 免口令（局域网自用）。设了之后 /api/data 与
# /api/native/data 需要口令；行情代理与 ping 始终免口令（行情是公开数据，
# 且网页要靠 ping 判断代理是否可用）。口令来源：?tok= / Bearer / body.tok
SYNC_TOKEN = os.environ.get("SYNC_TOKEN", "").strip()
SYNC_PATHS = {"/api/data", "/api/native/data", "/api/market/archive"}

# ----------------------------------------------------------------- 行情上游
UA = {
    'User-Agent': ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                   '(KHTML, like Gecko) Chrome/120.0 Safari/537.36'),
    'Referer': 'https://gu.qq.com/',
}

# K 线多域名降级：主源不通时自动换备源，成功的源会被记住一段时间。
KLINE_HOSTS = [
    'https://proxy.finance.qq.com/ifzqgtimg/appstock/app/',
    'https://ifzq.gtimg.cn/ifzqgtimg/appstock/app/',
    'https://web.ifzq.gtimg.cn/ifzqgtimg/appstock/app/',
]
KLINE_STATE = {"host": KLINE_HOSTS[0], "lock": threading.Lock()}


def _kline_url(base: str, q: dict) -> str:
    # Web view injects K-line responses as a script and reads the `_var` global.
    # Preserve that callback through the NAS proxy, otherwise a successful JSONP
    # response is executed without assigning the variable the browser is polling.
    callback = q.get('_var') or 'klineResult'
    if not re.fullmatch(r'[A-Za-z_$][A-Za-z0-9_$]{0,79}', callback):
        raise ValueError('K线回调名无效')
    params = urllib.parse.urlencode({
        '_var': callback,
        'param': (q.get('code', '') + ',' + (q.get('period') or 'day') + ',,,'
                  + (q.get('n') or '640') + ',' + (q.get('fq') or 'qfq')),
    })
    return base + 'newfqkline/get?' + params


UPSTREAM = {
    'quote': lambda q: 'https://qt.gtimg.cn/q=' + q.get('codes', ''),
    'pe': lambda q: 'https://qt.gtimg.cn/q=' + q.get('codes', ''),
    'fx': lambda q: 'https://hq.sinajs.cn/list=' + q.get('codes', ''),
    'minute': lambda q: minute_url(q),
    'hold': lambda q: ('https://fundf10.eastmoney.com/FundArchivesDatas.aspx?'
                       'type=jjcc&code=' + q.get('code', '')
                       + '&topline=' + (q.get('topline') or '50')
                       + '&year=&month='),
    'fundinfo': lambda q: ('https://fund.eastmoney.com/pingzhongdata/'
                           + q.get('code', '') + '.js'),
}


def minute_url(q: dict) -> str:
    """Build Tencent's A-share or US minute JSONP URL, retaining the caller callback."""
    symbol = str(q.get("code", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9]{2,20}", symbol):
        raise ValueError("分时代码无效")
    callback = str(q.get("_var") or "minuteResult").strip()
    if not re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]{0,79}", callback):
        raise ValueError("分时回调名无效")
    market = "usMinute" if symbol.lower().startswith("us") else "minute"
    host = "web.ifzq.gtimg.cn" if market == "usMinute" else "ifzq.gtimg.cn"
    return (f"https://{host}/appstock/app/{market}/query?_var="
            + urllib.parse.quote(callback, safe="") + "&code="
            + urllib.parse.quote(symbol, safe=""))


def collector_minute_url(symbol: str) -> str:
    """Build the correct Tencent minute endpoint for the NAS background collector."""
    query = urllib.parse.urlencode({"code": symbol, "_t": str(int(time.time()))})
    if symbol.lower().startswith("us"):
        return "https://web.ifzq.gtimg.cn/appstock/app/usMinute/query?" + query
    return "https://ifzq.gtimg.cn/appstock/app/minute/query?" + query


def us_eastern_time(now: datetime) -> datetime:
    """Convert aware time to US Eastern, including DST, without OS tzdata."""
    utc = now.astimezone(timezone.utc)
    year = utc.year
    # US DST: second Sunday in March at 07:00 UTC through first Sunday in
    # November at 06:00 UTC. This avoids requiring tzdata in Alpine containers.
    march_first = datetime(year, 3, 1, tzinfo=timezone.utc)
    first_sunday = 1 + (6 - march_first.weekday()) % 7
    dst_start = datetime(year, 3, first_sunday + 7, 7, tzinfo=timezone.utc)
    november_first = datetime(year, 11, 1, tzinfo=timezone.utc)
    dst_end = datetime(year, 11, 1 + (6 - november_first.weekday()) % 7, 6, tzinfo=timezone.utc)
    offset = timedelta(hours=-4 if dst_start <= utc < dst_end else -5)
    return utc.astimezone(timezone(offset))


def market_session_open(symbol: str, now: datetime) -> bool:
    """Whether this symbol's exchange is in its regular minute-collection window."""
    if symbol.lower().startswith("us"):
        local = us_eastern_time(now)
        minute = local.hour * 60 + local.minute
        return local.weekday() < 5 and 9 * 60 + 25 <= minute <= 16 * 60 + 5
    local = now.astimezone(timezone(timedelta(hours=8)))
    minute = local.hour * 60 + local.minute
    return local.weekday() < 5 and (
        9 * 60 + 15 <= minute <= 11 * 60 + 35 or
        12 * 60 + 55 <= minute <= 15 * 60 + 10
    )


def http_get(url: str, headers: dict | None = None, timeout: float | None = None):
    req = urllib.request.Request(url, headers=headers or UA)
    with urllib.request.urlopen(req, timeout=timeout or UPSTREAM_TIMEOUT) as r:
        return r.read(), r.headers.get('Content-Type', '')


def fetch_kline(q: dict):
    """K 线：按记忆顺序尝试三个域名，成功即记住。"""
    tried = []
    with KLINE_STATE["lock"]:
        order = [KLINE_STATE["host"]] + [h for h in KLINE_HOSTS if h != KLINE_STATE["host"]]
    last = None
    for base in order:
        tried.append(base)
        try:
            body, ct = http_get(_kline_url(base, q))
            with KLINE_STATE["lock"]:
                KLINE_STATE["host"] = base
            return body, ct
        except Exception as exc:  # noqa: BLE001 - 逐个降级
            last = exc
    raise RuntimeError("K线三个源都失败：%s" % last)


def q_get(path: str, key: str) -> str | None:
    for k, v in urllib.parse.parse_qsl(path.split("?", 1)[1] if "?" in path else ""):
        if k == key:
            return v
    return None


# ------------------------------------------------------------------- 工具
def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def connect() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DB_PATH, timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")
    db.execute("""CREATE TABLE IF NOT EXISTS latest (
        namespace TEXT PRIMARY KEY, revision INTEGER NOT NULL,
        updated_at TEXT NOT NULL, payload TEXT NOT NULL)""")
    db.execute("""CREATE TABLE IF NOT EXISTS history (
        namespace TEXT NOT NULL, revision INTEGER NOT NULL,
        updated_at TEXT NOT NULL, payload TEXT NOT NULL,
        PRIMARY KEY(namespace, revision))""")
    # 行情档案与账户同步版本分表保存，避免每分钟采集都制造账本新版本。
    db.execute("""CREATE TABLE IF NOT EXISTS market_watchlist (
        code TEXT PRIMARY KEY, symbol TEXT NOT NULL, name TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1, updated_at TEXT NOT NULL)""")
    db.execute("""CREATE TABLE IF NOT EXISTS market_intraday (
        code TEXT NOT NULL, day TEXT NOT NULL, minute_epoch INTEGER NOT NULL,
        price REAL NOT NULL, volume REAL, source TEXT NOT NULL, captured_at TEXT NOT NULL,
        iopv REAL,
        PRIMARY KEY(code, minute_epoch))""")
    # Upgrade existing NAS databases in place; never discard archived bars.
    columns = {row[1] for row in db.execute("PRAGMA table_info(market_intraday)")}
    if "iopv" not in columns:
        db.execute("ALTER TABLE market_intraday ADD COLUMN iopv REAL")
    db.execute("""CREATE TABLE IF NOT EXISTS market_collector (
        id INTEGER PRIMARY KEY CHECK(id=1), last_cycle_at TEXT, last_success_at TEXT,
        last_error TEXT, symbols INTEGER NOT NULL DEFAULT 0, bars INTEGER NOT NULL DEFAULT 0)""")
    db.execute("INSERT OR IGNORE INTO market_collector(id) VALUES(1)")
    return db


def tencent_symbol(code: str) -> str:
    c = re.sub(r"[^A-Za-z0-9]", "", str(code)).lower()
    if c.startswith(("sh", "sz", "bj", "hk", "us")): return c
    if len(c) != 6 or not c.isdigit(): return ""
    if c.startswith(("5", "6", "9")): return "sh" + c
    if c.startswith(("0", "1", "2", "3")): return "sz" + c
    if c.startswith(("4", "8")): return "bj" + c
    return ""


def sync_market_watchlist(payload: object) -> None:
    if not isinstance(payload, dict): return
    data = payload.get("data") if isinstance(payload.get("data"), dict) else payload
    if not isinstance(data, dict): return
    items: dict[str, tuple[str, str]] = {}
    for key in ("quotes", "holdings"):
        values = data.get(key, [])
        if not isinstance(values, list): continue
        for row in values:
            if not isinstance(row, dict): continue
            if key == "holdings" and row.get("kind") not in ("etf", "stock", "security", None): continue
            code = str(row.get("code", "")).strip()
            symbol = tencent_symbol(code)
            if symbol: items[code] = (symbol, str(row.get("name") or code))
    # 常用指数由 NAS 一并采集，App 离线打开指数页也能读到已归档分钟线。
    for symbol, name in (("sh000001", "上证指数"), ("sz399001", "深证成指"),
                         ("sz399006", "创业板指"), ("sh000300", "沪深300"),
                         ("sh000688", "科创50"), ("usNDX", "纳斯达克100"),
                         ("usINX", "标普500")):
        items[symbol] = (symbol, name)
    now = utc_now()
    with WRITE_LOCK, closing(connect()) as db:
        db.execute("UPDATE market_watchlist SET active=0")
        db.executemany("""INSERT INTO market_watchlist(code,symbol,name,active,updated_at)
            VALUES(?,?,?,1,?) ON CONFLICT(code) DO UPDATE SET symbol=excluded.symbol,
            name=excluded.name, active=1, updated_at=excluded.updated_at""",
            [(c, s, n, now) for c, (s, n) in items.items()])


def seed_market_archive(payload: object) -> int:
    """Import minute bars already present in the NAS native snapshot once on boot."""
    if not isinstance(payload, dict): return 0
    bars = payload.get("intradayBars", [])
    if not isinstance(bars, list): return 0
    grouped: dict[str, list[dict]] = {}
    for bar in bars:
        if not isinstance(bar, dict): continue
        code = str(bar.get("code", "")).strip()
        stamp = bar.get("timestamp")
        try:
            if isinstance(stamp, (int, float)):
                # Swift JSONEncoder's default reference date is 2001-01-01.
                epoch = int(stamp + 978307200)
                local = datetime.fromtimestamp(epoch, timezone(timedelta(hours=8)))
            else:
                local = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
                if local.tzinfo is None: local = local.replace(tzinfo=timezone.utc)
                local = local.astimezone(timezone(timedelta(hours=8)))
                epoch = int(local.timestamp())
            day = str(bar.get("day") or local.strftime("%Y-%m-%d"))[:10]
            price = float(bar.get("price"))
            volume = float(bar["volume"]) if bar.get("volume") is not None else None
            if not code or price <= 0 or len(day) != 10: continue
            iopv = bar.get("iopv")
            try: iopv = float(iopv) if iopv is not None else None
            except (ValueError, TypeError): iopv = None
            grouped.setdefault(code, []).append({"timestamp": epoch, "day": day, "price": price, "volume": volume, "iopv": iopv})
        except (ValueError, TypeError, OverflowError): continue
    return sum(save_market_bars(code, values, "app-import") for code, values in grouped.items())


def parse_tencent_minute(raw: bytes, symbol: str) -> list[dict]:
    try:
        text = raw.decode("utf-8", "ignore")
        root = json.loads(text[text.index("{"):text.rindex("}") + 1])
        nodes = root.get("data", {})
        node = nodes.get(symbol) or next((v for k, v in nodes.items() if k.lower() == symbol.lower()), None)
        payload = (node or {}).get("data", node or {})
        rows = payload.get("data") or payload.get("items") or []
        dayraw = str(payload.get("date") or (node or {}).get("date") or "")
        day = (dayraw[:4] + "-" + dayraw[4:6] + "-" + dayraw[6:8]) if len(dayraw) == 8 else dayraw[:10]
        if len(day) != 10: return []
        tz = timezone(timedelta(hours=8)); out = []; previous = 0.0
        for row in rows:
            f = str(row).split()
            if len(f) < 2: continue
            try:
                price = float(f[1]); cumulative = float(f[2]) if len(f) > 2 else None
                stamp = datetime.strptime(day + " " + f[0], "%Y-%m-%d %H:%M").replace(tzinfo=tz)
            except (ValueError, TypeError): continue
            if price <= 0: continue
            volume = max(0.0, cumulative - previous) if cumulative is not None else None
            if cumulative is not None: previous = cumulative
            out.append({"timestamp": int(stamp.timestamp()), "day": day, "price": price, "volume": volume})
        return out
    except (ValueError, TypeError, KeyError, AttributeError, json.JSONDecodeError): return []


def is_etf_symbol(symbol: str) -> bool:
    """Tencent symbols for mainland exchange-traded funds (not stocks, indices, or REITs).

    Mirrors the App's `isTencentETFCode`: the 6-digit code (after the sh/sz
    exchange prefix) carries an ETF prefix, but REITs — infrastructure/fund
    codes starting with 508 or 180 — are explicitly excluded because they have
    no intraday IOPV and their field 78 would otherwise be misread.
    """
    value = symbol.lower()
    if not value.startswith(("sh", "sz")):
        return False
    code = value[2:]
    if code.startswith(("508", "180")):   # REIT — not an ETF
        return False
    return code.startswith(("15", "16", "18", "50", "51", "52", "56", "58", "59"))


def parse_tencent_iopv_quote(raw: bytes, symbol: str) -> float | None:
    """Read Tencent snapshot field 78 (zero-based) as the ETF's live IOPV.

    Self-gates on ETF identity so a non-ETF's field 78 (which carries an
    unrelated figure) is never mistaken for IOPV. This mirrors the App's
    `parseTencent` / `isTencentETFCode`: a symbol is treated as an ETF when
    Tencent's security-type field (index 61) says "ETF", or its 6-digit code
    carries an ETF prefix. REITs (508 / 180) are explicitly excluded — they
    have no intraday IOPV, and their field 78 would otherwise be misread.
    """
    text = raw.decode("utf-8", "ignore")
    match = re.search(r"(?:^|;)\s*v_" + re.escape(symbol) + r'="([^"\r\n]*)"', text, re.IGNORECASE)
    if not match:
        # Some responses contain only one assignment and omit the usual v_ prefix.
        match = re.search(r'="([^"\r\n]*)"', text)
    if not match: return None
    fields = match.group(1).split("~")
    if len(fields) <= 78: return None
    # --- ETF 识别，与 App 端 isETF 一致 ---
    is_etf = False
    if len(fields) > 61:
        is_etf = str(fields[61]).strip().upper() == "ETF"
    if not is_etf and is_etf_symbol(symbol):
        is_etf = True
    if not is_etf:
        return None
    try:
        value = float(fields[78])
        return value if value > 0 and value < 1_000_000 and value == value else None
    except (ValueError, TypeError): return None


def save_market_bars(code: str, bars: list[dict], source: str = "tencent") -> int:
    if not bars: return 0
    now = utc_now()
    rows = [(code, b["day"], b["timestamp"], b["price"], b.get("volume"), source, now, b.get("iopv")) for b in bars]
    with closing(connect()) as db:
        before = db.total_changes
        db.executemany("""INSERT INTO market_intraday(code,day,minute_epoch,price,volume,source,captured_at,iopv)
            VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(code,minute_epoch) DO UPDATE SET
            day=excluded.day, price=excluded.price,
            volume=COALESCE(excluded.volume,market_intraday.volume),
            source=excluded.source,captured_at=excluded.captured_at,
            iopv=COALESCE(excluded.iopv,market_intraday.iopv)
            WHERE market_intraday.day<>excluded.day OR market_intraday.price<>excluded.price
            OR (excluded.volume IS NOT NULL AND market_intraday.volume IS NOT excluded.volume)
            OR (excluded.iopv IS NOT NULL AND market_intraday.iopv IS NOT excluded.iopv)""", rows)
        return db.total_changes - before


def market_archive(query: dict) -> dict:
    after = max(0, int(query.get("after", "0") or 0))
    offset = max(0, int(query.get("offset", "0") or 0))
    limit = min(20000, max(1, int(query.get("limit", "10000") or 10000)))
    code = str(query.get("code", "")).strip()
    with closing(connect()) as db:
        where = "minute_epoch>?"; args: list[object] = [after]
        if code: where += " AND code=?"; args.append(code)
        rows = db.execute(f"SELECT code,day,minute_epoch,price,volume,iopv FROM market_intraday WHERE {where} ORDER BY minute_epoch,code LIMIT ? OFFSET ?", (*args, limit + 1, offset)).fetchall()
        status = db.execute("SELECT last_cycle_at,last_success_at,last_error,symbols,bars FROM market_collector WHERE id=1").fetchone()
        total = db.execute(f"SELECT COUNT(*) FROM market_intraday WHERE {where}", args).fetchone()[0]
    more = len(rows) > limit; rows = rows[:limit]
    return {"ok": True, "bars": [{"code": r["code"], "day": r["day"], "timestamp": datetime.fromtimestamp(r["minute_epoch"], timezone(timedelta(hours=8))).isoformat(), "price": r["price"], "volume": r["volume"], "iopv": r["iopv"]} for r in rows],
            "total": total, "offset": offset, "limit": limit, "nextOffset": offset + len(rows), "hasMore": more,
            "collector": dict(status) if status else {}}


def collector_loop() -> None:
    while True:
        try:
            now = datetime.now(timezone(timedelta(hours=8)))
            with closing(connect()) as db:
                symbols = db.execute("SELECT code,symbol FROM market_watchlist WHERE active=1").fetchall()
            captured = 0; succeeded = 0; errors = []; attempted = 0
            for item in symbols:
                # Keep minute cadence during that symbol's own session. Outside
                # session, a 10-minute fetch is enough to let the provider publish
                # its completed day, without repeatedly polling unrelated markets.
                market_open = market_session_open(item["symbol"], now)
                if not market_open and now.minute % 10 != 0:
                    continue
                attempted += 1
                try:
                    url = collector_minute_url(item["symbol"])
                    raw, _ = http_get(url, timeout=8)
                    bars = parse_tencent_minute(raw, item["symbol"])
                    # Tencent's minute series has no IOPV. Read its live quote
                    # snapshot field 78 separately and attach it only to the
                    # current minute bar; never smear today's live IOPV across
                    # the older minute bars returned by the upstream endpoint.
                    # parse_tencent_iopv_quote self-gates on ETF identity so a
                    # REIT / stock is never mistaken for having an IOPV.
                    if bars and market_open and is_etf_symbol(item["symbol"]):
                        try:
                            quote_url = "https://qt.gtimg.cn/q=" + urllib.parse.quote(item["symbol"], safe="")
                            quote_raw, _ = http_get(quote_url, timeout=8)
                            iopv = parse_tencent_iopv_quote(quote_raw, item["symbol"])
                            if iopv is not None:
                                now_epoch = int(time.time())
                                latest = max(bars, key=lambda bar: bar["timestamp"])
                                if latest["day"] == now.strftime("%Y-%m-%d") and abs(latest["timestamp"] - now_epoch) <= 300:
                                    latest["iopv"] = iopv
                        except Exception as exc: errors.append(item["symbol"] + " IOPV: " + str(exc)[:120])
                    if bars: succeeded += 1
                    else: errors.append(item["symbol"] + ": no minute bars")
                    captured += save_market_bars(item["code"], bars)
                    if V2_RUNTIME is not None:
                        V2_RUNTIME.ingest_minutes(item["code"], bars)
                except Exception as exc: errors.append(str(exc)[:180])
            cycle_at = utc_now()
            with closing(connect()) as db:
                db.execute("""UPDATE market_collector SET last_cycle_at=?,
                    last_success_at=CASE WHEN ?>0 THEN ? ELSE last_success_at END,
                    last_error=?,symbols=?,bars=? WHERE id=1""",
                    (cycle_at, succeeded, cycle_at, "; ".join(errors[:3]) or None, attempted, captured))
        except Exception as exc:
            try:
                with closing(connect()) as db: db.execute("UPDATE market_collector SET last_cycle_at=?,last_error=? WHERE id=1", (utc_now(), str(exc)[:300]))
            except Exception: pass
        # 盘中每分钟；闭市后 10 分钟查一次，用于补齐源端完整日线。
        # One-minute scheduler while either supported exchange is open; each
        # symbol is independently throttled above. Otherwise check every 10 min.
        active_session = any(market_session_open(row["symbol"], now) for row in symbols) if 'symbols' in locals() else False
        time.sleep(60 if active_session else 600)


def read_snapshot(namespace: str) -> dict:
    with closing(connect()) as db:
        row = db.execute("SELECT revision, updated_at, payload FROM latest WHERE namespace=?",
                         (namespace,)).fetchone()
    if not row:
        return {"revision": 0, "updatedAt": None, "data": None}
    return {"revision": row["revision"], "updatedAt": row["updated_at"],
            "data": json.loads(row["payload"])}


def write_snapshot(namespace: str, payload: object, expected_revision: int | None = None,
                   allow_empty_overwrite: bool = False) -> dict:
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    now = utc_now()
    with WRITE_LOCK, closing(connect()) as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT revision,payload FROM latest WHERE namespace=?", (namespace,)).fetchone()
        current = int(row["revision"]) if row else 0
        if expected_revision is not None and expected_revision != current:
            db.execute("ROLLBACK")
            return {"conflict": True, "revision": current}
        if row and contains_user_data(json.loads(row["payload"])) and not contains_user_data(payload) and not allow_empty_overwrite:
            db.execute("ROLLBACK")
            return {"conflict": True, "revision": current, "err": "empty_overwrite_blocked"}
        revision = current + 1
        db.execute("INSERT INTO latest(namespace,revision,updated_at,payload) VALUES(?,?,?,?) "
                   "ON CONFLICT(namespace) DO UPDATE SET revision=excluded.revision, "
                   "updated_at=excluded.updated_at, payload=excluded.payload",
                   (namespace, revision, now, encoded))
        db.execute("INSERT INTO history(namespace,revision,updated_at,payload) VALUES(?,?,?,?)",
                   (namespace, revision, now, encoded))
        db.execute("DELETE FROM history WHERE namespace=? AND revision <= ?",
                   (namespace, max(0, revision - 10)))
        db.execute("COMMIT")
    return {"conflict": False, "revision": revision, "updatedAt": now}


def contains_user_data(payload: object) -> bool:
    """判断这份数据里有没有真实账本内容（用于防误删）。"""
    if not isinstance(payload, dict):
        return False
    data = payload.get("data") if isinstance(payload.get("data"), dict) else payload
    if isinstance(data, dict):
        # Real web backups use nested db.hold/trades and fund.hold/trades.
        # A cash-zero account can still contain valuable positions and history.
        for section, fields in (("db", ("hold", "watch", "trades")), ("fund", ("hold", "trades"))):
            nested = data.get(section)
            if isinstance(nested, dict) and any(isinstance(nested.get(k), list) and nested[k] for k in fields):
                return True
        if any(isinstance(data.get(k), list) and data[k] for k in ("tr", "cashlog", "snap")):
            return True
        for key in ("holdings", "ledger", "fundTransactions", "fundNAVHistory",
                    "fundFeePolicies", "fundDCAPlans", "cashFlows", "snapshots",
                    "quotes", "quoteAlerts", "allocationTargets", "tradePlans",
                    "dayGridPlans", "legacyGridArchives", "legacyShadowArchives",
                    "legacyDCAEvents", "legacySettingsArchives", "intradayBars",
                    "dailyBars", "hold", "watch", "funds"):
            value = data.get(key)
            if isinstance(value, list) and value:
                return True
        cash = data.get("cash", 0)
        if isinstance(cash, (int, float)) and cash != 0:
            return True
        if data.get("cashLinkedByDefault") or data.get("appearance", "system") != "system" \
                or data.get("quoteRefreshSeconds", 60) != 60:
            return True
        profile = data.get("investmentProfile")
        defaults = {"style": "swing", "risk": "bal", "maxPositionPercent": 35,
                    "horizon": "1-3个月", "premiumSensitive": True, "preference": "",
                    "avoid": "", "method": "", "goal": ""}
        if isinstance(profile, dict) and any(profile.get(k, v) != v for k, v in defaults.items()):
            return True
    for key in ("intradayBars", "dailyBars"):
        value = payload.get(key)
        if isinstance(value, list) and value:
            return True
    return False


def guard_empty_overwrite(namespace: str, payload: dict, allow: bool) -> dict | None:
    """服务器已有真实数据，却收到空数据时拒绝。返回 None 表示放行。"""
    current = read_snapshot(namespace)
    if contains_user_data(current["data"]) and not contains_user_data(payload) and not allow:
        return {"err": "服务器已有账本数据；拒绝空数据覆盖。请先下载，"
                       "或确认后带 allowEmptyOverwrite=true 上传。",
                "revision": current["revision"]}
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "GuanpanNAS/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        pass  # 安静运行，不刷日志

    # ------------------------------------------------------------ 基础响应
    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type,Authorization")
        self.send_header("Access-Control-Max-Age", "86400")

    def send_json(self, code: int, obj: dict, cors: bool = True) -> None:
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        if cors:
            self._cors()
        self.end_headers()
        try:
            self.wfile.write(raw)
        except OSError:
            pass

    def send_bytes(self, raw: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        try:
            self.wfile.write(raw)
        except OSError:
            pass

    def send_static(self, path: str) -> None:
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        if rel in ("", "."):
            rel = "index.html"
        file_path = (WEB_DIR / rel).resolve()
        if WEB_DIR.resolve() not in file_path.parents and file_path != WEB_DIR.resolve():
            self.send_json(403, {"err": "路径不合法"}, cors=False)
            return
        if not file_path.is_file():
            self.send_json(404, {"err": "网页版文件未打包"}, cors=False)
            return
        try:
            raw = file_path.read_bytes()
        except OSError:
            self.send_json(503, {"err": "网页版文件未打包"}, cors=False)
            return
        ct = "text/html; charset=utf-8"
        if file_path.suffix.lower() == ".json":
            ct = "application/json; charset=utf-8"
        elif file_path.suffix.lower() in (".js", ".mjs"):
            ct = "application/javascript; charset=utf-8"
        elif file_path.suffix.lower() == ".css":
            ct = "text/css; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self._cors()
        self.end_headers()

    def authorized(self, body: dict | None = None) -> bool:
        """没设 SYNC_TOKEN 时一律放行；设了则校验 ?tok= / Bearer / body.tok。"""
        if not SYNC_TOKEN:
            return True
        parsed = urlparse(self.path)
        supplied = self.headers.get("Authorization", "")
        if supplied.lower().startswith("bearer "):
            supplied = supplied[7:].strip()
        else:
            supplied = parse_qs(parsed.query).get("tok", [""])[0]
        if not supplied and body:
            supplied = str(body.get("tok", ""))
        return bool(supplied) and hmac.compare_digest(supplied.encode(), SYNC_TOKEN.encode())

    def read_body(self) -> dict:
        size = int(self.headers.get("Content-Length", "0"))
        if size <= 0 or size > MAX_BODY:
            raise ValueError("请求内容为空或超过大小限制")
        parsed = json.loads(self.rfile.read(size).decode("utf-8"))
        if not isinstance(parsed, dict):
            raise ValueError("请求必须是 JSON 对象")
        return parsed

    # ------------------------------------------------------------ 行情代理
    def do_proxy(self, kind: str, qs: str) -> None:
        q = dict(urllib.parse.parse_qsl(qs, keep_blank_values=True))
        url = ""
        try:
            if kind == "kline":
                # kline 走多源降级，最终 URL 由 fetch_kline 内部决定
                raw, ct = fetch_kline(q)
                if not raw.strip():
                    raise RuntimeError("K线数据源返回空内容")
                # K 线通过 script 标签加载（JSONP），统一用脚本 MIME 类型返回。
                ct = "application/javascript; charset=utf-8"
            else:
                url = UPSTREAM[kind](q)
                raw, ct = http_get(url)
            if "javascript" in ct or url.endswith(".js"):
                ct = "application/javascript; charset=utf-8"
            elif not ct:
                ct = "application/octet-stream"
            self.send_bytes(raw, ct)
        except KeyError:
            self.send_json(400, {"err": "未知的代理类型"})
        except Exception as exc:  # noqa: BLE001
            self.send_json(502, {"err": "代理拉取失败：%s" % exc})

    def do_holdjson(self) -> None:
        """基金重仓股：服务器解析东财页面，避开浏览器跨域。"""
        code = (q_get(self.path, "code") or "").strip()
        topline = q_get(self.path, "topline") or "50"
        if not re.match(r"^\d{6}$", code):
            self.send_json(400, {"err": "代码应为 6 位数字"})
            return
        try:
            headers = dict(UA)
            headers["Referer"] = "https://fundf10.eastmoney.com/"
            htm, _ = http_get(UPSTREAM["hold"]({"code": code, "topline": topline}),
                              headers=headers, timeout=15)
            htm = htm.decode("utf-8", "ignore")
            rows = re.findall(r"<tr[^>]*>(.*?)</tr>", htm, re.S)
            out, asof = [], ""
            m = re.search(r"截止至：[^>]*>([^<]+)<", htm)
            if m:
                asof = m.group(1).strip()
            for row in rows:
                tds = re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)
                if len(tds) < 7:
                    continue
                sc = re.sub(r"<[^>]+>", "", tds[1]).strip()
                nm = re.sub(r"<[^>]+>", "", tds[2]).strip()
                pc = re.sub(r"<[^>]+>", "", tds[6]).strip()
                if not nm or "%" not in pc:
                    continue
                try:
                    w = float(pc.replace("%", ""))
                except ValueError:
                    continue
                cc = re.sub(r"\D", "", sc)
                if len(cc) != 6:
                    continue
                mkt = ("sh" if cc[0] in "69" else "sz") + cc
                out.append({"code": cc, "name": nm, "w": w, "mkt": mkt})
            self.send_json(200, {"ok": True, "code": code, "asOf": asof,
                                 "list": out[:50], "n": len(out)})
        except Exception as exc:  # noqa: BLE001
            self.send_json(502, {"err": "拉取失败：%s" % exc})

    # ------------------------------------------------------------ 路由
    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        if market_route(self, "GET", path) or channel_route(self, "GET", path):
            return

        if path == "/api/ping":
            snap_legacy = read_snapshot("legacy")
            snap_native = read_snapshot("native")
            self.send_json(200, {
                "ok": True,
                "proxy": True,
                "msg": "观盘 Pro 服务器正常",
                "service": "Guanpan Pro NAS Sync",
                "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "legacy": {"revision": snap_legacy["revision"],
                           "updatedAt": snap_legacy["updatedAt"]},
                "native": {"revision": snap_native["revision"],
                           "updatedAt": snap_native["updatedAt"]},
                "klineHost": KLINE_STATE["host"],
            })
            return

        if path == "/api/native/ping":
            if not self.authorized():
                self.send_json(401, {"err": "同步口令错误或未填写"})
                return
            snap = read_snapshot("native")
            self.send_json(200, {"ok": True, "service": "Guanpan Pro Native Sync",
                                 "revision": snap["revision"],
                                 "updatedAt": snap["updatedAt"],
                                 "data": None})
            return

        if path == "/api/holdjson":
            self.do_holdjson()
            return

        if path == "/api/market/archive":
            if not self.authorized():
                self.send_json(401, {"err": "同步口令错误或未填写"})
                return
            try:
                self.send_json(200, market_archive(dict(urllib.parse.parse_qsl(parsed.query))))
            except (ValueError, OverflowError) as exc:
                self.send_json(400, {"err": "分页参数无效：%s" % exc})
            return

        if path.startswith("/api/") and path[5:] in set(UPSTREAM) | {"kline"}:
            self.do_proxy(path[5:], parsed.query)
            return

        if path in ("/api/data", "/api/native/data"):
            if not self.authorized():
                self.send_json(401, {"err": "同步口令错误或未填写"})
                return
            namespace = "legacy" if path == "/api/data" else "native"
            snap = read_snapshot(namespace)
            value = snap["data"] if namespace == "native" else (snap["data"] or {})
            self.send_json(200, {"ok": True, "data": value,
                                 "revision": snap["revision"],
                                 "updatedAt": snap["updatedAt"]})
            return

        if path.startswith("/api/"):
            self.send_json(404, {"err": "接口不存在"})
            return

        self.send_static(path)

    def do_POST(self) -> None:
        path = urlparse(self.path).path.rstrip("/")
        if market_route(self, "POST", path) or channel_route(self, "POST", path):
            return
        if path not in ("/api/data", "/api/native/data"):
            self.send_json(404, {"err": "接口不存在"})
            return
        try:
            body = self.read_body()
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
            self.send_json(400, {"err": str(error) or "JSON 格式无效"})
            return
        if not self.authorized(body):
            self.send_json(401, {"err": "同步口令错误或未填写"})
            return

        if path == "/api/data":
            payload = body.get("data")
            if not isinstance(payload, dict):
                self.send_json(400, {"err": "缺少网页账本 data"})
                return
            blocked = guard_empty_overwrite("legacy", payload,
                                            bool(body.get("allowEmptyOverwrite")))
            if blocked:
                blocked["ok"] = False
                self.send_json(409, blocked)
                return
            expected = body.get("expectedRevision")
            if expected is not None and (type(expected) is not int or expected < 0):
                self.send_json(400, {"err": "expectedRevision 必须为非负整数"})
                return
            result = write_snapshot("legacy", payload, expected_revision=expected,
                                    allow_empty_overwrite=body.get("allowEmptyOverwrite") is True)
            if result["conflict"]:
                self.send_json(409, {"err": result.get("err", "revision_conflict"), "revision": result["revision"]})
                return
            self.send_json(200, {"ok": True, "revision": result["revision"],
                                 "updatedAt": result["updatedAt"]})
            return

        payload = body.get("data")
        expected = body.get("expectedRevision")
        if not isinstance(payload, dict) or type(expected) is not int or expected < 0:
            self.send_json(400, {"err": "需要原生账本 data 和非负 expectedRevision"})
            return
        blocked = guard_empty_overwrite("native", payload,
                                        bool(body.get("allowEmptyOverwrite")))
        if blocked:
            blocked["ok"] = False
            self.send_json(409, blocked)
            return
        result = write_snapshot("native", payload, expected_revision=expected,
                                allow_empty_overwrite=body.get("allowEmptyOverwrite") is True)
        if result["conflict"]:
            self.send_json(409, {"err": "服务器版本已变化，请先重新下载并核对",
                                 "revision": result["revision"]})
            return
        try:
            sync_market_watchlist(payload)
        except Exception:
            pass  # 行情观察列表更新不能影响账本同步成功。
        self.send_json(200, {"ok": True, "revision": result["revision"],
                             "updatedAt": result["updatedAt"]})

    def do_HEAD(self) -> None:
        self.send_json(200, {"ok": True})


def main() -> None:
    global V2_RUNTIME
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    connect().close()
    existing = read_snapshot("native")["data"]
    if existing:
        sync_market_watchlist(existing)
        seed_market_archive(existing)
    channels = ChannelStore(DATA_DIR / "channels-v2.sqlite3")
    V2_RUNTIME = MarketRuntime(channels, MarketArchive(DATA_DIR / "market-v2.sqlite3"), http_get, fetch_kline)
    threading.Thread(target=collector_loop, name="market-collector", daemon=True).start()
    threading.Thread(target=V2_RUNTIME.loop, name="v2-market-collector", daemon=True).start()
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8787"))
    print(f"观盘 Pro 服务器已启动：http://{host}:{port}", flush=True)
    print("  网页版 /api/data    App版 /api/native/data    行情代理 /api/quote|kline|minute|holdjson", flush=True)
    httpd = ThreadingHTTPServer((host, port), Handler)
    httpd.channel_store = channels
    httpd.market_runtime = V2_RUNTIME
    httpd.serve_forever()


if __name__ == "__main__":
    main()
