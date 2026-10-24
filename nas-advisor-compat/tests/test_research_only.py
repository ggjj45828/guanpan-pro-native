import sys
import unittest
import inspect
import json
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
import cross_market
from domain import InvalidData, NextDatabase


class CrossMarketEvidenceTests(unittest.TestCase):
    def test_cross_market_archive_preserves_exchange_day_and_rejects_future_points(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        rows = [{"timestamp": "2026-10-23T11:30:00+09:00", "price": "100"}]
        database.put_cross_market_minute("KR_KOSPI", rows, "verified fixture", "2026-10-23T03:00:00Z")
        self.assertEqual(database.cross_market_days("KR_KOSPI", "2026-10-23", "2026-10-23"), ["2026-10-23"])
        self.assertEqual(database.get_cross_market_minute("KR_KOSPI", "2026-10-23")["rows"], [
            {"timestamp": rows[0]["timestamp"], "price": "100", "volume": None, "iopv": None}
        ])
        with self.assertRaises(InvalidData):
            database.put_cross_market_minute("KR_KOSPI", [
                {"timestamp": "2026-10-23T13:00:00+09:00", "price": "101"}
            ], "verified fixture", "2026-10-23T03:00:00Z")

    def test_replay_api_helper_reports_missing_real_archive_without_fabricating_result(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        result = mobile_research.replay_lunch_archive(
            database, "KR_KOSPI", "512480", "2026-10-01", "2026-10-23",
            {"leaderShockAtLeast": 0.005, "assetMorningAtMost": 0.0, "expectedDirection": 1})
        self.assertEqual(result["state"], "insufficient_samples")
        self.assertEqual(result["evidenceState"], "insufficient_real_archive")
        self.assertIsNone(result["confirmationRate"])

    def test_replay_readonly_api_returns_insufficient_without_real_archives(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        handler = object.__new__(app.make_handler(database))
        handler.path = ("/v1/research/cross-market/replay?leader=KR_KOSPI&asset=512480&"
                        "start=2026-10-01&end=2026-10-23")
        responses = []
        handler.reply = lambda status, body: responses.append((status, body))
        handler.do_GET()
        self.assertEqual(responses[0][0], 200)
        self.assertEqual(responses[0][1]["evidenceState"], "insufficient_real_archive")
        self.assertIsNone(responses[0][1]["confirmationRate"])

    def test_future_points_are_excluded_from_pair_and_lunch_calculations(self):
        from datetime import datetime, timedelta, timezone
        now = datetime(2026, 10, 23, 5, 0, tzinfo=timezone.utc)
        start = now - timedelta(minutes=180)
        leader, follower = [], []
        price = 100.0
        for i in range(181):
            stamp = start + timedelta(minutes=i)
            price *= 1 + ((i % 7) - 3) * 0.0001
            leader.append({"timestamp": stamp.isoformat(), "price": price})
            follower.append({"timestamp": stamp.isoformat(), "price": 50 + i * 0.002})
        future = (now + timedelta(minutes=1)).isoformat()
        leader.append({"timestamp": future, "price": 1_000_000})
        follower.append({"timestamp": future, "price": 0.00001})
        baseline = cross_market.analyze_pair(leader[:-1], follower[:-1], as_of=now.isoformat(),
                                             source="fixture", market_status="closed")
        with_future = cross_market.analyze_pair(leader, follower, as_of=now.isoformat(),
                                                source="fixture", market_status="closed")
        self.assertEqual(baseline, with_future)
        self.assertEqual(with_future["leaderSamples"], 181)

    def test_insufficient_or_stale_evidence_never_claims_stable_lead(self):
        from datetime import datetime, timedelta, timezone
        now = datetime(2026, 10, 23, 5, 0, tzinfo=timezone.utc)
        short = [{"timestamp": (now - timedelta(minutes=2)).isoformat(), "price": 10}]
        insufficient = cross_market.analyze_pair(short, short, as_of=now.isoformat(),
                                                 source="verified fixture", market_status="open")
        self.assertEqual(insufficient["state"], "no_stable_relationship")
        stale = cross_market.analyze_pair(short, short, as_of=now.isoformat(),
                                          source="verified fixture", market_status="open", max_age_seconds=30)
        self.assertEqual(stale["state"], "stale")
        self.assertEqual(stale["windows"], [])

    def test_lunch_shock_requires_real_1130_and_1250_observations(self):
        rows = [
            {"timestamp": "2026-10-23T11:30:00+08:00", "price": 100},
            {"timestamp": "2026-10-23T12:50:00+08:00", "price": 101.3},
        ]
        result = cross_market.lunch_shock(rows, day="2026-10-23", as_of="2026-10-23T13:00:00+08:00")
        self.assertEqual(result["state"], "observed")
        self.assertAlmostEqual(result["return"], 0.013)
        missing = cross_market.lunch_shock(rows[:1], day="2026-10-23", as_of="2026-10-23T13:00:00+08:00")
        self.assertEqual(missing["state"], "insufficient")

    def test_historical_replay_freezes_at_1250_and_aggregates_only_enough_signals(self):
        from datetime import date, timedelta
        rule = {"leaderShockAtLeast": 0.005, "assetMorningAtMost": 0.0, "expectedDirection": 1}
        leader, asset = [], []
        for hhmm, lp, ap in (("09:30", 100, 50), ("11:30", 100, 49),
                             ("12:50", 101, 49), ("13:00", 101, 49),
                             ("13:05", 101, 49.5), ("13:15", 101, 49.6),
                             ("13:30", 101, 49.7), ("14:00", 101, 49.8)):
            stamp = f"2026-10-23T{hhmm}:00+08:00"
            leader.append({"timestamp": stamp, "price": lp})
            asset.append({"timestamp": stamp, "price": ap})
        one = cross_market.replay_lunch_day(leader, asset, day="2026-10-23", source="fixture", rule=rule)
        changed_after_cutoff = [dict(r, price=999 if r["timestamp"].startswith("2026-10-23T13:") else r["price"])
                                for r in asset]
        two = cross_market.replay_lunch_day(leader, changed_after_cutoff, day="2026-10-23",
                                            source="fixture", rule=rule)
        self.assertEqual(one["frozenHypothesis"], two["frozenHypothesis"])
        self.assertEqual(one["frozenHypothesis"]["state"], "hypothesis")
        self.assertTrue(one["confirmedAt5m"])
        days, cursor = [], date(2026, 10, 23)
        while len(days) < 100:
            if cursor.weekday() < 5:
                day = cursor.isoformat()
                def shift(rows):
                    return [dict(row, timestamp=day + row["timestamp"][10:]) for row in rows]
                days.append({"day": day, "leader": shift(leader), "asset": shift(asset)})
            cursor -= timedelta(days=1)
        days.append(days[0])  # Duplicate sessions must not inflate evidence.
        summary = cross_market.replay_lunch_days(days, source="fixture", rule=rule, minimum_samples=100)
        self.assertEqual(summary["state"], "evaluated")
        self.assertEqual(summary["hypothesisCount"], 100)
        self.assertEqual(summary["confirmationRate"], 1.0)
        self.assertEqual(len(summary["results"]), 100)
        limited = cross_market.replay_lunch_days(days[:32], source="fixture", rule=rule,
                                                minimum_samples=100)
        self.assertEqual(limited["state"], "insufficient_samples")
        self.assertIsNone(limited["confirmationRate"])


class RetiredRoutesTests(unittest.TestCase):
    def request(self, path, method, database=None):
        handler = object.__new__(app.make_handler(database or object()))
        handler.path = path
        replies = []
        handler.reply = lambda status, body: replies.append((status, body))
        getattr(handler, method)()
        return replies

    def test_simulation_routes_are_gone(self):
        self.assertFalse((Path(__file__).resolve().parents[1] / "server" / "ai.py").exists(),
                         "NAS must not ship a separate model advisor")
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
            ("do_GET", "/v1/ai/verify"),
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
        self.assertFalse(any("simulation" in name or "grid" in name for name, _, _ in statuses))
        self.assertEqual(workers.DEFAULT_CODES, ())

    def test_archives_alone_do_not_keep_demo_symbols_on_upstream_poll_list(self):
        class Database:
            archived_codes = {"512480", "513520"}

            def tracked_instruments(self):
                return []

            def get_real(self, book_id):
                return {"bookJSON": None}

        codes = workers.tracked_codes(Database())
        self.assertEqual(codes, [], "old archive rows are not permission to keep polling symbols")

    def test_collector_uses_explicit_tracking_and_real_positive_holdings(self):
        class Database:
            def tracked_instruments(self):
                return ["510300"]

            def get_real(self, book_id):
                return {"bookJSON": json.dumps({"positions": [
                    {"code": "512480", "units": 500},
                    {"code": "513520", "units": 0},
                ]})}

        self.assertEqual(workers.tracked_codes(Database()), ["510300", "512480"])

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
            result = mobile_research.snapshot(database, now)
            row = result["data"]["quality"]["researchSnapshot"]["instruments"][0]
            self.assertEqual(row["symbol"], "512480")
            self.assertEqual(row["bars"][0]["close"], 8420)
            self.assertNotIn("quote", row, "NAS research snapshots must not fetch live quotes")
            self.assertIsNone(row["intradayResearch"]["volumeCoverage"])
            self.assertFalse(row["intradayResearch"]["pricePlansAllowed"])
            self.assertEqual(row["intradayResearch"]["status"], "raw-archive-only")
            self.assertIn("minuteStats", row)
            fallback = mobile_research.snapshot(database, now)
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
            self.assertEqual(response[0][1]["crossMarket"]["state"], "insufficient_real_archive")
            self.assertIsNone(response[0][1]["crossMarket"]["conditionalWinRate"])
            self.assertIsNone(response[0][1]["ai"])
            self.assertFalse(response[0][1]["providerConfigured"])
            self.assertEqual(response[0][1]["providerStatus"]["state"], "phone-only")
            del database
            gc.collect()

    def test_health_does_not_report_a_nas_model_provider(self):
        class Database:
            def worker_health(self): return []
        response = self.request("/health", "do_GET", Database())
        self.assertEqual(response[0][0], 200)
        self.assertNotIn("aiProvider", response[0][1])


if __name__ == "__main__":
    unittest.main()
