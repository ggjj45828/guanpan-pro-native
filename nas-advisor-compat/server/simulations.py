"""Revisioned virtual accounts kept entirely separate from the real ledger."""
from copy import deepcopy
from decimal import Decimal, InvalidOperation

from domain import InvalidData

STRATEGIES = tuple("ABCDEFGH")
ZERO = Decimal("0")


def _money(value, field, positive=False):
    try:
        amount = Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError):
        raise InvalidData(f"{field} must be a decimal")
    if not amount.is_finite() or (amount <= 0 if positive else amount < 0):
        raise InvalidData(f"{field} is outside the allowed range")
    return amount


def _validate_config(request):
    if not isinstance(request, dict) or set(request) != {"initialCash", "codes", "lotSizes", "feesPerFill", "weights"}:
        raise InvalidData("simulation start requires initialCash, codes, verified lotSizes, feesPerFill and weights")
    codes = request["codes"]
    if not isinstance(codes, list) or not 1 <= len(codes) <= 12 or len(set(codes)) != len(codes):
        raise InvalidData("choose 1–12 unique securities")
    if any(not isinstance(code, str) or len(code) != 6 or not code.isdigit() for code in codes):
        raise InvalidData("simulation security code is invalid")
    lots = request["lotSizes"]
    if not isinstance(lots, dict) or set(lots) != set(codes) or any(type(lots[c]) is not int or not 1 <= lots[c] <= 1_000_000 for c in codes):
        raise InvalidData("verified exchange lot size is required for each security")
    fees = request["feesPerFill"]
    if not isinstance(fees, dict) or set(fees) != set(codes):
        raise InvalidData("explicit per-security simulated commission is required")
    parsed_fees = {code: _money(fees[code], f"fee {code}") for code in codes}
    weights = request["weights"]
    if not isinstance(weights, dict) or set(weights) != set(codes):
        raise InvalidData("weights must include exactly the selected securities")
    parsed = {code: _money(weights[code], f"weight {code}") for code in codes}
    total = sum(parsed.values(), ZERO)
    if total > Decimal("1.000001"):
        raise InvalidData("target weights may not exceed 100%; remaining weight stays in cash")
    cash = _money(request["initialCash"], "initialCash", positive=True)
    return codes, lots, parsed_fees, parsed, cash


def create_account(strategy, request, now):
    if strategy not in STRATEGIES:
        raise InvalidData("strategy must be A–H")
    codes, lots, fees, weights, cash = _validate_config(request)
    return {
        "schemaVersion": 1, "kind": "live_paper_account", "strategy": strategy,
        "status": "running", "realOrder": False, "createdAt": now, "updatedAt": now,
        "config": {"codes": codes, "lotSizes": lots, "feesPerFill": {c: str(fees[c]) for c in codes}, "targetWeights": {c: str(weights[c]) for c in codes}},
        "initialCash": str(cash), "cash": str(cash), "frozenCash": "0",
        "positions": {c: 0 for c in codes}, "orders": [], "fills": [],
        "cashFlows": [{"date": now, "type": "initial", "amount": str(cash), "reason": "虚拟账户初始化"}],
        "decisions": [], "aiRuns": [], "curve": [{"date": now, "equity": str(cash), "cash": str(cash), "nav": "1"}],
        "lastProcessedSession": None, "audit": [{"date": now, "action": "start", "amount": str(cash)}],
    }


