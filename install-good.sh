#!/usr/bin/env bash
# Installation de good sur une nouvelle machine
# Usage: bash install-good.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; }

echo ""
echo "=== Installation de good ==="
echo ""

# ─── 1. Ollama ────────────────────────────────────────────────────────────────
if ! command -v ollama &>/dev/null; then
    warn "Ollama non trouvé — installation..."
    curl -fsSL https://ollama.com/install.sh | sh
    ok "Ollama installé"
else
    ok "Ollama déjà installé ($(ollama --version 2>/dev/null | head -1))"
fi

# Démarrer ollama si pas actif
if ! ollama list &>/dev/null; then
    ollama serve &>/dev/null &
    sleep 2
fi

# Télécharger qwen3:8b si absent
if ! ollama list 2>/dev/null | grep -q "qwen3:8b"; then
    warn "Téléchargement de qwen3:8b (5.2 Go, patience)..."
    ollama pull qwen3:8b
    ok "qwen3:8b téléchargé"
else
    ok "qwen3:8b déjà présent"
fi

# ─── 2. GitHub CLI ────────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
    warn "GitHub CLI non trouvé — installation..."
    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt-get update -q && sudo apt-get install gh -y -q
    elif command -v brew &>/dev/null; then
        brew install gh
    else
        err "Installe GitHub CLI manuellement : https://cli.github.com"
        exit 1
    fi
    ok "GitHub CLI installé"
else
    ok "GitHub CLI déjà installé"
fi

# Vérifier l'auth GitHub
if ! gh auth status &>/dev/null; then
    warn "GitHub non authentifié — lance la connexion..."
    gh auth login
else
    ok "GitHub authentifié ($(gh auth status 2>&1 | grep 'Logged in' | xargs))"
fi

# ─── 3. Script good ──────────────────────────────────────────────────────────
mkdir -p "$HOME/.local/bin"

cat > "$HOME/.local/bin/good" << 'GITAI_SCRIPT'
#!/usr/bin/env bash
# good - Git + IA workflow helper (utilise ollama, pas Cursor)
set -euo pipefail

COMMAND="${1:-help}"

_ai() {
    echo "$@" | ollama run qwen3:8b --nowordwrap 2>/dev/null \
        | sed '/^Thinking\.\.\./,/^\.\.\.done thinking\./d' \
        | sed 's/^`\+//;s/`\+$//;/^```/d' \
        | sed '/^[[:space:]]*$/d'
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

_generate_commit_msg() {
    local diff="$1"
    _ai "Tu es un expert git. Génère UN message de commit concis en anglais au format Conventional Commits (ex: feat(auth): add JWT refresh, fix(api): handle null response).
Analyse ce diff et retourne UNIQUEMENT le message de commit, sans guillemets, sans explication.

DIFF:
$diff"
}

_print_sep() {
    echo "──────────────────────────────────────"
}

cmd_commit() {
    _check_git
    if ! _has_staged; then
        if ! _has_changes; then
            echo "Rien à committer."
            exit 0
        fi
        echo "Stage de toutes les modifications..."
        git add -A
    fi
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
    read -rp "Valider? [Y/n/e=éditer] " ANSWER
    case "${ANSWER,,}" in
        n)    echo "Commit annulé."; exit 0 ;;
        e)    read -rp "Nouveau message: " MSG ;;
    esac
    git commit -m "$MSG"
    echo "✓ Commit: $MSG"
}

cmd_push() {
    _check_git
    if _has_changes || _has_staged; then
        cmd_commit
    fi
    BRANCH=$(git branch --show-current)
    REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
    if [ -z "$REMOTE" ]; then
        REPO=$(_repo_name)
        echo "Aucun remote. Création du repo GitHub '$REPO'..."
        read -rp "Repo privé? [Y/n] " PRIV
        if [[ "${PRIV,,}" == "n" ]]; then
            gh repo create "$REPO" --public --source=. --push
        else
            gh repo create "$REPO" --private --source=. --push
        fi
        echo "✓ Repo créé et pushé: $(git remote get-url origin)"
    else
        git push -u origin "$BRANCH"
        echo "✓ Pushé sur origin/$BRANCH"
    fi
}

cmd_sync() {
    _check_git
    if _has_changes || _has_staged; then
        echo "Changements locaux détectés → commit avant sync..."
        cmd_commit
    fi
    BRANCH=$(git branch --show-current)
    echo "Fetch origin..."
    git fetch origin 2>/dev/null || { echo "Erreur fetch (vérifier la connexion/remote)"; exit 1; }
    BEHIND=$(git rev-list "HEAD..origin/$BRANCH" --count 2>/dev/null || echo "0")
    AHEAD=$(git rev-list "origin/$BRANCH..HEAD" --count 2>/dev/null || echo "0")
    if [ "$BEHIND" -gt 0 ]; then
        echo "$BEHIND commit(s) à intégrer depuis origin/$BRANCH..."
        if ! git rebase "origin/$BRANCH"; then
            echo ""
            echo "Conflits détectés. Lance 'good resolve' pour les résoudre automatiquement."
            exit 1
        fi
    fi
    if [ "$AHEAD" -gt 0 ] || [ "$BEHIND" -gt 0 ]; then
        git push -u origin "$BRANCH"
        echo "✓ Sync terminé (origin/$BRANCH)"
    else
        echo "✓ Déjà à jour."
    fi
}

