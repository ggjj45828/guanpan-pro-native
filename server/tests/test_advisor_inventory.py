import json
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

from advisor import COCOA_EPOCH, analyze_position, inventory, ledger_available_units
from domain import NextDatabase


class AdvisorInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.db = NextDatabase(Path(self.temp.name) / "book.sqlite")

    def tearDown(self):
        self.temp.cleanup()

    def test_empty_book(self):
        result = inventory(self.db)
        self.assertEqual(result["positions"], [])
        self.assertFalse(result["realOrder"])
        self.assertEqual(result["bookRevision"], 0)

    def test_available_units_uses_only_same_day_buy_fills(self):
        now = datetime.fromisoformat("2026-10-22T01:00:00+00:00")
        today_fill = (now - COCOA_EPOCH).total_seconds()
        prior_fill = (now - timedelta(days=1) - COCOA_EPOCH).total_seconds()
        book = {"fills": [{"code": "159941", "side": "buy", "units": 300, "date": today_fill},
                          {"code": "159941", "side": "buy", "units": 200, "date": prior_fill}]}
        self.assertEqual(ledger_available_units(book, {"code": "159941", "units": 1000}, now), 700)

    def test_oscillating_minute_history_yields_only_conditional_grid_plan(self):
        import math
        rows = []
        day = datetime(2026, 9, 1).date()
        accepted = 0
        while accepted < 60:
            if day.weekday() < 5:
                base = datetime.fromisoformat(day.isoformat() + "T09:30:00+08:00")
                session = []
                for i in range(120):
                    price = 1 + 0.01 * math.sin(i * math.pi / 12)
                    session.append((base + timedelta(minutes=i), price))
                afternoon = datetime.fromisoformat(day.isoformat() + "T13:00:00+08:00")
                for i in range(80):
                    price = 1 + 0.01 * math.sin((i + 120) * math.pi / 12)
                    session.append((afternoon + timedelta(minutes=i), price))
                rows.extend({"timestamp": stamp.isoformat(), "price": str(price), "volume": None, "iopv": None}
                            for stamp, price in session)
                accepted += 1
            day += timedelta(days=1)
        now = datetime.fromisoformat("2026-12-01T10:00:00+08:00")
        quote = {"price": "1", "time": now.isoformat(), "source": "test"}
        rules = {"verified": True, "source": "verified test rule", "verifiedAt": now.isoformat(),
                 "settlement": "t1", "lotSize": 100, "feePerTrade": "0.10", "sellableUnits": 1000}
        report = analyze_position({"code": "159941", "name": "ETF", "units": 1000}, quote, rows, rules, 1000, now)
        self.assertEqual(report["decision"], "网格候选")
        self.assertIsNotNone(report["plan"])
        self.assertEqual(report["plan"]["unitsPerSide"] % 100, 0)
        self.assertGreater(float(report["plan"]["estimatedNetIfBothFill"]), 0)
        self.assertFalse(report["realOrder"])

    def test_short_history_never_produces_trade_numbers(self):
        now = datetime.now().astimezone()
        quote = {"price": "1", "time": now.isoformat(), "source": "test"}
        report = analyze_position({"code": "159941", "name": "ETF", "units": 100}, quote, [], None, 1000, now)
        self.assertEqual(report["decision"], "暂不交易")
        self.assertIsNone(report["plan"])

    def test_real_positions_only_and_no_book_write(self):
        book = {"schemaVersion": 1, "id": "00000000-0000-4000-8000-000000000001", "cash": 1000,
                "positions": [{"code": "159941", "name": "ETF", "units": 100, "bookCost": 120},
                              {"code": "563020", "name": "empty", "units": 0, "bookCost": 0}],
                "fills": [], "history": []}
        self.db.put_real("main", 0, json.dumps(book))
        start = datetime.fromisoformat("2026-10-19T09:30:00+08:00")
        rows = []
        for minute in range(200):
            # Keep all points within the two continuous trading sessions.
            stamp = start + timedelta(minutes=minute + (90 if minute > 120 else 0))
            rows.append({"timestamp": stamp.isoformat(), "price": "1.2", "volume": None, "iopv": None})
        self.db.put_minute("159941", rows, "2026-10-19T08:00:00+00:00")
        before = self.db.get_real("main")
        result = inventory(self.db)
        self.assertEqual(self.db.get_real("main"), before)
        self.assertEqual(len(result["positions"]), 1)
        p = result["positions"][0]
        self.assertEqual((p["days"], p["completeDays"]), (1, 1))
        self.assertEqual(p["decision"], "暂不交易")
        self.assertFalse(result["realOrder"])

