import unittest
from datetime import date, timedelta
from decimal import Decimal

from backtest import run_backtest
from domain import InvalidData


def fixture_bars(count=280):
    rows = {"159941": [], "563020": []}
    day = date(2025, 1, 1)
    index = 0
    while index < count:
        if day.weekday() < 5:
            for code, trend in (("159941", Decimal("1.002")), ("563020", Decimal("0.999"))):
                close = Decimal("1") * (trend ** index)
                previous = Decimal("1") * (trend ** max(0, index - 1))
                opened = previous if index else close
                rows[code].append({"date": day.isoformat(), "open": str(opened), "close": str(close),
                                   "high": str(max(opened, close) + Decimal("0.01")),
                                   "low": str(min(opened, close) - Decimal("0.01")), "volume": "100000"})
            index += 1
        day += timedelta(days=1)
    return rows


class BacktestTests(unittest.TestCase):
    def setUp(self):
        self.bars = fixture_bars()
        self.base = {"strategy": "B", "codes": ["159941", "563020"], "initialCash": "10020",
                     "monthlyContribution": "100", "weights": {"159941": "0.5", "563020": "0.5"},
                     "lotSizes": {"159941": 100, "563020": 100}}

    def test_buy_hold_replay_uses_real_ohlc_and_fixed_fee(self):
        result = run_backtest(self.base, self.bars)
        self.assertEqual(result["engine"], "point-in-time daily OHLC replay")
        self.assertFalse(result["realOrder"])
        self.assertEqual(result["feePerFill"], "0.10")
        self.assertEqual(result["sessions"], 280)
        self.assertEqual(result["tradeCount"], 2)
        self.assertEqual(result["feesPaid"], "0.20")
        self.assertEqual(len(result["curve"]), 280)
        self.assertGreater(Decimal(result["totalReturn"]), 0)
        self.assertLessEqual(Decimal(result["maxDrawdown"]), 0)

    def test_cash_control_and_monthly_target_have_distinct_curves(self):
        no_action = dict(self.base, strategy="A")
        target = dict(self.base, strategy="C")
        a = run_backtest(no_action, self.bars)
        c = run_backtest(target, self.bars)
        self.assertEqual(a["tradeCount"], 0)
        self.assertEqual(Decimal(a["totalReturn"]), Decimal(0))
        self.assertGreater(c["tradeCount"], 2)
        self.assertGreater(Decimal(c["externalContributions"]), 0)

    def test_multifactor_discloses_it_is_not_historical_llm_output(self):
        result = run_backtest(dict(self.base, strategy="G"), self.bars)
        self.assertIn("not a historical DeepSeek forecast", result["aiSignalAccuracy"])
        self.assertEqual(result["queueAccuracy"], "daily bars cannot prove order-book queue fills")

    def test_custom_parameters_are_bounded_and_verified_lots_required(self):
        request = dict(self.base, strategy="H", parameters={"fastWindow": 5, "slowWindow": 20})
        result = run_backtest(request, self.bars)
        self.assertEqual(result["strategy"], "H")
        self.assertEqual(result["parameters"], {"fastWindow": 5, "slowWindow": 20})
        request["lotSizes"] = {}
        with self.assertRaises(InvalidData): run_backtest(request, self.bars)
        request["lotSizes"] = {"159941": 100, "563020": 100}
        request["parameters"] = {"fastWindow": 20, "slowWindow": 5}
        with self.assertRaises(InvalidData): run_backtest(request, self.bars)

    def test_dividend_strategy_only_uses_confirmed_past_events(self):
        result = run_backtest(dict(self.base, strategy="E"), self.bars,
            {"159941": [{"date": "2025-02-01", "amountPerShare": "0.05", "isEstimated": False}],
             "563020": [{"date": "2025-02-01", "amountPerShare": "0.50", "isEstimated": True}]})
        self.assertEqual(result["strategy"], "E")
        self.assertGreaterEqual(result["tradeCount"], 0)

    def test_misaligned_short_or_corrupt_history_is_rejected(self):
        short = {"159941": self.bars["159941"][:1], "563020": self.bars["563020"][:1]}
        with self.assertRaises(InvalidData): run_backtest(self.base, short)
        corrupt = {key: list(value) for key, value in self.bars.items()}
        corrupt["159941"][-1] = dict(corrupt["159941"][-1], low="9")
        with self.assertRaises(InvalidData): run_backtest(self.base, corrupt)
        duplicate = {key: list(value) for key, value in self.bars.items()}
        duplicate["159941"].append(dict(duplicate["159941"][0]))
        with self.assertRaises(InvalidData): run_backtest(self.base, duplicate)


if __name__ == "__main__": unittest.main()
