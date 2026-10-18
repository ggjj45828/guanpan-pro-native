"""Opt-in v2 channel store. Separate file; never opens legacy sync.sqlite3.

No migration, real-asset inference, strategy execution or market-source fetching.
All writes require CAS + idempotency keys; asset writes additionally require
an explicit manual intent. Tests use TemporaryDirectory, never shipped data.
"""
from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import time
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path

CHANNELS = {"assets": "manual", "market": "automatic", "quant": "automatic"}
FIELDS = {
    "assets": {"holdings", "cash", "ledger", "costs", "cashFlows", "asOf"},
    "market": {"quotes", "iopv", "intraday", "daily", "books", "quality", "asOf"},
    "quant": {"lab", "strategies", "orders", "fills", "decisions", "reviews", "backtests", "asOf", "executor", "preferences"},
}


class ChannelError(Exception):
    def __init__(self, status: int, code: str, revision: int | None = None):
        super().__init__(code)
        self.status, self.code, self.revision = status, code, revision


def canonical(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def nonnegative_int(value: object) -> bool:
    return type(value) is int and value >= 0


def validate_payload(channel: str, payload: object) -> dict:
    if channel not in CHANNELS:
        raise ChannelError(404, "unknown_channel")
    if not isinstance(payload, dict) or not payload or not set(payload) <= FIELDS[channel]:
        raise ChannelError(422, "payload_fields_do_not_match_channel")
    # Keep the channel envelope narrow. Domain-specific validation evolves by schema.
    for name, value in payload.items():
        if name == "cash":
            if not nonnegative_int(value):
                raise ChannelError(422, "cash_must_be_integer_1e4_cny")
        elif name == "asOf":
            if not nonnegative_int(value):
                raise ChannelError(422, "asOf_must_be_epoch_milliseconds")
        elif name in {"lab", "quality", "costs", "executor", "preferences"}:
            if not isinstance(value, dict):
                raise ChannelError(422, "expected_object")
        elif not isinstance(value, list):
            raise ChannelError(422, "expected_array")
    try:
        if len(canonical(payload).encode("utf-8")) > 16 * 1024 * 1024:
            raise ChannelError(413, "channel_document_too_large")
    except (ValueError, TypeError):
        raise ChannelError(422, "non_finite_or_invalid_json") from None
    return payload


def meaningful(payload: dict) -> bool:
    return any(value for name, value in payload.items() if name not in {"asOf", "quality"})


class ChannelStore:
    def __init__(self, path: Path):
        self.path = Path(path)
        if self.path.name in {"sync.sqlite3", "sync.sqlite3-wal", "sync.sqlite3-shm"}:
            raise ValueError("v2 store must not use legacy database filename")

    def connect(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=FULL")
        db.executescript("""
            CREATE TABLE IF NOT EXISTS channel_latest(
                channel TEXT PRIMARY KEY, revision INTEGER NOT NULL,
                updated_at TEXT NOT NULL, digest TEXT NOT NULL, payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS channel_history(
                channel TEXT NOT NULL, revision INTEGER NOT NULL, updated_at TEXT NOT NULL,
                digest TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(channel,revision));
            CREATE TABLE IF NOT EXISTS channel_requests(
                channel TEXT NOT NULL, request_id TEXT NOT NULL, request_hash TEXT NOT NULL,
                result TEXT NOT NULL, PRIMARY KEY(channel,request_id));
            CREATE TABLE IF NOT EXISTS execution_lease(
                id INTEGER PRIMARY KEY CHECK(id=1), owner TEXT NOT NULL,
                expires_ms INTEGER NOT NULL, fence INTEGER NOT NULL);
        """)
        return db

    @staticmethod
    def channel(channel):
        if channel not in CHANNELS:
            raise ChannelError(404, "unknown_channel")

    @staticmethod
    def decode(row, channel):
        return {"ok": True, "schemaVersion": 2, "channel": channel,
                "mode": CHANNELS[channel], "revision": row["revision"] if row else 0,
                "updatedAt": row["updated_at"] if row else None,
                "digest": row["digest"] if row else None,
                "data": json.loads(row["payload"]) if row else None}

    def get(self, channel):
        self.channel(channel)
        with closing(self.connect()) as db:
            row = db.execute("SELECT * FROM channel_latest WHERE channel=?", (channel,)).fetchone()
            return self.decode(row, channel)

    def history(self, channel):
        self.channel(channel)
        with closing(self.connect()) as db:
            rows = db.execute("SELECT revision,updated_at,digest FROM channel_history WHERE channel=? ORDER BY revision DESC LIMIT 100", (channel,)).fetchall()
        return {"ok": True, "channel": channel, "versions": [dict(r) for r in rows]}

    def put(self, channel, body):
        self.channel(channel)
        if body.get("schemaVersion") != 2 or not nonnegative_int(body.get("expectedRevision")):
            raise ChannelError(422, "schema_and_expected_revision_required")
        if channel == "assets" and body.get("intent") != "manual":
            raise ChannelError(403, "assets_require_manual_intent")
        request_id = body.get("requestID")
        if not isinstance(request_id, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,100}", request_id):
            raise ChannelError(422, "request_id_required")
        if type(body.get("allowEmptyOverwrite", False)) is not bool:
            raise ChannelError(422, "allow_empty_must_be_boolean")
        payload = validate_payload(channel, body.get("data"))
        encoded = canonical(payload)
        digest = hashlib.sha256(encoded.encode()).hexdigest()
        request_hash = hashlib.sha256(canonical(body).encode()).hexdigest()
        with closing(self.connect()) as db:
            db.execute("BEGIN IMMEDIATE")
            try:
                if channel == 'quant':
                    lease = db.execute('SELECT * FROM execution_lease WHERE id=1').fetchone()
                    supplied = body.get('executionLease')
                    now = int(time.time()*1000)
                    if supplied is not None:
                        if not isinstance(supplied, dict) or not lease or lease['expires_ms'] <= now or supplied.get('owner') != lease['owner'] or supplied.get('fence') != lease['fence']:
                            raise ChannelError(409, 'expired_or_invalid_execution_lease')
                    elif lease and lease['expires_ms'] > now:
                        raise ChannelError(409, 'virtual_executor_busy_retry')
                prior = db.execute("SELECT * FROM channel_requests WHERE channel=? AND request_id=?", (channel, request_id)).fetchone()
                if prior:
                    if prior["request_hash"] != request_hash:
                        raise ChannelError(409, "idempotency_key_reused_with_different_request")
                    db.rollback()
                    return json.loads(prior["result"])
                current = db.execute("SELECT * FROM channel_latest WHERE channel=?", (channel,)).fetchone()
                revision = current["revision"] if current else 0
                if body["expectedRevision"] != revision:
                    raise ChannelError(409, "revision_conflict", revision)
                if current and meaningful(json.loads(current["payload"])) and not meaningful(payload) and not body.get("allowEmptyOverwrite", False):
                    raise ChannelError(409, "empty_overwrite_blocked", revision)
                if current and current["digest"] == digest:
                    result = self.decode(current, channel)
                    result.pop("data")
                    result["unchanged"] = True
                else:
                    now = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
                    result = {"ok": True, "channel": channel, "schemaVersion": 2,
                              "revision": revision + 1, "updatedAt": now, "digest": digest, "unchanged": False}
                    args = (channel, revision + 1, now, digest, encoded)
                    db.execute("INSERT INTO channel_latest VALUES(?,?,?,?,?) ON CONFLICT(channel) DO UPDATE SET revision=excluded.revision,updated_at=excluded.updated_at,digest=excluded.digest,payload=excluded.payload", args)
                    db.execute("INSERT INTO channel_history VALUES(?,?,?,?,?)", args)
                db.execute("INSERT INTO channel_requests VALUES(?,?,?,?)", (channel, request_id, request_hash, canonical(result)))
                db.commit()
                return result
            except BaseException:
                db.rollback()
                raise

    def restore(self, channel, body):
        self.channel(channel)
        revision = body.get("restoreRevision")
        if not nonnegative_int(revision) or revision == 0:
            raise ChannelError(422, "restore_revision_required")
        with closing(self.connect()) as db:
            row = db.execute("SELECT payload FROM channel_history WHERE channel=? AND revision=?", (channel, revision)).fetchone()
        if not row:
            raise ChannelError(404, "history_revision_not_found")
        # The same transactional CAS, manual-intent and empty protections apply.
        return self.put(channel, dict(body, data=json.loads(row["payload"])))

    def backup(self, destination: Path):
        destination = Path(destination)
        if destination.resolve() == self.path.resolve() or destination.exists():
            raise ValueError("backup destination must be a new file")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with closing(self.connect()) as db, closing(sqlite3.connect(destination)) as out:
            db.backup(out)
        return destination

    def acquire_execution(self, owner, ttl=15, now=None):
        if not isinstance(owner,str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,100}',owner) or type(ttl) is not int or not 1 <= ttl <= 30:
            raise ChannelError(422,'invalid_execution_lease_request')
        now = int(time.time()*1000) if now is None else now
        with closing(self.connect()) as db:
            db.execute('BEGIN IMMEDIATE')
            try:
                old=db.execute('SELECT * FROM execution_lease WHERE id=1').fetchone()
                if old and old['expires_ms']>now and old['owner']!=owner:
                    raise ChannelError(409,'virtual_executor_busy_retry')
                fence = old['fence'] if old and old['owner']==owner and old['expires_ms']>now else (old['fence']+1 if old else 1)
                expiry=now+ttl*1000
                db.execute('INSERT INTO execution_lease VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET owner=excluded.owner,expires_ms=excluded.expires_ms,fence=excluded.fence',(owner,expiry,fence))
                db.commit()
                return dict(ok=True,owner=owner,fence=fence,expiresAt=expiry)
            except BaseException:db.rollback();raise

    def release_execution(self, owner, fence):
        with closing(self.connect()) as db:
            changed=db.execute('UPDATE execution_lease SET expires_ms=0 WHERE id=1 AND owner=? AND fence=?',(owner,fence)).rowcount
        if not changed:raise ChannelError(409,'execution_lease_not_owned')
        return dict(ok=True)


def route(handler, method, path, body=None):
    """Called by existing HTTP handler before old API routes; no legacy DB access."""
    if not path.startswith("/api/v2/"):
        return False
    if not handler.authorized():
        handler.close_connection = True
        handler.send_json(401, {"ok": False, "err": "unauthorized"})
        return True
    try:
        store = handler.server.channel_store
        if path == "/api/v2/channels" and method == "GET":
            status = {}
            for channel in CHANNELS:
                item = store.get(channel)
                item.pop("data")
                status[channel] = item
            handler.send_json(200, {"ok": True, "channels": status})
            return True
        parts = path.split("/")
        if len(parts) not in (5, 6) or parts[3] != "channels":
            raise ChannelError(404, "route_not_found")
        channel = parts[4]
        suffix = parts[5] if len(parts) == 6 else ""
        store.channel(channel)
        if method == "GET" and suffix == "":
            result = store.get(channel)
        elif method == "GET" and suffix == "history":
            result = store.history(channel)
        elif method == "POST" and suffix in ("", "restore", "lease", "release"):
            if int(handler.headers.get("Content-Length", "0")) > 16 * 1024 * 1024:
                handler.close_connection = True
                raise ChannelError(413, "channel_document_too_large")
            body = body if body is not None else handler.read_body()
            if suffix in ('lease','release'):
                if channel!='quant':raise ChannelError(404,'route_not_found')
                result=store.acquire_execution(body.get('owner'),body.get('ttlSeconds',15)) if suffix=='lease' else store.release_execution(body.get('owner'),body.get('fence'))
            else:result = store.restore(channel, body) if suffix else store.put(channel, body)
        else:
            raise ChannelError(404, "route_not_found")
        handler.send_json(200, result)
    except ChannelError as exc:
        handler.send_json(exc.status, {"ok": False, "err": exc.code, "revision": exc.revision})
    except (ValueError, TypeError, UnicodeError):
        handler.close_connection = True
        handler.send_json(400, {"ok": False, "err": "invalid_json_or_request"})
    return True