def apply_action(account, request, now):
    if not isinstance(request, dict) or not isinstance(request.get("action"), str):
        raise InvalidData("simulation action is required")
    action = request["action"]
    allowed = {
        "pause": {"action"}, "resume": {"action"},
        "fund": {"action", "amount", "reason"},
        "withdraw": {"action", "amount", "reason"},
        "reset": {"action", "userConfirmed"},
    }
    if action not in allowed or set(request) - allowed[action]:
        raise InvalidData("unexpected simulation action fields")
    updated = deepcopy(account)
    if action == "pause":
        if updated["status"] != "running": raise InvalidData("only a running simulation can be paused")
        updated["status"] = "paused"
    elif action == "resume":
        if updated["status"] != "paused": raise InvalidData("only a paused simulation can be resumed")
        updated["status"] = "running"
    elif action in ("fund", "withdraw"):
        if updated["status"] == "reset": raise InvalidData("reset account must be started again")
        amount = _money(request.get("amount"), "amount", positive=True)
        cash = _money(updated["cash"], "cash")
        frozen = _money(updated["frozenCash"], "frozenCash")
        if action == "fund":
            updated["cash"] = str(cash + amount)
            kind = "virtual_funding"
        else:
            available = cash - frozen
            if amount > available: raise InvalidData("cannot withdraw virtual funds reserved by open orders")
            updated["cash"] = str(cash - amount)
            kind = "virtual_withdrawal"
        reason = request.get("reason", "用户确认")
        if not isinstance(reason, str): raise InvalidData("reason must be text")
        updated["cashFlows"].append({"date": now, "type": kind, "amount": str(amount), "reason": reason[:160]})
    elif action == "reset":
        if request.get("userConfirmed") is not True: raise InvalidData("reset requires explicit confirmation")
        cash = _money(updated["initialCash"], "initialCash", positive=True)
        updated["status"] = "reset"
        updated["cash"] = str(cash); updated["frozenCash"] = "0"
        updated["positions"] = {c: 0 for c in updated["config"]["codes"]}
        updated["orders"] = []; updated["fills"] = []; updated["decisions"] = []
        updated["cashFlows"] = [{"date": now, "type": "reset", "amount": str(cash), "reason": "用户确认重置虚拟账户"}]
        updated["curve"] = [{"date": now, "equity": str(cash), "cash": str(cash), "nav": "1"}]
        updated["lastProcessedSession"] = None
    else:
        raise InvalidData("unsupported simulation action")
    updated["updatedAt"] = now
    updated["audit"].append({"date": now, "action": action, "amount": str(request.get("amount", "0"))})
    return updated


def append_ai_decision(account, decision):
    """Append one immutable AI decision per completed market session."""
    if account.get("strategy") != "G" or account.get("kind") != "live_paper_account":
        raise InvalidData("AI autonomous decisions are only accepted by the G virtual account")
    if not isinstance(decision, dict) or decision.get("realOrder") is not False:
        raise InvalidData("AI decision must be a no-real-order research record")
    day = decision.get("asOf")
    if not isinstance(day, str) or len(day) != 10:
        raise InvalidData("AI decision session is invalid")
    if account.get("lastProcessedSession") == day:
        return deepcopy(account), False
    updated = deepcopy(account)
    updated["decisions"].append(deepcopy(decision))
    updated["lastProcessedSession"] = day
    updated["updatedAt"] = decision.get("createdAt", day)
    return updated, True


def _bar_decimal(bar, key):
    try:
        value = Decimal(str(bar[key]))
    except (KeyError, InvalidOperation, TypeError, ValueError):
        raise InvalidData(f"daily {key} is invalid")
    if not value.is_finite() or value <= 0:
        raise InvalidData(f"daily {key} is invalid")
    return value


