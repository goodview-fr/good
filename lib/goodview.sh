#!/usr/bin/env bash
# Goodview integration
_good_normalize_site_base() {
    local base="${1%/}"
    case "$base" in
        https://goodview.fr|http://goodview.fr)
            echo "https://www.goodview.fr"
            ;;
        *)
            echo "$base"
            ;;
    esac
}

_good_format_http_error() {
    local status="${1:-?}" body="$2"
    python3 - "$status" "$body" <<'PY'
import json, re, sys

status, body = sys.argv[1], sys.argv[2]
stripped = body.lstrip()
if stripped.startswith("{"):
    try:
        data = json.loads(body)
        print(data.get("message") or json.dumps(data, ensure_ascii=False))
        raise SystemExit(0)
    except json.JSONDecodeError:
        pass

title = re.search(r"<title[^>]*>([^<]+)</title>", body, re.I)
if title:
    print(f"HTTP {status} — {title.group(1).strip()}")
    raise SystemExit(0)

snippet = next(
    (line.strip() for line in body.splitlines() if line.strip() and not line.lstrip().startswith("<")),
    "",
)
if snippet:
    print(f"HTTP {status} — {snippet[:120]}")
else:
    print(
        f"HTTP {status} — réponse HTML inattendue "
        "(vérifier GOODVIEW_URL=https://www.goodview.fr ou GOODVIEW_API)"
    )
PY
}

_good_site_base() {
    if [ -n "${GOODVIEW_URL:-}" ]; then
        _good_normalize_site_base "${GOODVIEW_URL}"
        return
    fi
    if [ -f "$(_good_config_file)" ]; then
        local from_config
        from_config="$(python3 - "$(_good_config_file)" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f).get("site_base", ""))
PY
)"
        if [ -n "$from_config" ]; then
            _good_normalize_site_base "$from_config"
            return
        fi
    fi
    echo "https://www.goodview.fr"
}

_good_api_base() {
    if [ -n "${GOODVIEW_API:-}" ]; then
        echo "${GOODVIEW_API%/}"
        return
    fi
    if [ -f "$(_good_config_file)" ]; then
        local from_config
        from_config="$(python3 - "$(_good_config_file)" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f).get("api_base", ""))
PY
)"
        if [ -n "$from_config" ]; then
            echo "$from_config"
            return
        fi
    fi
    echo "$(_good_site_base)/api"
}

_good_require_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Erreur: python3 est requis pour good init / good info."
        exit 1
    fi
}

_good_require_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "Erreur: curl est requis pour good init / good info."
        exit 1
    fi
}

_good_open_url() {
    local url="$1"
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$url" >/dev/null 2>&1 &
    else
        echo "Ouvre cette URL dans ton navigateur :" >&2
        echo "$url" >&2
    fi
}

_good_ensure_gitignore() {
    local gitignore="$(_good_root)/.gitignore"
    if [ ! -f "$gitignore" ]; then
        printf '%s\n' '.good/' > "$gitignore"
        return
    fi
    if ! grep -qxF '.good/' "$gitignore" 2>/dev/null && ! grep -qxF '.good' "$gitignore" 2>/dev/null; then
        printf '\n# good CLI — token et liaison Goodview\n.good/\n' >> "$gitignore"
    fi
}

