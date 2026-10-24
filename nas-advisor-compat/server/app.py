"""Independent NAS service and local web console for Guanpan Pro Next.

The service intentionally has no application passphrase.  It is designed for a
trusted home LAN / VPN; the iOS app and the web console make real-book writes
explicit and revision-checked.
"""
import json
import os
import uuid
from concurrent.futures import ThreadPoolExecutor
from zoneinfo import ZoneInfo
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from datetime import datetime, timezone
from urllib.parse import parse_qs, urlparse
from ai import provider_status, verify_provider, analyze_user_context, build_analysis_context, AIProviderError, profile_from_environment
from domain import Conflict, InvalidData, NextDatabase, convert_legacy_web_book
from market import (fetch_indices, fetch_tencent_quotes, fetch_tencent_daily, fetch_dividend_events, fetch_kline,
                    fetch_quotes, fetch_daily,
                    symbol_for, DIVIDEND_RULES_VERSION as dividend_rules_version)
from workers import start_workers
import grid
import advisor
import mobile_research
from backtest import run_backtest
from simulations import apply_action, create_account

WEB_ROOT = Path(__file__).with_name("web")


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
    def grid_bars(codes):
        """网格参数只需要近 20 个交易日的振幅，用 NAS 已归档的日 K，够了。"""
        bars = {}
        for code in codes:
            try:
                stored = database.get_daily(code)
                if stored:
                    bars[code] = stored["bars"]
            except Exception:
                pass
        return bars

    def grid_quotes(codes):
        """批量取报价；批量里缺哪只就单独补一次。

        腾讯的批量接口偶发只返回一部分（之前 563020 还被串成过别的品种），
        网格如果拿不到价就会用成本价当锚点，档位全是错的 —— 所以这里宁可慢一点。
        """
        if not codes:
            return {}
        result = {}
        try:
            result = {row["code"]: row for row in market_fetcher(codes)}
        except Exception:
            result = {}
        missing = [code for code in codes if code not in result]
        for code in missing:
            try:
                for row in market_fetcher([code]):
                    result[row["code"]] = row
            except Exception:
                pass
        return result

    def grid_book():
        remote = database.get_real("main")
        raw = remote.get("bookJSON")
        if not raw:
            return None
        return json.loads(raw)

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

        def html(self, name="index.html"):
            body = (WEB_ROOT / name).read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers(); self.wfile.write(body)

        def do_GET(self):
            parsed = urlparse(self.path); path = parsed.path
            if path.startswith(("/v1/grid/", "/v1/simulations/", "/v1/backtests/")):
                return self.reply(410, {"error": "模拟网格、虚拟账户与回测入口已停用；历史记录未删除"})
            if path == "/v1/mobile/research":
                try:
                    return self.reply(200, mobile_research.snapshot(database, market_fetcher))
                except Exception:
                    return self.reply(503, {"error": "NAS 历史档案暂不可用；未生成交易证据"})
            if path == "/v1/advisor/inventory":
                try:
                    return self.reply(200, advisor.inventory(database))
                except (InvalidData, ValueError, TypeError):
                    return self.reply(422, {"error": "真实账本或分时档案无法读取；未生成建议"})
            if path in ("/", "/index.html"):
                return self.html()
            if path in ("/market", "/market.html"):
                return self.html("market.html")
            if path in ("/classic", "/classic.html"):
                # 旧版《观盘 Pro 智能看盘》：数据本来只存 localStorage，换端口就丢；
                # 现在托管在这里并配了 /api/web/data，数据落在 NAS 上。
                return self.html("classic.html")
            if path == "/health":
                return self.reply(200, {"service": "guanpan-advisor", "schemaVersion": 1, "authentication": "none", "web": True,
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
            if path == "/api/web/data":
                # 旧版网页的整包数据（localStorage 的替代品）。只读，不会动真实账本。
                try: return self.reply(200, {"ok": True, **database.get_web_snapshot("classic")})
                except InvalidData as error: return self.reply(400, {"error": str(error)})
            if path == "/v1/grid/status":
                try:
                    stored = database.get_grid_state()
                    state = stored.get("state")
                    if not state:
                        return self.reply(200, {"ok": True, "initialized": False, "summary": None,
                                                "daily": [], "fills": []})
                    codes = list((state.get("plans") or {}).keys())
                    quotes = grid_quotes(codes)
                    return self.reply(200, {"ok": True, "initialized": True, "updatedAt": stored.get("updatedAt"),
                                            "summary": grid.summary(state, quotes),
                                            # 明天的挂单表：网格真正的"未来指导"，不是预测涨跌
                                            "ladder": grid.ladder(state, quotes),
                                            "daily": (state.get("daily") or [])[-90:],
                                            "fills": (state.get("fills") or [])[-20:]})
                except (InvalidData, ValueError) as error:
                    return self.reply(400, {"error": str(error)})
            if path == "/v1/grid/history":
                try:
                    stored = database.get_grid_state()
                    state = stored.get("state") or {}
                    return self.reply(200, {"ok": True, "daily": state.get("daily") or [],
                                            "fills": (state.get("fills") or [])[-100:]})
                except (InvalidData, ValueError) as error:
                    return self.reply(400, {"error": str(error)})
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
            if path.startswith("/v1/backtests/runs/"):
                try:
                    run_id = path.rsplit("/", 1)[-1]
                    result = database.get_experiment("backtest-" + run_id)
                    return self.reply(200, result) if result else self.reply(404, {"error": "backtest run not found"})
                except InvalidData as error: return self.reply(400, {"error": str(error)})
            if path.startswith("/v1/simulations/"):
                try:
                    parts = path.strip("/").split("/")
                    if len(parts) not in (3, 4): raise InvalidData("invalid simulation path")
                    strategy = parts[2]
                    current = database.get_twin_account(strategy)
                    if len(parts) == 4:
                        if parts[3] != "history": raise InvalidData("unknown simulation resource")
                        return self.reply(200, {"strategy": strategy, "history": database.twin_account_history(strategy)})
                    return self.reply(200, {"strategy": strategy, **current})
                except InvalidData as error: return self.reply(400, {"error": str(error)})
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
                    if cached is None:
                        rows = daily_fetcher(code)
                        database.put_daily(code, rows, datetime.now(timezone.utc).isoformat())
                        cached = database.get_daily(code)
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
                    return self.reply(200, {"quotes": market_fetcher(codes)})
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
            if path.startswith(("/v1/grid/", "/v1/simulations/", "/v1/backtests/")) or path in ("/v1/advisor/analyze", "/v1/ai/analyze"):
                return self.reply(410, {"error": "NAS 不再生成第二套交易建议或推进模拟账户；请在手机使用统一 AI 今日指导"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 16 * 1024 * 1024:
                    return self.reply(413, {"error": "invalid body size"})
                value = json.loads(self.rfile.read(length))
                if not isinstance(value, dict): raise InvalidData("JSON object required")
                if path == "/v1/advisor/analyze":
                    if value.get("userConfirmed") is not True:
                        return self.reply(400, {"error": "发送真实持仓与行情给 NAS DeepSeek 分析前必须逐次确认"})
                    remote = database.get_real("main")
                    book = json.loads(remote["bookJSON"]) if remote.get("bookJSON") else None
                    if not book:
                        return self.reply(422, {"error": "NAS 真实账本为空"})
                    holdings = [p for p in book.get("positions", []) if p.get("units", 0) > 0]
                    if not holdings:
                        return self.reply(422, {"error": "真实持仓为空；未生成建议"})
                    if len(holdings) > 20:
                        return self.reply(422, {"error": "持仓超过 20 只，请先选择要分析的证券"})
                    raw_rules = value.get("rules", {})
                    if not isinstance(raw_rules, dict):
                        raise InvalidData("verified rules must be an object")
                    try:
                        quote_rows = market_fetcher([p["code"] for p in holdings])
                        quotes = {row["code"]: row for row in quote_rows}
                    except Exception:
                        quotes = {}
                    total_market_value = sum((advisor._decimal(quotes.get(p["code"], {}).get("price")) or 0) * p["units"] for p in holdings)
                    reports, headlines = [], []
                    news_jobs = []
                    cash = advisor._decimal(book.get("cash"))
                    per_position_budget = cash / len(holdings) if cash is not None and holdings else None
                    for position in holdings:
                        code = position["code"]
                        with database.connect() as db:
                            minute_rows = [json.loads(row[0]) for row in db.execute(
                                "SELECT body FROM (SELECT body, stamp FROM minute_archive WHERE code=? ORDER BY stamp DESC LIMIT 36000) ORDER BY stamp", (code,)).fetchall()]
                        rules = raw_rules.get(code)
                        if isinstance(rules, dict):
                            rules = dict(rules)
                            rules["sellableUnits"] = advisor.ledger_available_units(book, position)
                        item = advisor.analyze_position(position, quotes.get(code), minute_rows,
                                                        rules, per_position_budget)
                        item["cashBudgetAssumption"] = str(per_position_budget) if per_position_budget is not None else None
                        position_value = (advisor._decimal(quotes.get(code, {}).get("price")) or 0) * position["units"]
                        item["portfolioWeightPercent"] = str((position_value / total_market_value * 100).quantize(advisor.Decimal("0.01"))) if total_market_value > 0 else None
                        reports.append(item)
                        news_jobs.append((code, position.get("name", code)))
                    with ThreadPoolExecutor(max_workers=5) as executor:
                        news_results = list(executor.map(lambda row: advisor.fetch_headlines(*row), news_jobs))
                    for report, (code, name), news in zip(reports, news_jobs, news_results):
                        headlines.append({"code": code, "name": name, **news})
                        report["newsState"] = news["state"]
                    ai_result = advisor.online_synthesis(reports, headlines)
                    return self.reply(200, {"bookRevision": remote["revision"],
                                            "generatedAt": datetime.now(timezone.utc).isoformat(),
                                            "positions": reports, "news": headlines, "ai": ai_result,
                                            "realOrder": False,
                                            "notice": "手工研究参考；限价不保证成交。任何交易必须由你在券商内自行核对和下单。"})
                if path == "/v1/ai/analyze":
                    if value.get("userConfirmed") is not True:
                        return self.reply(400, {"error": "此分析必须由 iOS 页面明确确认后发起"})
                    context = value.get("context")
                    if not isinstance(context, dict):
                        # 网页路径：只传 code，服务端用账本 + 行情 + 日K + 分红拼完整 context，
                        # 客户端不再各自拼 schema（拼错就是 400 "schema is invalid"）。
                        code = value.get("code")
                        if not isinstance(code, str) or len(code) != 6 or not code.isdigit():
                            return self.reply(400, {"error": "需要完整 context，或提供 6 位代码 code"})
                        try:
                            stored = database.get_real("main")
                            book = json.loads(stored["bookJSON"]) if stored.get("bookJSON") else {}
                            codes = sorted({str(p.get("code")) for p in (book.get("positions") or []) if p.get("code")} | {code})
                            try:
                                rows = market_fetcher(codes)
                            except Exception:
                                rows = []
                            quotes = {row.get("code"): row for row in rows if isinstance(row, dict)}
                            try:
                                bars = daily_fetcher(code)
                            except Exception:
                                bars = []
                            try:
                                dividends = dividend_fetcher(code)
                            except Exception:
                                dividends = []
                            context = build_analysis_context(book, code, quotes, bars, dividends)
                        except InvalidData as error:
                            return self.reply(400, {"error": str(error)})
                        except Exception:
                            return self.reply(503, {"error": "组装分析上下文失败：账本或行情不可用"})
                    try:
                        result = analyze_user_context(context, profile=profile_from_environment())
                        result["createdAt"] = datetime.now(timezone.utc).isoformat()
                        return self.reply(200, result)
                    except AIProviderError as error:
                        return self.reply(503, {"error": str(error)})
                    except ValueError as error:
                        return self.reply(400, {"error": str(error)})
                    except Exception:
                        return self.reply(502, {"error": "DeepSeek 分析失败；未生成建议"})
                if path.startswith("/v1/simulations/"):
                    parts = path.strip("/").split("/")
                    if len(parts) != 3: raise InvalidData("invalid simulation path")
                    strategy = parts[2]
                    if value.get("userConfirmed") is not True:
                        raise InvalidData("virtual account changes require explicit confirmation")
                    expected = value.get("expectedRevision")
                    if type(expected) is not int or expected < 0:
                        raise InvalidData("expectedRevision is required")
                    action = value.get("action")
                    now = datetime.now(timezone.utc).isoformat()
                    current = database.get_twin_account(strategy)
                    if current["revision"] != expected:
                        raise Conflict("simulation revision changed")
                    if action == "start":
                        if set(value) != {"action", "userConfirmed", "expectedRevision", "config"}:
                            raise InvalidData("simulation start fields are invalid")
                        if current["account"] is not None and current["account"].get("status") != "reset":
                            raise InvalidData("account already exists; pause it or reset it before restarting")
                        config = value.get("config")
                        account = create_account(strategy, config, now)
                    else:
                        if current["account"] is None: raise InvalidData("start this virtual account first")
                        if set(value) - {"action", "userConfirmed", "expectedRevision", "amount", "reason"}:
                            raise InvalidData("unexpected simulation action fields")
                        action_request = {"action": action}
                        if action == "reset": action_request["userConfirmed"] = value.get("userConfirmed")
                        if action in ("fund", "withdraw"):
                            for key in ("amount", "reason"):
                                if key in value: action_request[key] = value[key]
                        account = apply_action(current["account"], action_request, now)
                    revision = database.put_twin_account(strategy, expected, account)
                    return self.reply(200, {"strategy": strategy, "revision": revision, "account": account, "realOrder": False})
                if path == "/api/data":
                    if value.get("mode") != "legacy-stage-confirmed":
                        raise InvalidData("legacy staging requires explicit migration action")
                    revision = database.put_legacy_inbox("main", value.get("expectedRevision"), value.get("data"))
                    return self.reply(200, {"ok": True, "revision": revision})
                if path == "/api/web/data":
                    # 旧版网页 POST 的形状是 {tok, data}。没有 data 就拒，别猜。
                    payload = value.get("data")
                    if not isinstance(payload, dict):
                        raise InvalidData("web snapshot requires a data object")
                    expected = value.get("expectedRevision")
                    revision = database.put_web_snapshot("classic", payload,
                                                         int(expected) if isinstance(expected, int) else None)
                    return self.reply(200, {"ok": True, "revision": revision})
                if path == "/v1/grid/reset":
                    # 按当前真实持仓重建网格账户。只影响模拟，不动账本。
                    if value.get("mode") != "grid-reset-confirmed":
                        raise InvalidData("grid reset requires explicit confirmation")
                    book = grid_book()
                    if not book:
                        raise InvalidData("NAS 上还没有真实账本")
                    codes = [p["code"] for p in book.get("positions") or []]
                    quotes = grid_quotes(codes)
                    state = grid.build(book, quotes, grid_bars(codes))
                    database.put_grid_state(state)
                    return self.reply(200, {"ok": True, "summary": grid.summary(state, quotes)})
                if path == "/v1/grid/advance":
                    # 手动推进一次（自动推进由后台线程做）。用来立刻看到结果。
                    if value.get("mode") != "grid-advance-confirmed":
                        raise InvalidData("grid advance requires explicit confirmation")
                    book = grid_book()
                    if not book:
                        raise InvalidData("NAS 上还没有真实账本")
                    stored = database.get_grid_state()
                    state = stored.get("state")
                    codes = [p["code"] for p in book.get("positions") or []]
                    quotes = grid_quotes(codes)
                    if not state:
                        state = grid.build(book, quotes, grid_bars(codes))
                    else:
                        state = grid.sync_with_book(state, book, quotes, grid_bars(codes))
                    state, fills = grid.tick(state, quotes)
                    if datetime.now(ZoneInfo("Asia/Shanghai")).hour >= 15:
                        state = grid.mark_day(state, quotes)
                    database.put_grid_state(state)
                    return self.reply(200, {"ok": True, "fills": len(fills),
                                            "summary": grid.summary(state, quotes)})
                if path.startswith("/v1/backtests/"):
                    strategy = path.rsplit("/", 1)[-1]
                    if value.get("strategy") != strategy:
                        raise InvalidData("path and request strategy do not match")
                    codes = value.get("codes")
                    if not isinstance(codes, list) or not 1 <= len(codes) <= 12:
                        raise InvalidData("choose 1–12 ETF codes")
                    bars, dividends = {}, {}
                    now = datetime.now(timezone.utc)
                    for code in codes:
                        symbol_for(code)
                        cached = database.get_daily(code)
                        if cached is None:
                            try:
                                rows = daily_fetcher(code)
                                database.put_daily(code, rows, now.isoformat())
                                cached = database.get_daily(code)
                            except Exception:
                                return self.reply(503, {"error": f"no verified daily archive or source for {code}"})
                        if cached is None or len(cached["bars"]) < 2:
                            return self.reply(422, {"error": f"at least two archived daily bars are required for {code}"})
                        bars[code] = cached["bars"]
                        distribution = database.get_dividend_events(code)
                        dividends[code] = distribution["events"] if distribution else []
                    result = run_backtest(value, bars, dividends)
                    run_id = uuid.uuid4().hex
                    result["runId"] = run_id
                    result["createdAt"] = now.isoformat()
                    database.put_experiment("backtest-" + run_id, result)
                    return self.reply(200, result)
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
