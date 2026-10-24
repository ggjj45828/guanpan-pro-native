"""Read-only bridge from the existing NAS archive to phone-side research.

This never reads or writes virtual accounts and never computes an order price.
Minute-volume evidence is admitted only after per-session comparison with the
independent daily-volume archive; unverified/incomplete sessions are excluded.
"""
from __future__ import annotations

import json
import math
import re
import base64
import gzip
import hashlib
import uuid
import zlib
from collections import defaultdict
from datetime import date, datetime, time, timezone, timedelta
from decimal import Decimal, InvalidOperation
from zoneinfo import ZoneInfo
from statistics import median, pstdev
import cross_market
from workers import CROSS_MARKET_SERIES, market_session_open

CN = ZoneInfo("Asia/Shanghai")


def cross_market_evidence(database, code, now=None, lookback_days=240):
    """Compute one holding's historical lead/lag evidence from NAS minute archives."""
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None or not isinstance(lookback_days, int) or not 60 <= lookback_days <= 400:
        raise ValueError("timezone-aware now and a 60–400 day research window are required")
    end = now.astimezone(CN).date()
    start = (end - timedelta(days=lookback_days)).isoformat()
    end_text = end.isoformat()
    follower_rows = []
    with database.connect() as db:
        rows = db.execute("SELECT body FROM minute_archive WHERE code=? AND stamp>=? ORDER BY stamp",
                          (code, start)).fetchall()
    for row in rows:
        try:
            value = json.loads(row[0])
            stamp = datetime.fromisoformat(value["timestamp"])
            if stamp.tzinfo is not None and stamp.astimezone(timezone.utc) <= now.astimezone(timezone.utc):
                follower_rows.append(value)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            continue
    reports, sources = [], set()
    for market_id in CROSS_MARKET_SERIES:
        archive = database.get_cross_market_range(market_id, start, end_text)
        leader_rows = archive["rows"]
        source = archive.get("source")
        source_names = ({source} if isinstance(source, str) else
                        {item for item in source if isinstance(item, str)} if isinstance(source, list) else set())
        market_open = market_session_open(market_id, now)
        report = cross_market.analyze_pair(leader_rows, follower_rows, as_of=now,
            source=", ".join(sorted(source_names)) or "未验证来源",
            market_status="open" if market_open else "closed", max_age_seconds=600,
            multiple_comparison_count=len(CROSS_MARKET_SERIES) * len(cross_market.LAG_MINUTES) * 4)
        stable_windows = [row for row in report.get("windows", [])
                          if row.get("state") == "stable_candidate"]
        # A default observation window is explicitly non-trading when no
        # historical candidate exists; it is there to reveal decay, not to
        # quietly turn a no-relationship result into a signal.
        reference = (min(stable_windows, key=lambda row: row.get("bonferroniAdjustedPValue", 1.0))
                     if stable_windows else {"lagMinutes": 0, "horizonMinutes": 15})
        rolling = cross_market.rolling_validity(
            leader_rows, follower_rows, as_of=now,
            lag_minutes=reference["lagMinutes"], horizon_minutes=reference["horizonMinutes"])
        profiles = cross_market.intraday_time_profiles(
            leader_rows, follower_rows, as_of=now,
            lag_minutes=reference["lagMinutes"], horizon_minutes=reference["horizonMinutes"])
        overnight = cross_market.overnight_absorption(leader_rows, follower_rows, as_of=now)
        overnight.pop("sessions", None)  # Keep the phone payload to compact statistics, not raw archives.
        reports.append({"market": market_id, "currentMarketStatus": "open" if market_open else "closed",
                        "liveDivergence": cross_market.detect_live_divergence(
                            leader_rows, follower_rows, as_of=now, window_minutes=15,
                            minimum_move_percent=0.25, tolerance_seconds=90,
                            maximum_age_seconds=600),
                        "overnightAbsorption": overnight,
                        "rollingValidity": rolling,
                        "timeProfiles": profiles, **report})
    def newest_timestamp(rows):
        stamps = [row["leaderLatestAt"] for row in rows if row.get("leaderLatestAt")]
        return max(stamps, key=lambda value: datetime.fromisoformat(value).astimezone(timezone.utc)) if stamps else None

    stable = [row for row in reports if row["state"] == "stable_candidate"]
    sufficiently_tested = [window for row in reports for window in row.get("windows", [])
                           if window.get("sampleCount", 0) >= cross_market.MIN_SAMPLES]
    lead_sources = []
    for row in reports:
        # A window that merely has enough days is not a leading relationship.
        # Exposing its lag as "best" would make an unsupported source look usable.
        metrics = [window for window in row.get("windows", [])
                   if window.get("state") == "stable_candidate"
                   and window.get("bonferroniAdjustedPValue") is not None]
        best_for_market = min(metrics, key=lambda window: window.get("bonferroniAdjustedPValue", 1.0)) if metrics else None
        lead_sources.append({"market": row["market"], "state": row["state"],
            "currentMarketStatus": row["currentMarketStatus"], "source": row["source"],
            "latestAt": row["leaderLatestAt"], "ageSeconds": row["leaderAgeSeconds"],
            "sampleCount": max((window["sampleCount"] for window in row.get("windows", [])), default=0),
            "bestLagMinutes": best_for_market["lagMinutes"] if best_for_market else None,
            "bestHorizonMinutes": best_for_market["horizonMinutes"] if best_for_market else None,
            "correlation": best_for_market["correlation"] if best_for_market else None,
            "adjustedPValue": best_for_market["bonferroniAdjustedPValue"] if best_for_market else None,
            "conditionalWinRate": best_for_market["conditionalWinRate"] if best_for_market else None,
            "stability": best_for_market["stability"] if best_for_market else None,
            "historicalCandidateOnly": best_for_market is not None})
    ranked_sources = sorted((item for item in lead_sources if item["state"] == "stable_candidate"),
                            key=lambda item: (item["adjustedPValue"],
                                              -(item["sampleCount"] or 0), item["market"]))
    ranked_sources = [{**item, "rank": index + 1} for index, item in enumerate(ranked_sources)]
    best = min(stable, key=lambda row: min(
        (window["bonferroniAdjustedPValue"] for window in row["windows"]
         if window["state"] == "stable_candidate" and window["bonferroniAdjustedPValue"] is not None),
        default=1.0)) if stable else None
    if best:
        candidates = [window for window in best["windows"] if window["state"] == "stable_candidate"]
        best_window = min(candidates, key=lambda window: window["bonferroniAdjustedPValue"])
        state, reason = "stable_candidate", None
        best_lag = best_window["lagMinutes"]
        win_rate = best_window["conditionalWinRate"]
        source = best["source"]
        sample_count = best_window["sampleCount"]
        best_market = best["market"]
        latest_at = best["leaderLatestAt"]
        current_status = best["currentMarketStatus"]
        age_seconds = best["leaderAgeSeconds"]
    elif sufficiently_tested:
        state, reason = "no_stable_relationship", "历史样本未通过分段稳定性与多重比较校正；没有稳定领先关系"
        best_lag, win_rate, source, sample_count, best_market = None, None, None, max(
            row["sampleCount"] for row in reports), None
        sample_count = max(window["sampleCount"] for window in sufficiently_tested)
        latest_at = newest_timestamp(reports)
        source = ", ".join(sorted({row["source"] for row in reports if row["source"] != "未验证来源"})) or None
        most_supported = max(reports, key=lambda row: max(
            (window["sampleCount"] for window in row.get("windows", [])), default=0))
        current_status, age_seconds = most_supported["currentMarketStatus"], most_supported["leaderAgeSeconds"]
    else:
        state, reason = "insufficient_real_archive", "跨市场或持仓分钟档案不足100个独立交易日，无法判断领先关系"
        best_lag, win_rate, source, sample_count, best_market = None, None, None, 0, None
        latest_at = newest_timestamp(reports)
        source = ", ".join(sorted({row["source"] for row in reports if row["source"] != "未验证来源"})) or None
        current_status, age_seconds = "unknown", None
    # A historical relationship cannot quietly become a trading input.  At
    # least two independently pre-registered, non-overlapping future windows
    # must pass before the phone may use a *fresh* live divergence to pause a
    # plan.  Even then this only informs a Risk Guard; it never creates prices.
    validations = []
    for row in database.list_research("cross_market_pre_registered_hypothesis", 100):
        definition = row["record"].get("definition")
        if isinstance(definition, dict) and definition.get("asset") == code:
            status = prospective_replication_status(database, row["id"])
            validations.append({"registrationId": row["id"], "leader": definition.get("leader"), **status})
    validated_markets = {row["leader"] for row in validations
                         if row.get("state") == "prospectively_replicated" and isinstance(row.get("leader"), str)}
    eligible = best_market in validated_markets if best_market else False
    live_divergences = []
    for row in reports:
        observation = dict(row["liveDivergence"])
        observation["eligibleForTradingSignal"] = bool(
            row["market"] in validated_markets and observation.get("state") == "observed_divergence")
        live_divergences.append({"market": row["market"], **observation})
    tail_to_next_day = cross_market.tail_to_next_day(follower_rows, as_of=now)
    # The app needs the auditable summary, not an entire minute archive payload.
    tail_to_next_day.pop("sessions", None)
    return {"state": state, "reason": reason, "source": source, "asOf": latest_at,
            "sampleCount": sample_count,
            "bestLagMinutes": best_lag, "conditionalWinRate": win_rate,
            "bestMarket": best_market, "currentMarketStatus": current_status,
            "ageSeconds": age_seconds, "researchWindow": {"start": start, "end": end_text},
            "leadSources": lead_sources, "rankedHistoricalCandidates": ranked_sources,
            "liveDivergences": live_divergences,
            "overnightAbsorption": [{"market": row["market"], **row["overnightAbsorption"]} for row in reports],
            "rollingValidity": [{"market": row["market"], **row["rollingValidity"]} for row in reports],
            "timeProfiles": [{"market": row["market"], **row["timeProfiles"]} for row in reports],
            "tailToNextDay": tail_to_next_day,
            "preRegisteredValidations": validations,
            "eligibleForTradingSignal": eligible,
            "validationState": ("prospectively_replicated" if eligible else
                                "requires_pre_registered_future_replication" if ranked_sources else
                                "no_validated_candidate")}


