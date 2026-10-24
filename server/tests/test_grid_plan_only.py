"""网格必须是「档位计划」，不能是「模拟账户」。

这组测试锁住三件事：
1. build()/summary() 不再产出虚拟本金、虚拟权益、模拟盈亏这些字段；
2. tick() 只记「价格触及了哪一档」，绝不改现金、绝不成交、绝不改持仓；
3. 档数、每档份额、单档往返净收益都是算出来的，不是写死的常数。
"""
import unittest
from decimal import Decimal

import grid


def book_with(cash="100000", positions=None):
    return {"cash": Decimal(cash), "positions": positions or []}


def position(code, units, cost):
    return {"code": code, "units": units, "bookCost": Decimal(cost) * Decimal(units)}


def bars(high, low, days=25):
    """构造一段日 K，只用到 high/low（算日内振幅）。"""
    return [{"date": f"2026-09-{i + 1:02d}", "high": Decimal(high), "low": Decimal(low),
             "close": Decimal((Decimal(high) + Decimal(low)) / 2)} for i in range(days)]


QUOTES = {"512480": {"price": Decimal("0.800"), "previousClose": Decimal("0.800")}}


class GridPlanOnlyTests(unittest.TestCase):
    def build_state(self, units=40000, cash="100000"):
        b = book_with(cash, [position("512480", units, "0.790")])
        return grid.build(b, QUOTES, {"512480": bars("0.820", "0.780")})

    def test_state_has_no_virtual_account_fields(self):
        state = self.build_state()
        for key in ("cash", "equity", "startEquity", "fills", "daily"):
            self.assertNotIn(key, state, f"网格状态不该再有虚拟账户字段 {key}")
        self.assertIn("deployableCash", state)
        self.assertIn("plans", state)
        self.assertEqual(state["version"], 2)

    def test_summary_has_no_pnl(self):
        state = self.build_state()
        summary = grid.summary(state, QUOTES)
        for key in ("equity", "startEquity", "pnl", "pnlPercent", "days", "buys", "sells"):
            self.assertNotIn(key, summary, f"网格口径不该再有模拟盈亏字段 {key}")
        self.assertEqual(summary["mode"], "plan-only")
        self.assertEqual(summary["holdingsCovered"], 1)

    def test_tick_only_records_touch_and_never_moves_cash_or_units(self):
        state = self.build_state()
        cash_before = state["deployableCash"]
        units_before = state["plans"]["512480"]["units"]
        plan = state["plans"]["512480"]
        # 价格跌穿第一买档，应当只记一条触达
        crashed = {"512480": {"price": plan["anchor"] * (1 - plan["step"]) * Decimal("0.999"),
                              "previousClose": plan["anchor"]}}
        state, touches = grid.tick(state, crashed)
        self.assertEqual(len(touches), 1)
        self.assertEqual(touches[0]["side"], "buy")
        self.assertEqual(state["deployableCash"], cash_before)
        self.assertEqual(state["plans"]["512480"]["units"], units_before)
        self.assertNotIn("buys", state["plans"]["512480"])
        self.assertEqual(len(state["touches"]), 1)

    def test_levels_and_shares_are_derived_not_fixed(self):
        small = self.build_state(units=6000)     # 约 ¥4800 市值：档数少
        large = self.build_state(units=200000)   # 约 ¥16 万市值：档数多
        small_plan = small["plans"]["512480"]
        large_plan = large["plans"]["512480"]
        self.assertLessEqual(small_plan["levels"], large_plan["levels"])
        self.assertNotEqual(small_plan["sharesPerRung"], large_plan["sharesPerRung"])
        self.assertGreaterEqual(large_plan["levels"], 1)
        self.assertLessEqual(large_plan["levels"], grid.LEVELS)

    def test_net_per_rung_uses_fee(self):
        state = self.build_state()
        plan = state["plans"]["512480"]
        metrics = grid.plan_metrics(plan)
        anchor = Decimal(plan["anchor"])
        gross = anchor * Decimal(plan["step"]) * Decimal(plan["sharesPerRung"])
        self.assertAlmostEqual(float(metrics["grossPerRung"]), float(gross.quantize(Decimal("0.01"))), places=2)
        self.assertAlmostEqual(float(metrics["netPerRung"]),
                               float((gross - Decimal("0.20")).quantize(Decimal("0.01"))), places=2,
                               msg="单档往返净收益必须扣掉两次手续费")

    def test_skips_positions_below_one_lot(self):
        b = book_with("100000", [position("512480", 100, "0.800")])
        state = grid.build(b, QUOTES, {"512480": bars("0.820", "0.780")})
        self.assertEqual(state["plans"], {})
        self.assertEqual(len(state["skipped"]), 1)
        self.assertIn("不足一手", state["skipped"][0]["reason"])


if __name__ == "__main__":
    unittest.main()
