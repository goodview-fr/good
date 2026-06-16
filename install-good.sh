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

if ! ollama list &>/dev/null; then
    ollama serve &>/dev/null &
    sleep 2
fi

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

if ! gh auth status &>/dev/null; then
    warn "GitHub non authentifié — lance la connexion..."
    gh auth login
else
    ok "GitHub authentifié ($(gh auth status 2>&1 | grep 'Logged in' | xargs))"
fi

# ─── 3. Script good + lib/ ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GOOD_ROOT="$SCRIPT_DIR"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/good"

install -m 755 "$SCRIPT_DIR/good" "$HOME/.local/bin/good"
rm -rf "$HOME/.local/share/good/lib"
cp -a "$SCRIPT_DIR/lib" "$HOME/.local/share/good/"
find "$HOME/.local/share/good/lib" -name '*.py' -exec chmod 644 {} \;
find "$HOME/.local/share/good/lib" -name '*.sh' -exec chmod 644 {} \;
ok "good installé dans ~/.local/bin/good (lib dans ~/.local/share/good/lib)"

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
for alias_name in aic aip ais air; do
    if git config --global "alias.$alias_name" >/dev/null 2>&1; then
        existing="$(git config --global "alias.$alias_name")"
        if [[ "$existing" != *"good"* ]]; then
            warn "Alias git $alias_name déjà défini ($existing) — non écrasé"
            continue
        fi
    fi
    case "$alias_name" in
        aic) git config --global alias.aic '!good commit' ;;
        aip) git config --global alias.aip '!good push' ;;
        ais) git config --global alias.ais '!good sync' ;;
        air) git config --global alias.air '!good resolve' ;;
    esac
done
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

echo ""
echo "=== Installation terminée ==="
echo ""
echo "  good c    → commit avec message IA"
echo "  good p    → push GitHub"
echo "  good s    → sync complet"
echo "  good r    → résoudre conflits"
echo "  good dev  → stop|status|start serveur de dev"
echo "  good health → santé du projet"
echo "  good stats  → activité développeur"
echo "  good report → rapport manager (+ --sync Goodview)"
echo "  good i    → init git + lier à Goodview (OAuth)"
echo "  good info → afficher la liaison Goodview"
echo "  good update → mettre à jour le CLI (+ contexte Goodview si lié)"
echo ""
