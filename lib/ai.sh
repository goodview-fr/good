#!/usr/bin/env bash
# AI task pipeline
_ai_gather_context() {
    local instruction="$1" root config_file
    root="$(_good_root)"
    config_file="$(_good_config_file)"
    python3 - "$root" "$config_file" "$instruction" <<'PY'
import json, os, re, subprocess, sys

root, config_file, instruction = sys.argv[1:4]
lines = [f"Racine du projet: {root}"]

if os.path.isfile(config_file):
    with open(config_file) as f:
        cfg = json.load(f)
    cfg_safe = {k: v for k, v in cfg.items() if k != "token"}
    lines.append("Liaison Goodview (.good/config.json, sans token):")
    lines.append(json.dumps(cfg_safe, ensure_ascii=False, indent=2))

try:
    status = subprocess.check_output(
        ["git", "status", "-s"],
        cwd=root,
        stderr=subprocess.DEVNULL,
        text=True,
    ).strip()
    if status:
        lines.append("Git status (-s):")
        lines.append(status)
    else:
        lines.append("Git status: propre")
except Exception:
    lines.append("Git status: indisponible")

skip_dirs = {".git", "node_modules", "vendor", "dist", "build", ".next", "storage"}
entries = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in skip_dirs and not d.startswith(".")]
    rel_dir = os.path.relpath(dirpath, root)
    depth = 0 if rel_dir == "." else rel_dir.count(os.sep) + 1
    if depth > 2:
        dirnames.clear()
        continue
    for name in sorted(filenames):
        if name.startswith(".") and name not in {".env", ".env.example", ".gitignore"}:
            continue
        rel = name if rel_dir == "." else os.path.join(rel_dir, name)
        entries.append(rel)
    if len(entries) >= 80:
        break
if entries:
    lines.append("Fichiers clés (max 80):")
    lines.append("\n".join(entries[:80]))

mentioned = set()
for match in re.findall(
    r"(?:^|[\s'\"`])([\w./-]+\.(?:env(?:\.\w+)?|json|ya?ml|php|ts|tsx|js|jsx|vue|md|txt|sh|toml|ini|xml|css|py|rb|sql|lock))\b|(?:^|[\s'\"`])(\.env(?:\.\w+)?)\b",
    instruction,
    re.I,
):
    for part in match:
        if part:
            mentioned.add(part.lstrip("./"))

for rel in sorted(mentioned):
    path = os.path.normpath(os.path.join(root, rel))
    if not path.startswith(os.path.realpath(root) + os.sep):
        continue
    if not os.path.isfile(path):
        lines.append(f"Fichier mentionné absent: {rel}")
        continue
    if os.path.getsize(path) > 120_000:
        lines.append(f"Fichier mentionné trop volumineux: {rel}")
        continue
    with open(path, errors="replace") as f:
        content = f.read()
    lines.append(f"Contenu actuel de {rel}:")
    lines.append("---")
    lines.append(content)
    lines.append("---")

print("\n".join(lines))
PY
}

