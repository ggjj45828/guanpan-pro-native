import sys
import unittest
import inspect
import json
import io
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
    def test_replay_assessment_requires_holdout_controls_and_does_not_overclaim(self):
        few = [{"triggered": index < 20, "confirmed": index % 2 == 0}
               for index in range(100)]
        self.assertEqual(cross_market._replay_assessment(few, 30)["state"], "insufficient_samples")

        # A large, balanced holdout can reject a practically meaningful edge.
        balanced = [{"triggered": index % 2 == 0, "confirmed": index % 4 < 2}
                    for index in range(12000)]
        assessment = cross_market._replay_assessment(balanced, 100)
        self.assertEqual(assessment["state"], "no_stable_relationship")
        self.assertIn("没有稳定领先关系", assessment["note"])

        # A clearly separated holdout remains a candidate, never an established law.
        candidate = [{"triggered": index % 2 == 0,
                      "confirmed": (index % 10 < 8 if index % 2 == 0 else index % 4 == 1)}
                     for index in range(1200)]
        assessment = cross_market._replay_assessment(candidate, 100)
        self.assertEqual(assessment["state"], "candidate_requires_replication")
        self.assertIn("后续未见数据复现", assessment["note"])

    def test_verified_tencent_mainland_index_minute_parser_uses_only_current_session(self):
        from datetime import datetime
        now = datetime.fromisoformat("2026-10-23T09:32:00+08:00")
        body = ('min_data_sh000001={"code":0,"msg":"","data":{"sh000001":{"data":'
                '{"date":"20261023","data":["0930 3623.57 1000 1",'
                '"0931 3622.80 2000 2","0933 3620.00 3000 3"]}}}}')
        rows = workers.parse_cross_market_minute(body, "sh000001", now=now)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["timestamp"], "2026-10-23T09:30:00+08:00")
        self.assertEqual(rows[0]["price"], "3623.57")
        self.assertIsNone(rows[0]["volume"])
        with self.assertRaises(ValueError):
            workers.parse_cross_market_minute(body, "b_KOSPI", now=now)
        stale = body.replace("20261023", "20261022")
        with self.assertRaisesRegex(ValueError, "non-current session"):
            workers.parse_cross_market_minute(stale, "sh000001", now=now)
        delayed = body.replace("0930", "0800").replace("0931", "0801").replace("0933", "0803")
        with self.assertRaisesRegex(ValueError, "stale"):
            workers.parse_cross_market_minute(delayed, "sh000001", now=now)

    def test_eastmoney_global_minute_parser_checks_whitelist_timestamp_and_freshness(self):
        now = datetime.fromisoformat("2026-10-23T08:31:00+08:00")
        payload = {"rc": 0, "data": {"code": "KS11", "trends": [
            "2026-10-23 08:00,2600.10,0,0,0,0", "2026-10-23 08:30,2601.20,0,0,0,0",
            "2026-10-23 15:02,9999,0,0,0,0"]}}
        rows, source = market.parse_eastmoney_cross_market_minute(payload, "KR_KOSPI", now=now)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[-1]["timestamp"], "2026-10-23T09:30:00+09:00")
        self.assertEqual(source, "Eastmoney trends 100.KS11")
        self.assertIsNone(rows[-1]["volume"])
        with self.assertRaisesRegex(ValueError, "stale"):
            market.parse_eastmoney_cross_market_minute(payload, "KR_KOSPI",
                now=datetime.fromisoformat("2026-10-23T08:43:00+08:00"))
        with self.assertRaisesRegex(ValueError, "matching index"):
            market.parse_eastmoney_cross_market_minute(payload, "JP_N225", now=now)

    def test_cross_market_session_gate_handles_lunch_weekends_and_us_dst(self):
        cases = [
            ("JP_N225", "2026-10-23T10:00:00+09:00", True),
            ("JP_N225", "2026-10-23T12:00:00+09:00", False),
            ("KR_KOSPI", "2026-10-23T14:00:00+09:00", True),
            ("HK_HSI", "2026-10-23T12:30:00+08:00", False),
            ("US_NDX", "2026-07-06T09:30:00-04:00", True),
            ("US_SPX", "2026-01-05T09:30:00-05:00", True),
            ("US_SPX", "2026-01-03T10:00:00-05:00", False),
        ]
        for market_id, stamp, expected in cases:
            with self.subTest(market_id=market_id, stamp=stamp):
                self.assertEqual(workers.market_session_open(market_id,
                    datetime.fromisoformat(stamp)), expected)

    def test_collector_archives_only_open_markets_and_reports_source_failures(self):
        class Database:
            def __init__(self): self.saved = []
            def put_cross_market_minute(self, market_id, rows, source, fetched_at):
                self.saved.append((market_id, rows, source, fetched_at))

        database = Database()
        calls = []
        def fetcher(market_id):
            calls.append(market_id)
            if market_id == "KR_KOSPI": raise OSError("provider unavailable")
            return ([{"timestamp": "2026-10-23T09:00:00+09:00", "price": "100"}], "verified fixture")

        now = datetime.fromisoformat("2026-10-23T00:00:00+00:00")
        result = workers.collect_cross_market_once(database, now=now,
            series_ids=("JP_N225", "KR_KOSPI", "US_NDX"), fetcher=fetcher)
        self.assertEqual(calls, ["JP_N225", "KR_KOSPI"])
        self.assertEqual(result["state"], "degraded")
        self.assertEqual(result["failures"], ["KR_KOSPI:OSError"])
        self.assertEqual([row[0] for row in database.saved], ["JP_N225"])
        self.assertEqual(database.saved[0][3], "2026-10-23T00:00:00+00:00")

    def test_repeated_stale_provider_pauses_only_current_market_session(self):
        class Database:
            def put_cross_market_minute(self, *args): self.fail("stale response must not be archived")

        calls = []
        def stale_fetcher(market_id):
            calls.append(market_id)
            raise ValueError("cross-market provider minute data is stale")

        state, paused = {}, {}
        morning = datetime.fromisoformat("2026-10-23T00:00:00+00:00")
        for _ in range(3):
            result = workers.collect_cross_market_once(Database(), now=morning,
                series_ids=("JP_N225",), fetcher=stale_fetcher,
                stale_failures=state, suppressed_sessions=paused)
        self.assertEqual(len(calls), 3)
        self.assertEqual(result["paused"], ["JP_N225"])
        same_session = workers.collect_cross_market_once(Database(), now=morning,
            series_ids=("JP_N225",), fetcher=stale_fetcher,
            stale_failures=state, suppressed_sessions=paused)
        self.assertEqual(same_session["state"], "idle")
        self.assertEqual(len(calls), 3)
        afternoon = datetime.fromisoformat("2026-10-23T03:30:00+00:00")
        resumed = workers.collect_cross_market_once(Database(), now=afternoon,
            series_ids=("JP_N225",), fetcher=stale_fetcher,
            stale_failures=state, suppressed_sessions=paused)
        self.assertEqual(resumed["state"], "degraded")
        self.assertEqual(len(calls), 4)

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

    def test_user_hypothesis_post_is_readonly_and_fails_closed_without_archive(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        body = {"leader": "KR_KOSPI", "asset": "512480", "start": "2026-10-01",
                "end": "2026-10-23", "minimumSamples": 100,
                "hypothesis": {"id": "generic", "cutoff": "12:50",
                    "conditions": [{"series": "leader", "from": "11:30", "to": "12:50",
                                     "operator": "gte", "threshold": 0.005}],
                    "expectedDirection": 1, "outcomeBaseline": "13:00", "confirmAt": "13:05"}}
        raw = json.dumps(body).encode()
        handler = object.__new__(app.make_handler(database))
        handler.path = "/v1/research/cross-market/hypothesis"
        handler.headers = {"Content-Length": str(len(raw))}
        handler.rfile = io.BytesIO(raw)
        responses = []
        handler.reply = lambda status, value: responses.append((status, value))
        handler.do_POST()
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
        self.assertEqual(with_future["state"], "insufficient",
                         "minute points from one session are not independent evidence")

    def test_lead_lag_stability_uses_independent_sessions_not_minute_count(self):
        from datetime import date, datetime, time, timedelta
        from zoneinfo import ZoneInfo
        leader, follower = [], []
        cursor = date(2026, 10, 23)
        session = 0
        while session < 100:
            if cursor.weekday() < 5:
                direction = 1 if session % 2 == 0 else -1
                start = datetime.combine(cursor, time(9, 30), ZoneInfo("Asia/Shanghai"))
                for minute in range(211):
                    stamp = (start + timedelta(minutes=minute)).isoformat()
                    leader.append({"timestamp": stamp, "price": 100 + direction * minute * 0.005})
                    follower.append({"timestamp": stamp, "price": 50 + direction * minute * 0.002})
                session += 1
            cursor -= timedelta(days=1)
        result = cross_market.analyze_pair(leader, follower,
            as_of="2026-10-24T00:00:00+08:00", source="multi-session fixture", market_status="closed")
        window = next(row for row in result["windows"] if row["lagMinutes"] == 0 and row["horizonMinutes"] == 5)
        self.assertEqual(window["sampleCount"], 100)
        self.assertEqual(window["sampleUnit"], "independent trading sessions")
        self.assertGreater(window["observationCount"], window["sampleCount"])
        self.assertEqual(window["state"], "stable_candidate")
        self.assertEqual(window["conditionalWinRate"], 1.0)

    def test_100_sessions_without_variation_explicitly_report_no_stable_relationship(self):
        from datetime import date, time, timedelta
        from zoneinfo import ZoneInfo
        leader, follower = [], []
        cursor = date(2026, 10, 23)
        sessions = 0
        while sessions < 100:
            if cursor.weekday() < 5:
                for clock, price in ((time(9, 25), 100), (time(9, 30), 100)):
                    stamp = datetime.combine(cursor, clock, ZoneInfo("Asia/Shanghai")).isoformat()
                    leader.append({"timestamp": stamp, "price": price})
                for clock, price in ((time(9, 30), 50), (time(9, 35), 50)):
                    stamp = datetime.combine(cursor, clock, ZoneInfo("Asia/Shanghai")).isoformat()
                    follower.append({"timestamp": stamp, "price": price})
                sessions += 1
            cursor -= timedelta(days=1)
        report = cross_market.analyze_pair(leader, follower,
            as_of="2026-10-24T00:00:00+08:00", source="flat fixture", market_status="closed")
        self.assertEqual(report["state"], "no_stable_relationship")
        self.assertIn("没有稳定领先关系", report["reason"])

    def test_holding_research_reads_archived_minute_rows_and_finds_only_supported_pair(self):
        import shutil
        from datetime import date, time, timedelta
        from zoneinfo import ZoneInfo
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        now = datetime.now(timezone.utc)
        cursor = now.astimezone(ZoneInfo("Asia/Shanghai")).date()
        session = 0
        while session < 100:
            if cursor.weekday() < 5:
                direction = 1 if session % 2 == 0 else -1
                leader = []
                asset = []
                for clock, price in ((time(9, 25), 100), (time(9, 30), 100 + direction)):
                    stamp = datetime.combine(cursor, clock, ZoneInfo("Asia/Shanghai")).isoformat()
                    leader.append({"timestamp": stamp, "price": str(price)})
                for clock, price in ((time(9, 30), 50), (time(9, 35), 50 + direction / 2)):
                    stamp = datetime.combine(cursor, clock, ZoneInfo("Asia/Shanghai")).isoformat()
                    asset.append({"timestamp": stamp, "price": str(price), "volume": None, "iopv": None})
                database.put_cross_market_minute("KR_KOSPI", leader, "verified fixture", now.isoformat())
                database.put_minute("512480", asset, now.isoformat())
                session += 1
            cursor -= timedelta(days=1)
        report = mobile_research.cross_market_evidence(database, "512480", now=now)
        self.assertEqual(report["state"], "stable_candidate")
        self.assertEqual(report["bestMarket"], "KR_KOSPI")
        self.assertEqual(report["sampleCount"], 100)
        self.assertEqual(report["source"], "verified fixture")

    def test_insufficient_or_stale_evidence_never_claims_stable_lead(self):
        from datetime import datetime, timedelta, timezone
        now = datetime(2026, 10, 23, 5, 0, tzinfo=timezone.utc)
        short = [{"timestamp": (now - timedelta(minutes=2)).isoformat(), "price": 10}]
        insufficient = cross_market.analyze_pair(short, short, as_of=now.isoformat(),
                                                 source="verified fixture", market_status="open")
        self.assertEqual(insufficient["state"], "insufficient")
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
        self.assertEqual(summary["state"], "insufficient_samples")
        self.assertEqual(summary["replayState"], "evaluated")
        self.assertEqual(summary["hypothesisCount"], 100)
        self.assertIsNone(summary["confirmationRate"], "full-sample hit rate must not look like holdout evidence")
        self.assertEqual(summary["inSampleConfirmationRate"], 1.0)
        self.assertEqual(len(summary["results"]), 100)
        limited = cross_market.replay_lunch_days(days[:32], source="fixture", rule=rule,
                                                minimum_samples=100)
        self.assertEqual(limited["state"], "insufficient_samples")
        self.assertIsNone(limited["confirmationRate"])

    def test_user_defined_hypothesis_replays_without_changing_rule_code(self):
        hypothesis = {
            "id": "kospi-morning-strength-to-semiconductor-afternoon",
            "cutoff": "12:50", "cutoffTimezone": "Asia/Shanghai",
            "leaderTimezone": "Asia/Seoul", "assetTimezone": "Asia/Shanghai",
            "conditions": [
                {"series": "leader", "from": "09:00", "to": "11:30",
                 "operator": "gte", "threshold": 0.005},
                {"series": "asset", "from": "09:30", "to": "11:30",
                 "operator": "lte", "threshold": 0.0},
            ],
            "expectedDirection": 1, "outcomeBaseline": "13:00", "confirmAt": "13:05",
            "horizons": ["13:15", "13:30"],
        }
        leader = [
            {"timestamp": "2026-10-23T09:00:00+09:00", "price": 100},
            {"timestamp": "2026-10-23T11:30:00+09:00", "price": 101},
        ]
        asset = [
            {"timestamp": "2026-10-23T09:30:00+08:00", "price": 50},
            {"timestamp": "2026-10-23T11:30:00+08:00", "price": 49.7},
            {"timestamp": "2026-10-23T12:50:00+08:00", "price": 49.8},
            {"timestamp": "2026-10-23T13:00:00+08:00", "price": 49.8},
            {"timestamp": "2026-10-23T13:05:00+08:00", "price": 49.9},
            {"timestamp": "2026-10-23T13:15:00+08:00", "price": 50.0},
            {"timestamp": "2026-10-23T13:30:00+08:00", "price": 50.1},
        ]
        report = cross_market.replay_hypothesis_day(leader, asset, day="2026-10-23",
                                                    source="verified fixture", hypothesis=hypothesis)
        self.assertEqual(report["frozenHypothesis"]["state"], "hypothesis")
        self.assertTrue(report["confirmed"])
        tampered = [dict(row, price=1) if row["timestamp"].startswith("2026-10-23T13:") else row
                    for row in asset]
        repeated = cross_market.replay_hypothesis_day(leader, tampered, day="2026-10-23",
                                                     source="verified fixture", hypothesis=hypothesis)
        self.assertEqual(report["frozenHypothesis"], repeated["frozenHypothesis"])

    def test_replay_outcome_never_uses_a_pre_1300_price_for_a_1300_baseline(self):
        hypothesis = {"id": "frozen-test", "cutoff": "12:50",
            "conditions": [{"series": "leader", "from": "11:30", "to": "12:50",
                            "operator": "gte", "threshold": 0.0}],
            "expectedDirection": 1, "outcomeBaseline": "13:00", "confirmAt": "13:05"}
        leader = [{"timestamp": "2026-10-23T11:30:00+08:00", "price": 100},
                  {"timestamp": "2026-10-23T12:50:00+08:00", "price": 101}]
        asset = [{"timestamp": "2026-10-23T11:30:00+08:00", "price": 50},
                 {"timestamp": "2026-10-23T12:59:00+08:00", "price": 40}]
        report = cross_market.replay_hypothesis_day(leader, asset, day="2026-10-23",
                                                     source="fixture", hypothesis=hypothesis)
        self.assertIsNone(report["confirmationReturn"])
        self.assertIsNone(report["confirmed"])
        self.assertEqual(report["outcomeState"], "awaiting_post_cutoff_data")
        with self.assertRaisesRegex(ValueError, "weekend"):
            cross_market.replay_hypothesis_day([], [], day="2026-10-24",
                source="fixture", hypothesis=hypothesis)


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
        self.assertEqual(started, ["daily-archive", "minute-archive", "dividend-research",
                                   "factor-research", "cross-market-minute"])
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
        self.assertIs(parameters["cross_market_fetcher"].default, workers.fetch_cross_market_minute)

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
