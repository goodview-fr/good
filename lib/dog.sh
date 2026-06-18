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
Commit, push, sync, conflits : exécute directement (run_git / resolve_conflicts) — pas de confirmation.
Recherche web : opt-in (GOOD_WEB_SEARCH=1 ou --web).

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
CODE_FG   = "\033[38;5;215m"
RULE_FG   = "\033[38;5;240m"
HEADER_FG = "\033[38;5;147m"
QUOTE_FG  = "\033[38;5;246m"

COLS = shutil.get_terminal_size((80, 24)).columns

# ── State ─────────────────────────────────────────────────────────────────────
host_arg, model_arg, system_str, mode, verbose_str, prompt_arg, good_lib, web_search_str, root_arg, config_arg, provider_arg, api_key_arg = sys.argv[1:13]
verbose  = verbose_str == "1"
web_search_enabled = web_search_str == "1"
provider = provider_arg   # "ollama" | "deepseek" | "openai"
api_key  = api_key_arg

# Ollama: base URL only used when provider == ollama
base     = host_arg if host_arg.startswith("http") else f"http://{host_arg}" if host_arg else ""

model    = [model_arg]
project_root = root_arg
config_file = config_arg
multitask_str = sys.argv[13] if len(sys.argv) > 13 else "0"
agent_str = sys.argv[14] if len(sys.argv) > 14 else "0"
multitask = multitask_str == "1" or os.environ.get("GOOD_DOG_MULTITASK") == "1"
agent_mode = agent_str == "1" or os.environ.get("GOOD_DOG_AGENT") == "1"
TODOS_FILE = os.path.join(project_root, ".good", "todos.json")
SESSION_FILE = os.path.join(project_root, ".good", "dog_session.json")
forced_input = [None]
_last_sigint = [0.0]

# ── Import local modules directly (performance: no subprocess per call) ───────
sys.path.insert(0, os.path.join(good_lib, "py"))
import classify_intent as _ci
import dog_context as _dc
import project_info as _pi
from agent_loop import AgentLoop
from tools import ToolEngine, TOOLS_NEEDS_CONFIRM, format_tool_args, git_needs_confirm, normalize_tool_args, shell_needs_confirm
from resolve_conflicts import resolve_all
from system_prompt import SystemPromptBuilder
from context_manager import ContextManager

pending_docs_context = [None]

def _build_system_prompt():
    builder = SystemPromptBuilder(
        project_root, config_file, provider,
        include_tools=agent_mode,
    )
    if provider == "ollama" and not agent_mode:
        return builder.build_compact()
    return builder.build()

system_str = _build_system_prompt()
ctx_manager = ContextManager(model[0], provider)

PROMPT_CH = "❯"

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


def _history_messages(messages):
    return [m for m in messages if m.get("role") != "system"]


def _load_session():
    if not os.path.isfile(SESSION_FILE):
        return [], None
    try:
        with open(SESSION_FILE, encoding="utf-8") as f:
            data = json.load(f)
        return data.get("history") or [], data.get("pending_command")
    except Exception:
        return [], None


def _save_session(history, pending_command=None):
    try:
        os.makedirs(os.path.dirname(SESSION_FILE), exist_ok=True)
        with open(SESSION_FILE, "w", encoding="utf-8") as f:
            json.dump(
                {"history": history, "pending_command": pending_command},
                f,
                ensure_ascii=False,
                indent=2,
            )
    except OSError:
        pass


def _print_cancel_hint(pending=None):
    if pending:
        short = pending[:55] + ("…" if len(pending) > 55 else "")
        print(
            f"\n{GY}⏹ Interrompu — {CY}/resume{R}{GY} pour relancer : "
            f"« {short} »{R}",
            file=sys.stderr,
        )
    else:
        print(
            f"\n{GY}⏹ Annulé — {CY}/resume{R}{GY} si besoin · "
            f"Ctrl+C ×2 ou Ctrl+D pour quitter{R}",
            file=sys.stderr,
        )


def read_user_line():
    sys.stdout.write(f"\n{CY}{PROMPT_CH}{R} ")
    sys.stdout.flush()
    line = tty_in.readline()
    if not line:
        raise EOFError
    return line.rstrip("\n\r")


# ── Markdown renderer ─────────────────────────────────────────────────────────
def _strip_ansi(text):
    return re.sub(r"\033\[[0-9;]*m", "", text)


def _hl_inline(text):
    parts = re.split(r"(`[^`\n]+`)", text)
    out = []
    for p in parts:
        if p.startswith("`") and p.endswith("`") and len(p) > 2:
            out.append(f"{CODE_FG}{p[1:-1]}{R}")
        else:
            p = re.sub(r"\*\*(.+?)\*\*", lambda m: f"{B}{m.group(1)}{R}", p)
            p = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", lambda m: f"{IT}{m.group(1)}{R}", p)
            p = re.sub(r"__(.+?)__", lambda m: f"{B}{m.group(1)}{R}", p)
            p = re.sub(r"\[([^\]]+)\]\([^)]+\)", lambda m: f"{UL}{CY}{m.group(1)}{R}", p)
            out.append(p)
    return "".join(out)


class MarkdownRenderer:
    def __init__(self):
        self._buf  = ""
        self._code = False
        self._code_lang = ""

    def _render_line(self, line):
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
        if line.startswith("#### "):
            return f"{B}{CY}{line[5:]}{R}"
        if line.startswith("### "):
            return f"{B}{CY}{line[4:]}{R}"
        if line.startswith("## "):
            return f"{B}{BL}{line[3:]}{R}"
        if line.startswith("# "):
            return f"{B}{MA}{line[2:]}{R}"
        if re.match(r"^[-*_]{3,}\s*$", line):
            return f"{RULE_FG}{'─' * (COLS - 2)}{R}"
        m = re.match(r"^(\s*)([-*+]) (.+)", line)
        if m:
            return f"{m.group(1)}{CY}•{R} {_hl_inline(m.group(3))}"
        m = re.match(r"^(\s*)(\d+\.) (.+)", line)
        if m:
            return f"{m.group(1)}{GY}{m.group(2)}{R} {_hl_inline(m.group(3))}"
        if line.startswith("> "):
            return f"{RULE_FG}▎{R} {QUOTE_FG}{IT}{line[2:]}{R}"
        if not line.strip():
            return ""
        return _hl_inline(line)

    def feed(self, text):
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


# ── Filtre blocs Thinking ─────────────────────────────────────────────────────
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


