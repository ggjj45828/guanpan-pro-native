"""Read-only Tencent quote adapter; no settlement or instrument type inference."""
import json
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from re import finditer
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo


def symbol_for(code):
    if not isinstance(code, str) or len(code) != 6 or not code.isascii() or not code.isdigit():
        raise ValueError("invalid mainland exchange code")
    first = code[0]
    prefix = "sh" if first in "569" else "sz" if first in "0123" else "bj" if first in "48" else None
    if prefix is None:
        raise ValueError("unsupported exchange code")
    return prefix + code


def _in_trading_hours(now):
    """当前北京时间是否在连续交易时段内（含开盘前 09:15 集合竞价）。"""
    if now.weekday() >= 5:
        return False
    minutes = now.hour * 60 + now.minute
    return 9 * 60 + 15 <= minutes <= 15 * 60 + 5


def _quote_is_fresh(stamp, received_at):
    """行情快照是否够新。

    盘中按 60 秒卡实时性；**收盘后不能也按 60 秒卡** —— 腾讯在 15:00 之后照样返回
    当日收盘快照（深市 ETF 还有盘后固定价交易，时间戳会到 16:10+），
    上一版一律要求 60 秒内，导致每天 15:00 之后 quotes 接口把全部记录丢掉、
    返回 502，网页端拿不到报价就把现价按 0 渲染，整页变成「盈亏 -100%」。

    盘中还反向卡一次：行情时间戳比 NAS 时钟快 2 分钟以上的一律当成脏数据丢掉
    （时钟漂移或上游返回了未来时间）；2 分钟以内容忍，避免两地时钟差误杀有效报价。
    """
    cn = ZoneInfo("Asia/Shanghai")
    now = received_at.astimezone(cn)
    quoted = stamp.astimezone(cn)
    if quoted.date() == now.date():
        # 同一天：盘中进行时要求 60 秒内的实时快照，盘后/盘前接受当日快照。
        if not _in_trading_hours(now):
            return True
        delta = (now - quoted).total_seconds()
        return -120 < delta <= 60
    # 不同日期：盘前和周末拿到的是上一个交易日的收盘快照，允许；
    # 但最多 3 天，防止把接口返回的陈旧数据当成有效行情。
    return 0 < (now.date() - quoted.date()).days <= 3


def parse_quotes(body, codes, received_at=None):
    received_at = received_at or datetime.now(timezone.utc)
    if received_at.tzinfo is None:
        raise ValueError("received_at must be timezone aware")
    requested = {symbol_for(code): code for code in codes}
    found = {}
    for match in finditer(r'v_([A-Za-z0-9]+)="([^"]*)"', body):
        symbol, payload = match.groups()
        code = requested.get(symbol.lower())
        if not code:
            continue
        fields = payload.split("~")
        if len(fields) <= 30 or not fields[1]:
            continue
        try:
            price, previous = Decimal(fields[3]), Decimal(fields[4])
            digits = "".join(ch for ch in fields[30] if ch.isdigit())
            if len(digits) not in (12, 14):
                continue
            date_format = "%Y%m%d%H%M%S" if len(digits) == 14 else "%Y%m%d%H%M"
            stamp = datetime.strptime(digits, date_format).replace(tzinfo=ZoneInfo("Asia/Shanghai"))
            provider_type = fields[61].strip().upper() if len(fields) > 61 else None
            iopv = Decimal(fields[78]) if provider_type == "ETF" and len(fields) > 78 and fields[78] else None
        except (InvalidOperation, ValueError, IndexError):
            continue
        if not price.is_finite() or not previous.is_finite() or price <= 0 or previous <= 0:
            continue
        if iopv is not None and (not iopv.is_finite() or iopv <= 0):
            iopv = None
        if not _quote_is_fresh(stamp, received_at):
            continue
        found[code] = {
            "code": code, "name": fields[1], "price": str(price), "previousClose": str(previous),
            "time": stamp.isoformat(), "source": "Tencent qt.gtimg.cn", "providerInstrumentType": provider_type,
            "iopv": str(iopv) if iopv is not None else None,
        }
    return [found[code] for code in codes if code in found]


