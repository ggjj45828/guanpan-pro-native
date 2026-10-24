"""Fresh securities schema. No legacy database, OTC model or broker adapter."""
import json
import re
import sqlite3
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
import uuid


class InvalidData(ValueError):
    pass


class Conflict(Exception):
    pass


def strict_iso_date(value):
    """Accept only canonical Gregorian YYYY-MM-DD dates used by the iOS wire models."""
    if not isinstance(value, str) or re.fullmatch(r"\d{4}-\d{2}-\d{2}", value) is None:
        raise ValueError("date must use YYYY-MM-DD")
    parsed = date.fromisoformat(value)
    if parsed.isoformat() != value:
        raise ValueError("date must use canonical YYYY-MM-DD")
    return parsed


def validate_book_json(text):
    if not isinstance(text, str):
        raise InvalidData("bookJSON must be a JSON string")
    def reject(value):
        raise InvalidData("non-finite number")
    try:
        book = json.loads(text, parse_float=Decimal, parse_constant=reject)
        if not isinstance(book, dict) or book.get("schemaVersion") != 1:
            raise InvalidData("unsupported book schema")
        allowed = {"schemaVersion", "id", "cash", "positions", "fills", "cashMovements", "incomeEvents", "dividendEvents", "history", "importedAt"}
        if set(book) - allowed:
            raise InvalidData("unexpected fields; legacy backups are not accepted")
        def number(value, minimum=Decimal(0)):
            if isinstance(value, bool) or not isinstance(value, (Decimal, int)):
                raise InvalidData("invalid numeric field")
            d = Decimal(value)
            if not d.is_finite() or (minimum is not None and d < minimum):
                raise InvalidData("invalid numeric range")
            return d
        def code(value):
            if not isinstance(value, str) or re.fullmatch(r"[0-9]{6}", value) is None:
                raise InvalidData("invalid exchange code")
        def identifier(value):
            if not isinstance(value, str): raise InvalidData("invalid UUID identifier")
            try: uuid.UUID(value)
            except (ValueError, AttributeError): raise InvalidData("invalid UUID identifier")
        identifier(book.get("id"))
        if "importedAt" in book: number(book["importedAt"], minimum=None)
        number(book["cash"])
        positions = book["positions"]
        if not isinstance(positions, list):
            raise InvalidData("positions must be a list")
        seen = set()
        position_required = {"code", "name", "units", "bookCost"}
        # iOS 3.4.1+ 在持仓里带 acquiredAt（建仓日，用于分红归属）；网页端忽略该字段。
        # 不放行它，整个账本上传会被 400 拒绝，网页账本永远拿不到 iOS 的真实成本。
        position_allowed = position_required | {"acquiredAt"}
        for p in positions:
            if not isinstance(p, dict) or not position_required <= set(p) or set(p) - position_allowed:
                raise InvalidData("invalid position fields")
            code(p["code"])
            if p["code"] in seen or not isinstance(p["name"], str):
                raise InvalidData("duplicate code or invalid name")
            seen.add(p["code"])
            if type(p["units"]) is not int or p["units"] < 0:
                raise InvalidData("units must be a nonnegative integer")
            number(p["bookCost"])
        if not isinstance(book.get("fills"), list) or not isinstance(book.get("history"), list):
            raise InvalidData("fills/history must be arrays")
        movements = book.get("cashMovements", [])
        if not isinstance(movements, list):
            raise InvalidData("cashMovements must be an array")
        for movement in movements:
            if not isinstance(movement, dict) or set(movement) != {"id", "date", "amount", "reason"}:
                raise InvalidData("invalid cash movement fields")
            identifier(movement["id"])
            number(movement["amount"], minimum=None)
            number(movement["date"], minimum=None)
            if not isinstance(movement["reason"], str) or not movement["reason"].strip():
                raise InvalidData("cash movement reason is required")
        income_events = book.get("incomeEvents", [])
        if not isinstance(income_events, list):
            raise InvalidData("incomeEvents must be an array")
        for event in income_events:
            required = {"id", "kind", "name", "payDate", "grossAmount", "tax", "status", "note"}
            optional = {"code", "exDate", "units", "perUnit", "receivedAt"}
            if not isinstance(event, dict) or required - set(event) or set(event) - required - optional:
                raise InvalidData("invalid income event fields")
            if event["kind"] not in ("etfDistribution", "cashInterest", "other") or event["status"] not in ("expected", "received"):
                raise InvalidData("invalid income kind/status")
            if not isinstance(event["id"], str) or not isinstance(event["name"], str) or not isinstance(event["note"], str):
                raise InvalidData("invalid income text fields")
            identifier(event["id"])
            number(event["grossAmount"]); number(event["tax"])
            if Decimal(event["tax"]) > Decimal(event["grossAmount"]):
                raise InvalidData("income tax exceeds gross amount")
            number(event["payDate"], minimum=None)
            if "exDate" in event: number(event["exDate"], minimum=None)
            if "receivedAt" in event: number(event["receivedAt"], minimum=None)
            if "units" in event and (type(event["units"]) is not int or event["units"] <= 0):
                raise InvalidData("invalid income units")
            if "perUnit" in event: number(event["perUnit"])
            if "code" in event: code(event["code"])
            if event["kind"] == "etfDistribution" and "code" not in event:
                raise InvalidData("ETF distribution requires a code")
            if event["status"] == "received" and "receivedAt" not in event:
                raise InvalidData("received income requires a receivedAt date")
        dividend_events = book.get("dividendEvents", [])
        if not isinstance(dividend_events, list):
            raise InvalidData("dividendEvents must be an array")
        for event in dividend_events:
            if not isinstance(event, dict) or set(event) - {"code", "date", "amountPerShare", "isEstimated", "recordDate", "payDate"} or not {"code", "date", "amountPerShare"}.issubset(event):
                raise InvalidData("invalid dividend event fields")
            code(event["code"])
            try: strict_iso_date(event["date"])
            except ValueError: raise InvalidData("invalid dividend event date")
            number(event["amountPerShare"])
            if event.get("isEstimated") not in (None, True, False):
                raise InvalidData("invalid dividend estimate marker")
            for field in ("recordDate", "payDate"):
                if field in event and event[field] is not None:
                    try: strict_iso_date(event[field])
                    except ValueError: raise InvalidData("invalid dividend date field")
        for fill in book["fills"]:
            if not isinstance(fill, dict) or set(fill) != {"id", "date", "code", "side", "units", "price", "fee", "realized"}:
                raise InvalidData("invalid fill fields")
            identifier(fill["id"])
            code(fill["code"])
            if fill["side"] not in ("buy", "sell") or type(fill["units"]) is not int or fill["units"] <= 0:
                raise InvalidData("invalid fill side/units")
            for key in ("price", "fee"): number(fill[key])
            for key in ("date", "realized"): number(fill[key], minimum=None)
        for point in book["history"]:
            if not isinstance(point, dict) or set(point) != {"id", "date", "total", "externalFlow"}:
                raise InvalidData("invalid history point")
            identifier(point["id"])
            number(point["total"])
            number(point["date"], minimum=None)
            number(point["externalFlow"], minimum=None)
        return book
    except (KeyError, TypeError, json.JSONDecodeError, InvalidOperation) as error:
        raise InvalidData("invalid securities book") from error

