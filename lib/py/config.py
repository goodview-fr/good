#!/usr/bin/env python3
"""Read values from .good/config.json with safe error handling."""
import json
import sys


def load_value(config_path: str, key: str) -> tuple[str, int]:
    """Return (value, exit_code). exit_code 0=ok, 1=missing key, 2=invalid file."""
    try:
        with open(config_path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return "", 2
    except json.JSONDecodeError:
        return "", 2
    value = data.get(key, "")
    if value is None or value == "":
        return "", 1
    return str(value), 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(2)
    val, code = load_value(sys.argv[1], sys.argv[2])
    if code == 2:
        print("Erreur: fichier .good/config.json absent ou invalide.", file=sys.stderr)
        sys.exit(2)
    print(val)
    sys.exit(0 if code == 0 else 0)