_ai_request_task() {
    local instruction="$1" context="$2"
    _ai "Tu es un assistant de développement pour le CLI « good ».
L'utilisateur donne une instruction en français. Analyse le contexte du projet et propose des modifications de fichiers concrètes.

Règles strictes:
- Réponds UNIQUEMENT avec un objet JSON valide, sans markdown, sans texte avant ou après
- Format exact:
{\"summary\":\"résumé en français\",\"files\":[{\"path\":\"chemin/relatif\",\"action\":\"create|modify|delete\",\"content\":\"contenu complet\"}]}
- action \"delete\" sans champ content
- Ne propose AUCUNE commande shell
- Chemins relatifs à la racine du projet, pas de .. ni de chemins absolus
- Ne modifie jamais .good/config.json
- Pour modifier un fichier existant, renvoie le contenu COMPLET du fichier après modification
- Si l'instruction est impossible ou ambiguë, renvoie {\"summary\":\"...\",\"files\":[]}

CONTEXTE PROJET:
$context

INSTRUCTION UTILISATEUR:
$instruction"
}

_ai_parse_task_response() {
    python3 - "$1" <<'PY'
import json, re, sys

raw = sys.argv[1]
start = raw.find("{")
end = raw.rfind("}")
if start < 0 or end <= start:
    print("Erreur: réponse IA sans JSON.", file=sys.stderr)
    sys.exit(1)
try:
    data = json.loads(raw[start:end + 1])
except json.JSONDecodeError as exc:
    print(f"Erreur: JSON IA invalide ({exc}).", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict):
    print("Erreur: format IA inattendu.", file=sys.stderr)
    sys.exit(1)
data.setdefault("summary", "")
data.setdefault("files", [])
if not isinstance(data["files"], list):
    print("Erreur: liste files invalide.", file=sys.stderr)
    sys.exit(1)
print(json.dumps(data, ensure_ascii=False))
PY
}

_ai_validate_task() {
    local root="$1" payload="$2"
    python3 "$GOOD_LIB/py/validate_task.py" "$root" "$payload"
}

_ai_preview_task() {
    local root="$1" payload="$2"
    python3 - "$root" "$payload" <<'PY'
import difflib, json, os, re, sys

root = sys.argv[1]
data = json.loads(sys.argv[2])
secret_re = re.compile(r"(secret|token|password|api[_-]?key|private[_-]?key)", re.I)

def mask_line(line):
    if secret_re.search(line) and "=" in line:
        key, _, _ = line.partition("=")
        return f"{key}=***"
    return line

print(data.get("summary") or "Modifications proposées")
print()

for item in data.get("files") or []:
    path = item["path"]
    action = item["action"]
    print(f"[{action.upper()}] {path}")
    if action == "delete":
        continue
    new_lines = item["content"].splitlines(keepends=True)
    full = os.path.join(root, path)
    if action == "modify" and os.path.isfile(full):
        with open(full, errors="replace") as f:
            old_lines = f.readlines()
        diff = difflib.unified_diff(
            [mask_line(l.rstrip("\n")) + "\n" for l in old_lines],
            [mask_line(l.rstrip("\n")) + "\n" for l in new_lines],
            fromfile=f"a/{path}",
            tofile=f"b/{path}",
            lineterm="",
        )
        shown = False
        for line in diff:
            shown = True
            print(line.rstrip("\n"))
        if not shown:
            print("  (aucun changement de contenu détecté)")
    else:
        preview = "".join(mask_line(l.rstrip("\n")) + "\n" for l in new_lines[:40])
        print(preview.rstrip())
        if len(new_lines) > 40:
            print(f"  ... ({len(new_lines) - 40} lignes supplémentaires)")
    print()
PY
}

_ai_apply_task() {
    local root="$1" payload="$2"
    python3 - "$root" "$payload" <<'PY'
import json, os, sys

root = sys.argv[1]
data = json.loads(sys.argv[2])

for item in data.get("files") or []:
    path = item["path"]
    action = item["action"]
    full = os.path.join(root, path)
    if action == "delete":
        os.remove(full)
        print(f"✓ Supprimé: {path}")
    elif action == "create":
        os.makedirs(os.path.dirname(full) or root, exist_ok=True)
        with open(full, "w") as f:
            f.write(item["content"])
        print(f"✓ Créé: {path}")
    else:
        with open(full, "w") as f:
            f.write(item["content"])
        print(f"✓ Modifié: {path}")
PY
}

_ai_confirm() {
    local prompt="$1"
    read -rp "$prompt [Y/n] " ANSWER
    case "${ANSWER,,}" in
        n|non)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

_ai_classify_intent() {
    local instruction="$1"
    python3 "$GOOD_LIB/py/classify_intent.py" "$instruction"
}

_ai_project_info() {
    local root="$1"
    python3 "$GOOD_LIB/py/project_info.py" "$root"
}

_ai_is_safe_run_command() {
    local cmd="$1"
    python3 - "$cmd" <<'PY'
import re, sys

cmd = sys.argv[1].strip()
allowed = {
    "composer dev",
    "composer stack:up",
    "composer postgres:up",
    "npm run dev",
    "pnpm run dev",
    "docker compose up -d",
    "make dev",
    "bash docker/scripts/ensure-dev-up.sh",
}
if cmd not in allowed:
    print(f"Commande non autorisée: {cmd}", file=sys.stderr)
    sys.exit(1)
if re.search(r"[;|&`$()<>]", cmd):
    print("Caractères shell interdits dans la commande.", file=sys.stderr)
    sys.exit(1)
destructive = re.compile(
    r"\b(rm|mv|dd|mkfs|shutdown|reboot|kill|git|docker\s+down|truncate|drop)\b",
    re.I,
)
if destructive.search(cmd):
    print("Commande potentiellement destructive refusée.", file=sys.stderr)
    sys.exit(1)
PY
}

_ai_service_status_json() {
    local root="$1" info_json="$2"
    python3 - "$root" "$info_json" <<'PY'
import json, os, shutil, subprocess, sys, urllib.error, urllib.request

root = sys.argv[1]
info = json.loads(sys.argv[2])

services = []
for check in info.get("checks") or []:
    url = check["url"]
    name = check["name"]
    status = "down"
    detail = ""
    try:
        req = urllib.request.Request(url, method="GET", headers={"User-Agent": "good-cli"})
        with urllib.request.urlopen(req, timeout=2) as resp:
            status = "up"
            detail = f"HTTP {resp.status}"
    except urllib.error.HTTPError as exc:
        status = "up"
        detail = f"HTTP {exc.code}"
    except Exception as exc:
        detail = str(exc)
        low = detail.lower()
        if "refused" in low or "timed out" in low or "timeout" in low:
            status = "down"
        else:
            status = "down"
    services.append({**check, "status": status, "detail": detail})

docker_lines = []
if shutil.which("docker"):
    try:
        out = subprocess.check_output(
            ["docker", "ps", "--format", "{{.Names}}\t{{.Status}}"],
            text=True,
            timeout=5,
        ).strip()
        docker_lines = [line for line in out.splitlines() if line.strip()]
    except Exception as exc:
        docker_lines = [f"docker ps échoué: {exc}"]
else:
    docker_lines = ["docker non installé ou absent du PATH"]

env_hints = []
env_path = os.path.join(root, ".env")
if os.path.isfile(env_path):
    env = {}
    with open(env_path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip().strip('"').strip("'")
    app_url = env.get("APP_URL", "")
    if app_url and "127.0.0.1:8000" not in app_url and "localhost:8000" not in app_url:
        env_hints.append(
            f"APP_URL={app_url} — en local, utilisez http://127.0.0.1:8000"
        )
    if not env.get("APP_KEY"):
        env_hints.append("APP_KEY vide — lancez: php artisan key:generate")
    db_host = env.get("DB_HOST", "")
    if db_host == "postgres" and not docker_lines:
        env_hints.append(
            "DB_HOST=postgres nécessite Docker — lancez composer stack:up avant composer dev"
        )
elif os.path.isfile(os.path.join(root, ".env.example")):
    env_hints.append(".env absent — copiez .env.example vers .env puis configurez APP_KEY")

laravel_up = any(s["name"] == "Laravel" and s["status"] == "up" for s in services)
vite_up = any(s["name"] == "Vite" and s["status"] == "up" for s in services)
all_up = bool(services) and all(s["status"] == "up" for s in services)

print(
    json.dumps(
        {
            "services": services,
            "docker": docker_lines,
            "env_hints": env_hints,
            "all_up": all_up,
            "laravel_up": laravel_up,
            "vite_up": vite_up,
        },
        ensure_ascii=False,
    )
)
PY
}

_ai_print_diagnosis() {
    local status_json="$1" info_json="$2"
    python3 - "$status_json" "$info_json" <<'PY'
import json, sys

status = json.loads(sys.argv[1])
info = json.loads(sys.argv[2])

print("=== Diagnostic ===")
print()

for svc in status.get("services") or []:
    name = svc["name"]
    url = svc["url"]
    if svc["status"] == "up":
        print(f"✓ {name} ({url}) — {svc.get('detail') or 'répond'}")
    else:
        print(f"✗ {name} ({url}) — connexion refusée ou service arrêté")
        if name == "Laravel":
            print("  → Le serveur Laravel n'est pas lancé. Lancez `composer dev` dans le projet.")
            print("  → Si Docker/Postgres est requis : `composer stack:up` puis `composer dev`.")
        elif name == "Vite":
            print("  → Vite ne répond pas sur le port 5173.")
            print("  → Avec goodview.fr, Vite est inclus dans `composer dev` (npm run dev).")

print()
print("=== Docker ===")
for line in status.get("docker") or ["aucun conteneur listé"]:
    print(f"  {line}")

if status.get("env_hints"):
    print()
    print("=== Suggestions .env ===")
    for hint in status["env_hints"]:
        print(f"  • {hint}")

if info.get("kind") == "laravel" and not status.get("laravel_up"):
    print()
    print(
        "Astuce : « connection refused » sur http://127.0.0.1:8000 signifie "
        "que `bin/artisan serve` n'est pas actif — pas un problème de .env seul."
    )
PY
}

_ai_run_in_background() {
    local root="$1" cmd="$2"
    local log_dir log_file pid_file
    if ! _ai_is_safe_run_command "$cmd"; then
        return 1
    fi
    log_dir="$(_good_config_dir)"
    mkdir -p "$log_dir"
    log_file="$log_dir/dev.log"
    pid_file="$log_dir/dev.pid"

    if [ -f "$pid_file" ]; then
        local old_pid
        old_pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "Un serveur dev tourne déjà (PID $old_pid). Lance 'good dev stop' d'abord."
            return 1
        fi
        rm -f "$pid_file"
    fi

    echo "Démarrage en arrière-plan..."
    echo "  Commande : $cmd"
    echo "  Dossier  : $root"
    echo "  Logs     : $log_file"
    (
        cd "$root" || return 1
        nohup bash -lc "$cmd" >> "$log_file" 2>&1 &
        echo $! > "$pid_file"
    )
    sleep 4
    echo ""
    echo "Vérification des services après démarrage..."
    local info_json status_json
    info_json="$(_ai_project_info "$root")"
    status_json="$(_ai_service_status_json "$root" "$info_json")"
    _ai_print_diagnosis "$status_json" "$info_json"
    if python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("all_up"))' "$status_json" | grep -qx True; then
        echo ""
        echo "✓ Services opérationnels."
    else
        echo ""
        echo "Les services ne répondent pas encore — consultez les logs : tail -f $log_file"
    fi
}

_ai_handle_start() {
    local instruction="$1" root info_json start_cmd status_json
    root="$(_good_root)"
    info_json="$(_ai_project_info "$root")"
    start_cmd="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); cmds=d.get("start_commands") or []; print(cmds[0] if cmds else "")' "$info_json")"

    if [ -z "$start_cmd" ]; then
        local candidates
        candidates="$(python3 -c 'import json,sys; print(", ".join(json.loads(sys.argv[1]).get("start_commands") or []))' "$info_json")"
        echo "Aucune commande de démarrage détectée (composer dev, npm run dev, docker compose, ./good…)."
        if [ -n "$candidates" ]; then
            echo "Commandes candidates : $candidates"
        fi
        echo "Astuce : good dog --agent pour exécution directe via l'IA."
        exit 1
    fi

    echo "Vérification des services..."
    status_json="$(_ai_service_status_json "$root" "$info_json")"
    _ai_print_diagnosis "$status_json" "$info_json"

    if python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("all_up"))' "$status_json" | grep -qx True; then
        echo ""
        echo "✓ Le projet semble déjà en cours d'exécution."
        return 0
    fi

    _print_sep
    echo "Commande proposée :"
    echo "  $start_cmd"
    echo "  (dans $root)"
    echo "  Logs : $(_good_config_dir)/dev.log"
    _print_sep
    if _ai_confirm "Exécuter cette commande?"; then
        _ai_run_in_background "$root" "$start_cmd"
    else
        echo "Commande non exécutée."
    fi
}

