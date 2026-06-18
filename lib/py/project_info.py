#!/usr/bin/env python3
"""Detect project stack and start commands from composer.json, package.json, Makefile."""
import json
import os
import re
import sys


_MAKEFILE_TARGETS = ("dev", "start", "serve", "up")
_PACKAGE_SCRIPTS = ("dev", "start", "serve", "watch")
_SHELL_SCRIPTS = ("start.sh", "dev.sh", "run.sh")
_COMPOSE_FILES = (
    "docker-compose.yml",
    "docker-compose.yaml",
    "compose.yml",
    "compose.yaml",
)


def _makefile_targets(content: str) -> list[str]:
    found = []
    for line in content.splitlines():
        m = re.match(r"^([a-zA-Z0-9_-]+)\s*:", line)
        if m and m.group(1) in _MAKEFILE_TARGETS:
            found.append(m.group(1))
    # Preserve order, unique
    seen = set()
    ordered = []
    for t in found:
        if t not in seen:
            seen.add(t)
            ordered.append(t)
    return ordered


def _package_manager(root: str) -> str:
    if os.path.isfile(os.path.join(root, "pnpm-lock.yaml")):
        return "pnpm"
    if os.path.isfile(os.path.join(root, "yarn.lock")):
        return "yarn"
    return "npm"


def _append_unique(commands: list[str], cmd: str) -> None:
    if cmd and cmd not in commands:
        commands.append(cmd)


def detect(root: str) -> dict:
    info = {
        "kind": "generic",
        "start_commands": [],
        "checks": [],
    }
    commands: list[str] = []

    composer_path = os.path.join(root, "composer.json")
    package_path = os.path.join(root, "package.json")
    makefile_path = os.path.join(root, "Makefile")
    good_cli = os.path.join(root, "good")
    procfile = os.path.join(root, "Procfile")
    justfile = os.path.join(root, "justfile")

    if os.path.isfile(composer_path):
        try:
            with open(composer_path, encoding="utf-8") as f:
                scripts = json.load(f).get("scripts", {})
            for key in ("dev", "stack:up", "serve", "start"):
                if key in scripts:
                    _append_unique(commands, f"composer {key}")
        except (OSError, json.JSONDecodeError):
            pass
        if os.path.isfile(os.path.join(root, "artisan")):
            info["kind"] = "laravel"
            info["checks"] = [
                {"name": "Laravel", "url": "http://127.0.0.1:8000", "port": 8000},
                {"name": "Vite", "url": "http://127.0.0.1:5173", "port": 5173},
            ]

    if os.path.isfile(package_path):
        try:
            with open(package_path, encoding="utf-8") as f:
                pkg = json.load(f)
            scripts = pkg.get("scripts", {})
            pm = _package_manager(root)
            for script in _PACKAGE_SCRIPTS:
                if script in scripts:
                    if pm == "yarn":
                        _append_unique(commands, f"yarn {script}")
                    else:
                        _append_unique(commands, f"{pm} run {script}")
            if commands and not info["checks"]:
                info["checks"].append(
                    {"name": "Dev server", "url": "http://127.0.0.1:5173", "port": 5173}
                )
        except (OSError, json.JSONDecodeError):
            pass

    if os.path.isfile(makefile_path):
        try:
            with open(makefile_path, encoding="utf-8") as f:
                content = f.read()
            for target in _makefile_targets(content):
                _append_unique(commands, f"make {target}")
        except OSError:
            pass

    for compose_name in _COMPOSE_FILES:
        if os.path.isfile(os.path.join(root, compose_name)):
            _append_unique(commands, "docker compose up -d")
            break

    if os.path.isfile(good_cli) and os.access(good_cli, os.X_OK):
        _append_unique(commands, "./good dev start")

    for script_name in _SHELL_SCRIPTS:
        script_path = os.path.join(root, script_name)
        if os.path.isfile(script_path):
            _append_unique(commands, f"bash {script_name}")

    if os.path.isfile(procfile):
        _append_unique(commands, "foreman start")
        _append_unique(commands, "honcho start")

    if os.path.isfile(justfile):
        for recipe in ("dev", "start", "serve", "up"):
            _append_unique(commands, f"just {recipe}")

    if info["kind"] == "laravel" and not info["checks"]:
        info["checks"] = [
            {"name": "Laravel", "url": "http://127.0.0.1:8000", "port": 8000},
            {"name": "Vite", "url": "http://127.0.0.1:5173", "port": 5173},
        ]

    info["start_commands"] = commands
    return info


def re_match_dev_target(content: str) -> bool:
    return bool(_makefile_targets(content))


if __name__ == "__main__":
    print(json.dumps(detect(sys.argv[1]), ensure_ascii=False))
