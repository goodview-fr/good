#!/usr/bin/env bash
# good dog — assistant interactif Ollama (stream + file d'attente)

_good_ollama_model() {
    echo "${GOOD_OLLAMA_MODEL:-qwen3:8b}"
}

_dog_ollama_host() {
    local host="${OLLAMA_HOST:-127.0.0.1:11434}"
    host="${host#http://}"
    host="${host#https://}"
    echo "$host"
}

_dog_system_prompt() {
    local root branch git_status gv_ctx
    root="$(_good_root)"
    branch=""
    git_status=""
    gv_ctx=""
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
        branch="$(git -C "$root" branch --show-current 2>/dev/null || echo "?")"
        git_status="$(git -C "$root" status -s 2>/dev/null | head -20 || true)"
    fi
    if [ -f "$(_good_config_file)" ]; then
        gv_ctx="$(python3 "$GOOD_LIB/py/dog_context.py" goodview "$(_good_config_file)" 2>/dev/null || true)"
    fi
    cat <<EOF
Tu es dog, un assistant de développement en ligne de commande (style Claude Code), intégré au CLI good.
Tu aides sur le projet courant : code, debug, git, architecture, déploiement, documentation, recherche web.
Réponds en français sauf si l'utilisateur écrit en anglais. Sois concis et actionnable.
Les demandes de création/modification de fichiers, démarrage, diagnostic ou déploiement sont exécutées automatiquement (avec confirmation).
Pour les questions générales (explication, revue, conseil), réponds directement.
Pour committer : « good c ». Pour pousser : « good p ». Recherche web : opt-in (GOOD_WEB_SEARCH=1 ou --web).

Projet : $root
Branche git : ${branch:-—}
$(if [ -n "$git_status" ]; then printf 'Git status :\n%s\n' "$git_status"; fi)
$(if [ -n "$gv_ctx" ]; then printf '%s\n' "$gv_ctx"; fi)
EOF
}

_dog_chat() {
    python3 - "$@" <<'PY'
import json, os, re, select, shutil, subprocess, sys, termios, threading, time, tty
import urllib.error, urllib.request

# ── ANSI ──────────────────────────────────────────────────────────────────────
R   = "\033[0m"
B   = "\033[1m"
D   = "\033[2m"
IT  = "\033[3m"
UL  = "\033[4m"
CY  = "\033[36m"
BL  = "\033[34m"
YE  = "\033[33m"
GR  = "\033[32m"
MA  = "\033[35m"
RE  = "\033[31m"
GY  = "\033[90m"
W   = "\033[97m"
CODE_FG   = "\033[38;5;215m"   # peach/orange
RULE_FG   = "\033[38;5;240m"   # gris foncé
HEADER_FG = "\033[38;5;147m"   # lavande
QUOTE_FG  = "\033[38;5;246m"   # gris moyen

COLS = shutil.get_terminal_size((80, 24)).columns

# ── State ─────────────────────────────────────────────────────────────────────
host_arg, model_arg, system_str, mode, verbose_str, prompt_arg, good_lib, web_search_str, root_arg, config_arg = sys.argv[1:11]
verbose  = verbose_str == "1"
web_search_enabled = web_search_str == "1"
base     = host_arg if host_arg.startswith("http") else f"http://{host_arg}"
model    = [model_arg]   # liste mutable pour /model
classify_script = os.path.join(good_lib, "py", "classify_intent.py")
dog_context_script = os.path.join(good_lib, "py", "dog_context.py")
project_root = root_arg
config_file = config_arg

pending_docs_context = [None]  # contexte /docs pour le prochain message

PROMPT_CH = "❯"

# Heredoc bash : stdin Python = script, pas le terminal — lire /dev/tty en interactif.
tty_in = None
if mode != "print":
    try:
        tty_in = open("/dev/tty", "r", encoding="utf-8", errors="replace")
    except OSError:
        print("Erreur: session interactive impossible (pas de terminal).", file=sys.stderr)
        print('Utilisez: good dog -p "question"', file=sys.stderr)
        raise SystemExit(1)


def _tty_fd():
    return tty_in.fileno() if tty_in is not None else None


def read_user_line():
    sys.stdout.write(f"\n{CY}{PROMPT_CH}{R} ")
    sys.stdout.flush()
    line = tty_in.readline()
    if not line:
        raise EOFError
    return line.rstrip("\n\r")


# ── Markdown renderer (streaming, ligne par ligne) ─────────────────────────────
def _strip_ansi(text):
    return re.sub(r"\033\[[0-9;]*m", "", text)


def _hl_inline(text):
    """Rend le markdown inline : `code`, **bold**, *italic*, [link](url)."""
    parts = re.split(r"(`[^`\n]+`)", text)
    out = []
    for p in parts:
        if p.startswith("`") and p.endswith("`") and len(p) > 2:
            out.append(f"{CODE_FG}{p[1:-1]}{R}")
        else:
            p = re.sub(r"\*\*(.+?)\*\*",
                       lambda m: f"{B}{m.group(1)}{R}", p)
            p = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)",
                       lambda m: f"{IT}{m.group(1)}{R}", p)
            p = re.sub(r"__(.+?)__",
                       lambda m: f"{B}{m.group(1)}{R}", p)
            p = re.sub(r"\[([^\]]+)\]\([^)]+\)",
                       lambda m: f"{UL}{CY}{m.group(1)}{R}", p)
            out.append(p)
    return "".join(out)