_ai_handle_deploy() {
    local instruction="$1" root config_file git_status branch prod_url client_name project_name
    root="$(_good_root)"
    config_file="$(_good_config_file)"

    echo "=== Déploiement — checklist (aucune action destructive automatique) ==="
    echo ""

    if [ -f "$config_file" ]; then
        python3 - "$config_file" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
cache = cfg.get("project_cache") or {}
client = cache.get("client_name") or "—"
name = cache.get("name") or "—"
prod = cache.get("prod_url") or ""
github = cache.get("github_url") or ""
print(f"Projet Goodview : {name} ({client})")
if github:
    print(f"Dépôt           : {github}")
if prod:
    env = cache.get("prod_environment_name") or "prod"
    print(f"URL production  : {prod} ({env})")
else:
    print("URL production  : non renseignée — lance 'good update' ou 'good info'")
PY
    else
        echo "Pas de liaison Goodview (.good/config.json absent)."
        echo "Lance 'good init' pour lier le projet et obtenir l'URL prod."
    fi

    echo ""
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
        branch="$(git -C "$root" branch --show-current 2>/dev/null || echo "?")"
        git_status="$(git -C "$root" status -s 2>/dev/null || true)"
        echo "Branche git : $branch"
        if [ -n "$git_status" ]; then
            echo ""
            echo "⚠ Git non propre — commits ou modifications en attente :"
            echo "$git_status" | head -20
            echo ""
            echo "Étape recommandée : good dog --agent « committe et pousse »"
        else
            echo "✓ Git propre"
            echo ""
            echo "Étape recommandée : good dog --agent « pousse sur GitHub »"
        fi
    else
        echo "Pas de dépôt git — initialise avec 'good init'."
    fi

    echo ""
    _print_sep
    echo "Étapes suggérées :"
    echo "  1. Vérifier que les tests passent localement"
    echo "  2. good dog --agent  — committer et pousser (via git)"
    echo "  3. Déployer via Clever Cloud / pipeline habituel du projet"
    if [ -f "$config_file" ]; then
        prod_url="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print((c.get("project_cache") or {}).get("prod_url") or "")' "$config_file" 2>/dev/null || true)"
        if [ -n "$prod_url" ]; then
            echo "  4. Vérifier : $prod_url"
        fi
    fi
    _print_sep
    echo ""
    echo "good ne lance aucun déploiement automatique."
    if _ai_confirm "Afficher les commandes Clever Cloud courantes (informatif)?"; then
        echo ""
        echo "Clever Cloud (exemples — adapte à ton app) :"
        echo "  clever login"
        echo "  clever status"
        echo "  clever deploy   # depuis la branche configurée sur Clever"
        echo "  clever logs --follow"
    fi
}