def fetch_tencent_quotes(codes):
    symbols = [symbol_for(code) for code in codes]
    query = urlencode({"_t": str(int(datetime.now().timestamp()))})
    request = Request("https://qt.gtimg.cn/q=" + ",".join(symbols) + "&" + query, headers={"Accept": "text/plain", "User-Agent": "GuanpanPro/3"})
    with urlopen(request, timeout=8) as response:
        if response.status != 200:
            raise OSError("quote source unavailable")
        raw = response.read(2_000_000)
        try:
            body = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            body = raw.decode("gb18030", errors="strict")
    result = parse_quotes(body, codes)
    if not result:
        raise ValueError("quote response had no validated matching records")
    return result


def parse_daily_bars(body, code, adjustment="qfq"):
    """Validate Tencent daily OHLCV records; never synthesize from minute data."""
    import json
    from datetime import date
    symbol = symbol_for(code)
    start, end = body.find("{"), body.rfind("}")
    if start < 0 or end < start: raise ValueError("invalid daily response")
    node = json.loads(body[start:end + 1]).get("data", {}).get(symbol, {})
    rows = node.get("qfqday" if adjustment == "qfq" else "day")
    # 部分标的（如 159866）腾讯只返回原始日K `day` 而无前复权 `qfqday`，
    # 此时回退到原始序列，否则会误报 "daily bars missing"。
    if adjustment == "qfq" and not isinstance(rows, list):
        rows = node.get("day")
    if not isinstance(rows, list): raise ValueError("daily bars missing")
    result = {}
    for row in rows:
        if not isinstance(row, list) or len(row) < 6: continue
        try:
            business_day = date.fromisoformat(row[0])
            open_, close, high, low, volume = (Decimal(str(v)) for v in row[1:6])
            if (business_day > datetime.now(ZoneInfo("Asia/Shanghai")).date() or
                    any(not n.is_finite() for n in (open_, close, high, low, volume)) or
                    min(open_, close, high, low) <= 0 or volume < 0 or
                    low > min(open_, close) or high < max(open_, close)):
                continue
            result[str(business_day)] = {"date": str(business_day), "open": str(open_),
                "close": str(close), "high": str(high), "low": str(low), "volume": str(volume)}
        except (ValueError, InvalidOperation, TypeError): continue
    if not result: raise ValueError("no validated daily bars")
    return [result[key] for key in sorted(result)]


def fetch_tencent_daily(code, adjustment="qfq"):
    if adjustment not in ("qfq", "raw"):
        raise ValueError("unsupported adjustment")
    symbol = symbol_for(code)
    adjust_code = "qfq" if adjustment == "qfq" else ""
    url = "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get?" + urlencode({"param": f"{symbol},day,,,640,{adjust_code}"})
    request = Request(url, headers={"Accept": "application/json", "User-Agent": "GuanpanProNext/3", "Referer": "https://gu.qq.com/"})
    with urlopen(request, timeout=12) as response:
        if response.status != 200: raise OSError("daily source unavailable")
        raw = response.read(2_000_000).decode("utf-8", errors="strict")
    return parse_daily_bars(raw, code, adjustment)


def em_secid(code):
    """东财 secid：沪市(5/6/9)→1.xxxxxx，深市/北交所(0/1/2/3/4/8)→0.xxxxxx。"""
    if not isinstance(code, str) or len(code) != 6 or not code.isascii() or not code.isdigit():
        raise ValueError("invalid mainland exchange code")
    market = "1" if code[0] in "569" else "0"
    return f"{market}.{code}"


def fetch_eastmoney_quotes(codes):
    """东财实时报价兜底源。腾讯找不到的标的（或腾讯限流）走这里。"""
    secids = []
    for code in codes:
        try: secids.append(em_secid(code))
        except ValueError: continue
    if not secids: return []
    query = urlencode({"fields": "f12,f13,f14,f2,f3,f4,f6,f60,f124",
                      "secids": ",".join(secids), "fltt": "2", "np": "1"})
    request = Request("https://push2.eastmoney.com/api/qt/ulist.np/get?" + query,
                      headers={"Referer": "https://quote.eastmoney.com/",
                               "User-Agent": "Mozilla/5.0 (compatible; GuanpanAdvisor/3)"})
    with urlopen(request, timeout=8) as response:
        if response.status != 200: raise OSError("eastmoney quote source unavailable")
        data = json.loads(response.read(2_000_000).decode("utf-8", "replace"))
    diff = (data.get("data") or {}).get("diff") or []
    found = {}
    for row in diff:
        code = str(row.get("f12") or "")
        price, prev, pct = row.get("f2"), row.get("f60"), row.get("f3")
        if not code or price in (None, 0) or prev in (None, 0): continue
        try:
            price_value, prev_value = Decimal(str(price)), Decimal(str(prev))
            event_at = datetime.fromtimestamp(int(row["f124"]), timezone.utc)
            if (not price_value.is_finite() or not prev_value.is_finite() or
                    price_value <= 0 or prev_value <= 0 or
                    not _quote_is_fresh(event_at, datetime.now(timezone.utc))):
                continue
            price, prev = str(price_value), str(prev_value)
        except (InvalidOperation, ValueError, TypeError, KeyError, OverflowError, OSError): continue
        found[code] = {
            "code": code, "name": row.get("f14") or code,
            "price": price, "previousClose": prev,
            "time": event_at.isoformat(),
            "source": "Eastmoney quote", "providerInstrumentType": None, "iopv": None,
            "changePercent": (float(pct) if isinstance(pct, (int, float)) else None),
        }
    return [found[c] for c in codes if c in found]


