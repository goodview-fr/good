# good

CLI shell qui automatise le workflow **Git + Goodview** : commits assistés par IA, push/sync GitHub, résolution de conflits, liaison OAuth avec un projet client, et tâches en langage naturel (démarrage, diagnostic, modifications de fichiers).

**Version actuelle :** `1.0.3` — vérifiable avec `good --version`.

---

## Prérequis

| Outil | Rôle |
|---|---|
| **Git** | Dépôts locaux, commits, rebase |
| **Ollama** + modèle **qwen3:8b** (~5,2 Go) | IA locale (défaut) — commits, conflits, modifications |
| **Claude Code CLI** (`claude`, optionnel) | IA via `good settings claude` — authentification gérée par le CLI |
| **GitHub CLI** (`gh`) | Création de dépôts, push, authentification GitHub |
| **python3** | `good init`, `good info`, `good update`, `good ai` |
| **curl** | OAuth Goodview, téléchargement des mises à jour |

Le script d'installation configure aussi `~/.local/bin` dans le `PATH` et les alias git `git aic` / `aip` / `ais` / `air`.

---

## Installation rapide

Clone le dépôt et lance le script d'installation (Ollama, modèle IA, `gh`, binaire `good`, PATH, aliases) :

```bash
git clone https://github.com/goodview-fr/good.git /tmp/good \
  && bash /tmp/good/install-good.sh
```

One-liner sans clone git (télécharge les deux fichiers requis dans un dossier temporaire) :

```bash
tmpdir=$(mktemp -d) \
  && curl -fsSL https://raw.githubusercontent.com/goodview-fr/good/main/install-good.sh -o "$tmpdir/install-good.sh" \
  && curl -fsSL https://raw.githubusercontent.com/goodview-fr/good/main/good -o "$tmpdir/good" \
  && bash "$tmpdir/install-good.sh"
```

> **Note :** `install-good.sh` doit trouver le fichier `good` dans le même répertoire — un simple `curl … | bash` ne suffit pas.

Relancez le terminal (ou `source ~/.bashrc` / `source ~/.zshrc`) après l'installation.

---

## Installation manuelle

### 1. Installer le CLI

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/goodview-fr/good/main/good \
  -o ~/.local/bin/good
chmod +x ~/.local/bin/good
export PATH="$HOME/.local/bin:$PATH"   # à ajouter dans ~/.bashrc ou ~/.zshrc
```

### 2. Ollama et modèle IA

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen3:8b
```

### 3. GitHub CLI

Installez [GitHub CLI](https://cli.github.com/) puis authentifiez-vous :

```bash
gh auth login
```

### 4. Aliases git (optionnel)

```bash
git config --global alias.aic '!good commit'
git config --global alias.aip '!good push'
git config --global alias.ais '!good sync'
git config --global alias.air '!good resolve'
```

Vérifiez l'installation :

```bash
good --version
good help
```

---

## Utilisation

| Commande | Description |
|---|---|
| `good c` | Stage tout, propose un message de commit (IA), commit |
| `good p` | Commit si besoin, crée le repo GitHub si absent, push |
| `good s` | Commit + fetch + rebase + push |
| `good r` | Résout les conflits git avec l'IA |
| `good init` | `git init` + liaison OAuth à un projet Goodview |
| `good info` | Affiche la liaison Goodview du dépôt courant |
| `good update` | Met à jour le CLI (manifest Goodview ou repli GitHub) |
| `good settings` | Choisir le fournisseur IA (`ollama` ou `claude`) |
| `good ai <instruction>` | Tâche en langage naturel (démarrage, diagnostic, edits) |
| `good l` | Historique git graphique (20 commits) |
| `good st` | Status court + 5 derniers commits |

**Premier projet :**

```bash
cd mon-projet
good init          # lie à Goodview (compte admin requis)
good c             # commit avec message IA
good p             # push sur GitHub
```

**Dev local Goodview :**

```bash
export GOODVIEW_URL=http://localhost:8000
good init
```

**IA Claude (CLI locale) :**

```bash
good settings claude       # nécessite la commande claude (Claude Code)
good settings              # vérifier la config
```

---

## Documentation complète

Pour le détail des commandes, la sécurité, `good ai`, la checklist de release et le fonctionnement interne, voir **[GOOD.md](./GOOD.md)**.

---

## Mise à jour

```bash
good update              # CLI + contexte Goodview si projet lié
good update --deps       # + composer install / npm install
good update --force      # réinstalle même si déjà à jour
```

---

## Licence

Projet interne [Goodview](https://www.goodview.fr) — dépôt [goodview-fr/good](https://github.com/goodview-fr/good).
