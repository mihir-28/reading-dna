#!/usr/bin/env python3
"""Extract release notes from the matching CHANGELOG.md section."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADING = re.compile(r"^##\s+(\d+\.\d+\.\d+)(?:\s+[—-].*)?\s*$")


def sections(text: str) -> list[tuple[str, str]]:
    lines = text.splitlines()
    starts = [
        (index, match.group(1))
        for index, line in enumerate(lines)
        if (match := HEADING.match(line))
    ]
    result = []
    for position, (start, version) in enumerate(starts):
        end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        result.append((version, "\n".join(lines[start:end]).strip()))
    return result


def extract(text: str, version: str, since: str | None = None) -> str:
    parsed = sections(text)
    selected = []
    found_version = False
    for section_version, section in parsed:
        if not found_version:
            if section_version == version:
                found_version = True
            else:
                continue
        if since and section_version == since:
            break
        selected.append(section)
    if not found_version:
        raise ValueError(f"CHANGELOG.md missing entry for {version}")
    if since and not any(section_version == since for section_version, _ in parsed):
        raise ValueError(f"CHANGELOG.md missing lower bound {since}")
    if since and (not selected or selected[-1].startswith(f"## {since}")):
        raise ValueError(f"No changelog sections found after {since}")
    return "\n\n".join(selected)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--since", help="Exclude this version and older sections")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    notes = extract(changelog, args.version, args.since)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(notes + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