def replay_lunch_archive(database, leader, asset, start, end, rule, minimum_samples=30):
    """Replay archived provider observations; never synthesize absent sessions."""
    if not isinstance(leader, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,80}", leader) is None:
        raise ValueError("invalid leader id")
    if not isinstance(asset, str) or len(asset) != 6 or not asset.isdigit():
        raise ValueError("invalid asset code")
    session_days = database.cross_market_days(leader, start, end)
    sessions, missing_asset = [], 0
    sources = set()
    evidence_sessions = []
    for day in session_days:
        lead = database.get_cross_market_minute_observations(leader, day)
        held = database.get_minute_observations(asset, day)
        if not lead["rows"] or not held["rows"]:
            missing_asset += 1
            continue
        if isinstance(lead["source"], str):
            sources.add(lead["source"])
        sessions.append({"day": day, "leader": lead["rows"], "asset": held["rows"]})
        evidence_sessions.append({"day": day,
            "leader": {"source": lead["source"], "fetchedAtRange": lead.get("fetchedAtRange"), "rows": lead["rows"]},
            "asset": {"source": held["source"], "fetchedAtRange": held.get("fetchedAtRange"), "rows": held["rows"]}})
    report = cross_market.replay_lunch_days(sessions, source=", ".join(sorted(sources)) or "未验证来源",
                                            rule=rule, minimum_samples=minimum_samples)
    report.update({"leader": leader, "asset": asset, "range": {"start": start, "end": end},
                   "archivedLeaderSessions": len(session_days), "replayedSessions": len(sessions),
                   "missingAssetSessions": missing_asset,
                   "evidenceState": "available" if sessions else "insufficient_real_archive",
                   "warning": None if sessions else "NAS没有可用于回放的跨市场与持仓分钟档案；没有生成预测结论"})
    report["evidenceSessions"] = evidence_sessions
    return report


