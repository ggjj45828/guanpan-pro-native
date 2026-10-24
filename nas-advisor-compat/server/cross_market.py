"""Evidence-first cross-market lead/lag research.

This module consumes timestamped source observations; it never invents a market
calendar, fills missing minutes, or treats correlation as a forecast. Synthetic
fixtures belong in tests only. Until a provider's historical minute series is
available, callers receive an explicit insufficient-evidence result.
"""
from bisect import bisect_right
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import json
from math import sqrt
from statistics import mean, median

LAG_MINUTES = (0, 5, 10, 15, 30, 45, 60, 90)
MIN_SAMPLES = 40


def _timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(timezone.utc)
    except (ValueError, OverflowError):
        return None


def _series(rows, as_of):
    """Normalize positive, timezone-aware points and enforce point-in-time data."""
    result = {}
    if not isinstance(rows, list):
        return result
    for row in rows:
        if not isinstance(row, dict):
            continue
        stamp = _timestamp(row.get("timestamp"))
        try:
            price = float(row.get("price"))
        except (TypeError, ValueError, OverflowError):
            continue
        if stamp is None or stamp > as_of or not (price > 0 and price < float("inf")):
            continue
        result[stamp] = price
    return dict(sorted(result.items()))


def _nearest(points, target, tolerance_seconds=90, stamps=None):
    # Use only observations at or before target. Never nearest-future matching.
    stamps = stamps if stamps is not None else list(points)
    index = bisect_right(stamps, target) - 1
    if index < 0:
        return None
    stamp = stamps[index]
    return points[stamp] if (target - stamp).total_seconds() <= tolerance_seconds else None


def _correlation(xs, ys):
    if len(xs) < 2:
        return None
    mx, my = mean(xs), mean(ys)
    vx = sum((x - mx) ** 2 for x in xs)
    vy = sum((y - my) ** 2 for y in ys)
    if vx <= 0 or vy <= 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sqrt(vx * vy)


def _metrics(leader, follower, lag_minutes, horizon_minutes):
    lead_changes, future_returns = [], []
    tolerance = 90
    leader_stamps, follower_stamps = list(leader), list(follower)
    for target, target_price in follower.items():
        lead_now = _nearest(leader, target - timedelta(minutes=lag_minutes), tolerance, leader_stamps)
        lead_before = _nearest(leader, target - timedelta(minutes=lag_minutes + 5), tolerance, leader_stamps)
        future_price = _nearest(follower, target + timedelta(minutes=horizon_minutes), tolerance, follower_stamps)
        if lead_now is None or lead_before is None or future_price is None or target_price <= 0:
            continue
        lead_changes.append(lead_now / lead_before - 1.0)
        future_returns.append(future_price / target_price - 1.0)
    n = len(lead_changes)
    if n < MIN_SAMPLES:
        return {"sampleCount": n, "state": "insufficient", "correlation": None,
                "conditionalWinRate": None, "positiveLeadSampleCount": 0,
                "positiveLeadWinRate": None, "negativeLeadSampleCount": 0,
                "negativeLeadWinRate": None, "meanForwardReturn": None,
                "medianForwardReturn": None, "maxAdverseMove": None, "stability": None}
    corr = _correlation(lead_changes, future_returns)
    positive_pairs = [(x, r) for x, r in zip(lead_changes, future_returns) if x > 0]
    negative_pairs = [(x, r) for x, r in zip(lead_changes, future_returns) if x < 0]
    directional_pairs = positive_pairs + negative_pairs
    directional_wins = sum((r > 0 if x > 0 else r < 0) for x, r in directional_pairs)
    half = n // 2
    first_corr = _correlation(lead_changes[:half], future_returns[:half])
    second_corr = _correlation(lead_changes[half:], future_returns[half:])
    stability = (1.0 - min(1.0, abs(first_corr - second_corr) / 2.0)
                 if first_corr is not None and second_corr is not None else None)
    # Require non-trivial evidence and split-period agreement before labeling stable.
    stable = n >= MIN_SAMPLES and corr is not None and stability is not None and stability >= 0.65
    return {"sampleCount": n, "state": "stable_candidate" if stable else "unstable",
            "correlation": corr,
            "conditionalWinRate": directional_wins / len(directional_pairs) if directional_pairs else None,
            "positiveLeadSampleCount": len(positive_pairs),
            "positiveLeadWinRate": (sum(r > 0 for _, r in positive_pairs) / len(positive_pairs)
                                    if positive_pairs else None),
            "negativeLeadSampleCount": len(negative_pairs),
            "negativeLeadWinRate": (sum(r < 0 for _, r in negative_pairs) / len(negative_pairs)
                                    if negative_pairs else None),
            "meanForwardReturn": mean(future_returns), "medianForwardReturn": median(future_returns),
            "maxAdverseMove": min(future_returns), "stability": stability}


