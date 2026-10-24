"""离线验证东财兜底数据源的解析逻辑（用真实接口返回样本，mock urlopen）。

不依赖外网：样本来自 2026-10-21 对 Eastmoney 接口的真实抓取，
确保 ulist/qt/stock/kline 三种形态都能正确解析。
"""
import json
import unittest
from unittest.mock import patch

import market


# ---- 样本（2026-10-21 真实 Eastmoney 返回，精炼） ----
QUOTE_FIXTURE = json.dumps({"rc": 0, "data": {"total": 2, "diff": [
    {"f2": 4.185, "f3": -0.83, "f4": -0.035, "f6": 5943185942.0,
     "f12": "510300", "f13": 1, "f14": "沪深300ETF华泰柏瑞", "f60": 4.220},
    {"f2": 2.713, "f3": -1.56, "f4": -0.043, "f6": 10410389037.534,
     "f12": "159915", "f13": 0, "f14": "创业板ETF易方达", "f60": 2.757},
]}}).encode()

INDEX_FIXTURE = json.dumps({"rc": 0, "data": {"total": 10, "diff": [
    {"f2": 3713.03, "f3": -0.6, "f4": -22.34, "f12": "000001", "f13": 1, "f14": "上证指数", "f60": 3735.37},
    {"f2": 11704.35, "f3": -0.82, "f12": "399001", "f13": 0, "f14": "深证成指", "f60": 11785.66},
    {"f2": 2694.71, "f3": -1.62, "f12": "399006", "f13": 0, "f14": "创业板指", "f60": 2739.03},
    {"f2": 4111.93, "f3": -0.97, "f12": "000300", "f13": 1, "f14": "沪深300", "f60": 4152.16},
    {"f2": 26537.55, "f3": 0.43, "f12": "NDX", "f13": 100, "f14": "纳斯达克", "f60": 26424.82},
    {"f2": 64621.24, "f3": 0.85, "f12": "N225", "f13": 100, "f14": "日经225", "f60": 64075.42},
    {"f2": 5735.66, "f3": 3.29, "f12": "KS11", "f13": 100, "f14": "韩国KOSPI", "f60": 5552.74},
    {"f2": 23651.87, "f3": -0.9, "f12": "HSI", "f13": 100, "f14": "恒生指数", "f60": 23867.74},
    {"f2": 7715.08, "f3": 0.03, "f12": "SPX", "f13": 100, "f14": "标普500", "f60": 7712.74},
    {"f2": 52433.65, "f3": -0.12, "f12": "DJIA", "f13": 100, "f14": "道琼斯", "f60": 52495.88},
]}}).encode()

KLINE_FIXTURE = json.dumps({"rc": 0, "data": {"code": "000001", "name": "上证指数",
    "klines": [
        "2026-10-20,3718.44,3735.37,3740.07,3702.44,408693062,699969753798.90,1.01",
        "2026-10-21,3740.57,3713.03,3743.08,3703.12,378286389,642751560386.80,1.07",
    ]}}).encode()


class _FakeResp:
    def __init__(self, body, status=200):
        self._body = body
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, n=-1):
        return self._body if n == -1 else self._body[:n]


def _router(request, *_a, **_k):
    url = request.full_url
    if "ulist.np/get" in url:
        if "510300" in url or "159915" in url:
            return _FakeResp(QUOTE_FIXTURE)
        return _FakeResp(INDEX_FIXTURE)
    if "kline/get" in url:
        return _FakeResp(KLINE_FIXTURE)
    raise OSError("unexpected url in test: " + url)


class MarketSourcesTest(unittest.TestCase):
    def test_em_secid_mapping(self):
        self.assertEqual(market.em_secid("510300"), "1.510300")
        self.assertEqual(market.em_secid("159915"), "0.159915")
        self.assertEqual(market.em_secid("830799"), "0.830799")  # 北交所走 0

    def test_fetch_eastmoney_quotes(self):
        with patch("market.urlopen", _router):
            rows = market.fetch_eastmoney_quotes(["510300", "159915"])
        self.assertEqual(len(rows), 2)
        by = {r["code"]: r for r in rows}
        self.assertEqual(by["510300"]["name"], "沪深300ETF华泰柏瑞")
        self.assertEqual(by["510300"]["price"], "4.185")
        self.assertEqual(by["510300"]["previousClose"], "4.22")  # Decimal 规范化尾零，数值等价
        self.assertEqual(by["510300"]["source"], "Eastmoney quote")
        self.assertEqual(by["510300"]["timeQuality"], "receipt_only")

    def test_fetch_quotes_falls_back_to_eastmoney(self):
        # 模拟腾讯彻底不可用
        def boom(*a, **k):
            raise ValueError("tencent down")
        with patch("market.fetch_tencent_quotes", boom), patch("market.urlopen", _router):
            rows = market.fetch_quotes(["510300", "159915"])
        self.assertEqual({r["code"] for r in rows}, {"510300", "159915"})

    def test_fetch_eastmoney_indices(self):
        with patch("market.urlopen", _router):
            rows = market._fetch_eastmoney_indices()
        self.assertEqual(len(rows), 10, rows)
        by = {r["symbol"]: r for r in rows}
        self.assertEqual(by["1.000001"]["name"], "上证指数")
        self.assertEqual(by["1.000001"]["kline"], "1.000001")  # kline 用东财 secid
        self.assertAlmostEqual(by["1.000001"]["price"], 3713.03)
        self.assertAlmostEqual(by["100.N225"]["changePercent"], 0.85)
        # 所有指数都带 kline（曲线有源）
        self.assertTrue(all(r.get("kline") for r in rows))

    def test_fetch_indices_prefers_eastmoney(self):
        with patch("market.urlopen", _router):
            rows = market.fetch_indices()
        self.assertEqual(len(rows), 10)

    def test_fetch_eastmoney_kline(self):
        with patch("market.urlopen", _router):
            bars = market._fetch_eastmoney_kline("1.000001", datalen=320)
        self.assertEqual(len(bars), 2)
        self.assertEqual(bars[0]["date"], "2026-10-20")
        self.assertEqual(bars[0]["open"], "3718.44")
        self.assertEqual(bars[0]["close"], "3735.37")
        self.assertEqual(bars[0]["high"], "3740.07")
        self.assertEqual(bars[0]["low"], "3702.44")

    def test_fetch_kline_dispatches_by_secid(self):
        with patch("market.urlopen", _router):
            bars = market.fetch_kline("1.000001", datalen=320)  # 含点号 → 东财
        self.assertEqual(len(bars), 2)

    def test_fetch_daily_falls_back_to_eastmoney(self):
        def boom(*a, **k):
            raise OSError("tencent daily down")
        with patch("market.fetch_tencent_daily", boom), patch("market.urlopen", _router):
            bars = market.fetch_daily("000001", "qfq")
        self.assertEqual(len(bars), 2)


if __name__ == "__main__":
    unittest.main()
