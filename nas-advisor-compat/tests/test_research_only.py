import sys
import unittest
import inspect
import json
import io
import tempfile
import gc
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
import app
import workers
import mobile_research
import market
import cross_market
from domain import InvalidData, NextDatabase


class LiveDivergenceTests(unittest.TestCase):
    def test_divergence_is_time_aligned_fresh_and_observation_only(self):
        as_of = datetime.fromisoformat("2026-10-23T09:45:00+08:00")
        leader = [
            {"timestamp": "2026-10-23T10:30:00+09:00", "price": "100"},
            {"timestamp": "2026-10-23T10:45:00+09:00", "price": "99.4"},
        ]
        asset = [
            {"timestamp": "2026-10-23T09:30:00+08:00", "price": "1.000"},
            {"timestamp": "2026-10-23T09:45:00+08:00", "price": "1.004"},
        ]
        result = cross_market.detect_live_divergence(leader, asset, as_of=as_of)
        self.assertEqual(result["state"], "observed_divergence")
        self.assertAlmostEqual(result["leaderReturnPercent"], -0.6, places=4)
        self.assertAlmostEqual(result["assetReturnPercent"], 0.4, places=4)
        self.assertFalse(result["eligibleForTradingSignal"])
        self.assertEqual(datetime.fromisoformat(result["expiresAt"]),
                         datetime.fromisoformat("2026-10-23T09:55:00+08:00"))
        self.assertNotIn("price", result)

    def test_divergence_rejects_future_points_and_stale_sources(self):
        as_of = datetime.fromisoformat("2026-10-23T09:45:00+08:00")
        leader = [
            {"timestamp": "2026-10-23T10:30:00+09:00", "price": "100"},
            {"timestamp": "2026-10-23T10:45:00+09:00", "price": "99.4"},
            {"timestamp": "2026-10-23T10:50:00+09:00", "price": "1"},
        ]
        asset = [
            {"timestamp": "2026-10-23T09:30:00+08:00", "price": "1.000"},
            {"timestamp": "2026-10-23T09:45:00+08:00", "price": "1.004"},
            {"timestamp": "2026-10-23T09:50:00+08:00", "price": "9"},
        ]
        result = cross_market.detect_live_divergence(leader, asset, as_of=as_of)
        self.assertEqual(result["state"], "observed_divergence")
        self.assertLessEqual(datetime.fromisoformat(result["asOf"]).astimezone(timezone.utc),
                             as_of.astimezone(timezone.utc))
        stale = cross_market.detect_live_divergence(leader, asset,
            as_of=datetime.fromisoformat("2026-10-23T10:30:00+08:00"))
        self.assertEqual(stale["state"], "stale")
        self.assertFalse(stale["eligibleForTradingSignal"])

    def test_divergence_requires_nearby_window_endpoints(self):
        as_of = datetime.fromisoformat("2026-10-23T09:45:00+08:00")
        leader = [{"timestamp": "2026-10-23T10:30:00+09:00", "price": "100"},
                  {"timestamp": "2026-10-23T10:45:00+09:00", "price": "99"}]
        asset = [{"timestamp": "2026-10-23T09:30:00+08:00", "price": "1.0"},
                 {"timestamp": "2026-10-23T09:43:00+08:00", "price": "1.1"}]
        result = cross_market.detect_live_divergence(leader, asset, as_of=as_of)
        self.assertEqual(result["state"], "insufficient_data")

    def test_divergence_rejects_nonfinite_or_boolean_threshold(self):
        as_of = datetime.fromisoformat("2026-10-23T09:45:00+08:00")
        for threshold in (float("nan"), float("inf"), True):
            with self.subTest(threshold=threshold), self.assertRaises(ValueError):
                cross_market.detect_live_divergence([], [], as_of=as_of,
                                                    minimum_move_percent=threshold)