def convert_legacy_web_book(source):
    """Convert the old /api/data ETF ledger to the independent Next book schema.

    This is a preview-only conversion. It intentionally ignores the old `fund`
    section and returns counts so the caller can ask the user to review before
    writing anything to the real ledger.
    """
    if isinstance(source, str):
        try:
            source = json.loads(source, parse_float=Decimal, parse_constant=lambda _: None)
        except (json.JSONDecodeError, TypeError):
            raise InvalidData("旧版网页数据不是有效 JSON")
    if not isinstance(source, dict):
        raise InvalidData("旧版网页数据必须是 JSON 对象")
    if isinstance(source.get("data"), dict):
        source = source["data"]
    db = source.get("db") if isinstance(source.get("db"), dict) else source

    def amount(value, default=Decimal(0)):
        if isinstance(value, bool) or value is None:
            return default
        try:
            result = Decimal(str(value))
            return result if result.is_finite() else default
        except (InvalidOperation, ValueError):
            return default

    def code(value):
        return value if isinstance(value, str) and re.fullmatch(r"[0-9]{6}", value) else None

    def timestamp(value):
        if isinstance(value, (int, float, Decimal)) and not isinstance(value, bool):
            result = float(value)
            return result - 978307200 if result > 0 else 0.0
        if not isinstance(value, str) or not value.strip():
            return 0.0
        raw = value.strip()
        try:
            if len(raw) == 10 and raw.isdigit():
                parsed = datetime.strptime(raw, "%Y%m%d").replace(tzinfo=timezone.utc)
            else:
                parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed.timestamp() - 978307200
        except ValueError:
            try:
                return datetime.combine(date.fromisoformat(raw[:10]), datetime.min.time(), timezone.utc).timestamp() - 978307200
            except ValueError:
                return 0.0

    def stable_id(prefix, *parts):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "guanpan-advisor:" + prefix + ":" + ":".join(map(str, parts))))

    holdings = db.get("hold") if isinstance(db.get("hold"), list) else []
    positions, seen = [], set()
    skipped_positions = 0
    for index, row in enumerate(holdings):
        if not isinstance(row, dict) or not code(row.get("code")):
            skipped_positions += 1
            continue
        code_value = row["code"]
        units_value = amount(row.get("num"))
        if units_value < 0 or units_value != units_value.to_integral_value():
            raise InvalidData(f"{code_value} 持仓份额不是非负整数，无法安全转换")
        if code_value in seen:
            raise InvalidData(f"旧版网页中证券 {code_value} 有重复持仓，请先在网页合并")
        seen.add(code_value)
        units = int(units_value)
        cost_per_unit = amount(row.get("cost"))
        if cost_per_unit < 0:
            raise InvalidData(f"{code_value} 成本价不能为负数")
        positions.append({"code": code_value, "name": str(row.get("name") or code_value),
                          "units": units, "bookCost": cost_per_unit * units})

    fills, fill_keys = [], set()
    trade_rows = []
    for row in (db.get("trades") if isinstance(db.get("trades"), list) else []):
        if isinstance(row, dict): trade_rows.append((row, "modern"))
    for row in (source.get("tr") if isinstance(source.get("tr"), list) else []):
        if isinstance(row, dict): trade_rows.append((row, "legacy"))
    skipped_trades = 0
    for row, kind in trade_rows:
        trade_code = code(row.get("code"))
        side = row.get("side")
        quantity = amount(row.get("num", row.get("quantity")))
        price = amount(row.get("price"))
        if not trade_code or side not in ("buy", "sell"):
            skipped_trades += 1
            continue
        if quantity <= 0 or quantity != quantity.to_integral_value() or price <= 0:
            raise InvalidData(f"{trade_code} 有交易流水的份额或价格无效，转换已停止")
        raw_date = row.get("date", row.get("d"))
        date_value = timestamp(raw_date)
        if date_value <= 0:
            raise InvalidData(f"{trade_code} 有交易流水缺少可识别日期")
        key = (trade_code, side, int(quantity), str(price), int(date_value))
        if key in fill_keys:
            continue
        fill_keys.add(key)
        fee = amount(row.get("fee"))
        realized = amount(row.get("realized", row.get("profit")))
        fills.append({"id": stable_id("fill", *key), "date": date_value, "code": trade_code,
                      "side": side, "units": int(quantity), "price": price,
                      "fee": fee, "realized": realized})

    cash = amount(source.get("cash"))
    if cash < 0:
        raise InvalidData("旧版网页现金为负，转换已停止")
    cash_movements = []
    for index, row in enumerate(source.get("cashlog") if isinstance(source.get("cashlog"), list) else []):
        if not isinstance(row, dict): continue
        value = amount(row.get("amt"))
        if row.get("type") == "out": value = -value
        elif row.get("type") != "in": continue
        raw_date = row.get("date")
        when = timestamp(raw_date)
        if value == 0 or when <= 0: continue
        cash_movements.append({"id": stable_id("cash", index, when, value), "date": when,
                               "amount": value, "reason": str(row.get("note") or ("现金转入" if value > 0 else "现金转出"))})

    history = []
    for index, row in enumerate(source.get("snap", source.get("snapshots", [])) if isinstance(source.get("snap", source.get("snapshots", [])), list) else []):
        if not isinstance(row, dict) or row.get("scope", "all") != "all": continue
        when = timestamp(row.get("d", row.get("date")))
        total = amount(row.get("total"), amount(row.get("mv")) + cash)
        if when > 0 and total >= 0:
            history.append({"id": stable_id("history", index, when), "date": when, "total": total, "externalFlow": Decimal(0)})

    legacy_dividends = []
    dividend_source = source.get("etfDividendEvents", source.get("dividendEvents", db.get("etfDividendEvents", [])))
    if isinstance(dividend_source, list):
        seen_dividends = set()
        for row in dividend_source:
            if not isinstance(row, dict): continue
            event_code = code(row.get("code")); event_date = row.get("date")
            amount_per_share = amount(row.get("amountPerShare"))
            if not event_code or not isinstance(event_date, str) or re.fullmatch(r"\d{4}-\d{2}-\d{2}", event_date) is None or amount_per_share <= 0:
                continue
            key = (event_code, event_date)
            if key in seen_dividends: continue
            seen_dividends.add(key)
            event = {"code": event_code, "date": event_date, "amountPerShare": amount_per_share}
            if row.get("isEstimated") is True: event["isEstimated"] = True
            elif row.get("isEstimated") is False: event["isEstimated"] = False
            legacy_dividends.append(event)

    if not ("cash" in source or positions or fills or history or cash_movements or legacy_dividends):
        raise InvalidData("未找到可转换的现金、场内持仓或交易流水")
    book = {"schemaVersion": 1, "id": str(uuid.uuid4()), "cash": cash, "positions": positions,
            "fills": fills, "cashMovements": cash_movements, "incomeEvents": [], "dividendEvents": legacy_dividends, "history": history,
            "importedAt": datetime.now(timezone.utc).timestamp() - 978307200}
    encoded = json.dumps(book, ensure_ascii=False, separators=(",", ":"), default=float)
    validate_book_json(encoded)
    watches = db.get("watch") if isinstance(db.get("watch"), list) else []
    watch_codes = list(dict.fromkeys(row.get("code") for row in watches
                                     if isinstance(row, dict) and code(row.get("code"))))
    return {"book": book, "summary": {"cash": cash, "positions": len(positions), "fills": len(fills),
            "cashMovements": len(cash_movements), "history": len(history),
            "watchCodes": watch_codes,
            "skippedPositions": skipped_positions, "skippedTrades": skipped_trades,
            "dividendEvents": len(legacy_dividends),
            "ignoredOTCFunds": len((source.get("fund") or {}).get("hold", [])) if isinstance(source.get("fund"), dict) and isinstance((source.get("fund") or {}).get("hold", []), list) else 0}}