_ai_handle_diagnose() {
    local instruction="$1" root info_json start_cmd status_json
    root="$(_good_root)"
    info_json="$(_ai_project_info "$root")"
    start_cmd="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); cmds=d.get("start_commands") or []; print(cmds[0] if cmds else "")' "$info_json")"
    status_json="$(_ai_service_status_json "$root" "$info_json")"

    _ai_print_diagnosis "$status_json" "$info_json"

    if ! python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("all_up"))' "$status_json" | grep -qx True; then
        if [ -n "$start_cmd" ]; then
            echo ""
            if _ai_confirm "Lancer le projet avec $start_cmd?"; then
                _ai_run_in_background "$root" "$start_cmd"
            fi
        fi
    fi

    if python3 -c 'import json,sys; print(len(json.loads(sys.argv[1]).get("env_hints") or []))' "$status_json" | grep -qv '^0$'; then
        echo ""
        if _ai_confirm "Proposer des corrections .env via l'IA (modification de fichiers)?"; then
            _ai_handle_edit "Corrige le fichier .env selon les suggestions du diagnostic : ${instruction}"
        fi
    fi
}

_ai_handle_edit() {
    local instruction="$1"
    _ai_check_provider

    local root context raw_response payload
    root="$(_good_root)"

    echo "Analyse du projet et génération des modifications..."
    context="$(_ai_gather_context "$instruction")"
    raw_response="$(_ai_request_task "$instruction" "$context" || true)"
    if [ -z "$raw_response" ]; then
        echo "Erreur: l'IA n'a pas répondu. Vérifie la configuration du provider ($(_good_ai_provider))."
        exit 1
    fi

    if ! payload="$(_ai_parse_task_response "$raw_response")"; then
        exit 1
    fi

    local file_count
    file_count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1]).get("files") or []))' "$payload")"
    if [ "$file_count" -eq 0 ]; then
        summary="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("summary") or "Aucune modification proposée.")' "$payload")"
        echo "$summary"
        exit 0
    fi

    if ! payload="$(_ai_validate_task "$root" "$payload")"; then
        echo "Modifications refusées pour des raisons de sécurité."
        exit 1
    fi

    _print_sep
    _ai_preview_task "$root" "$payload"
    _print_sep
    if [ "${GOOD_YES:-0}" -eq 1 ]; then
        ANSWER="y"
    else
        read -rp "Appliquer ces modifications? [Y/n/e=éditer l'instruction] " ANSWER
    fi
    case "${ANSWER,,}" in
        n)
            echo "Modifications annulées."
            exit 0
            ;;
        e)
            read -rp "Nouvelle instruction: " instruction
            if [ -z "$instruction" ]; then
                echo "Instruction vide — annulé."
                exit 0
            fi
            _ai_handle_edit "$instruction"
            return
            ;;
    esac

    _ai_apply_task "$root" "$payload"
    echo "✓ Modifications appliquées."
}