def analyze_pair(leader_rows, follower_rows, *, as_of, source, market_status="unknown",
                 max_age_seconds=300):
    """Return non-predictive evidence metrics for one leader/follower pair."""
    as_of = _timestamp(as_of) if isinstance(as_of, str) else as_of
    if as_of is None or as_of.tzinfo is None:
        raise ValueError("as_of must be timezone-aware")
    as_of = as_of.astimezone(timezone.utc)
    leader, follower = _series(leader_rows, as_of), _series(follower_rows, as_of)
    latest = max(leader.keys(), default=None)
    age = (as_of - latest).total_seconds() if latest else None
    base = {"source": source, "asOf": as_of.isoformat(), "leaderLatestAt": latest.isoformat() if latest else None,
            "leaderAgeSeconds": age, "marketStatus": market_status,
            "leaderSamples": len(leader), "followerSamples": len(follower)}
    if not leader or not follower:
        return {**base, "state": "insufficient", "reason": "缺少真实分钟样本", "windows": []}
    if age is None or age < 0 or (market_status == "open" and age > max_age_seconds):
        return {**base, "state": "stale", "reason": "先行市场数据过期或时间异常", "windows": []}
    windows = []
    for lag in LAG_MINUTES:
        for horizon in (5, 15, 30, 60):
            windows.append({"lagMinutes": lag, "horizonMinutes": horizon,
                            **_metrics(leader, follower, lag, horizon)})
    stable = [w for w in windows if w["state"] == "stable_candidate"]
    return {**base, "state": "stable_candidate" if stable else "no_stable_relationship",
            "reason": None if stable else "暂无达到样本量与滚动稳定性门槛的领先关系", "windows": windows}


def lunch_shock(rows, *, day, as_of):
    """Compute 11:30→12:50 price shock only from observed, same-day points."""
    as_of = _timestamp(as_of) if isinstance(as_of, str) else as_of
    if as_of is None or as_of.tzinfo is None:
        raise ValueError("as_of must be timezone-aware")
    points = _series(rows, as_of.astimezone(timezone.utc))
    start = _timestamp(day + "T11:30:00+08:00")
    end = _timestamp(day + "T12:50:00+08:00")
    p0, p1 = _nearest(points, start), _nearest(points, end)
    if p0 is None or p1 is None or p0 <= 0:
        return {"state": "insufficient", "return": None, "from": start.isoformat(), "to": end.isoformat()}
    return {"state": "observed", "return": p1 / p0 - 1.0, "from": start.isoformat(), "to": end.isoformat()}


