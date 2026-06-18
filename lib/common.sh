#!/usr/bin/env bash
# Shared utilities for good CLI

_good_py() {
    local script="$GOOD_LIB/py/$1"
    shift
    python3 "$script" "$@"
}

_print_sep() {
    echo "──────────────────────────────────────"
}

_ai_confirm() {
    local prompt="$1"
    if [ "${GOOD_YES:-0}" -eq 1 ]; then
        return 0
    fi
    read -rp "$prompt [Y/n] " ANSWER
    case "${ANSWER,,}" in
        n|non) return 1 ;;
        *)     return 0 ;;
    esac
}

_repo_name() {
    basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

_check_git() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        echo "Erreur: pas dans un dépôt git. Lance 'good init' pour initialiser."
        exit 1
    fi
}

_has_staged() {
    [ -n "$(git diff --cached --name-only 2>/dev/null)" ]
}

_has_changes() {
    [ -n "$(git status --porcelain 2>/dev/null)" ]
}

_good_root() {
    if git rev-parse --show-toplevel > /dev/null 2>&1; then
        git rev-parse --show-toplevel
    else
        pwd
    fi
}

_good_config_dir() {
    echo "$(_good_root)/.good"
}

_good_config_file() {
    echo "$(_good_config_dir)/config.json"
}

_good_require_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Erreur: python3 est requis."
        exit 1
    fi
}

_good_require_curl() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "Erreur: curl est requis."
        exit 1
    fi
}

_good_require_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        echo "Erreur: GitHub CLI (gh) requis. Installe-le : https://cli.github.com"
        exit 1
    fi
}

_ai_check_ollama() {
    if ! command -v ollama >/dev/null 2>&1; then
        echo "Erreur: Ollama n'est pas installé."
        exit 1
    fi
    if ! ollama list >/dev/null 2>&1; then
        echo "Erreur: Ollama ne répond pas. Lance 'ollama serve'."
        exit 1
    fi
}

# Retourne "deepseek" | "openai" | "ollama"
_good_ai_provider() {
    if [ -n "${GOOD_AI_PROVIDER:-}" ]; then
        echo "$GOOD_AI_PROVIDER"
        return
    fi
    if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
        echo "deepseek"
    else
        echo "ollama"
    fi
}

# Retourne le modèle par défaut selon le provider
_good_ai_model() {
    local provider="${1:-$(_good_ai_provider)}"
    case "$provider" in
        deepseek) echo "${DEEPSEEK_MODEL:-deepseek-chat}" ;;
        openai)   echo "${OPENAI_MODEL:-gpt-4o-mini}" ;;
        *)        echo "${GOOD_OLLAMA_MODEL:-qwen3:8b}" ;;
    esac
}

# Vérifie que le provider est opérationnel
_ai_check_provider() {
    local provider
    provider="$(_good_ai_provider)"
    case "$provider" in
        deepseek)
            if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
                echo "Erreur: DEEPSEEK_API_KEY non définie." >&2
                echo "  export DEEPSEEK_API_KEY=sk-..." >&2
                exit 1
            fi
            ;;
        openai)
            if [ -z "${OPENAI_API_KEY:-}" ]; then
                echo "Erreur: OPENAI_API_KEY non définie." >&2
                exit 1
            fi
            ;;
        ollama)
            _ai_check_ollama
            ;;
    esac
}

_ai() {
    local provider model
    provider="$(_good_ai_provider)"
    model="$(_good_ai_model "$provider")"
    case "$provider" in
        deepseek|openai)
            _ai_openai_oneshot "$provider" "$model" "$@"
            ;;
        *)
            echo "$@" | ollama run "$model" --nowordwrap 2>/dev/null \
                | sed '/^Thinking\.\.\./,/^\.\.\.done thinking\./d' \
                | sed 's/^`\+//;s/`\+$//;/^```/d' \
                | sed '/^[[:space:]]*$/d'
            ;;
    esac
}

_ai_openai_oneshot() {
    local provider="$1" model="$2"
    shift 2
    local prompt="$*"
    local api_key base_url
    if [ "$provider" = "deepseek" ]; then
        api_key="${DEEPSEEK_API_KEY:-}"
        base_url="${DEEPSEEK_BASE_URL:-https://api.deepseek.com}"
    else
        api_key="${OPENAI_API_KEY:-}"
        base_url="${OPENAI_BASE_URL:-https://api.openai.com}"
    fi
    python3 - "$base_url" "$model" "$api_key" "$prompt" <<'PY'
import json, sys, urllib.request, urllib.error
base_url, model, api_key, prompt = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
payload = json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "stream": False
}).encode()
req = urllib.request.Request(
    f"{base_url}/v1/chat/completions",
    data=payload,
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
    method="POST"
)
try:
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read())
    print(data["choices"][0]["message"]["content"])
except urllib.error.HTTPError as exc:
    print(f"Erreur API ({exc.code}): {exc.read().decode(errors='replace')}", file=sys.stderr)
    sys.exit(1)
except urllib.error.URLError as exc:
    print(f"Erreur réseau: {exc.reason}", file=sys.stderr)
    sys.exit(1)
PY
}

_good_branch_counts() {
    local branch="$1"
    # shellcheck disable=SC2034
    BEHIND=$(git rev-list "HEAD..origin/$branch" --count 2>/dev/null || echo "0")
    # shellcheck disable=SC2034
    AHEAD=$(git rev-list "origin/$branch..HEAD" --count 2>/dev/null || echo "0")
}

_good_remote_branch_exists() {
    local branch="$1"
    git ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1
}