cmd_ai() {
    local first="${1:-}" intent=""
    case "$first" in
        start|diagnose|deploy|edit|stop|status)
            _check_git
            intent="$first"
            _good_event_meta "$(python3 -c 'import json,sys; print(json.dumps({"intent":sys.argv[1]}))' "$intent")"
            shift
            case "$first" in
                start)    _ai_handle_start "$*" ;;
                diagnose) _ai_handle_diagnose "$*" ;;
                deploy)   _ai_handle_deploy "$*" ;;
                edit)
                    if [ -z "${*:-}" ]; then
                        echo "Usage: good ai edit <instruction>"
                        exit 1
                    fi
                    _ai_handle_edit "$*"
                    ;;
                stop)     _ai_dev_stop ;;
                status)   _ai_dev_status ;;
            esac
            return 0
            ;;
    esac

    local instruction="${*:-}"
    if [ -z "$instruction" ]; then
        echo "Usage: good ai <instruction>"
        echo "       good ai start|diagnose|edit|stop|status"
        echo "       good do <instruction>"
        echo "       good '#' '<instruction>'   (syntaxe « # message », entre guillemets)"
        echo ""
        echo "Exemples:"
        echo "  good ai lance le projet"
        echo "  good ai start"
        echo "  good ai connection refused sur 8000"
        echo "  good ai edit modifier .env pour ajouter TERMINAL_SERVICE_SECRET"
        echo "  good dev stop"
        exit 1
    fi

    _check_git

    local intent
    intent="$(_ai_classify_intent "$instruction")"
    _good_event_meta "$(python3 -c 'import json,sys; print(json.dumps({"intent":sys.argv[1]}))' "$intent")"
    case "$intent" in
        start)
            _ai_handle_start "$instruction"
            ;;
        diagnose)
            _ai_handle_diagnose "$instruction"
            ;;
        deploy)
            _ai_handle_deploy "$instruction"
            ;;
        *)
            _ai_handle_edit "$instruction"
            ;;
    esac
}

