"""Evidence-first cross-market lead/lag research.

This module consumes timestamped source observations; it never invents a market
calendar, fills missing minutes, or treats correlation as a forecast. Synthetic
fixtures belong in tests only. Until a provider's historical minute series is
available, callers receive an explicit insufficient-evidence result.
"""
from bisect import bisect_left, bisect_right
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import json
from math import atanh, erfc, isfinite, sqrt, tanh
from statistics import mean, median
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

LAG_MINUTES = (0, 5, 10, 15, 30, 45, 60, 90)
MIN_SAMPLES = 100  # Independent trading sessions, not correlated minute observations.
MIN_HOLDOUT_TRIGGERS = 30
PRACTICAL_EDGE = 0.05


def _wilson(successes, total, z=1.959963984540054):
    """Two-sided 95% Wilson interval for a binomial rate."""
    if total <= 0:
        return None
    rate = successes / total
    denominator = 1 + z * z / total
    center = (rate + z * z / (2 * total)) / denominator
    radius = z * sqrt((rate * (1 - rate) + z * z / (4 * total)) / total) / denominator
    return [max(0.0, center - radius), min(1.0, center + radius)]


def _replay_assessment(results, minimum_samples):
    """Assess a frozen rule on a chronological holdout against non-trigger days.

    A positive result remains a candidate requiring a later replication. A
    sufficiently powered result can reject a practically useful edge; lack of
    significance alone is never presented as proof of no relationship.
    """
    eligible = [row for row in results if row.get("dataComplete", True)
                and row.get("confirmed") is not None]
    if all(isinstance(row.get("day"), str) for row in eligible):
        eligible.sort(key=lambda row: row["day"])
    split = int(len(eligible) * 0.7)
    holdout = eligible[split:]
    triggered = [row for row in holdout if row.get("triggered") and row.get("confirmed") is not None]
    controls = [row for row in holdout if not row.get("triggered") and row.get("confirmed") is not None]
    trigger_hits = sum(row["confirmed"] is True for row in triggered)
    control_hits = sum(row["confirmed"] is True for row in controls)
    trigger_interval = _wilson(trigger_hits, len(triggered))
    control_interval = _wilson(control_hits, len(controls))
    edge_interval = ([max(-1.0, trigger_interval[0] - control_interval[1]),
                      min(1.0, trigger_interval[1] - control_interval[0])]
                     if trigger_interval and control_interval else None)
    if (len(eligible) < minimum_samples or len(triggered) < MIN_HOLDOUT_TRIGGERS or
            len(controls) < MIN_HOLDOUT_TRIGGERS):
        state = "insufficient_samples"
    elif edge_interval[1] <= PRACTICAL_EDGE:
        state = "no_stable_relationship"
    elif edge_interval[0] > 0:
        state = "candidate_requires_replication"
    else:
        state = "inconclusive"
    return {"state": state, "chronologicalSplitIndex": split,
            "minimumHoldoutTriggers": MIN_HOLDOUT_TRIGGERS,
            "holdoutSessions": len(holdout), "triggerCount": len(triggered),
            "triggerConfirmationRate": trigger_hits / len(triggered) if triggered else None,
            "triggerRate95CI": trigger_interval,
            "controlCount": len(controls),
            "controlConfirmationRate": control_hits / len(controls) if controls else None,
            "controlRate95CI": control_interval, "edge95CI": edge_interval,
            "practicalEdgeThreshold": PRACTICAL_EDGE,
            "note": ("样本不足，不能判断" if state == "insufficient_samples" else
                     "留出样本未支持至少5个百分点的稳定增量优势；没有稳定领先关系" if state == "no_stable_relationship" else
                     "留出样本出现候选增量关系，需用后续未见数据复现" if state == "candidate_requires_replication" else
                     "当前留出样本无法区分有用增量与随机波动")}


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


def _series(rows, as_of, *, require_available=True, require_availability_timestamp=False):
    """Normalize positive, timezone-aware points and enforce point-in-time data."""
    result = {}
    if not isinstance(rows, list):
        return result
    for row in rows:
        if not isinstance(row, dict):
            continue
        stamp = _timestamp(row.get("timestamp"))
        available_at = row.get("availableAt")
        availability = _timestamp(available_at) if available_at is not None else None
        raw_price = row.get("price")
        # Python's bool is an int subclass: float(True) == 1.0. A JSON boolean
        # is malformed market data, never a valid one-yuan observation.
        if isinstance(raw_price, bool):
            continue
        try:
            price = float(raw_price)
        except (TypeError, ValueError, OverflowError):
            continue
        if (stamp is None or stamp > as_of or
                (require_available and require_availability_timestamp and availability is None) or
                (require_available and available_at is not None and
                 (availability is None or availability > as_of)) or
                not (price > 0 and price < float("inf"))):
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


def _following(points, target, tolerance_seconds=90, stamps=None):
    """Match an outcome only to a real observation at/after its requested time."""
    stamps = stamps if stamps is not None else list(points)
    index = bisect_left(stamps, target)
    if index < 0 or index >= len(stamps):
        return None
    stamp = stamps[index]
    return points[stamp] if (stamp - target).total_seconds() <= tolerance_seconds else None


def _correlation(xs, ys):
    if len(xs) < 2:
        return None
    mx, my = mean(xs), mean(ys)
    vx = sum((x - mx) ** 2 for x in xs)
    vy = sum((y - my) ** 2 for y in ys)
    if vx <= 0 or vy <= 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sqrt(vx * vy)