class MarkdownRenderer:
    """Rend le markdown en ANSI, ligne par ligne, pendant le streaming."""

    def __init__(self):
        self._buf  = ""
        self._code = False
        self._code_lang = ""

    def _render_line(self, line):
        # ── code fence ──────────────────────────────────────────────────────
        if line.startswith("```"):
            if not self._code:
                self._code = True
                self._code_lang = line[3:].strip() or "code"
                label = f" {self._code_lang} "
                bar_w = COLS - len(label) - 5
                return (
                    f"{RULE_FG}╭─{CODE_FG}{B}{label}{R}"
                    f"{RULE_FG}{'─' * max(0, bar_w)}╮{R}"
                )
            else:
                self._code = False
                return f"{RULE_FG}╰{'─' * (COLS - 3)}╯{R}"

        if self._code:
            return f"{RULE_FG}│{R} {CODE_FG}{line}{R}"

        # ── titres ──────────────────────────────────────────────────────────
        if line.startswith("#### "):
            return f"{B}{CY}{line[5:]}{R}"
        if line.startswith("### "):
            return f"{B}{CY}{line[4:]}{R}"
        if line.startswith("## "):
            return f"{B}{BL}{line[3:]}{R}"
        if line.startswith("# "):
            return f"{B}{MA}{line[2:]}{R}"

        # ── séparateur horizontal ────────────────────────────────────────────
        if re.match(r"^[-*_]{3,}\s*$", line):
            return f"{RULE_FG}{'─' * (COLS - 2)}{R}"

        # ── liste à puces ────────────────────────────────────────────────────
        m = re.match(r"^(\s*)([-*+]) (.+)", line)
        if m:
            indent = m.group(1)
            return f"{indent}{CY}•{R} {_hl_inline(m.group(3))}"

        # ── liste numérotée ──────────────────────────────────────────────────
        m = re.match(r"^(\s*)(\d+\.) (.+)", line)
        if m:
            return f"{m.group(1)}{GY}{m.group(2)}{R} {_hl_inline(m.group(3))}"

        # ── blockquote ───────────────────────────────────────────────────────
        if line.startswith("> "):
            return f"{RULE_FG}▎{R} {QUOTE_FG}{IT}{line[2:]}{R}"

        # ── ligne vide ───────────────────────────────────────────────────────
        if not line.strip():
            return ""

        return _hl_inline(line)

    def feed(self, text):
        """Reçoit un chunk streamé, renvoie le texte ANSI prêt à afficher."""
        out = []
        self._buf += text
        while "\n" in self._buf:
            idx  = self._buf.index("\n")
            line = self._buf[:idx]
            self._buf = self._buf[idx + 1:]
            out.append(self._render_line(line) + "\n")
        return "".join(out)

    def flush(self):
        if not self._buf:
            return ""
        out = self._render_line(self._buf)
        self._buf = ""
        return out