_good_save_config() {
    local token="$1" project_id="$2" site_base="$3" api_base="$4"
    local config_dir config_file
    config_dir="$(_good_config_dir)"
    config_file="$(_good_config_file)"
    mkdir -p "$config_dir"
    python3 - "$config_file" "$token" "$project_id" "$site_base" "$api_base" "$(_good_root)" <<'PY'
import json, sys, datetime, os
path, token, project_id, site_base, api_base, local_path = sys.argv[1:7]
data = {
    "version": 1,
    "site_base": site_base,
    "api_base": api_base,
    "token": token,
    "project_id": int(project_id),
    "local_path": local_path,
    "linked_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
    "telemetry_enabled": True,
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PY
    _good_ensure_gitignore
}

_good_load_config_value() {
    local key="$1" config_file value
    config_file="$(_good_config_file)"
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    value="$(python3 "$GOOD_LIB/py/config.py" "$config_file" "$key" 2>/dev/null)" || {
        echo "Erreur: .good/config.json absent ou invalide. Relance 'good init'." >&2
        return 1
    }
    echo "$value"
}

_good_oauth_token() {
    _good_require_python
    _good_require_curl

    local site_base api_base result_file port state redirect_uri authorize_url
    site_base="$(_good_site_base)"
    api_base="$(_good_api_base)"
    result_file="$(mktemp)"
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
    state="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
    redirect_uri="http://127.0.0.1:${port}/callback"
    authorize_url="${site_base}/gdview/authorize?client=good-cli&redirect_uri=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$redirect_uri")&state=${state}"

    python3 - "$port" "$state" "$result_file" <<'PY' &
import http.server, socketserver, urllib.parse, json, sys, threading

port, state, result_file = map(str, sys.argv[1:4])
result = {"ok": False}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        code = (params.get("code") or [None])[0]
        returned_state = (params.get("state") or [None])[0]
        error = (params.get("error") or [None])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        body = """<!DOCTYPE html>
<html lang="fr"><head><meta charset="utf-8"><title>Good CLI</title></head>
<body style="font-family:system-ui;background:#111827;color:#fff;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0">
<div style="text-align:center;max-width:24rem;padding:2rem">
<h1 style="font-size:1.125rem;margin:0 0 .5rem">Connexion réussie</h1>
<p style="color:#9ca3af;margin:0">Retourne dans le terminal, tu peux fermer cette fenêtre.</p>
</div></body></html>"""
        self.wfile.write(body.encode("utf-8"))
        if error:
            result["error"] = error
        elif code and returned_state == state:
            result.update({"ok": True, "code": code, "redirect_uri": f"http://127.0.0.1:{port}/callback"})
        else:
            result["error"] = "Réponse OAuth invalide"
        threading.Thread(target=self.server.shutdown, daemon=True).start()

with socketserver.TCPServer(("127.0.0.1", int(port)), Handler) as httpd:
    httpd.timeout = 300
    httpd.handle_request()

with open(result_file, "w") as f:
    json.dump(result, f)
PY
    local server_pid=$!

    _good_oauth_cleanup() {
        if [ -n "${server_pid:-}" ] && kill -0 "$server_pid" 2>/dev/null; then
            kill "$server_pid" 2>/dev/null || true
            wait "$server_pid" 2>/dev/null || true
        fi
    }
    trap _good_oauth_cleanup EXIT

    echo "Connexion à Goodview..." >&2
    echo "Ouvre le navigateur pour autoriser Good CLI." >&2
    _good_open_url "$authorize_url"

    local waited=0
    while [ ! -s "$result_file" ] && [ "$waited" -lt 300 ]; do
        sleep 1
        waited=$((waited + 1))
        if ! kill -0 "$server_pid" 2>/dev/null; then
            break
        fi
    done
    wait "$server_pid" 2>/dev/null || true

    if [ ! -s "$result_file" ]; then
        trap - EXIT
        _good_oauth_cleanup
        rm -f "$result_file"
        echo "Erreur: délai OAuth dépassé." >&2
        exit 1
    fi

    trap - EXIT
    _good_oauth_cleanup

    local oauth_payload token_response
    oauth_payload="$(cat "$result_file")"
    rm -f "$result_file"

    if ! python3 - "$oauth_payload" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
sys.exit(0 if data.get("ok") else 1)
PY
    then
        echo "Erreur: $(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("error","Connexion refusée"))' "$oauth_payload")" >&2
        exit 1
    fi

    token_response="$(python3 - "$oauth_payload" "$api_base" <<'PY'
import json, re, sys, urllib.error, urllib.request

def format_http_error(status, body, content_type=""):
    if "json" in content_type or body.lstrip().startswith("{"):
        try:
            data = json.loads(body)
            return data.get("message") or json.dumps(data, ensure_ascii=False)
        except json.JSONDecodeError:
            pass
    title = re.search(r"<title[^>]*>([^<]+)</title>", body, re.I)
    if title:
        return f"HTTP {status} — {title.group(1).strip()}"
    snippet = next(
        (line.strip() for line in body.splitlines() if line.strip() and not line.lstrip().startswith("<")),
        "",
    )
    if snippet:
        return f"HTTP {status} — {snippet[:120]}"
    return (
        f"HTTP {status} — réponse HTML inattendue "
        "(vérifier GOODVIEW_URL=https://www.goodview.fr ou GOODVIEW_API)"
    )

payload = json.loads(sys.argv[1])
api_base = sys.argv[2].rstrip("/")
body = json.dumps({
    "code": payload["code"],
    "redirect_uri": payload["redirect_uri"],
}).encode("utf-8")
req = urllib.request.Request(
    f"{api_base}/v1/gdview/token",
    data=body,
    headers={"Accept": "application/json", "Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
        if raw.lstrip().startswith("<"):
            message = format_http_error(
                resp.status,
                raw,
                resp.headers.get("Content-Type", ""),
            )
            print(json.dumps({"error": message}, ensure_ascii=False))
        else:
            print(raw)
except urllib.error.HTTPError as exc:
    raw = exc.read().decode("utf-8", errors="replace")
    message = format_http_error(exc.code, raw, exc.headers.get("Content-Type", ""))
    print(json.dumps({"error": message, "status": exc.code}, ensure_ascii=False))
except Exception as exc:
    print(json.dumps({"error": str(exc)}, ensure_ascii=False))
PY
)"

    if ! python3 - "$token_response" <<'PY'
import json, re, sys

try:
    data = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(1)

token = data.get("token")
if not isinstance(token, str) or not re.fullmatch(r"\d+\|[A-Za-z0-9]+", token):
    sys.exit(1)
sys.exit(0)
PY
    then
        echo "Erreur: échange OAuth impossible." >&2
        if python3 -c 'import json,sys; json.loads(sys.argv[1])' "$token_response" 2>/dev/null; then
            python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("message") or d.get("error") or d)' "$token_response" >&2
        else
            _good_format_http_error "?" "$token_response" >&2
        fi
        exit 1
    fi

    if ! python3 - "$token_response" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
sys.exit(0 if data.get("user", {}).get("is_admin") else 1)
PY
    then
        echo "Erreur: un compte administrateur Goodview est requis pour lier un projet." >&2
        exit 1
    fi

    python3 - "$token_response" <<'PY'
import json, re, sys

data = json.loads(sys.argv[1])
token = data["token"]
if not re.fullmatch(r"\d+\|[A-Za-z0-9]+", token):
    print("Erreur: token OAuth invalide.", file=sys.stderr)
    sys.exit(1)
print(token)
PY
}

