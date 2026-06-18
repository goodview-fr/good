#!/usr/bin/env python3
"""Context helpers for good dog: Goodview metadata, docs, web search."""
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request


def _normalize(text: str) -> str:
    text = unicodedata.normalize("NFD", text)
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return text.lower()

DOCS_QUERY_PATTERNS = [
    r"\bexplique\b.*\b(projet|depot|repo|structure|architecture)\b",
    r"\bcomment\b.*\b(fonctionne|marche|structure|organise)\b",
    r"\b(documentation|doc|readme|good\.md)\b",
    r"\b(structure|architecture)\b.*\b(projet|depot|codebase)\b",
    r"\bwhat is this (project|repo)\b",
    r"\bhow does (this|the) (project|repo) work\b",
]

SAFE_CONFIG_KEYS = (
    "client_name",
    "name",
    "slug",
    "type",
    "type_label",
    "status",
    "status_label",
    "github_url",
    "dev_url",
    "dev_environment_name",
    "prod_url",
    "prod_environment_name",
)


def goodview_prompt_block(config_path: str) -> str:
    if not os.path.isfile(config_path):
        return ""
    try:
        with open(config_path, encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        return ""

    cache = cfg.get("project_cache") or {}
    if not cache:
        return ""

    lines = ["Contexte Goodview (liaison .good/config.json, sans secrets) :"]
    if cache.get("client_name"):
        lines.append(f"Client : {cache['client_name']}")
    if cache.get("name"):
        lines.append(f"Projet : {cache['name']}")
    if cache.get("type_label") or cache.get("type"):
        lines.append(f"Type : {cache.get('type_label') or cache.get('type')}")
    if cache.get("status_label") or cache.get("status"):
        lines.append(f"Statut : {cache.get('status_label') or cache.get('status')}")
    if cache.get("github_url"):
        lines.append(f"Dépôt : {cache['github_url']}")
    if cache.get("dev_url"):
        env = cache.get("dev_environment_name") or "dev"
        lines.append(f"URL dev : {cache['dev_url']} ({env})")
    if cache.get("prod_url"):
        env = cache.get("prod_environment_name") or "prod"
        lines.append(f"URL prod : {cache['prod_url']} ({env})")

    if len(lines) == 1:
        return ""
    return "\n".join(lines)


def is_docs_query(text: str) -> bool:
    norm = _normalize(text)
    return any(re.search(p, norm) for p in DOCS_QUERY_PATTERNS)


def _read_file_chunk(path: str, max_chars: int) -> str:
    if not os.path.isfile(path):
        return ""
    try:
        size = os.path.getsize(path)
        if size > 200_000:
            return f"[Fichier trop volumineux : {os.path.basename(path)}]"
        with open(path, encoding="utf-8", errors="replace") as f:
            content = f.read(max_chars)
        if len(content) >= max_chars:
            content += "\n… (tronqué)"
        return content
    except OSError:
        return ""


def docs_context(root: str, instruction: str = "", max_chars: int = 12_000) -> str:
    """Read README.md, GOOD.md and files mentioned in the instruction."""
    parts = []
    budget = max_chars
    default_files = ["README.md", "GOOD.md"]

    mentioned = set()
    for match in re.findall(
        r"(?:^|[\s'\"`])([\w./-]+\.(?:md|txt|rst))\b",
        instruction or "",
        re.I,
    ):
        mentioned.add(match.lstrip("./"))

    for rel in default_files + sorted(mentioned):
        if rel in default_files and rel in {m for m in mentioned}:
            continue
        path = os.path.normpath(os.path.join(root, rel))
        if not path.startswith(os.path.realpath(root) + os.sep) and path != os.path.realpath(root):
            continue
        chunk = _read_file_chunk(path, min(budget, 6000))
        if chunk:
            header = f"--- {rel} ---"
            block = f"{header}\n{chunk}"
            if len(block) > budget:
                block = block[:budget] + "\n… (tronqué)"
            parts.append(block)
            budget -= len(block)
            if budget <= 0:
                break

    if not parts:
        return ""
    return "Documentation du projet :\n" + "\n\n".join(parts)


def web_search(query: str, max_results: int = 5) -> str:
    """Lightweight DuckDuckGo lite HTML scrape — no API key."""
    q = urllib.parse.quote_plus(query.strip())
    url = f"https://lite.duckduckgo.com/lite/?q={q}"
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "good-cli-dog/1.0"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            html = resp.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return f"Recherche web échouée : {exc}"

    results = []
    # DDG lite: result links in <a class="result-link">, snippets in next rows
    link_re = re.compile(
        r'<a[^>]+class="[^"]*result-link[^"]*"[^>]+href="([^"]+)"[^>]*>([^<]+)</a>',
        re.I,
    )
    snippet_re = re.compile(
        r'<td[^>]+class="[^"]*result-snippet[^"]*"[^>]*>([^<]+)</td>',
        re.I,
    )
    links = link_re.findall(html)
    snippets = snippet_re.findall(html)

    for i, (href, title) in enumerate(links[:max_results]):
        snippet = snippets[i].strip() if i < len(snippets) else ""
        title = re.sub(r"\s+", " ", title).strip()
        snippet = re.sub(r"\s+", " ", snippet).strip()
        if href.startswith("//"):
            href = "https:" + href
        results.append(f"{i + 1}. {title}\n   {href}\n   {snippet}")

    if not results:
        return "Aucun résultat web trouvé."
    return "Résultats web (DuckDuckGo) :\n" + "\n\n".join(results)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "goodview":
        print(goodview_prompt_block(sys.argv[2]))
    elif cmd == "docs":
        print(docs_context(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""))
    elif cmd == "search":
        print(web_search(sys.argv[2]))
    elif cmd == "is-docs":
        print("yes" if is_docs_query(sys.argv[2]) else "no")
    else:
        print("Usage: dog_context.py goodview|docs|search|is-docs …", file=sys.stderr)
        sys.exit(1)
