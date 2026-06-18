#!/usr/bin/env python3
"""Tool definitions and execution engine for good dog agent loop."""

import json
import os
import re
import shutil
import subprocess
import sys

# ── Destructive command patterns (always blocked) ─────────────────────────────
DESTRUCTIVE_PATTERNS = [
    r"\brm\s+-[rf]+\s+/",
    r"\brm\s+-rf\b",
    r"\bmkfs\b",
    r"\bdd\s+if=",
    r"\bshutdown\b",
    r"\breboot\b",
    r"git\s+push\s+--force",
    r"git\s+reset\s+--hard",
    r"git\s+clean\s+-f",
    r">\s*/dev/",
    r"\|\s*rm\b",
    r"curl\s+.*\|\s*(ba)?sh",
    r"wget\s+.*\|\s*(ba)?sh",
    r"\bchmod\s+777\b",
    r"\bchown\b",
    r"\bkill\s+-9\b",
    r"\bpkill\s+-9\b",
    r"\bkillall\s+-9\b",
]

# ── Tool needs-confirm set (write always; shell checked via shell_needs_confirm) ─
TOOLS_NEEDS_CONFIRM = {"write_file", "run_shell", "run_command"}

# ── OpenAI function-calling schema (DeepSeek / OpenAI) ─────────────────────────
OPENAI_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Lire le contenu d'un fichier du projet (chemin relatif à la racine git).",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Chemin relatif au projet, ex: routes/api.php",
                    }
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Écrire ou créer un fichier dans le projet.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Chemin relatif au projet, ex: src/utils.ts",
                    },
                    "content": {
                        "type": "string",
                        "description": "Contenu complet à écrire dans le fichier.",
                    },
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_directory",
            "description": "Lister les fichiers et dossiers d'un répertoire du projet.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Chemin relatif au projet (défaut: racine du projet).",
                    },
                    "depth": {
                        "type": "integer",
                        "description": "Profondeur maximale d'exploration (défaut: 2).",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_files",
            "description": "Chercher un pattern dans les fichiers du projet (rg/grep).",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {
                        "type": "string",
                        "description": "Expression régulière ou texte à chercher.",
                    },
                    "path": {
                        "type": "string",
                        "description": "Dossier où chercher (défaut: racine du projet).",
                    },
                    "glob": {
                        "type": "string",
                        "description": "Filtre de fichiers glob, ex: *.php (défaut: *).",
                    },
                },
                "required": ["pattern"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_git",
            "description": (
                "Exécuter une commande git (status, diff, log, add, commit -m, fetch, rebase, push). "
                "Pour committer/pousser/synchroniser : status → add → commit -m → fetch → rebase → push."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "args": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Arguments git, ex: ['log', '--oneline', '-10']",
                    }
                },
                "required": ["args"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": (
                "Exécuter une commande shell dans le projet (docker, npm, composer, make, "
                "php artisan, systemctl, ollama, etc.). Préférer cet outil pour démarrer/arrêter des services."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Commande shell, ex: docker compose down",
                    }
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_shell",
            "description": (
                "Alias de run_command — exécuter une commande shell whitelistée dans le projet."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Commande shell, ex: docker compose up -d",
                    }
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "resolve_conflicts",
            "description": "Résoudre tous les conflits git (marqueurs <<<<<<<) via IA et continuer rebase/merge.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Rechercher sur le web via DuckDuckGo (sans clé API).",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Requête de recherche.",
                    }
                },
                "required": ["query"],
            },
        },
    },
]

