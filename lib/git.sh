#!/usr/bin/env bash
# Git helpers (log, status — commit/push/sync/conflits via good dog)

cmd_log() {
    _check_git
    git log --oneline --graph --decorate -20
}

cmd_status() {
    _check_git
    git status -s
    _print_sep
    git log --oneline -5
}

cmd_unlink() {
    local config_file="$(_good_config_file)"
    if [ ! -f "$config_file" ]; then
        echo "Ce dépôt n'est pas lié à Goodview."
        exit 0
    fi
    if [ "${GOOD_YES:-0}" -ne 1 ]; then
        read -rp "Supprimer la liaison Goodview (.good/config.json)? [y/N] " ANSWER
        if [[ "${ANSWER,,}" != "y" ]]; then
            echo "Annulé."
            exit 0
        fi
    fi
    rm -f "$config_file"
    echo "✓ Liaison Goodview supprimée."
}
