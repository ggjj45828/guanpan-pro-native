import json
import os
import unittest
from unittest.mock import patch
from datetime import date, timedelta
from io import BytesIO
from urllib.error import HTTPError

from ai import AIProviderError, generate_g_twin_plan


class Response:
    status = 200
    def __init__(self, body): self.body = body
    def __enter__(self): return self
    def __exit__(self, *_): return None
    def read(self, _limit): return json.dumps({"choices": [{"message": {"content": json.dumps(self.body)}}]}).encode()


def context():
    start = date(2025, 1, 1)
    bars = []
    for index in range(390):
        day = start + timedelta(days=index)
        if day.weekday() >= 5: continue
        bars.append({"date": day.isoformat(), "open": "1.0", "high": "1.1", "low": "0.9", "close": "1.0", "volume": "100"})
    as_of = bars[-1]["date"]
    return {"asOf": as_of, "codes": ["159941"], "dailyBars": {"159941": bars}, "cash": "1000",
            "positions": {"159941": 0}, "currentWeights": {"159941": "0"}, "baseWeights": {"159941": "0.8"}}


class DeepSeekGPlanTests(unittest.TestCase):
    def body(self, ctx, weight="0.7"):
        return {"asOf": ctx["asOf"], "targetWeights": {"159941": weight}, "summary": "按趋势和回撤调整虚拟仓位",
                "risks": ["日 K 无法反映盘口深度"], "invalidators": ["历史数据过期"]}

    def test_validated_plan_is_provider_attributed_and_non_trading(self):
        ctx = context()
        result = generate_g_twin_plan(ctx, api_key="fake", profile={"base": "https://unit.test", "model": "test"},
            opener=lambda *_a, **_kw: Response(self.body(ctx)))
        self.assertEqual(result["provider"], "DeepSeek")
        self.assertEqual(result["targetWeights"]["159941"], "0.7")
        self.assertFalse(result["realOrder"])

    def test_missing_key_or_bad_model_weights_do_not_create_a_decision(self):
        ctx = context()
        with self.assertRaises(AIProviderError): generate_g_twin_plan(ctx, api_key="")
        with self.assertRaises(AIProviderError):
            generate_g_twin_plan(ctx, api_key="fake", profile={"base": "https://unit.test", "model": "test"},
                opener=lambda *_a, **_kw: Response(self.body(ctx, "1.1")))

    def test_rejects_unaligned_or_malformed_historical_bars_before_network(self):
        ctx = context()
        ctx["dailyBars"]["159941"][-1]["date"] = "2020-01-01"
        with self.assertRaises(ValueError):
            generate_g_twin_plan(ctx, api_key="fake", profile={"base": "https://unit.test", "model": "test"},
                                 opener=lambda *_a, **_kw: self.fail("must reject before API call"))

    def test_twelve_security_payload_uses_compact_real_daily_history(self):
        ctx = context()
        codes = [f"1599{i:02d}" for i in range(12)]
        ctx["codes"] = codes
        ctx["dailyBars"] = {code: list(ctx["dailyBars"]["159941"]) for code in codes}
        ctx["positions"] = {code: 0 for code in codes}
        ctx["currentWeights"] = {code: "0" for code in codes}
        ctx["baseWeights"] = {code: "0.05" for code in codes}
        body = {"asOf": ctx["asOf"], "targetWeights": {code: "0.05" for code in codes},
                "summary": "分散配置", "risks": ["无法观察盘口"], "invalidators": ["历史行情过期"]}
        captured = {}
        def opener(request, **_kwargs):
            captured["payload"] = json.loads(request.data)
            return Response(body)
        result = generate_g_twin_plan(ctx, api_key="fake", profile={"base": "https://unit.test", "model": "test"}, opener=opener)
        packed = captured["payload"]["messages"][1]["content"]
        model_ctx = json.loads(packed)["context"]
        self.assertLess(len(packed.encode()), 220_000)
        self.assertEqual(len(model_ctx["dailyBars"][codes[0]]), 250)
        self.assertEqual(len(model_ctx["dailyBars"][codes[0]][0]), 6)
        self.assertEqual(len(result["targetWeights"]), 12)