# ── Ollama system prompt injection ────────────────────────────────────────────
OLLAMA_TOOL_SYSTEM = """
Tu peux utiliser ces outils en outputtant exactement ce format (sur une ligne seule) :
<tool_call>{"name": "read_file", "args": {"path": "routes/api.php"}}</tool_call>

Outils disponibles :
- read_file(path) : lire un fichier du projet (chemin relatif à la racine)
- write_file(path, content) : écrire ou créer un fichier
- list_directory(path, depth) : lister les fichiers d'un dossier
- search_files(pattern, path, glob) : chercher dans les fichiers (rg/grep)
- run_git(args) : git (status, diff, log, add, commit -m, fetch, rebase, push…)
- resolve_conflicts() : résoudre les conflits git via IA
- run_command(command) : exécuter une commande shell (docker, npm, composer, make, php artisan…)
- run_shell(command) : alias de run_command
- web_search(query) : recherche web DuckDuckGo

Règles :
- Pour committer/pousser : run_git avec add, commit -m "message", fetch, rebase, push (Conventional Commits).
- Pour démarrer/arrêter docker, npm, composer : utilise run_command — n'invite pas l'utilisateur à taper la commande.
- Interdit : push --force, reset --hard, clean -f.
- Après chaque <tool_call>, attends le résultat <tool_result> avant de continuer.
- Une fois que tu as toutes les informations nécessaires, réponds directement sans <tool_call>.
- N'invente jamais le contenu d'un fichier : utilise read_file pour le lire d'abord.
"""

# ── ToolEngine ─────────────────────────────────────────────────────────────────

_GIT_READOPS = frozenset({
    "status", "log", "diff", "branch", "show", "blame", "tag", "rev-parse",
})
_GIT_WRITEOPS = frozenset({
    "add", "commit", "push", "fetch", "pull", "rebase", "merge",
})
_GIT_ALLOWED = _GIT_READOPS | _GIT_WRITEOPS | frozenset({"stash", "remote"})

_DANGEROUS_GIT_PATTERNS = [
    r"push\s+(-f|--force)\b",
    r"reset\s+--hard\b",
    r"clean\s+-f\b",
    r"rebase\s+--abort\b",
    r"branch\s+-D\b",
]


def format_tool_args(args) -> str:
    """Affichage compact des arguments outil (dict, list, str…)."""
    if isinstance(args, dict):
        return ", ".join(f"{k}={v!r}"[:40] for k, v in args.items())
    if isinstance(args, list):
        return ", ".join(repr(a)[:40] for a in args)
    if args is None:
        return ""
    return repr(args)[:80]


def normalize_tool_args(name: str, args) -> dict:
    """Normalise les arguments outil — Ollama renvoie souvent une liste au lieu d'un dict."""
    if isinstance(args, str):
        raw = args.strip()
        if not raw:
            return {}
        try:
            args = json.loads(raw)
        except json.JSONDecodeError:
            if name in ("run_shell", "run_command"):
                return {"command": raw}
            if name == "run_git":
                return {"args": raw.split()}
            if name == "read_file":
                return {"path": raw}
            if name == "web_search":
                return {"query": raw}
            return {}

    if isinstance(args, list):
        if name == "run_git" or (args and str(args[0]).lower() in _GIT_ALLOWED):
            return {"args": [str(a) for a in args]}
        if name in ("run_shell", "run_command"):
            return {"command": " ".join(str(a) for a in args)}
        if name == "read_file" and args:
            return {"path": str(args[0])}
        if name == "write_file" and len(args) >= 2:
            return {"path": str(args[0]), "content": str(args[1])}
        if name == "search_files" and args:
            kw = {"pattern": str(args[0])}
            if len(args) > 1:
                kw["path"] = str(args[1])
            return kw
        if name == "web_search" and args:
            return {"query": str(args[0])}
        if name == "list_directory":
            kw = {}
            if args:
                kw["path"] = str(args[0])
            if len(args) > 1:
                try:
                    kw["depth"] = int(args[1])
                except (TypeError, ValueError):
                    pass
            return kw
        return {}

    if not isinstance(args, dict):
        return {}

    if name == "run_git":
        git_args = args.get("args")
        if isinstance(git_args, str):
            return {"args": git_args.split()}
        if isinstance(git_args, list):
            return {"args": [str(a) for a in git_args]}
        if git_args is None and "command" in args:
            return {"args": str(args["command"]).split()}
        if git_args is None and len(args) == 1:
            k = next(iter(args))
            if str(k).lower() in _GIT_ALLOWED:
                v = args[k]
                return {"args": [str(k), str(v)] if v not in (None, "") else [str(k)]}

    if name in ("run_shell", "run_command") and "command" not in args:
        if "cmd" in args:
            return {"command": str(args["cmd"])}

    return args