# ── API calls ─────────────────────────────────────────────────────────────────
def api_chat_ollama(messages):
    """Ollama ndjson streaming."""
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


def api_chat_openai(messages):
    """OpenAI-compatible SSE streaming (DeepSeek, OpenAI, etc.)."""
    if provider == "deepseek":
        base_url = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
    else:
        base_url = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com")

    payload = json.dumps({
        "model": model[0],
        "messages": messages,
        "stream": True,
    }).encode()
    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    try:
        return urllib.request.urlopen(req, timeout=600)
    except urllib.error.URLError as exc:
        provider_label = provider.capitalize()
        print(f"\n{RE}{B}✗ {provider_label} inaccessible{R}", file=sys.stderr)
        print(f"  Vérifie ta clé API et ta connexion.", file=sys.stderr)
        print(f"  {GY}Détail: {exc.reason}{R}", file=sys.stderr)
        raise SystemExit(1)


def api_chat(messages):
    if provider in ("deepseek", "openai"):
        return api_chat_openai(messages)
    return api_chat_ollama(messages)


# ── Stream parsers ────────────────────────────────────────────────────────────
def _iter_ollama_stream(resp, cancel_event):
    """Yields (content_chunk, done_flag, total_duration, eval_count)."""
    for raw in resp:
        if cancel_event and cancel_event.is_set():
            resp.close()
            return
        line = raw.decode().strip()
        if not line:
            continue
        chunk   = json.loads(line)
        msg     = chunk.get("message") or {}
        content = msg.get("content") or ""
        done    = chunk.get("done", False)
        yield content, done, chunk.get("total_duration"), chunk.get("eval_count")


def _iter_openai_stream(resp, cancel_event):
    """Yields (content_chunk, done_flag, total_duration, eval_count)."""
    for raw in resp:
        if cancel_event and cancel_event.is_set():
            resp.close()
            return
        line = raw.decode("utf-8", errors="replace").strip()
        if not line or not line.startswith("data: "):
            continue
        data_str = line[6:]
        if data_str == "[DONE]":
            yield "", True, None, None
            return
        try:
            chunk = json.loads(data_str)
        except json.JSONDecodeError:
            continue
        choices = chunk.get("choices") or []
        if not choices:
            continue
        delta   = choices[0].get("delta") or {}
        content = delta.get("content") or ""
        finish  = choices[0].get("finish_reason")
        done    = finish is not None
        usage   = chunk.get("usage") or {}
        yield content, done, None, usage.get("completion_tokens")


def _print_dog_label():
    provider_tag = f"/{provider}" if provider != "ollama" else ""
    label = f" dog/{model[0]}{provider_tag} "
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
            if provider in ("deepseek", "openai"):
                iter_fn = _iter_openai_stream(resp, cancel_event)
            else:
                iter_fn = _iter_ollama_stream(resp, cancel_event)

            for content, done, td, ec in iter_fn:
                if cancel_event and cancel_event.is_set():
                    cancelled = True
                    break
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
                if done:
                    if td:
                        total_duration = td
                    if ec:
                        eval_count = ec

    except urllib.error.HTTPError as exc:
        spinner.stop()
        body = exc.read().decode(errors="replace")
        try:
            err_data = json.loads(body)
            err_msg = (err_data.get("error") or {}).get("message") or body
        except Exception:
            err_msg = body
        print(f"\n{RE}Erreur API ({exc.code}): {err_msg}{R}", file=sys.stderr)
        raise
    finally:
        spinner.stop()

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


def _print_agent_response(text):
    if not text:
        return
    _print_dog_label()
    md = MarkdownRenderer()
    for line in text.split("\n"):
        rendered = md.feed(line + "\n")
        if rendered:
            print(rendered, end="", flush=True)
    tail = md.flush()
    if tail:
        print(tail, end="", flush=True)
    print()


def _confirm_tool(name, args):
    """Demande confirmation sauf si GOOD_YES=1 (défaut dans good dog)."""
    args = normalize_tool_args(name, args or {})
    if os.environ.get("GOOD_YES") == "1":
        return True
    if name == "write_file":
        path = args.get("path", "?")
        print(f"\n{YE}⚡ write_file({path}){R} — confirmer? [Y/n] ", end="", flush=True)
    elif name == "run_git":
        git_args = args.get("args") or []
        if not git_needs_confirm(git_args):
            return True
        print(f"\n{YE}⚡ git {' '.join(str(a) for a in git_args)}{R}\nConfirmer? [Y/n] ", end="", flush=True)
    elif name in ("run_shell", "run_command"):
        cmd = args.get("command", "?")
        if not shell_needs_confirm(cmd):
            return True
        print(f"\n{YE}⚡ Exécuter: {cmd}{R}\nConfirmer? [Y/n] ", end="", flush=True)
    else:
        return True
    try:
        line = tty_in.readline().strip().lower() if tty_in else "y"
        return line not in ("n", "non")
    except Exception:
        return True


