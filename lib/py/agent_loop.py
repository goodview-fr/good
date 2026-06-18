#!/usr/bin/env python3
"""Agentic loop engine for good dog — ReAct pattern with tool-use."""

import json
import os
import re
import sys
import threading
import urllib.error
import urllib.request

# Local import — tools.py must be in the same directory
_here = os.path.dirname(os.path.abspath(__file__))
if _here not in sys.path:
    sys.path.insert(0, _here)

from tools import (
    OPENAI_TOOLS,
    OLLAMA_TOOL_SYSTEM,
    TOOLS_NEEDS_CONFIRM,
    ToolEngine,
    format_tool_args,
    git_needs_confirm,
    normalize_tool_args,
    shell_needs_confirm,
)


class AgentLoop:
    MAX_STEPS = 15
    MAX_TOOL_OUTPUT = 8_000

    def __init__(
        self,
        model: str,
        provider: str,
        api_key: str,
        base_url: str,
        tool_engine: ToolEngine,
        system_prompt: str,
        verbose: bool = False,
        cancel_event: threading.Event = None,
        on_tool_call=None,
        on_tool_result=None,
        on_content=None,
        confirm_tool=None,
    ):
        self.model = model
        self.provider = provider
        self.api_key = api_key
        self.base_url = base_url
        self.tool_engine = tool_engine
        self.system_prompt = system_prompt
        self.verbose = verbose
        self.cancel_event = cancel_event or threading.Event()
        self.on_tool_call = on_tool_call
        self.on_tool_result = on_tool_result
        self.on_content = on_content
        self.confirm_tool = confirm_tool

    # ── Public entry point ─────────────────────────────────────────────────────

    def run(self, user_message: str, history: list) -> tuple:
        """
        Lance la boucle agentique ReAct.
        Retourne (final_response: str, updated_history: list[dict]).
        """
        is_ollama = self.provider == "ollama"

        # Construire le system prompt (avec injection tools pour Ollama)
        if is_ollama:
            effective_system = self.system_prompt + "\n\n" + OLLAMA_TOOL_SYSTEM
        else:
            effective_system = self.system_prompt

        messages = [{"role": "system", "content": effective_system}]
        messages.extend(history)
        messages.append({"role": "user", "content": user_message})

        for step in range(self.MAX_STEPS):
            if self.cancel_event.is_set():
                return "[Annulé]", self._strip_system(messages, history)

            # Appel LLM
            try:
                if is_ollama:
                    response = self._call_ollama(messages)
                else:
                    response = self._call_openai(messages)
            except Exception as exc:
                return f"[Erreur API: {exc}]", self._strip_system(messages, history)

            # Extraire les tool calls
            tool_calls = self._extract_tool_calls(response, is_ollama)

            if not tool_calls:
                # Réponse finale
                final = self._get_final_content(response, is_ollama)
                if self.on_content and final:
                    self.on_content(final)
                updated = list(history) + [
                    {"role": "user", "content": user_message},
                    {"role": "assistant", "content": final},
                ]
                return final, updated

            # Ajouter la réponse de l'assistant (avec tool_calls) dans l'historique
            if is_ollama:
                assistant_content = response.get("message", {}).get("content", "")
                messages.append({"role": "assistant", "content": assistant_content})
            else:
                assistant_msg = self._build_assistant_message_openai(response)
                messages.append(assistant_msg)

            # Exécuter les outils
            tool_results = []
            for tc in tool_calls:
                if self.cancel_event.is_set():
                    break

                name = tc.get("name", "")
                args = normalize_tool_args(name, tc.get("args") or tc.get("arguments") or {})

                if self.on_tool_call:
                    self.on_tool_call(name, args)

                needs_confirm = name in TOOLS_NEEDS_CONFIRM
                if name in ("run_shell", "run_command"):
                    cmd = (args or {}).get("command", "")
                    needs_confirm = shell_needs_confirm(cmd)
                elif name == "run_git":
                    needs_confirm = git_needs_confirm((args or {}).get("args") or [])
                if needs_confirm and self.confirm_tool:
                    if not self.confirm_tool(name, args):
                        result = "[Annulé par l'utilisateur]"
                    else:
                        result = self.tool_engine.execute(name, args)
                else:
                    result = self.tool_engine.execute(name, args)

                # Tronquer les résultats longs
                if len(result) > self.MAX_TOOL_OUTPUT:
                    result = result[: self.MAX_TOOL_OUTPUT] + "\n... [tronqué]"

                if self.on_tool_result:
                    self.on_tool_result(name, result)

                tool_results.append((tc, result))

            # Injecter les résultats dans les messages
            if is_ollama:
                for tc, result in tool_results:
                    messages = self._append_tool_result_ollama(messages, tc, result)
            else:
                for tc, result in tool_results:
                    messages = self._append_tool_result_openai(messages, tc, result)

        return "[Max steps atteint — boucle agentique interrompue]", history

    # ── LLM calls ─────────────────────────────────────────────────────────────

    def _call_openai(self, messages: list) -> dict:
        """Appel non-streaming pour les étapes avec tool-use (DeepSeek/OpenAI)."""
        if self.provider == "deepseek":
            api_base = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
        else:
            api_base = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com")

        payload = json.dumps({
            "model": self.model,
            "messages": messages,
            "tools": OPENAI_TOOLS,
            "tool_choice": "auto",
            "stream": False,
        }).encode()

        req = urllib.request.Request(
            f"{api_base}/v1/chat/completions",
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self.api_key}",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            try:
                err = json.loads(body).get("error", {}).get("message", body)
            except Exception:
                err = body
            raise RuntimeError(f"HTTP {exc.code}: {err}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Connexion échouée: {exc.reason}") from exc

    def _call_ollama(self, messages: list) -> dict:
        """Appel non-streaming Ollama (JSON)."""
        if not self.base_url:
            raise RuntimeError("base_url Ollama non défini")
        base = self.base_url if self.base_url.startswith("http") else f"http://{self.base_url}"

        payload = json.dumps({
            "model": self.model,
            "messages": messages,
            "stream": False,
        }).encode()

        req = urllib.request.Request(
            f"{base}/api/chat",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Ollama inaccessible ({base}): {exc.reason}") from exc

    # ── Tool call extraction ───────────────────────────────────────────────────

    def _extract_tool_calls(self, response: dict, is_ollama: bool) -> list:
        """Extrait les tool calls depuis la réponse LLM."""
        if is_ollama:
            return self._parse_ollama_tool_calls(response)
        return self._parse_openai_tool_calls(response)

    def _parse_openai_tool_calls(self, response: dict) -> list:
        """Format natif OpenAI tool_calls."""
        tool_calls = []
        choices = response.get("choices") or []
        if not choices:
            return []
        message = choices[0].get("message") or {}
        raw_tcs = message.get("tool_calls") or []
        for tc in raw_tcs:
            fn = tc.get("function") or {}
            name = fn.get("name", "")
            raw_args = fn.get("arguments", "{}")
            try:
                args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
            except json.JSONDecodeError:
                args = {}
            tool_calls.append({
                "id": tc.get("id", ""),
                "name": name,
                "args": args,
            })
        return tool_calls

    def _parse_ollama_tool_calls(self, response: dict) -> list:
        """Parse les <tool_call>{...}</tool_call> dans le contenu Ollama."""
        content = response.get("message", {}).get("content", "") or ""
        tool_calls = []
        for m in re.finditer(r"<tool_call>(.*?)</tool_call>", content, re.DOTALL):
            raw = m.group(1).strip()
            try:
                tc = json.loads(raw)
                if "name" in tc:
                    tool_calls.append({
                        "id": f"ollama_{len(tool_calls)}",
                        "name": tc["name"],
                        "args": tc.get("args") or tc.get("arguments") or {},
                        "_raw_match": m.group(0),
                    })
            except json.JSONDecodeError:
                pass
        return tool_calls

    # ── Message building ───────────────────────────────────────────────────────

    def _build_assistant_message_openai(self, response: dict) -> dict:
        """Reconstruit le message assistant avec tool_calls pour OpenAI."""
        choices = response.get("choices") or []
        if not choices:
            return {"role": "assistant", "content": ""}
        message = choices[0].get("message") or {}
        # Retourner tel quel (inclut tool_calls natifs)
        return {
            "role": "assistant",
            "content": message.get("content"),
            "tool_calls": message.get("tool_calls") or [],
        }

    def _append_tool_result_openai(self, messages: list, tc: dict, result: str) -> list:
        """Ajoute un tool_result au format OpenAI."""
        messages.append({
            "role": "tool",
            "tool_call_id": tc.get("id", ""),
            "content": result,
        })
        return messages

    def _append_tool_result_ollama(self, messages: list, tc: dict, result: str) -> list:
        """Ajoute un tool_result au format Ollama (injection dans user message)."""
        messages.append({
            "role": "user",
            "content": f"<tool_result>{result}</tool_result>",
        })
        return messages

    # ── Final content extraction ───────────────────────────────────────────────

    def _get_final_content(self, response: dict, is_ollama: bool) -> str:
        """Extrait le contenu textuel final de la réponse."""
        if is_ollama:
            content = response.get("message", {}).get("content", "") or ""
            # Retirer les éventuels blocs tool_call résiduels
            content = re.sub(r"<tool_call>.*?</tool_call>", "", content, flags=re.DOTALL)
            return content.strip()
        choices = response.get("choices") or []
        if not choices:
            return ""
        message = choices[0].get("message") or {}
        return (message.get("content") or "").strip()

    # ── Utilities ──────────────────────────────────────────────────────────────

    def _strip_system(self, messages: list, original_history: list) -> list:
        """Retourne l'historique mis à jour sans le message system."""
        return [m for m in messages if m.get("role") != "system"]


# ── Streaming final response (helper utilisable depuis dog.sh) ─────────────────

def stream_agent_response(
    model: str,
    provider: str,
    api_key: str,
    base_url: str,
    system_prompt: str,
    messages: list,
) -> str:
    """
    Streaming d'une réponse finale sans tool-use.
    Retourne le contenu complet streamé.
    Utilisable indépendamment de AgentLoop pour les réponses simples.
    """
    is_ollama = provider == "ollama"

    if is_ollama:
        if not base_url:
            return "[Erreur: base_url Ollama non défini]"
        base = base_url if base_url.startswith("http") else f"http://{base_url}"
        payload = json.dumps({
            "model": model,
            "messages": messages,
            "stream": True,
        }).encode()
        req = urllib.request.Request(
            f"{base}/api/chat",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
    else:
        api_base = os.environ.get(
            "DEEPSEEK_BASE_URL" if provider == "deepseek" else "OPENAI_BASE_URL",
            "https://api.deepseek.com" if provider == "deepseek" else "https://api.openai.com",
        )
        payload = json.dumps({
            "model": model,
            "messages": messages,
            "stream": True,
        }).encode()
        req = urllib.request.Request(
            f"{api_base}/v1/chat/completions",
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}",
            },
            method="POST",
        )

    parts = []
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            for raw in resp:
                line = raw.decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                if is_ollama:
                    try:
                        chunk = json.loads(line)
                        content = chunk.get("message", {}).get("content", "")
                        if content:
                            parts.append(content)
                    except json.JSONDecodeError:
                        pass
                else:
                    if not line.startswith("data: "):
                        continue
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                        choices = chunk.get("choices") or []
                        if choices:
                            delta = choices[0].get("delta") or {}
                            content = delta.get("content") or ""
                            if content:
                                parts.append(content)
                    except json.JSONDecodeError:
                        pass
    except Exception as exc:
        return f"[Erreur streaming: {exc}]"

    return "".join(parts)


# ── Self-test ──────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import os

    root = os.getcwd()
    engine = ToolEngine(root)

    def _on_tool_call(name, args):
        print(f"\n  ⚡ {name}({format_tool_args(args)})")

    def _on_tool_result(name, result):
        preview = result[:200].replace("\n", " ")
        print(f"  → {preview}…" if len(result) > 200 else f"  → {result}")

    def _on_content(text):
        print(text, end="", flush=True)

    # Test sans LLM réel — vérification des outils directement
    print("=== Test ToolEngine ===")
    print(engine.execute("list_directory", {"path": ".", "depth": 1}))
    print()
    print(engine.execute("run_git", {"args": ["status"]}))
    print()
    print(engine.execute("run_git", {"args": ["push", "--force"]}))  # doit être refusé
    print()
    print(engine.execute("run_shell", {"command": "pwd"}))
    print()
    print(engine.execute("run_shell", {"command": "rm -rf /"}))  # doit être refusé
