#!/usr/bin/env python3
"""Context window management for good dog conversations."""
import sys
from typing import Callable, Optional


class ContextManager:
    """
    Gère la fenêtre de contexte d'une session good dog.

    Stratégies :
    - SLIDING_WINDOW : garde les N derniers messages
    - SUMMARIZE      : résume les vieux messages via LLM
    - PRUNE_TOOLS    : supprime les tool_results intermédiaires après usage
    """

    # Limites par modèle (en tokens estimés)
    CONTEXT_LIMITS: dict = {
        "deepseek-chat": 60_000,
        "deepseek-reasoner": 60_000,
        "gpt-4o": 120_000,
        "gpt-4o-mini": 100_000,
        "gpt-4": 100_000,
        "qwen3:8b": 28_000,
        "qwen3:14b": 40_000,
        "qwen3:32b": 60_000,
        "llama3.2": 20_000,
        "llama3.1": 20_000,
        "llama3": 20_000,
        "mistral": 24_000,
        "gemma2": 20_000,
        "phi3": 16_000,
        "default": 20_000,
    }

    # Seuil de déclenchement : 80% de la limite
    TRIGGER_RATIO = 0.80

    def __init__(self, model: str, provider: str, strategy: str = "auto"):
        self.model = model
        self.provider = provider
        # "auto" | "sliding_window" | "summarize" | "prune_tools"
        self.strategy = strategy
        self._limit = self._get_limit()
        self._summary_cache: str = ""

    def set_model(self, model: str) -> None:
        """Met à jour le modèle et recalcule la limite de contexte."""
        self.model = model
        self._limit = self._get_limit()

    # ── Limit resolution ───────────────────────────────────────────────────────

    def _get_limit(self) -> int:
        """Résout la limite de tokens pour le modèle courant."""
        # Correspondance exacte d'abord
        if self.model in self.CONTEXT_LIMITS:
            return self.CONTEXT_LIMITS[self.model]
        # Correspondance par préfixe (ex: "qwen3:8b-instruct" → "qwen3:8b")
        for key, limit in self.CONTEXT_LIMITS.items():
            if key != "default" and self.model.startswith(key):
                return limit
        # Heuristique par provider
        if self.provider in ("deepseek",):
            return 60_000
        if self.provider in ("openai",):
            return 100_000
        return self.CONTEXT_LIMITS["default"]

    # ── Token estimation ───────────────────────────────────────────────────────

    def estimate_tokens(self, messages: list) -> int:
        """Estimation rapide : ~4 chars par token (approximation GPT).

        Gère les contenus texte simples et les formats tool-call OpenAI.
        """
        total = 0
        for m in messages:
            content = m.get("content") or ""
            if isinstance(content, list):
                # Format OpenAI avec tool_calls ou blocs multimodaux
                content = " ".join(
                    part.get("text", "") if isinstance(part, dict) else str(part)
                    for part in content
                )
            total += len(str(content)) // 4 + 10  # +10 overhead par message
            # Compter aussi les tool_calls dans la réponse assistant
            for tc in m.get("tool_calls") or []:
                func = tc.get("function") or {}
                total += len(str(func.get("arguments", ""))) // 4 + 5
        return total

    def is_near_limit(self, messages: list) -> bool:
        """Vrai si le contexte dépasse TRIGGER_RATIO de la limite."""
        return self.estimate_tokens(messages) > self._limit * self.TRIGGER_RATIO

    def usage_ratio(self, messages: list) -> float:
        """Ratio d'utilisation du contexte (0.0 – 1.0+)."""
        return self.estimate_tokens(messages) / self._limit

    # ── Strategies ─────────────────────────────────────────────────────────────

    def prune_tool_results(self, messages: list) -> list:
        """
        Remplace les tool_results longs par des résumés courts.
        Garde toujours les 3 derniers tool_results intacts.
        """
        tool_indices = [
            i for i, m in enumerate(messages)
            if m.get("role") == "tool"
            or (m.get("role") == "assistant" and m.get("tool_calls"))
        ]

        # Conserver les 3 dernières paires (6 entrées : call + result × 3)
        to_prune = set(tool_indices[:-6]) if len(tool_indices) > 6 else set()

        result = []
        for i, m in enumerate(messages):
            if i in to_prune and m.get("role") == "tool":
                content = m.get("content", "")
                if isinstance(content, str) and len(content) > 200:
                    m = {**m, "content": content[:200] + "\n… [tronqué — déjà traité]"}
            result.append(m)
        return result

    def apply_sliding_window(self, messages: list, keep_last: int = 20) -> list:
        """
        Garde le(s) message(s) système + les keep_last derniers échanges.
        Injecte un message de contexte si des messages ont été supprimés.
        """
        system_msgs = [m for m in messages if m.get("role") == "system"]
        non_system = [m for m in messages if m.get("role") != "system"]

        if len(non_system) <= keep_last:
            return messages

        dropped = len(non_system) - keep_last
        kept = non_system[-keep_last:]

        context_note: dict = {
            "role": "system",
            "content": (
                f"[Note : {dropped} message(s) précédent(s) non affiché(s) "
                "— contexte de session tronqué]"
            ),
        }

        return system_msgs + [context_note] + kept

    def summarize_history(
        self,
        messages: list,
        llm_caller: Callable,
        keep_recent: int = 6,
    ) -> list:
        """
        Résume les vieux messages via LLM, garde les keep_recent derniers.
        Le résumé est injecté comme message système.

        llm_caller : callable(messages: list) -> str
        """
        system_msgs = [m for m in messages if m.get("role") == "system"]
        non_system = [m for m in messages if m.get("role") != "system"]

        if len(non_system) <= keep_recent:
            return messages

        to_summarize = non_system[:-keep_recent]
        recent = non_system[-keep_recent:]

        history_text = "\n".join(
            f"{m['role'].upper()}: {str(m.get('content', ''))[:500]}"
            for m in to_summarize
        )

        summary_prompt = [
            {
                "role": "system",
                "content": "Tu es un assistant. Résume cette conversation de façon concise.",
            },
            {
                "role": "user",
                "content": (
                    "Résume en 3-5 phrases les points clés, "
                    "décisions et fichiers modifiés :\n\n" + history_text
                ),
            },
        ]

        try:
            summary = llm_caller(summary_prompt)
        except Exception as exc:
            # Si le LLM échoue, repli sur sliding window
            summary = f"[Résumé indisponible : {exc}]"

        self._summary_cache = summary

        summary_msg: dict = {
            "role": "system",
            "content": f"[Résumé des échanges précédents]\n{summary}",
        }

        return system_msgs + [summary_msg] + recent

    # ── Main entry point ───────────────────────────────────────────────────────

    def trim(self, messages: list, llm_caller: Optional[Callable] = None) -> list:
        """
        Applique la stratégie appropriée pour réduire le contexte.
        Appelé automatiquement quand is_near_limit() est True.

        Retourne la liste (éventuellement tronquée) prête à envoyer au LLM.
        """
        if not self.is_near_limit(messages):
            return messages

        strategy = self.strategy
        if strategy == "auto":
            ratio = self.usage_ratio(messages)
            if ratio > 0.95:
                # Urgence : sliding window immédiat
                strategy = "sliding_window"
            elif llm_caller and ratio > 0.85:
                strategy = "summarize"
            else:
                strategy = "prune_tools"

        if strategy == "sliding_window":
            return self.apply_sliding_window(messages)
        if strategy == "summarize" and llm_caller:
            return self.summarize_history(messages, llm_caller)
        # Repli : prune_tools (safe, sans LLM requis)
        return self.prune_tool_results(messages)

    # ── Display helpers ────────────────────────────────────────────────────────

    def status_line(self, messages: list) -> str:
        """Retourne une ligne d'état colorée pour l'affichage dans good dog.

        Exemple :  ctx 4,230/20,000 tokens ████░░░░░░
        """
        tokens = self.estimate_tokens(messages)
        ratio = tokens / self._limit

        if ratio < 0.5:
            color = "\033[32m"   # vert
        elif ratio < 0.8:
            color = "\033[33m"   # jaune
        else:
            color = "\033[31m"   # rouge

        reset = "\033[0m"
        bar_filled = min(10, int(ratio * 10))
        bar = "█" * bar_filled + "░" * (10 - bar_filled)
        return f"{color}ctx {tokens:,}/{self._limit:,} tokens {bar}{reset}"

    def summary(self, messages: list) -> dict:
        """Retourne un dictionnaire de métriques pour debug/logging."""
        tokens = self.estimate_tokens(messages)
        turns = len([m for m in messages if m["role"] != "system"])
        return {
            "model": self.model,
            "provider": self.provider,
            "strategy": self.strategy,
            "tokens_estimated": tokens,
            "limit": self._limit,
            "ratio": round(tokens / self._limit, 3),
            "near_limit": self.is_near_limit(messages),
            "turns": turns,
            "total_messages": len(messages),
            "summary_cache": bool(self._summary_cache),
        }


