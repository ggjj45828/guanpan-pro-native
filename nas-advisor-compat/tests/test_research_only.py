import sys
import unittest
import tempfile
import gc
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
import app
import workers
import mobile_research
from domain import NextDatabase


class RetiredRoutesTests(unittest.TestCase):
    def request(self, path, method):
        handler = object.__new__(app.make_handler(object()))
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
            ("do_POST", "/v1/grid/advance"),
            ("do_POST", "/v1/simulations/G"),
            ("do_POST", "/v1/backtests/G"),
            ("do_POST", "/v1/advisor/analyze"),
            ("do_POST", "/v1/ai/analyze"),
        ):
            with self.subTest(path=path, method=method):
                response = self.request(path, method)
                self.assertEqual(response[0][0], 410)

    def test_unavailable_archive_fails_closed(self):
        with patch.object(mobile_research, "snapshot", side_effect=ValueError("bad archive")):
            response = self.request("/v1/mobile/research", "do_GET")
        self.assertEqual(response[0][0], 503)

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
            self.assertEqual(row["intradayResearch"]["volumeCoverage"], 0)
            self.assertFalse(row["intradayResearch"]["pricePlansAllowed"])
            self.assertEqual(row["intradayResearch"]["status"], "insufficient-history-or-coverage")
            quote["source"] = "Eastmoney quote"
            fallback = mobile_research.snapshot(database, lambda codes: [quote], now)
            self.assertNotIn("quote", fallback["data"]["quality"]["researchSnapshot"]["instruments"][0])
            del database
            gc.collect()


if __name__ == "__main__":
    unittest.main()
