# good

CLI **Git + Goodview** : commits IA (Ollama), push/sync GitHub, résolution de conflits, liaison OAuth projet, tâches en langage naturel, suivi d'activité et santé du dépôt.

**Version :** `1.2.0` — `good --version`

---

## Installation

```bash
git clone https://github.com/goodview-fr/good.git
cd good
bash install-good.sh
```

Installe `~/.local/bin/good` + `~/.local/share/good/lib/` (modules, télémétrie, tests).

Relance le terminal ou `source ~/.bashrc`.

---

## Commandes principales

| Commande | Description |
|----------|-------------|
| `good c` | Commit avec message IA |
| `good p` / `good s` | Push / sync (fetch + rebase + push) |
| `good r` | Résolution de conflits IA |
| `good ai <…>` | Tâche en langage naturel |
| `good dev` | Serveur de dev (start/stop/status) |
| `good health` | Santé du projet (score 0–100) |
| `good stats` | Activité développeur |
| `good report` | Rapport manager (+ sync Goodview) |
| `good init` | Git + liaison OAuth Goodview |
| `good update` | Mise à jour CLI + cache projet |

Documentation complète : **[GOOD.md](./GOOD.md)**

---

## Mise à jour

```bash
good update
# ou depuis le clone :
bash install-good.sh
```

---

## Développement

```bash
python3 -m unittest discover -s tests/pytest -v
bats tests/bats/
shellcheck good install-good.sh lib/*.sh
```

---

Projet [Goodview](https://www.goodview.fr) — [goodview-fr/good](https://github.com/goodview-fr/good)
