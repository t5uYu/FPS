#!/usr/bin/env python3
"""Build a compact, searchable knowledge index for the FPS Unreal project."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
KNOWLEDGE_DIR = ROOT / "docs" / "knowledge"
GENERATED_DIR = KNOWLEDGE_DIR / "generated"
JSON_OUTPUT = GENERATED_DIR / "index.json"
MARKDOWN_OUTPUT = GENERATED_DIR / "SYMBOL_INDEX.md"

TEXT_EXTENSIONS = {
    ".h", ".hpp", ".cpp", ".c", ".cs", ".lua", ".py", ".ps1", ".bat",
    ".json", ".ini", ".csv", ".txt", ".uproject", ".uplugin",
}

SCAN_ROOTS = (
    ROOT / "Source" / "FPS",
    ROOT / "Content" / "Script",
    ROOT / "Config",
    ROOT / "Tools" / "DataTableConverter",
    ROOT / "Plugins" / "GamePlay" / "Source",
    ROOT / "Plugins" / "Web" / "Source",
    ROOT / "Plugins" / "UEEditorMCP" / "Source",
    ROOT / "Plugins" / "UEEditorMCP" / "Python" / "ue_editor_mcp",
)

EXPLICIT_TEXT_FILES = (
    ROOT / "FPS.uproject",
    ROOT / "SourceData" / "Items.csv",
    ROOT / "Output" / "CSV" / "DT_ItemDefinition.csv",
    ROOT / "Content" / "Data" / "WeaponBallistics.json",
    ROOT / "Content" / "_UGC" / "Placeables" / "placeable_manifest.json",
)

CORE_ASSET_ROOTS = (
    ROOT / "Content" / "_FPS",
    ROOT / "Content" / "_UGC",
    ROOT / "Content" / "Data",
    ROOT / "Content" / "Script",
)

EXCLUDED_PARTS = {
    ".git", ".venv", "__pycache__", "Binaries", "Intermediate", "Saved",
    "DerivedDataCache", "generated",
}


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def read_text(path: Path) -> str:
    for encoding in ("utf-8-sig", "utf-8", "gb18030"):
        try:
            return path.read_text(encoding=encoding)
        except UnicodeDecodeError:
            continue
    return path.read_text(encoding="utf-8", errors="replace")


def iter_files(base: Path, extensions: set[str] | None = None) -> Iterable[Path]:
    if not base.exists():
        return
    if base.is_file():
        yield base
        return
    for path in base.rglob("*"):
        if not path.is_file():
            continue
        if any(part in EXCLUDED_PARTS for part in path.parts):
            continue
        if extensions is None or path.suffix.lower() in extensions:
            yield path


def source_files() -> list[Path]:
    paths: set[Path] = set()
    for base in SCAN_ROOTS:
        paths.update(iter_files(base, TEXT_EXTENSIONS))
    for path in EXPLICIT_TEXT_FILES:
        if path.exists():
            paths.add(path)
    for path in ROOT.glob("Plugins/**/*.uplugin"):
        paths.add(path)
    for path in ROOT.glob("Source/*.Target.cs"):
        paths.add(path)
    return sorted(paths)


def core_asset_files() -> list[Path]:
    paths: set[Path] = set()
    for base in CORE_ASSET_ROOTS:
        paths.update(iter_files(base))
    return sorted(paths)


def fingerprint(text_paths: Iterable[Path], asset_paths: Iterable[Path]) -> str:
    digest = hashlib.sha256()
    for path in text_paths:
        digest.update(rel(path).encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    for path in asset_paths:
        digest.update(rel(path).encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def line_count(text: str) -> int:
    return text.count("\n") + (1 if text else 0)


def git_head() -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, check=True,
            capture_output=True, text=True,
        )
        return result.stdout.strip()
    except Exception:
        return "unknown"


def load_json_tolerant(path: Path) -> dict[str, Any]:
    text = read_text(path)
    text = re.sub(r",\s*([}\]])", r"\1", text)
    return json.loads(text)


def parse_plugins() -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for path in sorted(ROOT.glob("Plugins/**/*.uplugin")):
        try:
            data = load_json_tolerant(path)
            result.append({
                "path": rel(path),
                "friendly_name": data.get("FriendlyName", path.stem),
                "version": data.get("VersionName"),
                "category": data.get("Category"),
                "enabled_by_default": data.get("EnabledByDefault"),
                "modules": [
                    {
                        "name": item.get("Name"),
                        "type": item.get("Type"),
                        "loading_phase": item.get("LoadingPhase"),
                    }
                    for item in data.get("Modules", [])
                ],
            })
        except Exception as exc:
            result.append({"path": rel(path), "parse_error": str(exc)})
    return result


def parse_build_dependencies() -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    candidates = list(ROOT.glob("Source/**/*.Build.cs"))
    candidates += list((ROOT / "Plugins" / "GamePlay").glob("Source/**/*.Build.cs"))
    candidates += list((ROOT / "Plugins" / "Web").glob("Source/**/*.Build.cs"))
    candidates += list((ROOT / "Plugins" / "UEEditorMCP").glob("Source/**/*.Build.cs"))
    for path in sorted(set(candidates)):
        text = read_text(path)
        deps: list[str] = []
        for match in re.finditer(
            r"(?:Public|Private)DependencyModuleNames\.AddRange\s*\(\s*new\s+string\[\]\s*\{(.*?)\}\s*\)",
            text, re.S,
        ):
            deps.extend(re.findall(r'"([^"]+)"', match.group(1)))
        result.append({"path": rel(path), "dependencies": sorted(set(deps))})
    return result


def parse_cpp() -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    roots = (ROOT / "Source" / "FPS", ROOT / "Plugins" / "GamePlay" / "Source")
    for base in roots:
        for path in iter_files(base, {".h", ".hpp", ".cpp", ".c", ".cs"}):
            text = read_text(path)
            types = []
            for kind, name, bases in re.findall(
                r"\b(class|struct)\s+(?:[A-Z0-9_]+_API\s+)?([A-Za-z_][A-Za-z0-9_]*)"
                r"(?:\s*:\s*public\s*([^{\n]+))?", text,
            ):
                types.append({"kind": kind, "name": name, "bases": bases.strip() if bases else ""})
            for name in re.findall(r"\benum\s+class\s+([A-Za-z_][A-Za-z0-9_]*)", text):
                types.append({"kind": "enum", "name": name, "bases": ""})

            methods: list[dict[str, Any]] = []
            if path.suffix.lower() in {".h", ".hpp"}:
                method_re = re.compile(
                    r"^\s*(?:virtual\s+|static\s+|FORCEINLINE\s+|explicit\s+)*"
                    r"[A-Za-z_][A-Za-z0-9_:<>,*&\s]*\s+"
                    r"([A-Za-z_~][A-Za-z0-9_]*)\s*\([^;{}]*\)"
                    r"\s*(?:const\s*)?(?:override\s*)?;", re.M,
                )
                for match in method_re.finditer(text):
                    methods.append({
                        "name": match.group(1),
                        "line": text.count("\n", 0, match.start()) + 1,
                    })

            result.append({
                "path": rel(path),
                "lines": line_count(text),
                "types": types,
                "methods": methods,
            })
    return sorted(result, key=lambda item: item["path"])


def parse_lua() -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for path in iter_files(ROOT / "Content" / "Script", {".lua"}):
        text = read_text(path)
        requires = sorted(set(re.findall(r'require\s*\(?\s*["\']([^"\']+)["\']', text)))
        functions = [
            {"name": match.group(1), "line": text.count("\n", 0, match.start()) + 1}
            for match in re.finditer(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_:.]*)\s*\(", text, re.M)
        ]
        result.append({
            "path": rel(path),
            "module": rel(path).removeprefix("Content/Script/").removesuffix(".lua").replace("/", "."),
            "lines": line_count(text),
            "requires": requires,
            "functions": functions,
        })
    return sorted(result, key=lambda item: item["path"])


def parse_assets() -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for path in core_asset_files():
        if path.suffix.lower() not in {".uasset", ".umap", ".json", ".lua"}:
            continue
        stem = path.stem
        if path.suffix.lower() == ".umap":
            kind = "map"
        elif stem.startswith(("BP_", "BA_")):
            kind = "blueprint"
        elif stem.startswith("WBP_"):
            kind = "widget"
        elif stem.startswith("DA_"):
            kind = "data_asset"
        elif stem.startswith("DT_"):
            kind = "data_table"
        elif stem.startswith("IA_"):
            kind = "input_action"
        elif stem.startswith("IMC_"):
            kind = "input_context"
        elif stem.startswith("GE_"):
            kind = "gameplay_effect"
        elif path.suffix.lower() == ".lua":
            kind = "lua"
        elif path.suffix.lower() == ".json":
            kind = "json"
        else:
            kind = "asset"
        result.append({"path": rel(path), "name": stem, "kind": kind, "bytes": path.stat().st_size})
    return sorted(result, key=lambda item: item["path"])


def asset_ref_exists(asset_path: str) -> tuple[bool, str]:
    clean = asset_path.rstrip("/")
    leaf = clean.rsplit("/", 1)[-1]
    if "." in leaf:
        clean = clean.rsplit(".", 1)[0]
    relative = clean.removeprefix("/Game/")
    direct = ROOT / "Content" / relative
    candidates = [direct.with_suffix(".uasset"), direct.with_suffix(".umap"), direct]
    for candidate in candidates:
        if candidate.is_file():
            return True, rel(candidate)
    return False, rel(direct.with_suffix(".uasset"))


def collect_references_and_todos(paths: list[Path]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    references: dict[str, list[str]] = {}
    todos: list[dict[str, Any]] = []
    asset_pattern = re.compile(r"/Game/[A-Za-z0-9_./]+")
    todo_pattern = re.compile(r"TODO|FIXME|HACK|XXX|待实现|未实现|临时方案", re.I)

    for path in paths:
        text = read_text(path)
        for line_no, line in enumerate(text.splitlines(), 1):
            for asset_path in asset_pattern.findall(line):
                references.setdefault(asset_path, []).append(f"{rel(path)}:{line_no}")
            if todo_pattern.search(line):
                todos.append({"path": rel(path), "line": line_no, "text": line.strip()[:300]})

    ref_rows = []
    for asset_path, locations in sorted(references.items()):
        exists, candidate = asset_ref_exists(asset_path)
        ref_rows.append({
            "asset_path": asset_path,
            "exists": exists,
            "candidate": candidate,
            "references": locations,
        })
    return ref_rows, todos


def parse_config_facts() -> list[dict[str, Any]]:
    patterns = re.compile(
        r"EditorStartupMap|GameDefaultMap|GlobalDefaultGameMode|"
        r"DefaultPlayerInputClass|DefaultInputComponentClass|"
        r"WwiseProjectPath|DirectoriesToAlwaysCook|DirectoriesToAlwaysStageAsUFS|"
        r"GameplayTagList|bEnableDebug|bEnableUnrealInsights|SecurityToken"
    )
    result = []
    for path in iter_files(ROOT / "Config", {".ini"}):
        for line_no, line in enumerate(read_text(path).splitlines(), 1):
            if patterns.search(line):
                result.append({"path": rel(path), "line": line_no, "text": line.strip()})
    return result


def repository_stats() -> dict[str, Any]:
    extension_counts: Counter[str] = Counter()
    top_level: dict[str, dict[str, float | int]] = {}
    for child in ROOT.iterdir():
        if child.name == ".git" or not child.is_dir():
            continue
        count = 0
        size = 0
        for path in child.rglob("*"):
            if not path.is_file() or ".git" in path.parts:
                continue
            count += 1
            size += path.stat().st_size
            extension_counts[path.suffix.lower() or "<none>"] += 1
        top_level[child.name] = {"files": count, "bytes": size}
    return {"top_level": top_level, "extension_counts": dict(extension_counts.most_common())}


def build_index() -> dict[str, Any]:
    files = source_files()
    assets_for_fingerprint = core_asset_files()
    try:
        project = load_json_tolerant(ROOT / "FPS.uproject")
    except Exception:
        project = {}
    references, todos = collect_references_and_todos(files)
    cpp = parse_cpp()
    lua = parse_lua()
    assets = parse_assets()
    maps = [{"path": rel(path), "bytes": path.stat().st_size} for path in sorted((ROOT / "Content").rglob("*.umap"))]
    return {
        "schema_version": 1,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "git_head": git_head(),
        "source_fingerprint": fingerprint(files, assets_for_fingerprint),
        "project": {
            "name": "FPS",
            "engine_association": project.get("EngineAssociation"),
            "modules": project.get("Modules", []),
            "enabled_plugins": project.get("Plugins", []),
        },
        "scope": {
            "indexed_text_roots": [rel(path) for path in SCAN_ROOTS if path.exists()],
            "core_asset_roots": [rel(path) for path in CORE_ASSET_ROOTS if path.exists()],
            "excluded_by_default": sorted(EXCLUDED_PARTS),
        },
        "stats": repository_stats(),
        "build_modules": parse_build_dependencies(),
        "plugins": parse_plugins(),
        "cpp_files": cpp,
        "lua_files": lua,
        "core_assets": assets,
        "maps": maps,
        "hardcoded_asset_references": references,
        "config_facts": parse_config_facts(),
        "todos": todos,
    }


def render_markdown(data: dict[str, Any]) -> str:
    lines = [
        "# Generated Symbol and Asset Index", "",
        "> Generated by `Tools/ProjectIndex/build_index.py`. Do not edit manually.",
        f"> Git HEAD: `{data['git_head']}`",
        f"> Source fingerprint: `{data['source_fingerprint']}`", "",
        "## C++ files", "",
    ]
    for item in data["cpp_files"]:
        type_names = ", ".join(t["name"] for t in item["types"]) or "-"
        method_names = ", ".join(m["name"] for m in item["methods"]) or "-"
        lines.extend([
            f"### `{item['path']}`",
            f"- Lines: {item['lines']}",
            f"- Types: {type_names}",
            f"- Declared methods: {method_names}", "",
        ])

    lines.extend(["## Lua modules", ""])
    for item in data["lua_files"]:
        reqs = ", ".join(item["requires"]) or "-"
        funcs = ", ".join(f["name"] for f in item["functions"]) or "-"
        lines.extend([
            f"### `{item['module']}`",
            f"- File: `{item['path']}`",
            f"- Lines: {item['lines']}",
            f"- Requires: {reqs}",
            f"- Functions: {funcs}", "",
        ])

    lines.extend(["## Core assets", ""])
    for kind in sorted({item["kind"] for item in data["core_assets"]}):
        items = [item for item in data["core_assets"] if item["kind"] == kind]
        lines.append(f"### {kind} ({len(items)})")
        lines.extend(f"- `{item['path']}`" for item in items)
        lines.append("")

    lines.extend(["## Hardcoded `/Game` references", ""])
    for item in data["hardcoded_asset_references"]:
        marker = "OK" if item["exists"] else "MISSING"
        lines.append(
            f"- **{marker}** `{item['asset_path']}` -> `{item['candidate']}` "
            f"({', '.join(item['references'])})"
        )

    lines.extend(["", "## TODO/FIXME markers", ""])
    for item in data["todos"]:
        lines.append(f"- `{item['path']}:{item['line']}` - {item['text']}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Exit non-zero when the existing index is missing or stale.")
    args = parser.parse_args()
    data = build_index()

    if args.check:
        if not JSON_OUTPUT.exists():
            print(f"STALE: missing {rel(JSON_OUTPUT)}")
            return 1
        existing = json.loads(read_text(JSON_OUTPUT))
        if existing.get("source_fingerprint") != data["source_fingerprint"]:
            print("STALE: project sources/config/assets changed; rebuild the index.")
            return 1
        print(f"OK: index matches {data['source_fingerprint'][:12]}")
        return 0

    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    JSON_OUTPUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    MARKDOWN_OUTPUT.write_text(render_markdown(data), encoding="utf-8")
    print(f"Wrote {rel(JSON_OUTPUT)}")
    print(f"Wrote {rel(MARKDOWN_OUTPUT)}")
    print(f"Fingerprint {data['source_fingerprint']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
