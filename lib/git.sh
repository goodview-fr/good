#!/usr/bin/env bash
# Git workflow commands

_generate_commit_msg() {
    local diff="$1"
    _ai "Tu es un expert git. Génère UN message de commit concis en anglais au format Conventional Commits (ex: feat(auth): add JWT refresh, fix(api): handle null response).
Analyse ce diff et retourne UNIQUEMENT le message de commit, sans guillemets, sans explication.

DIFF:
$diff"
}

# cmd_commit [composed]
# composed=1 when called from push/sync — returns 2 if user cancels, 0 on success
cmd_commit() {
    local _composed="${1:-0}"
    _check_git

    if ! _has_staged; then
        if ! _has_changes; then
            if [ "$_composed" -eq 1 ]; then
                return 0
            fi
            echo "Rien à committer."
            exit 0
        fi
        echo "Stage de toutes les modifications..."
        git add -A
    fi

    _ai_check_ollama

    local DIFF MSG ANSWER
    DIFF=$(git diff --cached --stat && printf '\n---\n' && git diff --cached)
    echo "Génération du message de commit..."
    MSG=$(_generate_commit_msg "$DIFF")
    if [ -z "$MSG" ]; then
        echo "Impossible de générer un message automatique."
        read -rp "Message de commit: " MSG
    fi
    _print_sep
    echo "Message proposé: $MSG"
    _print_sep
    if [ "${GOOD_YES:-0}" -eq 1 ]; then
        ANSWER="y"
    else
        read -rp "Valider? [Y/n/e=éditer] " ANSWER
    fi
    case "${ANSWER,,}" in
        n)
            echo "Commit annulé."
            if [ "$_composed" -eq 1 ]; then
                return 2
            fi
            exit 0
            ;;
        e)
            read -rp "Nouveau message: " MSG
            ;;
    esac

    if [ -z "$MSG" ]; then
        echo "Erreur: message de commit vide."
        if [ "$_composed" -eq 1 ]; then
            return 2
        fi
        exit 1
    fi

    git commit -m "$MSG"
    echo "✓ Commit: $MSG"
    _good_commit_meta
    return 0
}

_good_push_hint_diverged() {
    local branch="$1" behind="$2" ahead="$3"
    echo ""
    echo "Historiques divergés sur $branch : $ahead commit(s) local(aux), $behind commit(s) sur origin non intégrés."
    echo "Git refuse le push tant que le distant n'est pas rebasé en local."
    echo "→ Lance 'good s' (fetch + rebase + push)."
    echo "   Manuel : git fetch origin && git rebase origin/$branch && git push"
}

cmd_push() {
    local no_commit=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-commit) no_commit=1; shift ;;
            -y|--yes) GOOD_YES=1; shift ;;
            *) break ;;
        esac
    done

    _check_git
    if [ "$no_commit" -eq 0 ] && { _has_changes || _has_staged; }; then
        cmd_commit 1 || {
            echo "Push annulé (commit refusé)."
            exit 1
        }
    fi

    local BRANCH REMOTE REPO PRIV BEHIND AHEAD
    BRANCH=$(git branch --show-current)
    REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
    if [ -z "$REMOTE" ]; then
        _good_require_gh
        REPO=$(_repo_name)
        echo "Aucun remote. Création du repo GitHub '$REPO'..."
        if [ "${GOOD_YES:-0}" -eq 1 ]; then
            PRIV="y"
        else
            read -rp "Repo privé? [Y/n] " PRIV
        fi
        if [[ "${PRIV,,}" == "n" ]]; then
            gh repo create "$REPO" --public --source=. --push
        else
            gh repo create "$REPO" --private --source=. --push
        fi
        echo "✓ Repo créé et pushé: $(git remote get-url origin)"
    else
        if ! git fetch origin "$BRANCH" 2>/dev/null; then
            if _good_remote_branch_exists "$BRANCH"; then
                echo "Erreur fetch (vérifier la connexion, le remote ou gh auth status)."
                exit 1
            fi
        fi
        _good_branch_counts "$BRANCH"
        if [ "$BEHIND" -gt 0 ]; then
            _good_push_hint_diverged "$BRANCH" "$BEHIND" "$AHEAD"
            exit 1
        fi
        if ! git push -u origin "$BRANCH"; then
            echo ""
            echo "Push refusé. Vérifiez les droits sur le dépôt (gh auth status) ou lancez 'good s' si le distant a évolué."
            exit 1
        fi
        echo "✓ Pushé sur origin/$BRANCH"
    fi
}