def replay_hypothesis_archive(database, leader, asset, start, end, hypothesis, minimum_samples=100):
    """Run a bounded, read-only user hypothesis against NAS minute archives."""
    if not isinstance(leader, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,80}", leader) is None:
        raise ValueError("invalid leader id")
    if not isinstance(asset, str) or len(asset) != 6 or not asset.isdigit():
        raise ValueError("invalid asset code")
    session_days = database.cross_market_days(leader, start, end)
    sessions, missing_asset = [], 0
    sources = set()
    evidence_sessions = []
    for day in session_days:
        lead = database.get_cross_market_minute_observations(leader, day)
        held = database.get_minute_observations(asset, day)
        if not lead["rows"] or not held["rows"]:
            missing_asset += 1
            continue
        if isinstance(lead["source"], str): sources.add(lead["source"])
        sessions.append({"day": day, "leader": lead["rows"], "asset": held["rows"]})
        evidence_sessions.append({"day": day,
            "leader": {"source": lead["source"], "fetchedAtRange": lead.get("fetchedAtRange"), "rows": lead["rows"]},
            "asset": {"source": held["source"], "fetchedAtRange": held.get("fetchedAtRange"), "rows": held["rows"]}})
    report = cross_market.replay_hypothesis_days(
        sessions, source=", ".join(sorted(sources)) or "未验证来源",
        hypothesis=hypothesis, minimum_samples=minimum_samples)
    report.update({"leader": leader, "asset": asset, "range": {"start": start, "end": end},
                   "archivedLeaderSessions": len(session_days), "replayedSessions": len(sessions),
                   "missingAssetSessions": missing_asset,
                   "evidenceState": "available" if sessions else "insufficient_real_archive",
                   "warning": None if sessions else "NAS没有可用于回放的跨市场与持仓分钟档案；没有生成预测结论"})
    report["evidenceSessions"] = evidence_sessions
    return report


