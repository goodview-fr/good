#!/usr/bin/env python3
"""Classify natural-language instructions into start/diagnose/edit intents."""
import re
import sys
import unicodedata


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFD", text)
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    return text.lower()


def classify(instruction: str) -> str:
    text = normalize(instruction)

    diagnose_patterns = [
        r"refus", r"refused", r"connexion", r"connection", r"inaccessible",
        r"ne repond", r"ne marche", r"marche pas", r"erreur", r"error",
        r"\bport\b", r"\bdown\b", r"arrete", r"502", r"503", r"504",
        r"timeout", r"timed out", r"echec", r"échec", r"diagnostic", r"diagnostique",
    ]
    start_patterns = [
        r"\blance\b", r"\blancer\b", r"\bdemarre\b", r"\bdemarrer\b",
        r"\bstart\b", r"\brun\b", r"\bouvre\b", r"\bboot\b", r"\bserve\b",
        r"\blance le projet\b", r"\bdemarre le projet\b",
    ]

    diagnose_score = sum(1 for p in diagnose_patterns if re.search(p, text))
    start_score = sum(1 for p in start_patterns if re.search(p, text))

    if diagnose_score > 0 and re.search(r"refus|refused|connexion|connection", text):
        return "diagnose"
    if start_score > diagnose_score and start_score > 0:
        return "start"
    if diagnose_score > 0:
        return "diagnose"
    if start_score > 0:
        return "start"
    return "edit"


if __name__ == "__main__":
    print(classify(sys.argv[1] if len(sys.argv) > 1 else ""))
