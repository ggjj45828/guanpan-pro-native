"""NAS 长期分时统计的验收测试。

这些数字会直接进做 T / 网格的价格计算，所以必须逐项对得上：
VWAP 按成交量加权、振幅按 (high-low)/mid、往返次数按穿越中位价、
支撑压力取窗口内的分位、完整度按 240 分钟/日、新鲜度隔夜不算过期。
"""
import unittest
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import research

SH = timezone(timedelta(hours=8))


def minutes_for_day(day, prices, volumes=None, start="09:31"):
    """造一天的分钟行。prices 每个元素一分钟。"""
    base = datetime.fromisoformat(f"{day}T{start}:00").replace(tzinfo=SH)
    rows = []
    for index, price in enumerate(prices):
        volume = (volumes[index] if volumes else 1000 + index)
        rows.append({"timestamp": (base + timedelta(minutes=index)).isoformat(),
                     "price": str(price), "volume": str(volume), "iopv": None})
    return rows


class MinuteStatsTests(unittest.TestCase):
    def test_vwap_is_volume_weighted(self):
        rows = minutes_for_day("2026-10-20", ["1.000", "2.000"], volumes=[900, 100])
        stats = research.minute_stats(rows, now=datetime(2026, 10, 20, 15, 10, tzinfo=SH))
        day = research.day_metrics(research.group_by_day(rows)["2026-10-20"])
        # (1.0*900 + 2.0*100) / 1000 = 1.1
        self.assertAlmostEqual(float(day["vwap"]), 1.1, places=6)
        self.assertEqual(stats["days"], 1)

    def test_amplitude_and_round_trips(self):
        prices = ["1.00", "1.10", "0.95", "1.05", "0.98", "1.02"]
        rows = minutes_for_day("2026-10-20", prices)
        day = research.day_metrics(research.group_by_day(rows)["2026-10-20"])
        high, low = Decimal("1.10"), Decimal("0.95")
        mid = (high + low) / 2
        self.assertAlmostEqual(day["amplitudePercent"], float((high - low) / mid * 100), places=4)
        self.assertGreaterEqual(day["roundTrips"], 3, "价格来回穿越中位价，往返次数应大于 3")

    def test_completeness_uses_240_minutes(self):
        rows = minutes_for_day("2026-10-20", ["1.00"] * 120)
        day = research.day_metrics(research.group_by_day(rows)["2026-10-20"])
        self.assertEqual(day["expectedMinutes"], 240)
        self.assertAlmostEqual(day["completeness"], 0.5, places=4)

    def test_window_stats_support_resistance_and_coverage(self):
        days = []
        for index in range(6):
            day = f"2026-10-{20 + index:02d}"
            # 每天区间不同，便于验证支撑=最小 low、压力=最大 high
            low = Decimal("0.900") + Decimal(index) / 1000
            high = Decimal("1.100") + Decimal(index) / 1000
            days.extend(minutes_for_day(day, [str(low), str(high), str((low + high) / 2)]))
        stats = research.minute_stats(days, now=datetime(2026, 10, 26, 15, 10, tzinfo=SH))
        w5 = stats["windows"]["5"]
        self.assertEqual(w5["daysUsed"], 5)
        self.assertAlmostEqual(w5["dayCoverage"], 1.0, places=4)
        self.assertLess(Decimal(w5["support"]), Decimal(w5["resistance"]))
        self.assertLessEqual(Decimal(w5["supportP10"]), Decimal(w5["resistanceP90"]))
        self.assertEqual(stats["windows"]["120"]["daysUsed"], 6, "窗口不足时如实返回实际天数")
        self.assertAlmostEqual(stats["windows"]["120"]["dayCoverage"], round(6 / 120, 4), places=4)
        self.assertAlmostEqual(w5["volumeCoverage"], 1.0, places=4)
        self.assertGreater(w5["vwapHighDeviationMedian"], 0)
        self.assertLess(w5["vwapLowDeviationMedian"], 0)

    def test_missing_volume_is_not_counted_as_observed(self):
        rows = minutes_for_day("2026-10-20", ["1.00", "1.01", "0.99"])
        rows[1].pop("volume")
        stats = research.minute_stats(rows, now=datetime(2026, 10, 20, 15, 10, tzinfo=SH))
        self.assertAlmostEqual(stats["quality"]["volumeCoverage"], 2 / 3, places=4)

    def test_close_vs_vwap_sign(self):
        rows = minutes_for_day("2026-10-20", ["1.00"] * 10 + ["1.20"] * 2, volumes=[100] * 12)
        stats = research.minute_stats(rows, now=datetime(2026, 10, 20, 15, 10, tzinfo=SH))
        self.assertGreater(stats["windows"]["1"]["closeVsVwapPercent"], 0)

    def test_freshness_today_vs_stale(self):
        rows = minutes_for_day("2026-10-20", ["1.00"] * 5)
        fresh = research.freshness(rows, now=datetime(2026, 10, 20, 9, 40, tzinfo=SH))
        self.assertTrue(fresh["isToday"])
        self.assertFalse(fresh["stale"])
        # 隔一天以上才算过期；隔夜（开盘前最后一条是昨天收盘）不算。
        overnight = research.freshness(rows, now=datetime(2026, 10, 21, 9, 10, tzinfo=SH))
        self.assertFalse(overnight["stale"])
        stale = research.freshness(rows, now=datetime(2026, 10, 25, 9, 10, tzinfo=SH))
        self.assertTrue(stale["stale"])

    def test_quality_gate_for_long_term(self):
        rows = []
        start = datetime(2026, 1, 1)
        for index in range(60):
            day = (start + timedelta(days=index)).date().isoformat()
            rows.extend(minutes_for_day(day, ["1.00"] * 240))
        stats = research.minute_stats(rows, now=datetime(2026, 3, 10, 15, 10, tzinfo=SH))
        self.assertTrue(stats["quality"]["enoughForLongTerm"])

        short_stats = research.minute_stats(rows[: 5 * 240], now=datetime(2026, 1, 6, 15, 10, tzinfo=SH))
        self.assertFalse(short_stats["quality"]["enoughForLongTerm"], "少于 60 个有效日不能支撑长期精确建议")

        thin = minutes_for_day("2026-10-20", ["1.00"] * 10)
        thin_stats = research.minute_stats(thin, now=datetime(2026, 10, 20, 15, 10, tzinfo=SH))
        self.assertFalse(thin_stats["quality"]["enoughForLongTerm"], "只有 1 天、10 分钟不能算够算长期结论")

    def test_empty_input_is_honest(self):
        stats = research.minute_stats([], now=datetime(2026, 10, 20, 15, 10, tzinfo=SH))
        self.assertEqual(stats["days"], 0)
        self.assertEqual(stats["windows"], {})
        self.assertTrue(stats["freshness"]["stale"])
        self.assertFalse(stats["quality"]["enoughForLongTerm"])


if __name__ == "__main__":
    unittest.main()