def replay_lunch_day(leader_rows, asset_rows, *, day, source, rule,
                     minimum_samples=100):
    """Point-in-time lunch replay; cutoff evidence is frozen before outcomes are read.

    `rule` is an explicit, versionable research hypothesis, not a live trading rule.
    For example: {"leaderShockAtLeast": 0.004, "assetMorningAtMost": 0.002,
    "expectedDirection": 1}. Only real dated rows supplied by the archive are used.
    """
    cutoff = _timestamp(day + "T12:50:00+08:00")
    if cutoff > datetime.now(timezone.utc):
        raise ValueError("replay date is not historical")
    if not isinstance(rule, dict) or not isinstance(source, str) or not source.strip():
        raise ValueError("a named source and explicit research rule are required")
    try:
        required_shock = float(rule.get("leaderShockAtLeast", 0.0))
        max_morning = float(rule.get("assetMorningAtMost", 1.0))
        direction_value = int(rule.get("expectedDirection", 1))
    except (TypeError, ValueError, OverflowError):
        raise ValueError("invalid replay rule")
    if not (-1 <= required_shock <= 1 and -1 <= max_morning <= 1 and direction_value in (-1, 1)
            and isinstance(minimum_samples, int) and minimum_samples > 0):
        raise ValueError("replay rule bounds are invalid")
    leader = _series(leader_rows, cutoff)
    asset_pre = _series(asset_rows, cutoff)
    leader_shock = lunch_shock(leader_rows, day=day, as_of=cutoff.isoformat())
    morning_start = _timestamp(day + "T09:30:00+08:00")
    morning_end = _timestamp(day + "T11:30:00+08:00")
    morning_open = _nearest(asset_pre, morning_start)
    morning_close = _nearest(asset_pre, morning_end)
    morning_return = (morning_close / morning_open - 1.0) if morning_open and morning_close else None
    direction = direction_value
    enough = leader_shock["state"] == "observed" and morning_return is not None
    triggered = bool(enough and direction * leader_shock["return"] >= required_shock
                     and morning_return <= max_morning)
    frozen = {"cutoff": cutoff.isoformat(), "day": day, "source": source,
              "rule": dict(rule), "leaderLunchReturn": leader_shock["return"],
              "assetMorningReturn": morning_return,
              "state": "hypothesis" if triggered else "no_hypothesis",
              "reason": None if triggered else "截止时点不满足假设条件或数据不足"}
    # Outcome rows are deliberately isolated from the 12:50 frozen block.
    post = _series(asset_rows, datetime.max.replace(tzinfo=timezone.utc))
    open_1300 = _nearest(post, _timestamp(day + "T13:00:00+08:00"))
    outcomes = {}
    for minutes in (5, 15, 30, 60):
        stamp = _timestamp(day + f"T13:{minutes:02d}:00+08:00") if minutes < 60 else _timestamp(day + "T14:00:00+08:00")
        value = _nearest(post, stamp)
        outcomes[str(minutes)] = (value / open_1300 - 1.0) if open_1300 and value else None
    confirmed = None
    if triggered and outcomes["5"] is not None:
        confirmed = (outcomes["5"] > 0) == (direction > 0)
    fingerprint = sha256(json.dumps({"leader": leader_rows, "asset": asset_rows,
                                     "rule": rule, "day": day}, sort_keys=True,
                                    ensure_ascii=False, default=str).encode()).hexdigest()
    return {"day": day, "source": source, "fingerprint": fingerprint,
            "frozenAt": cutoff.isoformat(), "frozenHypothesis": frozen,
            "postOpenReturns": outcomes, "confirmedAt5m": confirmed,
            "outcomeState": "evaluated" if open_1300 is not None else "awaiting_post_open_data",
            "minimumSamplesForAggregate": minimum_samples}


def replay_lunch_days(days, *, source, rule, minimum_samples=100):
    """Replay actual sessions independently; report no rate below the sample floor."""
    if not isinstance(minimum_samples, int) or minimum_samples < 1 or minimum_samples > 1000:
        raise ValueError("minimum replay sample count must be from 1 to 1000")
    results, seen_days = [], set()
    for row in days:
        if not isinstance(row, dict) or not isinstance(row.get("day"), str) or row["day"] in seen_days:
            continue
        seen_days.add(row["day"])
        results.append(replay_lunch_day(row.get("leader", []), row.get("asset", []),
                                        day=row["day"], source=source, rule=rule,
                                        minimum_samples=minimum_samples))
    triggered = [r for r in results if r["frozenHypothesis"]["state"] == "hypothesis"
                 and r["confirmedAt5m"] is not None]
    confirmed = sum(r["confirmedAt5m"] is True for r in triggered)
    return {"source": source, "rule": dict(rule), "sessionCount": len(results),
            "hypothesisCount": len(triggered), "confirmationCount": confirmed,
            "confirmationRate": confirmed / len(triggered) if len(triggered) >= minimum_samples else None,
            "state": "evaluated" if len(triggered) >= minimum_samples else "insufficient_samples",
            "results": results}
