# good — Aide-mémoire

**Version actuelle : 1.3.1** — `good --version`

`good` est un outil en ligne de commande pour le workflow Git + Goodview :
résolution de conflits IA, assistant `good dog` (commit/push via git), liaison projet Goodview.
Disponible dans tous tes projets.

---

## Les commandes

### Git — commit, push, sync via `good dog`

Les anciennes commandes `good c`, `good p`, `good s` ont été retirées.

**Pour committer, pousser ou synchroniser**, dis-le simplement dans dog :

```bash
good dog
# « committe et pousse » / « synchronise »
```

Dog exécute git directement (`add`, `commit`, `fetch`, `rebase`, `push`) **sans confirmation** (défaut). Mode agent activé par défaut.

Messages de commit : **Conventional Commits** en anglais (`feat(scope): description`).

Sync typique en cas de divergence :
```bash
git fetch origin && git rebase origin/<branche> && git push -u origin <branche>
```

---

### Conflits git — via `good dog`

**Quand :** rebase/merge en conflit.

Dis-le à dog : « résous les conflits » ou `/resolve`. Dog appelle `resolve_conflicts()` (IA + `git add` + rebase/merge continue).

---

### `good i` — Initialiser et lier à Goodview

**Quand l'utiliser :** pour un nouveau dépôt local que tu veux rattacher à un projet client Goodview.

Ce que ça fait :
1. `git init` si le dossier n'est pas encore un dépôt git
2. Ouvre le navigateur pour une connexion OAuth Goodview (compte admin requis)
3. Te propose de choisir le projet client à lier (auto-détection si le remote GitHub correspond)
4. Enregistre la liaison dans `.good/config.json` (gitignored, permissions 600)
5. Attache le dépôt GitHub au projet Goodview si le remote `origin` est reconnu

```bash
cd mon-projet
good init
# → Connexion OAuth dans le navigateur
# → Sélection du projet Goodview
```

Variables utiles pour le dev local :
```bash
export GOODVIEW_URL=http://localhost:8000
good init
```

En production, l'URL par défaut est `https://www.goodview.fr` (`goodview.fr` redirige le navigateur mais son API `/api/*` pointe vers un autre site).

---

### `good info` — Voir la liaison Goodview

Affiche le client, le projet, les URLs d'environnement et le dépôt liés au dossier courant.

Si le dépôt n'est pas lié, invite à lancer `good init`.

---

### `good unlink` — Supprimer la liaison Goodview

Supprime `.good/config.json` sans relancer OAuth. Utile pour changer de projet ou nettoyer.

---

### `good update` / `good u` — Mettre à jour good et le contexte Goodview

**Quand l'utiliser :** pour récupérer la dernière version du CLI et rafraîchir les métadonnées du projet lié (URLs dev/prod, nom client, etc.).

Ce que ça fait :
1. Compare la version locale du CLI avec le manifest Goodview (ou GitHub en repli)
2. Télécharge et installe la dernière version dans `~/.local/bin/good` + `~/.local/share/good/lib/`
3. Si `.good/config.json` existe : rafraîchit le cache projet depuis l'API Goodview
4. Option `--deps` : lance `composer install` et/ou `npm install` si les fichiers sont présents

```bash
good update              # CLI + contexte Goodview
good update --deps       # + dépendances du projet
good update --force      # réinstalle le CLI même si déjà à jour
```

Sans projet lié : met à jour uniquement le CLI (repli GitHub `goodview-fr/good`).

---

### `good ai` / `good do` — Tâche en langage naturel

**Quand l'utiliser :** pour agir sur le projet sans tout faire à la main — lancer les services,
diagnostiquer une erreur « connection refused », ou modifier des fichiers via l'IA.