# ── Filtre blocs Thinking (qwen3) ─────────────────────────────────────────────
class StreamFilter:
    def __init__(self):
        self._skip    = False
        self._pending = ""

    def feed(self, text):
        out = []
        self._pending += text
        while self._pending:
            if self._skip:
                end = self._pending.find("\n")
                if end == -1:
                    break
                line = self._pending[: end + 1]
                self._pending = self._pending[end + 1:]
                if "...done thinking." in line or "</think>" in line:
                    self._skip = False
                continue
            start = self._pending.find("\n")
            if start == -1:
                if self._pending.startswith(("Thinking...", "<think>")):
                    self._skip = True
                    self._pending = ""
                elif "Thinking..." not in self._pending:
                    out.append(self._pending)
                    self._pending = ""
                break
            line = self._pending[: start + 1]
            self._pending = self._pending[start + 1:]
            if line.startswith(("Thinking...", "<think>")):
                self._skip = True
                continue
            out.append(line)
        return "".join(out)

    def flush(self):
        if self._skip or not self._pending:
            self._pending = ""
            return ""
        if self._pending.startswith(("Thinking...", "<think>")):
            self._pending = ""
            return ""
        text = self._pending
        self._pending = ""
        return text


# ── Spinner ───────────────────────────────────────────────────────────────────
class Spinner:
    FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    def __init__(self):
        self._stop   = threading.Event()
        self._thread = None

    def start(self):
        self._stop.clear()

        def _run():
            i = 0
            while not self._stop.is_set():
                sys.stderr.write(
                    f"\r{GY}{self.FRAMES[i % len(self.FRAMES)]} génération…{R}"
                )
                sys.stderr.flush()
                time.sleep(0.08)
                i += 1

        self._thread = threading.Thread(target=_run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=0.3)
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()


