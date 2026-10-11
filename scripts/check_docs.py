#!/usr/bin/env python3
"""Fail when repository Markdown contains broken or machine-local links."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)")


def repository_markdown_files() -> list[Path]:
    """Return tracked and new untracked *.md files, never git-ignored scratch notes."""
    try:
        listing = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md"],
            capture_output=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Could not list repository Markdown files with git: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    paths = (ROOT / name for name in listing.stdout.decode("utf-8").split("\0") if name)
    # A tracked file deleted in the working tree has nothing left to lint.
    return sorted({path for path in paths if path.is_file()})


def main() -> int:
    failures: list[str] = []
    for document in repository_markdown_files():
        text = document.read_text(encoding="utf-8")
        for match in LINK.finditer(text):
            raw = match.group(1).strip().strip("<>")
            target = raw.split(maxsplit=1)[0]
            parsed = urlsplit(target)
            if parsed.scheme in {"http", "https", "mailto"} or target.startswith("#"):
                continue
            line = text.count("\n", 0, match.start()) + 1
            if target.startswith(("/", "~")):
                failures.append(f"{document.relative_to(ROOT)}:{line}: machine-local link {target}")
                continue
            path = (document.parent / unquote(parsed.path)).resolve()
            try:
                path.relative_to(ROOT)
            except ValueError:
                failures.append(f"{document.relative_to(ROOT)}:{line}: link escapes repository {target}")
                continue
            if not path.exists():
                failures.append(f"{document.relative_to(ROOT)}:{line}: missing target {target}")

    if failures:
        print("Documentation link check failed:", file=sys.stderr)
        print("\n".join(f"- {failure}" for failure in failures), file=sys.stderr)
        return 1
    print("Documentation links are repository-relative and resolve locally.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