class OvernightAbsorptionTests(unittest.TestCase):
    def test_uses_complete_point_in_time_sessions_and_never_emits_trade_signal(self):
        leader, asset = [], []
        shanghai = timezone(timedelta(hours=8))
        day = datetime(2026, 8, 3, tzinfo=shanghai).date()
        trading_days = []
        while len(trading_days) < 32:
            if day.weekday() < 5:
                trading_days.append(day)
            day += timedelta(days=1)
        for index, session_day in enumerate(trading_days):
            base = 100 + index
            previous_close = datetime.combine(session_day, datetime.min.time(), shanghai).replace(hour=14, minute=59)
            overnight_at = previous_close.replace(hour=16, minute=0)
            asset.extend([
                {"timestamp": previous_close.isoformat(), "price": str(base)},
                {"timestamp": previous_close.replace(hour=9, minute=30).isoformat(), "price": str(base * 1.01)},
                {"timestamp": previous_close.replace(hour=10, minute=0).isoformat(), "price": str(base * 1.005)},
            ])
            leader.extend([
                {"timestamp": previous_close.isoformat(), "price": str(1000 + index)},
                {"timestamp": overnight_at.isoformat(), "price": str((1000 + index) * 1.01)},
            ])
        as_of = datetime.combine(trading_days[-1], datetime.min.time(), shanghai).replace(hour=10, minute=1)
        report = cross_market.overnight_absorption(leader, asset, as_of=as_of)
        self.assertEqual(report["state"], "descriptive_only")
        self.assertEqual(report["sampleCount"], 31)
        self.assertGreater(report["meanOpeningGapPercent"], 0)
        self.assertGreater(report["meanGapAbsorptionFraction"], 0)
        self.assertFalse(report["eligibleForTradingSignal"])
        self.assertNotIn("price", report)
        self.assertEqual(report["sessions"][-1]["day"], trading_days[-1].isoformat())

    def test_old_or_future_intervals_cannot_fabricate_overnight_samples(self):
        as_of = datetime.fromisoformat("2026-10-23T10:01:00+08:00")
        leader = [{"timestamp": "2026-10-22T14:59:00+08:00", "price": "100"},
                  {"timestamp": "2026-10-22T16:00:00+08:00", "price": "101"},
                  {"timestamp": "2026-10-23T08:00:00+08:00", "price": "101.5"},
                  {"timestamp": "2026-10-23T09:31:00+08:00", "price": "102"}]
        asset = [{"timestamp": "2026-10-22T14:59:00+08:00", "price": "1"},
                 {"timestamp": "2026-10-23T09:30:00+08:00", "price": "1.01"},
                 {"timestamp": "2026-10-23T10:00:00+08:00", "price": "1.00"},
                 {"timestamp": "2026-10-23T10:02:00+08:00", "price": "9"}]
        report = cross_market.overnight_absorption(leader, asset, as_of=as_of, minimum_sessions=2)
        self.assertEqual(report["state"], "insufficient")
        self.assertEqual(report["sampleCount"], 1)
        self.assertEqual(report["sessions"][0]["assetOpenAt"], "2026-10-23T01:30:00+00:00")
        self.assertNotEqual(report["sessions"][0]["firstThirtyMinuteReturnPercent"], 800)


class TailToNextDayTests(unittest.TestCase):
    def test_tail_research_requires_real_cross_day_endpoints_and_is_not_a_signal(self):
        rows = []
        shanghai = timezone(timedelta(hours=8))
        day = datetime(2026, 7, 1, tzinfo=shanghai).date()
        trading_days = []
        while len(trading_days) < 32:
            if day.weekday() < 5:
                trading_days.append(day)
            day += timedelta(days=1)
        for index, session_day in enumerate(trading_days):
            base = 1 + index / 100
            stamp = datetime.combine(session_day, datetime.min.time(), shanghai)
            rows.extend([
                {"timestamp": stamp.replace(hour=14, minute=0).isoformat(), "price": str(base)},
                {"timestamp": stamp.replace(hour=14, minute=59).isoformat(), "price": str(base * 1.01)},
                {"timestamp": stamp.replace(hour=9, minute=30).isoformat(), "price": str(base * 1.005)},
                {"timestamp": stamp.replace(hour=10, minute=0).isoformat(), "price": str(base * 1.007)},
            ])
        as_of = datetime.combine(trading_days[-1], datetime.min.time(), shanghai).replace(hour=10, minute=1)
        report = cross_market.tail_to_next_day(rows, as_of=as_of)
        self.assertEqual(report["state"], "descriptive_only")
        self.assertEqual(report["sampleCount"], 31)
        self.assertFalse(report["eligibleForTradingSignal"])
        self.assertNotIn("price", report)
        self.assertEqual(report["sessions"][-1]["day"], trading_days[-1].isoformat())

    def test_tail_research_excludes_future_points(self):
        as_of = datetime.fromisoformat("2026-10-23T10:01:00+08:00")
        rows = [
            {"timestamp": "2026-10-22T14:00:00+08:00", "price": "1"},
            {"timestamp": "2026-10-22T14:59:00+08:00", "price": "1.01"},
            {"timestamp": "2026-10-23T09:30:00+08:00", "price": "1.005"},
            {"timestamp": "2026-10-23T10:00:00+08:00", "price": "1.007"},
            {"timestamp": "2026-10-23T10:02:00+08:00", "price": "9"},
        ]
        report = cross_market.tail_to_next_day(rows, as_of=as_of, minimum_sessions=2)
        self.assertEqual(report["sampleCount"], 1)
        self.assertEqual(report["state"], "insufficient")
        self.assertAlmostEqual(report["sessions"][0]["firstThirtyMinuteReturnPercent"], (1.007 / 1.005 - 1) * 100)