def _daily_pair_returns(leader, follower, lag_minutes, horizon_minutes, session_timezone):
    """Return one mean pair per exchange-local trading day, with no future
    matching. This is the shared, point-in-time input for rolling and intraday
    research views; it deliberately does not convert minute count into sample
    count.
    """
    intraday_pairs = {}
    tolerance = 90
    leader_stamps, follower_stamps = list(leader), list(follower)
    zone = ZoneInfo(session_timezone)
    for target, target_price in follower.items():
        lead_now = _nearest(leader, target - timedelta(minutes=lag_minutes), tolerance, leader_stamps)
        lead_before = _nearest(leader, target - timedelta(minutes=lag_minutes + 5), tolerance, leader_stamps)
        future_price = _following(follower, target + timedelta(minutes=horizon_minutes), tolerance, follower_stamps)
        if lead_now is None or lead_before is None or future_price is None or target_price <= 0:
            continue
        day = target.astimezone(zone).date().isoformat()
        intraday_pairs.setdefault(day, []).append((lead_now / lead_before - 1.0,
                                                    future_price / target_price - 1.0))
    return [(day, mean(x for x, _ in samples), mean(y for _, y in samples), len(samples))
            for day, samples in sorted(intraday_pairs.items()) if samples]


def _metrics(leader, follower, lag_minutes, horizon_minutes, session_timezone="Asia/Shanghai",
             comparison_count=None):
    comparison_count = comparison_count or len(LAG_MINUTES) * 4
    daily_pairs = _daily_pair_returns(leader, follower, lag_minutes, horizon_minutes, session_timezone)
    lead_changes = [x for _, x, _, _ in daily_pairs]
    future_returns = [y for _, _, y, _ in daily_pairs]
    n = len(lead_changes)
    if n < MIN_SAMPLES:
        return {"sampleCount": n, "state": "insufficient", "correlation": None,
                "conditionalWinRate": None, "positiveLeadSampleCount": 0,
                "positiveLeadWinRate": None, "negativeLeadSampleCount": 0,
                "negativeLeadWinRate": None, "meanForwardReturn": None,
                "medianForwardReturn": None, "maxAdverseMove": None, "stability": None,
                "correlationCI95": None, "bonferroniAdjustedPValue": None,
                "testedWindowCount": comparison_count,
                "observationCount": sum(count for _, _, _, count in daily_pairs),
                "sampleUnit": "independent trading sessions"}
    corr = _correlation(lead_changes, future_returns)
    positive_pairs = [(x, r) for x, r in zip(lead_changes, future_returns) if x > 0]
    negative_pairs = [(x, r) for x, r in zip(lead_changes, future_returns) if x < 0]
    directional_pairs = positive_pairs + negative_pairs
    directional_wins = sum((r > 0 if x > 0 else r < 0) for x, r in directional_pairs)
    # A relation driven by a few event days is not a dependable cross-market
    # finding. At least 30 genuinely directional sessions and 30% of the
    # observed days must contribute before it can even be a candidate.
    minimum_directional_days = max(30, int(n * 0.30))
    half = n // 2
    first_corr = _correlation(lead_changes[:half], future_returns[:half])
    second_corr = _correlation(lead_changes[half:], future_returns[half:])
    stability = (1.0 - min(1.0, abs(first_corr - second_corr) / 2.0)
                 if first_corr is not None and second_corr is not None else None)
    # Fisher-z correlation test with a caller-specified Bonferroni family size.
    # Direct pair analysis covers 8x4 windows; per-holding scans cover all
    # markets and windows. This is a screening guard, not causality.
    confidence = None
    adjusted_p = None
    if corr is not None and n > 3:
        bounded_corr = min(0.999999, max(-0.999999, corr))
        z_score = atanh(bounded_corr) * sqrt(n - 3)
        margin = 1.96 / sqrt(n - 3)
        center = atanh(bounded_corr)
        confidence = [tanh(center - margin), tanh(center + margin)]
        adjusted_p = min(1.0, erfc(abs(z_score) / sqrt(2.0)) * comparison_count)
    stable = (n >= MIN_SAMPLES and len(directional_pairs) >= minimum_directional_days
              and corr is not None and stability is not None
              and stability >= 0.65 and adjusted_p is not None and adjusted_p <= 0.05)
    return {"sampleCount": n, "state": "stable_candidate" if stable else "unstable",
            "sampleUnit": "independent trading sessions",
            "observationCount": sum(count for _, _, _, count in daily_pairs),
            "correlation": corr,
            "correlationCI95": confidence,
            "bonferroniAdjustedPValue": adjusted_p,
            "testedWindowCount": comparison_count,
            "conditionalWinRate": directional_wins / len(directional_pairs) if directional_pairs else None,
            "positiveLeadSampleCount": len(positive_pairs),
            "positiveLeadWinRate": (sum(r > 0 for _, r in positive_pairs) / len(positive_pairs)
                                    if positive_pairs else None),
            "negativeLeadSampleCount": len(negative_pairs),
            "negativeLeadWinRate": (sum(r < 0 for _, r in negative_pairs) / len(negative_pairs)
                                    if negative_pairs else None),
            "directionalSampleCount": len(directional_pairs),
            "minimumDirectionalSampleCount": minimum_directional_days,
            "meanForwardReturn": mean(future_returns), "medianForwardReturn": median(future_returns),
            "maxAdverseMove": min(future_returns), "stability": stability}


def analyze_pair(leader_rows, follower_rows, *, as_of, source, market_status="unknown",
                 max_age_seconds=300, follower_timezone="Asia/Shanghai",
                 multiple_comparison_count=None):
    """Return non-predictive evidence metrics for one leader/follower pair."""
    as_of = _timestamp(as_of) if isinstance(as_of, str) else as_of
    if as_of is None or as_of.tzinfo is None:
        raise ValueError("as_of must be timezone-aware")
    as_of = as_of.astimezone(timezone.utc)
    comparison_count = multiple_comparison_count or len(LAG_MINUTES) * 4
    if not isinstance(comparison_count, int) or comparison_count < len(LAG_MINUTES) * 4:
        raise ValueError("multiple comparison count must cover all tested windows")
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
                            **_metrics(leader, follower, lag, horizon, follower_timezone,
                                       comparison_count)})
    stable = [w for w in windows if w["state"] == "stable_candidate"]
    tested = [w for w in windows if w["sampleCount"] >= MIN_SAMPLES]
    if stable:
        state, reason = "stable_candidate", None
    elif tested:
        state, reason = "no_stable_relationship", "历史样本未通过分段稳定性和32窗口多重比较校正；没有稳定领先关系"
    else:
        state, reason = "insufficient", "独立交易日样本不足，无法判断是否存在稳定领先关系"
    return {**base, "state": state, "reason": reason, "windows": windows}