cmd_resolve() {
    _check_git
    CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -z "$CONFLICTS" ]; then
        echo "Aucun conflit détecté."
        exit 0
    fi
    echo "Fichiers en conflit:"
    echo "$CONFLICTS"
    _print_sep
    FAILED=()
    for FILE in $CONFLICTS; do
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
            echo "$RESOLVED" > "$FILE"
            git add "$FILE"
            echo "✓ Résolu: $FILE"
        else
            echo "✗ Résolution manuelle requise: $FILE"
            FAILED+=("$FILE")
        fi
    done
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
        cmd_commit
    fi
    echo "✓ Tous les conflits résolus."
}

cmd_init() {
    REPO="${2:-$(_repo_name)}"
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        git init
        echo "✓ Git initialisé"
    fi
    if ! git rev-parse HEAD > /dev/null 2>&1; then
        git add -A
        git commit -m "feat: initial commit" 2>/dev/null || true
    fi
    if ! git remote get-url origin > /dev/null 2>&1; then
        read -rp "Repo privé? [Y/n] " PRIV
        if [[ "${PRIV,,}" == "n" ]]; then
            gh repo create "$REPO" --public --source=. --push
        else
            gh repo create "$REPO" --private --source=. --push
        fi
        echo "✓ Repo GitHub créé: $(gh repo view "$REPO" --json url -q .url 2>/dev/null || echo $REPO)"
    else
        echo "Remote déjà configuré: $(git remote get-url origin)"
    fi
}

cmd_log()    { _check_git; git log --oneline --graph --decorate -20; }
cmd_status() { _check_git; git status -s; _print_sep; git log --oneline -5; }
cmd_help() {
    cat <<'EOF'
good - Git + IA (sans Cursor)

  c, commit    Stage tout + génère message AI + commit
  p, push      Commit si besoin + push GitHub (crée le repo si absent)
  s, sync      Commit + fetch + rebase + push
  r, resolve   Résout les conflits git avec l'IA
  i, init      Initialise git + crée repo GitHub
  l, log       Log git graphique (20 derniers commits)
  st, status   Status court + derniers commits
EOF
}

case "$COMMAND" in
    c|commit)   cmd_commit  ;;
    p|push)     cmd_push    ;;
    s|sync)     cmd_sync    ;;
    r|resolve)  cmd_resolve ;;
    i|init)     cmd_init    ;;
    l|log)      cmd_log     ;;
    st|status)  cmd_status  ;;
    help|-h|--help) cmd_help ;;
    *) echo "Commande inconnue: $COMMAND"; cmd_help; exit 1 ;;
esac
GITAI_SCRIPT

chmod +x "$HOME/.local/bin/good"
ok "Script good installé dans ~/.local/bin/good"

# ─── 4. PATH ──────────────────────────────────────────────────────────────────
SHELL_RC=""
if [[ "$SHELL" == *"zsh"* ]]; then
    SHELL_RC="$HOME/.zshrc"
elif [[ "$SHELL" == *"bash"* ]]; then
    SHELL_RC="$HOME/.bashrc"
fi

if [ -n "$SHELL_RC" ] && ! grep -q 'local/bin' "$SHELL_RC" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    warn "PATH mis à jour dans $SHELL_RC — relance ton terminal ou lance : source $SHELL_RC"
else
    ok "~/.local/bin déjà dans le PATH"
fi

# ─── 5. Aliases git ───────────────────────────────────────────────────────────
git config --global alias.aic '!good commit'
git config --global alias.aip '!good push'
git config --global alias.ais '!good sync'
git config --global alias.air '!good resolve'
ok "Aliases git configurés (git aic / aip / ais / air)"

# ─── 6. Config git minimale ───────────────────────────────────────────────────
if [ -z "$(git config --global user.name 2>/dev/null)" ]; then
    read -rp "Ton nom pour git (ex: Lucie Besse): " GIT_NAME
    git config --global user.name "$GIT_NAME"
fi
if [ -z "$(git config --global user.email 2>/dev/null)" ]; then
    read -rp "Ton email pour git: " GIT_EMAIL
    git config --global user.email "$GIT_EMAIL"
fi
ok "Config git : $(git config --global user.name) <$(git config --global user.email)>"

# ─── Résumé ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Installation terminée ==="
echo ""
echo "  good c    → commit avec message IA"
echo "  good p    → push GitHub"
echo "  good s    → sync complet"
echo "  good r    → résoudre conflits"
echo "  good i    → init + créer repo GitHub"
echo ""
