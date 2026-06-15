# good — Aide-mémoire

**Version actuelle : 1.0.1** — `good --version` ou l'en-tête de `good help`.

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
2. Si le projet n'a jamais été pushé : **crée le repo GitHub automatiquement** et demande public ou privé
3. Push sur la branche courante

```bash
good p
# → Repo privé? [Y/n]   (uniquement si le repo n'existe pas encore sur GitHub)
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
3. Écrase le fichier avec la version résolue
4. Continue automatiquement le rebase ou merge interrompu

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

### `good update` — Mettre à jour good et le contexte Goodview

**Quand l'utiliser :** pour récupérer la dernière version du CLI et rafraîchir les métadonnées du projet lié (URLs dev/prod, nom client, etc.).

Ce que ça fait :
1. Compare la version locale du CLI avec le manifest Goodview (ou GitHub en repli)
2. Télécharge et installe la dernière version dans `~/.local/bin/good`
3. Si `.good/config.json` existe : rafraîchit le cache projet depuis l'API Goodview
4. Option `--deps` : lance `composer install` et/ou `npm install` si les fichiers sont présents

```bash
good update              # CLI + contexte Goodview
good update --deps       # + dépendances du projet
good update --force      # réinstalle le CLI même si déjà à jour
good --version           # affiche la version installée (ex. good v1.0.1)
```

Sans projet lié : met à jour uniquement le CLI (repli GitHub `goodview-fr/good`).

Test local sans push GitHub : site Laravel avec `GOOD_CLI_VERSION=1.0.1` et
`GOOD_CLI_DOWNLOAD_URL=file:///chemin/vers/good/good`, dépôt lié via `good init`,
puis simuler une version obsolète avec
`sed -i 's/VERSION="1.0.1"/VERSION="1.0.0"/' ~/.local/bin/good` avant `good update`.

#### Checklist release CLI

À faire **à chaque** nouvelle version du script (`good/good`, ligne `VERSION="…"`) pour que
`good update` fonctionne sur toutes les machines :

1. **Bump `VERSION`** dans `good/good` (ex. `1.0.1` → `1.0.2`).
2. **Commit + push** le dépôt [goodview-fr/good](https://github.com/goodview-fr/good) sur `main`.
   Sans ce push, le repli GitHub sert encore l’ancienne version.
3. **Vérifier le manifest GitHub** :
   ```bash
   curl -s https://raw.githubusercontent.com/goodview-fr/good/main/good | grep '^VERSION='
   ```
4. **Mettre à jour goodview.fr** : `GOOD_CLI_VERSION=<même version>` dans `.env` prod (Clever Cloud).
   Le défaut dans `config/good-cli.php` ne suffit pas si prod a une valeur explicite.
5. **Déployer goodview.fr** pour exposer `GET /api/v1/admin/good-cli/version` avec la nouvelle version.
6. **Mettre à jour `GOOD.md`** (en-tête « Version actuelle ») et `.env.example` du Site si besoin.
7. **Tester** sur une machine « propre » :
   ```bash
   sed -i 's/VERSION="[^"]*"/VERSION="0.0.0"/' ~/.local/bin/good
   good update
   ```

Si ta machine locale est **plus récente** que le manifest (dev non publié), `good update` affiche
« Rien à télécharger — publie vX sur GitHub… » au lieu de prétendre qu’une mise à jour a eu lieu.

---

### `good ai` / `good do` — Tâche en langage naturel

**Quand l'utiliser :** pour agir sur le projet sans tout faire à la main — lancer les services,
diagnostiquer une erreur « connection refused », ou modifier des fichiers via l'IA.

Syntaxe bash (le `#` seul démarre un commentaire, d'où ces formes) :

```bash
good ai lance le projet
good ai connection refused sur 8000
good ai demarre le projet ilo est refused
good ai occupe-toi de modifier .env pour ajouter TERMINAL_SERVICE_SECRET
good do ajoute une route health dans routes/api.php
good '#' 'lance le projet'   # syntaxe « # message »
```

#### Types d'actions

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
`composer dev`, `composer stack:up`, `composer postgres:up`, `npm run dev`,
`bash docker/scripts/ensure-dev-up.sh`

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
Voir l'historique       →  good l
Voir l'état             →  good st
```

---

## Sous le capot

- Modèle IA : **qwen3:8b** via Ollama (local, gratuit, aucun crédit consommé)
- Script installé dans : `~/.local/bin/good`
- Aliases git disponibles : `git aic`, `git aip`, `git ais`, `git air`
