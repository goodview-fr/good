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
    local root branch git_status
    root="$(_good_root)"
    branch=""
    git_status=""
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
        branch="$(git -C "$root" branch --show-current 2>/dev/null || echo "?")"
        git_status="$(git -C "$root" status -s 2>/dev/null | head -20 || true)"
    fi
    cat <<EOF
Tu es dog, un assistant de développement en ligne de commande (style Claude Code), intégré au CLI good.
Tu aides sur le projet courant : code, debug, git, architecture, bonnes pratiques.
Réponds en français sauf si l'utilisateur écrit en anglais. Sois concis et actionnable.
Pour appliquer des modifications de fichiers automatiquement, suggère « good ai <instruction> ».
Pour committer : « good c ». Pour pousser : « good p ».

Projet : $root
Branche git : ${branch:-—}
$(if [ -n "$git_status" ]; then printf 'Git status :\n%s\n' "$git_status"; fi)
EOF
}

_dog_chat() {
    exec 3<&0
    python3 - "$@" 0<&3 3<<'PY'
import json
import os
import select
import sys
import termios
import threading
import tty
import urllib.error
import urllib.request

host, model, system, mode, verbose, prompt = sys.argv[1:7]
verbose = verbose == "1"
base = host if host.startswith("http") else f"http://{host}"
PROMPT = "❯ "
GEN_HINT = (
    "  Entrée : mettre en file · Ctrl+C ou Échap : annuler la génération"
)

# Heredoc bash sur fd 3 : stdin Python = terminal (fd 0). Secours : /dev/tty.
tty_in = None
if mode != "print" and not sys.stdin.isatty():
    try:
        tty_in = open("/dev/tty", "r", encoding="utf-8", errors="replace")
    except OSError:
        print(
            "Erreur: session interactive impossible (pas de terminal).",
            file=sys.stderr,
        )
        print('Utilisez: good dog -p "question"', file=sys.stderr)
        raise SystemExit(1)


def read_user_line():
    if tty_in is not None:
        sys.stdout.write(PROMPT)
        sys.stdout.flush()
        line = tty_in.readline()
        if not line:
            raise EOFError
        return line.rstrip("\n\r")
    return input(PROMPT)


class StreamFilter:
    """Filtre les blocs « Thinking… / …done thinking. » (modèles type qwen3)."""

    def __init__(self):
        self._skip = False
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
                self._pending = self._pending[end + 1 :]
                if "...done thinking." in line:
                    self._skip = False
                continue
            start = self._pending.find("\n")
            if start == -1:
                if self._pending.startswith("Thinking..."):
                    self._skip = True
                    self._pending = ""
                elif "Thinking..." not in self._pending:
                    out.append(self._pending)
                    self._pending = ""
                break
            line = self._pending[: start + 1]
            self._pending = self._pending[start + 1 :]
            if line.startswith("Thinking..."):
                self._skip = True
                continue
            out.append(line)
        return "".join(out)

    def flush(self):
        if self._skip or not self._pending:
            self._pending = ""
            return ""
        if self._pending.startswith("Thinking..."):
            self._pending = ""
            return ""
        text = self._pending
        self._pending = ""
        return text


def api_chat(messages):
    payload = json.dumps({"model": model, "messages": messages, "stream": True}).encode()
    req = urllib.request.Request(
        f"{base}/api/chat",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        return urllib.request.urlopen(req, timeout=600)
    except urllib.error.URLError as exc:
        print(f"Erreur: impossible de joindre Ollama ({base}). Lance 'ollama serve'.", file=sys.stderr)
        print(f"Détail: {exc.reason}", file=sys.stderr)
        raise SystemExit(1)


def stream_response(messages, cancel_event=None):
    total_duration = None
    assistant_parts = []
    filt = StreamFilter()
    cancelled = False
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
                chunk = json.loads(line)
                msg = chunk.get("message") or {}
                content = msg.get("content") or ""
                if content:
                    visible = filt.feed(content)
                    if visible:
                        print(visible, end="", flush=True)
                        assistant_parts.append(visible)
                if chunk.get("done"):
                    total_duration = chunk.get("total_duration")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        print(f"\nErreur Ollama ({exc.code}): {body}", file=sys.stderr)
        raise
    tail = filt.flush()
    if tail:
        print(tail, end="", flush=True)
        assistant_parts.append(tail)
    if not cancelled:
        print()
    if verbose and total_duration is not None and not cancelled:
        print(f"[{total_duration / 1e9:.1f}s]", file=sys.stderr)
    if cancelled:
        print("\n⏹ Génération annulée.", file=sys.stderr)
        return None
    return "".join(assistant_parts) if assistant_parts else ""


def _stderr_line(text):
    sys.stderr.write(f"\r\033[K{text}\n")
    sys.stderr.flush()


def _draw_queue_input(buf):
    sys.stderr.write(f"\r\033[K{PROMPT}{''.join(buf)}")
    sys.stderr.flush()


def read_while_generating(cancel_event, gen_thread):
    """Lit des messages pendant la génération (file d'attente sur stderr)."""
    if tty_in is not None:
        fd = tty_in.fileno()
    elif sys.stdin.isatty():
        fd = sys.stdin.fileno()
    else:
        return []
    old = termios.tcgetattr(fd)
    queued = []
    buf = []
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
                buf = []
                if line:
                    queued.append(line)
                    _stderr_line(f"⏳ {len(queued)} message(s) en file")
                _draw_queue_input(buf)
            elif ch == "\x03":  # Ctrl+C
                cancel_event.set()
                break
            elif ch == "\x1b":  # Échap seul (pas flèches)
                if select.select([fd], [], [], 0.05)[0]:
                    seq = os.read(fd, 8).decode("utf-8", errors="replace")
                    if seq.startswith("["):  # séquence flèche / navigation
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
    if mode != "print" and (tty_in is not None or sys.stdin.isatty()):
        print(GEN_HINT, file=sys.stderr)
        queued = read_while_generating(cancel_event, thread)

    thread.join()
    return result["text"], result["error"], queued


def handle_slash(text, messages):
    lowered = text.lower()
    if lowered in ("/bye", "/exit", "/quit", "/q"):
        return "quit", messages
    if lowered in ("/clear", "/reset"):
        print("Historique effacé.")
        return "clear", [{"role": "system", "content": system}]
    if lowered in ("/help", "/?"):
        print("Commandes : /clear, /bye — Ctrl+D pour quitter.")
        print("Pendant une réponse : Entrée met en file, Ctrl+C ou Échap annule.")
        return "help", messages
    return None, messages


def chat_once(user_text):
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user_text},
    ]
    cancel = threading.Event()
    stream_response(messages, cancel)


