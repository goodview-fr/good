#!/usr/bin/env bash
# Activity telemetry, health, stats, report, Goodview sync

_good_activity_file() {
    echo "$(_good_config_dir)/activity.jsonl"
}

_good_telemetry_enabled() {
    if [ "${GOOD_TELEMETRY:-}" = "0" ]; then
        return 1
    fi
    local config_file enabled
    config_file="$(_good_config_file)"
    if [ ! -f "$config_file" ]; then
        return 0
    fi
    enabled="$(python3 - "$config_file" <<'PY' 2>/dev/null || echo "true"
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    print("true" if data.get("telemetry_enabled", True) else "false")
except Exception:
    print("true")
PY
)"
    [ "$enabled" = "true" ]
}

_good_event_meta() {
    # Set metadata for the next logged event (JSON string)
    # shellcheck disable=SC2034
    GOOD_EVENT_META="${1:-{}}"
}

_good_record_event() {
    local cmd="$1" status="$2" duration_ms="${3:-0}" meta="${4:-{}}"
    _good_telemetry_enabled || return 0
    _good_require_python
    local root activity
    root="$(_good_root)"
    activity="$(_good_activity_file)"
    mkdir -p "$(_good_config_dir)"
    python3 "$GOOD_LIB/py/telemetry.py" append \
        "$root" "$activity" "$cmd" "$status" "$duration_ms" "$meta" >/dev/null 2>&1 || true
    _good_telemetry_sync_background
}

_good_telemetry_sync_background() {
    _good_telemetry_enabled || return 0
    [ -f "$(_good_config_file)" ] || return 0
    (
        _good_telemetry_sync 2>/dev/null || true
    ) &
}

_good_telemetry_sync() {
    local token project_id config_file activity payload response synced_ids
    _good_require_python
    _good_require_curl
    config_file="$(_good_config_file)"
    [ -f "$config_file" ] || return 0
    token="$(_good_load_config_value token 2>/dev/null || true)"
    project_id="$(_good_load_config_value project_id 2>/dev/null || true)"
    [ -n "$token" ] && [ -n "$project_id" ] || return 0
    activity="$(_good_activity_file)"
    [ -f "$activity" ] || return 0

    payload="$(python3 "$GOOD_LIB/py/telemetry.py" build-sync \
        "$project_id" "$(_good_root)" "$(_good_config_dir)" "$activity" "$VERSION" 7 2>/dev/null)" || return 1
    [ -n "$payload" ] || return 0

    if ! python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get("events") else 1)' "$payload" 2>/dev/null; then
        return 0
    fi

    response="$(_good_api_request POST "/v1/admin/good-cli/events" "$token" "$payload")"
    if ! python3 - "$response" <<'PY' >/dev/null 2>&1; then
import json, sys
try:
    data = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(1)
sys.exit(0 if data.get("data") is not None or data.get("ok") else 1)
PY
        return 1
    fi

    synced_ids="$(python3 - "$payload" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
print(json.dumps([e["id"] for e in data.get("events") or [] if e.get("id")]))
PY
)"
    python3 "$GOOD_LIB/py/telemetry.py" mark-synced "$activity" "$synced_ids" >/dev/null 2>&1 || true
    return 0
}

_good_map_exit_status() {
    local exit_code="$1"
    if [ "$exit_code" -eq 0 ]; then
        echo "ok"
    else
        echo "fail"
    fi
}

_good_run_command() {
    local cmd="$1"
    shift
    local start end duration_ms exit_code status meta
    # shellcheck disable=SC2034
    GOOD_EVENT_META="{}"
    start=$(date +%s 2>/dev/null || echo 0)
    set +e
    _good_dispatch "$cmd" "$@"
    exit_code=$?
    set -e
    end=$(date +%s 2>/dev/null || echo 0)
    duration_ms=$(( (end - start) * 1000 ))
    status="$(_good_map_exit_status "$exit_code")"
    meta="${GOOD_EVENT_META:-{}}"
    case "$cmd" in
        health|stats|report|help|-h|--help|--version|-v) ;;
        *)
            _good_record_event "$cmd" "$status" "$duration_ms" "$meta"
            ;;
    esac
    return "$exit_code"
}

cmd_health() {
    _good_require_python
    if git rev-parse --git-dir > /dev/null 2>&1; then
        :
    else
        echo "Pas de dépôt git — santé limitée aux outils."
    fi
    python3 "$GOOD_LIB/py/telemetry.py" health "$(_good_root)" "$(_good_config_dir)"
}