def git_needs_confirm(args: list) -> bool:
    """Git workflow (add/commit/push…) : pas de confirmation — validate_git_args filtre le dangereux."""
    return False


def validate_git_args(args: list) -> tuple[bool, str]:
    """Valide une invocation git pour run_git."""
    if not args:
        return False, "aucun argument git fourni"
    first = str(args[0]).lower()
    if first not in _GIT_ALLOWED:
        return False, (
            f"sous-commande git non autorisée '{first}'. "
            f"Autorisées: {', '.join(sorted(_GIT_ALLOWED))}"
        )

    joined = " ".join(str(a) for a in args)
    for pat in _DANGEROUS_GIT_PATTERNS:
        if re.search(pat, joined, re.I):
            return False, f"commande git dangereuse interdite: {joined}"

    if first == "commit":
        lowered = [str(a).lower() for a in args]
        if "-m" not in lowered and "--message" not in lowered:
            return False, 'commit nécessite -m "message" (pas d\'éditeur interactif)'

    if first == "stash":
        if len(args) < 2 or str(args[1]).lower() != "list":
            return False, "seule la sous-commande 'stash list' est autorisée"

    if first == "remote":
        sub = str(args[1]).lower() if len(args) > 1 else ""
        if sub not in ("-v", "show", "get-url"):
            return False, "remote : seulement -v, show, get-url"

    if first == "merge":
        lowered = [str(a).lower() for a in args]
        if "--no-edit" not in lowered and "-m" not in lowered and "--message" not in lowered:
            return False, "merge nécessite --no-edit ou -m (pas d'éditeur interactif)"

    return True, ""


# Legacy alias (tests / imports)
_GIT_WHITELIST = _GIT_ALLOWED

_SHELL_READONLY = (
    r"^(docker\s+(ps|images|inspect|version)|docker-compose\s+ps)\b",
    r"^docker\s+compose\s+(ps|config|version)\b",
    r"^docker\s+logs\b",
    r"^(ls|cat|pwd|which|echo|head|tail|sleep|wc|find|grep|rg|file|stat)\b",
    r"^(curl|wget|lsof|ss|netstat)\b",
    r"^php\s+artisan\s+(route:list|config:show|migrate:status|db:show|model:show|about|env)\b",
    r"^composer\s+(show|info|validate|dump-autoload|diagnose)\b",
    r"^(npm|pnpm|yarn)\s+(ls|list|view)\b",
    r"^ollama\s+(list|ps|show)\b",
    r"^systemctl\s+status\b",
    r"^make\s+-n\b",
    r"^\./good\s+(st|status|l|log|info|health|--version|-h|--help)\b",
)

_EXCLUDE_DIRS = {"node_modules", "vendor", ".git", "dist", "build", "storage"}


def shell_needs_confirm(command: str) -> bool:
    """True si la commande modifie l'état (stop, down, kill, start, up…)."""
    cmd = command.strip()
    if not cmd:
        return True
    for pat in _SHELL_READONLY:
        if re.search(pat, cmd, re.I):
            return False
    return True