_good_api_request() {
    local method="$1" path="$2" token="$3" body="${4:-}"
    local api_base tmp http_code response
    api_base="$(_good_api_base)"
    tmp="$(mktemp)"
    if [ -n "$body" ]; then
        http_code="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "${api_base}${path}")"
    else
        http_code="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/json" \
            "${api_base}${path}")"
    fi
    response="$(cat "$tmp")"
    rm -f "$tmp"
    if [ "${http_code:0:1}" != "2" ]; then
        local err_msg
        err_msg="$(_good_format_http_error "$http_code" "$response")"
        python3 -c 'import json,sys; print(json.dumps({"error": sys.argv[1], "status": int(sys.argv[2])}, ensure_ascii=False))' "$err_msg" "$http_code"
        return
    fi
    echo "$response"
}

_good_fetch_projects() {
    local token="$1"
    python3 - "$token" "$(_good_api_base)" <<'PY'
import json, re, sys, urllib.error, urllib.request

def format_http_error(status, body, content_type=""):
    if "json" in content_type or body.lstrip().startswith("{"):
        try:
            data = json.loads(body)
            return data.get("message") or json.dumps(data, ensure_ascii=False)
        except json.JSONDecodeError:
            pass
    title = re.search(r"<title[^>]*>([^<]+)</title>", body, re.I)
    if title:
        return f"HTTP {status} — {title.group(1).strip()}"
    snippet = next(
        (line.strip() for line in body.splitlines() if line.strip() and not line.lstrip().startswith("<")),
        "",
    )
    if snippet:
        return f"HTTP {status} — {snippet[:120]}"
    return (
        f"HTTP {status} — réponse HTML inattendue "
        "(vérifier GOODVIEW_URL=https://www.goodview.fr ou GOODVIEW_API)"
    )

token, api_base = sys.argv[1:3]
req = urllib.request.Request(
    f"{api_base.rstrip('/')}/v1/admin/projects",
    headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        print(json.dumps(json.load(resp), ensure_ascii=False))
except urllib.error.HTTPError as exc:
    raw = exc.read().decode("utf-8", errors="replace")
    print(format_http_error(exc.code, raw, exc.headers.get("Content-Type", "")), file=sys.stderr)
    sys.exit(1)
except urllib.error.URLError as exc:
    print(f"Erreur réseau : {exc.reason}", file=sys.stderr)
    sys.exit(1)
PY
}

_good_match_project_by_remote() {
    local projects_json="$1" git_remote="$2"
    python3 - "$projects_json" "$git_remote" <<'PY'
import json, sys

projects = json.loads(sys.argv[1]).get("data") or []
git_remote = sys.argv[2].strip()
slug = None
if git_remote:
    for prefix in ("git@github.com:", "https://github.com/", "http://github.com/"):
        if git_remote.startswith(prefix):
            slug = git_remote[len(prefix):].removesuffix(".git")
            break
if slug:
    slug_lower = slug.lower()
    for project in projects:
        gh = (project.get("github_repo") or "").lower()
        if gh == slug_lower:
            print(project["id"])
            break
PY
}

_good_print_project_list() {
    local projects_json="$1"
    python3 - "$projects_json" <<'PY'
import json, sys

projects = json.loads(sys.argv[1]).get("data") or []
print("Projets Goodview disponibles :", file=sys.stderr)
for idx, project in enumerate(projects, start=1):
    client = (project.get("client") or {}).get("name") or "Sans client"
    gh = project.get("github_repo") or "—"
    print(f"  {idx}. {project['name']} ({client}) — {gh}", file=sys.stderr)
PY
}

_good_project_id_at_index() {
    local projects_json="$1" index="$2"
    python3 - "$projects_json" "$index" <<'PY'
import json, sys

projects = json.loads(sys.argv[1]).get("data") or []
try:
    num = int(sys.argv[2].strip())
except ValueError:
    sys.exit(1)
if 1 <= num <= len(projects):
    print(projects[num - 1]["id"])
else:
    sys.exit(1)
PY
}

_good_select_project() {
    local token="$1" git_remote="$2"
    local projects_json project_id count choice

    if ! projects_json="$(_good_fetch_projects "$token")"; then
        exit 1
    fi

    if ! python3 - "$projects_json" <<'PY' >/dev/null 2>&1; then
import json, sys
json.loads(sys.argv[1]).get("data")
PY
        echo "Erreur: impossible de récupérer les projets." >&2
        echo "$projects_json" >&2
        exit 1
    fi

    count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1]).get("data") or []))' "$projects_json")"

    if [ "$count" -eq 0 ]; then
        echo "Erreur: aucun projet disponible sur Goodview." >&2
        exit 1
    fi

    if [ "$count" -eq 1 ]; then
        project_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["data"][0]["id"])' "$projects_json")"
        echo "$project_id"
        return 0
    fi

    project_id="$(_good_match_project_by_remote "$projects_json" "$git_remote" || true)"
    if [ -n "$project_id" ]; then
        echo "$project_id"
        return 0
    fi

    _good_print_project_list "$projects_json"

    if [ ! -t 0 ]; then
        echo "Erreur: plusieurs projets disponibles — sélection interactive requise (terminal non interactif)." >&2
        exit 1
    fi

    while true; do
        read -rp "Numéro du projet à lier : " choice
        if project_id="$(_good_project_id_at_index "$projects_json" "$choice" 2>/dev/null)"; then
            echo "$project_id"
            return 0
        fi
        echo "Choix invalide." >&2
    done
}
cmd_init() {
    _good_require_python
    _good_require_curl

    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        git init
        echo "✓ Git initialisé"
    fi

    if [ -f "$(_good_config_file)" ]; then
        read -rp "Projet déjà lié à Goodview. Relier? [y/N] " RELINK
        if [[ "${RELINK,,}" != "y" ]]; then
            echo "Annulé. Lance 'good info' pour voir la liaison actuelle."
            exit 0
        fi
    fi

    local token site_base api_base git_remote default_branch project_id link_body link_response
    site_base="$(_good_site_base)"
    api_base="$(_good_api_base)"
    token="$(_good_oauth_token)"
    git_remote="$(git remote get-url origin 2>/dev/null || true)"
    default_branch="$(git branch --show-current 2>/dev/null || echo main)"

    project_id="$(_good_select_project "$token" "$git_remote")"
    link_body="$(python3 - "$project_id" "$git_remote" "$default_branch" "$(_good_root)" <<'PY'
import json, sys
print(json.dumps({
    "project_id": int(sys.argv[1]),
    "git_remote": sys.argv[2] or None,
    "default_branch": sys.argv[3] or "main",
    "local_path": sys.argv[4],
}))
PY
)"

    link_response="$(_good_api_request POST "/v1/admin/good-cli/link" "$token" "$link_body")"

    if ! python3 - "$link_response" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