def rolling_validity(leader_rows, follower_rows, *, as_of, lag_minutes, horizon_minutes,
                     windows=(20, 60, 120), session_timezone="Asia/Shanghai"):
    """Report rolling descriptive validity for one explicitly selected window.

    A short rolling window can show a correlation but cannot establish a lead.
    Therefore every row stays research-only; a lack of correlation is shown as
    such instead of being silently replaced by an intuitive market story.
    """
    as_of = _timestamp(as_of) if isinstance(as_of, str) else as_of
    if as_of is None or as_of.tzinfo is None:
        raise ValueError("as_of must be timezone-aware")
    if type(lag_minutes) is not int or lag_minutes not in LAG_MINUTES:
        raise ValueError("lag_minutes must be a configured lag")
    if type(horizon_minutes) is not int or horizon_minutes not in (5, 15, 30, 60):
        raise ValueError("horizon_minutes must be a configured horizon")
    if (not isinstance(windows, (tuple, list)) or not windows or
            any(type(item) is not int or item < 2 or item > 400 for item in windows)):
        raise ValueError("windows must contain 2–400 session lengths")
    leader = _series(leader_rows, as_of.astimezone(timezone.utc))
    follower = _series(follower_rows, as_of.astimezone(timezone.utc))
    pairs = _daily_pair_returns(leader, follower, lag_minutes, horizon_minutes, session_timezone)
    results = []
    for window in sorted(set(windows)):
        subset = pairs[-window:]
        xs, ys = [row[1] for row in subset], [row[2] for row in subset]
        count = len(subset)
        correlation = _correlation(xs, ys)
        # “no_consistent_relationship” is only a descriptive outcome here;
        # it does not prove no relationship outside this observed interval.
        state = "descriptive_only" if count >= window else "insufficient"
        results.append({"windowSessions": window, "sampleCount": count,
                        "sampleStartDay": subset[0][0] if subset else None,
                        "sampleEndDay": subset[-1][0] if subset else None,
                        "correlation": correlation,
                        "conditionalDirectionRate": (sum((x > 0) == (y > 0) for x, y in zip(xs, ys)) / count
                                                     if count else None),
                        "state": state, "eligibleForTradingSignal": False})
    return {"lagMinutes": lag_minutes, "horizonMinutes": horizon_minutes,
            "asOf": as_of.astimezone(timezone.utc).isoformat(), "windows": results,
            "eligibleForTradingSignal": False,
            "note": "20/60/120日滚动统计只用于观察关系是否衰减；未通过未来复现前不能作为交易信号"}


