#!/usr/bin/env python3
"""Query the generated FPS project index without rescanning the repository."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
INDEX_PATH = ROOT / "docs" / "knowledge" / "generated" / "index.json"


def compact(value: Any, limit: int = 500) -> str:
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return text if len(text) <= limit else text[: limit - 3] + "..."


def searchable_rows(data: dict[str, Any], kind: str) -> list[tuple[str, dict[str, Any]]]:
    groups = {
        "cpp": data.get("cpp_files", []),
        "lua": data.get("lua_files", []),
        "asset": data.get("core_assets", []),
        "map": data.get("maps", []),
        "plugin": data.get("plugins", []),
        "config": data.get("config_facts", []),
        "todo": data.get("todos", []),
        "ref": data.get("hardcoded_asset_references", []),
        "module": data.get("build_modules", []),
    }
    if kind == "all":
        return [(name, row) for name, rows in groups.items() for row in rows]
    return [(kind, row) for row in groups[kind]]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--kind",
        choices=("all", "cpp", "lua", "asset", "map", "plugin", "config", "todo", "ref", "module"),
        default="all",
    )
    parser.add_argument("terms", nargs="+", help="Case-insensitive terms; all must match.")
    parser.add_argument("--limit", type=int, default=40)
    args = parser.parse_args()

    if not INDEX_PATH.exists():
        print("Index missing. Run: python Tools/ProjectIndex/build_index.py", file=sys.stderr)
        return 2

    data = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
    needles = [term.casefold() for term in args.terms]
    matches = []
    for kind, row in searchable_rows(data, args.kind):
        haystack = compact(row, limit=100000).casefold()
        if all(needle in haystack for needle in needles):
            matches.append((kind, row))

    for kind, row in matches[: args.limit]:
        path = row.get("path") or row.get("asset_path") or row.get("friendly_name") or "entry"
        print(f"[{kind}] {path}")
        print(f"  {compact(row)}")

    print(f"Matches: {len(matches)} (shown {min(len(matches), args.limit)})")
    return 0 if matches else 1


if __name__ == "__main__":
    sys.exit(main())
