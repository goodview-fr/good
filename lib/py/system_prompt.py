#!/usr/bin/env python3
"""Rich system prompt builder for good dog."""
import json
import os
import subprocess
import sys


# ── Constant sections ──────────────────────────────────────────────────────────

IDENTITY_SECTION = """\
Tu es dog, un ingénieur logiciel senior intégré au CLI `good`.
Tu travailles dans le terminal, en mode CLI.
Sois concis et actionnable — pas de bavardage inutile.
Réponds en français sauf si l'utilisateur écrit en anglais.\
"""

REASONING_SECTION = """\
## Approche de travail
- Tâches simples : répondre directement
- Tâches complexes : planifie d'abord (liste numérotée), puis agis étape par étape
- Avant de modifier un fichier : lis-le d'abord si tu ne l'as pas encore
- Préfère le diff minimal plutôt que la réécriture complète
- En cas d'incertitude sur l'intention : pose une question courte\
"""

SECURITY_SECTION = """\
## Règles de sécurité
- Ne jamais inclure/révéler : tokens, clés API, mots de passe, secrets .env
- Confirmer avant toute suppression ou modification irréversible
- Les commandes shell doivent être lues/comprises avant d'être proposées\
"""

GIT_WORKFLOW_SECTION = """\
## Git (commit, push, sync)
Les commandes `good c`, `good p`, `good s` n'existent plus.
Quand l'utilisateur demande commit/push/sync : exécute directement via `run_git`, sans demander confirmation.
Séquence type :
1. `status` / `diff` — voir les changements
2. `add -A` (ou fichiers ciblés)
3. `commit -m "feat(scope): description"` — Conventional Commits, en anglais
4. `fetch origin` puis `rebase origin/<branche>` si le distant a évolué
5. `push -u origin <branche>`
Conflits : `resolve_conflicts()` ou run_git (`add` + `rebase --continue`).
Interdit : `push --force`, `reset --hard`, `clean -f`.\
"""