def execute_open_orders(account, bars_by_code, session):
    """Execute yesterday's virtual intent at today's archived daily open.

    This is a transparent daily-bar proxy, not an exchange queue or guaranteed fill.
    """
    updated = deepcopy(account)
    if updated.get("strategy") != "G" or updated.get("kind") != "live_paper_account":
        raise InvalidData("open-order simulation is only available for G")
    codes = updated["config"]["codes"]
    if not isinstance(bars_by_code, dict) or set(bars_by_code) != set(codes):
        raise InvalidData("complete daily bars are required for simulated execution")
    for code, bar in bars_by_code.items():
        if not isinstance(bar, dict) or bar.get("date") != session:
            raise InvalidData("simulated execution bars are not aligned to one session")
        _bar_decimal(bar, "open"); _bar_decimal(bar, "close")
    cash = _money(updated["cash"], "cash")
    # Release virtual sell proceeds before sizing buys. This is a portfolio-level
    # daily-bar simulation; it does not imply exchange queue priority.
    for order in sorted(updated["orders"], key=lambda item: 0 if item["side"] == "sell" else 1):
        if order["status"] not in ("pending", "pending_partial") or order["submittedAsOf"] >= session:
            continue
        code = order["code"]
        price = _bar_decimal(bars_by_code[code], "open")
        lot = updated["config"]["lotSizes"][code]
        fee = _money(updated["config"]["feesPerFill"][code], "fee")
        wanted = int(order.get("remainingUnits", order["units"]))
        held = int(updated["positions"][code])
        if order["side"] == "sell":
            units = min(wanted, held)
            units = units // lot * lot
            if units:
                cash += Decimal(units) * price - fee
                updated["positions"][code] = held - units
        else:
            affordable = max(0, int(max(Decimal(0), cash - fee) // price))
            units = min(wanted, affordable) // lot * lot
            if units:
                cash -= Decimal(units) * price + fee
                updated["positions"][code] = held + units
        order["executionSession"] = session
        order["executionModel"] = "archived daily open proxy; no orderbook or queue evidence"
        order["executedUnits"] = units
        order["averagePrice"] = str(price) if units else None
        order["fee"] = str(fee) if units else "0"
        order["remainingUnits"] = wanted - units
        order["status"] = "filled" if units == wanted else "pending_partial" if units else "cancelled_unaffordable_or_unavailable"
        if units:
            updated["fills"].append({"date": session, "orderId": order["id"], "code": code,
                "side": order["side"], "units": units, "price": str(price), "fee": str(fee),
                "executionModel": order["executionModel"], "realOrder": False})
    updated["cash"] = str(cash)
    return updated


def close_g_session(account, bars_by_code, decision, now, failure=None):
    """Mark a completed session and optionally queue validated next-open intents."""
    day = (decision.get("asOf") if isinstance(decision, dict) else
           next(iter(bars_by_code.values())).get("date") if isinstance(bars_by_code, dict) and bars_by_code else None)
    if not isinstance(day, str) or len(day) != 10:
        raise InvalidData("G decision session is invalid")
    if account.get("lastProcessedSession") == day:
        return deepcopy(account), False
    updated = deepcopy(account)
    if updated.get("status") != "running":
        return updated, False
    codes = updated["config"]["codes"]
    if not isinstance(bars_by_code, dict) or set(bars_by_code) != set(codes):
        raise InvalidData("complete daily bars are required for G valuation")
    for code, bar in bars_by_code.items():
        if not isinstance(bar, dict) or bar.get("date") != day:
            raise InvalidData("G valuation bars are not aligned to one session")
        _bar_decimal(bar, "close")
    parsed = None
    if decision is not None:
        if decision.get("realOrder") is not False or decision.get("provider") != "DeepSeek":
            raise InvalidData("G requires a validated DeepSeek decision; no local substitute is accepted")
        weights = decision.get("targetWeights")
        if not isinstance(weights, dict) or set(weights) != set(codes):
            raise InvalidData("G AI target weights do not match the virtual account")
        parsed = {c: _money(weights[c], f"target weight {c}") for c in codes}
        if sum(parsed.values(), ZERO) > Decimal("1.000001"):
            raise InvalidData("G AI target weights exceed 100%")

    cash = _money(updated["cash"], "cash")
    equity = cash + sum((Decimal(int(updated["positions"][c])) * _bar_decimal(bars_by_code[c], "close") for c in codes), ZERO)
    if equity <= 0:
        raise InvalidData("G virtual equity is not positive")
    queued = 0
    if parsed is not None:
        for code in codes:
            close = _bar_decimal(bars_by_code[code], "close")
            target_value = equity * parsed[code]
            lot = updated["config"]["lotSizes"][code]
            target_units = int(target_value // close) // lot * lot
            projected_units = int(updated["positions"][code])
            for pending in updated["orders"]:
                if pending["code"] == code and pending["status"] in ("pending", "pending_partial"):
                    remaining = int(pending.get("remainingUnits", pending["units"]))
                    projected_units += remaining if pending["side"] == "buy" else -remaining
            delta = target_units - projected_units
            if not delta:
                continue
            updated["orders"].append({"id": f"G-{day}-{code}-{len(updated['orders']) + 1}", "code": code,
                "side": "buy" if delta > 0 else "sell", "units": abs(delta), "remainingUnits": abs(delta), "submittedAsOf": day,
                "referenceClose": str(close), "status": "pending", "executionModel": "next available archived daily open proxy"})
            queued += 1
    previous_peak = _money(max((row["equity"] for row in updated["curve"]), key=lambda x: Decimal(x)), "peak")
    peak = max(previous_peak, equity)
    drawdown = (equity / peak - 1) if peak else ZERO
    initial = _money(updated["initialCash"], "initialCash", positive=True)
    updated["curve"].append({"date": day, "equity": str(equity), "cash": str(cash),
        "nav": str(equity / initial), "drawdown": str(drawdown)})
    if decision is not None:
        updated["decisions"].append(deepcopy(decision))
        updated["aiRuns"].append({"date": day, "status": "completed", "provider": "DeepSeek", "model": decision.get("model"), "realOrder": False})
    else:
        reason = failure if isinstance(failure, str) and failure.strip() else "DeepSeek decision unavailable"
        updated["aiRuns"].append({"date": day, "status": "unavailable", "reason": reason[:400], "realOrder": False})
    updated["lastProcessedSession"] = day
    updated["updatedAt"] = now
    updated["audit"].append({"date": now, "action": "g_session_close", "session": day,
        "equity": str(equity), "queuedOrders": queued})
    return updated, True