Syntaxe bash (le `#` seul démarre un commentaire, d'où ces formes) :

```bash
good ai deploy                         # checklist déploiement explicite
good ai lance le projet
good ai start                          # sous-commande explicite (sans classifieur)
good ai diagnose                       # diagnostic explicite
good ai edit modifier routes/api.php   # modification de fichiers
good ai connection refused sur 8000
good do ajoute une route health dans routes/api.php
good '#' 'lance le projet'   # syntaxe « # message »
good -y ai edit corrige typo dans README.md   # skip confirmations
```

#### `good dev` — Cycle de vie du serveur de dev

```bash
good dev start     # lance le projet (comme good ai start)
good dev status    # PID, logs récents, health check
good dev stop      # arrête le process enregistré dans .good/dev.pid
```

---

| Intent détecté | Mots-clés typiques | Action |
|---|---|---|
| **Démarrage** | lance, démarre, start, run | Vérifie les ports, propose `composer dev` ou `npm run dev` |
| **Diagnostic** | refused, connexion, port, erreur | Teste Laravel (8000), Vite (5173), `docker ps`, lit `.env` |
| **Déploiement** | déploie, deploy, production, clever, mise en prod | Checklist git + `good dog --agent` + URL prod (confirmation, pas d'auto-deploy) |
| **Modification** | modifier, ajoute, corrige, fichier | Propose des edits JSON comme avant (Ollama requis) |

Pour **goodview.fr** :
- Démarrage : `composer dev` (inclut `composer stack:up` + artisan + Vite)
- Vérifications : http://127.0.0.1:8000 et port 5173
- Messages « connexion refusée » en français avec pistes de correction

#### Démarrage / diagnostic

1. Détecte le type de projet (`composer.json`, `package.json`, `artisan`)
2. Vérifie si les services répondent déjà
3. Affiche un diagnostic (services, Docker, suggestions `.env`)
4. Propose d'exécuter la commande de démarrage — **confirmation obligatoire** :

```
Exécuter cette commande? [Y/n]
  Y  → lance en arrière-plan (logs dans `.good/dev.log`)
  n  → annule
```

Commandes exécutables (liste blanche, jamais destructives) :
`composer dev`, `composer stack:up`, `composer postgres:up`, `npm run dev`, `pnpm run dev`,
`make dev`, `docker compose up -d`, `bash docker/scripts/ensure-dev-up.sh`

Détection élargie : Laravel, npm, pnpm, Makefile, docker-compose.

#### Modifications de fichiers (intent « edit »)

1. Rassemble le contexte (racine git, liaison Goodview, `git status`, fichiers clés)
2. Demande à l'IA (Ollama) de proposer des modifications concrètes en JSON
3. Affiche un aperçu (diff masqué pour secrets) — validation interactive :

```
Appliquer ces modifications? [Y/n/e=éditer l'instruction]
  Y  → écrit les fichiers
  n  → annule
  e  → saisir une nouvelle instruction et relancer
```

Sécurité :
- Uniquement des fichiers dans le dépôt git (pas de `..`, pas de `.git/`)
- `.good/config.json` et tout `.good/` sont protégés
- Aucune commande shell destructrice ; exécution uniquement sur liste blanche
- Les valeurs sensibles (SECRET, TOKEN, PASSWORD…) sont masquées à l'affichage

---

### `good l` — Voir l'historique

Affiche les 20 derniers commits sous forme graphique, avec les branches et tags.

```
* a3f1c2e (HEAD -> main) feat(auth): add password reset
* 9b2d4f1 fix(api): handle empty response
* 7e8c3a0 feat: initial commit
```

---

### `good st` — Voir l'état rapide

Affiche en deux blocs :
- Les fichiers modifiés / non commités (status court)
- Les 5 derniers commits

---

### `good health` — Santé du projet

Score 0–100 basé sur l'état git, les conflits, le serveur de dev et les outils (Ollama, gh).

```bash
good health
# → Score, branche, conflits, dev server, avertissements
```

---

### `good stats` — Vue développeur

Ton activité `good` sur la période (commits, push, sync, resolve, actions IA).

```bash
good stats              # 7 derniers jours (défaut)
good stats --days 30
good stats --sync       # pousse les events vers Goodview
```

Journal local : `.good/activity.jsonl` (gitignored).

---

### `good report` — Vue manager

Synthèse équipe pour un lead : activité agrégée par développeur, santé actuelle, sync Goodview.

```bash
good report --days 7
good report --sync      # sync + rapport
```

Remonte vers `POST /v1/admin/good-cli/events` si le projet est lié via `good init`.

---

### `good telemetry` — Gérer le suivi

```bash
good telemetry status   # activé/désactivé, events en attente
good telemetry on|off   # opt-in / opt-out (GOOD_TELEMETRY=0 aussi)
good telemetry sync     # sync manuelle vers Goodview
```

Données enregistrées : commande, statut, durée, branche, email git — **jamais** le contenu des diffs ou fichiers.

---

## Résumé visuel

```
Nouveau projet          →  good init (+ good dog --agent pour GitHub)
Voir liaison Goodview   →  good info
Mettre à jour           →  good update
Committer / push / sync →  good dog --agent (« committe et pousse »)
Conflit à résoudre      →  good dog (« résous les conflits » ou /resolve)
Tâche IA (action)      →  good ai <instruction>
Serveur de dev         →  good dev stop|status|start
Santé du projet        →  good health
Mon activité           →  good stats
Rapport équipe         →  good report --sync
Délier Goodview        →  good unlink
Voir l'historique       →  good l
Voir l'état             →  good st
```

---

### `good dog` — Assistant interactif et orchestrateur de tâches

**Quand l'utiliser :** pour discuter avec l'IA, gérer des tâches en parallèle, maintenir une todo list — comme `claude`, en local via Ollama ou via DeepSeek API.

```bash
good dog                              # session interactive (stream + file d'attente)
good dog -p "explique ce dépôt"       # réponse unique streamée (mode print)
good dog --model qwen3:8b             # surcharger le modèle pour cette session
good dog --web                        # activer la recherche web (DuckDuckGo)
good dog --multitask                  # mode multitask (éditions de fichiers en background)
good dog --agent                      # mode agent ReAct (run_command, docker, npm…)
GOOD_DOG_MULTITASK=1 good dog         # mode multitask via variable d'environnement
GOOD_DOG_AGENT=0 good dog             # désactiver l'agent auto (avec DEEPSEEK_API_KEY)
GOOD_WEB_SEARCH=1 good dog            # recherche web via variable d'environnement
good dog --verbose                    # afficher la durée de réponse
echo "…" | good dog -p               # question via stdin
dog                                   # alias (install-good.sh)

# Providers
good dog --deepseek                   # DeepSeek API (deepseek-chat)
good dog --ollama                     # Ollama local (qwen3:8b)
good dog --provider deepseek          # équivalent à --deepseek
DEEPSEEK_API_KEY=sk-... good dog      # active DeepSeek automatiquement
good dog --model deepseek-reasoner    # surcharger le modèle DeepSeek
```

**Provider sélectionné automatiquement :**
- Si `DEEPSEEK_API_KEY` est défini → DeepSeek (`deepseek-chat`)
- Si `GOOD_AI_PROVIDER=deepseek|ollama` → provider forcé
- Sinon → Ollama local (`qwen3:8b`)

**Variables d'environnement :**

| Variable | Rôle | Défaut |
|---|---|---|
| `DEEPSEEK_API_KEY` | Active DeepSeek | — |
| `DEEPSEEK_MODEL` | Modèle DeepSeek | `deepseek-chat` |
| `DEEPSEEK_BASE_URL` | URL API DeepSeek | `https://api.deepseek.com` |
| `GOOD_OLLAMA_MODEL` | Modèle Ollama | `qwen3:8b` |
| `GOOD_AI_PROVIDER` | Provider forcé | auto |
| `GOOD_WEB_SEARCH` | Recherche web | `0` |
| `GOOD_DOG_MULTITASK` | Mode multitask | `0` |
| `GOOD_DOG_AGENT` | Mode agent ReAct | auto si `DEEPSEEK_API_KEY` (`GOOD_DOG_AGENT=0` pour désactiver) |

**Mode agent (`--agent` / `-A` / `GOOD_DOG_AGENT=1`) :** boucle ReAct (max 15 étapes) avec 8 outils : `read_file`, `write_file`, `list_directory`, `search_files`, `run_git`, `run_command`, `run_shell`, `web_search`. L'agent exécute git (add, commit, fetch, rebase, push) via `run_git` et des commandes shell (docker, npm, composer…) via `run_command`. Les commandes en lecture seule s'exécutent sans confirmation ; commit/push/stop/down demandent confirmation. `write_file` demande toujours confirmation. **Activé par défaut** quand `DEEPSEEK_API_KEY` est définie (désactiver avec `GOOD_DOG_AGENT=0`). Recommandé pour « committe et pousse », « lance le serveur », etc.

**Prérequis Ollama :** Ollama **0.20+** installé et démarré (`ollama serve`), modèle `qwen3:8b` (`ollama pull qwen3:8b`). Non requis si DeepSeek est configuré.

**Contexte Goodview :** si `.good/config.json` existe, dog injecte client, projet, URLs dev/prod et dépôt (sans token).

**Documentation :** la commande `/docs` charge `README.md` + `GOOD.md` pour le prochain message.

**Recherche web (opt-in) :** avec `--web` ou `GOOD_WEB_SEARCH=1`, dog interroge DuckDuckGo lite et injecte les résultats avant la réponse.

**Déploiement :** « déploie en prod » déclenche une checklist (`git status`, commit/push via dog, URL prod) — confirmation requise, jamais de déploiement automatique.

**Conflits git :** au démarrage, dog détecte les conflits et les résout automatiquement. `/resolve` relance la résolution.

**Système de tâches :** dog peut lancer des `good ai edit` en arrière-plan (threads daemon). En mode `--multitask`, toute demande de modification de fichiers est automatiquement lancée en background. Si l'IA propose plusieurs tâches dans un bloc `{"tasks": [...]}`, dog propose de toutes les lancer en parallèle.

```
/tasks  →  #1 ✓ done     Ajouter la route /health
           #2 ⠋ running  Mettre à jour les tests
              └ Analyse du projet…
           #3 ⏸ pending  Mettre à jour CHANGELOG.md
```

**Todo list persistée :** les todos sont stockés dans `.good/todos.json` (gitignored).

**UI moderne :** header avec box-drawing, markdown en temps réel, spinner, timing après chaque réponse.

**Streaming :** Ollama (ndjson) et DeepSeek/OpenAI (SSE) streamés ligne par ligne.

**File d'attente :** pendant qu'une réponse se génère, tapez un message pour le mettre en file (`⏳ N en file`). Prompt : `❯`.

| Raccourci / commande | Action |
|---|---|
| Entrée (pendant génération) | Mettre le message en file |
| Ctrl+C ou Échap | Annuler la commande en cours · `/resume` pour relancer |
| Ctrl+C ×2 | Quitter proprement (sans traceback) |
| Ctrl+D | Quitter la session |
| `/clear` | Effacer l'historique et vider l'écran |
| `/docs` | Injecter README.md + GOOD.md pour le prochain message |
| `/model <nom>` | Changer de modèle en cours de session |
| `/provider` | Afficher le provider et le modèle actifs |
| `/context` | Taille de l'historique (messages, caractères, barre de tokens) |
| `/copy` | Copier la dernière réponse dans le presse-papiers |
| `/help` | Aide complète des commandes |
| `/bye` | Quitter |
| `/tasks` | Afficher les tâches en cours / terminées |
| `/task <instruction>` | Lancer une tâche en arrière-plan |
| `/stop [id]` | Arrêter une tâche (ou toutes) |
| `/edit <id> <instr>` | Modifier / relancer une tâche |
| `/todo` | Afficher la liste de todos |
| `/todo add <texte>` | Ajouter un todo |
| `/todo done <id>` | Marquer un todo comme fait |
| `/todo del <id>` | Supprimer un todo |
| `/todo clear` | Supprimer tous les todos terminés |
| `/resolve` | Résoudre les conflits git (IA) |
| `/resume` | Reprendre la commande interrompue (Ctrl+C) |

Le prompt système est construit dynamiquement (`SystemPromptBuilder`) : identité, capacités, stack détectée (Laravel/Vue/React/Electron), git, Goodview.
Les demandes explicites (créer/modifier un fichier, déployer) passent par le pipeline `good ai` en mode standard. Démarrage, diagnostic et commandes shell (« lance le serveur », « arrête docker ») sont gérés par l'agent (`run_command`) — activé par défaut avec DeepSeek. En mode classique sans agent, dog propose les commandes détectées sans les exécuter.

---

## Sous le capot

- Modèle IA : **qwen3:8b** via Ollama (local, gratuit) ou **deepseek-chat** via DeepSeek API (cloud)
- Provider sélectionné automatiquement selon `DEEPSEEK_API_KEY` / `GOOD_AI_PROVIDER`
- Streaming Ollama : ndjson `/api/chat` · DeepSeek/OpenAI : SSE `/v1/chat/completions`
- Modules Python (`classify_intent`, `dog_context`) importés directement — pas de sous-processus par message
- Architecture modulaire : `good` (entry) + `lib/*.sh` + `lib/py/*.py`
- Script installé dans : `~/.local/bin/good`
- Bibliothèque installée dans : `~/.local/share/good/lib/`
- Aliases git disponibles : `git aic`, `git aip`, `git ais`, `git air`
- Flag global `-y` / `--yes` pour skip les confirmations
- Tests : `bats tests/bats/` et `python3 -m unittest discover -s tests/pytest`
