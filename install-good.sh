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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -m 755 "$SCRIPT_DIR/good" "$HOME/.local/bin/good"
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
echo "  good i    → init git + lier à Goodview (OAuth)"
echo "  good info → afficher la liaison Goodview"
echo ""
