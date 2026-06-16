#!/usr/bin/env python3
"""Detect leftover git conflict markers in file content."""
import sys

MARKERS = ("<<<<<<<", "=======", ">>>>>>>")


def has_conflict_markers(content: str) -> bool:
    for line in content.splitlines():
        stripped = line.strip()
        for marker in MARKERS:
            if stripped.startswith(marker):
                return True
    return False


if __name__ == "__main__":
    content = sys.stdin.read() if len(sys.argv) == 1 else open(sys.argv[1]).read()
    sys.exit(1 if has_conflict_markers(content) else 0)