sys.exit(0 if data.get("data", {}).get("id") else 1)
PY
    then
        echo "Erreur: liaison au projet impossible."
        if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("message") or d.get("error") or d)' "$link_response" 2>/dev/null; then
            :
        else
            _good_format_http_error "?" "$link_response"
        fi
        exit 1
    fi

    _good_save_config "$token" "$project_id" "$site_base" "$api_base"

    python3 - "$link_response" <<'PY'
import json, sys
data = json.loads(sys.argv[1])["data"]
client = (data.get("client") or {}).get("name") or "—"
print(f"✓ Projet lié : {data['name']} ({client})")
if data.get("github_url"):
    print(f"  Dépôt : {data['github_url']}")
if data.get("dev_url"):
    print(f"  Dev : {data['dev_url']} ({data.get('dev_environment_name') or 'dev'})")
if data.get("prod_url"):
    print(f"  Prod : {data['prod_url']} ({data.get('prod_environment_name') or 'prod'})")
print("  Config : .good/config.json (gitignored)")
PY

    if [ -z "$git_remote" ]; then
        echo ""
        echo "Aucun remote git configuré. Utilise 'good p' pour créer le repo GitHub et pousser."
    fi
}

cmd_info() {
    _good_require_python
    _good_require_curl

    local config_file="$(_good_config_file)"
    if [ ! -f "$config_file" ]; then
        echo "Ce dépôt n'est pas lié à Goodview."
        echo "Lance 'good init' pour connecter le projet local."
        exit 1
    fi

    local token project_id response
    token="$(_good_load_config_value token)"
    project_id="$(_good_load_config_value project_id)"

    if [ -z "$token" ] || [ -z "$project_id" ]; then
        echo "Configuration .good invalide. Relance 'good init'."
        exit 1
    fi

    response="$(_good_api_request GET "/v1/admin/good-cli/projects/${project_id}" "$token")"

    if ! python3 - "$response" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
sys.exit(0 if data.get("data", {}).get("id") else 1)
PY
    then
        echo "Erreur: impossible de récupérer le projet (token expiré ?). Relance 'good init'."
        if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("message") or d.get("error") or d)' "$response" 2>/dev/null; then
            :
        else
            _good_format_http_error "?" "$response"
        fi
        exit 1
    fi

    python3 - "$response" "$config_file" <<'PY'
