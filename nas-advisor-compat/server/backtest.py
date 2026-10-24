"""Deterministic, fee-aware historical ETF strategy replay.

Signals are formed using data through the prior session and traded at the next
session's open. The engine never uses future bars or claims exchange queue fills.
"""
from collections import defaultdict
from datetime import date
from decimal import Decimal, InvalidOperation, ROUND_FLOOR
import math
import statistics

from domain import InvalidData, strict_iso_date

FEE = Decimal("0.10")
ZERO = Decimal("0")


def _decimal(value, label, minimum=ZERO):
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError):
        raise InvalidData(f"{label} must be a decimal")
    if not result.is_finite() or (minimum is not None and result < minimum):
        raise InvalidData(f"{label} is outside the allowed range")
    return result


def validate_request(request, bars_by_code):
    if not isinstance(request, dict):
        raise InvalidData("backtest request must be an object")
    strategy = request.get("strategy")
    if strategy not in tuple("ABCDEFGH"):
        raise InvalidData("strategy must be A–H")
    codes = request.get("codes")
    if not isinstance(codes, list) or not 1 <= len(codes) <= 12 or len(set(codes)) != len(codes):
        raise InvalidData("choose 1–12 unique ETFs")
    for code in codes:
        if not isinstance(code, str) or len(code) != 6 or not code.isdigit() or code not in bars_by_code:
            raise InvalidData(f"daily history unavailable for ETF {code}")
    initial_cash = _decimal(request.get("initialCash", "10000"), "initialCash", Decimal("1"))
    monthly = _decimal(request.get("monthlyContribution", "0"), "monthlyContribution")
    fee = _decimal(request.get("fee", FEE), "fee")
    if fee != FEE:
        raise InvalidData("ETF backtest fee is fixed at ¥0.10 per executed side")
    lots = request.get("lotSizes")
    if not isinstance(lots, dict) or any(code not in lots for code in codes):
        raise InvalidData("verified exchange lot size is required for every ETF; no lot size is guessed")
    for code in codes:
        if type(lots[code]) is not int or not 1 <= lots[code] <= 1_000_000:
            raise InvalidData(f"invalid verified lot size for {code}")
    weights = request.get("weights") or {code: 1 / len(codes) for code in codes}
    if not isinstance(weights, dict) or set(weights) != set(codes):
        raise InvalidData("weights must include exactly the selected ETF codes")
    weights = {code: _decimal(weights[code], f"weight {code}") for code in codes}
    if sum(weights.values(), ZERO) <= 0 or abs(sum(weights.values(), ZERO) - 1) > Decimal("0.0001"):
        raise InvalidData("portfolio weights must total 1")
    params = request.get("parameters") or {}
    if not isinstance(params, dict): raise InvalidData("parameters must be an object")
    fast = params.get("fastWindow", 20); slow = params.get("slowWindow", 60)
    if type(fast) is not int or type(slow) is not int or not 2 <= fast < slow <= 250:
        raise InvalidData("custom strategy requires 2 <= fastWindow < slowWindow <= 250")
    normalized = {}
    date_sets = []
    for code in codes:
        rows = bars_by_code[code]
        if not isinstance(rows, list): raise InvalidData(f"invalid daily history for {code}")
        by_day = {}
        for row in rows:
            if not isinstance(row, dict): raise InvalidData(f"invalid daily row for {code}")
            try: day = strict_iso_date(row["date"])
            except (KeyError, ValueError): raise InvalidData(f"invalid daily date for {code}")
            try:
                opened = _decimal(row["open"], "open", Decimal("0.000001"))
                close = _decimal(row["close"], "close", Decimal("0.000001"))
                high = _decimal(row["high"], "high", Decimal("0.000001"))
                low = _decimal(row["low"], "low", Decimal("0.000001"))
            except (KeyError, InvalidData): raise InvalidData(f"invalid OHLC row for {code} on {day}")
            if low > min(opened, close) or high < max(opened, close): raise InvalidData(f"invalid OHLC range for {code} on {day}")
            if day.isoformat() in by_day: raise InvalidData(f"duplicate daily session {day} for {code}")
            by_day[day.isoformat()] = {"date": day.isoformat(), "open": opened, "close": close}
        normalized[code] = by_day
        date_sets.append(set(by_day))
    sessions = sorted(set.intersection(*date_sets))
    if len(sessions) < 2: raise InvalidData("at least two aligned trading sessions are required")
    if len(sessions) > 5000: raise InvalidData("backtest is limited to 5000 aligned sessions per run")
    return strategy, codes, normalized, sessions, initial_cash, monthly, weights, lots, fast, slow