class RollingCrossMarketResearchTests(unittest.TestCase):
    def _rows(self, count=32):
        leader, asset = [], []
        shanghai = timezone(timedelta(hours=8))
        day = datetime(2026, 7, 1, tzinfo=shanghai).date()
        added = 0
        while added < count:
            if day.weekday() < 5:
                sign = 1 if added % 2 else -1
                base = 100 + added
                stamp = datetime.combine(day, datetime.min.time(), shanghai)
                leader.extend([
                    {"timestamp": stamp.replace(hour=9, minute=25).isoformat(), "price": str(base)},
                    {"timestamp": stamp.replace(hour=9, minute=30).isoformat(), "price": str(base * (1 + sign * .002))},
                ])
                asset.extend([
                    {"timestamp": stamp.replace(hour=9, minute=30).isoformat(), "price": "1"},
                    {"timestamp": stamp.replace(hour=9, minute=45).isoformat(), "price": str(1 + sign * .001)},
                ])
                added += 1
            day += timedelta(days=1)
        as_of = datetime.combine(day, datetime.min.time(), shanghai).replace(hour=12)
        return leader, asset, as_of

    def test_rolling_windows_keep_short_history_explicitly_insufficient(self):
        leader, asset, as_of = self._rows()
        report = cross_market.rolling_validity(leader, asset, as_of=as_of,
                                                lag_minutes=0, horizon_minutes=15)
        by_window = {row["windowSessions"]: row for row in report["windows"]}
        self.assertEqual(by_window[20]["state"], "descriptive_only")
        self.assertEqual(by_window[20]["sampleCount"], 20)
        self.assertEqual(by_window[60]["state"], "insufficient")
        self.assertEqual(by_window[60]["sampleCount"], 32)
        self.assertFalse(report["eligibleForTradingSignal"])

    def test_time_profile_aggregates_by_day_not_raw_minute_count(self):
        leader, asset, as_of = self._rows()
        report = cross_market.intraday_time_profiles(leader, asset, as_of=as_of,
                                                       lag_minutes=0, horizon_minutes=15,
                                                       minimum_sessions=20)
        self.assertEqual(len(report["profiles"]), 1)
        profile = report["profiles"][0]
        self.assertEqual(profile["sampleCount"], 32)
        self.assertEqual(profile["state"], "descriptive_only")
        self.assertFalse(profile["eligibleForTradingSignal"])
        self.assertNotIn("price", profile)


class CurrencyContextTests(unittest.TestCase):
    def test_sina_fx_parser_requires_fresh_timestamped_bid_ask(self):
        now = datetime.fromisoformat("2026-10-23T10:05:00+08:00")
        body = 'var hq_str_fx_susdcny="10:04:30,7.1000,7.1020,x,x,2026-10-23";'
        rows = market.parse_sina_fx_usdcny(body, now=now)
        self.assertEqual(rows[0]["timestamp"], "2026-10-23T10:04:30+08:00")
        self.assertEqual(rows[0]["price"], "7.1010")
        self.assertIsNone(rows[0]["volume"])
        with self.assertRaisesRegex(ValueError, "stale"):
            market.parse_sina_fx_usdcny(body, now=datetime.fromisoformat("2026-10-23T10:30:00+08:00"))
        with self.assertRaisesRegex(ValueError, "invalid bid/ask"):
            market.parse_sina_fx_usdcny('var hq_str_fx_susdcny="10:04:30,0,7.1020,x,2026-10-23";', now=now)

    def test_fx_collector_archives_context_or_reports_failure_without_promoting_it(self):
        class Database:
            def __init__(self): self.saved = []
            def put_cross_market_minute(self, *args): self.saved.append(args)
        now = datetime.fromisoformat("2026-10-23T10:05:00+08:00")
        database = Database()
        def fresh(*, now):
            return ([{"timestamp": now.isoformat(), "price": "7.101", "volume": None, "iopv": None}], "FX fixture")
        result = workers.collect_fx_once(database, now=now, fetcher=fresh)
        self.assertEqual(result["state"], "ok")
        self.assertEqual(database.saved[0][0], "FX_USDCNY")
        self.assertIn("non-executable", result["detail"])
        failed = workers.collect_fx_once(database, now=now, fetcher=lambda **_: (_ for _ in ()).throw(ValueError("stale")))
        self.assertEqual(failed["state"], "degraded")
        self.assertEqual(len(database.saved), 1)

    def test_currency_context_requires_named_fresh_series_and_never_authorizes_trade(self):
        as_of = datetime.fromisoformat("2026-10-23T10:00:00+08:00")
        fx = [
            {"timestamp": "2026-10-23T09:00:00+08:00", "price": "7.10"},
            {"timestamp": "2026-10-23T10:00:00+08:00", "price": "7.12"},
        ]
        asset = [
            {"timestamp": "2026-10-23T09:00:00+08:00", "price": "1.00"},
            {"timestamp": "2026-10-23T10:00:00+08:00", "price": "1.01"},
        ]
        report = cross_market.currency_context(fx, asset, as_of=as_of,
                                                source="verified FX fixture", pair="USD/CNY")
        self.assertEqual(report["state"], "observed_context")
        self.assertAlmostEqual(report["fxReturnPercent"], (7.12 / 7.10 - 1) * 100, places=4)
        self.assertFalse(report["eligibleForTradingSignal"])
        self.assertNotIn("price", report)
        unverified = cross_market.currency_context(fx, asset, as_of=as_of,
            source="未验证来源", pair="USD/CNY")
        self.assertEqual(unverified["state"], "insufficient_data")
        self.assertIsNone(unverified["source"])
        stale = cross_market.currency_context(fx, asset,
            as_of=datetime.fromisoformat("2026-10-23T11:00:00+08:00"),
            source="verified FX fixture", pair="USD/CNY")
        self.assertEqual(stale["state"], "stale")