if __name__ == "__main__": unittest.main()


class DeepSeekEmptyContentTests(unittest.TestCase):
    """V4 默认思考模式下，思考过程会先吃掉 token，正文可能为空。

    这时必须给出能定位的原因（思考过程长度、finish_reason），
    而不是一句看不出所以然的"返回空内容"——那样会被误判成网络故障（HTTP 503）。
    """

    def test_returns_content_when_present(self):
        from ai import _message_content
        self.assertEqual(_message_content({"choices": [{"message": {"content": "你好"}}]}), "你好")

    def test_empty_content_reports_reasoning_and_finish_reason(self):
        from ai import AIProviderError, _message_content
        payload = {"choices": [{"message": {"content": "", "reasoning_content": "先想一想"},
                                "finish_reason": "length"}]}
        with self.assertRaises(AIProviderError) as caught:
            _message_content(payload)
        text = str(caught.exception)
        self.assertIn("思考过程", text)
        self.assertIn("finish_reason=length", text)
        self.assertIn("max_tokens", text)

    def test_malformed_choices_are_rejected(self):
        from ai import AIProviderError, _message_content
        for bad in ({"choices": []}, {}, {"choices": [{"message": None}]}):
            with self.assertRaises(AIProviderError):
                _message_content(bad)


class DeepSeekThinkingModeTests(unittest.TestCase):
    """V4 默认思考模式会吃掉正文额度，结构化任务必须能关掉它。

    实测：一次单证券分析写出近万字思考过程，4096 额度被吃光、正文为空
    （finish_reason=length），从外面看就是"AI 分析失败"。
    """

    def _ok(self):
        class R:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): return None
            def read(self, _limit): return json.dumps({"choices": [{"message": {"content": "ok"}}]}).encode()
        return R()

    def test_thinking_disabled_by_default(self):
        from ai import _thinking_disabled
        with patch.dict("os.environ", {}, clear=False):
            os.environ.pop("GUANPAN_AI_THINKING", None)
            self.assertTrue(_thinking_disabled())
        with patch.dict("os.environ", {"GUANPAN_AI_THINKING": "on"}):
            self.assertFalse(_thinking_disabled())

    def test_request_carries_thinking_flag_and_falls_back_on_400(self):
        """服务端不认 thinking 参数（400）时要自动去掉重试，不能因此失败。"""
        from urllib.error import HTTPError
        from ai import _chat_request
        seen = []
        def opener(request, **_kw):
            body = json.loads(request.data.decode())
            seen.append("thinking" in body)
            if "thinking" in body:
                raise HTTPError("https://api.deepseek.com/chat/completions", 400, "Bad Request", None, None)
            return self._ok()
        payload = {"model": "deepseek-v4-flash", "stream": False, "max_tokens": 8,
                   "messages": [{"role": "user", "content": "hi"}], "thinking": {"type": "disabled"}}
        result = _chat_request({"base": "https://api.deepseek.com"}, payload, "k", 5, opener)
        self.assertEqual(seen, [True, False], "应先带 thinking 请求，400 后去掉重试")
        self.assertEqual(result["choices"][0]["message"]["content"], "ok")

    def test_non_400_errors_are_not_retried(self):
        from urllib.error import HTTPError
        from ai import _chat_request
        calls = []
        def opener(_request, **_kw):
            calls.append(1)
            raise HTTPError("https://api.deepseek.com/chat/completions", 401, "Unauthorized", None, None)
        payload = {"model": "m", "stream": False, "max_tokens": 8, "messages": [], "thinking": {"type": "disabled"}}
        with self.assertRaises(HTTPError):
            _chat_request({"base": "https://api.deepseek.com"}, payload, "k", 5, opener)
        self.assertEqual(len(calls), 1, "401 不该重试")