def is_safe_shell(command: str) -> tuple[bool, str]:
    """Retourne (safe, reason)."""
    cmd = command.strip()
    if not cmd:
        return False, "commande vide"
    for pat in DESTRUCTIVE_PATTERNS:
        if re.search(pat, cmd, re.I):
            return False, "commande destructive détectée"
    if re.search(r"\bcomposer\s+remove\b", cmd, re.I):
        return False, "composer remove interdit"
    if re.search(r"\bmake\s+clean\b", cmd, re.I):
        return False, "make clean interdit (potentiellement destructif)"
    if re.search(r"\bgit\b", cmd, re.I):
        return False, "utilise run_git pour les commandes git"
    return True, ""


class ToolEngine:
    def __init__(self, project_root: str, ai_fn=None):
        self.root = os.path.realpath(project_root)
        self.ai_fn = ai_fn
        self._secret_re = re.compile(
            r"(secret|token|password|api[_-]?key|private[_-]?key)", re.I
        )

    # ── Public interface ───────────────────────────────────────────────────────

    def execute(self, name: str, args) -> str:
        """Exécute un outil et retourne le résultat comme string."""
        if name == "run_command":
            name = "run_shell"
        args = normalize_tool_args(name, args or {})
        handler = getattr(self, f"_tool_{name}", None)
        if not handler:
            return f"Erreur: outil inconnu '{name}'"
        try:
            return handler(**args)
        except TypeError as exc:
            return f"Erreur d'arguments pour {name}: {exc}"
        except Exception as exc:
            return f"Erreur lors de l'exécution de {name}: {exc}"

    # ── Security helpers ───────────────────────────────────────────────────────

    def _safe_path(self, path: str) -> str:
        """Valide et résout un chemin dans le projet. Lève ValueError si invalide."""
        if not path or path.strip() == "":
            raise ValueError("Chemin vide")
        if os.path.isabs(path):
            raise ValueError(f"Chemin absolu non autorisé: {path}")
        resolved = os.path.realpath(os.path.join(self.root, path))
        if not (resolved == self.root or resolved.startswith(self.root + os.sep)):
            raise ValueError(f"Chemin hors du projet: {path}")
        rel = os.path.relpath(resolved, self.root)
        parts = rel.split(os.sep)
        if parts and parts[0] == ".git":
            raise ValueError("Accès au répertoire .git interdit")
        return resolved

    def _mask_secrets(self, content: str) -> str:
        return re.sub(
            r"((?:SECRET|TOKEN|PASSWORD|API[_-]?KEY|PRIVATE[_-]?KEY)\s*=\s*)([^\s\n\"']+)",
            r"\1[MASQUÉ]",
            content,
            flags=re.I,
        )

    def _fmt(self, label: str, content: str) -> str:
        return f"--- {label} ---\n{content}\n--- fin ---"

    def _is_safe_shell(self, command: str) -> tuple[bool, str]:
        safe, reason = is_safe_shell(command)
        if not safe:
            return safe, reason
        cmd = command.strip()
        # Scripts bash du projet uniquement
        m = re.match(r"^(?:bash|sh)\s+([^\s;|&]+)", cmd)
        if m:
            script = m.group(1).lstrip("./")
            try:
                self._safe_path(script)
            except ValueError:
                return False, f"script hors du projet: {m.group(1)}"
        # ./good ou ./script.sh à la racine
        m2 = re.match(r"^\./(\S+)", cmd)
        if m2:
            rel = m2.group(1).split()[0]
            try:
                self._safe_path(rel)
            except ValueError:
                return False, f"exécutable hors du projet: {rel}"
        return True, ""

    # ── Tool implementations ───────────────────────────────────────────────────

    def _tool_read_file(self, path: str) -> str:
        resolved = self._safe_path(path)
        if not os.path.isfile(resolved):
            return self._fmt(f"read_file: {path}", f"Erreur: fichier introuvable '{path}'")
        size = os.path.getsize(resolved)
        if size > 100_000:
            return self._fmt(
                f"read_file: {path}",
                f"Erreur: fichier trop volumineux ({size:,} octets > 100k). Utilisez search_files pour chercher dedans.",
            )
        try:
            with open(resolved, encoding="utf-8", errors="replace") as f:
                content = f.read()
        except OSError as exc:
            return self._fmt(f"read_file: {path}", f"Erreur de lecture: {exc}")
        content = self._mask_secrets(content)
        return self._fmt(f"read_file: {path}", content)

    def _tool_write_file(self, path: str, content: str) -> str:
        rel_norm = path.replace("\\", "/").lstrip("./")
        if rel_norm in (".good/config.json", ".good/config.json"):
            return self._fmt(
                f"write_file: {path}",
                "Erreur: modification de .good/config.json interdite.",
            )
        resolved = self._safe_path(path)
        parent = os.path.dirname(resolved)
        try:
            os.makedirs(parent, exist_ok=True)
            with open(resolved, "w", encoding="utf-8") as f:
                f.write(content)
        except OSError as exc:
            return self._fmt(f"write_file: {path}", f"Erreur d'écriture: {exc}")
        lines = content.count("\n") + 1
        return self._fmt(
            f"write_file: {path}",
            f"Fichier écrit avec succès ({lines} ligne(s), {len(content):,} caractères).",
        )

    def _tool_list_directory(self, path: str = ".", depth: int = 2) -> str:
        try:
            resolved = self._safe_path(path)
        except ValueError as exc:
            return self._fmt("list_directory", f"Erreur: {exc}")
        if not os.path.isdir(resolved):
            return self._fmt(f"list_directory: {path}", f"Erreur: dossier introuvable '{path}'")
        depth = max(1, min(int(depth), 5))
        lines = []

        def _walk(current: str, prefix: str, remaining: int):
            try:
                entries = sorted(os.listdir(current))
            except PermissionError:
                return
            dirs = [
                e for e in entries
                if os.path.isdir(os.path.join(current, e))
                and e not in _EXCLUDE_DIRS
                and not e.startswith(".")
            ]
            files = [e for e in entries if os.path.isfile(os.path.join(current, e))]
            for i, name in enumerate(dirs + files):
                entry_path = os.path.join(current, name)
                is_last = i == len(dirs) + len(files) - 1
                connector = "└── " if is_last else "├── "
                if os.path.isdir(entry_path):
                    lines.append(f"{prefix}{connector}{name}/")
                    if remaining > 1:
                        extension = "    " if is_last else "│   "
                        _walk(entry_path, prefix + extension, remaining - 1)
                else:
                    size = os.path.getsize(entry_path)
                    size_str = f" ({size:,}B)" if size < 100_000 else f" ({size / 1024:.0f}kB)"
                    lines.append(f"{prefix}{connector}{name}{size_str}")

        rel = os.path.relpath(resolved, self.root)
        display = "." if rel == "." else rel
        lines.append(f"{display}/")
        _walk(resolved, "", depth)
        return self._fmt(f"list_directory: {path} (depth={depth})", "\n".join(lines))

    def _tool_search_files(self, pattern: str, path: str = ".", glob: str = "*") -> str:
        try:
            resolved = self._safe_path(path)
        except ValueError as exc:
            return self._fmt("search_files", f"Erreur: {exc}")
        if not os.path.isdir(resolved) and not os.path.isfile(resolved):
            return self._fmt(f"search_files: {pattern}", f"Erreur: chemin introuvable '{path}'")

        use_rg = shutil.which("rg") is not None
        try:
            if use_rg:
                cmd = ["rg", "--no-heading", "--line-number", "-m", "50", "-g", glob, pattern, resolved]
            else:
                cmd = [
                    "grep", "-r", "-n", "--include", f"*{glob}*" if glob != "*" else "*",
                    "-m", "50", pattern, resolved,
                ]
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30,
                cwd=self.root,
            )
            output = result.stdout.strip()
            if not output:
                return self._fmt(f"search_files: {pattern}", "Aucun résultat trouvé.")
            lines = output.splitlines()
            if len(lines) > 50:
                output = "\n".join(lines[:50]) + f"\n… ({len(lines) - 50} résultats supplémentaires tronqués)"
            output = output.replace(self.root + os.sep, "")
            return self._fmt(f"search_files: {pattern}", output)
        except subprocess.TimeoutExpired:
            return self._fmt(f"search_files: {pattern}", "Erreur: délai dépassé (30s).")
        except FileNotFoundError:
            return self._fmt(f"search_files: {pattern}", "Erreur: ni rg ni grep disponibles.")

    def _tool_run_git(self, args: list) -> str:
        if not args:
            return self._fmt("run_git", "Erreur: aucun argument git fourni.")
        ok, reason = validate_git_args(args)
        if not ok:
            return self._fmt(f"run_git: {' '.join(str(a) for a in args)}", f"Erreur: {reason}.")
        first = str(args[0]).lower()
        timeout = 120 if first in _GIT_WRITEOPS else 30
        try:
            result = subprocess.run(
                ["git"] + [str(a) for a in args],
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=self.root,
            )
            output = (result.stdout + result.stderr).strip()
            if not output:
                output = f"(commande terminée avec code {result.returncode})"
            elif result.returncode != 0:
                output = f"[code {result.returncode}]\n{output}"
            return self._fmt(f"run_git: git {' '.join(str(a) for a in args)}", output)
        except subprocess.TimeoutExpired:
            return self._fmt(
                f"run_git: {' '.join(str(a) for a in args)}",
                f"Erreur: délai dépassé ({timeout}s).",
            )

    def _tool_run_shell(self, command: str) -> str:
        cmd = command.strip()
        safe, reason = self._is_safe_shell(cmd)
        if not safe:
            return self._fmt(
                f"run_shell: {cmd}",
                f"Erreur: {reason}.",
            )
        try:
            result = subprocess.run(
                cmd,
                shell=True,
                capture_output=True,
                text=True,
                timeout=120,
                cwd=self.root,
            )
            output = (result.stdout + result.stderr).strip()
            if not output:
                output = f"(commande terminée avec code {result.returncode})"
            elif result.returncode != 0:
                output = f"[code {result.returncode}]\n{output}"
            return self._fmt(f"run_shell: {cmd}", output)
        except subprocess.TimeoutExpired:
            return self._fmt(f"run_shell: {cmd}", "Erreur: délai dépassé (120s).")

    def _tool_resolve_conflicts(self) -> str:
        if not self.ai_fn:
            return self._fmt("resolve_conflicts", "Erreur: IA non configurée pour la résolution.")
        try:
            _here = os.path.dirname(os.path.abspath(__file__))
            if _here not in sys.path:
                sys.path.insert(0, _here)
            from resolve_conflicts import resolve_all
            ok, msg = resolve_all(self.root, self.ai_fn)
            label = "resolve_conflicts"
            if not ok:
                return self._fmt(label, f"[échec]\n{msg}")
            return self._fmt(label, msg)
        except Exception as exc:
            return self._fmt("resolve_conflicts", f"Erreur: {exc}")

    def _tool_web_search(self, query: str) -> str:
        try:
            _here = os.path.dirname(os.path.abspath(__file__))
            if _here not in sys.path:
                sys.path.insert(0, _here)
            import dog_context as _dc
            result = _dc.web_search(query)
            return self._fmt(f"web_search: {query}", result)
        except Exception as exc:
            return self._fmt(f"web_search: {query}", f"Erreur lors de la recherche: {exc}")


if __name__ == "__main__":
    engine = ToolEngine(os.getcwd())
    print(engine.execute("list_directory", {"path": ".", "depth": 1}))
    print()
    print(engine.execute("run_git", {"args": ["status"]}))
    print()
    print(engine.execute("run_git", {"args": ["push", "--force"]}))
    print()
    print(engine.execute("run_shell", {"command": "pwd"}))
    print()
    print(engine.execute("run_shell", {"command": "rm -rf /"}))