class PreRegisteredHypothesisTests(unittest.TestCase):
    def test_registration_is_future_only_and_never_creates_a_trade_record(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).resolve().parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        now = datetime(2026, 10, 24, 1, tzinfo=timezone.utc)
        result = mobile_research.preregister_hypothesis(
            database, "KR_KOSPI", "512480", {"id": "kr-lunch-v1"},
            "2026-10-25T00:00:00+00:00", now=now)
        self.assertEqual(result["state"], "awaiting_future_observations")
        self.assertFalse(result["eligibleForTradingSignal"])
        self.assertEqual(database.get_research(result["registrationId"])["definitionFingerprint"], result["definitionFingerprint"])
        self.assertIsNone(database.get_real("main")["bookJSON"])
        with self.assertRaises(ValueError):
            mobile_research.preregister_hypothesis(database, "KR_KOSPI", "512480", {"id": "bad"},
                                                    "2026-10-23T00:00:00+00:00", now=now)
        del database

    def test_registration_api_is_queryable_and_never_mutates_real_book(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).resolve().parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        before = database.get_real("main")
        body = {"leader": "KR_KOSPI", "asset": "512480", "hypothesis": {"id": "kr-lunch-v1"},
                "notBefore": "2099-01-01T00:00:00+00:00"}
        raw = json.dumps(body).encode()
        handler = object.__new__(app.make_handler(database))
        handler.path = "/v1/research/cross-market/registrations"
        handler.headers = {"Content-Length": str(len(raw))}
        handler.rfile = io.BytesIO(raw)
        responses = []
        handler.reply = lambda status, value: responses.append((status, value))
        handler.do_POST()
        self.assertEqual(responses[0][0], 201)
        registration = responses[0][1]
        self.assertEqual(registration["state"], "awaiting_future_observations")
        self.assertFalse(registration["eligibleForTradingSignal"])
        self.assertEqual(database.get_real("main"), before)

        handler.path = "/v1/research/cross-market/registrations?limit=20"
        responses.clear()
        handler.do_GET()
        self.assertEqual(responses[0][0], 200)
        self.assertEqual(responses[0][1]["registrations"][0]["registrationId"], registration["registrationId"])
        self.assertFalse(responses[0][1]["registrations"][0]["eligibleForTradingSignal"])

        handler.path = "/v1/research/cross-market/registrations/" + registration["registrationId"]
        responses.clear()
        handler.do_GET()
        self.assertEqual(responses[0][0], 200)
        self.assertEqual(responses[0][1]["definitionFingerprint"], registration["definitionFingerprint"])
        self.assertFalse(responses[0][1]["eligibleForTradingSignal"])

        invalid = dict(body, notBefore="2020-01-01T00:00:00+00:00")
        encoded = json.dumps(invalid).encode()
        handler.path = "/v1/research/cross-market/registrations"
        handler.headers = {"Content-Length": str(len(encoded))}
        handler.rfile = io.BytesIO(encoded)
        responses.clear()
        handler.do_POST()
        self.assertEqual(responses[0][0], 400)
        self.assertEqual(database.get_real("main"), before)
        del database

    def test_pre_registered_evaluation_refuses_pre_window_and_stays_research_only(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).resolve().parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        registered = mobile_research.preregister_hypothesis(
            database, "KR_KOSPI", "512480", {"id": "kr-lunch-v1"},
            "2026-10-20T00:00:00+00:00", now=datetime(2026, 10, 1, tzinfo=timezone.utc))
        before = database.get_real("main")
        with self.assertRaises(ValueError):
            mobile_research.evaluate_pre_registered_hypothesis(
                database, registered["registrationId"], "2026-10-19", "2026-10-21", 1,
                now=datetime(2026, 10, 24, tzinfo=timezone.utc))
        result = mobile_research.evaluate_pre_registered_hypothesis(
            database, registered["registrationId"], "2026-10-20", "2026-10-23", 1,
            now=datetime(2026, 10, 24, tzinfo=timezone.utc))
        self.assertEqual(result["registrationId"], registered["registrationId"])
        self.assertEqual(result["evidenceState"], "insufficient_real_archive")
        self.assertFalse(result["eligibleForTradingSignal"])
        self.assertEqual(database.get_real("main"), before)
        self.assertEqual(database.list_research("cross_market_point_in_time_replay"), [])
        del database

    def test_future_replication_requires_two_non_overlapping_passing_windows(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).resolve().parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        registered = mobile_research.preregister_hypothesis(
            database, "KR_KOSPI", "512480", {"id": "kr-lunch-v1"},
            "2026-01-01T00:00:00+00:00", now=datetime(2025, 12, 1, tzinfo=timezone.utc))
        def evaluation(run_id, start, end, state="candidate_requires_replication"):
            database.put_research(run_id, {"kind": "cross_market_point_in_time_replay",
                "request": {"hypothesis": {"registrationId": registered["registrationId"]}},
                "report": {"range": {"start": start, "end": end},
                           "evidenceState": "available", "state": state}})
        evaluation("replay-first", "2026-01-01", "2026-05-31")
        waiting = mobile_research.prospective_replication_status(database, registered["registrationId"])
        self.assertEqual(waiting["state"], "awaiting_future_replication")
        self.assertFalse(waiting["eligibleForTradingSignal"])
        evaluation("replay-overlap", "2026-05-01", "2026-09-30")
        self.assertEqual(mobile_research.prospective_replication_status(database, registered["registrationId"])["state"],
                         "awaiting_future_replication")
        evaluation("replay-second", "2026-06-01", "2026-10-23")
        replicated = mobile_research.prospective_replication_status(database, registered["registrationId"])
        self.assertEqual(replicated["state"], "prospectively_replicated")
        self.assertTrue(replicated["eligibleForTradingSignal"])
        self.assertEqual(len(replicated["passingIndependentEvaluations"]), 2)
        evaluation("replay-failure", "2026-10-24", "2026-10-25", "no_stable_relationship")
        rejected = mobile_research.prospective_replication_status(database, registered["registrationId"])
        self.assertEqual(rejected["state"], "no_stable_relationship")
        self.assertFalse(rejected["eligibleForTradingSignal"])
        self.assertIsNone(database.get_real("main")["bookJSON"])
        del database