import json, sys
project = json.loads(sys.argv[1])["data"]
with open(sys.argv[2]) as f:
    local = json.load(f)

print("Liaison Goodview")
print("────────────────")
print(f"Client    : {(project.get('client') or {}).get('name') or '—'}")
print(f"Projet    : {project['name']} ({project.get('status_label') or project.get('status')})")
print(f"Type      : {project.get('type_label') or project.get('type')}")
print(f"Chemin    : {local.get('local_path') or '—'}")
print(f"Lié le    : {local.get('linked_at') or '—'}")
print(f"Goodview  : {local.get('site_base') or '—'}/admin/projects/{project['id']}/edit")

if project.get("github_url"):
    print(f"Dépôt     : {project['github_url']}")
elif project.get("repos"):
    print(f"Dépôt     : {project['repos'][0].get('url') or '—'}")

git_remote = ""
try:
    import subprocess
    git_remote = subprocess.check_output(
        ["git", "remote", "get-url", "origin"],
        stderr=subprocess.DEVNULL,
        text=True,
    ).strip()
except Exception:
    pass
if git_remote:
    print(f"Remote    : {git_remote}")

if project.get("dev_url"):
    print(f"Dev       : {project['dev_url']} ({project.get('dev_environment_name') or 'dev'})")
if project.get("prod_url"):
    print(f"Prod      : {project['prod_url']} ({project.get('prod_environment_name') or 'prod'})")