def _ai_oneshot(prompt: str) -> str:
    """Appel IA non-stream pour résolution de conflits."""
    messages = [{"role": "user", "content": prompt}]
    if provider in ("deepseek", "openai"):
        api_base = (
            os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
            if provider == "deepseek"
            else os.environ.get("OPENAI_BASE_URL", "https://api.openai.com")
        )
        payload = json.dumps({"model": model[0], "messages": messages, "stream": False}).encode()
        req = urllib.request.Request(
            f"{api_base}/v1/chat/completions",
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
        return (data["choices"][0]["message"].get("content") or "").strip()
    payload = json.dumps({"model": model[0], "messages": messages, "stream": False}).encode()
    req = urllib.request.Request(
        f"{base}/api/chat",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        data = json.loads(resp.read())
    content = (data.get("message") or {}).get("content") or ""
    content = re.sub(r"Thinking\.\.\..*?\.\.\.done thinking\.", "", content, flags=re.DOTALL)
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL)
    return content.strip().strip("`")


def _on_tool_call(name, args):
    args = normalize_tool_args(name, args or {})
    args_str = format_tool_args(args)
    sys.stderr.write(f"\r\033[K{GY}⚡ {name}({args_str}){R}\n")
    sys.stderr.flush()


def _on_tool_result(name, result):
    preview = result[:120].replace("\n", " ")
    sys.stderr.write(f"{GY}  → {preview}{'…' if len(result) > 120 else ''}{R}\n")
    sys.stderr.flush()


def run_agent_turn(user_text, messages, cancel_event):
    tool_engine = ToolEngine(project_root, ai_fn=_ai_oneshot)
    base_url = ""
    if provider == "deepseek":
        base_url = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
    elif provider == "openai":
        base_url = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com")
    elif provider == "ollama":
        base_url = base

    trimmed = ctx_manager.trim(messages[1:])
    history = trimmed

    loop = AgentLoop(
        model=model[0],
        provider=provider,
        api_key=api_key,
        base_url=base_url,
        tool_engine=tool_engine,
        system_prompt=system_str,
        verbose=verbose,
        cancel_event=cancel_event,
        on_tool_call=_on_tool_call,
        on_tool_result=_on_tool_result,
        confirm_tool=_confirm_tool,
    )
    final, updated = loop.run(user_text, history)
    return final, updated


def run_agent_generation(user_text, messages, cancel_event):
    result = {"final": None, "updated": None, "error": None}

    def worker():
        try:
            final, updated = run_agent_turn(user_text, messages, cancel_event)
            result["final"] = final
            result["updated"] = updated
        except KeyboardInterrupt:
            cancel_event.set()
        except Exception as exc:
            result["error"] = str(exc)

    spinner = Spinner()
    spinner.start()
    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    queued = []
    if tty_in is not None:
        print(GEN_HINT, file=sys.stderr)
        queued = read_while_generating(cancel_event, thread)
    try:
        thread.join()
    except KeyboardInterrupt:
        cancel_event.set()
        thread.join(timeout=3)
    spinner.stop()

    if result["error"]:
        print(f"\n{RE}Erreur agent : {result['error']}{R}", file=sys.stderr)
        return None, None, queued
    if cancel_event.is_set():
        return None, None, queued
    return result["final"], result["updated"], queued


# ── File d'attente pendant génération ─────────────────────────────────────────
GEN_HINT = (
    f"  {GY}Entrée : file · Ctrl+C / Échap : annuler · "
    f"/resume : reprendre · Ctrl+C ×2 : quitter{R}"
)


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
            elif ch == "\x03":
                cancel_event.set()
                break
            elif ch == "\x1b":
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
        except KeyboardInterrupt:
            cancel_event.set()
        except urllib.error.HTTPError:
            result["error"] = "http"

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()

    queued = []
    if tty_in is not None and mode != "print":
        print(GEN_HINT, file=sys.stderr)
        queued = read_while_generating(cancel_event, thread)

    try:
        thread.join()
    except KeyboardInterrupt:
        cancel_event.set()
        thread.join(timeout=3)

    return result["text"], result["error"], queued


# ── Intent + enrichissement (performance: import direct, cache intent) ─────────
_intent_cache: dict = {}


def _classify_intent(user_text: str) -> str:
    if user_text not in _intent_cache:
        _intent_cache[user_text] = _ci.classify(user_text)
    return _intent_cache[user_text]


def _is_action(user_text: str) -> bool:
    return _ci.is_file_action(user_text)


def _is_docs_query(text: str) -> bool:
    return _dc.is_docs_query(text)


def _gather_docs_context(instruction: str) -> str:
    return _dc.docs_context(project_root, instruction or "")


def _web_search(query: str) -> str:
    print(f"\n{YE}🔍 Recherche web…{R}", file=sys.stderr)
    return _dc.web_search(query)


def _enrich_user_message(user_text: str, intent: str) -> str:
    """Enrichit le message utilisateur avec docs et/ou recherche web.

    Prend l'intent pré-calculé pour éviter le double appel.
    """
    parts = [user_text]
    extra = []

    if pending_docs_context[0]:
        extra.append(pending_docs_context[0])
        pending_docs_context[0] = None

    if _is_docs_query(user_text):
        docs = _gather_docs_context(user_text)
        if docs and docs not in extra:
            extra.append(docs)

    if intent == "search" or web_search_enabled:
        results = _web_search(user_text)
        if results:
            extra.append(results)

    if extra:
        parts.append("\n\n--- Contexte complémentaire ---\n")
        parts.append("\n\n".join(extra))
    return "".join(parts)


def _get_start_candidates() -> list:
    try:
        info = _pi.detect(project_root)
        return info.get("start_commands") or []
    except Exception:
        return []


def _enrich_action_context(user_text: str, intent: str) -> str:
    """Enrichit start/diagnose/shell en mode classique (sans agent)."""
    if agent_mode or intent not in ("start", "diagnose", "shell"):
        return user_text
    extra = []
    candidates = _get_start_candidates()
    if intent == "shell":
        extra.append(
            "L'utilisateur demande une action shell (docker, npm, composer, make…). "
            "Propose et explique la commande exacte à exécuter — ne demande pas à l'utilisateur "
            "de la retaper manuellement. Pour exécution directe : `good dog --agent`."
        )
        if candidates:
            extra.append(f"Commandes de démarrage du projet : {', '.join(candidates)}")
    elif intent == "start":
        if candidates:
            extra.append(f"Commandes de démarrage détectées : {', '.join(candidates)}")
        else:
            extra.append(
                "Aucun script standard détecté — essaie docker compose up -d, npm run dev, "
                "composer dev ou ./good dev start selon le projet."
            )
        extra.append("Pour exécution automatique avec confirmation : `good dog --agent`.")
    elif intent == "diagnose" and candidates:
        extra.append(f"Commandes de redémarrage possibles : {', '.join(candidates)}")
    if not extra:
        return user_text
    return user_text + "\n\n--- Contexte action ---\n" + "\n".join(extra)


def _resolve_action(intent: str, user_text: str):
    """Retourne l'action (edit|deploy) ou None. En mode agent, l'agent gère tout."""
    if agent_mode:
        return None
    if intent in ("shell", "start", "diagnose"):
        return None
    if intent == "deploy":
        return intent
    if intent == "search":
        return None
    if _is_action(user_text):
        return "edit"
    return None


def _is_git_resolve(text: str) -> bool:
    t = text.lower()
    return bool(re.search(r"\b(conflit|conflits|resolve|résous|resous)\b", t))


def _resolve_git_conflicts() -> str:
    print(f"\n{YE}⚡ Résolution des conflits git…{R}")

    def _progress(msg):
        print(f"  {msg}")

    ok, msg = resolve_all(project_root, _ai_oneshot, on_progress=_progress)
    print(msg)
    if ok:
        print(f"\n{GR}✓ Conflits résolus.{R}")
        return "[Conflits git résolus]"
    print(f"\n{RE}✗ Résolution incomplète.{R}", file=sys.stderr)
    return "[Résolution conflits échouée]"


def _run_good_action(action: str, user_text: str) -> str:
    labels = {
        "edit": "Modification de fichiers",
        "start": "Démarrage du projet",
        "diagnose": "Diagnostic",
        "deploy": "Déploiement",
    }
    if os.environ.get("GOOD_YES") != "1":
        print(f"\n{YE}⚡ {labels.get(action, action)}{R} {GY}— confirmation requise{R}\n")
        sys.stdout.flush()

    env = os.environ.copy()
    rc = subprocess.run(
        ["good", "ai", action, user_text],
        stdin=sys.stdin,
        env=env,
    ).returncode

    if rc == 0:
        print(f"\n{GR}✓ Action terminée.{R}")
        return f"[Action {action} exécutée : {user_text}]"
    if action == "start":
        candidates = _get_start_candidates()
        print(f"\n{YE}Aucun script de démarrage standard.{R}")
        if candidates:
            print(f"  Commandes détectées : {', '.join(candidates)}")
        print(f"  Essaie {B}good dog --agent{R} ou tape directement la commande.")
        print(f"  Ex: {CY}docker compose up -d{R}, {CY}npm run dev{R}")
    else:
        print(f"\n{RE}✗ Action échouée.{R}", file=sys.stderr)
    return f"[Action {action} annulée : {user_text}]"


# ── Task Manager ──────────────────────────────────────────────────────────────
class Task:
    """Une tâche background exécutée par 'good ai edit <instruction>'."""
    def __init__(self, tid: int, instruction: str):
        self.id          = tid
        self.instruction = instruction
        self.status      = "pending"   # pending | running | done | cancelled | error
        self.cancel      = threading.Event()
        self.thread      = None
        self.last_line   = ""
        self.result      = None
        self.created_at  = time.time()


class TaskManager:
    def __init__(self):
        self._tasks = []
        self._next_id = 1
        self._lock = threading.Lock()

    def add(self, instruction: str):
        with self._lock:
            t = Task(self._next_id, instruction)
            self._next_id += 1
            self._tasks.append(t)
        return t

    def get(self, tid: int):
        return next((t for t in self._tasks if t.id == tid), None)

    def all(self) -> list:
        return list(self._tasks)

    def running(self) -> list:
        return [t for t in self._tasks if t.status == "running"]

    def pending_tasks(self) -> list:
        return [t for t in self._tasks if t.status == "pending"]


task_manager = TaskManager()


def _notify_task_done(task):
    icon  = {"done": "✓", "cancelled": "⏹", "error": "✗"}.get(task.status, "?")
    color = {"done": GR, "cancelled": GY, "error": RE}.get(task.status, R)
    sys.stderr.write(f"\r\033[K{color}{icon} Tâche #{task.id} {task.status}{R}: {task.instruction[:50]}\n")
    sys.stderr.flush()
    sys.stderr.write(f"{CY}{PROMPT_CH}{R} ")
    sys.stderr.flush()


def _run_task(task, good_root: str):
    """Lance 'good ai edit <instruction>' dans un thread dédié."""
    task.status = "running"
    lines = []
    env = os.environ.copy()
    env["GOOD_YES"] = "1"
    try:
        proc = subprocess.Popen(
            ["good", "ai", "edit", task.instruction],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            cwd=good_root,
            env=env,
        )
        for line in proc.stdout:
            if task.cancel.is_set():
                proc.terminate()
                break
            line = line.rstrip()
            if line:
                task.last_line = line
                lines.append(line)
        proc.wait()
        if task.cancel.is_set():
            task.status = "cancelled"
        elif proc.returncode == 0:
            task.status = "done"
            task.result = "\n".join(lines[-5:])
        else:
            task.status = "error"
            task.result = "\n".join(lines[-3:])
    except Exception as exc:
        task.status = "error"
        task.result = str(exc)
    finally:
        _notify_task_done(task)


def spawn_task(instruction: str):
    """Crée et lance une tâche en arrière-plan."""
    task = task_manager.add(instruction)
    task.thread = threading.Thread(
        target=_run_task,
        args=(task, project_root),
        daemon=True,
    )
    task.thread.start()
    return task


def _extract_task_list(ai_response: str) -> list:
    """Extrait une liste de tâches JSON depuis la réponse IA.

    Cherche: {"tasks": ["instruction 1", "instruction 2"]}
    """
    m = re.search(r'\{"tasks"\s*:\s*(\[[^\]]+\])\}', ai_response)
    if m:
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            pass
    return []


def _check_git_conflicts() -> list:
    """Retourne la liste des fichiers en conflit."""
    try:
        out = subprocess.check_output(
            ["git", "diff", "--name-only", "--diff-filter=U"],
            cwd=project_root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return [f for f in out.splitlines() if f]
    except Exception:
        return []


# ── Todos ─────────────────────────────────────────────────────────────────────
def _load_todos() -> list:
    if not os.path.isfile(TODOS_FILE):
        return []
    try:
        with open(TODOS_FILE) as f:
            return json.load(f)
    except Exception:
        return []


def _save_todos(todos: list):
    os.makedirs(os.path.dirname(TODOS_FILE), exist_ok=True)
    with open(TODOS_FILE, "w") as f:
        json.dump(todos, f, ensure_ascii=False, indent=2)


def _print_todos():
    todos = _load_todos()
    if not todos:
        print(f"  {GY}Aucun todo.{R}")
        return
    n = len(todos)
    print(f"\n  {B}Todos{R} {GY}(#{n}){R}")
    print(f"  {RULE_FG}{'─' * (COLS - 4)}{R}")
    for item in todos:
        idx  = item.get("id", "?")
        done = item.get("done", False)
        text = item.get("text", "")
        icon = f"{GR}✓{R}" if done else f"{GY}○{R}"
        dim  = f"{GY}{D}" if done else ""
        print(f"  {idx}. {icon}  {dim}{text}{R if done else ''}")
    print(f"  {RULE_FG}{'─' * (COLS - 4)}{R}")


def _print_tasks():
    tasks = task_manager.all()
    if not tasks:
        print(f"  {GY}Aucune tâche.{R}")
        return
    done_c   = sum(1 for t in tasks if t.status == "done")
    active_c = sum(1 for t in tasks if t.status in ("running", "pending"))
    frames   = Spinner.FRAMES
    print(f"\n  {B}Tâches{R}")
    print(f"  {RULE_FG}{'─' * (COLS - 4)}{R}")
    for t in tasks:
        if t.status == "done":
            icon  = f"{GR}✓{R}"
            label = f"{GR}done    {R}"
        elif t.status == "running":
            icon  = f"{CY}{frames[int(time.time() * 8) % len(frames)]}{R}"
            label = f"{CY}running {R}"
        elif t.status == "pending":
            icon  = f"{GY}⏸{R}"
            label = f"{GY}pending {R}"
        elif t.status == "cancelled":
            icon  = f"{GY}⏹{R}"
            label = f"{GY}annulée {R}"
        else:
            icon  = f"{RE}✗{R}"
            label = f"{RE}erreur  {R}"
        instr = t.instruction[:52] + ("…" if len(t.instruction) > 52 else "")
        print(f"  {GY}#{t.id}{R} {icon} {label} {instr}")
        hint_src = t.last_line if t.status == "running" else (t.result or "")
        if hint_src:
            hint = hint_src.splitlines()[0][:60]
            print(f"     {GY}└ {hint}{R}")
    print(f"  {RULE_FG}{'─' * (COLS - 4)}{R}")
    print(f"  {GY}{active_c} active{'s' if active_c != 1 else ''} · {done_c} terminée{'s' if done_c != 1 else ''}{R}")


# ── Slash commands ────────────────────────────────────────────────────────────
HELP_TEXT = f"""
  {B}Conversation{R}
  {CY}/clear{R}               effacer l'historique et l'écran
  {CY}/docs{R}                injecter README.md + GOOD.md
  {CY}/model{R} {D}<nom>{R}        changer de modèle  (ex: {D}/model deepseek-reasoner{R})
  {CY}/provider{R}            afficher le provider actuel
  {CY}/context{R}             taille de l'historique
  {CY}/copy{R}                copier la dernière réponse
  {CY}/resume{R}              reprendre la commande interrompue (Ctrl+C)
  {CY}/bye{R}                 quitter

  {B}Tâches background{R}
  {CY}/tasks{R}               afficher les tâches en cours / terminées
  {CY}/task{R} {D}<instruction>{R}  lancer une tâche en arrière-plan
  {CY}/stop{R} {D}[id]{R}          arrêter une tâche (ou toutes)
  {CY}/edit{R} {D}<id> <instr>{R}  modifier / relancer une tâche

  {B}Todos{R}
  {CY}/todo{R}                afficher la liste de todos
  {CY}/todo add{R} {D}<texte>{R}   ajouter un todo
  {CY}/todo done{R} {D}<id>{R}     marquer comme fait
  {CY}/todo del{R} {D}<id>{R}      supprimer un todo
  {CY}/todo clear{R}          supprimer tous les todos terminés

  {B}Git{R}
  {CY}/resolve{R}             résoudre les conflits git

  {B}Raccourcis{R}
  {GY}Ctrl+D{R}    quitter
  {GY}Ctrl+C{R}    annuler (puis /resume) · Ctrl+C ×2 quitter
  {GY}Entrée{R}    (pendant une réponse) mettre en file d'attente
"""


def handle_slash(text, messages):
    lowered = text.lower().strip()

    if lowered in ("/bye", "/exit", "/quit", "/q"):
        _save_session(_history_messages(messages))
        return "quit", messages

    if lowered in ("/clear", "/reset"):
        os.system("clear")
        _save_session([], pending_command=None)
        _print_header()
        return "clear", [{"role": "system", "content": system_str}]

    if lowered == "/resume":
        _, pending = _load_session()
        if not pending:
            print(f"  {GY}Aucune commande à reprendre.{R}")
        else:
            forced_input[0] = pending
            _save_session(_history_messages(messages), pending_command=None)
            short = pending[:60] + ("…" if len(pending) > 60 else "")
            print(f"  {GR}▶ Reprise : {short}{R}")
        return "resume", messages

    if lowered in ("/help", "/?"):
        print(HELP_TEXT)
        return "help", messages

    if lowered.startswith("/model"):
        parts = text.strip().split(None, 1)
        if len(parts) < 2 or not parts[1].strip():
            print(f"  {GY}Modèle actuel : {B}{model[0]}{R}")
            print(f"  {D}Usage : /model <nom>  (ex : /model deepseek-reasoner){R}")
        else:
            model[0] = parts[1].strip()
            ctx_manager.set_model(model[0])
            print(f"  {GR}✓ Modèle → {B}{model[0]}{R}")
        return "model", messages

    if lowered in ("/provider", "/prov"):
        provider_label = f"{provider} ({model[0]})"
        if provider == "ollama":
            provider_label += f"  {GY}@ {base}{R}"
        print(f"  {GY}Provider : {B}{provider_label}{R}")
        return "provider", messages

    if lowered in ("/context", "/ctx", "/info"):
        turns = len([m for m in messages if m["role"] != "system"])
        chars = sum(len(str(m.get("content", ""))) for m in messages)
        print(
            f"  {GY}Historique : {B}{turns}{R}{GY} messages · "
            f"~{chars:,} caractères{R}"
        )
        print(ctx_manager.status_line(messages))
        if agent_mode:
            print(f"  {GY}Mode agent : {GR}actif{R} (tool-use ReAct)")
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
        last = next(
            (m["content"] for m in reversed(messages) if m["role"] == "assistant"),
            None,
        )
        if not last:
            print(f"  {GY}Aucune réponse à copier.{R}")
        else:
            copied = False
            for cmd in (
                ["wl-copy"],
                ["xclip", "-selection", "clipboard"],
                ["xsel", "--clipboard", "--input"],
            ):
                try:
                    subprocess.run(cmd, input=last.encode(), check=True, stderr=subprocess.DEVNULL)
                    print(f"  {GR}✓ Copié dans le presse-papiers.{R}")
                    copied = True
                    break
                except (FileNotFoundError, subprocess.CalledProcessError):
                    continue
            if not copied:
                print(f"  {RE}✗ Aucun outil presse-papiers trouvé (wl-copy, xclip, xsel).{R}")
        return "copy", messages

    # /tasks — show task list
    if lowered in ("/tasks", "/taches", "/tâches"):
        _print_tasks()
        return "task", messages

    # /task <instruction> — spawn background task, or show list if no args
    if lowered.startswith("/task"):
        parts = text.strip().split(None, 1)
        if len(parts) < 2 or not parts[1].strip():
            _print_tasks()
        else:
            instr = parts[1].strip()
            t = spawn_task(instr)
            print(f"  {GR}⚡ Tâche #{t.id} lancée{R}: {instr[:60]}")
        return "task", messages

    # /stop [id] — cancel task(s)
    if lowered.startswith("/stop"):
        parts = text.strip().split()
        if len(parts) > 1:
            try:
                tid = int(parts[1])
                t = task_manager.get(tid)
                if t is None:
                    print(f"  {RE}✗ Tâche #{tid} introuvable.{R}")
                elif t.status not in ("running", "pending"):
                    print(f"  {GY}Tâche #{tid} déjà {t.status}.{R}")
                else:
                    t.cancel.set()
                    t.status = "cancelled"
                    print(f"  {GY}⏹ Tâche #{tid} annulée.{R}")
            except ValueError:
                print(f"  {RE}Usage: /stop [id]{R}")
        else:
            stopped = 0
            for t in task_manager.all():
                if t.status in ("running", "pending"):
                    t.cancel.set()
                    t.status = "cancelled"
                    stopped += 1
            if stopped:
                print(f"  {GY}⏹ {stopped} tâche(s) annulée(s).{R}")
            else:
                print(f"  {GY}Aucune tâche active.{R}")
        return "stop", messages

    # /edit <id> <instruction> — modify or restart a task
    if lowered.startswith("/edit "):
        parts = text.strip().split(None, 2)
        if len(parts) < 3:
            print(f"  {GY}Usage: /edit <id> <nouvelle instruction>{R}")
            return "edit_task", messages
        try:
            tid = int(parts[1])
        except ValueError:
            print(f"  {RE}✗ ID invalide: {parts[1]}{R}")
            return "edit_task", messages
        new_instr = parts[2].strip()
        t = task_manager.get(tid)
        if t is None:
            print(f"  {RE}✗ Tâche #{tid} introuvable.{R}")
        elif t.status == "pending":
            t.instruction = new_instr
            print(f"  {GR}✓ Tâche #{tid} mise à jour.{R}")
        elif t.status == "running":
            t.cancel.set()
            if t.thread:
                t.thread.join(timeout=2)
            nt = spawn_task(new_instr)
            print(f"  {GR}⚡ Tâche #{tid} remplacée par #{nt.id}{R}: {new_instr[:50]}")
        else:
            nt = spawn_task(new_instr)
            print(f"  {GR}⚡ Nouvelle tâche #{nt.id} lancée{R}: {new_instr[:50]}")
        return "edit_task", messages

    # /todo [add|done|del|clear|<texte>]
    if lowered.startswith("/todo"):
        parts = text.strip().split(None, 2)
        subcmd = parts[1].lower() if len(parts) > 1 else ""
        if not subcmd or subcmd == "list":
            _print_todos()
        elif subcmd == "add":
            if len(parts) < 3:
                print(f"  {GY}Usage: /todo add <texte>{R}")
            else:
                todos = _load_todos()
                nid = max((item.get("id", 0) for item in todos), default=0) + 1
                todos.append({"id": nid, "text": parts[2], "done": False})
                _save_todos(todos)
                print(f"  {GR}✓ Todo #{nid} ajouté.{R}")
        elif subcmd == "done":
            if len(parts) < 3:
                print(f"  {GY}Usage: /todo done <id>{R}")
            else:
                try:
                    tid = int(parts[2])
                    todos = _load_todos()
                    found = False
                    for item in todos:
                        if item.get("id") == tid:
                            item["done"] = True
                            found = True
                            break
                    if found:
                        _save_todos(todos)
                        print(f"  {GR}✓ Todo #{tid} marqué fait.{R}")
                    else:
                        print(f"  {RE}✗ Todo #{tid} introuvable.{R}")
                except ValueError:
                    print(f"  {RE}Usage: /todo done <id>{R}")
        elif subcmd == "del":
            if len(parts) < 3:
                print(f"  {GY}Usage: /todo del <id>{R}")
            else:
                try:
                    tid = int(parts[2])
                    todos = _load_todos()
                    new_todos = [item for item in todos if item.get("id") != tid]
                    if len(new_todos) == len(todos):
                        print(f"  {RE}✗ Todo #{tid} introuvable.{R}")
                    else:
                        _save_todos(new_todos)
                        print(f"  {GR}✓ Todo #{tid} supprimé.{R}")
                except ValueError:
                    print(f"  {RE}Usage: /todo del <id>{R}")
        elif subcmd == "clear":
            todos = _load_todos()
            new_todos = [item for item in todos if not item.get("done", False)]
            removed = len(todos) - len(new_todos)
            _save_todos(new_todos)
            print(f"  {GR}✓ {removed} todo(s) terminé(s) supprimé(s).{R}")
        else:
            print(f"  {GY}Usage: /todo [add|done|del|clear]{R}")
        return "todo", messages

    # /resolve — resolve git conflicts
    if lowered == "/resolve":
        conflicts = _check_git_conflicts()
        if not conflicts:
            print(f"  {GR}✓ Aucun conflit git.{R}")
        else:
            _resolve_git_conflicts()
        return "resolve", messages

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

    provider_tag = f"/{provider}" if provider != "ollama" else ""
    tag    = f"{MA}{B}dog{R}"
    mdl    = f"{GY}{model[0]}{provider_tag}{R}"
    sep    = f"{RULE_FG}·{R}"
    parts  = [tag, sep, mdl]
    if proj:
        parts += [sep, f"{W}{proj}{R}"]
    if branch:
        parts += [sep, f"{CY}{branch}{R}"]
    if agent_mode:
        parts += [sep, f"{GR}agent{R}"]
    title_str = " ".join(parts)
    title_vis = " ".join([
        "dog", "·", f"{model[0]}{provider_tag}",
        *(["·", proj] if proj else []),
        *(["·", branch] if branch else []),
        *(["·", "agent"] if agent_mode else []),
    ])
    pad = max(0, COLS - len(title_vis) - 5)
    print(f"{RULE_FG}╭─ {R}{title_str} {RULE_FG}{'─' * pad}╮{R}")

    cmds_str = (
        f"  {GY}/clear  /docs  /resume  /tasks  /task  /stop  /todo  /resolve  /help  /bye"
        f"  ·  Ctrl+C annuler/resume  ·  Ctrl+D quitter{R}  "
    )
    cmds_vis = "  /clear  /docs  /resume  /tasks  /task  /stop  /todo  /resolve  /help  /bye  ·  Ctrl+C annuler/resume  ·  Ctrl+D quitter  "
    pad2 = max(0, COLS - len(cmds_vis) - 2)
    print(f"{RULE_FG}│{R}{cmds_str}{' ' * pad2}{RULE_FG}│{R}")
    print(f"{RULE_FG}╰{'─' * (COLS - 2)}╯{R}")


def _print_user_turn(text):
    label     = f"{B}{BL} Vous {R}"
    label_vis = " Vous "
    bar_w     = max(0, COLS - len(label_vis) - 2)
    print(f"\n{label} {RULE_FG}{'─' * bar_w}{R}")
    print(text)


# ── chat_once (mode -p) ───────────────────────────────────────────────────────
def chat_once(user_text):
    intent = _classify_intent(user_text)
    if intent == "git" and _is_git_resolve(user_text):
        _resolve_git_conflicts()
        return
    action = _resolve_action(intent, user_text)
    if action:
        _run_good_action(action, user_text)
        return

    user_text = _enrich_action_context(user_text, intent)
    enriched = _enrich_user_message(user_text, intent)
    messages = [
        {"role": "system", "content": system_str},
    ]
    cancel = threading.Event()
    if agent_mode:
        final, updated, _ = run_agent_generation(enriched, messages, cancel)
        if final:
            _print_agent_response(final)
    else:
        messages.append({"role": "user", "content": enriched})
        stream_response(messages, cancel)


# ── chat_interactive ──────────────────────────────────────────────────────────
_NEW_SLASH_ACTIONS = ("task", "stop", "edit_task", "todo", "resolve", "resume")


def chat_interactive():
    saved_history, pending_cmd = _load_session()
    messages = [{"role": "system", "content": system_str}] + saved_history
    pending  = []

    if pending_cmd:
        short = pending_cmd[:55] + ("…" if len(pending_cmd) > 55 else "")
        print(
            f"\n{YE}⏸ Commande interrompue : « {short} » — "
            f"{CY}/resume{R}{YE} pour relancer{R}"
        )

    # Conflits git au démarrage → résolution auto
    conflicts = _check_git_conflicts()
    if conflicts:
        n = len(conflicts)
        print(f"\n{YE}⚠ {n} conflit(s) git{R}: {', '.join(conflicts[:3])}{'…' if n > 3 else ''}")
        _resolve_git_conflicts()

    while True:
        if forced_input[0]:
            user_text = forced_input[0]
            forced_input[0] = None
        elif pending:
            user_text = pending.pop(0)
            if pending:
                _stderr_line(f"  {GY}⏳ {len(pending)} message(s) en file{R}")
        else:
            try:
                user_text = read_user_line().strip()
            except KeyboardInterrupt:
                now = time.time()
                if now - _last_sigint[0] < 1.5:
                    _save_session(_history_messages(messages))
                    print(f"\n{GY}Au revoir.{R}")
                    break
                _last_sigint[0] = now
                _, pend = _load_session()
                if pend:
                    _print_cancel_hint(pend)
                else:
                    print(
                        f"\n{GY}⏹ Ctrl+C encore pour quitter · Ctrl+D quitter{R}",
                        file=sys.stderr,
                    )
                continue
            except EOFError:
                _save_session(_history_messages(messages))
                print()
                break
            if not user_text:
                continue

        slash_action, messages = handle_slash(user_text, messages)
        if slash_action == "quit":
            break
        if slash_action in ("clear", "help", "model", "info", "copy", "docs", "provider") + _NEW_SLASH_ACTIONS:
            continue

        _print_user_turn(user_text)

        intent = _classify_intent(user_text)
        if intent == "git" and _is_git_resolve(user_text):
            result = _resolve_git_conflicts()
            messages.append({"role": "user", "content": user_text})
            messages.append({"role": "assistant", "content": result})
            _save_session(_history_messages(messages), pending_command=None)
            print()
            continue

        action = _resolve_action(intent, user_text)

        if action:
            # Mode multitask : les modifications de fichiers sont lancées en background
            if multitask and action == "edit":
                t = spawn_task(user_text)
                print(f"\n{CY}⚡ Tâche #{t.id} lancée en arrière-plan.{R}")
                messages.append({"role": "user", "content": user_text})
                messages.append({"role": "assistant", "content": f"[Tâche #{t.id} lancée: {user_text}]"})
                _save_session(_history_messages(messages), pending_command=None)
                print()
                continue
            action_result = _run_good_action(action, user_text)
            messages.append({"role": "user", "content": user_text})
            messages.append({"role": "assistant", "content": action_result})
            _save_session(_history_messages(messages), pending_command=None)
            print()
            continue

        user_text = _enrich_action_context(user_text, intent)
        enriched  = _enrich_user_message(user_text, intent)
        cancel    = threading.Event()
        queued    = []

        if agent_mode:
            final, updated, queued = run_agent_generation(enriched, messages, cancel)
            if cancel.is_set():
                _save_session(_history_messages(messages), pending_command=user_text)
                _print_cancel_hint(user_text)
            elif final and updated:
                _print_agent_response(final)
                messages = [{"role": "system", "content": system_str}] + updated
                _save_session(updated, pending_command=None)
                task_list = _extract_task_list(final)
                if task_list:
                    n = len(task_list)
                    sys.stdout.write(f"\n{CY}⚡ {n} tâche(s) détectée(s) — lancer en parallèle? [Y/n] {R}")
                    sys.stdout.flush()
                    try:
                        ans = tty_in.readline().strip().lower() if tty_in else "n"
                    except Exception:
                        ans = "n"
                    if ans not in ("n", "non"):
                        for instr in task_list:
                            t = spawn_task(instr)
                            print(f"  {GR}⚡ Tâche #{t.id}{R}: {instr[:55]}")
        else:
            messages.append({"role": "user", "content": enriched})
            assistant, err, queued = run_generation(messages, cancel)

            if err == "http":
                messages.pop()
            elif assistant:
                messages.append({"role": "assistant", "content": assistant})
                _save_session(_history_messages(messages), pending_command=None)
                task_list = _extract_task_list(assistant)
                if task_list:
                    n = len(task_list)
                    sys.stdout.write(f"\n{CY}⚡ {n} tâche(s) détectée(s) — lancer en parallèle? [Y/n] {R}")
                    sys.stdout.flush()
                    try:
                        ans = tty_in.readline().strip().lower() if tty_in else "n"
                    except Exception:
                        ans = "n"
                    if ans not in ("n", "non"):
                        for instr in task_list:
                            t = spawn_task(instr)
                            print(f"  {GR}⚡ Tâche #{t.id}{R}: {instr[:55]}")
            elif cancel.is_set():
                _save_session(_history_messages(messages), pending_command=user_text)
                _print_cancel_hint(user_text)
                messages.pop()

        for q_line in queued:
            slash_action, messages = handle_slash(q_line, messages)
            if slash_action == "quit":
                return
            if slash_action == "clear":
                pending.clear()
                continue
            if slash_action in ("help", "model", "info", "copy", "docs", "provider") + _NEW_SLASH_ACTIONS:
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
    try:
        _print_header()
        chat_interactive()
    except KeyboardInterrupt:
        print(f"\n{GY}Au revoir.{R}")
        raise SystemExit(0)
    print(f"\n{GY}Au revoir.{R}")
PY
}

cmd_dog() {
    local print_mode=0 prompt="" verbose=0 web_search=0 multitask=0 agent_mode=0
    local provider api_key model host

    provider="$(_good_ai_provider)"
    model="$(_good_ai_model "$provider")"

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
            --provider|-P)
                shift
                provider="${1:-}"
                model="$(_good_ai_model "$provider")"
                ;;
            --deepseek)
                provider="deepseek"
                model="${DEEPSEEK_MODEL:-deepseek-chat}"
                ;;
            --ollama)
                provider="ollama"
                model="${GOOD_OLLAMA_MODEL:-qwen3:8b}"
                ;;
            --web)
                web_search=1
                ;;
            --multitask|-M)
                multitask=1
                ;;
            --agent|-A)
                agent_mode=1
                ;;
            -v|--verbose)
                verbose=1
                ;;
            -h|--help|help)
                echo "Usage: good dog [-p \"question\"] [--model modèle] [--provider ollama|deepseek] [--web] [--multitask] [--agent] [--verbose]"
                echo ""
                echo "Assistant interactif style Claude Code avec orchestrateur de tâches."
                echo ""
                echo "Providers :"
                echo "  --ollama               Ollama local (défaut sans DEEPSEEK_API_KEY)"
                echo "  --deepseek             DeepSeek API (ou DEEPSEEK_API_KEY=sk-...)"
                echo "  --provider <nom>       Choisir explicitement le provider"
                echo ""
                echo "  good dog                      Session interactive multi-tours"
                echo "  good dog -p \"…\"               Réponse unique streamée"
                echo "  echo \"…\" | good dog -p        Question via stdin"
                echo "  good dog --model deepseek-reasoner  Surcharger le modèle"
                echo "  good dog --web                Active la recherche web"
                echo "  good dog --multitask          Mode multitask (éditions en background)"
                echo "  good dog --agent              Mode agent ReAct (activé par défaut, GOOD_DOG_AGENT=0 pour off)"
                echo "  good dog --verbose            Affiche durée + tokens"
                echo ""
                echo "Variables d'environnement :"
                echo "  DEEPSEEK_API_KEY       Active DeepSeek automatiquement"
                echo "  DEEPSEEK_MODEL         Modèle DeepSeek (défaut: deepseek-chat)"
                echo "  DEEPSEEK_BASE_URL      URL base (défaut: https://api.deepseek.com)"
                echo "  GOOD_OLLAMA_MODEL      Modèle Ollama (défaut: qwen3:8b)"
                echo "  GOOD_AI_PROVIDER       Provider forcé (ollama|deepseek)"
                echo "  GOOD_WEB_SEARCH=1      Recherche web activée"
                echo "  GOOD_DOG_MULTITASK=1   Mode multitask activé"
                echo "  GOOD_DOG_AGENT=0     Désactiver le mode agent (défaut : activé)"
                echo "  GOOD_YES=0           Demander confirmation avant actions (défaut : 1)"
                echo ""
                echo "Modèle actuel  : $model"
                echo "Provider actuel: $provider"
                exit 0
                ;;
            *)
                echo "Option inconnue: $1" >&2
                echo "Usage: good dog [-p \"question\"] [--model modèle] [--provider ollama|deepseek]" >&2
                exit 1
                ;;
        esac
        shift
    done

    if [ "${GOOD_WEB_SEARCH:-0}" = "1" ]; then
        web_search=1
    fi
    if [ "${GOOD_DOG_MULTITASK:-0}" = "1" ]; then
        multitask=1
    fi
    if [ "${GOOD_DOG_AGENT:-0}" = "1" ]; then
        agent_mode=1
    fi
    if [ "${GOOD_DOG_AGENT:-}" != "0" ] && [ "$agent_mode" -eq 0 ]; then
        agent_mode=1
    fi

    export GOOD_YES="${GOOD_YES:-1}"

    # Vérification provider
    case "$provider" in
        deepseek|openai)
            local key_var
            [ "$provider" = "deepseek" ] && key_var="${DEEPSEEK_API_KEY:-}" || key_var="${OPENAI_API_KEY:-}"
            if [ -z "$key_var" ]; then
                local env_name
                [ "$provider" = "deepseek" ] && env_name="DEEPSEEK_API_KEY" || env_name="OPENAI_API_KEY"
                echo "Erreur: ${env_name} non définie." >&2
                echo "  export ${env_name}=sk-..." >&2
                exit 1
            fi
            api_key="$key_var"
            host=""
            ;;
        *)
            provider="ollama"
            _ai_check_ollama
            api_key=""
            host="$(_dog_ollama_host)"
            ;;
    esac

    local system root config
    if [ ! -t 0 ]; then
        if [ "$print_mode" -eq 0 ]; then
            print_mode=1
        fi
        if [ -z "$prompt" ]; then
            prompt="$(cat)"
        fi
    fi

    system="$(_dog_system_prompt)"
    root="$(_good_root)"
    config="$(_good_config_file)"

    if [ "$print_mode" -eq 1 ]; then
        if [ -z "$prompt" ]; then
            echo "Usage: good dog -p \"question\"  (ou pipe stdin)" >&2
            exit 1
        fi
        _dog_chat "$host" "$model" "$system" print "$verbose" "$prompt" "$GOOD_LIB" "$web_search" "$root" "$config" "$provider" "$api_key" "$multitask" "$agent_mode"
        return
    fi

    _dog_chat "$host" "$model" "$system" interactive "$verbose" "" "$GOOD_LIB" "$web_search" "$root" "$config" "$provider" "$api_key" "$multitask" "$agent_mode"
}