class PointInTimeArchiveTests(unittest.TestCase):
    def test_first_observed_snapshots_survive_later_provider_corrections(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        stamp = "2026-10-23T12:50:00+08:00"
        first = "2026-10-23T04:50:30+00:00"
        later = "2026-10-23T05:10:00+00:00"
        database.put_minute("512480", [{"timestamp": stamp, "price": "1.000", "volume": "100", "iopv": None}], first)
        database.put_minute("512480", [{"timestamp": stamp, "price": "1.010", "volume": "120", "iopv": None}], later)
        current_asset = database.get_minute("512480", "2026-10-23")
        observed_asset = database.get_minute_observations("512480", "2026-10-23")
        self.assertEqual(current_asset["rows"][0]["price"], "1.010")
        self.assertEqual(observed_asset["rows"][0]["price"], "1.000")
        self.assertEqual(observed_asset["rows"][0]["availableAt"], first)

        database.put_cross_market_minute("KR_KOSPI", [{"timestamp": stamp, "price": "100"}], "first", first)
        database.put_cross_market_minute("KR_KOSPI", [{"timestamp": stamp, "price": "101"}], "later", later)
        current_leader = database.get_cross_market_minute("KR_KOSPI", "2026-10-23")
        observed_leader = database.get_cross_market_minute_observations("KR_KOSPI", "2026-10-23")
        self.assertEqual(current_leader["rows"][0]["price"], "101")
        self.assertEqual(observed_leader["rows"][0]["price"], "100")
        self.assertEqual(observed_leader["rows"][0]["availableAt"], first)
        self.assertEqual(observed_leader["source"], "first")

    def test_lunch_replay_excludes_points_not_collected_by_freeze_time(self):
        leader = [
            {"timestamp": "2026-10-23T11:30:00+08:00", "price": "100",
             "availableAt": "2026-10-23T11:31:00+08:00"},
            {"timestamp": "2026-10-23T12:50:00+08:00", "price": "101",
             "availableAt": "2026-10-23T12:51:00+08:00"},
        ]
        asset = [
            {"timestamp": "2026-10-23T09:30:00+08:00", "price": "50",
             "availableAt": "2026-10-23T09:31:00+08:00"},
            {"timestamp": "2026-10-23T11:30:00+08:00", "price": "49",
             "availableAt": "2026-10-23T11:31:00+08:00"},
            {"timestamp": "2026-10-23T13:00:00+08:00", "price": "49",
             "availableAt": "2026-10-23T13:01:00+08:00"},
            {"timestamp": "2026-10-23T13:05:00+08:00", "price": "49.5",
             "availableAt": "2026-10-23T13:06:00+08:00"},
        ]
        report = cross_market.replay_lunch_day(leader, asset, day="2026-10-23", source="fixture",
            rule={"leaderShockAtLeast": 0.005, "assetMorningAtMost": 0.0, "expectedDirection": 1})
        self.assertEqual(report["frozenHypothesis"]["state"], "no_hypothesis")
        self.assertEqual(report["frozenHypothesis"]["reason"], "截止时点不满足假设条件或数据不足")
        self.assertTrue(report["confirmedAt5m"], "后验真实价格可晚几分钟被采集，不得反向进入冻结输入")

    def test_legacy_schema_migrates_first_observed_metadata_conservatively(self):
        import sqlite3
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        path = Path(root) / "legacy.sqlite3"
        with sqlite3.connect(path) as db:
            db.executescript("""
                CREATE TABLE minute_archive(code TEXT NOT NULL, stamp TEXT NOT NULL, body TEXT NOT NULL,
                    fetched_at TEXT NOT NULL, PRIMARY KEY(code, stamp));
                CREATE TABLE cross_market_minute(market TEXT NOT NULL, stamp TEXT NOT NULL, body TEXT NOT NULL,
                    source TEXT NOT NULL, fetched_at TEXT NOT NULL, PRIMARY KEY(market, stamp));
            """)
            minute = json.dumps({"timestamp": "2026-10-23T12:50:00+08:00", "price": "1", "volume": None, "iopv": None})
            external = json.dumps({"timestamp": "2026-10-23T12:50:00+08:00", "price": "100", "volume": None, "iopv": None})
            db.execute("INSERT INTO minute_archive VALUES (?,?,?,?)", ("512480", "2026-10-23T12:50:00+08:00", minute, "2026-10-23T13:10:00+08:00"))
            db.execute("INSERT INTO cross_market_minute VALUES (?,?,?,?,?)", ("KR_KOSPI", "2026-10-23T12:50:00+08:00", external, "legacy", "2026-10-23T13:10:00+08:00"))
        database = NextDatabase(path)
        asset = database.get_minute_observations("512480", "2026-10-23")["rows"][0]
        leader = database.get_cross_market_minute_observations("KR_KOSPI", "2026-10-23")["rows"][0]
        self.assertEqual(asset["availableAt"], "2026-10-23T13:10:00+08:00")
        self.assertEqual(leader["availableAt"], "2026-10-23T13:10:00+08:00")


class CrossMarketEvidenceTests(unittest.TestCase):
    def test_research_response_exposes_only_timestamped_non_executable_fx_context(self):
        import shutil
        from zoneinfo import ZoneInfo
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
        cn = ZoneInfo("Asia/Shanghai")
        prior = now - timedelta(minutes=60)
        fx_rows = [
            {"timestamp": prior.astimezone(cn).isoformat(), "price": "7.10"},
            {"timestamp": now.astimezone(cn).isoformat(), "price": "7.12"},
        ]
        asset_rows = [
            {"timestamp": prior.astimezone(cn).isoformat(), "price": "1.00", "volume": None, "iopv": None},
            {"timestamp": now.astimezone(cn).isoformat(), "price": "1.01", "volume": None, "iopv": None},
        ]
        database.put_cross_market_minute("FX_USDCNY", fx_rows, "Sina FX fixture", now.isoformat())
        database.put_minute("512480", asset_rows, now.isoformat())
        report = mobile_research.cross_market_evidence(database, "512480", now=now)
        fx = report["currencyContext"]
        self.assertEqual(fx["state"], "observed_context")
        self.assertEqual(fx["source"], "Sina FX fixture")
        self.assertAlmostEqual(fx["fxReturnPercent"], (7.12 / 7.10 - 1) * 100, places=4)
        self.assertFalse(fx["eligibleForTradingSignal"])
        self.assertNotIn("price", fx)

    def test_older_fetch_cannot_replace_newer_daily_or_minute_evidence(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        def bar(day, close):
            return {"date": day, "open": close, "close": close,
                    "high": close, "low": close, "volume": "1000"}
        newer = "2026-10-23T08:00:00+00:00"
        older = "2026-10-23T07:00:00+00:00"
        database.put_daily("512480", [bar("2026-10-23", "1.20")], newer)
        database.put_daily("512480", [bar("2026-10-23", "9.99"),
                                       bar("2026-10-22", "1.10")], older)
        daily = database.get_daily("512480")
        self.assertEqual(daily["fetchedAt"], newer)
        self.assertEqual([row["close"] for row in daily["bars"]], ["1.10", "1.20"])

        stamp = "2026-10-23T09:31:00+08:00"
        def minute(price, iopv):
            return {"timestamp": stamp, "price": price, "volume": "100", "iopv": iopv}
        database.put_minute("512480", [minute("1.20", "1.21")], newer)
        database.put_minute("512480", [minute("9.99", None)], older)
        database.put_minute("512480", [{"timestamp": "2026-10-23T09:32:00+08:00",
                                        "price": "1.21", "volume": "100", "iopv": None}],
                            "2026-10-23T15:30:00+09:00")
        archived = database.get_minute("512480", "2026-10-23")
        self.assertEqual(archived["rows"][0]["price"], "1.20")
        self.assertEqual(archived["rows"][0]["iopv"], "1.21")
        self.assertEqual(archived["fetchedAt"], newer)

    def test_older_cross_market_fetch_cannot_change_replay_price_or_source(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        row = {"timestamp": "2026-10-23T11:30:00+09:00", "price": "100"}
        database.put_cross_market_minute("KR_KOSPI", [row], "new source", "2026-10-23T08:00:00Z")
        database.put_cross_market_minute("KR_KOSPI", [dict(row, price="999")],
                                         "old source", "2026-10-23T16:00:00+09:00")
        database.put_cross_market_minute("KR_KOSPI", [
            {"timestamp": "2026-10-23T11:31:00+09:00", "price": "101"}],
            "older source", "2026-10-23T15:30:00+09:00")
        archived = database.get_cross_market_minute("KR_KOSPI", "2026-10-23")
        self.assertEqual(archived["rows"][0]["price"], "100")
        self.assertIn("new source", archived["source"])
        self.assertNotIn("old source", archived["source"])
        self.assertEqual(archived["fetchedAt"], "2026-10-23T08:00:00+00:00")

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
            ("CN_SSE", "2026-10-01T10:00:00+08:00", False),
            ("CN_SSE", "2026-10-08T10:00:00+08:00", True),
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
        self.assertEqual(database.list_research("cross_market_point_in_time_replay"), [])

    def test_replay_api_persists_exact_research_evidence_without_touching_real_book(self):
        import shutil
        root = tempfile.mkdtemp(dir=Path(__file__).parent)
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.addCleanup(gc.collect)
        database = NextDatabase(Path(root) / "advisor.sqlite3")
        fetched = "2026-10-23T07:00:00+00:00"
        database.put_cross_market_minute("KR_KOSPI", [
            {"timestamp": "2026-10-23T11:30:00+09:00", "price": "100", "volume": "1000"},
            {"timestamp": "2026-10-23T12:50:00+09:00", "price": "101", "volume": "1200"}],
            "verified fixture", fetched)
        database.put_minute("512480", [
            {"timestamp": "2026-10-23T13:00:00+08:00", "price": "1", "volume": "1000", "iopv": None}], fetched)
        book_before = database.get_real("main")
        handler = object.__new__(app.make_handler(database))
        handler.path = ("/v1/research/cross-market/replay?leader=KR_KOSPI&asset=512480&"
                        "start=2026-10-23&end=2026-10-23&minimumSamples=1")
        responses = []
        handler.reply = lambda status, body: responses.append((status, body))
        handler.do_GET()
        self.assertEqual(responses[0][0], 200)
        summary = responses[0][1]
        self.assertEqual(summary["evidenceSessionCount"], 1)
        self.assertEqual(len(summary["inputFingerprint"]), 64)
        record = database.get_research(summary["replayId"])
        self.assertEqual(record["kind"], "cross_market_point_in_time_replay")
        self.assertEqual(record["snapshotEncoding"], "gzip+base64")
        self.assertNotIn("evidenceSessions", record)
        self.assertEqual(len(summary["reportFingerprint"]), 64)
        self.assertEqual(database.get_real("main"), book_before)

        handler.path = "/v1/research/cross-market/runs/" + summary["replayId"]
        responses.clear()
        handler.do_GET()
        self.assertEqual(responses[0][0], 200)
        self.assertEqual(responses[0][1]["inputFingerprint"], summary["inputFingerprint"])
        evidence = responses[0][1]["evidenceSessions"][0]
        self.assertEqual(evidence["leader"]["source"], "verified fixture")
        self.assertEqual(evidence["leader"]["fetchedAtRange"]["last"], fetched)
        self.assertEqual(evidence["asset"]["rows"][0]["price"], "1")

        handler.path = "/v1/research/cross-market/runs?limit=20"
        responses.clear()
        handler.do_GET()
        self.assertEqual(responses[0][0], 200)
        self.assertEqual(responses[0][1]["runs"][0]["replayId"], summary["replayId"])
        self.assertNotIn("evidenceSessions", responses[0][1]["runs"][0]["summary"])
        handler.path = "/v1/research/cross-market/runs?limit=101"
        responses.clear()
        handler.do_GET()
        self.assertEqual(responses[0][0], 400)

        altered_report = json.loads(json.dumps(record))
        altered_report["report"]["state"] = "forged"
        database.put_research(summary["replayId"], altered_report)
        handler.path = "/v1/research/cross-market/runs/" + summary["replayId"]
        responses.clear()
        handler.do_GET()
        self.assertEqual(responses[0][0], 400)
        self.assertIn("report fingerprint", responses[0][1]["error"])

        encoded = record["evidenceSnapshot"]
        record["evidenceSnapshot"] = ("B" if encoded[0] == "A" else "A") + encoded[1:]
        database.put_research(summary["replayId"], record)
        responses.clear()
        handler.do_GET()
        self.assertEqual(responses[0][0], 400)
        self.assertIn("snapshot", responses[0][1]["error"])

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

    def test_sparse_event_days_cannot_promote_a_spurious_stable_lead(self):
        from zoneinfo import ZoneInfo
        leader, follower = [], []
        zone, day, added = ZoneInfo("Asia/Shanghai"), datetime(2026, 1, 5).date(), 0
        while added < 100:
            if day.weekday() < 5:
                stamp = datetime.combine(day, datetime.min.time(), zone)
                direction = (1 if (added // 5) % 2 else -1) if added % 5 == 0 else 0
                leader.extend([
                    {"timestamp": stamp.replace(hour=9, minute=25).isoformat(), "price": "100"},
                    {"timestamp": stamp.replace(hour=9, minute=30).isoformat(), "price": str(100 * (1 + direction * .01))},
                ])
                follower.extend([
                    {"timestamp": stamp.replace(hour=9, minute=30).isoformat(), "price": "1"},
                    {"timestamp": stamp.replace(hour=9, minute=35).isoformat(), "price": str(1 + direction * .01)},
                ])
                added += 1
            day += timedelta(days=1)
        report = cross_market.analyze_pair(leader, follower, as_of="2026-12-31T00:00:00+08:00",
                                            source="sparse-event fixture", market_status="closed")
        window = next(row for row in report["windows"] if row["lagMinutes"] == 0 and row["horizonMinutes"] == 5)
        self.assertEqual(window["directionalSampleCount"], 20)
        self.assertEqual(window["minimumDirectionalSampleCount"], 30)
        self.assertNotEqual(window["state"], "stable_candidate")
        self.assertEqual(report["state"], "no_stable_relationship")

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
        self.assertEqual(report["rankedHistoricalCandidates"][0]["rank"], 1)
        self.assertEqual(report["rankedHistoricalCandidates"][0]["market"], "KR_KOSPI")
        self.assertFalse(report["eligibleForTradingSignal"],
                         "历史发现不能在缺少预注册未来复现时直接触发交易")
        self.assertEqual(report["validationState"], "requires_pre_registered_future_replication")
        other_sources = [row for row in report["leadSources"] if row["market"] != "KR_KOSPI"]
        self.assertTrue(all(row["bestLagMinutes"] is None for row in other_sources))
        self.assertEqual(report["source"], "verified fixture")
        self.assertEqual(report["currencyContext"]["state"], "insufficient_data")
        self.assertFalse(report["currencyContext"]["eligibleForTradingSignal"])

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
                                   "factor-research", "cross-market-minute", "fx-context"])
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
            divergences = response[0][1]["crossMarket"]["liveDivergences"]
            self.assertEqual(len(divergences), len(workers.CROSS_MARKET_SERIES))
            self.assertTrue(all(item["eligibleForTradingSignal"] is False for item in divergences))
            overnight = response[0][1]["crossMarket"]["overnightAbsorption"]
            self.assertEqual(len(overnight), len(workers.CROSS_MARKET_SERIES))
            self.assertTrue(all(item["eligibleForTradingSignal"] is False for item in overnight))
            self.assertTrue(all("sessions" not in item for item in overnight), "Phone receives compact stats, not raw NAS minute archives")
            rolling = response[0][1]["crossMarket"]["rollingValidity"]
            profiles = response[0][1]["crossMarket"]["timeProfiles"]
            self.assertEqual(len(rolling), len(workers.CROSS_MARKET_SERIES))
            self.assertEqual(len(profiles), len(workers.CROSS_MARKET_SERIES))
            self.assertTrue(all(item["eligibleForTradingSignal"] is False for item in rolling + profiles))
            tail = response[0][1]["crossMarket"]["tailToNextDay"]
            self.assertFalse(tail["eligibleForTradingSignal"])
            self.assertNotIn("sessions", tail)
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