PY
}
_good_install_target() {
    echo "${HOME}/.local/bin/good"
}

_good_share_dir() {
    echo "${HOME}/.local/share/good"
}

_good_install_package() {
    local source_root="${1:-}" target lib_dest
    target="$(_good_install_target)"
    lib_dest="$(_good_share_dir)/lib"

    if [ -n "$source_root" ] && [ -f "$source_root/good" ] && [ -d "$source_root/lib" ]; then
        mkdir -p "$(dirname "$target")" "$(_good_share_dir)"
        install -m 755 "$source_root/good" "$target"
        rm -rf "$lib_dest"
        cp -a "$source_root/lib" "$(_good_share_dir)/"
        find "$lib_dest" -name '*.py' -exec chmod 644 {} \;
        find "$lib_dest" -name '*.sh' -exec chmod 644 {} \;
        echo "✓ good installé dans $target (lib dans $lib_dest)"
        return 0
    fi
    return 1
}

_good_fetch_github_tree() {
    local dest="$1"
    local tarball="https://github.com/${GOOD_CLI_GITHUB_REPO}/archive/refs/heads/${GOOD_CLI_GITHUB_REF}.tar.gz"
    local tmpdir extracted
    tmpdir="$(mktemp -d)"
    if curl -fsSL "$tarball" -o "$tmpdir/archive.tar.gz" 2>/dev/null \
        && tar -xzf "$tmpdir/archive.tar.gz" -C "$tmpdir" 2>/dev/null; then
        extracted="$(find "$tmpdir" -maxdepth 1 -type d -name 'good-*' | head -1)"
        if [ -n "$extracted" ] && [ -f "$extracted/good" ]; then
            cp -a "$extracted" "$dest"
            rm -rf "$tmpdir"
            return 0
        fi
    fi
    rm -rf "$tmpdir"
    return 1
}

_good_compare_versions() {
    python3 - "$1" "$2" <<'PY'
import sys

def parts(v):
    out = []
    for piece in v.lstrip("v").split("."):
        num = ""
        for ch in piece:
            if ch.isdigit():
                num += ch
            else:
                break
        out.append(int(num or 0))
    return out

a, b = parts(sys.argv[1]), parts(sys.argv[2])
length = max(len(a), len(b))
for i in range(length):
    av = a[i] if i < len(a) else 0
    bv = b[i] if i < len(b) else 0
    if av < bv:
        print("older")
        break
    if av > bv:
        print("newer")
        break
else:
    print("equal")
PY
}

_good_fetch_github_script() {
    local dest="$1"
    if curl -fsSL "$GOOD_CLI_GITHUB_RAW" -o "$dest" 2>/dev/null \
        && head -n 1 "$dest" | grep -q '^#!/'; then
        return 0
    fi
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        if gh api "repos/${GOOD_CLI_GITHUB_REPO}/contents/${GOOD_CLI_GITHUB_PATH}?ref=${GOOD_CLI_GITHUB_REF}" \
            --jq '.content' 2>/dev/null \
            | tr -d '\n' | base64 -d > "$dest" 2>/dev/null \
            && head -n 1 "$dest" | grep -q '^#!/'; then
            return 0
        fi
    fi
    return 1
}