def preregister_hypothesis(database, leader, asset, hypothesis, not_before, *, now=None):
    """Persist an immutable future-study definition before its observation window.

    Registration creates research metadata only: no plan, account, order, cash
    or position is changed. A later evaluator must use a time window beginning
    no earlier than ``notBefore`` and retain the definition fingerprint.
    """
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None or not isinstance(leader, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,80}", leader) is None:
        raise ValueError("valid leader and timezone-aware registration time are required")
    if not isinstance(asset, str) or len(asset) != 6 or not asset.isdigit() or not isinstance(hypothesis, dict):
        raise ValueError("valid real ETF asset and hypothesis are required")
    try:
        start = datetime.fromisoformat(not_before.replace("Z", "+00:00")) if isinstance(not_before, str) else None
    except ValueError:
        start = None
    if start is None or start.tzinfo is None or start.astimezone(timezone.utc) <= now.astimezone(timezone.utc):
        raise ValueError("notBefore must be a future timezone-aware timestamp")
    definition = {"leader": leader, "asset": asset, "hypothesis": hypothesis,
                  "notBefore": start.astimezone(timezone.utc).isoformat()}
    canonical = json.dumps(definition, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    fingerprint = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    registration_id = "pre-register-" + uuid.uuid4().hex
    record = {"kind": "cross_market_pre_registered_hypothesis", "registeredAt": now.astimezone(timezone.utc).isoformat(),
              "definition": definition, "definitionFingerprint": fingerprint,
              "state": "awaiting_future_observations", "eligibleForTradingSignal": False,
              "note": "预注册研究定义；只能在notBefore之后用未见档案评估，不能作为交易信号"}
    database.put_research(registration_id, record)
    return {"registrationId": registration_id, **record}


def evaluate_pre_registered_hypothesis(database, registration_id, start, end, minimum_samples=100, *, now=None):
    """Evaluate only observations that were unavailable when a study was registered.

    The result remains research evidence.  In particular it must never become a
    candidate plan: its `eligibleForTradingSignal` flag is permanently false
    until a separately reviewed product rule says otherwise.
    """
    now = now or datetime.now(timezone.utc)
    record = database.get_research(registration_id)
    if not record or record.get("kind") != "cross_market_pre_registered_hypothesis":
        raise ValueError("pre-registered hypothesis not found")
    definition = record.get("definition")
    if not isinstance(definition, dict):
        raise ValueError("pre-registered hypothesis definition is unreadable")
    try:
        not_before = datetime.fromisoformat(str(definition["notBefore"]).replace("Z", "+00:00"))
        first, last = date.fromisoformat(start), date.fromisoformat(end)
    except (KeyError, TypeError, ValueError):
        raise ValueError("invalid evaluation date range")
    if now.tzinfo is None or not_before.tzinfo is None or not_before > now:
        raise ValueError("hypothesis is not eligible for future-observation evaluation yet")
    if first > last or first < not_before.astimezone(timezone.utc).date():
        raise ValueError("evaluation range must start on or after the pre-registered future window")
    if last >= now.astimezone(timezone.utc).date():
        raise ValueError("evaluation range must end before the current UTC date")
    if not isinstance(minimum_samples, int) or isinstance(minimum_samples, bool) or not 1 <= minimum_samples <= 1000:
        raise ValueError("minimumSamples must be from 1 to 1000")
    report = replay_hypothesis_archive(database, definition.get("leader"), definition.get("asset"),
                                       start, end, definition.get("hypothesis"), minimum_samples)
    report.update({"registrationId": registration_id,
                   "definitionFingerprint": record.get("definitionFingerprint"),
                   "preRegistrationState": record.get("state"),
                   "eligibleForTradingSignal": False,
                   "warning": report.get("warning") or
                       "这是预注册后的研究评估，不是交易信号，不能改变候选限价计划或真实账本"})
    saved = persist_replay(database, report, {
        "type": "pre_registered_future_evaluation", "registrationId": registration_id,
        "definitionFingerprint": record.get("definitionFingerprint"),
        "definition": definition, "minimumSamples": minimum_samples})
    saved["eligibleForTradingSignal"] = False
    return saved


def prospective_replication_status(database, registration_id):
    """Return a deliberately strict, read-only future-replication verdict.

    A single attractive out-of-sample segment is still only a candidate.  Two
    non-overlapping, post-registration segments must each pass their own
    holdout/control assessment.  This does not create a signal or mutate the
    registration; it only exposes whether a later Risk Guard may consider a
    fresh divergence as a reason to withdraw an existing plan.
    """
    registration = database.get_research(registration_id)
    if not registration or registration.get("kind") != "cross_market_pre_registered_hypothesis":
        raise ValueError("pre-registered hypothesis not found")
    accepted, rejected, incomplete = [], [], []
    for row in database.list_research("cross_market_point_in_time_replay", 100):
        payload = row["record"]
        request = payload.get("request") if isinstance(payload, dict) else None
        hypothesis = request.get("hypothesis") if isinstance(request, dict) else None
        if not isinstance(hypothesis, dict) or hypothesis.get("registrationId") != registration_id:
            continue
        report = payload.get("report")
        interval = report.get("range") if isinstance(report, dict) else None
        if not isinstance(interval, dict) or not isinstance(interval.get("start"), str) or not isinstance(interval.get("end"), str):
            incomplete.append(row["id"]); continue
        try:
            start, end = date.fromisoformat(interval["start"]), date.fromisoformat(interval["end"])
        except ValueError:
            incomplete.append(row["id"]); continue
        item = {"replayId": row["id"], "start": start, "end": end,
                "state": report.get("state"), "evidenceState": report.get("evidenceState")}
        if report.get("evidenceState") != "available": incomplete.append(row["id"])
        elif report.get("state") == "candidate_requires_replication": accepted.append(item)
        elif report.get("state") in ("no_stable_relationship", "inconclusive"): rejected.append(item)
        else: incomplete.append(row["id"])
    accepted.sort(key=lambda item: (item["start"], item["end"], item["replayId"]))
    independent = []
    for item in accepted:
        if not independent or item["start"] > independent[-1]["end"]:
            independent.append(item)
    if rejected:
        state = "no_stable_relationship"
        note = "至少一个预注册未来样本未支持稳定增量关系；不能用于风险判断"
    elif len(independent) >= 2:
        state = "prospectively_replicated"
        note = "两个不重叠的预注册未来样本均通过各自的留出/对照评估；仅可用于新鲜背离的保守风险拦截"
    else:
        state = "awaiting_future_replication"
        note = "需要至少两个不重叠的预注册未来样本分别通过评估；当前不能用于风险判断"
    return {"state": state, "eligibleForTradingSignal": state == "prospectively_replicated",
            "passingIndependentEvaluations": [{"replayId": item["replayId"], "range": {
                "start": item["start"].isoformat(), "end": item["end"].isoformat()}} for item in independent],
            "rejectedEvaluations": [item["replayId"] for item in rejected],
            "incompleteEvaluations": incomplete, "note": note}


def persist_replay(database, report, hypothesis):
    """Keep an immutable, research-only point-in-time replay snapshot.

    This table is separate from real_books and never represents orders, fills,
    cash, positions, or simulated account state.
    """
    sessions = report.pop("evidenceSessions", [])
    if not sessions:
        # Do not accumulate empty runs caused by temporarily missing archive data.
        return report
    evidence = {"leader": report.get("leader"), "asset": report.get("asset"),
                "range": report.get("range"), "hypothesis": hypothesis,
                "sessions": sessions}
    canonical = json.dumps(evidence, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    fingerprint = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    run_id = "replay-" + uuid.uuid4().hex
    generated_at = datetime.now(timezone.utc).isoformat()
    report.update({"replayId": run_id, "generatedAt": generated_at,
                   "inputFingerprint": fingerprint,
                   "evidenceSessionCount": len(sessions)})
    report_fingerprint = hashlib.sha256(json.dumps(report, ensure_ascii=False, sort_keys=True,
        separators=(",", ":")).encode("utf-8")).hexdigest()
    report["reportFingerprint"] = report_fingerprint
    database.put_research(run_id, {"kind": "cross_market_point_in_time_replay",
        "generatedAt": generated_at, "inputFingerprint": fingerprint,
        "reportFingerprint": report_fingerprint,
        "request": {"leader": report.get("leader"), "asset": report.get("asset"),
                    "range": report.get("range"), "hypothesis": hypothesis},
        "report": report, "snapshotEncoding": "gzip+base64",
        "evidenceSnapshot": base64.b64encode(gzip.compress(canonical.encode("utf-8"), mtime=0)).decode("ascii")})
    return report


def restore_replay(database, run_id):
    """Retrieve and integrity-check a previously saved replay evidence bundle."""
    record = database.get_research(run_id)
    if not record or record.get("kind") != "cross_market_point_in_time_replay":
        return None
    if record.get("snapshotEncoding") != "gzip+base64":
        raise ValueError("unsupported replay evidence encoding")
    try:
        raw = gzip.decompress(base64.b64decode(record["evidenceSnapshot"], validate=True))
        evidence = json.loads(raw)
    except (KeyError, ValueError, OSError, EOFError, json.JSONDecodeError, zlib.error) as error:
        raise ValueError("replay evidence snapshot is unreadable") from error
    if not isinstance(evidence, dict) or not isinstance(evidence.get("sessions"), list):
        raise ValueError("replay evidence snapshot has invalid structure")
    fingerprint = hashlib.sha256(json.dumps(evidence, ensure_ascii=False, sort_keys=True,
        separators=(",", ":")).encode("utf-8")).hexdigest()
    if fingerprint != record.get("inputFingerprint"):
        raise ValueError("replay evidence fingerprint mismatch")
    report = record.get("report")
    if not isinstance(report, dict):
        raise ValueError("replay report is unreadable")
    report_body = {key: value for key, value in report.items() if key != "reportFingerprint"}
    report_fingerprint = hashlib.sha256(json.dumps(report_body, ensure_ascii=False, sort_keys=True,
        separators=(",", ":")).encode("utf-8")).hexdigest()
    if report_fingerprint != record.get("reportFingerprint") or report_fingerprint != report.get("reportFingerprint"):
        raise ValueError("replay report fingerprint mismatch")
    return {**record, "request": {"leader": evidence.get("leader"), "asset": evidence.get("asset"),
                                  "range": evidence.get("range"), "hypothesis": evidence.get("hypothesis")},
            "evidenceSessions": evidence.get("sessions", [])}


def minute_stats(database, code, now=None):
    """Build the exact research wire shape consumed by the iOS advisor.

    Tencent reports cumulative minute volume. We difference it in the archive
    worker, then validate each session sum against daily archive volume before
    using those rows for VWAP or volatility statistics.
    """
    now = now or datetime.now(timezone.utc)
    now_ms = int(now.timestamp() * 1000)
    daily = database.get_daily(code) or {}
    daily_by_day = {row.get("date"): row for row in daily.get("bars", [])
                    if isinstance(row, dict) and isinstance(row.get("date"), str)}
    with database.connect() as db:
        lower_bound = (now.astimezone(CN).date() - timedelta(days=240)).isoformat()
        raw_rows = db.execute("SELECT stamp, body, fetched_at FROM minute_archive WHERE code=? AND stamp>=? ORDER BY stamp",
                              (code, lower_bound)).fetchall()
    grouped = defaultdict(list)
    fetched = {}
    for stamp_text, body, fetched_at in raw_rows:
        try:
            row = json.loads(body)
            stamp = datetime.fromisoformat(row["timestamp"])
            if stamp.tzinfo is None or int(stamp.timestamp() * 1000) > now_ms:
                continue
            local = stamp.astimezone(CN)
            clock = local.time()
            if local.weekday() >= 5 or not (time(9, 30) <= clock < time(11, 30) or time(13) <= clock < time(15)):
                continue
            price = Decimal(str(row["price"]))
            volume = Decimal(str(row["volume"])) if row.get("volume") is not None else None
            if not price.is_finite() or price <= 0 or (volume is not None and (not volume.is_finite() or volume < 0)):
                continue
            key = local.date().isoformat()
            grouped[key].append((stamp, price, volume))
            fetched[key] = max(fetched.get(key, 0), milliseconds(fetched_at) or 0)
        except (KeyError, TypeError, ValueError, InvalidOperation, OverflowError):
            continue

    sessions = []
    for day in sorted(grouped)[-120:]:
        points = sorted(grouped[day], key=lambda item: item[0])
        bar = daily_by_day.get(day)
        try:
            daily_volume = Decimal(str(bar["volume"])) if bar else None
            prices = [p for _, p, _ in points]
            valid_volumes = [v for _, _, v in points if v is not None]
            observed_volume = sum(valid_volumes, Decimal(0))
            coverage = len(valid_volumes) / max(1, len(points))
            mismatch = (abs(observed_volume - daily_volume) / daily_volume
                        if daily_volume and daily_volume > 0 else None)
            # 1% tolerance accounts for first-minute delta and provider refresh
            # timing. Outside it, the day cannot support VWAP calculations.
            verified = len(points) >= 200 and coverage >= 0.98 and mismatch is not None and mismatch <= Decimal("0.01")
            vwap = (sum((p * v for _, p, v in points if v is not None), Decimal(0)) / observed_volume
                    if verified and observed_volume > 0 else None)
            crossings = 0
            if vwap is not None:
                sides = [1 if price > vwap else -1 if price < vwap else 0 for price in prices]
                sides = [side for side in sides if side]
                crossings = sum(1 for left, right in zip(sides, sides[1:]) if left != right)
            low = Decimal(str(bar["low"])) if bar else min(prices)
            high = Decimal(str(bar["high"])) if bar else max(prices)
            sessions.append({"day": day, "points": points, "prices": prices, "vwap": vwap,
                             "low": low, "high": high, "volumeCoverage": coverage,
                             "roundTrips": crossings // 2, "verified": verified,
                             "fetchedAt": fetched.get(day, 0)})
        except (KeyError, TypeError, ValueError, InvalidOperation, ZeroDivisionError):
            continue

    sessions = sessions[-120:]
    verified_sessions = [row for row in sessions if row["verified"]]
    last_day = sessions[-1]["day"] if sessions else None
    last_stamp = max((int(row["points"][-1][0].timestamp() * 1000) for row in sessions if row["points"]), default=None)
    age_minutes = max(0.0, (now_ms - last_stamp) / 60000) if last_stamp else None
    stale = age_minutes is None or age_minutes > 36 * 60
    freshness = {"lastDay": last_day, "ageMinutes": age_minutes,
                 "isToday": last_day == now.astimezone(CN).date().isoformat() if last_day else False,
                 "stale": stale, "reason": "分钟归档超过36小时或尚无样本" if stale else None}
    n = len(sessions)
    volume_coverage = len(verified_sessions) / max(1, n)
    minute_coverage = min(1.0, sum(min(len(row["points"]) / 240, 1.0) for row in sessions) / max(1, n))

    windows = {}
    for count in (5, 20, 60, 120):
        chosen = sessions[-count:]
        good = [row for row in chosen if row["verified"]]
        if not good:
            continue
        aggregate_volume = sum((sum((v for _, _, v in row["points"] if v is not None), Decimal(0)) for row in good), Decimal(0))
        aggregate_value = sum((sum((p * v for _, p, v in row["points"] if v is not None), Decimal(0)) for row in good), Decimal(0))
        if aggregate_volume <= 0:
            continue
        daily_vwaps = [float(row["vwap"]) for row in good]
        amplitudes = [(float(row["high"] - row["low"]) / float(row["low"]) * 100) for row in good if row["low"] > 0]
        close = Decimal(str(daily_by_day.get(good[-1]["day"], {}).get("close", good[-1]["prices"][-1])))
        close_vs_vwap = (float((close / (aggregate_value / aggregate_volume) - 1) * 100))
        lows = sorted(float(row["low"]) for row in good)
        highs = sorted(float(row["high"]) for row in good)
        returns = [float(Decimal(str(daily_by_day[day]["close"])) / Decimal(str(daily_by_day[prior]["close"])) - 1)
                   for prior, day in zip([r["day"] for r in good], [r["day"] for r in good][1:])
                   if day in daily_by_day and prior in daily_by_day and Decimal(str(daily_by_day[prior]["close"])) > 0]
        price = lambda value: format(Decimal(str(value)).quantize(Decimal("0.0001")), "f")
        windows[str(count)] = {
            "window": count, "daysUsed": len(good), "dayCoverage": len(good) / max(1, len(chosen)),
            "minuteCoverage": min(1.0, sum(min(len(row["points"]) / 240, 1.0) for row in good) / max(1, len(good))),
            "vwap": price(aggregate_value / aggregate_volume), "closeVsVwapPercent": close_vs_vwap,
            "amplitudeMedianPercent": median(amplitudes) if amplitudes else None,
            "roundTripsMedian": median([row["roundTrips"] for row in good]),
            "support": price(lows[0]), "resistance": price(highs[-1]),
            "supportP10": price(lows[max(0, int((len(lows) - 1) * .10))]),
            "resistanceP90": price(highs[min(len(highs) - 1, int((len(highs) - 1) * .90))]),
            "volatilityPercent": pstdev(returns) * 100 if len(returns) > 1 else None,
            "vwapHighDeviationMedian": median([max((float(p / row["vwap"] - 1) for p in row["prices"]), default=0) for row in good]),
            "vwapLowDeviationMedian": median([min((float(p / row["vwap"] - 1) for p in row["prices"]), default=0) for row in good]),
            "volumeCoverage": sum(row["volumeCoverage"] for row in good) / len(good)}

    enough = len(sessions) >= 60 and volume_coverage >= 0.8 and minute_coverage >= 0.8
    return {"days": n, "minutes": sum(len(row["points"]) for row in sessions), "lastDay": last_day,
            "quality": {"days": len(verified_sessions), "minuteCoverage": minute_coverage,
                        "hasVolume": bool(verified_sessions), "enoughForLongTerm": enough,
                        "volumeCoverage": volume_coverage}, "freshness": freshness,
            "windows": windows, "roundTripEvidence": None}


def milliseconds(stamp):
    try:
        value = datetime.fromisoformat(stamp)
        if value.tzinfo is None:
            return None
        return int(value.timestamp() * 1000)
    except (TypeError, ValueError, OverflowError):
        return None


def price_units(value):
    try:
        number = Decimal(str(value)) * 10000
        if not number.is_finite() or number <= 0 or number != number.to_integral_value():
            return None
        result = int(number)
        return result if result < 2**53 else None
    except (InvalidOperation, TypeError, ValueError, OverflowError):
        return None


def minute_summary(rows, now_ms):
    """Raw timestamp/point completeness only; validated volume is in minute_stats."""
    by_day = defaultdict(set)
    for raw in rows:
        try:
            row = json.loads(raw[0]); stamp = datetime.fromisoformat(row["timestamp"])
            if stamp.tzinfo is None or not price_units(row.get("price")):
                continue
            local = stamp.astimezone(CN); clock = local.time()
            if (int(stamp.timestamp() * 1000) > now_ms or local.weekday() >= 5 or
                    not (time(9, 30) <= clock < time(11, 30) or time(13) <= clock < time(15))):
                continue
            by_day[local.date().isoformat()].add(local.strftime("%H:%M"))
        except (KeyError, TypeError, ValueError, OverflowError):
            continue
    sessions = sorted(by_day)[-120:]
    complete = sum(len(by_day[day]) >= 200 for day in sessions)
    return {"source": "guanpan2 archived Tencent minute prices", "sessions": len(sessions),
            "samplePoints": sum(len(by_day[day]) for day in sessions),
            "firstDay": sessions[0] if sessions else None,
            "lastDay": sessions[-1] if sessions else None,
            "completeMinuteDays": complete,
            "volumeCoverage": None, "minuteEvidence": [],
            "windows": {str(n): {"available": len(sessions) >= n,
                                   "sessions": min(n, len(sessions))} for n in (5, 20, 60, 120)},
            "status": "raw-archive-only", "pricePlansAllowed": False,
            "limitations": ["本字段只描述分钟时间点覆盖；分钟量校验及VWAP见同响应 minuteStats"]}


def snapshot(database, now=None):
    now = now or datetime.now(timezone.utc)
    now_ms = int(now.timestamp() * 1000)
    with database.connect() as db:
        codes = [row[0] for row in db.execute(
            "SELECT code FROM tracked_instruments UNION SELECT code FROM daily_bars "
            "UNION SELECT DISTINCT code FROM minute_archive ORDER BY code LIMIT 60").fetchall()]
    instruments = []
    for code in codes:
        bars = []
        stored = database.get_daily(code)
        available_at = milliseconds(stored.get("fetchedAt")) if stored else None
        for item in (stored or {}).get("bars", [])[-640:]:
            day = item.get("date")
            at = milliseconds(day + "T15:00:00+08:00") if isinstance(day, str) else None
            values = {key: price_units(item.get(key)) for key in ("open", "high", "low", "close")}
            if at is None or at > now_ms or any(value is None for value in values.values()):
                continue
            if available_at is None or available_at > now_ms:
                continue
            bars.append({"at": at, "availableAt": available_at, **values})
        with database.connect() as db:
            minutes = db.execute("SELECT body FROM minute_archive WHERE code=? ORDER BY stamp DESC LIMIT 30000", (code,)).fetchall()
        asset = "etf" if code.startswith(("15", "16", "50", "51", "52", "56", "58", "59")) and not code.startswith("508") else "stock"
        row = {"symbol": code, "asset": asset, "source": "guanpan2 NAS archive",
               "evidenceIDs": ["guanpan2:" + code], "bars": bars,
               "intradayResearch": minute_summary(minutes, now_ms),
               "minuteStats": minute_stats(database, code, now)}
        instruments.append(row)
    research = {"asOf": now_ms, "scope": "NAS archived tracked symbols; phone filters to real holdings",
                "universeComplete": False, "instruments": instruments, "books": [],
                "news": [], "availabilityNote": "只读历史证据；VWAP仅在分钟量与日K成交量交叉校验通过后计算，未达到60个有效交易日不支持具体计划"}
    return {"ok": True, "source": "guanpan2-read-only-adapter", "generatedAt": now.isoformat(),
            "revision": 0, "data": {"quality": {"researchSnapshot": research}}}
