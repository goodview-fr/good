# good — Aide-mémoire

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

### `good i` — Initialiser un nouveau projet

**Quand l'utiliser :** pour un tout nouveau projet qui n'est pas encore sur GitHub.

Ce que ça fait :
1. `git init` — initialise le dépôt local
2. Premier commit automatique
3. Crée le repo sur GitHub (public ou privé, à ton choix)
4. Configure le remote et push

```bash
cd mon-nouveau-projet
good i
# → Repo privé? [Y/n]
```

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
Nouveau projet          →  good i
Sauvegarder             →  good c
Envoyer sur GitHub      →  good p
Récupérer + envoyer     →  good s
Conflit à résoudre      →  good r
Voir l'historique       →  good l
Voir l'état             →  good st
```

---

## Sous le capot

- Modèle IA : **qwen3:8b** via Ollama (local, gratuit, aucun crédit consommé)
- Script installé dans : `~/.local/bin/good`
- Aliases git disponibles : `git aic`, `git aip`, `git ais`, `git air`