# ── Ollama API ────────────────────────────────────────────────────────────────
def api_chat(messages):
    payload = json.dumps(
        {"model": model[0], "messages": messages, "stream": True}
    ).encode()
    req = urllib.request.Request(
        f"{base}/api/chat",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        return urllib.request.urlopen(req, timeout=600)
    except urllib.error.URLError as exc:
        print(f"\n{RE}{B}✗ Ollama inaccessible{R} ({base})", file=sys.stderr)
        print(f"  Lance {B}ollama serve{R} puis réessaie.", file=sys.stderr)
        print(f"  {GY}Détail: {exc.reason}{R}", file=sys.stderr)
        raise SystemExit(1)


def _print_dog_label():
    label = f" dog/{model[0]} "
    bar_w = COLS - len(label) - 3
    print(f"\n{MA}{B}{label}{R} {RULE_FG}{'─' * max(0, bar_w)}{R}")


def _print_response_footer(duration_ns, eval_count):
    parts = []
    if duration_ns:
        parts.append(f"{duration_ns / 1e9:.1f}s")
    if verbose and eval_count:
        parts.append(f"{eval_count} tokens")
    if parts:
        print(f"\n{GY}[{' · '.join(parts)}]{R}", file=sys.stderr)


def stream_response(messages, cancel_event=None):
    total_duration = None
    eval_count     = None
    assistant_parts = []
    filt      = StreamFilter()
    md        = MarkdownRenderer()
    spinner   = Spinner()
    cancelled = False
    first_token = False

    spinner.start()
    try:
        with api_chat(messages) as resp:
            for raw in resp:
                if cancel_event and cancel_event.is_set():
                    resp.close()
                    cancelled = True
                    break
                line = raw.decode().strip()
                if not line:
                    continue
                chunk   = json.loads(line)
                msg     = chunk.get("message") or {}
                content = msg.get("content") or ""
                if content:
                    if not first_token:
                        spinner.stop()
                        first_token = True
                        _print_dog_label()
                    filtered = filt.feed(content)
                    if filtered:
                        rendered = md.feed(filtered)
                        if rendered:
                            print(rendered, end="", flush=True)
                        assistant_parts.append(filtered)
                if chunk.get("done"):
                    total_duration = chunk.get("total_duration")
                    eval_count     = chunk.get("eval_count")
    except urllib.error.HTTPError as exc:
        spinner.stop()
        body = exc.read().decode(errors="replace")
        print(f"\n{RE}Erreur Ollama ({exc.code}): {body}{R}", file=sys.stderr)
        raise
    finally:
        spinner.stop()

    # Flush ligne partielle
    tail_f = filt.flush()
    if tail_f:
        rendered = md.feed(tail_f)
        if rendered:
            print(rendered, end="", flush=True)
    tail_md = md.flush()
    if tail_md:
        print(tail_md, end="", flush=True)
    if tail_f:
        assistant_parts.append(tail_f)

    if not cancelled:
        print()
        _print_response_footer(total_duration, eval_count)
    else:
        print(f"\n{GY}⏹ Annulé{R}", file=sys.stderr)
        return None

    return "".join(assistant_parts) if assistant_parts else ""


# ── File d'attente pendant génération ─────────────────────────────────────────
GEN_HINT = f"  {GY}Entrée : file · Ctrl+C / Échap : annuler{R}"


def _stderr_line(text):
    sys.stderr.write(f"\r\033[K{text}\n")
    sys.stderr.flush()


def _draw_queue_input(buf):
    sys.stderr.write(f"\r\033[K{CY}{PROMPT_CH}{R} {''.join(buf)}")
    sys.stderr.flush()


def read_while_generating(cancel_event, gen_thread):
    fd = _tty_fd()
    if fd is None:
        return []
    old    = termios.tcgetattr(fd)
    queued = []
    buf    = []
    try:
        tty.setcbreak(fd)
        _draw_queue_input(buf)
        while gen_thread.is_alive() and not cancel_event.is_set():
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            ch = os.read(fd, 1).decode("utf-8", errors="replace")
            if ch in ("\n", "\r"):
                line = "".join(buf).strip()
                buf  = []
                if line:
                    queued.append(line)
                    _stderr_line(f"  {GY}⏳ {len(queued)} message(s) en file{R}")
                _draw_queue_input(buf)
            elif ch == "\x03":   # Ctrl+C
                cancel_event.set()
                break
            elif ch == "\x1b":   # Échap
                if select.select([fd], [], [], 0.05)[0]:
                    seq = os.read(fd, 8).decode("utf-8", errors="replace")
                    if seq.startswith("["):
                        continue
                cancel_event.set()
                break
            elif ch in ("\x7f", "\x08"):
                if buf:
                    buf.pop()
                    _draw_queue_input(buf)
            elif ch >= " " or ch == "\t":
                buf.append(ch)
                _draw_queue_input(buf)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()
    return queued


def run_generation(messages, cancel_event):
    result = {"text": None, "error": None}

    def worker():
        try:
            result["text"] = stream_response(messages, cancel_event)
        except urllib.error.HTTPError:
            result["error"] = "http"

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()

    queued = []
    if tty_in is not None and mode != "print":
        print(GEN_HINT, file=sys.stderr)
        queued = read_while_generating(cancel_event, thread)

    thread.join()
    return result["text"], result["error"], queued


# ── Slash commands ────────────────────────────────────────────────────────────
HELP_TEXT = f"""
  {B}Commandes{R}
  {CY}/clear{R}          effacer l'historique et l'écran
  {CY}/docs{R}           injecter README.md + GOOD.md pour le prochain message
  {CY}/model{R} {D}<nom>{R}   changer de modèle Ollama  (ex: {D}/model llama3.2{R})
  {CY}/context{R}        afficher la taille de l'historique
  {CY}/copy{R}           copier la dernière réponse dans le presse-papiers
  {CY}/bye{R}            quitter

  {B}Raccourcis{R}
  {GY}Ctrl+D{R}    quitter
  {GY}Ctrl+C{R}    annuler la génération en cours
  {GY}Entrée{R}    (pendant une réponse) mettre le message en file d'attente
"""


def handle_slash(text, messages):
    lowered = text.lower().strip()

    if lowered in ("/bye", "/exit", "/quit", "/q"):
        return "quit", messages

    if lowered in ("/clear", "/reset"):
        os.system("clear")
        _print_header()
        return "clear", [{"role": "system", "content": system_str}]

    if lowered in ("/help", "/?"):
        print(HELP_TEXT)
        return "help", messages

    if lowered.startswith("/model"):
        parts = text.strip().split(None, 1)
        if len(parts) < 2 or not parts[1].strip():
            print(f"  {GY}Modèle actuel : {B}{model[0]}{R}")
            print(f"  {D}Usage : /model <nom>  (ex : /model llama3.2){R}")
        else:
            model[0] = parts[1].strip()
            print(f"  {GR}✓ Modèle → {B}{model[0]}{R}")
        return "model", messages

    if lowered in ("/context", "/ctx", "/info"):
        turns = len([m for m in messages if m["role"] != "system"])
        chars = sum(len(m.get("content", "")) for m in messages)
        print(
            f"  {GY}Historique : {B}{turns}{R}{GY} messages · "
            f"~{chars:,} caractères{R}"
        )
        return "info", messages

    if lowered in ("/docs", "/doc"):
        ctx = _gather_docs_context("")
        if ctx:
            pending_docs_context[0] = ctx
            print(f"  {GR}✓ Documentation chargée pour le prochain message.{R}")
        else:
            print(f"  {GY}Aucun README.md / GOOD.md trouvé.{R}")
        return "docs", messages

    if lowered == "/copy":
        # Cherche la dernière réponse assistant
        last = next(
            (m["content"] for m in reversed(messages) if m["role"] == "assistant"),
            None,
        )
        if not last:
            print(f"  {GY}Aucune réponse à copier.{R}")
        else:
            try:
                subprocess.run(
                    ["xclip", "-selection", "clipboard"],
                    input=last.encode(),
                    check=True,
                    stderr=subprocess.DEVNULL,
                )
                print(f"  {GR}✓ Copié dans le presse-papiers.{R}")
            except (FileNotFoundError, subprocess.CalledProcessError):
                try:
                    subprocess.run(
                        ["xdotool", "type", "--clearmodifiers", last],
                        check=True,
                        stderr=subprocess.DEVNULL,
                    )
                    print(f"  {GR}✓ Copié (xdotool).{R}")
                except (FileNotFoundError, subprocess.CalledProcessError):
                    print(f"  {RE}✗ xclip ou xdotool introuvable.{R}")
        return "copy", messages

    return None, messages


# ── Header ────────────────────────────────────────────────────────────────────
def _get_git_context():
    try:
        br = subprocess.check_output(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        proj = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return os.path.basename(proj), br
    except Exception:
        return None, None


def _print_header():
    proj, branch = _get_git_context()

    # Ligne de titre
    tag    = f"{MA}{B}dog{R}"
    mdl    = f"{GY}{model[0]}{R}"
    sep    = f"{RULE_FG}·{R}"
    parts  = [tag, sep, mdl]
    if proj:
        parts += [sep, f"{W}{proj}{R}"]
    if branch:
        parts += [sep, f"{CY}{branch}{R}"]
    title_str = " ".join(parts)
    title_vis = " ".join([
        "dog", "·", model[0],
        *(["·", proj] if proj else []),
        *(["·", branch] if branch else []),
    ])
    pad = max(0, COLS - len(title_vis) - 5)
    print(f"{RULE_FG}╭─ {R}{title_str} {RULE_FG}{'─' * pad}╮{R}")

    # Ligne de commandes
    cmds_str = (
        f"  {GY}/clear  /docs  /model  /context  /copy  /help  /bye"
        f"  ·  Ctrl+D quitter  ·  Ctrl+C annuler{R}  "
    )
    cmds_vis = "  /clear  /docs  /model  /context  /copy  /help  /bye  ·  Ctrl+D quitter  ·  Ctrl+C annuler  "
    pad2 = max(0, COLS - len(cmds_vis) - 2)
    print(f"{RULE_FG}│{R}{cmds_str}{' ' * pad2}{RULE_FG}│{R}")
    print(f"{RULE_FG}╰{'─' * (COLS - 2)}╯{R}")


# ── Affichage tours utilisateur ────────────────────────────────────────────────
def _print_user_turn(text):
    label     = f"{B}{BL} Vous {R}"
    label_vis = " Vous "
    bar_w     = max(0, COLS - len(label_vis) - 2)
    print(f"\n{label} {RULE_FG}{'─' * bar_w}{R}")
    print(text)


# ── Actions (good ai) ─────────────────────────────────────────────────────────
def _run_dog_context(cmd, *args):
    try:
        return subprocess.check_output(
            ["python3", dog_context_script, cmd, *args],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def _gather_docs_context(instruction):
    try:
        return subprocess.check_output(
            ["python3", dog_context_script, "docs", project_root, instruction or ""],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def _is_docs_query(text):
    out = _run_dog_context("is-docs", text)
    return out == "yes"


def _web_search(query):
    print(f"\n{YE}🔍 Recherche web…{R}", file=sys.stderr)
    return _run_dog_context("search", query)


def _enrich_user_message(user_text):
    """Ajoute documentation et/ou résultats web au message utilisateur."""
    parts = [user_text]
    extra = []

    if pending_docs_context[0]:
        extra.append(pending_docs_context[0])
        pending_docs_context[0] = None

    if _is_docs_query(user_text):
        docs = _gather_docs_context(user_text)
        if docs and docs not in extra:
            extra.append(docs)

    intent = _classify_intent(user_text)
    if intent == "search" or web_search_enabled:
        results = _web_search(user_text)
        if results:
            extra.append(results)

    if extra:
        parts.append("\n\n--- Contexte complémentaire ---\n")
        parts.append("\n\n".join(extra))
    return "".join(parts)


def _classify_intent(user_text):
    try:
        return subprocess.check_output(
            ["python3", classify_script, user_text],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "edit"


def _resolve_action(user_text):
    """Retourne edit|start|diagnose|deploy ou None pour rester en mode chat."""
    intent = _classify_intent(user_text)

    if intent in ("start", "diagnose", "deploy"):
        return intent

    if intent == "search":
        return None

    try:
        is_action = subprocess.check_output(
            ["python3", classify_script, "--action", user_text],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

    if is_action == "yes":
        return "edit"
    return None


def _run_good_action(action, user_text):
    """Délègue à good ai (modifications, démarrage, diagnostic, déploiement)."""
    labels = {
        "edit": "Modification de fichiers",
        "start": "Démarrage du projet",
        "diagnose": "Diagnostic",
        "deploy": "Déploiement",
    }
    print(f"\n{YE}⚡ {labels.get(action, action)}{R} {GY}— confirmation requise{R}\n")
    sys.stdout.flush()

    rc = subprocess.run(
        ["good", "ai", action, user_text],
        stdin=sys.stdin,
    ).returncode

    if rc == 0:
        print(f"\n{GR}✓ Action terminée.{R}")
        return f"[Action {action} exécutée : {user_text}]"
    print(f"\n{RE}✗ Action annulée ou échouée.{R}", file=sys.stderr)
    return f"[Action {action} annulée : {user_text}]"


def _maybe_dispatch_action(user_text):
    action = _resolve_action(user_text)
    if not action:
        return None
    return _run_good_action(action, user_text)


# ── chat_once (mode -p) ───────────────────────────────────────────────────────
def chat_once(user_text):
    handled = _maybe_dispatch_action(user_text)
    if handled:
        return

    enriched = _enrich_user_message(user_text)
    messages = [
        {"role": "system", "content": system_str},
        {"role": "user",   "content": enriched},
    ]
    cancel = threading.Event()
    stream_response(messages, cancel)


# ── chat_interactive ──────────────────────────────────────────────────────────
def chat_interactive():
    messages = [{"role": "system", "content": system_str}]
    pending  = []

    while True:
        if pending:
            user_text = pending.pop(0)
            if pending:
                _stderr_line(f"  {GY}⏳ {len(pending)} message(s) en file{R}")
        else:
            try:
                user_text = read_user_line().strip()
            except EOFError:
                print()
                break
            if not user_text:
                continue

        action, messages = handle_slash(user_text, messages)
        if action == "quit":
            break
        if action in ("clear", "help", "model", "info", "copy", "docs"):
            continue

        _print_user_turn(user_text)

        action_result = _maybe_dispatch_action(user_text)
        if action_result:
            messages.append({"role": "user", "content": user_text})
            messages.append({"role": "assistant", "content": action_result})
            print()
            continue

        enriched = _enrich_user_message(user_text)
        messages.append({"role": "user", "content": enriched})
        cancel    = threading.Event()
        assistant, err, queued = run_generation(messages, cancel)

        if err == "http":
            messages.pop()
        elif assistant:
            messages.append({"role": "assistant", "content": assistant})
        elif cancel.is_set():
            messages.pop()

        for q_line in queued:
            action, messages = handle_slash(q_line, messages)
            if action == "quit":
                return
            if action == "clear":
                pending.clear()
                continue
            if action in ("help", "model", "info", "copy", "docs"):
                continue
            pending.append(q_line)

        print()


# ── Entry point ───────────────────────────────────────────────────────────────
if mode == "print":
    p = prompt_arg.strip()
    if not p:
        print('Usage: good dog -p "question"  (ou pipe stdin)', file=sys.stderr)
        raise SystemExit(1)
    chat_once(p)
else:
    _print_header()
    chat_interactive()
    print(f"\n{GY}Au revoir.{R}")
PY
}

cmd_dog() {
    local print_mode=0 prompt="" model="" verbose=0 web_search=0
    model="$(_good_ollama_model)"

    while [ $# -gt 0 ]; do
        case "$1" in
            -p|--print)
                print_mode=1
                shift
                prompt="${*:-}"
                break
                ;;
            --model|-m)
                shift
                model="${1:-}"
                if [ -z "$model" ]; then
                    echo "Usage: good dog --model <nom>" >&2
                    exit 1
                fi
                ;;
            --web)
                web_search=1
                ;;
            -v|--verbose)
                verbose=1
                ;;
            -h|--help|help)
                echo "Usage: good dog [-p \"question\"] [--model modèle] [--web] [--verbose]"
                echo ""
                echo "Assistant interactif style Claude Code, propulsé par Ollama (défaut : qwen3:8b)."
                echo ""
                echo "  good dog                      Session interactive multi-tours"
                echo "  good dog -p \"…\"               Réponse unique streamée"
                echo "  echo \"…\" | good dog -p        Question via stdin"
                echo "  good dog --model llama3.2     Surcharge le modèle pour cette session"
                echo "  good dog --web                Active la recherche web (DuckDuckGo)"
                echo "  GOOD_WEB_SEARCH=1 good dog    Recherche web via variable d'environnement"
                echo "  good dog --verbose            Affiche durée + tokens"
                echo ""
                echo "  /clear   effacer l'historique   /docs          charger README+GOOD.md"
                echo "  /model <nom>  changer de modèle /context       taille de l'historique"
                echo "  /copy         copier réponse    /bye           quitter"
                echo ""
                echo "Alias : « dog » appelle good dog (si installé via install-good.sh)."
                echo "Modèle par défaut : $(_good_ollama_model)"
                exit 0
                ;;
            *)
                echo "Option inconnue: $1" >&2
                echo "Usage: good dog [-p \"question\"] [--model modèle] [--web]" >&2
                exit 1
                ;;
        esac
        shift
    done

    if [ "${GOOD_WEB_SEARCH:-0}" = "1" ]; then
        web_search=1
    fi

    _ai_check_ollama

    local system host mode root config
    if [ ! -t 0 ]; then
        if [ "$print_mode" -eq 0 ]; then
            print_mode=1
        fi
        if [ -z "$prompt" ]; then
            prompt="$(cat)"
        fi
    fi

    system="$(_dog_system_prompt)"
    host="$(_dog_ollama_host)"
    root="$(_good_root)"
    config="$(_good_config_file)"

    if [ "$print_mode" -eq 1 ]; then
        if [ -z "$prompt" ]; then
            echo "Usage: good dog -p \"question\"  (ou pipe stdin)" >&2
            exit 1
        fi
        _dog_chat "$host" "$model" "$system" print "$verbose" "$prompt" "$GOOD_LIB" "$web_search" "$root" "$config"
        return
    fi

    _dog_chat "$host" "$model" "$system" interactive "$verbose" "" "$GOOD_LIB" "$web_search" "$root" "$config"
}
