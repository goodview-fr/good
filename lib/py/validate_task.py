#!/usr/bin/env python3
"""Validate AI-proposed file modifications before apply."""
import json
import os
import sys


def validate(root: str, payload: str) -> dict:
    root = os.path.realpath(root)
    data = json.loads(payload)
    valid_files = []
    errors = []

    for item in data.get("files") or []:
        if not isinstance(item, dict):
            errors.append("Entrée fichier invalide.")
            continue
        path = (item.get("path") or "").strip().replace("\\", "/")
        action = (item.get("action") or "").strip().lower()
        if not path or path.startswith("/") or ".." in path.split("/"):
            errors.append(f"Chemin refusé: {path or '?'}")
            continue
        norm = os.path.normpath(path)
        if norm.startswith("..") or norm == ".good/config.json" or norm.startswith(".good/"):
            errors.append(f"Chemin protégé ou hors dépôt: {path}")
            continue
        full = os.path.realpath(os.path.join(root, norm))
        if not (full == root or full.startswith(root + os.sep)):
            errors.append(f"Hors du dépôt: {path}")
            continue
        if full.startswith(os.path.join(root, ".git") + os.sep) or full == os.path.join(root, ".git"):
            errors.append(f"Modification .git interdite: {path}")
            continue
        if action not in {"create", "modify", "delete"}:
            errors.append(f"Action inconnue pour {path}: {action}")
            continue
        if action in {"create", "modify"} and not isinstance(item.get("content"), str):
            errors.append(f"Contenu manquant pour {path}")
            continue
        if action == "modify" and not os.path.isfile(full):
            errors.append(f"Fichier absent pour modification: {path}")
            continue
        if action == "create" and os.path.exists(full):
            errors.append(f"Fichier déjà présent (utilise modify): {path}")
            continue
        if action == "delete" and not os.path.exists(full):
            errors.append(f"Fichier absent pour suppression: {path}")
            continue
        valid_files.append({"path": norm, "action": action, "content": item.get("content", "")})

    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        sys.exit(1)

    data["files"] = valid_files
    return data


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(2)
    result = validate(sys.argv[1], sys.argv[2])
    print(json.dumps(result, ensure_ascii=False))
