#!/usr/bin/env python3
"""Résolution de conflits git via IA (utilisé par good dog)."""
import os
import subprocess
import sys
from typing import Callable, Optional

_here = os.path.dirname(os.path.abspath(__file__))
if _here not in sys.path:
    sys.path.insert(0, _here)
from conflict_markers import has_conflict_markers

RESOLVE_PROMPT = """Tu es un expert en résolution de conflits git.
Analyse ce fichier avec des marqueurs de conflit (<<<<<<, =======, >>>>>>>) et résous-les intelligemment.
Fusionne les deux versions quand c'est possible, ou choisit la meilleure version en fonction du contexte.
Retourne UNIQUEMENT le contenu final du fichier, sans marqueurs de conflit, sans balises markdown.

FICHIER: {path}
---
{content}"""


def list_conflict_files(root: str) -> list[str]:
    try:
        out = subprocess.check_output(
            ["git", "diff", "--name-only", "--diff-filter=U"],
            cwd=root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return [f for f in out.splitlines() if f]
    except subprocess.CalledProcessError:
        return []


def _git_continue(root: str) -> tuple[bool, str]:
    rebase = os.path.isdir(os.path.join(root, ".git", "rebase-merge")) or os.path.isdir(
        os.path.join(root, ".git", "rebase-apply")
    )
    merge = os.path.isfile(os.path.join(root, ".git", "MERGE_HEAD"))
    env = {**os.environ, "GIT_EDITOR": "true"}
    if rebase:
        r = subprocess.run(
            ["git", "rebase", "--continue"],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            return False, (r.stderr or r.stdout or "rebase --continue échoué").strip()
        return True, "Rebase continué."
    if merge:
        r = subprocess.run(
            ["git", "commit", "--no-edit"],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            return False, (r.stderr or r.stdout or "commit merge échoué").strip()
        return True, "Merge terminé."
    return True, ""


def resolve_all(
    root: str,
    ai_fn: Callable[[str], str],
    on_progress: Optional[Callable[[str], None]] = None,
) -> tuple[bool, str]:
    """Résout tous les conflits. Retourne (succès, message résumé)."""
    root = os.path.realpath(root)
    conflicts = list_conflict_files(root)
    if not conflicts:
        rebase = os.path.isdir(os.path.join(root, ".git", "rebase-merge")) or os.path.isdir(
            os.path.join(root, ".git", "rebase-apply")
        )
        if rebase:
            ok, msg = _git_continue(root)
            if ok:
                return True, msg or "Rebase continué (aucun marqueur de conflit)."
            return False, msg
        return True, "Aucun conflit git."

    failed: list[str] = []
    lines = [f"{len(conflicts)} fichier(s) en conflit."]

    for path in conflicts:
        if on_progress:
            on_progress(f"Résolution IA: {path}")
        full = os.path.join(root, path)
        try:
            with open(full, encoding="utf-8", errors="replace") as f:
                content = f.read()
        except OSError as exc:
            failed.append(path)
            lines.append(f"✗ {path}: lecture impossible ({exc})")
            continue

        prompt = RESOLVE_PROMPT.format(path=path, content=content)
        try:
            resolved = (ai_fn(prompt) or "").strip()
        except Exception as exc:
            failed.append(path)
            lines.append(f"✗ {path}: IA ({exc})")
            continue

        if not resolved:
            failed.append(path)
            lines.append(f"✗ {path}: réponse IA vide")
            continue
        if has_conflict_markers(resolved):
            failed.append(path)
            lines.append(f"✗ {path}: marqueurs restants")
            continue

        try:
            with open(full, "w", encoding="utf-8") as f:
                f.write(resolved)
            subprocess.run(["git", "add", path], cwd=root, check=True, capture_output=True)
            lines.append(f"✓ {path}")
        except (OSError, subprocess.CalledProcessError) as exc:
            failed.append(path)
            lines.append(f"✗ {path}: {exc}")

    if failed:
        return False, "\n".join(lines + [f"Échec sur: {', '.join(failed)}"])

    ok, cont_msg = _git_continue(root)
    if not ok:
        return False, "\n".join(lines + [cont_msg])
    if cont_msg:
        lines.append(cont_msg)
    lines.append("✓ Tous les conflits résolus.")
    return True, "\n".join(lines)