def intraday_time_profiles(leader_rows, follower_rows, *, as_of, lag_minutes=0,
                           horizon_minutes=15, session_timezone="Asia/Shanghai",
                           bucket_minutes=30, minimum_sessions=20):
    """Create exchange-local time-of-day profiles from one pair per day/bucket.

    The aggregation unit is a trading day within each bucket, preventing many
    correlated minute observations from masquerading as independent evidence.
    """
    as_of = _timestamp(as_of) if isinstance(as_of, str) else as_of
    if as_of is None or as_of.tzinfo is None:
        raise ValueError("as_of must be timezone-aware")
    if type(bucket_minutes) is not int or bucket_minutes not in (15, 30, 60):
        raise ValueError("bucket_minutes must be 15, 30 or 60")
    if type(minimum_sessions) is not int or not 2 <= minimum_sessions <= 400:
        raise ValueError("minimum_sessions must be between 2 and 400")
    leader = _series(leader_rows, as_of.astimezone(timezone.utc))
    follower = _series(follower_rows, as_of.astimezone(timezone.utc))
    zone = ZoneInfo(session_timezone)
    grouped = {}
    leader_stamps, follower_stamps = list(leader), list(follower)
    for target, target_price in follower.items():
        lead_now = _nearest(leader, target - timedelta(minutes=lag_minutes), stamps=leader_stamps)
        lead_before = _nearest(leader, target - timedelta(minutes=lag_minutes + 5), stamps=leader_stamps)
        future = _following(follower, target + timedelta(minutes=horizon_minutes), stamps=follower_stamps)
        if lead_now is None or lead_before is None or future is None or target_price <= 0:
            continue
        local = target.astimezone(zone)
        minute = local.hour * 60 + local.minute
        bucket = (minute // bucket_minutes) * bucket_minutes
        key = (local.date().isoformat(), bucket)
        grouped.setdefault(key, []).append((lead_now / lead_before - 1.0, future / target_price - 1.0))
    by_bucket = {}
    for (day, bucket), rows in grouped.items():
        by_bucket.setdefault(bucket, []).append((day, mean(x for x, _ in rows), mean(y for _, y in rows)))
    profiles = []
    for bucket in sorted(by_bucket):
        rows = sorted(by_bucket[bucket])
        xs, ys = [row[1] for row in rows], [row[2] for row in rows]
        profiles.append({"startMinute": bucket, "endMinute": bucket + bucket_minutes,
                         "sampleCount": len(rows), "sampleStartDay": rows[0][0] if rows else None,
                         "sampleEndDay": rows[-1][0] if rows else None,
                         "correlation": _correlation(xs, ys),
                         "conditionalDirectionRate": (sum((x > 0) == (y > 0) for x, y in zip(xs, ys)) / len(rows)
                                                      if rows else None),
                         "state": "descriptive_only" if len(rows) >= minimum_sessions else "insufficient",
                         "eligibleForTradingSignal": False})
    return {"lagMinutes": lag_minutes, "horizonMinutes": horizon_minutes,
            "bucketMinutes": bucket_minutes, "minimumSessions": minimum_sessions,
            "profiles": profiles, "eligibleForTradingSignal": False,
            "note": "分时段画像按交易日聚合，仅描述不同时间段的历史关系；不是盘中预测或交易信号"}


def currency_context(fx_rows, asset_rows, *, as_of, source, pair, window_minutes=60,
                     maximum_age_seconds=900):
    """Return a timestamped FX context only when the caller supplies a named,
    verified feed. It deliberately has no hard-coded 'weaker currency means
    buy' rule: an FX move is an observation that may invalidate assumptions,
    never an order authorization.
    """
    as_of = _timestamp(as_of) if isinstance(as_of, str) else as_of
    if as_of is None or as_of.tzinfo is None:
        raise ValueError("as_of must be timezone-aware")
    if not isinstance(source, str) or not source.strip() or not isinstance(pair, str) or not pair.strip():
        raise ValueError("named FX source and pair are required")
    if type(window_minutes) is not int or not 5 <= window_minutes <= 240:
        raise ValueError("window_minutes must be between 5 and 240")
    if type(maximum_age_seconds) is not int or not 60 <= maximum_age_seconds <= 3600:
        raise ValueError("maximum_age_seconds must be between 60 and 3600")
    as_of = as_of.astimezone(timezone.utc)
    fx, asset = _series(fx_rows, as_of), _series(asset_rows, as_of)
    if source.strip().casefold() in {"未验证来源", "unknown", "unknown source", "unverified"}:
        return {"pair": pair, "source": None, "state": "insufficient_data",
                "reason": "汇率来源未验证，不进入决策上下文", "eligibleForTradingSignal": False}
    if not fx:
        return {"pair": pair, "source": source, "state": "insufficient_data",
                "reason": "没有带来源和时间戳的汇率样本", "eligibleForTradingSignal": False}
    fx_stamps = list(fx)
    latest = max(fx)
    age = (as_of - latest).total_seconds()
    base = {"pair": pair, "source": source, "asOf": latest.isoformat(), "ageSeconds": max(0, age),
            "windowMinutes": window_minutes, "eligibleForTradingSignal": False,
            "note": "汇率仅作为跨境资产上下文；没有硬编码方向规则，不能单独触发做T、网格或买卖"}
    if age < 0 or age > maximum_age_seconds:
        return {**base, "state": "stale", "reason": "汇率行情超过新鲜度门槛"}
    prior = _nearest(fx, latest - timedelta(minutes=window_minutes), stamps=fx_stamps)
    asset_latest = max(asset, default=None)
    asset_prior = (_nearest(asset, asset_latest - timedelta(minutes=window_minutes), stamps=list(asset))
                   if asset_latest else None)
    if prior is None or asset_latest is None or asset_prior is None:
        return {**base, "state": "insufficient_data",
                "reason": "汇率或持仓缺少同窗真实样本，不输出方向推断"}
    return {**base, "state": "observed_context", "reason": None,
            "fxReturnPercent": round((fx[latest] / prior - 1.0) * 100, 4),
            "assetReturnPercent": round((asset[asset_latest] / asset_prior - 1.0) * 100, 4),
            "assetLatestAt": asset_latest.isoformat()}


def detect_live_divergence(leader_rows, asset_rows, *, as_of, window_minutes=15,
                           minimum_move_percent=0.25, tolerance_seconds=90,
                           maximum_age_seconds=600):
    """Describe a fresh, timestamp-aligned move mismatch; this is not a forecast.

    Returns an observation only. It deliberately has no strategy, price, or
    order fields and is never eligible to authorize a trade by itself.
    """
    as_of = _timestamp(as_of) if isinstance(as_of, str) else as_of
    if as_of is None or as_of.tzinfo is None:
        raise ValueError("as_of must be timezone-aware")
    if type(window_minutes) is not int or not 5 <= window_minutes <= 120:
        raise ValueError("window_minutes must be between 5 and 120")
    if (isinstance(minimum_move_percent, bool) or
            not isinstance(minimum_move_percent, (int, float)) or
            not isfinite(minimum_move_percent) or not 0.05 <= minimum_move_percent <= 5):
        raise ValueError("minimum_move_percent must be between 0.05 and 5")
    if type(tolerance_seconds) is not int or not 0 <= tolerance_seconds <= 180:
        raise ValueError("tolerance_seconds must be between 0 and 180")
    if type(maximum_age_seconds) is not int or not 60 <= maximum_age_seconds <= 1800:
        raise ValueError("maximum_age_seconds must be between 60 and 1800")

    as_of = as_of.astimezone(timezone.utc)
    leader = _series(leader_rows, as_of)
    asset = _series(asset_rows, as_of)
    if not leader or not asset:
        return {"state": "insufficient_data", "reason": "缺少真实分钟样本",
                "eligibleForTradingSignal": False, "windowMinutes": window_minutes}

    leader_latest, asset_latest = max(leader), max(asset)
    leader_age = (as_of - leader_latest).total_seconds()
    asset_age = (as_of - asset_latest).total_seconds()
    common_at = min(leader_latest, asset_latest)
    target = common_at - timedelta(minutes=window_minutes)
    leader_stamps, asset_stamps = list(leader), list(asset)
    leader_now = _nearest(leader, common_at, tolerance_seconds, leader_stamps)
    asset_now = _nearest(asset, common_at, tolerance_seconds, asset_stamps)
    leader_then = _nearest(leader, target, tolerance_seconds, leader_stamps)
    asset_then = _nearest(asset, target, tolerance_seconds, asset_stamps)
    result = {"windowMinutes": window_minutes, "asOf": common_at.isoformat(),
              "leaderLatestAt": leader_latest.isoformat(), "assetLatestAt": asset_latest.isoformat(),
              "expiresAt": (common_at + timedelta(seconds=maximum_age_seconds)).isoformat(),
              "leaderAgeSeconds": max(0, leader_age), "assetAgeSeconds": max(0, asset_age),
              "eligibleForTradingSignal": False,
              "note": "仅描述同一时段的已观察价格差异，不代表领先预测，也不能单独触发交易"}
    if leader_age > maximum_age_seconds or asset_age > maximum_age_seconds:
        return {**result, "state": "stale", "reason": "跨市场或持仓行情超过新鲜度门槛"}
    if any(value is None for value in (leader_now, asset_now, leader_then, asset_then)):
        return {**result, "state": "insufficient_data", "reason": "窗口端点缺少足够接近的真实分钟点"}

    leader_return = leader_now / leader_then - 1
    asset_return = asset_now / asset_then - 1
    threshold = minimum_move_percent / 100
    leader_direction = 1 if leader_return >= threshold else -1 if leader_return <= -threshold else 0
    asset_direction = 1 if asset_return >= threshold else -1 if asset_return <= -threshold else 0
    if leader_direction == 0 and asset_direction == 0:
        state = "no_material_move"
    elif leader_direction and asset_direction and leader_direction != asset_direction:
        state = "observed_divergence"
    else:
        state = "aligned_or_one_side_flat"
    return {**result, "state": state, "reason": None,
            "leaderReturnPercent": round(leader_return * 100, 4),
            "assetReturnPercent": round(asset_return * 100, 4),
            "minimumMovePercent": minimum_move_percent,
            "leaderDirection": leader_direction, "assetDirection": asset_direction}


def lunch_shock(rows, *, day, as_of, require_availability_timestamp=False):
    """Compute 11:30→12:50 price shock only from observed, same-day points."""
    as_of = _timestamp(as_of) if isinstance(as_of, str) else as_of
    if as_of is None or as_of.tzinfo is None:
        raise ValueError("as_of must be timezone-aware")
    points = _series(rows, as_of.astimezone(timezone.utc),
                     require_availability_timestamp=require_availability_timestamp)
    start = _timestamp(day + "T11:30:00+08:00")
    end = _timestamp(day + "T12:50:00+08:00")
    p0, p1 = _nearest(points, start), _nearest(points, end)
    if p0 is None or p1 is None or p0 <= 0:
        return {"state": "insufficient", "return": None, "from": start.isoformat(), "to": end.isoformat()}
    return {"state": "observed", "return": p1 / p0 - 1.0, "from": start.isoformat(), "to": end.isoformat()}


def overnight_absorption(leader_rows, asset_rows, *, as_of, minimum_sessions=30,
                         maximum_baseline_age_hours=24):
    """Describe external-market moves after the prior A-share close and their
    observed opening-gap/first-30-minute digestion for the held ETF.

    The result is descriptive only. It does not claim stable lead/lag, predict
    a price, or authorize a trade. A session is omitted unless all endpoints
    are actual, point-in-time observations from the source and held asset.
    """
    as_of = _timestamp(as_of) if isinstance(as_of, str) else as_of
    if as_of is None or as_of.tzinfo is None:
        raise ValueError("as_of must be timezone-aware")
    if type(minimum_sessions) is not int or not 2 <= minimum_sessions <= 500:
        raise ValueError("minimum_sessions must be between 2 and 500")
    if (isinstance(maximum_baseline_age_hours, bool) or
            not isinstance(maximum_baseline_age_hours, (int, float)) or
            not isfinite(maximum_baseline_age_hours) or not 1 <= maximum_baseline_age_hours <= 72):
        raise ValueError("maximum_baseline_age_hours must be between 1 and 72")

    as_of = as_of.astimezone(timezone.utc)
    leader = _series(leader_rows, as_of)
    asset = _series(asset_rows, as_of)
    zone = ZoneInfo("Asia/Shanghai")
    by_day = {}
    for stamp, price in asset.items():
        local = stamp.astimezone(zone)
        minute = local.hour * 60 + local.minute
        if 570 <= minute <= 900:
            by_day.setdefault(local.date().isoformat(), []).append((stamp, price, minute))

    sessions = []
    leader_stamps = list(leader)
    dates = sorted(by_day)
    for index in range(1, len(dates)):
        previous_day, day = dates[index - 1], dates[index]
        previous_close_candidates = [row for row in by_day[previous_day] if 890 <= row[2] <= 900]
        today = by_day[day]
        open_candidates = [row for row in today if 570 <= row[2] <= 580]
        checkpoint_candidates = [row for row in today if 595 <= row[2] <= 605]
        if not previous_close_candidates or not open_candidates or not checkpoint_candidates:
            continue
        previous_close = max(previous_close_candidates, key=lambda row: row[0])
        opening = min(open_candidates, key=lambda row: row[0])
        checkpoint = min(checkpoint_candidates, key=lambda row: (abs(row[2] - 600), row[0]))
        if not leader:
            continue
        source_start = _nearest(leader, previous_close[0], stamps=leader_stamps)
        source_start_stamp = next((stamp for stamp in reversed(leader_stamps)
                                   if stamp <= previous_close[0]), None)
        source_end_stamp = next((stamp for stamp in reversed(leader_stamps)
                                 if previous_close[0] < stamp <= opening[0]), None)
        if (source_start is None or source_start_stamp is None or source_end_stamp is None or
                (previous_close[0] - source_start_stamp).total_seconds() > maximum_baseline_age_hours * 3600):
            continue
        source_end = leader[source_end_stamp]
        gap = opening[1] / previous_close[1] - 1.0
        digestion = checkpoint[1] / opening[1] - 1.0
        absorption = -digestion / gap if abs(gap) >= 0.001 else None
        sessions.append({"day": day, "leaderReturnPercent": (source_end / source_start - 1.0) * 100,
                         "openingGapPercent": gap * 100, "firstThirtyMinuteReturnPercent": digestion * 100,
                         "gapAbsorptionFraction": absorption,
                         "sourceStartAt": source_start_stamp.isoformat(),
                         "sourceEndAt": source_end_stamp.isoformat(),
                         "assetPreviousCloseAt": previous_close[0].isoformat(),
                         "assetOpenAt": opening[0].isoformat(), "assetCheckpointAt": checkpoint[0].isoformat()})

    count = len(sessions)
    paired = [row for row in sessions if row["leaderReturnPercent"] is not None]
    absorptions = [row["gapAbsorptionFraction"] for row in sessions
                   if row["gapAbsorptionFraction"] is not None and isfinite(row["gapAbsorptionFraction"])]
    state = "descriptive_only" if count >= minimum_sessions else "insufficient"
    return {"state": state, "asOf": as_of.isoformat(), "sampleCount": count, "minimumSessions": minimum_sessions,
            "sampleStartDay": sessions[0]["day"] if sessions else None,
            "sampleEndDay": sessions[-1]["day"] if sessions else None,
            "leaderOpenGapCorrelation": _correlation([row["leaderReturnPercent"] for row in paired],
                                                      [row["openingGapPercent"] for row in paired]),
            "meanLeaderReturnPercent": mean(row["leaderReturnPercent"] for row in paired) if paired else None,
            "meanOpeningGapPercent": mean(row["openingGapPercent"] for row in sessions) if sessions else None,
            "meanFirstThirtyMinuteReturnPercent": mean(row["firstThirtyMinuteReturnPercent"] for row in sessions) if sessions else None,
            "meanGapAbsorptionFraction": mean(absorptions) if absorptions else None,
            "absorptionSampleCount": len(absorptions), "eligibleForTradingSignal": False,
            "note": ("只描述隔夜来源变动、A股开盘缺口及开盘后30分钟的历史关系；不代表预测或交易信号"
                     if state == "descriptive_only" else
                     f"有效完整交易日仅 {count} 天，至少需要 {minimum_sessions} 天；不生成隔夜关系结论"),
            "sessions": sessions}


def tail_to_next_day(asset_rows, *, as_of, minimum_sessions=30):
    """Describe, rather than predict, a held asset's late-session move and
    the following session's opening/first-half-hour path.

    Sessions require actual timestamps on both sides of the overnight boundary.
    Missing holidays and provider gaps are omitted; they are never filled from a
    later close. This is a research statistic, not a next-day order signal.
    """
    as_of = _timestamp(as_of) if isinstance(as_of, str) else as_of
    if as_of is None or as_of.tzinfo is None:
        raise ValueError("as_of must be timezone-aware")
    if type(minimum_sessions) is not int or not 2 <= minimum_sessions <= 500:
        raise ValueError("minimum_sessions must be between 2 and 500")
    points = _series(asset_rows, as_of.astimezone(timezone.utc))
    zone = ZoneInfo("Asia/Shanghai")
    by_day = {}
    for stamp, price in points.items():
        local = stamp.astimezone(zone)
        minute = local.hour * 60 + local.minute
        if 570 <= minute <= 900:
            by_day.setdefault(local.date().isoformat(), []).append((stamp, price, minute))

    sessions = []
    dates = sorted(by_day)
    for index in range(1, len(dates)):
        prior, day = dates[index - 1], dates[index]
        prior_rows, today = by_day[prior], by_day[day]
        tail_start = [row for row in prior_rows if 840 <= row[2] <= 850]
        tail_close = [row for row in prior_rows if 890 <= row[2] <= 900]
        opening = [row for row in today if 570 <= row[2] <= 580]
        checkpoint = [row for row in today if 595 <= row[2] <= 605]
        if not tail_start or not tail_close or not opening or not checkpoint:
            continue
        start = min(tail_start, key=lambda row: row[0])
        close = max(tail_close, key=lambda row: row[0])
        opened = min(opening, key=lambda row: row[0])
        after_open = min(checkpoint, key=lambda row: (abs(row[2] - 600), row[0]))
        if start[1] <= 0 or close[1] <= 0 or opened[1] <= 0:
            continue
        sessions.append({"day": day,
                         "tailReturnPercent": (close[1] / start[1] - 1.0) * 100,
                         "nextOpeningGapPercent": (opened[1] / close[1] - 1.0) * 100,
                         "firstThirtyMinuteReturnPercent": (after_open[1] / opened[1] - 1.0) * 100,
                         "tailStartAt": start[0].isoformat(), "priorCloseAt": close[0].isoformat(),
                         "nextOpenAt": opened[0].isoformat(), "nextCheckpointAt": after_open[0].isoformat()})
    tail = [row["tailReturnPercent"] for row in sessions]
    gap = [row["nextOpeningGapPercent"] for row in sessions]
    open_path = [row["firstThirtyMinuteReturnPercent"] for row in sessions]
    count = len(sessions)
    state = "descriptive_only" if count >= minimum_sessions else "insufficient"
    return {"state": state, "asOf": as_of.astimezone(timezone.utc).isoformat(),
            "sampleCount": count, "minimumSessions": minimum_sessions,
            "sampleStartDay": sessions[0]["day"] if sessions else None,
            "sampleEndDay": sessions[-1]["day"] if sessions else None,
            "tailToOpenGapCorrelation": _correlation(tail, gap),
            "tailToFirstThirtyMinuteCorrelation": _correlation(tail, open_path),
            "meanTailReturnPercent": mean(tail) if tail else None,
            "meanNextOpeningGapPercent": mean(gap) if gap else None,
            "meanFirstThirtyMinuteReturnPercent": mean(open_path) if open_path else None,
            "eligibleForTradingSignal": False,
            "note": ("仅描述该ETF尾盘、次日开盘及开盘后30分钟的历史路径；不代表预测或交易信号"
                     if state == "descriptive_only" else
                     f"有效完整交易日仅 {count} 天，至少需要 {minimum_sessions} 天；不生成尾盘至次日结论"),
            "sessions": sessions}


def _session_time(day, clock, zone):
    try:
        parsed_day = datetime.strptime(day, "%Y-%m-%d").date()
        parsed_clock = datetime.strptime(clock, "%H:%M").time()
        return datetime.combine(parsed_day, parsed_clock, ZoneInfo(zone)).astimezone(timezone.utc)
    except (ValueError, TypeError, ZoneInfoNotFoundError):
        raise ValueError("invalid replay session time or timezone")


def _validate_replay_day(day):
    try:
        parsed_day = datetime.strptime(day, "%Y-%m-%d").date()
    except (ValueError, TypeError):
        raise ValueError("invalid replay day")
    if parsed_day.weekday() >= 5:
        raise ValueError("weekend replay is not a trading session")


def replay_hypothesis_day(leader_rows, asset_rows, *, day, source, hypothesis,
                          minimum_samples=100):
    """Evaluate a user-supplied bounded hypothesis spec without executable rules.

    Conditions use observed return between two exchange-local HH:MM times. The
    frozen hypothesis only reads points available by `cutoff`; post-cutoff rows
    are accessed in a separate outcome pass.
    """
    if not isinstance(hypothesis, dict) or not isinstance(source, str) or not source.strip():
        raise ValueError("named data source and hypothesis object are required")
    _validate_replay_day(day)
    cutoff_time = hypothesis.get("cutoff")
    leader_zone = hypothesis.get("leaderTimezone", "Asia/Shanghai")
    asset_zone = hypothesis.get("assetTimezone", "Asia/Shanghai")
    cutoff_zone = hypothesis.get("cutoffTimezone", asset_zone)
    cutoff = _session_time(day, cutoff_time, cutoff_zone)
    if cutoff > datetime.now(timezone.utc):
        raise ValueError("replay date is not historical")
    conditions = hypothesis.get("conditions")
    direction = hypothesis.get("expectedDirection")
    baseline_clock = hypothesis.get("outcomeBaseline")
    confirmation_clock = hypothesis.get("confirmAt")
    horizon_clocks = hypothesis.get("horizons", [])
    if (not isinstance(conditions, list) or not 1 <= len(conditions) <= 8 or
            direction not in (-1, 1) or not isinstance(horizon_clocks, list) or len(horizon_clocks) > 8):
        raise ValueError("invalid hypothesis specification")
    baseline = _session_time(day, baseline_clock, asset_zone)
    confirmation = _session_time(day, confirmation_clock, asset_zone)
    if baseline <= cutoff or confirmation < baseline:
        raise ValueError("outcome times must follow the frozen cutoff")
    horizons = [_session_time(day, clock, asset_zone) for clock in horizon_clocks]
    if any(item <= baseline for item in horizons):
        raise ValueError("outcome horizons must follow the baseline")
    leader = _series(leader_rows, cutoff, require_availability_timestamp=True)
    asset_pre = _series(asset_rows, cutoff, require_availability_timestamp=True)
    evaluated, complete = [], True
    for condition in conditions:
        if not isinstance(condition, dict) or condition.get("series") not in ("leader", "asset"):
            raise ValueError("invalid hypothesis condition")
        zone = leader_zone if condition["series"] == "leader" else asset_zone
        start = _session_time(day, condition.get("from"), zone)
        end = _session_time(day, condition.get("to"), zone)
        if start >= end or end > cutoff:
            raise ValueError("hypothesis condition must end by the freeze time")
        series = leader if condition["series"] == "leader" else asset_pre
        stamps = list(series)
        start_price = _nearest(series, start, stamps=stamps)
        end_price = _nearest(series, end, stamps=stamps)
        observed = (end_price / start_price - 1.0) if start_price and end_price else None
        try:
            threshold = float(condition["threshold"])
            operator = condition["operator"]
            upper = float(condition["upperThreshold"]) if operator == "between" else None
        except (KeyError, TypeError, ValueError, OverflowError):
            raise ValueError("invalid hypothesis threshold")
        if not (-1 <= threshold <= 1 and (upper is None or threshold <= upper <= 1) or
                upper is not None and -1 <= threshold <= upper <= 1):
            raise ValueError("hypothesis threshold is outside the supported return range")
        if operator not in ("gte", "lte", "between"):
            raise ValueError("unsupported hypothesis operator")
        passed = (observed is not None and
                  (observed >= threshold if operator == "gte" else
                   observed <= threshold if operator == "lte" else threshold <= observed <= upper))
        complete = complete and observed is not None
        evaluated.append({"series": condition["series"], "from": condition["from"], "to": condition["to"],
                          "operator": operator, "threshold": threshold, "upperThreshold": upper,
                          "observedReturn": observed, "passed": bool(passed)})
    trigger = complete and all(item["passed"] for item in evaluated)
    frozen = {"cutoff": cutoff.isoformat(), "hypothesisId": hypothesis.get("id"),
              "conditions": evaluated, "dataComplete": complete,
              "state": "hypothesis" if trigger else "no_hypothesis",
              "reason": None if trigger else "冻结时点条件不成立或输入分钟数据不完整"}
    max_outcome = max([baseline, confirmation] + horizons)
    # Outcome labels may be collected shortly after their event timestamp; the
    # availability cutoff applies to frozen inputs, not to later ground truth.
    asset_all = _series(asset_rows, max_outcome, require_available=False)
    outcome_stamps = list(asset_all)
    base_value = _following(asset_all, baseline, stamps=outcome_stamps)
    confirm_value = _following(asset_all, confirmation, stamps=outcome_stamps)
    confirm_return = confirm_value / base_value - 1 if base_value and confirm_value else None
    outcomes = {}
    for clock, stamp in zip(horizon_clocks, horizons):
        price = _following(asset_all, stamp, stamps=outcome_stamps)
        outcomes[clock] = price / base_value - 1 if base_value and price else None
    confirmed = None
    if confirm_return is not None:
        confirmed = confirm_return > 0 if direction > 0 else confirm_return < 0
    fingerprint = sha256(json.dumps({"leader": leader_rows, "asset": asset_rows,
                                     "hypothesis": hypothesis, "day": day}, sort_keys=True,
                                    ensure_ascii=False, default=str).encode()).hexdigest()
    return {"day": day, "source": source, "fingerprint": fingerprint,
            "frozenAt": cutoff.isoformat(), "frozenHypothesis": frozen,
            "confirmationReturn": confirm_return, "confirmed": confirmed,
            "postOpenReturns": outcomes,
            "outcomeState": ("evaluated" if base_value is not None and confirm_value is not None
                             and all(value is not None for value in outcomes.values())
                             else "awaiting_post_cutoff_data")}


def replay_hypothesis_days(days, *, source, hypothesis, minimum_samples=100):
    if not isinstance(minimum_samples, int) or minimum_samples < 1 or minimum_samples > 1000:
        raise ValueError("minimum replay sample count must be from 1 to 1000")
    results, seen = [], set()
    for row in days:
        if not isinstance(row, dict) or not isinstance(row.get("day"), str) or row["day"] in seen:
            continue
        seen.add(row["day"])
        results.append(replay_hypothesis_day(row.get("leader", []), row.get("asset", []),
                                             day=row["day"], source=source, hypothesis=hypothesis,
                                             minimum_samples=minimum_samples))
    triggers = [row for row in results if row["frozenHypothesis"]["state"] == "hypothesis"
                and row["confirmed"] is not None]
    hits = sum(row["confirmed"] is True for row in triggers)
    assessment_rows = [{"day": row["day"],
                        "dataComplete": row["frozenHypothesis"].get("dataComplete", False),
                        "triggered": row["frozenHypothesis"]["state"] == "hypothesis",
                        "confirmed": row["confirmed"]} for row in results]
    assessment = _replay_assessment(assessment_rows, minimum_samples)
    return {"hypothesis": dict(hypothesis), "sessionCount": len(results),
            "triggerCount": len(triggers), "confirmationCount": hits,
            "confirmationRate": (assessment["triggerConfirmationRate"]
                                 if assessment["state"] != "insufficient_samples" else None),
            "inSampleConfirmationRate": hits / len(triggers) if len(triggers) >= minimum_samples else None,
            "state": assessment["state"],
            "replayState": "evaluated" if len(triggers) >= minimum_samples else "insufficient_samples",
            "assessment": assessment,
            "results": results}


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
    _validate_replay_day(day)
    try:
        required_shock = float(rule.get("leaderShockAtLeast", 0.0))
        max_morning = float(rule.get("assetMorningAtMost", 1.0))
        direction_value = int(rule.get("expectedDirection", 1))
    except (TypeError, ValueError, OverflowError):
        raise ValueError("invalid replay rule")
    if not (-1 <= required_shock <= 1 and -1 <= max_morning <= 1 and direction_value in (-1, 1)
            and isinstance(minimum_samples, int) and minimum_samples > 0):
        raise ValueError("replay rule bounds are invalid")
    leader = _series(leader_rows, cutoff, require_availability_timestamp=True)
    asset_pre = _series(asset_rows, cutoff, require_availability_timestamp=True)
    leader_shock = lunch_shock(leader_rows, day=day, as_of=cutoff.isoformat(),
                               require_availability_timestamp=True)
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
              "rule": dict(rule), "dataComplete": enough,
              "leaderLunchReturn": leader_shock["return"],
              "assetMorningReturn": morning_return,
              "state": "hypothesis" if triggered else "no_hypothesis",
              "reason": None if triggered else "截止时点不满足假设条件或数据不足"}
    # Outcome rows are deliberately isolated from the 12:50 frozen block.
    # Outcomes are realized prices, so they are selected by exchange timestamp;
    # only the frozen 12:50 input pass is gated by first-observed time.
    post = _series(asset_rows, datetime.max.replace(tzinfo=timezone.utc), require_available=False)
    post_stamps = list(post)
    open_1300 = _following(post, _timestamp(day + "T13:00:00+08:00"), stamps=post_stamps)
    outcomes = {}
    for minutes in (5, 15, 30, 60):
        stamp = _timestamp(day + f"T13:{minutes:02d}:00+08:00") if minutes < 60 else _timestamp(day + "T14:00:00+08:00")
        value = _following(post, stamp, stamps=post_stamps)
        outcomes[str(minutes)] = (value / open_1300 - 1.0) if open_1300 and value else None
    confirmed = None
    if outcomes["5"] is not None:
        confirmed = outcomes["5"] > 0 if direction > 0 else outcomes["5"] < 0
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
    assessment_rows = [{"day": row["day"],
                        "dataComplete": row["frozenHypothesis"].get("dataComplete", False),
                        "triggered": row["frozenHypothesis"]["state"] == "hypothesis",
                        "confirmed": row["confirmedAt5m"]} for row in results]
    assessment = _replay_assessment(assessment_rows, minimum_samples)
    return {"source": source, "rule": dict(rule), "sessionCount": len(results),
            "hypothesisCount": len(triggered), "confirmationCount": confirmed,
            "confirmationRate": (assessment["triggerConfirmationRate"]
                                 if assessment["state"] != "insufficient_samples" else None),
            "inSampleConfirmationRate": confirmed / len(triggered) if len(triggered) >= minimum_samples else None,
            "state": assessment["state"],
            "replayState": "evaluated" if len(triggered) >= minimum_samples else "insufficient_samples",
            "assessment": assessment,
            "results": results}