_good_remote_script_version() {
    local tmp version
    tmp="$(mktemp)"
    if ! _good_fetch_github_script "$tmp"; then
        rm -f "$tmp"
        echo "$VERSION"
        return
    fi
    version="$(grep -E '^VERSION=' "$tmp" | head -1 | sed -E 's/^VERSION="([^"]+)".*/\1/')"
    rm -f "$tmp"
    echo "${version:-$VERSION}"
}

_good_fetch_version_manifest() {
    local token="${1:-}" manifest remote_version
    if [ -n "$token" ]; then
        manifest="$(_good_api_request GET "/v1/admin/good-cli/version" "$token")"
        if python3 - "$manifest" <<'PY' >/dev/null 2>&1
import json, sys
data = json.loads(sys.argv[1])
sys.exit(0 if data.get("data", {}).get("version") else 1)
PY
        then
            echo "$manifest"
            return 0
        fi
        echo "Attention: manifest Goodview indisponible, repli GitHub." >&2
    fi
    remote_version="$(_good_remote_script_version)"
    python3 - "$remote_version" "$GOOD_CLI_GITHUB_RAW" <<'PY'
import json, sys
print(json.dumps({
    "data": {
        "version": sys.argv[1],
        "download_url": sys.argv[2],
        "github_repo": "goodview-fr/good",
    }
}, ensure_ascii=False))
PY
}

_good_install_cli() {
    local url="${1:-}" target tmp ok=0 tmpdir extracted
    target="$(_good_install_target)"

    if [ -n "${GOOD_ROOT:-}" ] && _good_install_package "$GOOD_ROOT"; then
        return 0
    fi

    tmpdir="$(mktemp -d)"
    if _good_fetch_github_tree "$tmpdir/pkg"; then
        _good_install_package "$tmpdir/pkg" && { rm -rf "$tmpdir"; return 0; }
    fi
    rm -rf "$tmpdir"

    tmp="$(mktemp)"
    if [ -n "$url" ] && curl -fsSL "$url" -o "$tmp" 2>/dev/null \
        && head -n 1 "$tmp" | grep -q '^#!/'; then
        ok=1
    elif _good_fetch_github_script "$tmp"; then
        ok=1
    fi
    if [ "$ok" -eq 0 ]; then
        rm -f "$tmp"
        echo "Erreur: téléchargement impossible." >&2
        echo "  Installe depuis une copie locale :" >&2
        echo "  bash install-good.sh" >&2
        return 1
    fi
    mkdir -p "$(dirname "$target")"
    install -m 755 "$tmp" "$target"
    rm -f "$tmp"
    echo "✓ good installé dans $target (mode monolithique — relance install-good.sh pour lib/)"
}

_good_update_cli() {
    local force="${1:-0}" token="${2:-}" manifest remote_version download_url current cmp
    current="$VERSION"
    manifest="$(_good_fetch_version_manifest "$token")"
    if ! remote_version="$(python3 - "$manifest" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(data["data"]["version"])
except (json.JSONDecodeError, KeyError, TypeError):
    sys.exit(1)
PY
)"; then
        echo "Erreur: manifest de version invalide." >&2
        return 1
    fi
    if ! download_url="$(python3 - "$manifest" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(data["data"].get("download_url") or "")
except (json.JSONDecodeError, KeyError, TypeError):
    sys.exit(1)
PY
)"; then
        download_url=""
    fi

    echo "CLI good : v${current} installé"
    echo "Disponible : v${remote_version}"

    cmp="$(_good_compare_versions "$current" "$remote_version")"
    if [ "$cmp" = "equal" ] && [ "$force" != "1" ]; then
        echo "✓ good CLI déjà à jour."
        return 0
    fi
    if [ "$cmp" = "newer" ] && [ "$force" != "1" ]; then
        echo "Version locale plus récente que le manifest (dev ?). Utilise --force pour réinstaller."
        return 0
    fi

    echo "Téléchargement de good v${remote_version}..."
    _good_install_cli "$download_url"
}