cmd_stats() {
    _good_require_python
    _check_git
    local since_days=7
    while [ $# -gt 0 ]; do
        case "$1" in
            --days) since_days="$2"; shift 2 ;;
            --sync) _good_telemetry_sync; shift ;;
            -h|--help)
                echo "Usage: good stats [--days N] [--sync]"
                echo "  Vue développeur — activité good sur la période."
                exit 0
                ;;
            *) echo "Option inconnue: $1" >&2; exit 1 ;;
        esac
    done
    python3 "$GOOD_LIB/py/telemetry.py" stats "$(_good_root)" "$(_good_activity_file)" "$since_days"
}

cmd_report() {
    _good_require_python
    _check_git
    local since_days=7 do_sync=0 project_name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --days) since_days="$2"; shift 2 ;;
            --sync) do_sync=1; shift ;;
            -h|--help)
                echo "Usage: good report [--days N] [--sync]"
                echo "  Vue manager — synthèse équipe + santé + sync Goodview."
                exit 0
                ;;
            *) echo "Option inconnue: $1" >&2; exit 1 ;;
        esac
    done
    if [ -f "$(_good_config_file)" ]; then
        project_name="$(_good_load_config_value project_id 2>/dev/null || true)"
        if [ -n "$project_name" ]; then
            project_name="Projet #$project_name"
        fi
    fi
    if [ "$do_sync" -eq 1 ]; then
        if _good_telemetry_sync; then
            echo "✓ Sync Goodview terminé."
        else
            echo "! Sync Goodview en attente (API indisponible ou aucun événement)."
        fi
        echo ""
    fi
    python3 "$GOOD_LIB/py/telemetry.py" report \
        "$(_good_root)" "$(_good_config_dir)" "$(_good_activity_file)" "$since_days" "$project_name"
}

cmd_telemetry() {
    local sub="${1:-status}"
    shift || true
    case "$sub" in
        on)
            _good_set_telemetry 1
            echo "✓ Télémétrie activée."
            ;;
        off)
            _good_set_telemetry 0
            echo "✓ Télémétrie désactivée (local uniquement, pas de nouveaux events)."
            ;;
        sync)
            if _good_telemetry_sync; then
                echo "✓ Événements synchronisés vers Goodview."
            else
                echo "Erreur ou rien à synchroniser. Vérifie 'good init' et la connexion."
                exit 1
            fi
            ;;
        status|*)
            if _good_telemetry_enabled; then
                echo "Télémétrie : activée"
            else
                echo "Télémétrie : désactivée"
            fi
            local activity count unsynced
            activity="$(_good_activity_file)"
            if [ -f "$activity" ]; then
                count="$(wc -l < "$activity" | tr -d ' ')"
                unsynced="$(python3 - "$activity" <<'PY'
import json, sys
n = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            if not json.loads(line).get("synced"):
                n += 1
        except json.JSONDecodeError:
            pass
print(n)
PY
)"
                echo "Événements locaux : $count ($unsynced en attente de sync)"
            else
                echo "Événements locaux : aucun"
            fi
            ;;
    esac
}

_good_set_telemetry() {
    local enabled="$1" config_file
    _good_require_python
    config_file="$(_good_config_file)"
    if [ ! -f "$config_file" ]; then
        echo "Pas de config .good — lance 'good init' ou travaille dans un dépôt git."
        exit 1
    fi
    python3 - "$config_file" "$enabled" <<'PY'
import json, sys, os
path, enabled = sys.argv[1], sys.argv[2] == "1"
with open(path) as f:
    data = json.load(f)
data["telemetry_enabled"] = enabled
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PY
}

_good_commit_meta() {
    local root files ins del
    root="$(_good_root)"
    files=$(git diff HEAD~1 --name-only 2>/dev/null | wc -l | tr -d ' ')
    ins=$(git diff HEAD~1 --shortstat 2>/dev/null | sed -n 's/.* \([0-9][0-9]*\) insertion.*/\1/p')
    del=$(git diff HEAD~1 --shortstat 2>/dev/null | sed -n 's/.* \([0-9][0-9]*\) deletion.*/\1/p')
    _good_event_meta "$(python3 -c 'import json,sys; print(json.dumps({"ai_used":True,"files_changed":int(sys.argv[1] or 0),"insertions":int(sys.argv[2] or 0),"deletions":int(sys.argv[3] or 0)}))' "${files:-0}" "${ins:-0}" "${del:-0}")"
}