class SystemPromptBuilder:
    """Construit un system prompt professionnel pour good dog."""

    def __init__(
        self,
        project_root: str,
        config_file: str,
        provider: str = "ollama",
        include_tools: bool = False,
        tools_description: str = "",
    ):
        self.root = project_root
        self.config_file = config_file
        self.provider = provider
        self.include_tools = include_tools
        self.tools_description = tools_description

    # ── Internal collectors ────────────────────────────────────────────────────

    def _get_project_info(self) -> dict:
        """Collecte les infos du projet : type, framework, scripts npm/composer."""
        info: dict = {
            "type": "unknown",
            "framework": None,
            "scripts": [],
            "composer_scripts": [],
            "key_files": [],
            "root": self.root,
        }

        # Détection Laravel
        if os.path.isfile(os.path.join(self.root, "artisan")):
            info["type"] = "laravel"
            info["framework"] = "Laravel"

        # Détection Vue/React/Node
        pkg_path = os.path.join(self.root, "package.json")
        if os.path.isfile(pkg_path):
            try:
                with open(pkg_path, encoding="utf-8") as f:
                    pkg = json.load(f)
                scripts = list((pkg.get("scripts") or {}).keys())
                info["scripts"] = scripts[:8]
                deps = {
                    **pkg.get("dependencies", {}),
                    **pkg.get("devDependencies", {}),
                }
                if "vue" in deps:
                    info["framework"] = (info["framework"] or "") + " Vue"
                if "react" in deps:
                    info["framework"] = (info["framework"] or "") + " React"
                if "electron" in deps:
                    info["framework"] = (info["framework"] or "") + " Electron"
                if info["type"] == "unknown":
                    info["type"] = "node"
            except Exception:
                pass

        # Composer
        comp_path = os.path.join(self.root, "composer.json")
        if os.path.isfile(comp_path):
            try:
                with open(comp_path, encoding="utf-8") as f:
                    comp = json.load(f)
                composer_scripts = list((comp.get("scripts") or {}).keys())
                info["composer_scripts"] = composer_scripts[:8]
                if info["type"] == "unknown":
                    info["type"] = "php"
            except Exception:
                pass

        # Python
        for py_marker in ("pyproject.toml", "setup.py", "setup.cfg"):
            if os.path.isfile(os.path.join(self.root, py_marker)):
                if info["type"] == "unknown":
                    info["type"] = "python"
                break

        # Fichiers clés utiles au contexte
        key_candidates = [
            "Makefile",
            "docker-compose.yml",
            "docker-compose.yaml",
            ".env.example",
            "Dockerfile",
            "GOOD.md",
            "README.md",
        ]
        info["key_files"] = [
            f for f in key_candidates
            if os.path.isfile(os.path.join(self.root, f))
        ]

        return info

    def _get_git_info(self) -> dict:
        """Branche, status court, derniers commits."""
        try:
            branch = subprocess.check_output(
                ["git", "rev-parse", "--abbrev-ref", "HEAD"],
                cwd=self.root,
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
            status = subprocess.check_output(
                ["git", "status", "-s"],
                cwd=self.root,
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
            log = subprocess.check_output(
                ["git", "log", "--oneline", "-5"],
                cwd=self.root,
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
            return {"branch": branch, "status": status, "recent_commits": log}
        except Exception:
            return {}

    def _get_goodview_context(self) -> str:
        """Lit le contexte Goodview depuis .good/config.json sans dépendance à dog_context."""
        if not os.path.isfile(self.config_file):
            return ""
        try:
            with open(self.config_file, encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception:
            return ""

        cache = cfg.get("project_cache") or {}
        if not cache:
            return ""

        lines = ["Contexte Goodview (liaison .good/config.json, sans secrets) :"]
        if cache.get("client_name"):
            lines.append(f"Client : {cache['client_name']}")
        if cache.get("name"):
            lines.append(f"Projet : {cache['name']}")
        label = cache.get("type_label") or cache.get("type")
        if label:
            lines.append(f"Type : {label}")
        status = cache.get("status_label") or cache.get("status")
        if status:
            lines.append(f"Statut : {status}")
        if cache.get("github_url"):
            lines.append(f"Dépôt : {cache['github_url']}")
        if cache.get("dev_url"):
            env = cache.get("dev_environment_name") or "dev"
            lines.append(f"URL dev : {cache['dev_url']} ({env})")
        if cache.get("prod_url"):
            env = cache.get("prod_environment_name") or "prod"
            lines.append(f"URL prod : {cache['prod_url']} ({env})")

        return "\n".join(lines) if len(lines) > 1 else ""

    # ── Section builders ───────────────────────────────────────────────────────

    def _section_identity(self) -> str:
        return f"## Identité\n{IDENTITY_SECTION}"

    def _section_capabilities(self) -> str:
        base_caps = (
            "- Analyse de code, debug, refactoring, architecture\n"
            "- Git : commits, branches, conflits, rebase\n"
            "- Déploiement, Docker, CI/CD\n"
            "- Documentation, revues de code\n"
            "- Commandes shell : lire et comprendre avant de proposer"
        )
        if self.include_tools and self.tools_description:
            tools_caps = (
                f"\n\n**Outils disponibles (tool-use activé) :**\n{self.tools_description}"
            )
        elif self.include_tools:
            tools_caps = (
                "\n\n**Outils disponibles (tool-use activé) :**\n"
                "- Lecture et écriture de fichiers\n"
                "- Recherche dans le code (grep, glob)\n"
                "- Git complet via run_git (add, commit, fetch, rebase, push)\n"
                "- Commandes shell (docker, npm, composer…)\n"
                "- Recherche web"
            )
        else:
            tools_caps = (
                "\n\n*Mode conversation uniquement — pas de tool-use.*\n"
                "Fournis des extraits de code copiables et des commandes shell explicites."
            )
        return f"## Capacités\n{base_caps}{tools_caps}"

    def _section_reasoning(self) -> str:
        return REASONING_SECTION

    def _section_project(self, info: dict) -> str:
        lines = ["## Projet courant"]
        lines.append(f"Racine : {info['root']}")

        fw = (info.get("framework") or "").strip()
        proj_type = info.get("type", "unknown")
        if fw:
            lines.append(f"Stack : {fw} ({proj_type})")
        elif proj_type != "unknown":
            lines.append(f"Type : {proj_type}")

        scripts = info.get("scripts", [])
        if scripts:
            lines.append(f"Scripts npm : {', '.join(scripts)}")

        composer_scripts = info.get("composer_scripts", [])
        if composer_scripts:
            lines.append(f"Scripts composer : {', '.join(composer_scripts)}")

        key_files = info.get("key_files", [])
        if key_files:
            lines.append(f"Fichiers clés : {', '.join(key_files)}")

        return "\n".join(lines)

    def _section_git(self, git: dict) -> str:
        if not git:
            return ""
        lines = ["## Git"]
        if git.get("branch"):
            lines.append(f"Branche : {git['branch']}")
        if git.get("status"):
            lines.append(f"Status :\n{git['status']}")
        if git.get("recent_commits"):
            lines.append(f"Derniers commits :\n{git['recent_commits']}")
        return "\n".join(lines)

    def _section_goodview(self, gv_ctx: str) -> str:
        if not gv_ctx:
            return ""
        return f"## Contexte Goodview\n{gv_ctx}"

    def _section_security(self) -> str:
        return SECURITY_SECTION

    # ── Public API ─────────────────────────────────────────────────────────────

    def build(self) -> str:
        """Génère le system prompt complet structuré."""
        info = self._get_project_info()
        git = self._get_git_info()
        gv_ctx = self._get_goodview_context()

        sections = [
            self._section_identity(),
            self._section_capabilities(),
            self._section_reasoning(),
            self._section_project(info),
        ]

        git_section = self._section_git(git)
        if git_section:
            sections.append(git_section)

        gv_section = self._section_goodview(gv_ctx)
        if gv_section:
            sections.append(gv_section)

        sections.append(self._section_security())

        if self.include_tools:
            sections.append(GIT_WORKFLOW_SECTION)

        return "\n\n".join(sections)

    def build_compact(self) -> str:
        """Version courte pour modèles avec contexte limité (< 8k tokens).

        Environ 40% plus court : enlève les exemples, réduit les listes.
        """
        info = self._get_project_info()
        git = self._get_git_info()
        gv_ctx = self._get_goodview_context()

        lines = [
            "Tu es dog, assistant CLI senior. Sois concis, actionnable. Réponds en français.",
            "Pas de secrets/tokens. Confirmer avant suppression. Diff minimal.",
            "",
        ]

        # Projet
        fw = (info.get("framework") or "").strip()
        proj_type = info.get("type", "unknown")
        proj_line = f"Projet : {info['root']}"
        if fw:
            proj_line += f" | Stack : {fw}"
        elif proj_type != "unknown":
            proj_line += f" | Type : {proj_type}"
        lines.append(proj_line)

        # Git
        if git.get("branch"):
            git_line = f"Git : branche {git['branch']}"
            if git.get("status"):
                status_count = len(git["status"].splitlines())
                git_line += f" | {status_count} fichier(s) modifié(s)"
            lines.append(git_line)

        # Goodview : premières lignes seulement
        if gv_ctx:
            gv_short = "\n".join(gv_ctx.splitlines()[:3])
            lines.append(gv_short)

        lines.append("")
        lines.append(
            "Tâches complexes : planifie avant d'agir. "
            "Tâches simples : répondre direct."
        )

        return "\n".join(lines)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Tester SystemPromptBuilder",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Exemples :\n"
            "  python3 lib/py/system_prompt.py\n"
            "  python3 lib/py/system_prompt.py /path/to/project\n"
            "  python3 lib/py/system_prompt.py /path/to/project /path/to/.good/config.json\n"
            "  python3 lib/py/system_prompt.py --compact --provider deepseek\n"
        ),
    )
    parser.add_argument(
        "root", nargs="?", default=os.getcwd(),
        help="Racine du projet (défaut: cwd)",
    )
    parser.add_argument(
        "config", nargs="?", default="",
        help="Chemin vers .good/config.json",
    )
    parser.add_argument(
        "--provider", default="ollama",
        help="Provider : ollama | deepseek | openai",
    )
    parser.add_argument(
        "--tools", action="store_true",
        help="Inclure section tool-use",
    )
    parser.add_argument(
        "--compact", action="store_true",
        help="Mode compact (petits modèles)",
    )
    args = parser.parse_args()

    config_path = args.config or os.path.join(args.root, ".good", "config.json")
    builder = SystemPromptBuilder(
        project_root=args.root,
        config_file=config_path,
        provider=args.provider,
        include_tools=args.tools,
    )

    if args.compact:
        prompt = builder.build_compact()
        label = "COMPACT"
    else:
        prompt = builder.build()
        label = "FULL"

    print(f"=== {label} ({len(prompt)} chars / ~{len(prompt) // 4} tokens estimés) ===\n")
    print(prompt)
