"""Self-test for server-side build_analysis_context + analyze_user_context schema.

Verifies the web path (only `code` sent) assembles a context that passes the
strict 8-field schema check in analyze_user_context, without hitting the network.
"""
import json
import io
from ai import build_analysis_context, analyze_user_context


class _MockResponse:
    def __init__(self, payload):
        self.status = 200
        self._payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, n=-1):
        return self._payload if n == -1 else self._payload[:n]


def _mock_opener(request, timeout=None):
    # The request body proves build_analysis_context produced a valid context.
    body = json.loads(request.data.decode())
    assert "messages" in body and body["messages"], "missing messages"
    user_content = body["messages"][-1]["content"]
    return _MockResponse({"choices": [{"message": {"content": "MOCK-ANALYSIS:" + user_content[:20]}}]})


def main():
    # Book with the previously-rejected `acquiredAt` field (iOS 3.4.1 feature).
    book = {
        "cash": "1234.56",
        "positions": [
            {"code": "515180", "name": "国泰中证A500ETF", "units": 1000, "bookCost": "1032.10", "acquiredAt": "2026-06-01"},
            {"code": "159866", "name": "东财创业板ETF", "units": 500, "bookCost": "560.00", "acquiredAt": "2026-05-12"},
            {"code": "510300", "name": "沪深300ETF", "units": 0, "bookCost": "0", "acquiredAt": "2026-01-01"},
        ],
        "fills": [
            {"code": "515180", "date": "2026-06-01", "side": "buy", "units": 1000, "price": "1.0321", "fee": "0.10"},
        ],
        "goal": {"years": 5, "monthlyBudget": "500", "concentrationLimit": "0.4", "targetWeights": {"515180": "0.5"}},
    }
    # Quotes may be empty (NAS offline / proxy) — context must still validate.
    quotes = {
        "515180": {"code": "515180", "name": "国泰中证A500ETF", "price": "1.05", "previousClose": "1.04", "iopv": "1.051"},
    }
    # daily_bars / dividends empty to simulate "no archive yet".
    bars, dividends = [
        {"date": "2026-10-20", "open": "1.03", "high": "1.06", "low": "1.02", "close": "1.05", "volume": "123456"},
        {"date": "2026-10-21", "open": "1.05", "high": "1.07", "low": "1.04", "close": "1.06", "volume": "234567"},
    ], [{"date": "2026-06-10", "amountPerShare": "0.012"}]

    ctx = build_analysis_context(book, "515180", quotes, bars, dividends)

    # 1) Top-level keys exactly match the schema.
    assert set(ctx) == {"security", "dailyBars", "position", "allPositions", "cash", "recentFills", "goal", "dividends"}, ctx.keys()
    # 2) allPositions excludes zero-unit holding (515180 + 159866 only).
    assert [p["code"] for p in ctx["allPositions"]] == ["515180", "159866"], ctx["allPositions"]
    # 3) goal shape.
    assert ctx["goal"]["years"] == 5 and ctx["goal"]["concentrationLimit"] == "0.4"
    # 4) The position for the analyzed code is present.
    assert ctx["position"]["units"] == 1000
    # 5) recentFills filtered to the code.
    assert ctx["recentFills"][0]["units"] == 1000

    # Now push through the real validator (schema check runs before network).
    result = analyze_user_context(ctx, api_key="dummy", opener=_mock_opener)
    assert result["code"] == "515180"
    assert result["content"].startswith("MOCK-ANALYSIS:")

    # 6) Empty-quotes path (offline) must still validate.
    ctx2 = build_analysis_context(book, "159866", {}, [], [])
    assert ctx2["security"] == {"code": "159866"}, ctx2["security"]
    assert ctx2["position"]["units"] == 500
    result2 = analyze_user_context(ctx2, api_key="dummy", opener=_mock_opener)
    assert result2["code"] == "159866"

    print(json.dumps({
        "ok": True,
        "allPositions": [p["code"] for p in ctx["allPositions"]],
        "security": ctx["security"],
        "goal": ctx["goal"],
        "contextBytes": len(json.dumps(ctx, ensure_ascii=False).encode("utf-8")),
        "mockAnalysisPrefix": result["content"][:20],
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