cmd_update() {
    _good_require_python
    _good_require_curl

    local force=0 with_deps=0 token config_file project_id linked=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force|-f) force=1 ;;
            --deps) with_deps=1 ;;
            -y|--yes) GOOD_YES=1 ;;
            -h|--help)
                echo "Usage: good update [--force] [--deps]"
                echo ""
                echo "  --force   Réinstalle le CLI même si la version est identique"
                echo "  --deps    Lance composer install / npm install si détectés"
                exit 0
                ;;
            *)
                echo "Option inconnue: $1" >&2
                exit 1
                ;;
        esac
        shift
    done

    config_file="$(_good_config_file)"
    token=""
    project_id=""
    if [ -f "$config_file" ]; then
        linked=1
        token="$(_good_load_config_value token || true)"
        project_id="$(_good_load_config_value project_id || true)"
    else
        echo "Pas de projet lié — mise à jour du CLI uniquement."
    fi

    echo "=== Mise à jour good ==="
    echo ""
    _good_update_cli "$force" "$token"

    if [ "$linked" -eq 1 ]; then
        echo ""
        if [ -z "$token" ] || [ -z "$project_id" ]; then
            echo "Configuration .good invalide — contexte projet ignoré. Relance 'good init'."
        else
            _good_refresh_project_cache "$token" "$project_id"
        fi
    fi

    if [ "$with_deps" -eq 1 ]; then
        echo ""
        _good_install_project_deps
    fi

    echo ""
    echo "✓ Mise à jour terminée."
}

_good_refresh_project_cache() {
    local token="$1" project_id="$2"
    local response
    response="$(_good_api_request GET "/v1/admin/good-cli/projects/${project_id}" "$token")"
    if ! python3 - "$response" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
sys.exit(0 if data.get("data", {}).get("id") else 1)
PY
    then
        echo "Erreur: impossible de rafraîchir le projet (token expiré ?). Relance 'good init'." >&2
        if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("message") or d.get("error") or d)' "$response" 2>/dev/null; then
            :
        else
            _good_format_http_error "?" "$response" >&2
        fi
        return 1
    fi

    python3 - "$(_good_config_file)" "$response" <<'PY'
import json, sys, datetime, os

config_path, response_raw = sys.argv[1:3]
project = json.loads(response_raw)["data"]
with open(config_path) as f:
    cfg = json.load(f)

cfg["project_cache"] = {
    "id": project["id"],
    "name": project["name"],
    "slug": project.get("slug"),
    "type": project.get("type"),
    "type_label": project.get("type_label"),
    "status": project.get("status"),
    "status_label": project.get("status_label"),
    "github_url": project.get("github_url"),
    "dev_url": project.get("dev_url"),
    "dev_environment_name": project.get("dev_environment_name"),
    "prod_url": project.get("prod_url"),
    "prod_environment_name": project.get("prod_environment_name"),
    "client_name": (project.get("client") or {}).get("name"),
}
cfg["updated_at"] = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.chmod(config_path, 0o600)
PY

    python3 - "$response" <<'PY'
import json, sys
project = json.loads(sys.argv[1])["data"]
client = (project.get("client") or {}).get("name") or "—"
print(f"✓ Contexte projet rafraîchi : {project['name']} ({client})")
if project.get("dev_url"):
    print(f"  Dev  : {project['dev_url']}")
if project.get("prod_url"):
    print(f"  Prod : {project['prod_url']}")
PY
}

_good_install_project_deps() {
    local root="$(_good_root)" ran=0
    if [ -f "$root/composer.json" ] && command -v composer >/dev/null 2>&1; then
        echo "Installation des dépendances PHP (composer install)..."
        (cd "$root" && composer install --no-interaction)
        echo "✓ composer install terminé"
        ran=1
    elif [ -f "$root/composer.json" ]; then
        echo "composer.json présent mais composer absent — ignoré." >&2
    fi
    if [ -f "$root/package.json" ] && command -v npm >/dev/null 2>&1; then
        echo "Installation des dépendances JS (npm install)..."
        (cd "$root" && npm install)
        echo "✓ npm install terminé"
        ran=1
    elif [ -f "$root/package.json" ]; then
        echo "package.json présent mais npm absent — ignoré." >&2
    fi
    if [ "$ran" -eq 0 ]; then
        echo "Aucune dépendance détectée (composer.json / package.json)."
    fi
}
