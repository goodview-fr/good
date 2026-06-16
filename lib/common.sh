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

_ai() {
    echo "$@" | ollama run qwen3:8b --nowordwrap 2>/dev/null \
        | sed '/^Thinking\.\.\./,/^\.\.\.done thinking\./d' \
        | sed 's/^`\+//;s/`\+$//;/^```/d' \
        | sed '/^[[:space:]]*$/d'
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
