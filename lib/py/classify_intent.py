#!/usr/bin/env python3
"""Classify natural-language instructions into action intents."""
import re
import sys
import unicodedata

SHELL_ACTION_PATTERNS = [
    r"\b(arrete|stop|kill|down|eteint)\b.*\b(docker|container|conteneur|serveur|server|vite|ollama)\b",
    r"\b(docker)\b.*\b(stop|down|start|up|restart|ps|logs|compose)\b",
    r"\b(lance|demarre|start|ouvre|boot)\b.*\b(serveur|server|docker|ollama|vite|conteneur|container)\b",
    r"\b(docker\s+compose)\b",
    r"\b(composer|npm|pnpm|yarn)\s+(dev|start|serve)\b",
    r"\b(systemctl|service)\b.*\b(start|stop|restart|status)\b",
    r"\b(pkill|killall)\b",
]


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFD", text)
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return text.lower()


def is_shell_action(instruction: str) -> bool:
    text = normalize(instruction)
    return any(re.search(p, text) for p in SHELL_ACTION_PATTERNS)


def classify(instruction: str) -> str:
    text = normalize(instruction)

    if is_shell_action(text):
        return "shell"

    git_patterns = [
        r"\bcommit\b", r"\bcommitte\b", r"\bcommiter\b", r"\bcommite\b",
        r"\bpousse\b", r"\bpousser\b", r"\bpush\b",
        r"\bsync\b", r"\bsynchronis",
        r"\benvoi.*github\b", r"\benvoyer.*github\b", r"\bsur github\b",
        r"\bresous\b", r"\bresolve\b", r"\bconflit\b", r"\bconflits\b",
        r"\brebase\b", r"\bfetch\b",
    ]
    if any(re.search(p, text) for p in git_patterns):
        return "git"

    deploy_patterns = [
        r"\bdeploie\b", r"\bdeploy\b", r"\bdeploiement\b", r"\bdeployment\b",
        r"\bmise en prod\b", r"\bmettre en (prod|production|ligne)\b",
        r"\bpublier en prod\b", r"\bpush.*prod\b",
        r"\bclever\b", r"\bclever cloud\b",
        r"\b(deploie|deploy).*\b(prod|production|clever)\b",
    ]
    search_patterns = [
        r"\bcherche\b", r"\brecherche\b", r"\bsearch\b", r"\bgoogle\b",
        r"\btrouve\b.*\b(sur le web|internet|en ligne)\b",
        r"\b(sur le web|sur internet|en ligne)\b",
        r"\b(actualite|news|documentation officielle)\b.*\b(web|internet)\b",
    ]
    diagnose_patterns = [
        r"refus", r"refused", r"connexion", r"connection", r"inaccessible",
        r"ne repond", r"ne marche", r"marche pas", r"erreur", r"error",
        r"\bport\b", r"\bdown\b", r"502", r"503", r"504",
        r"timeout", r"timed out", r"echec", r"échec", r"diagnostic", r"diagnostique",
    ]
    start_patterns = [
        r"\blance\b", r"\blancer\b", r"\bdemarre\b", r"\bdemarrer\b",
        r"\bstart\b", r"\brun\b", r"\bouvre\b", r"\bboot\b", r"\bserve\b",
        r"\blance le projet\b", r"\bdemarre le projet\b",
        r"\blance le serveur\b", r"\bdemarre le serveur\b",
    ]

    deploy_score = sum(1 for p in deploy_patterns if re.search(p, text))
    search_score = sum(1 for p in search_patterns if re.search(p, text))
    diagnose_score = sum(1 for p in diagnose_patterns if re.search(p, text))
    start_score = sum(1 for p in start_patterns if re.search(p, text))

    # Priority: shell handled above > diagnose (connexion) > deploy > start > search > edit
    if diagnose_score > 0 and re.search(r"refus|refused|connexion|connection", text):
        return "diagnose"
    if deploy_score > 0:
        return "deploy"
    if diagnose_score > start_score and diagnose_score > 0:
        return "diagnose"
    if start_score > diagnose_score and start_score > 0:
        return "start"
    if diagnose_score > 0:
        return "diagnose"
    if start_score > 0:
        return "start"
    if search_score > 0:
        return "search"
    return "edit"


def is_file_action(instruction: str) -> bool:
    """True when the user asks to create/modify/delete project files."""
    text = normalize(instruction)

    if is_shell_action(text):
        return False

    # Questions / explanations — not file edits
    if re.search(
        r"\b(explique|expliquez|decrit|decris|comment|pourquoi|qu'est.ce|c'est quoi|"
        r"what|how|why|describe|show me|montre|affiche|lis|lire|read)\b",
        text,
    ):
        if not re.search(
            r"\b(creer|create|ajoute|modifie|corrige|fix|supprime|delete|ecris|write|"
            r"implemente|remplace|update)\b",
            text,
        ):
            return False

    if re.search(r"\b(creer|create)\s+(un\s+)?fichier\b", text):
        return True

    verbs = (
        r"\b(creer|create|ajoute|ajouter|add|modifie|modifier|modify|change|changer|"
        r"corrige|corriger|fix|supprime|supprimer|delete|ecris|ecrire|write|mets|mettre|"
        r"update|remplace|remplacer|implemente|implementer|implement)\b"
    )
    targets = (
        r"\b(fichier|file|"
        r"\.(?:php|ts|tsx|js|jsx|vue|py|sh|md|json|ya?ml|env|txt|css|html|sql)|"
        r"route|component|composant|fonction|function|classe|class|module|endpoint|"
        r"migration|controller|middleware|service|store|model|test|spec)\b"
    )
    return bool(re.search(verbs, text) and re.search(targets, text))


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--action":
        print("yes" if is_file_action(sys.argv[2]) else "no")
    else:
        print(classify(sys.argv[1] if len(sys.argv) > 1 else ""))
