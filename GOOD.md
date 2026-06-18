# good — Aide-mémoire

**Version actuelle : 1.2.0** — `good --version`

`good` est un outil en ligne de commande qui automatise les opérations git courantes
en utilisant l'IA locale (qwen3:8b via Ollama) pour générer les messages de commit
et résoudre les conflits. Disponible dans tous tes projets.

---

## Les commandes

### `good c` — Committer

**Quand l'utiliser :** tu as modifié des fichiers et tu veux sauvegarder une version.

Ce que ça fait, dans l'ordre :
1. Stage automatiquement tous les fichiers modifiés (`git add -A`)
2. Analyse ce qui a changé (le diff)
3. Génère un message de commit adapté via l'IA
4. Te le propose — tu peux valider, refuser, ou l'éditer

```
Valider? [Y/n/e=éditer]
  Y       → commit avec le message proposé
  n       → annule
  e       → tu saisis ton propre message
```

Format des messages générés : **Conventional Commits**
```
feat(login): add JWT refresh token
fix(api): handle null response on timeout
refactor(db): simplify query builder
```

---

### `good p` — Pousser vers GitHub

**Quand l'utiliser :** tu veux envoyer ton travail sur GitHub.

Ce que ça fait :
1. Committe les changements en cours (si il y en a) — comme `good c`
2. Si tu refuses le commit, **le push est annulé** (pas de push partiel)
3. Si le projet n'a jamais été pushé : **crée le repo GitHub automatiquement** et demande public ou privé
4. Push sur la branche courante (y compris premier push si la branche distante n'existe pas encore)

```bash
good p
good p --no-commit    # push sans auto-commit
good -y p             # skip les confirmations
```

---

### `good s` — Synchroniser (sync)

**Quand l'utiliser :** tu travailles sur plusieurs machines, ou tu collabores avec quelqu'un
et tu veux intégrer les derniers changements distants tout en envoyant les tiens.

Ce que ça fait :
1. Committe tes changements locaux
2. Récupère les nouveaux commits depuis GitHub (`git fetch`)
3. Intègre les changements distants proprement (`git rebase`) — sans commit de merge inutile
4. Push le tout

Si des conflits apparaissent pendant le rebase, le script s'arrête et te dit de lancer `good r`.

```bash
good s --no-commit    # sync sans auto-commit
```

---

### `good r` — Résoudre les conflits

**Quand l'utiliser :** après un `good s` ou un `git merge` qui a échoué à cause de conflits.

Un conflit git, c'est quand deux versions du même fichier sont incompatibles :
```
<<<<<<< HEAD
ton code local
=======
code venu de GitHub
>>>>>>> origin/main
```

Ce que ça fait :
1. Détecte tous les fichiers en conflit
2. Envoie chaque fichier à l'IA pour qu'elle fusionne les deux versions intelligemment
3. Écrase le fichier avec la version résolue (rejet si marqueurs `<<<<<<<` restants)
4. Continue automatiquement le rebase ou merge interrompu (`git commit --no-edit` pour les merges)

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
3. Affiche un aperçu (diff masqué pour secrets) — validation comme `good c` :

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
Nouveau projet          →  good init (+ good p pour GitHub)
Voir liaison Goodview   →  good info
Mettre à jour           →  good update
Sauvegarder             →  good c
Envoyer sur GitHub      →  good p
Récupérer + envoyer     →  good s
Conflit à résoudre      →  good r
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

### `good dog` — Assistant interactif (style Claude Code)

**Quand l'utiliser :** pour discuter avec l'IA sur le projet, poser des questions, obtenir de l'aide au code — comme `claude`, mais en local via Ollama.

```bash
good dog                         # session interactive (stream + file d'attente)
good dog -p "explique ce dépôt"  # réponse unique streamée (mode print)
good dog --model qwen3:8b        # surcharger le modèle pour cette session
good dog --verbose               # afficher la durée de réponse
echo "…" | good dog -p           # question via stdin
dog                              # alias (install-good.sh)
```

Prérequis : Ollama **0.20+** installé et démarré (`ollama serve`), modèle `qwen3:8b` (`ollama pull qwen3:8b`).
Le prompt système (contexte projet, branche git, status) est envoyé via l'API `/api/chat` — le flag `ollama run --system` n'existe pas en 0.24.

**Streaming :** les tokens s'affichent au fil de l'eau (stdout flush) — mode print et interactif.

**File d'attente (style Claude CLI) :** pendant qu'une réponse est générée, tapez un message puis Entrée pour le mettre en file (`⏳ N message(s) en file`). Les messages en file sont traités dans l'ordre à la fin de la réponse courante. Prompt : `❯`.

| Raccourci | Action |
|---|---|
| Entrée (pendant génération) | Mettre le message en file |
| Ctrl+C ou Échap | Annuler la génération en cours |
| Ctrl+D | Quitter la session |
| `/clear` | Effacer l'historique |
| `/bye` | Quitter |

Session interactive : `/clear` efface l'historique, `/bye` ou Ctrl+D pour quitter.

Le prompt système inclut le répertoire courant, la branche git et un extrait du `git status`.
Pour modifier des fichiers automatiquement, utilise plutôt `good ai <instruction>`.

---

## Sous le capot

- Modèle IA : **qwen3:8b** via Ollama (local, gratuit, aucun crédit consommé)
- Architecture modulaire : `good` (entry) + `lib/*.sh` + `lib/py/*.py`
- Script installé dans : `~/.local/bin/good`
- Bibliothèque installée dans : `~/.local/share/good/lib/`
- Aliases git disponibles : `git aic`, `git aip`, `git ais`, `git air`
- Flag global `-y` / `--yes` pour skip les confirmations
- Tests : `bats tests/bats/` et `python3 -m unittest discover -s tests/pytest`
