#!/usr/bin/env python3
"""Build a small, reproducible Reading DNA install archive."""

from __future__ import annotations

import argparse
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ("micromodules/reading_dna.lua", "README.md", "CHANGELOG.md", "LICENSE")


def read_version() -> str:
    source = (ROOT / "micromodules/reading_dna.lua").read_text(encoding="utf-8")
    match = re.search(r'^local MODULE_VERSION = "([0-9]+\.[0-9]+\.[0-9]+)"$', source, re.M)
    if not match:
        raise SystemExit("Could not read MODULE_VERSION from installable module")
    return match.group(1)


def build(output_dir: Path, tag: str | None = None) -> Path:
    version = read_version()
    if tag and tag != f"v{version}":
        raise SystemExit(f"Tag {tag} does not match module version v{version}")
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    if not re.search(rf"^## {re.escape(version)}(?:\s|—|-)", changelog, re.M):
        raise SystemExit(f"CHANGELOG.md missing entry for {version}")

    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"reading-dna-v{version}.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for name in FILES:
            path = ROOT / name
            if not path.is_file():
                raise SystemExit(f"Required release file missing: {name}")
            archive_name = "reading_dna.lua" if name == "micromodules/reading_dna.lua" else name
            bundle.write(path, archive_name)
    return archive


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--tag", help="Optional Git tag; must match the module version")
    args = parser.parse_args()
    print(build(args.output.resolve(), args.tag))


if __name__ == "__main__":
    main()