def fetch_eastmoney_daily(code, adjustment="qfq"):
    """东财历史日 K 兜底源（前复权 qfq / 原始 raw）。"""
    if adjustment not in ("qfq", "raw"):
        raise ValueError("unsupported adjustment")
    secid = em_secid(code)
    query = urlencode({"secid": secid, "fields1": "f1,f2,f3,f4,f5,f6",
                      "fields2": "f51,f52,f53,f54,f55,f56,f57,f58",
                      "klt": "101", "fqt": ("1" if adjustment == "qfq" else "0"),
                      "end": "20500101", "lmt": "640"})
    request = Request("https://push2his.eastmoney.com/api/qt/stock/kline/get?" + query,
                      headers={"Referer": "https://quote.eastmoney.com/",
                               "User-Agent": "Mozilla/5.0 (compatible; GuanpanAdvisor/3)"})
    with urlopen(request, timeout=12) as response:
        if response.status != 200: raise OSError("eastmoney daily source unavailable")
        data = json.loads(response.read(2_000_000).decode("utf-8", "replace"))
    klines = (data.get("data") or {}).get("klines") or []
    result = {}
    for line in klines:
        parts = line.split(",")
        if len(parts) < 7: continue
        try:
            day = parts[0][:10]
            o, c, h, l, v = (Decimal(p) for p in parts[1:6])
        except (InvalidOperation, ValueError): continue
        if not (c > 0 and o > 0 and h > 0 and l > 0) or l > min(o, c) or h < max(o, c) or v < 0: continue
        if day > datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat(): continue
        result[day] = {"date": day, "open": str(o), "close": str(c),
                       "high": str(h), "low": str(l), "volume": str(v)}
    if not result: raise ValueError("no validated daily bars")
    return [result[d] for d in sorted(result)]


def fetch_quotes(codes):
    """统一报价入口：腾讯优先，腾讯缺失/失败的代码自动用东财兜底。"""
    try:
        tencent = fetch_tencent_quotes(codes)
    except Exception:
        tencent = []
    by_code = {q["code"]: q for q in tencent}
    missing = [c for c in codes if c not in by_code]
    if missing:
        try:
            for q in fetch_eastmoney_quotes(missing):
                by_code.setdefault(q["code"], q)
        except Exception:
            pass
    return [by_code[c] for c in codes if c in by_code]


def fetch_daily(code, adjustment="qfq"):
    """统一日 K 入口：腾讯优先，失败回退东财。"""
    try:
        return fetch_tencent_daily(code, adjustment)
    except Exception:
        return fetch_eastmoney_daily(code, adjustment)


def parse_eastmoney_dividends(body, code):
    """Return implemented mainland cash distributions only; proposals are excluded."""
    import json
    rows = json.loads(body).get("result", {}).get("data") or []
    found = {}
    for row in rows:
        if not isinstance(row, dict) or "实施" not in str(row.get("ASSIGN_PROGRESS", "")):
            continue
        raw_date = row.get("EX_DIVIDEND_DATE")
        date = str(raw_date or "")[:10]
        try: per_share = Decimal(str(row.get("PRETAX_BONUS_RMB"))) / Decimal(10)
        except (InvalidOperation, ValueError): continue
        if len(date) == 10 and per_share.is_finite() and per_share > 0:
            found[date] = {"code": code, "date": date, "amountPerShare": str(per_share), "isEstimated": False}
    return list(found.values())