cmd_sync() {
    local no_commit=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-commit) no_commit=1; shift ;;
            -y|--yes) GOOD_YES=1; shift ;;
            *) break ;;
        esac
    done

    _check_git
    if [ "$no_commit" -eq 0 ] && { _has_changes || _has_staged; }; then
        echo "Changements locaux détectés → commit avant sync..."
        cmd_commit 1 || {
            echo "Sync annulé (commit refusé)."
            exit 1
        }
    fi

    local BRANCH BEHIND AHEAD
    BRANCH=$(git branch --show-current)
    echo "Fetch origin..."
    git fetch origin 2>/dev/null || { echo "Erreur fetch (vérifier la connexion/remote)"; exit 1; }
    _good_branch_counts "$BRANCH"
    if [ "$BEHIND" -gt 0 ]; then
        echo "$BEHIND commit(s) à intégrer depuis origin/$BRANCH..."
        if ! git rebase "origin/$BRANCH"; then
            echo ""
            echo "Conflits détectés. Lance 'good resolve' pour les résoudre automatiquement."
            exit 1
        fi
        _good_branch_counts "$BRANCH"
    fi
    if [ "$AHEAD" -gt 0 ]; then
        git push -u origin "$BRANCH"
        echo "✓ Sync terminé (origin/$BRANCH)"
    else
        echo "✓ Déjà à jour."
    fi
}

cmd_resolve() {
    _check_git
    _ai_check_ollama

    local CONFLICTS FAILED=() FILE CONTENT RESOLVED
    CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -z "$CONFLICTS" ]; then
        echo "Aucun conflit de fusion dans les fichiers."
        if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
            echo "Rebase en cours sans marqueurs de conflit — essayez : git rebase --continue"
        else
            echo "Si un push a échoué (historique divergé), utilisez 'good s' et non 'good r'."
        fi
        exit 0
    fi
    echo "Fichiers en conflit:"
    echo "$CONFLICTS"
    _print_sep
    while IFS= read -r FILE; do
        [ -z "$FILE" ] && continue
        echo "Résolution IA: $FILE"
        CONTENT=$(cat "$FILE")
        RESOLVED=$(_ai "Tu es un expert en résolution de conflits git.
Analyse ce fichier avec des marqueurs de conflit (<<<<<<, =======, >>>>>>>) et résous-les intelligemment.
Fusionne les deux versions quand c'est possible, ou choisit la meilleure version en fonction du contexte.
Retourne UNIQUEMENT le contenu final du fichier, sans marqueurs de conflit, sans balises markdown.

FICHIER: $FILE
---
$CONTENT" || echo "")
        if [ -n "$RESOLVED" ]; then
            if ! echo "$RESOLVED" | python3 "$GOOD_LIB/py/conflict_markers.py" 2>/dev/null; then
                echo "✗ Marqueurs de conflit restants: $FILE"
                FAILED+=("$FILE")
                continue
            fi
            echo "$RESOLVED" > "$FILE"
            git add "$FILE"
            echo "✓ Résolu: $FILE"
        else
            echo "✗ Résolution manuelle requise: $FILE"
            FAILED+=("$FILE")
        fi
    done <<< "$CONFLICTS"
    if [ ${#FAILED[@]} -gt 0 ]; then
        echo ""
        echo "Fichiers à résoudre manuellement: ${FAILED[*]}"
        exit 1
    fi
    if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
        echo "Continuation du rebase..."
        GIT_EDITOR=true git rebase --continue
    elif [ -f ".git/MERGE_HEAD" ]; then
        echo "Continuation du merge..."
        GIT_EDITOR=true git commit --no-edit
    fi
    echo "✓ Tous les conflits résolus."
    _good_event_meta '{"conflicts_resolved":true}'
}

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
