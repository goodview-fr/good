#!/usr/bin/env python3
"""Detect project stack and start commands from composer.json, package.json, Makefile."""
import json
import os
import sys


def detect(root: str) -> dict:
    info = {
        "kind": "generic",
        "start_commands": [],
        "checks": [],
    }

    composer_path = os.path.join(root, "composer.json")
    package_path = os.path.join(root, "package.json")
    makefile_path = os.path.join(root, "Makefile")
    docker_compose = os.path.join(root, "docker-compose.yml")

    if os.path.isfile(composer_path):
        with open(composer_path) as f:
            scripts = json.load(f).get("scripts", {})
        if "dev" in scripts:
            info["start_commands"].append("composer dev")
        elif "stack:up" in scripts:
            info["start_commands"].append("composer stack:up")
        if os.path.isfile(os.path.join(root, "artisan")):
            info["kind"] = "laravel"
            info["checks"] = [
                {"name": "Laravel", "url": "http://127.0.0.1:8000", "port": 8000},
                {"name": "Vite", "url": "http://127.0.0.1:5173", "port": 5173},
            ]

    if os.path.isfile(package_path):
        with open(package_path) as f:
            pkg = json.load(f)
        scripts = pkg.get("scripts", {})
        if "dev" in scripts and not info["start_commands"]:
            if os.path.isfile(os.path.join(root, "pnpm-lock.yaml")):
                info["start_commands"].append("pnpm run dev")
            else:
                info["start_commands"].append("npm run dev")
            info["checks"].append(
                {"name": "Dev server", "url": "http://127.0.0.1:5173", "port": 5173}
            )

    if os.path.isfile(makefile_path) and not info["start_commands"]:
        with open(makefile_path) as f:
            content = f.read()
        if re_match_dev_target(content):
            info["start_commands"].append("make dev")

    if os.path.isfile(docker_compose) and not info["start_commands"]:
        info["start_commands"].append("docker compose up -d")

    if info["kind"] == "laravel" and not info["checks"]:
        info["checks"] = [
            {"name": "Laravel", "url": "http://127.0.0.1:8000", "port": 8000},
            {"name": "Vite", "url": "http://127.0.0.1:5173", "port": 5173},
        ]

    return info


def re_match_dev_target(content: str) -> bool:
    for line in content.splitlines():
        if line.strip().startswith("dev:") or line.strip().startswith("dev "):
            return True
    return False


if __name__ == "__main__":
    print(json.dumps(detect(sys.argv[1]), ensure_ascii=False))
