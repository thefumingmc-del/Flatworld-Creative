#!/usr/bin/env python3
"""Lightweight source sanity checks when the Godot 4.7.2 executable is unavailable.

This is deliberately not a replacement for Godot's GDScript parser/type checker.
It verifies balanced delimiters outside comments/strings, top-level duplicate methods,
literal res:// paths, and critical registry-separation contracts.
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
SCENES = ROOT / "scenes"
failures: list[str] = []
checks: list[str] = []


def require(condition: bool, label: str, detail: str = "") -> None:
    if condition:
        checks.append(label)
    else:
        failures.append(label + (": " + detail if detail else ""))


def scan_delimiters(path: Path, source: str) -> None:
    pairs = {")": "(", "]": "[", "}": "{"}
    stack: list[tuple[str, int]] = []
    state = "code"
    quote = ""
    escaped = False
    line = 1
    i = 0
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if ch == "\n":
            line += 1
            if state == "comment":
                state = "code"
            if state == "string" and quote in ("\"\"\"", "'''" ):
                pass
            elif state == "string" and quote in ("\"", "'") and not escaped:
                # GDScript single/double quoted strings cannot span literal newlines.
                failures.append(f"{path.relative_to(ROOT)}:{line}: unterminated string")
                state = "code"
            escaped = False
            i += 1
            continue
        if state == "comment":
            i += 1
            continue
        if state == "string":
            if quote in ("\"\"\"", "'''" ):
                if source.startswith(quote, i):
                    state = "code"
                    i += len(quote)
                    continue
                i += 1
                continue
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                state = "code"
            i += 1
            continue
        if ch == "#":
            state = "comment"
            i += 1
            continue
        if source.startswith('"""', i) or source.startswith("'''", i):
            quote = source[i:i + 3]
            state = "string"
            i += 3
            continue
        if ch in ('"', "'"):
            quote = ch
            state = "string"
            escaped = False
            i += 1
            continue
        if ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}" :
            if not stack or stack[-1][0] != pairs[ch]:
                failures.append(f"{path.relative_to(ROOT)}:{line}: unexpected delimiter {ch}")
            else:
                stack.pop()
        i += 1
    if state == "string":
        failures.append(f"{path.relative_to(ROOT)}: unterminated string at EOF")
    if stack:
        failures.append(f"{path.relative_to(ROOT)}: unclosed delimiters {stack[-4:]}")


gd_files = sorted([p for p in SCRIPTS.rglob("*.gd") if p.is_file()] + [p for p in SCENES.rglob("*.gd") if p.is_file()])
for path in gd_files:
    text = path.read_text(encoding="utf-8")
    before = len(failures)
    scan_delimiters(path, text)
    if len(failures) == before:
        checks.append(f"balanced delimiters: {path.relative_to(ROOT)}")
    funcs: dict[tuple[int, str], int] = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        match = re.match(r"^( *)func\s+([A-Za-z_][A-Za-z_0-9]*)\s*\(", line)
        if not match:
            continue
        key = (len(match.group(1)), match.group(2))
        if key in funcs:
            failures.append(f"{path.relative_to(ROOT)}:{lineno}: duplicate method {key[1]} at same indentation as line {funcs[key]}")
        else:
            funcs[key] = lineno
    if not any(f.startswith(f"{path.relative_to(ROOT)}:") and "duplicate method" in f for f in failures):
        checks.append(f"no duplicate same-scope method declarations: {path.relative_to(ROOT)}")

# Literal resource paths in scripts/scenes must exist in the project tree.
resource_refs: list[tuple[str, str]] = []
for path in gd_files:
    text = path.read_text(encoding="utf-8")
    for ref in re.findall(r'"(res://[^"\n]+)"|\'(res://[^\'\n]+)\'', text):
        value = ref[0] or ref[1]
        if "{" in value or "}" in value or "%" in value:
            continue
        resource_refs.append((str(path.relative_to(ROOT)), value))
missing = [(src, ref) for src, ref in resource_refs if not (ROOT / ref.removeprefix("res://")).exists()]
require(not missing, f"literal res:// paths resolve ({len(resource_refs)} checked, {len(missing)} missing)", repr(missing[:12]))

# Static contracts for the independent runtime registry APIs.
registry = (SCRIPTS / "block_registry.gd").read_text(encoding="utf-8")
require("static func get_block(block_id: String) -> Dictionary:" in registry and "return blocks.get(block_id, {})" in registry,
        "get_block reads the block-only runtime dictionary")
require("static func get_item(item_id: String) -> Dictionary:" in registry and "return items.get(item_id, {})" in registry,
        "get_item reads the independent item registry")
require("static func get_item_runtime(item_id: String) -> Dictionary:" in registry and "item_visual_definitions.get(item_id, {})" in registry,
        "item display data joins presentation only through the item accessor")
require("blocks[item_id] = runtime_item" not in registry,
        "item records are never inserted into the block runtime dictionary")
require("static func get_place_block_id(item_id: String) -> String:" in registry and "item_to_block.get(item_id, \"\")" in registry,
        "placement is resolved through an explicit item-to-block map")

if failures:
    print(f"GDScript static scan: {len(checks)} checks passed, {len(failures)} failures")
    for issue in failures:
        print("FAIL: " + issue)
    raise SystemExit(1)
print(f"GDScript static scan: {len(checks)} checks passed, 0 failures")
for item in checks:
    print("PASS: " + item)
print("NOTE: this scan is not a substitute for opening/running the project in Godot 4.7.2.")
