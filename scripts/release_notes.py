#!/usr/bin/env python3
"""Extract unreleased changelog sections for a GitHub release."""

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
    versions = [section_version for section_version, _ in parsed]
    if version not in versions:
        raise ValueError(f"CHANGELOG.md missing entry for {version}")
    start = versions.index(version)
    end = start + 1
    if since:
        if since not in versions:
            raise ValueError(f"CHANGELOG.md missing lower bound {since}")
        since_index = versions.index(since)
        if since_index == start:
            end = start + 1
        elif since_index < start:
            raise ValueError(f"Lower bound {since} must follow {version}")
        else:
            end = since_index
    selected = [section for _, section in parsed[start:end]]
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
