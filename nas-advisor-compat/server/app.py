"""NAS research and sync API for Guanpan Pro Next.

The service intentionally has no application passphrase.  It is designed for a
trusted home LAN / VPN; the iOS app makes real-book writes explicit and
revision-checked.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from datetime import datetime, timezone
from urllib.parse import parse_qs, urlparse
from ai import provider_status, verify_provider, AIProviderError
from domain import Conflict, InvalidData, NextDatabase, convert_legacy_web_book
from market import (fetch_indices, fetch_dividend_events, fetch_kline,
                    fetch_quotes, fetch_daily,
                    symbol_for, DIVIDEND_RULES_VERSION as dividend_rules_version)
from workers import start_workers
import mobile_research


def code_version():
    """部署代码版本号，用来确认“覆盖文件 + 重启”是否真的生效。

    更新后 /health 里的 codeVersion 必须变成新包里的值；没变就说明文件没覆盖到
    容器实际挂载的目录，或者容器没重启（Python 已加载的模块不会自动重载）。
    """
    try:
        return Path(__file__).with_name("VERSION").read_text(encoding="utf-8").strip() or "unknown"
    except OSError:
        return "unknown"


def code_source():
    """这次跑起来用的是宿主机同步进来的代码，还是镜像里 bake 进去的旧代码。

    start.sh 启动时写 .code-source：挂载源里没有 app.py 时会**静默退回镜像内置版本**，
    服务照常起来、心跳也正常，于是「部署没生效」这件事从外面完全看不出来
    （表现就是 /health 没有 codeVersion、模型名还是旧的、新增功能不出现）。
    把这个来源写进 /health，一眼就能判定：
      "host <路径>"  = 用的是你解压进去的新代码（正常）
      "image ..."    = 挂载没落到位，跑的还是镜像里的旧代码（去查 GUANPAN_CODE_DIR）
    """
    try:
        return Path(__file__).with_name(".code-source").read_text(encoding="utf-8").strip() or "unknown"
    except OSError:
        return "unknown"


def make_handler(database, market_fetcher=fetch_quotes, daily_fetcher=fetch_daily, dividend_fetcher=fetch_dividend_events):
    class Handler(BaseHTTPRequestHandler):
        server_version = "GuanpanAdvisor/1"

        def log_message(self, format, *args):
            # Personal book data and query strings are deliberately not logged.
            pass

        def reply(self, status, value):
            body = json.dumps(value, ensure_ascii=False, default=float).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers(); self.wfile.write(body)

        def do_GET(self):
            parsed = urlparse(self.path); path = parsed.path
            if path.startswith(("/v1/grid/", "/v1/simulations/", "/v1/backtests/")):
                return self.reply(410, {"error": "模拟网格、虚拟账户与回测入口已停用；历史记录未删除"})
            if path in ("/classic", "/classic.html", "/market", "/market.html", "/api/web/data", "/v1/advisor/inventory"):
                return self.reply(410, {"error": "旧版网页入口已停用；NAS 只提供后台研究与同步 API，请使用手机 App"})
            if path == "/v1/mobile/research":
                try:
                    return self.reply(200, mobile_research.snapshot(database, market_fetcher))
                except Exception:
                    return self.reply(503, {"error": "NAS 历史档案暂不可用；未生成交易证据"})
            if path in ("/", "/index.html"):
                return self.reply(200, {"service": "guanpan-advisor", "role": "NAS 后台研究与数据服务",
                                        "client": "请使用观盘 iOS App 查看真实持仓与唯一 AI 指导",
                                        "health": "/health", "research": "/v1/mobile/research"})
            if path == "/health":
                return self.reply(200, {"service": "guanpan-advisor", "schemaVersion": 1, "authentication": "none", "web": False,
                                        "codeVersion": code_version(), "codeSource": code_source(),
                                        "workers": database.worker_health(), "aiProvider": provider_status()})
            if path == "/v1/ai/verify":
                # 真实连通性探针：只发一句 "Reply with OK only."，不携带任何持仓数据。
                try:
                    return self.reply(200, verify_provider())
                except AIProviderError as error:
                    return self.reply(503, {"state": "unavailable", "error": str(error), "message": str(error)})
                except Exception:
                    return self.reply(502, {"state": "unavailable", "error": "DeepSeek 连通性验证失败", "message": "DeepSeek 连通性验证失败"})
            if path == "/api/data":
                try: return self.reply(200, {"ok": True, **database.get_legacy_inbox("main")})
                except InvalidData as error: return self.reply(400, {"error": str(error)})
            if path == "/v1/legacy/books/main":
                try:
                    legacy = database.get_legacy_inbox("main")
                    if legacy["data"] is None:
                        return self.reply(200, {"revision": legacy["revision"], "book": None, "summary": None})
                    converted = convert_legacy_web_book(legacy["data"])
                    return self.reply(200, {"revision": legacy["revision"], **converted})
                except InvalidData as error: return self.reply(422, {"error": str(error), "revision": database.get_legacy_inbox("main")["revision"]})
            if path.startswith("/v1/research/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    return self.reply(200, {"factors": database.get_research("factors-" + code),
                                            "ai": database.get_research("deepseek-" + code),
                                            "providerConfigured": provider_status()["configured"],
                                            "providerStatus": provider_status()})
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            if path == "/v1/market/indices":
                try: return self.reply(200, {"indices": fetch_indices()})
                except Exception: return self.reply(502, {"error": "index source unavailable"})
            if path == "/v1/market/kline":
                symbol = parse_qs(parsed.query).get("symbol", [""])[0]
                try: return self.reply(200, {"symbol": symbol, "bars": fetch_kline(symbol)})
                except (ValueError, InvalidData) as error: return self.reply(400, {"error": str(error)})
                except Exception: return self.reply(502, {"error": "index kline source unavailable"})
            if path.startswith("/v1/market/minute/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    day = parse_qs(parsed.query).get("day", [datetime.now().astimezone().date().isoformat()])[0]
                    return self.reply(200, database.get_minute(code, day))
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            if path.startswith("/v1/market/dividends/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    cached = database.get_dividend_events(code)
                    now = datetime.now(timezone.utc)
                    fresh = False
                    stale_rules = bool(cached) and cached.get("rulesVersion") != dividend_rules_version
                    if cached:
                        try: fresh = (now - datetime.fromisoformat(cached["fetchedAt"])).total_seconds() < 24 * 3600
                        except ValueError: pass
                        # 规则版本变了就必须重抓：否则旧缓存里那条"假分红"会继续返回，
                        # 服务端改了算法、App 上还是老结果，看起来像没修好。
                        if stale_rules: fresh = False
                    if not fresh:
                        try:
                            rows = dividend_fetcher(code)
                            database.put_dividend_events(code, rows, now.isoformat(), dividend_rules_version, replace=stale_rules)
                            cached = database.get_dividend_events(code)
                        except Exception:
                            if cached is None: raise
                    return self.reply(200, cached or {"code": code, "source": "NAS dividend archive", "fetchedAt": None, "events": []})
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
                except Exception: return self.reply(503, {"error": "no dividend archive or verified source available"})
            if path.startswith("/v1/market/daily/"):
                try:
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    cached = database.get_daily(code)
                    try:
                        fetched = datetime.fromisoformat(cached["fetchedAt"]) if cached else None
                        stale = fetched is None or fetched.tzinfo is None or (datetime.now(timezone.utc) - fetched).total_seconds() > 1800
                    except (ValueError, TypeError, KeyError):
                        stale = True
                    refreshed = False
                    if stale:
                        try:
                            rows = daily_fetcher(code)
                            database.put_daily(code, rows, datetime.now(timezone.utc).isoformat())
                            cached = database.get_daily(code)
                            refreshed = True
                        except Exception:
                            if cached is None:
                                raise
                    if cached is not None:
                        cached["staleArchive"] = stale and not refreshed
                    return self.reply(200, cached)
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
                except Exception: return self.reply(503, {"error": "daily source unavailable and no NAS cache"})
            if path == "/v1/market/quotes":
                try:
                    raw = parse_qs(parsed.query, strict_parsing=True).get("codes", [""])[0]
                    codes = raw.split(",") if raw else []
                    if not 1 <= len(codes) <= 60 or len(set(codes)) != len(codes):
                        raise InvalidData("provide 1–60 unique exchange codes")
                    for code in codes: symbol_for(code)
                    quotes = market_fetcher(codes)
                    if not quotes:
                        return self.reply(503, {"error": "all quote sources unavailable or returned stale data",
                                                "requestedCodes": codes})
                    present = {quote.get("code") for quote in quotes}
                    return self.reply(200, {"quotes": quotes,
                                            "missingCodes": [code for code in codes if code not in present]})
                except (InvalidData, ValueError) as error:
                    return self.reply(400, {"error": str(error)})
                except Exception:
                    return self.reply(502, {"error": "quote source unavailable; local cache remains authoritative"})
            if path.startswith("/v1/real/books/"):
                parts = path.strip("/").split("/")
                try:
                    # /v1/real/books/<id>/history        版本列表
                    # /v1/real/books/<id>/history/<rev>  单个版本正文
                    if len(parts) >= 5 and parts[4] == "history":
                        if len(parts) == 6:
                            return self.reply(200, database.real_history_body(parts[3], int(parts[5])))
                        return self.reply(200, database.real_history(parts[3]))
                    return self.reply(200, database.get_real(parts[3]))
                except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})
            self.reply(404, {"error": "unknown route"})

        def do_DELETE(self):
            """删除 NAS 上保存的账本历史版本。

            当前生效版本不允许删；`DELETE .../history?keep=N` 只保留最近 N 个。
            """
            parsed = urlparse(self.path); path = parsed.path
            parts = path.strip("/").split("/")
            try:
                if len(parts) >= 4 and parts[:3] == ["v1", "real", "books"] and len(parts) >= 5 and parts[4] == "history":
                    book_id = parts[3]
                    if len(parts) == 6:
                        revision = database.delete_real_history(book_id, int(parts[5]))
                        return self.reply(200, {"ok": True, "deleted": revision})
                    keep = int(parse_qs(parsed.query).get("keep", ["20"])[0])
                    removed = database.prune_real_history(book_id, keep)
                    return self.reply(200, {"ok": True, "kept": keep, "removed": removed})
                return self.reply(404, {"error": "unknown route"})
            except Conflict as error: return self.reply(409, {"error": str(error)})
            except (InvalidData, ValueError) as error: return self.reply(400, {"error": str(error)})

        def do_POST(self):
            path = urlparse(self.path).path
            if path.startswith(("/v1/grid/", "/v1/simulations/", "/v1/backtests/")) or path in ("/v1/advisor/analyze", "/v1/ai/analyze", "/api/web/data"):
                return self.reply(410, {"error": "NAS 不再生成第二套交易建议或推进模拟账户；请在手机使用统一 AI 今日指导"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 16 * 1024 * 1024:
                    return self.reply(413, {"error": "invalid body size"})
                value = json.loads(self.rfile.read(length))
                if not isinstance(value, dict): raise InvalidData("JSON object required")
                if path == "/api/data":
                    if value.get("mode") != "legacy-stage-confirmed":
                        raise InvalidData("legacy staging requires explicit migration action")
                    revision = database.put_legacy_inbox("main", value.get("expectedRevision"), value.get("data"))
                    return self.reply(200, {"ok": True, "revision": revision})
                if path == "/v1/legacy/books/main":
                    converted = convert_legacy_web_book(value.get("data", value))
                    return self.reply(200, {"revision": database.get_legacy_inbox("main")["revision"], **converted})
                if path.startswith("/v1/real/books/"):
                    if value.get("mode") != "manual-confirmed":
                        raise InvalidData("real books require explicit manual confirmation")
                    revision = database.put_real(path.rsplit("/", 1)[-1], value.get("expectedRevision"), value.get("bookJSON"))
                    return self.reply(200, {"revision": revision})
                if path.startswith("/v1/market/track/"):
                    if value.get("mode") != "track-confirmed":
                        raise InvalidData("instrument tracking requires explicit confirmation")
                    code = path.rsplit("/", 1)[-1]; symbol_for(code)
                    database.track_instrument(code, datetime.now(timezone.utc).isoformat())
                    return self.reply(200, {"code": code, "tracked": True})
                self.reply(404, {"error": "unknown route"})
            except Conflict:
                self.reply(409, {"error": "revision conflict; no changes saved"})
            except (InvalidData, ValueError, UnicodeError) as error:
                self.reply(400, {"error": str(error)})

    return Handler


if __name__ == "__main__":
    root = Path(os.environ.get("GUANPAN_NEXT_DATA", "/data")); root.mkdir(parents=True, exist_ok=True)
    database = NextDatabase(root / "guanpan-advisor.sqlite3")
    start_workers(database)
    # 容器内监听端口 = 宿主机端口（并行顾问副本默认 8789）：
    # 少一层映射就少一处"改了外面没改里面"的坑。要换端口用 GUANPAN_ADVISOR_PORT，
    # compose 的映射也跟着同一个变量走。
    try: port = int(os.environ.get("GUANPAN_ADVISOR_PORT", "8789"))
    except ValueError: port = 8789
    ThreadingHTTPServer(("0.0.0.0", port), make_handler(database)).serve_forever()