_ai_dev_pid_file() {
    echo "$(_good_config_dir)/dev.pid"
}

_ai_dev_log_file() {
    echo "$(_good_config_dir)/dev.log"
}

_ai_dev_stop() {
    local pid_file pid
    pid_file="$(_ai_dev_pid_file)"
    if [ ! -f "$pid_file" ]; then
        echo "Aucun serveur dev enregistré (.good/dev.pid absent)."
        return 0
    fi
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -z "$pid" ]; then
        rm -f "$pid_file"
        echo "Fichier PID vide — nettoyé."
        return 0
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        echo "✓ Serveur dev arrêté (PID $pid)."
    else
        echo "Processus $pid déjà arrêté."
    fi
    rm -f "$pid_file"
}

_ai_dev_status() {
    local pid_file log_file pid root info_json status_json
    pid_file="$(_ai_dev_pid_file)"
    log_file="$(_ai_dev_log_file)"
    root="$(_good_root)"
    info_json="$(_ai_project_info "$root")"
    status_json="$(_ai_service_status_json "$root" "$info_json")"

    echo "=== Dev server ==="
    if [ -f "$pid_file" ]; then
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "PID      : $pid (actif)"
        else
            echo "PID      : $pid (inactif — fichier obsolète)"
        fi
    else
        echo "PID      : aucun"
    fi
    echo "Logs     : $log_file"
    if [ -f "$log_file" ]; then
        echo ""
        echo "=== Dernières lignes de log ==="
        tail -n 15 "$log_file" 2>/dev/null || true
    fi
    echo ""
    _ai_print_diagnosis "$status_json" "$info_json"
}

cmd_dev() {
    local subcmd="${1:-status}"
    _check_git
    case "$subcmd" in
        stop)   shift; _ai_dev_stop "$@" ;;
        status) shift; _ai_dev_status "$@" ;;
        start)
            shift
            _ai_handle_start "${*:-lance le projet}"
            ;;
        *)
            echo "Usage: good dev stop|status|start"
            exit 1
            ;;
    esac
}