def fetch_eastmoney_dividends(code):
    from urllib.parse import urlencode
    from urllib.request import Request, urlopen
    params = {"reportName": "RPT_SHAREBONUS_DET", "columns": "SECURITY_CODE,PRETAX_BONUS_RMB,EX_DIVIDEND_DATE,ASSIGN_PROGRESS,REPORT_DATE",
        "filter": f'(SECURITY_CODE="{code}")', "pageSize": "30", "pageNumber": "1", "sortColumns": "EX_DIVIDEND_DATE", "sortTypes": "-1"}
    url = "https://datacenter-web.eastmoney.com/api/data/v1/get?" + urlencode(params)
    request = Request(url, headers={"Referer": "https://data.eastmoney.com/", "User-Agent": "GuanpanProNext/3"})
    with urlopen(request, timeout=12) as response:
        if response.status != 200: raise OSError("dividend source unavailable")
        return parse_eastmoney_dividends(response.read(2_000_000).decode("utf-8"), code)


def parse_eastmoney_fund_dividends(body, code):
    """Parse implemented fund/ETF cash distributions from Eastmoney F10 history."""
    from html.parser import HTMLParser
    import re

    class Tables(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.tables = []; self.table = None; self.row = None; self.cell = None
        def handle_starttag(self, tag, attrs):
            if tag == "table": self.table = []
            elif tag == "tr" and self.table is not None: self.row = []
            elif tag in ("td", "th") and self.row is not None: self.cell = []
        def handle_data(self, data):
            if self.cell is not None: self.cell.append(data)
        def handle_endtag(self, tag):
            if tag in ("td", "th") and self.cell is not None:
                self.row.append(" ".join(self.cell).strip()); self.cell = None
            elif tag == "tr" and self.row is not None:
                self.table.append(self.row); self.row = None
            elif tag == "table" and self.table is not None:
                self.tables.append(self.table); self.table = None

    if not (len(code) == 6 and code.isascii() and code.isdigit()): raise ValueError("invalid fund code")
    parser = Tables(); parser.feed(body)
    found = {}
    for table in parser.tables:
        header = " ".join(cell for row in table[:3] for cell in row)
        if "权益登记日" not in header or "除息日" not in header or "每10份分红" not in header: continue
        for row in table:
            text = " ".join(row)
            dates = re.findall(r"(?<!\d)(20\d{2}-\d{2}-\d{2})(?!\d)", text)
            amount_match = re.search(r"每\s*10\s*份\s*派现金\s*([0-9]+(?:\.[0-9]+)?)\s*元", text)
            if len(dates) < 2 or amount_match is None: continue
            try:
                record_date, ex_date = dates[0], dates[1]
                pay_date = dates[2] if len(dates) > 2 else None
                per_share = Decimal(amount_match.group(1)) / Decimal(10)
                for day in (record_date, ex_date, pay_date):
                    if day: date.fromisoformat(day)
            except (ValueError, InvalidOperation): continue
            if not per_share.is_finite() or per_share <= 0: continue
            found[ex_date] = {"code": code, "date": ex_date, "amountPerShare": format(per_share.normalize(), "f"),
                "isEstimated": False, "recordDate": record_date, "payDate": pay_date}
    return sorted(found.values(), key=lambda item: item["date"])


def fetch_eastmoney_fund_dividends(code):
    """Fetch a fund's server-rendered F10 distribution history from Eastmoney."""
    from urllib.request import Request, urlopen
    if not (len(code) == 6 and code.isascii() and code.isdigit()): raise ValueError("invalid fund code")
    url = f"https://fundf10.eastmoney.com/fhsp_{code}.html"
    request = Request(url, headers={"Accept": "text/html", "User-Agent": "Mozilla/5.0 (compatible; GuanpanProNext/3)",
        "Referer": f"https://fund.eastmoney.com/{code}.html"})
    with urlopen(request, timeout=12) as response:
        if response.status != 200: raise OSError("fund dividend source unavailable")
        raw = response.read(3_000_000)
        charset = response.headers.get_content_charset() or "utf-8"
        body = raw.decode(charset, errors="replace")
    events = parse_eastmoney_fund_dividends(body, code)
    # A valid F10 page with an empty history is distinct from a block/error page.
    if "分红送配详情" not in body: raise ValueError("fund dividend page did not contain a validated history section")
    return events


def infer_adjustment_dividends(code, adjusted, raw):
    """Detect qfq/raw factor steps. Estimated only; never reported as confirmed cash."""
    if len(adjusted) < 60 or len(raw) < 60: return []
    raw_by_day = {row["date"]: Decimal(row["close"]) for row in raw}
    factors = []
    for row in adjusted:
        close = Decimal(row["close"]); raw_close = raw_by_day.get(row["date"])
        if close > 0 and raw_close and raw_close > 0: factors.append((row["date"], raw_close / close, close))
    candidates = []
    for before, after in zip(factors, factors[1:]):
        move = after[1] / before[1] - 1
        amount = (before[1] - after[1]) * after[2]
        # 两条硬约束，缺一条就会把「份额折算 / 数据源复权口径切换」当成分红：
        # 1. 复权因子跳变不能超过 -20%（真实分红很少超过 5%）；
        # 2. 单次每份分红不能超过前收盘价的 20%。
        if not (Decimal("-0.20") < move < Decimal("-0.0025")):
            continue
        if amount < Decimal("0.003") or amount > before[2] * Decimal("0.20"):
            continue
        candidates.append((after[0], amount))
    merged = []
    for day, amount in candidates:
        if merged and (date.fromisoformat(day) - date.fromisoformat(merged[-1][0])).days <= 8:
            merged[-1] = (day, merged[-1][1] + amount)
        else: merged.append((day, amount))
    return [{"code": code, "date": day, "amountPerShare": format(amount.normalize(), "f"), "isEstimated": True} for day, amount in merged]


# 分红识别规则版本。改动推断/过滤规则时 +1，NAS 上旧缓存会自动失效重抓。
# v2: 不分红的 ETF 不再用复权因子跳变硬推；单次每份分红不得超过前收 20%。
DIVIDEND_RULES_VERSION = 2


def fetch_dividend_events(code, daily_fetcher=fetch_daily, stock_fetcher=fetch_eastmoney_dividends,
                          fund_fetcher=fetch_eastmoney_fund_dividends):
    official = []; inferred = []; succeeded = False
    # Eastmoney's RPT_SHAREBONUS_DET is an A-share corporate-action feed. It is
    # not an ETF distribution feed: querying it for fund codes can mislabel an
    # unrelated share-bonus record as ETF cash income.
    is_etf_code = len(code) == 6 and code.isdigit() and code.startswith(("15", "16", "18", "50", "51", "52", "56", "58", "59"))
    if is_etf_code:
        fund_answered = False
        try:
            official = fund_fetcher(code); fund_answered = True; succeeded = True
        except Exception: pass
        # 三种情况要分开处理：
        # - 官方接口返回了记录   → 用价差补齐历史（历史更完整）；
        # - 官方接口成功但为空   → **不推断**。不分红的 ETF（半导体设备 560780 这类）
        #   在 qfq/raw 上同样会因为数据源复权口径或份额折算产生跳变，硬推会得出
        #   「每份分 2.6 元」，乘上价格就是 300% 股息率，直接把评分带偏；
        # - 官方接口报错（不知道有没有）→ 仍用价差推断兜底，总比完全没数据好。
        if official or not fund_answered:
            try:
                adjusted = daily_fetcher(code, "qfq"); raw = daily_fetcher(code, "raw")
                inferred = infer_adjustment_dividends(code, adjusted, raw); succeeded = True
            except Exception: pass
    else:
        try:
            official = stock_fetcher(code); succeeded = True
        except Exception: pass
        # 个股保留价差推断（用来补缺失的除权记录），但同样受上面的硬约束保护。
        try:
            adjusted = daily_fetcher(code, "qfq"); raw = daily_fetcher(code, "raw")
            inferred = infer_adjustment_dividends(code, adjusted, raw); succeeded = True
        except Exception: pass
    if not succeeded: raise OSError("all dividend data sources unavailable")
    values = {(item["code"], item["date"]): item for item in inferred}
    for item in official: values[(item["code"], item["date"])] = item
    return sorted(values.values(), key=lambda item: item["date"])

# --- 指数行情（东财为主，新浪兜底） -------------------------------------------------
# 旧版只用新浪 hq.sinajs.cn，部分环境/接口被限导致「指数没数据线、曲线为空」。
# 现在以东财 push2 实时报价 + push2his 日 K 为首选数据源，覆盖 A 股与全球主要指数；
# 东财不可用时退回到新浪。每条指数用东财 secid 标识，kline 也走东财 secid，
# 保证「指数报价」与「指数曲线」同源、都有数据。
INDEX_SOURCES = [
    ("上证指数", "1.000001"),
    ("深证成指", "0.399001"),
    ("创业板指", "0.399006"),
    ("沪深300", "1.000300"),
    ("纳斯达克", "100.NDX"),
    ("日经225", "100.N225"),
    ("韩国KOSPI", "100.KS11"),
    ("恒生指数", "100.HSI"),
    ("标普500", "100.SPX"),
    ("道琼斯", "100.DJIA"),
]
NAME_TO_SECID = {name: secid for name, secid in INDEX_SOURCES}
# 兜底：新浪符号（接口形态见 _sina_parse_index_fields）。
SINA_INDEX_SYMBOLS = [
    ("s_sh000001", "上证指数", "sh000001"),
    ("b_NKY", "日经225", "b_NKY"),
    ("b_KOSPI", "韩国KOSPI", "b_KOSPI"),
    ("rt_hkHSI", "恒生指数", "rt_hkHSI"),
]


def _fetch_eastmoney_indices():
    secids = [s for _, s in INDEX_SOURCES]
    query = urlencode({"fields": "f12,f13,f14,f2,f3,f4,f6,f60",
                      "secids": ",".join(secids), "fltt": "2", "np": "1"})
    request = Request("https://push2.eastmoney.com/api/qt/ulist.np/get?" + query,
                      headers={"Referer": "https://quote.eastmoney.com/",
                               "User-Agent": "Mozilla/5.0 (compatible; GuanpanAdvisor/3)"})
    with urlopen(request, timeout=8) as response:
        if response.status != 200:
            raise OSError("eastmoney index source unavailable")
        data = json.loads(response.read(2_000_000).decode("utf-8", "replace"))
    diff = (data.get("data") or {}).get("diff") or []
    found = {}
    for row in diff:
        name = row.get("f14") or ""
        secid = NAME_TO_SECID.get(name)
        if not secid: continue
        price, prev, pct = row.get("f2"), row.get("f60"), row.get("f3")
        if price in (None, 0) or prev in (None, 0): continue
        found[secid] = {
            "symbol": secid, "name": name,
            "price": float(price), "changePercent": float(pct or 0),
            "previousClose": float(prev),
            "observedAt": datetime.now(timezone.utc).isoformat(),
            "kline": secid,
        }
    return [found[s] for _, s in INDEX_SOURCES if s in found]


def _sina_parse_index_fields(symbol, fields):
    def num(index):
        try:
            return float(fields[index])
        except (IndexError, ValueError):
            return None

    price = pct = close = stamp = None
    if symbol.startswith("gb_"):
        price, pct = num(1), num(2)
        stamp = fields[3] if len(fields) > 3 else None
    elif symbol.startswith("rt_hk"):
        close, price, pct = num(3), num(6), num(8)
        stamp = f"{fields[16]} {fields[17]}" if len(fields) > 17 else None
    elif symbol.startswith("b_"):
        price, pct = num(1), num(3)
        stamp = f"{fields[6]} {fields[5]}" if len(fields) > 6 else None
    else:
        price, pct = num(1), num(3)
    if not price or price <= 0:
        return None
    name = {item[0]: item[1] for item in SINA_INDEX_SYMBOLS}.get(symbol, symbol)
    return {"symbol": symbol, "name": name, "price": price,
            "changePercent": pct if pct is not None else 0.0,
            "previousClose": close, "observedAt": stamp, "kline": symbol}


def _fetch_sina_indices():
    query = ",".join(symbol for symbol, _, _ in SINA_INDEX_SYMBOLS)
    request = Request("https://hq.sinajs.cn/list=" + query,
                      headers={"Referer": "https://finance.sina.com.cn/",
                               "User-Agent": "Mozilla/5.0 (compatible; GuanpanAdvisor/1)"})
    with urlopen(request, timeout=8) as response:
        body = response.read().decode("utf-8", "replace")
    found = {}
    for line in body.splitlines():
        start = line.find('hq_str_'); eq = line.find('="')
        if start < 0 or eq < 0: continue
        symbol = line[start + 7:eq]; end = line.rfind('";')
        if end <= eq: continue
        fields = line[eq + 2:end].split(',')
        quote = _sina_parse_index_fields(symbol, fields)
        if quote: found[symbol] = quote
    result = [found[s] for s, _, _ in SINA_INDEX_SYMBOLS if s in found]
    if not result: raise ValueError("sina index source returned no parsable data")
    return result


def fetch_indices():
    """指数报价：东财优先，东财不可用退回新浪。"""
    try:
        quotes = _fetch_eastmoney_indices()
        if quotes: return quotes
    except Exception:
        pass
    return _fetch_sina_indices()


def _valid_kline_symbol(symbol):
    if not isinstance(symbol, str) or not symbol or len(symbol) > 24:
        return False
    return all(ch.isalnum() or ch in "._$: " for ch in symbol)


def fetch_kline(symbol, datalen=320):
    """指数日 K 历史曲线。东财 secid（含点号）走东财历史 K 线；其余符号走新浪兜底。"""
    if not _valid_kline_symbol(symbol):
        raise ValueError("invalid kline symbol")
    if "." in symbol and symbol[0].isdigit():
        return _fetch_eastmoney_kline(symbol, datalen)
    return _fetch_sina_kline(symbol, datalen)


def _fetch_eastmoney_kline(secid, datalen=320):
    """东财历史日 K：klines 每行 "日期,开,收,高,低,量,额,涨%"（fqt=1 前复权）。"""
    query = urlencode({"secid": secid, "fields1": "f1,f2,f3,f4,f5,f6",
                      "fields2": "f51,f52,f53,f54,f55,f56,f57,f58",
                      "klt": "101", "fqt": "1", "end": "20500101", "lmt": str(datalen)})
    request = Request("https://push2his.eastmoney.com/api/qt/stock/kline/get?" + query,
                      headers={"Referer": "https://quote.eastmoney.com/",
                               "User-Agent": "Mozilla/5.0 (compatible; GuanpanAdvisor/3)"})
    with urlopen(request, timeout=10) as response:
        if response.status != 200:
            raise OSError("eastmoney kline source unavailable")
        data = json.loads(response.read(4_000_000).decode("utf-8", "replace"))
    klines = (data.get("data") or {}).get("klines") or []
    bars = []
    for line in klines:
        parts = line.split(",")
        if len(parts) < 7: continue
        try:
            day = parts[0][:10]
            o, c, h, l, v = (Decimal(p) for p in parts[1:6])
        except (InvalidOperation, ValueError):
            continue
        if not (c > 0 and o > 0 and h > 0 and l > 0) or l > min(o, c) or h < max(o, c) or v < 0: continue
        bars.append({"date": day, "open": str(o), "high": str(h), "low": str(l),
                     "close": str(c), "volume": str(v)})
    if len(bars) < 2:
        raise ValueError("kline source returned no usable bars")
    return sorted(bars, key=lambda b: b["date"])


def _fetch_sina_kline(symbol, datalen=320):
    """新浪日 K 历史（旧接口，作为东财不可达时的兜底）。"""
    url = ("https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/"
           "CN_MarketDataService.getKLineData?" + urlencode(
               {"symbol": symbol, "scale": 240, "ma": "no", "datalen": datalen}))
    request = Request(url, headers={"Referer": "https://finance.sina.com.cn/",
                                    "User-Agent": "Mozilla/5.0 (compatible; GuanpanAdvisor/1)"})
    with urlopen(request, timeout=10) as response:
        body = response.read(4_000_000).decode("utf-8", "replace")
    try:
        rows = json.loads(body)
    except json.JSONDecodeError:
        raise ValueError("kline source returned undecodable data")
    if not isinstance(rows, list):
        raise ValueError("kline source returned unexpected shape")
    bars = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        try:
            day = str(row.get("day", ""))[:10]
            o, h, l, c = (float(row[k]) for k in ("open", "high", "low", "close"))
            v = float(row.get("volume") or 0)
        except (KeyError, ValueError, TypeError):
            continue
        if not (c > 0 and o > 0 and h > 0 and l > 0):
            continue
        bars.append({"date": day, "open": str(o), "high": str(h), "low": str(l),
                     "close": str(c), "volume": str(v)})
    if len(bars) < 2:
        raise ValueError("kline source returned no usable bars")
    return sorted(bars, key=lambda b: b["date"])

