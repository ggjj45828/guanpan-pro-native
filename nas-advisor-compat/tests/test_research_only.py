import sys
import unittest
import inspect
import tempfile
import gc
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
import app
import workers
import mobile_research
import market
from domain import NextDatabase


class RetiredRoutesTests(unittest.TestCase):
    def request(self, path, method, database=None):
        handler = object.__new__(app.make_handler(database or object()))
        handler.path = path
        replies = []
        handler.reply = lambda status, body: replies.append((status, body))
        getattr(handler, method)()
        return replies

    def test_simulation_routes_are_gone(self):
        for method, path in (
            ("do_GET", "/v1/grid/status"),
            ("do_GET", "/v1/simulations/G"),
            ("do_GET", "/v1/backtests/runs/old"),
            ("do_GET", "/classic"),
            ("do_GET", "/classic.html"),
            ("do_GET", "/market"),
            ("do_GET", "/market.html"),
            ("do_GET", "/api/web/data"),
            ("do_GET", "/v1/advisor/inventory"),
            ("do_POST", "/v1/grid/advance"),
            ("do_POST", "/v1/simulations/G"),
            ("do_POST", "/v1/backtests/G"),
            ("do_POST", "/v1/advisor/analyze"),
            ("do_POST", "/v1/ai/analyze"),
        ):
            with self.subTest(path=path, method=method):
                response = self.request(path, method)
                self.assertEqual(response[0][0], 410)

    def test_root_is_a_service_pointer_not_a_second_advisor_ui(self):
        response = self.request("/", "do_GET")
        self.assertEqual(response[0][0], 200)
        payload = response[0][1]
        self.assertEqual(payload["role"], "NAS 后台研究与数据服务")
        self.assertIn("/v1/mobile/research", payload["research"])

    def test_unavailable_archive_fails_closed(self):
        with patch.object(mobile_research, "snapshot", side_effect=ValueError("bad archive")):
            response = self.request("/v1/mobile/research", "do_GET")
        self.assertEqual(response[0][0], 503)

    def test_quote_endpoint_reports_missing_sources_instead_of_empty_success(self):
        handler = object.__new__(app.make_handler(object(), market_fetcher=lambda codes: []))
        handler.path = "/v1/market/quotes?codes=512480"
        replies = []
        handler.reply = lambda status, body: replies.append((status, body))
        handler.do_GET()
        self.assertEqual(replies[0][0], 503)
        self.assertEqual(replies[0][1]["requestedCodes"], ["512480"])

    def test_eastmoney_fallback_requires_exchange_event_timestamp(self):
        import json
        class Response:
            status = 200
            def __init__(self, payload): self.payload = payload
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self, _): return json.dumps({"data": {"diff": [self.payload]}}).encode()
        base = {"f12": "512480", "f14": "ETF", "f2": 0.842, "f60": 0.830}
        with patch.object(market, "urlopen", return_value=Response(base)):
            self.assertEqual(market.fetch_eastmoney_quotes(["512480"]), [])
        base["f124"] = int(datetime.now(timezone.utc).timestamp())
        with patch.object(market, "urlopen", return_value=Response(base)):
            quotes = market.fetch_eastmoney_quotes(["512480"])
        self.assertEqual(len(quotes), 1)
        self.assertEqual(quotes[0]["code"], "512480")
        self.assertNotEqual(quotes[0]["time"], datetime.now(timezone.utc).isoformat())

    def test_stale_daily_archive_attempts_refresh_and_marks_fallback(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as root:
            database = NextDatabase(Path(root) / "advisor.sqlite3")
            old = "2026-10-22T08:00:00+00:00"
            database.put_daily("512480", [{"date": "2026-10-22", "open": "0.800",
                "high": "0.850", "low": "0.790", "close": "0.842", "volume": "10000"}], old)
            calls = []
            def unavailable(code):
                calls.append(code)
                raise OSError("source down")
            handler = object.__new__(app.make_handler(database, daily_fetcher=unavailable))
            handler.path = "/v1/market/daily/512480"
            replies = []
            handler.reply = lambda status, body: replies.append((status, body))
            handler.do_GET()
            self.assertEqual(calls, ["512480"])
            self.assertEqual(replies[0][0], 200)
            self.assertTrue(replies[0][1]["staleArchive"])
            self.assertEqual(replies[0][1]["fetchedAt"], old)
            del handler, database
            gc.collect()

    def test_only_research_workers_start(self):
        started = []
        statuses = []

        class Database:
            def put_worker_status(self, name, at, state, detail):
                statuses.append((name, state, detail))

        class Thread:
            def __init__(self, target, name, daemon):
                started.append(name)

            def start(self):
                pass

        with patch.object(workers.threading, "Thread", Thread):
            workers.start_workers(Database())
        self.assertEqual(started, ["daily-archive", "minute-archive", "dividend-research", "factor-research"])
        self.assertIn(("g-live-simulation", "idle", "retired: no virtual account processing"), statuses)
        self.assertIn(("portfolio-grid", "idle", "retired: no simulated grid fills"), statuses)
        self.assertEqual(workers.DEFAULT_CODES, ())

    def test_archive_workers_use_multi_source_quote_and_daily_adapters(self):
        parameters = inspect.signature(workers.start_workers).parameters
        self.assertIs(parameters["daily_fetcher"].default, workers.fetch_daily)
        self.assertIs(parameters["quote_fetcher"].default, workers.fetch_quotes)

    def test_phone_archive_bridge_uses_real_rows_without_inventing_vwap(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as root:
            database = NextDatabase(Path(root) / "advisor.sqlite3")
            database.track_instrument("512480", "2026-10-23T00:00:00+00:00")
            database.put_daily("512480", [{"date": "2026-10-23", "open": "0.800",
                "high": "0.850", "low": "0.790", "close": "0.842", "volume": "10000"}],
                "2026-10-23T08:00:00+00:00")
            database.put_minute("512480", [{"timestamp": "2026-10-23T09:31:00+08:00",
                "price": "0.810", "volume": "100", "iopv": None}], "2026-10-23T01:32:00+00:00")
            now = datetime(2026, 10, 24, 1, 0, tzinfo=timezone.utc)
            quote = {"code": "512480", "price": "0.842", "time": "2026-10-24T08:59:30+08:00",
                     "source": "Tencent qt.gtimg.cn"}
            result = mobile_research.snapshot(database, lambda codes: [quote], now)
            row = result["data"]["quality"]["researchSnapshot"]["instruments"][0]
            self.assertEqual(row["symbol"], "512480")
            self.assertEqual(row["bars"][0]["close"], 8420)
            self.assertEqual(row["quote"]["price"], 8420)
            self.assertIsNone(row["intradayResearch"]["volumeCoverage"])
            self.assertFalse(row["intradayResearch"]["pricePlansAllowed"])
            self.assertEqual(row["intradayResearch"]["status"], "raw-archive-only")
            self.assertIn("minuteStats", row)
            quote["source"] = "Eastmoney quote"
            fallback = mobile_research.snapshot(database, lambda codes: [quote], now)
            self.assertNotIn("quote", fallback["data"]["quality"]["researchSnapshot"]["instruments"][0])
            del database
            gc.collect()

    def test_minute_stats_require_daily_volume_crosscheck_and_match_ios_schema(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as root:
            database = NextDatabase(Path(root) / "advisor.sqlite3")
            database.put_daily("512480", [{"date": "2026-10-23", "open": "0.800",
                "high": "0.850", "low": "0.790", "close": "0.842", "volume": "240"}],
                "2026-10-23T08:00:00+00:00")
            rows = []
            for index in range(240):
                if index < 120:
                    hour, minute = 9 + (30 + index) // 60, (30 + index) % 60
                else:
                    afternoon = index - 120
                    hour, minute = 13 + afternoon // 60, afternoon % 60
                stamp = datetime(2026, 10, 23, hour, minute, tzinfo=mobile_research.CN)
                rows.append({"timestamp": stamp.isoformat(), "price": "0.841" if index % 2 else "0.839",
                             "volume": "1", "iopv": None})
            database.put_minute("512480", rows, "2026-10-23T08:00:00+00:00")
            stats = mobile_research.minute_stats(database, "512480", datetime(2026, 10, 24, 1, 0, tzinfo=timezone.utc))
            self.assertEqual(set(stats), {"days", "minutes", "lastDay", "quality", "freshness", "windows", "roundTripEvidence"})
            self.assertEqual(set(stats["quality"]), {"days", "minuteCoverage", "hasVolume", "enoughForLongTerm", "volumeCoverage"})
            self.assertEqual(set(stats["freshness"]), {"lastDay", "ageMinutes", "isToday", "stale", "reason"})
            self.assertEqual(stats["days"], 1)
            self.assertTrue(stats["quality"]["hasVolume"])
            self.assertFalse(stats["quality"]["enoughForLongTerm"])
            self.assertEqual(stats["windows"]["5"]["vwap"], "0.8400")
            self.assertEqual(set(stats["windows"]["5"]), {
                "window", "daysUsed", "dayCoverage", "minuteCoverage", "vwap", "closeVsVwapPercent",
                "amplitudeMedianPercent", "roundTripsMedian", "support", "resistance", "supportP10",
                "resistanceP90", "volatilityPercent", "vwapHighDeviationMedian", "vwapLowDeviationMedian",
                "volumeCoverage"})
            self.assertEqual(stats["windows"]["5"]["daysUsed"], 1)
            self.assertGreater(stats["windows"]["5"]["roundTripsMedian"], 0)
            self.assertEqual(stats["roundTripEvidence"], None)
            # A mismatched daily total invalidates this session instead of
            # silently converting uncertain provider units into a VWAP.
            database.put_daily("512480", [{"date": "2026-10-23", "open": "0.800",
                "high": "0.850", "low": "0.790", "close": "0.842", "volume": "500"}],
                "2026-10-23T08:00:00+00:00")
            rejected = mobile_research.minute_stats(database, "512480", datetime(2026, 10, 24, 1, 0, tzinfo=timezone.utc))
            self.assertFalse(rejected["quality"]["hasVolume"])
            self.assertEqual(rejected["windows"], {})
            del database
            gc.collect()

    def test_phone_research_endpoint_includes_optional_long_term_stats(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as root:
            database = NextDatabase(Path(root) / "advisor.sqlite3")
            response = self.request("/v1/research/512480", "do_GET", database)
            self.assertEqual(response[0][0], 200)
            self.assertIn("minuteStats", response[0][1])
            self.assertEqual(response[0][1]["minuteStats"]["days"], 0)
            self.assertFalse(response[0][1]["minuteStats"]["quality"]["enoughForLongTerm"])
            del database
            gc.collect()


if __name__ == "__main__":
    unittest.main()