def chat_interactive():
    messages = [{"role": "system", "content": system}]
    pending = []

    while True:
        if pending:
            user_text = pending.pop(0)
            if len(pending):
                _stderr_line(f"⏳ {len(pending)} message(s) en file")
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
        if action in ("clear", "help"):
            continue

        messages.append({"role": "user", "content": user_text})
        cancel = threading.Event()
        assistant, err, queued = run_generation(messages, cancel)

        if err == "http":
            messages.pop()
        elif assistant:
            messages.append({"role": "assistant", "content": assistant})
        elif cancel.is_set():
            messages.pop()

        for line in queued:
            action, messages = handle_slash(line, messages)
            if action == "quit":
                return
            if action == "clear":
                pending.clear()
                continue
            if action == "help":
                continue
            pending.append(line)

        print()


if mode == "print":
    prompt = prompt.strip()
    if not prompt:
        print("Usage: good dog -p \"question\"  (ou pipe stdin)", file=sys.stderr)
        raise SystemExit(1)
    chat_once(prompt)
else:
    chat_interactive()
PY
    local rc=$?
    exec 3<&-
    return "$rc"
}

cmd_dog() {
    local print_mode=0 prompt="" model="" verbose=0
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
            -v|--verbose)
                verbose=1
                ;;
            -h|--help|help)
                echo "Usage: good dog [-p \"question\"] [--model modèle] [--verbose]"
                echo ""
                echo "Assistant interactif style Claude Code, propulsé par Ollama (défaut : qwen3:8b)."
                echo "Utilise l'API chat Ollama (compatible 0.24+) — pas de flag --system sur ollama run."
                echo ""
                echo "  good dog                      Session interactive multi-tours"
                echo "  good dog -p \"…\"               Réponse unique (comme claude -p)"
                echo "  echo \"…\" | good dog -p        Question via stdin"
                echo "  echo \"…\" | good dog           Mode print auto si stdin non-TTY"
                echo "  good dog --model qwen3:8b     Surcharge le modèle pour cette session"
                echo "  good dog --verbose            Affiche la durée de réponse"
                echo ""
                echo "Session interactive : réponses streamées, file d'attente pendant la génération."
                echo "  /clear, /bye · Ctrl+D quitter · Ctrl+C ou Échap annuler · Entrée en file"
                echo "Alias : la commande « dog » appelle good dog (si installée via install-good.sh)."
                echo "Modèle par défaut : $(_good_ollama_model) — GOOD_OLLAMA_MODEL ou good settings ollama [mod]"
                exit 0
                ;;
            *)
                echo "Option inconnue: $1" >&2
                echo "Usage: good dog [-p \"question\"] [--model modèle]" >&2
                exit 1
                ;;
        esac
        shift
    done

    _ai_check_ollama

    local system host mode
    # Lire stdin avant _dog_chat : le heredoc Python remplace stdin et empêche la lecture du pipe.
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

    if [ "$print_mode" -eq 1 ]; then
        if [ -z "$prompt" ]; then
            echo "Usage: good dog -p \"question\"  (ou pipe stdin)" >&2
            exit 1
        fi
        _dog_chat "$host" "$model" "$system" print "$verbose" "$prompt"
        return
    fi

    echo "dog — assistant dev (Ollama/$model)"
    echo "Projet : $(_good_root)"
    echo "Session interactive — réponses streamées · /bye ou Ctrl+D · /clear · file d'attente (Entrée pendant génération)"
    _print_sep
    _dog_chat "$host" "$model" "$system" interactive "$verbose" ""
}