class NextDatabase:
    """Compare-and-swap manual snapshots; real and research tables are separate."""
    def __init__(self, filename):
        self.filename = str(filename)
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                -- 以下 legacy 表仅为升级时保留旧数据库兼容；当前服务不读取或写入模拟网格/数字孪生数据。
                -- real_books 与研究归档为当前有效数据路径。
                CREATE TABLE IF NOT EXISTS grid_state (id TEXT PRIMARY KEY, body TEXT, updated_at TEXT);
                CREATE TABLE IF NOT EXISTS web_snapshots (
                    id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL, updated_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS legacy_inbox (
                    id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS real_books (
                    id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS real_book_history (
                    id TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL,
                    PRIMARY KEY(id, revision));
                CREATE TABLE IF NOT EXISTS daily_bars (code TEXT PRIMARY KEY, fetched_at TEXT NOT NULL, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS dividend_archive (
                    code TEXT PRIMARY KEY, fetched_at TEXT NOT NULL, body TEXT NOT NULL,
                    rules_version INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS minute_archive (
                    code TEXT NOT NULL, stamp TEXT NOT NULL, body TEXT NOT NULL, fetched_at TEXT NOT NULL,
                    PRIMARY KEY(code, stamp));
                CREATE TABLE IF NOT EXISTS cross_market_minute (
                    market TEXT NOT NULL, stamp TEXT NOT NULL, body TEXT NOT NULL,
                    source TEXT NOT NULL, fetched_at TEXT NOT NULL,
                    PRIMARY KEY(market, stamp));
                CREATE TABLE IF NOT EXISTS research_runs (
                    id TEXT PRIMARY KEY, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS tracked_instruments (
                    code TEXT PRIMARY KEY, added_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS worker_status (
                    name TEXT PRIMARY KEY, updated_at TEXT NOT NULL, state TEXT NOT NULL, detail TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS experiments (
                    id TEXT PRIMARY KEY, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS twin_accounts (
                    id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS twin_account_history (
                    id TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL,
                    PRIMARY KEY(id, revision));
            """)
            # 老库升级：`dividend_archive` 早期没有 rules_version 列。
            # 加不上（列已存在）就忽略 —— SQLite 没有 ADD COLUMN IF NOT EXISTS。
            try:
                db.execute("ALTER TABLE dividend_archive ADD COLUMN rules_version INTEGER NOT NULL DEFAULT 0")
            except sqlite3.OperationalError:
                pass

    def connect(self):
        return sqlite3.connect(self.filename, timeout=15)

    @staticmethod
    def validate_id(book_id):
        if not isinstance(book_id, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,80}", book_id) is None:
            raise InvalidData("invalid id")

    def get_real(self, book_id):
        self.validate_id(book_id)
        with self.connect() as db:
            row = db.execute("SELECT revision, body FROM real_books WHERE id=?", (book_id,)).fetchone()
        return {"revision": row[0], "bookJSON": row[1]} if row else {"revision": 0, "bookJSON": None}

    def put_real(self, book_id, expected, book_json):
        self.validate_id(book_id)
        if type(expected) is not int or expected < 0:
            raise InvalidData("invalid expectedRevision")
        validate_book_json(book_json)
        # The exact JSON text is stored; no float re-encoding of money occurs.
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT revision FROM real_books WHERE id=?", (book_id,)).fetchone()
            revision = current[0] if current else 0
            if revision != expected:
                raise Conflict("revision changed; manual conflict resolution required")
            revision += 1
            db.execute("INSERT OR REPLACE INTO real_books VALUES (?, ?, ?)", (book_id, revision, book_json))
            db.execute("INSERT INTO real_book_history VALUES (?, ?, ?)", (book_id, revision, book_json))
        return revision

    def real_history(self, book_id):
        """NAS 侧保存的账本版本列表（每次写入都会留一份完整 JSON）。

        只返回元数据，不回传整份账本 —— 网页/手机要恢复某个版本时再单取。
        """
        self.validate_id(book_id)
        with self.connect() as db:
            current = db.execute("SELECT revision FROM real_books WHERE id=?", (book_id,)).fetchone()
            rows = db.execute(
                "SELECT revision, length(body) FROM real_book_history WHERE id=? ORDER BY revision DESC",
                (book_id,)).fetchall()
        latest = current[0] if current else 0
        return {"bookId": book_id, "current": latest,
                "versions": [{"revision": r, "bytes": size, "current": r == latest} for r, size in rows]}

    def real_history_body(self, book_id, revision):
        self.validate_id(book_id)
        if type(revision) is not int or revision <= 0:
            raise InvalidData("invalid revision")
        with self.connect() as db:
            row = db.execute("SELECT body FROM real_book_history WHERE id=? AND revision=?",
                             (book_id, revision)).fetchone()
        if not row:
            raise InvalidData("revision not found")
        return {"revision": revision, "bookJSON": row[0]}

    def delete_real_history(self, book_id, revision):
        """删除一个历史版本。当前生效版本不能删 —— 删了就没有可回滚的锚点。"""
        self.validate_id(book_id)
        if type(revision) is not int or revision <= 0:
            raise InvalidData("invalid revision")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT revision FROM real_books WHERE id=?", (book_id,)).fetchone()
            if current and current[0] == revision:
                raise Conflict("cannot delete the current revision; write a new revision first")
            cursor = db.execute("DELETE FROM real_book_history WHERE id=? AND revision=?", (book_id, revision))
            if cursor.rowcount == 0:
                raise InvalidData("revision not found")
        return revision

    def prune_real_history(self, book_id, keep=20):
        """只保留最近 keep 个版本（含当前版本），更早的删掉。返回被删数量。"""
        self.validate_id(book_id)
        if type(keep) is not int or keep < 1:
            raise InvalidData("keep must be a positive integer")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current = db.execute("SELECT revision FROM real_books WHERE id=?", (book_id,)).fetchone()
            latest = current[0] if current else 0
            rows = db.execute("SELECT revision FROM real_book_history WHERE id=? ORDER BY revision DESC",
                              (book_id,)).fetchall()
            doomed = [r for (r,) in rows[keep:] if r != latest]
            for revision in doomed:
                db.execute("DELETE FROM real_book_history WHERE id=? AND revision=?", (book_id, revision))
        return len(doomed)

    def get_web_snapshot(self, snapshot_id="classic"):
        self.validate_id(snapshot_id)
        with self.connect() as db:
            row = db.execute("SELECT revision, body, updated_at FROM web_snapshots WHERE id=?", (snapshot_id,)).fetchone()
        if not row:
            return {"revision": 0, "data": None, "updatedAt": None}
        return {"revision": row[0], "data": json.loads(row[1]), "updatedAt": row[2]}

    def put_web_snapshot(self, snapshot_id, data, expected=None):
        """旧版网页的整包数据。expected 为 None 时不校验（老网页不带修订号），
        带了就必须相等，否则 409 —— 两个设备同时写不会互相覆盖。"""
        self.validate_id(snapshot_id)
        if not isinstance(data, dict):
            raise InvalidData("web snapshot must be an object")
        body = json.dumps(data, ensure_ascii=False, separators=(",", ":"), default=str)
        if len(body.encode("utf-8")) > 16 * 1024 * 1024:
            raise InvalidData("web snapshot exceeds 16 MiB")
        now = datetime.now(timezone.utc).isoformat()
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT revision FROM web_snapshots WHERE id=?", (snapshot_id,)).fetchone()
            current = row[0] if row else 0
            if expected is not None and int(expected) != current:
                raise Conflict("web snapshot revision changed")
            revision = current + 1
            db.execute("INSERT OR REPLACE INTO web_snapshots (id, revision, body, updated_at) VALUES (?, ?, ?, ?)",
                       (snapshot_id, revision, body, now))
            db.execute("COMMIT")
        return revision

    def get_legacy_inbox(self, inbox_id="main"):
        self.validate_id(inbox_id)
        with self.connect() as db:
            row = db.execute("SELECT revision, body FROM legacy_inbox WHERE id=?", (inbox_id,)).fetchone()
        return {"revision": row[0], "data": json.loads(row[1])} if row else {"revision": 0, "data": None}

    def put_legacy_inbox(self, inbox_id, expected, data):
        self.validate_id(inbox_id)
        if type(expected) is not int or expected < 0 or not isinstance(data, dict):
            raise InvalidData("invalid legacy staging request")
        # Validate conversion before persistence. This staging table never writes
        # to real_books and has its own revision history/CAS boundary.
        convert_legacy_web_book(data)
        body = json.dumps(data, ensure_ascii=False, separators=(",", ":"), default=str)
        if len(body.encode("utf-8")) > 16 * 1024 * 1024:
            raise InvalidData("legacy snapshot exceeds 16 MiB")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT revision FROM legacy_inbox WHERE id=?", (inbox_id,)).fetchone()
            revision = row[0] if row else 0
            if revision != expected:
                raise Conflict("legacy snapshot revision changed")
            revision += 1
            db.execute("INSERT OR REPLACE INTO legacy_inbox VALUES (?, ?, ?)", (inbox_id, revision, body))
        return revision

    def get_daily(self, code):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit(): raise InvalidData("invalid exchange code")
        with self.connect() as db:
            row = db.execute("SELECT fetched_at, body FROM daily_bars WHERE code=?", (code,)).fetchone()
        return {"code": code, "source": "NAS validated Tencent/Eastmoney daily archive", "fetchedAt": row[0], "bars": json.loads(row[1])} if row else None

    def put_daily(self, code, rows, stamp):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit() or not isinstance(rows, list) or not rows or not isinstance(stamp, str):
            raise InvalidData("invalid daily bars")
        incoming = {}
        for row in rows:
            if not isinstance(row, dict) or set(row) != {"date", "open", "close", "high", "low", "volume"}:
                raise InvalidData("invalid daily bar fields")
            day = row["date"]
            if not isinstance(day, str): raise InvalidData("invalid daily bar date")
            try:
                strict_iso_date(day)
                prices = {key: Decimal(str(row[key])) for key in ("open", "close", "high", "low", "volume")}
            except (ValueError, InvalidOperation): raise InvalidData("invalid daily bar values")
            if (any(not value.is_finite() for value in prices.values()) or
                    min(prices[key] for key in ("open", "close", "high", "low")) <= 0 or prices["volume"] < 0 or
                    prices["low"] > min(prices["open"], prices["close"]) or prices["high"] < max(prices["open"], prices["close"])):
                raise InvalidData("invalid daily OHLCV range")
            normalized = {"date": day, **{key: str(prices[key]) for key in ("open", "close", "high", "low", "volume")}}
            incoming[day] = normalized
        with self.connect() as db:
            previous = db.execute("SELECT body FROM daily_bars WHERE code=?", (code,)).fetchone()
            merged = {}
            if previous:
                try:
                    for row in json.loads(previous[0]):
                        if isinstance(row, dict) and isinstance(row.get("date"), str): merged[row["date"]] = row
                except (ValueError, TypeError): pass
            # Keep every archived day. A newly validated source row may update
            # that day's OHLCV, but a shorter upstream window never prunes history.
            merged.update(incoming)
            body = json.dumps([merged[key] for key in sorted(merged)], ensure_ascii=False)
            db.execute("INSERT OR REPLACE INTO daily_bars VALUES (?, ?, ?)", (code, stamp, body))

    def put_minute(self, code, rows, fetched_at):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit() or not isinstance(rows, list) or not rows:
            raise InvalidData("invalid minute archive")
        validated = []
        for row in rows:
            if not isinstance(row, dict) or set(row) != {"timestamp", "price", "volume", "iopv"}:
                raise InvalidData("invalid minute row")
            stamp, price, volume, iopv = row["timestamp"], row["price"], row["volume"], row["iopv"]
            if not isinstance(stamp, str) or "T" not in stamp:
                raise InvalidData("invalid minute timestamp")
            try:
                numeric_price = Decimal(str(price))
                numeric_volume = Decimal(str(volume)) if volume is not None else None
                numeric_iopv = Decimal(str(iopv)) if iopv is not None else None
            except (InvalidOperation, ValueError):
                raise InvalidData("invalid minute values")
            if (not numeric_price.is_finite() or numeric_price <= 0 or
                    (numeric_volume is not None and (not numeric_volume.is_finite() or numeric_volume < 0)) or
                    (numeric_iopv is not None and (not numeric_iopv.is_finite() or numeric_iopv <= 0))):
                raise InvalidData("invalid minute values")
            # A later raw minute pull must not erase a previously verified IOPV sample.
            validated.append((code, stamp, json.dumps(row, ensure_ascii=False), fetched_at))
        with self.connect() as db:
            for code, stamp, body, fetched_at in validated:
                existing = db.execute("SELECT body FROM minute_archive WHERE code=? AND stamp=?", (code, stamp)).fetchone()
                if existing:
                    prior = json.loads(existing[0])
                    incoming = json.loads(body)
                    if incoming.get("iopv") is None and prior.get("iopv") is not None:
                        incoming["iopv"] = prior["iopv"]
                        body = json.dumps(incoming, ensure_ascii=False)
                db.execute("INSERT OR REPLACE INTO minute_archive VALUES (?, ?, ?, ?)", (code, stamp, body, fetched_at))

    def get_dividend_events(self, code):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit(): raise InvalidData("invalid exchange code")
        with self.connect() as db:
            row = db.execute("SELECT fetched_at, body, rules_version FROM dividend_archive WHERE code=?", (code,)).fetchone()
        return {"code": code,
                "source": "Eastmoney fund F10 implemented distribution history + stock corporate actions + qfq/raw estimate",
                "fetchedAt": row[0], "rulesVersion": row[2], "events": json.loads(row[1])} if row else None

    def put_dividend_events(self, code, events, fetched_at, rules_version=0, replace=False):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit() or not isinstance(events, list) or not isinstance(fetched_at, str):
            raise InvalidData("invalid dividend archive")
        deduped = {}
        for item in events:
            if not isinstance(item, dict) or set(item) - {"code", "date", "amountPerShare", "isEstimated", "recordDate", "payDate"} or not {"code", "date", "amountPerShare"}.issubset(item):
                raise InvalidData("invalid dividend event")
            if item["code"] != code or not isinstance(item["date"], str): raise InvalidData("dividend code/date mismatch")
            try: strict_iso_date(item["date"]); amount = Decimal(str(item["amountPerShare"]))
            except (ValueError, InvalidOperation): raise InvalidData("invalid dividend date/amount")
            if not amount.is_finite() or amount <= 0 or item.get("isEstimated") not in (None, True, False):
                raise InvalidData("invalid dividend amount/provenance")
            event = {"code": code, "date": item["date"], "amountPerShare": str(amount), "isEstimated": item.get("isEstimated")}
            for field in ("recordDate", "payDate"):
                value = item.get(field)
                if value is not None:
                    if not isinstance(value, str): raise InvalidData("invalid dividend date field")
                    try: strict_iso_date(value)
                    except ValueError: raise InvalidData("invalid dividend date field")
                    event[field] = value
            deduped[item["date"]] = event
        with self.connect() as db:
            previous = db.execute("SELECT body FROM dividend_archive WHERE code=?", (code,)).fetchone()
            merged = {}
            # 默认与旧缓存合并（防某个源偶发只返回部分历史时把老记录冲掉）。
            # 但换了识别规则时必须整体替换 —— 否则新规则算出来是"没有分红"，
            # 这里会继续把旧的那条假分红合并回去，等于白改。
            if previous and not replace:
                try:
                    for old in json.loads(previous[0]):
                        if isinstance(old, dict) and old.get("code") == code and isinstance(old.get("date"), str): merged[old["date"]] = old
                except (ValueError, TypeError): pass
            for day, event in deduped.items():
                old = merged.get(day)
                if old and old.get("isEstimated") is False and event.get("isEstimated") is True: continue
                merged[day] = event
            body = json.dumps([merged[key] for key in sorted(merged)], ensure_ascii=False)
            db.execute("INSERT OR REPLACE INTO dividend_archive (code, fetched_at, body, rules_version) VALUES (?, ?, ?, ?)",
                       (code, fetched_at, body, int(rules_version)))

    def get_minute(self, code, day):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit() or not isinstance(day, str): raise InvalidData("invalid minute query")
        try: date.fromisoformat(day)
        except ValueError: raise InvalidData("invalid minute query")
        with self.connect() as db:
            rows = db.execute("SELECT body FROM minute_archive WHERE code=? AND stamp LIKE ? ORDER BY stamp",
                              (code, day + "%")).fetchall()
        return {"code": code, "day": day, "source": "Tencent minute query", "rows": [json.loads(row[0]) for row in rows]}

    def put_cross_market_minute(self, market, rows, source, fetched_at):
        """Persist provider-observed external minute points for research/replay only."""
        self.validate_id(market)
        if not isinstance(source, str) or not source.strip() or not isinstance(rows, list) or not rows:
            raise InvalidData("invalid cross-market archive")
        try:
            fetched = datetime.fromisoformat(fetched_at.replace("Z", "+00:00"))
            if fetched.tzinfo is None: raise ValueError("timezone required")
        except (AttributeError, TypeError, ValueError):
            raise InvalidData("invalid cross-market fetch timestamp")
        if fetched.astimezone(timezone.utc) > datetime.now(timezone.utc) + timedelta(seconds=120):
            raise InvalidData("future cross-market fetch timestamp")
        validated = []
        for row in rows:
            if not isinstance(row, dict): raise InvalidData("invalid cross-market minute row")
            try:
                stamp = datetime.fromisoformat(str(row["timestamp"]).replace("Z", "+00:00"))
                price = Decimal(str(row["price"]))
            except (KeyError, TypeError, ValueError, InvalidOperation):
                raise InvalidData("invalid cross-market minute values")
            if stamp.tzinfo is None or not price.is_finite() or price <= 0:
                raise InvalidData("cross-market point needs a zoned timestamp and positive price")
            if stamp.astimezone(timezone.utc) > fetched.astimezone(timezone.utc):
                raise InvalidData("future cross-market point rejected")
            canonical = {"timestamp": stamp.isoformat(), "price": str(price)}
            for optional in ("volume", "iopv"):
                value = row.get(optional)
                if value is None:
                    canonical[optional] = None
                else:
                    try: number = Decimal(str(value))
                    except (InvalidOperation, ValueError): raise InvalidData("invalid optional market value")
                    if not number.is_finite() or number < 0: raise InvalidData("invalid optional market value")
                    canonical[optional] = str(number)
            # Keep the provider's local offset in the archive key so session-day
            # replay (especially lunch breaks and US DST) uses the exchange date.
            validated.append((stamp.isoformat(),
                              json.dumps(canonical, separators=(",", ":"))))
        with self.connect() as db:
            db.executemany("INSERT OR REPLACE INTO cross_market_minute VALUES (?, ?, ?, ?, ?)",
                           [(market, stamp, body, source[:120], fetched.isoformat())
                            for stamp, body in validated])

    def get_cross_market_minute(self, market, day):
        self.validate_id(market)
        try: date.fromisoformat(day)
        except (ValueError, TypeError): raise InvalidData("invalid cross-market date")
        with self.connect() as db:
            rows = db.execute("SELECT body, source FROM cross_market_minute WHERE market=? "
                              "AND stamp LIKE ? ORDER BY stamp", (market, day + "%")).fetchall()
        sources = sorted({row[1] for row in rows})
        return {"market": market, "day": day, "source": sources[0] if len(sources) == 1 else sources,
                "rows": [json.loads(row[0]) for row in rows]}

    def get_cross_market_range(self, market, start, end):
        """Read a bounded source archive range for research without per-day DB opens."""
        self.validate_id(market)
        try:
            first, last = date.fromisoformat(start), date.fromisoformat(end)
        except (TypeError, ValueError): raise InvalidData("invalid cross-market date range")
        if first > last or (last - first).days > 400:
            raise InvalidData("cross-market research range must be within 400 days")
        with self.connect() as db:
            rows = db.execute("SELECT body, source FROM cross_market_minute WHERE market=? "
                              "AND substr(stamp,1,10)>=? AND substr(stamp,1,10)<=? ORDER BY stamp",
                              (market, start, end)).fetchall()
        sources = sorted({row[1] for row in rows})
        return {"market": market, "source": sources[0] if len(sources) == 1 else sources,
                "rows": [json.loads(row[0]) for row in rows]}

    def cross_market_days(self, market, start, end):
        self.validate_id(market)
        try:
            first, last = date.fromisoformat(start), date.fromisoformat(end)
        except (TypeError, ValueError): raise InvalidData("invalid cross-market date range")
        if first > last or (last - first).days > 400:
            raise InvalidData("cross-market replay range must be within 400 days")
        with self.connect() as db:
            rows = db.execute("SELECT DISTINCT substr(stamp,1,10) FROM cross_market_minute "
                              "WHERE market=? AND substr(stamp,1,10)>=? AND substr(stamp,1,10)<=? "
                              "ORDER BY 1", (market, start, end)).fetchall()
        return [row[0] for row in rows]

    def get_research(self, run_id):
        self.validate_id(run_id)
        with self.connect() as db:
            row = db.execute("SELECT body FROM research_runs WHERE id=?", (run_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def put_research(self, run_id, body):
        self.validate_id(run_id)
        if not isinstance(body, dict): raise InvalidData("invalid research body")
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO research_runs VALUES (?, ?)", (run_id, json.dumps(body, ensure_ascii=False)))

    def track_instrument(self, code, added_at):
        self.validate_id(code)
        if len(code) != 6 or not code.isdigit() or not isinstance(added_at, str) or not added_at:
            raise InvalidData("invalid tracked instrument")
        with self.connect() as db:
            db.execute("INSERT OR IGNORE INTO tracked_instruments VALUES (?, ?)", (code, added_at))

    def tracked_instruments(self):
        with self.connect() as db:
            rows = db.execute("SELECT code FROM tracked_instruments ORDER BY added_at, code").fetchall()
        return [row[0] for row in rows]

    def put_worker_status(self, name, updated_at, state, detail):
        if not isinstance(name, str) or re.fullmatch(r"[a-z-]{1,40}", name) is None:
            raise InvalidData("invalid worker name")
        if state not in ("starting", "idle", "ok", "degraded") or not isinstance(updated_at, str) or not updated_at:
            raise InvalidData("invalid worker status")
        if not isinstance(detail, str) or len(detail) > 500:
            raise InvalidData("invalid worker detail")
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO worker_status VALUES (?, ?, ?, ?)", (name, updated_at, state, detail))

    def worker_status(self):
        with self.connect() as db:
            rows = db.execute("SELECT name, updated_at, state, detail FROM worker_status ORDER BY name").fetchall()
        return [{"name": row[0], "updatedAt": row[1], "state": row[2], "detail": row[3]} for row in rows]

    def worker_health(self, now=None, stale_after_seconds=2400):
        """Expose stored worker heartbeat plus computed freshness; never report old OK as live."""
        now = now or datetime.now(timezone.utc)
        result = []
        for item in self.worker_status():
            try:
                updated = datetime.fromisoformat(item["updatedAt"])
                if updated.tzinfo is None: updated = updated.replace(tzinfo=timezone.utc)
                age = max(0, int((now - updated.astimezone(timezone.utc)).total_seconds()))
                parseable = True
            except (TypeError, ValueError):
                age = None; parseable = False
            stale = not parseable or age is None or age > stale_after_seconds
            result.append({**item, "ageSeconds": age, "stale": stale,
                           "health": "stale" if stale else item["state"]})
        return result
