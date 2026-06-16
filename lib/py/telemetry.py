#!/usr/bin/env python3
"""Activity logging, health checks, dev stats, manager reports, Goodview sync."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _run_git(args: list[str], cwd: str) -> str:
    try:
        return subprocess.check_output(
            ["git", *args],
            cwd=cwd,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except Exception:
        return ""


def git_developer(root: str) -> dict[str, str]:
    email = _run_git(["config", "user.email"], root)
    name = _run_git(["config", "user.name"], root)
    return {"developer_email": email, "developer_name": name}


def git_context(root: str) -> dict[str, Any]:
    branch = _run_git(["branch", "--show-current"], root) or "?"
    dirty = bool(_run_git(["status", "--porcelain"], root))
    staged = bool(_run_git(["diff", "--cached", "--name-only"], root))
    conflicts = [
        line
        for line in _run_git(["diff", "--name-only", "--diff-filter=U"], root).splitlines()
        if line.strip()
    ]
    ahead = behind = 0
    if branch and branch != "?":
        ahead_s = _run_git(["rev-list", f"origin/{branch}..HEAD", "--count"], root)
        behind_s = _run_git(["rev-list", f"HEAD..origin/{branch}", "--count"], root)
        ahead = int(ahead_s or "0") if ahead_s.isdigit() else 0
        behind = int(behind_s or "0") if behind_s.isdigit() else 0
    last_commit_at = _run_git(["log", "-1", "--format=%cI"], root)
    unpushed = ahead
    return {
        "branch": branch,
        "dirty": dirty,
        "staged": staged,
        "conflicts": len(conflicts),
        "conflict_files": conflicts[:10],
        "ahead": ahead,
        "behind": behind,
        "unpushed_commits": unpushed,
        "last_commit_at": last_commit_at or None,
    }


def tool_status() -> dict[str, bool]:
    def has(cmd: str) -> bool:
        return shutil.which(cmd) is not None

    ollama_ok = False
    if has("ollama"):
        try:
            subprocess.run(["ollama", "list"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            ollama_ok = True
        except Exception:
            pass
    gh_ok = False
    if has("gh"):
        try:
            subprocess.run(["gh", "auth", "status"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            gh_ok = True
        except Exception:
            pass
    return {"ollama": ollama_ok, "gh": gh_ok, "python3": has("python3"), "curl": has("curl")}


def dev_server_status(good_dir: str) -> dict[str, Any]:
    pid_file = os.path.join(good_dir, "dev.pid")
    log_file = os.path.join(good_dir, "dev.log")
    pid = None
    active = False
    if os.path.isfile(pid_file):
        try:
            pid = int(open(pid_file).read().strip())
            os.kill(pid, 0)
            active = True
        except (ValueError, ProcessLookupError, PermissionError, OSError):
            active = False
    return {
        "dev_active": active,
        "dev_pid": pid,
        "dev_log": log_file if os.path.isfile(log_file) else None,
    }


def compute_health(root: str, good_dir: str) -> dict[str, Any]:
    ctx = git_context(root)
    tools = tool_status()
    dev = dev_server_status(good_dir)
    score = 100
    issues: list[str] = []
    warnings: list[str] = []

    if ctx["conflicts"]:
        score -= 40
        issues.append(f"{ctx['conflicts']} fichier(s) en conflit")
    if ctx["behind"] > 0:
        score -= 15
        warnings.append(f"{ctx['behind']} commit(s) distants non intégrés")
    if ctx["ahead"] > 5:
        score -= 10
        warnings.append(f"{ctx['ahead']} commit(s) locaux non pushés")
    if ctx["dirty"]:
        score -= 10
        warnings.append("Modifications locales non commitées")
    if not tools["ollama"]:
        score -= 5
        warnings.append("Ollama indisponible (commits IA / resolve)")
    if not tools["gh"]:
        warnings.append("GitHub CLI non authentifié")
    if not dev["dev_active"] and os.path.isfile(os.path.join(root, "composer.json")):
        warnings.append("Serveur de dev inactif")

    score = max(0, min(100, score))
    level = "healthy" if score >= 80 else "warning" if score >= 50 else "critical"

    return {
        "ts": _now_iso(),
        "score": score,
        "level": level,
        "git": ctx,
        "tools": tools,
        "dev": dev,
        "issues": issues,
        "warnings": warnings,
    }


def append_event(
    activity_path: str,
    cmd: str,
    status: str,
    duration_ms: int,
    root: str,
    meta: dict | None = None,
) -> dict:
    os.makedirs(os.path.dirname(activity_path), exist_ok=True)
    dev = git_developer(root)
    ctx = git_context(root)
    event = {
        "id": str(uuid.uuid4()),
        "ts": _now_iso(),
        "cmd": cmd,
        "status": status,
        "duration_ms": duration_ms,
        "branch": ctx.get("branch"),
        **dev,
        "meta": meta or {},
        "synced": False,
    }
    with open(activity_path, "a") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")
    try:
        os.chmod(activity_path, 0o600)
    except OSError:
        pass
    return event


def load_events(activity_path: str) -> list[dict]:
    if not os.path.isfile(activity_path):
        return []
    events = []
    with open(activity_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def filter_events(events: list[dict], since_days: int) -> list[dict]:
    cutoff = datetime.now(timezone.utc) - timedelta(days=since_days)
    out = []
    for ev in events:
        ts = ev.get("ts")
        if not ts:
            continue
        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            if dt >= cutoff:
                out.append(ev)
        except ValueError:
            continue
    return out


def aggregate_stats(events: list[dict]) -> dict[str, Any]:
    by_cmd: dict[str, int] = {}
    by_status: dict[str, int] = {}
    by_day: dict[str, int] = {}
    ai_commits = 0
    total_duration = 0
    developers: dict[str, dict] = {}

    for ev in events:
        cmd = ev.get("cmd", "?")
        status = ev.get("status", "?")
        by_cmd[cmd] = by_cmd.get(cmd, 0) + 1
        by_status[status] = by_status.get(status, 0) + 1
        total_duration += int(ev.get("duration_ms") or 0)
        day = (ev.get("ts") or "")[:10]
        if day:
            by_day[day] = by_day.get(day, 0) + 1
        meta = ev.get("meta") or {}
        if cmd == "commit" and meta.get("ai_used"):
            ai_commits += 1
        email = ev.get("developer_email") or "unknown"
        if email not in developers:
            developers[email] = {
                "name": ev.get("developer_name") or email,
                "events": 0,
                "commits": 0,
                "pushes": 0,
                "syncs": 0,
                "resolves": 0,
                "ai_edits": 0,
            }
        developers[email]["events"] += 1
        if cmd == "commit" and status == "ok":
            developers[email]["commits"] += 1
        elif cmd == "push" and status == "ok":
            developers[email]["pushes"] += 1
        elif cmd == "sync" and status == "ok":
            developers[email]["syncs"] += 1
        elif cmd == "resolve" and status == "ok":
            developers[email]["resolves"] += 1
        elif cmd in ("ai", "do") and meta.get("intent") == "edit" and status == "ok":
            developers[email]["ai_edits"] += 1

    return {
        "total_events": len(events),
        "by_cmd": dict(sorted(by_cmd.items(), key=lambda x: -x[1])),
        "by_status": by_status,
        "by_day": dict(sorted(by_day.items())),
        "ai_commits": ai_commits,
        "avg_duration_ms": int(total_duration / len(events)) if events else 0,
        "developers": developers,
    }


def format_health(health: dict) -> str:
    lines = [
        "=== Santé du projet ===",
        "",
        f"Score     : {health['score']}/100 ({health['level']})",
        f"Branche   : {health['git']['branch']}",
    ]
    git = health["git"]
    if git["dirty"]:
        lines.append("Git       : ✗ modifications locales non commitées")
    else:
        lines.append("Git       : ✓ working tree propre")
    if git["conflicts"]:
        lines.append(f"Conflits  : ✗ {git['conflicts']} fichier(s)")
    elif git["behind"]:
        lines.append(f"Distant   : ! {git['behind']} commit(s) en retard")
    elif git["ahead"]:
        lines.append(f"Distant   : ↑ {git['ahead']} commit(s) en avance")
    else:
        lines.append("Distant   : ✓ à jour")
    tools = health["tools"]
    lines.append(f"Ollama    : {'✓' if tools['ollama'] else '✗'}")
    lines.append(f"GitHub    : {'✓' if tools['gh'] else '✗'}")
    dev = health["dev"]
    if dev["dev_active"]:
        lines.append(f"Dev server: ✓ actif (PID {dev['dev_pid']})")
    else:
        lines.append("Dev server: ○ inactif")
    if health["issues"]:
        lines.extend(["", "Problèmes :"])
        for i in health["issues"]:
            lines.append(f"  ✗ {i}")
    if health["warnings"]:
        lines.extend(["", "Attention :"])
        for w in health["warnings"]:
            lines.append(f"  ! {w}")
    return "\n".join(lines)


def format_stats(stats: dict, since_days: int) -> str:
    agg = stats["aggregate"]
    lines = [
        f"=== Activité good (derniers {since_days} jours) ===",
        "",
        f"Événements totaux : {agg['total_events']}",
        f"Commits via IA    : {agg['ai_commits']}",
        f"Durée moyenne     : {agg['avg_duration_ms']} ms",
        "",
        "Par commande :",
    ]
    for cmd, count in agg["by_cmd"].items():
        lines.append(f"  {cmd:10} {count}")
    if agg["by_day"]:
        lines.extend(["", "Par jour :"])
        for day, count in agg["by_day"].items():
            lines.append(f"  {day}  {count} événement(s)")
    lines.extend(["", "Ton activité :"])
    for email, dev in agg["developers"].items():
        if len(agg["developers"]) == 1 or email != "unknown":
            lines.append(
                f"  {dev['name']} — {dev['commits']} commit(s), "
                f"{dev['pushes']} push, {dev['syncs']} sync, "
                f"{dev['resolves']} resolve, {dev['ai_edits']} edit(s) IA"
            )
    return "\n".join(lines)


def format_report(report: dict, since_days: int) -> str:
    agg = report["aggregate"]
    health = report["health"]
    project = report.get("project_name") or "Projet local"
    lines = [
        f"=== Rapport manager — {project} — {since_days} derniers jours ===",
        "",
        "Activité équipe",
        f"  Événements    : {agg['total_events']}",
        f"  Commits       : {agg['by_cmd'].get('commit', 0)} ({agg['ai_commits']} via IA)",
        f"  Push          : {agg['by_cmd'].get('push', 0)}",
        f"  Sync          : {agg['by_cmd'].get('sync', 0)}",
        f"  Resolve       : {agg['by_cmd'].get('resolve', 0)}",
        f"  Actions IA    : {agg['by_cmd'].get('ai', 0) + agg['by_cmd'].get('do', 0)}",
        "",
        f"Santé actuelle : {health['score']}/100 ({health['level']})",
    ]
    if health["git"]["dirty"]:
        lines.append("  ! Modifications locales en cours")
    if health["git"]["conflicts"]:
        lines.append(f"  ✗ {health['git']['conflicts']} conflit(s) ouvert(s)")
    if agg["developers"]:
        lines.extend(["", "Développeurs :"])
        for email, dev in sorted(agg["developers"].items(), key=lambda x: -x[1]["events"]):
            lines.append(
                f"  {dev['name']:<20} {dev['events']:3} actions — "
                f"{dev['commits']}c {dev['pushes']}p {dev['syncs']}s {dev['resolves']}r {dev['ai_edits']}e"
            )
    sync = report.get("sync", {})
    if sync:
        lines.extend(["", "Sync Goodview :"])
        if sync.get("ok"):
            lines.append(f"  ✓ {sync.get('synced_count', 0)} événement(s) synchronisé(s)")
        else:
            lines.append(f"  ✗ {sync.get('error', 'échec')}")
    return "\n".join(lines)


def get_unsynced(events: list[dict]) -> list[dict]:
    return [e for e in events if not e.get("synced")]


def mark_synced(activity_path: str, event_ids: list[str]) -> None:
    if not event_ids or not os.path.isfile(activity_path):
        return
    ids = set(event_ids)
    lines_out = []
    with open(activity_path) as f:
        for line in f:
            raw = line.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
            except json.JSONDecodeError:
                lines_out.append(line)
                continue
            if ev.get("id") in ids:
                ev["synced"] = True
            lines_out.append(json.dumps(ev, ensure_ascii=False) + "\n")
    with open(activity_path, "w") as f:
        f.writelines(lines_out)


def build_sync_payload(
    project_id: int,
    events: list[dict],
    health: dict,
    report_summary: dict,
    cli_version: str,
) -> dict:
    return {
        "project_id": project_id,
        "cli_version": cli_version,
        "health_snapshot": health,
        "report_summary": report_summary,
        "events": [
            {
                "id": e.get("id"),
                "ts": e.get("ts"),
                "cmd": e.get("cmd"),
                "status": e.get("status"),
                "duration_ms": e.get("duration_ms"),
                "branch": e.get("branch"),
                "developer_email": e.get("developer_email"),
                "developer_name": e.get("developer_name"),
                "meta": e.get("meta") or {},
            }
            for e in events
        ],
    }


def cmd_append(argv: list[str]) -> None:
    root, activity_path, cmd, status, duration_ms = argv[2:7]
    meta = {}
    if len(argv) > 7 and argv[7]:
        meta = json.loads(argv[7])
    ev = append_event(activity_path, cmd, status, int(duration_ms), root, meta)
    print(json.dumps({"id": ev["id"]}, ensure_ascii=False))


def cmd_health(argv: list[str]) -> None:
    root, good_dir = argv[2], argv[3]
    print(format_health(compute_health(root, good_dir)))


def cmd_stats(argv: list[str]) -> None:
    root, activity_path, since_days = argv[2], argv[3], int(argv[4])
    events = filter_events(load_events(activity_path), since_days)
    stats = {"aggregate": aggregate_stats(events), "since_days": since_days}
    print(format_stats(stats, since_days))


def cmd_report(argv: list[str]) -> None:
    root, good_dir, activity_path, since_days = argv[2], argv[3], argv[4], int(argv[5])
    project_name = argv[6] if len(argv) > 6 else ""
    events = filter_events(load_events(activity_path), since_days)
    health = compute_health(root, good_dir)
    agg = aggregate_stats(events)
    report = {
        "aggregate": agg,
        "health": health,
        "project_name": project_name,
        "since_days": since_days,
    }
    print(format_report(report, since_days))


def cmd_build_sync(argv: list[str]) -> None:
    project_id, root, good_dir, activity_path, cli_version = argv[2:7]
    since_days = int(argv[7]) if len(argv) > 7 else 7
    events = get_unsynced(load_events(activity_path))
    health = compute_health(root, good_dir)
    recent = filter_events(events, since_days)
    agg = aggregate_stats(recent if recent else events)
    payload = build_sync_payload(
        int(project_id),
        events[:100],
        health,
        {"since_days": since_days, **agg},
        cli_version,
    )
    print(json.dumps(payload, ensure_ascii=False))


def cmd_mark_synced(argv: list[str]) -> None:
    activity_path = argv[2]
    ids = json.loads(argv[3])
    mark_synced(activity_path, ids)
    print(json.dumps({"marked": len(ids)}, ensure_ascii=False))


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(2)
    action = sys.argv[1]
    handlers = {
        "append": cmd_append,
        "health": cmd_health,
        "stats": cmd_stats,
        "report": cmd_report,
        "build-sync": cmd_build_sync,
        "mark-synced": cmd_mark_synced,
    }
    handler = handlers.get(action)
    if not handler:
        sys.exit(2)
    handler(sys.argv)


if __name__ == "__main__":
    main()