def _sma(closes, window):
    if len(closes) < window: return None
    return sum(closes[-window:], ZERO) / Decimal(window)


def _signals(strategy, codes, history, target, fast_window, slow_window, signal_date, dividends):
    """Choose target weights from completed history only."""
    latest = {code: history[code][-1]["close"] for code in codes if history[code]}
    if strategy == "A": return {code: ZERO for code in codes}
    if strategy == "B": return target
    if strategy in ("C", "D"): return target
    if strategy == "E":
        yields = {}
        for code in codes:
            close = latest[code]
            total = ZERO
            for event in dividends.get(code, []):
                try: event_date = strict_iso_date(event.get("date", ""))
                except (ValueError, TypeError): continue
                if event.get("isEstimated") is False and 0 < (signal_date - event_date).days <= 365:
                    try: total += _decimal(event.get("amountPerShare"), "dividend amount", Decimal("0.0000001"))
                    except InvalidData: continue
            if total > 0 and close > 0: yields[code] = total / close
        selected = sorted(yields, key=yields.get, reverse=True)[:min(3, len(yields))]
        return {code: Decimal(1) / len(selected) if code in selected else ZERO for code in codes} if selected else {code: ZERO for code in codes}
    if strategy == "F":
        eligible = [code for code in codes if (ma := _sma([r["close"] for r in history[code]], 50)) is not None and latest[code] >= ma]
        return {code: Decimal(1) / len(eligible) if code in eligible else ZERO for code in codes} if eligible else {code: ZERO for code in codes}
    if strategy == "G":
        # A transparent, point-in-time multifactor proxy: 20/60/250-session
        # momentum, MA250 trend, and 60-session drawdown. No LLM hindsight.
        scores = {}
        for code in codes:
            closes = [r["close"] for r in history[code]]
            if len(closes) < 250: continue
            ma250 = _sma(closes, 250)
            if latest[code] < ma250: continue
            mom20 = latest[code] / closes[-21] - 1
            mom60 = latest[code] / closes[-61] - 1
            mom250 = latest[code] / closes[-251] - 1 if len(closes) >= 251 else ZERO
            peak = max(closes[-60:]); drawdown = latest[code] / peak - 1
            score = mom20 * Decimal("0.25") + mom60 * Decimal("0.35") + mom250 * Decimal("0.40") + drawdown * Decimal("0.25")
            if score > 0: scores[code] = score
        if not scores: return {code: ZERO for code in codes}
        chosen = sorted(scores, key=scores.get, reverse=True)[:min(3, len(scores))]
        total = sum((scores[code] for code in chosen), ZERO)
        return {code: scores[code] / total if code in chosen else ZERO for code in codes}
    if strategy == "H":
        eligible = [code for code in codes if (_sma([r["close"] for r in history[code]], fast_window) or ZERO) > (_sma([r["close"] for r in history[code]], slow_window) or Decimal("Infinity"))]
        return {code: target[code] if code in eligible else ZERO for code in codes}
    return target