if __name__ == "__main__":
    import json

    # ── Demo ──────────────────────────────────────────────────────────────────
    print("=== ContextManager — démonstration ===\n")

    # Créer un gestionnaire pour qwen3:8b (limite 28k tokens)
    cm = ContextManager(model="qwen3:8b", provider="ollama", strategy="auto")

    # Simuler une conversation de 30 échanges
    messages: list = [{"role": "system", "content": "Tu es dog, un assistant CLI senior."}]
    for i in range(30):
        messages.append({"role": "user", "content": f"Question {i+1} : comment faire X en Python ?"})
        messages.append({
            "role": "assistant",
            "content": (
                f"Réponse {i+1} : " + "voici comment faire X. " * 20
            ),
        })

    print(f"Avant trim : {cm.status_line(messages)}")
    print(f"Métriques  : {json.dumps(cm.summary(messages), ensure_ascii=False)}\n")

    trimmed = cm.trim(messages)
    print(f"Après trim (sliding_window) : {cm.status_line(trimmed)}")
    print(f"Messages conservés : {len(trimmed)} / {len(messages)}\n")

    # Test prune_tools avec des tool calls simulés
    tool_messages: list = [
        {"role": "system", "content": "Système."},
        {"role": "user", "content": "Lis le fichier README.md"},
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [{"id": "t1", "function": {"name": "read_file", "arguments": '{"path":"README.md"}'}}],
        },
        {"role": "tool", "tool_call_id": "t1", "content": "# README\n" + "Contenu long. " * 100},
        {"role": "assistant", "content": "Voici le résumé du README."},
        {"role": "user", "content": "Maintenant lis GOOD.md"},
        {
            "role": "assistant",
            "content": "",
            "tool_calls": [{"id": "t2", "function": {"name": "read_file", "arguments": '{"path":"GOOD.md"}'}}],
        },
        {"role": "tool", "tool_call_id": "t2", "content": "# GOOD\n" + "Autre contenu. " * 50},
        {"role": "assistant", "content": "Voici le résumé de GOOD.md."},
    ]

    cm2 = ContextManager(model="llama3.2", provider="ollama", strategy="prune_tools")
    pruned = cm2.prune_tool_results(tool_messages)
    print(f"Test prune_tools : {len(tool_messages)} → {len(pruned)} messages (structure préservée)")

    # Test status_line sur différents niveaux
    print("\nStatus lines selon ratio :")
    for model_name, test_msgs in [
        ("qwen3:8b", [{"role": "user", "content": "x" * 1000}] * 3),   # ~faible
        ("llama3.2", [{"role": "user", "content": "x" * 2000}] * 10),  # ~moyen
        ("phi3",     [{"role": "user", "content": "x" * 3000}] * 15),  # ~élevé
    ]:
        cmt = ContextManager(model=model_name, provider="ollama")
        print(f"  {model_name:15s} {cmt.status_line(test_msgs)}")

    print("\nUsage : from context_manager import ContextManager")
    print("        cm = ContextManager(model, provider)")
    print("        messages = cm.trim(messages, llm_caller=None)")
    print("        print(cm.status_line(messages))")