def run_backtest(request, bars_by_code, dividends_by_code=None):
    strategy, codes, rows, sessions, cash, monthly, weights, lots, fast, slow = validate_request(request, bars_by_code)
    dividends_by_code = dividends_by_code or {}
    positions = {code: 0 for code in codes}
    fees_paid = ZERO; fills = []; curve = []; nav = Decimal("1"); max_dd = ZERO; peak_nav = nav; daily_returns = []
    previous_equity = cash
    history = {code: [] for code in codes}
    previous_month = None
    last_rebalance = None
    external_total = ZERO
    for index, day in enumerate(sessions):
        if index == 0:
            # Initial cash is the base capital; strategy entries wait for the
            # first signal and next open to avoid same-bar look-ahead.
            pass
        else:
            current_month = day[:7]
            external = monthly if current_month != previous_month else ZERO
            if external:
                cash += external; external_total += external
            should_rebalance = strategy in ("B", "C", "D") and index == 1
            should_rebalance = should_rebalance or (strategy == "C" and current_month != previous_month)
            should_rebalance = should_rebalance or (strategy == "D" and (last_rebalance is None or index - last_rebalance >= 63))
            should_rebalance = should_rebalance or (strategy in ("E", "F", "G") and current_month != previous_month)
            should_rebalance = should_rebalance or strategy == "H"
            if should_rebalance:
                signal_day = date.fromisoformat(sessions[index - 1])
                target_weights = _signals(strategy, codes, history, weights, fast, slow, signal_day, dividends_by_code)
                open_prices = {code: rows[code][day]["open"] for code in codes}
                equity_open = cash + sum((open_prices[c] * positions[c] for c in codes), ZERO)
                desired = {}
                for code in codes:
                    raw = (equity_open * target_weights[code]) / open_prices[code]
                    lot = lots[code]
                    desired[code] = int((raw / lot).to_integral_value(rounding=ROUND_FLOOR)) * lot
                # Place sells before buys. If the documented rule lot granularity
                # makes targets unaffordable, retain cash rather than borrowing.
                for side in ("sell", "buy"):
                    for code in codes:
                        change = desired[code] - positions[code]
                        if (side == "sell" and change >= 0) or (side == "buy" and change <= 0): continue
                        units = abs(change); gross = open_prices[code] * units
                        fee = FEE
                        if side == "sell":
                            units = min(units, positions[code]); gross = open_prices[code] * units
                            cash += gross - fee; positions[code] -= units
                        elif gross + fee <= cash:
                            cash -= gross + fee; positions[code] += units
                        else:
                            continue
                        fees_paid += fee
                        fills.append({"date": day, "code": code, "side": side, "units": units,
                                      "price": str(open_prices[code]), "fee": str(fee), "gross": str(gross)})
                last_rebalance = index
        closes = {code: rows[code][day]["close"] for code in codes}
        equity = cash + sum((closes[code] * positions[code] for code in codes), ZERO)
        if index > 0:
            flow = monthly if day[:7] != previous_month else ZERO
            base = previous_equity if previous_equity > 0 else ZERO
            daily_factor = (equity - flow) / base if base > 0 else Decimal(1)
            if daily_factor < 0: daily_factor = ZERO
            daily_returns.append(float(daily_factor - 1))
            nav *= daily_factor
            peak_nav = max(peak_nav, nav)
            drawdown = nav / peak_nav - 1 if peak_nav else ZERO
            max_dd = min(max_dd, drawdown)
        curve.append({"date": day, "equity": str(equity), "cash": str(cash),
                      "nav": str(nav), "externalFlow": str(monthly if index > 0 and day[:7] != previous_month else ZERO)})
        previous_equity = equity
        for code in codes: history[code].append(rows[code][day])
        previous_month = day[:7]
    final = Decimal(curve[-1]["equity"])
    years = max(1 / 252, (len(sessions) - 1) / 252)
    annualized = float(nav) ** (1 / years) - 1 if nav > 0 else -1.0
    volatility = statistics.pstdev(daily_returns) * math.sqrt(252) if len(daily_returns) > 1 else 0.0
    sharpe = (statistics.fmean(daily_returns) / statistics.pstdev(daily_returns) * math.sqrt(252)
              if len(daily_returns) > 1 and statistics.pstdev(daily_returns) else 0.0)
    calmar = annualized / abs(float(max_dd)) if max_dd < 0 else 0.0
    return {
        "schemaVersion": 1, "strategy": strategy, "engine": "point-in-time daily OHLC replay",
        "realOrder": False, "queueAccuracy": "daily bars cannot prove order-book queue fills",
        "aiSignalAccuracy": "G historical replay uses a deterministic point-in-time multifactor proxy; it is not a historical DeepSeek forecast",
        "source": "NAS archived Tencent qfqday", "startDate": sessions[0], "endDate": sessions[-1],
        "sessions": len(sessions), "codes": codes, "initialWeights": {code: str(weights[code]) for code in codes},
        "parameters": {"fastWindow": fast, "slowWindow": slow}, "feePerFill": str(FEE),
        "initialCash": str(_decimal(request.get("initialCash", "10000"), "initialCash")),
        "externalContributions": str(external_total), "endingEquity": str(final),
        "totalReturn": str(nav - 1), "annualizedReturn": str(annualized),
        "annualizedVolatility": str(volatility), "sharpe": str(sharpe), "calmar": str(calmar),
        "maxDrawdown": str(max_dd),
        "feesPaid": str(fees_paid), "tradeCount": len(fills),
        "openPositions": {code: positions[code] for code in codes},
        "pendingOrders": [], "curve": curve, "fills": fills,
    }
