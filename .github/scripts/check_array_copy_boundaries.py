#!/usr/bin/env python3
"""Reject public MoonBit boundaries that directly retain caller-owned arrays.

This is intentionally a small lexical guard, not a MoonBit parser. It examines
one top-level `///|` block at a time, finds public functions with `Array[...]`
parameters, and rejects direct retention in record fields or enum/constructor
payloads unless the retained value is an explicit `.copy()`.

Algorithms that only read an array are unaffected. If a future boundary
delegates to a helper that copies, keep the copy visible at the public boundary
instead of weakening this check.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOTS = ("types", "series", "expr", "frame", "lazy", "io", "internal")
PUBLIC_FN = re.compile(r"\bpub\s+fn(?:\[[^\]]+\])?\s+([A-Za-z0-9_:]+)\s*\(")
ARRAY_PARAM = re.compile(r"\b([a-z][A-Za-z0-9_]*)\s*:\s*Array\s*\[")


def matching_paren(text: str, opening: int) -> int | None:
    depth = 0
    in_string = False
    escaped = False
    for index in range(opening, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    return None


def constructor_retains(block: str, parameter: str) -> bool:
    """Whether an UpperCamel constructor directly receives `parameter`."""
    constructor = re.compile(r"(?<![:.A-Za-z0-9_])([A-Z][A-Za-z0-9_]*)\s*\(")
    for match in constructor.finditer(block):
        if match.group(1) in {"Some", "Ok", "Err"}:
            continue
        opening = block.find("(", match.start())
        closing = matching_paren(block, opening)
        if closing is None:
            continue
        arguments = block[opening + 1 : closing]
        depth = 0
        start = 0
        parts: list[str] = []
        for index, char in enumerate(arguments):
            if char in "([{":
                depth += 1
            elif char in ")]}":
                depth -= 1
            elif char == "," and depth == 0:
                parts.append(arguments[start:index].strip())
                start = index + 1
        parts.append(arguments[start:].strip())
        direct = re.compile(
            rf"^(?:[a-z][A-Za-z0-9_]*\s*=\s*)?{re.escape(parameter)}$"
        )
        if any(direct.fullmatch(part) for part in parts):
            return True
    return False


def retained_parameters(block: str) -> list[str]:
    match = PUBLIC_FN.search(block)
    if match is None:
        return []
    opening = block.find("(", match.start())
    closing = matching_paren(block, opening)
    if closing is None:
        return []
    signature = block[opening + 1 : closing]
    parameters = ARRAY_PARAM.findall(signature)
    body = re.sub(r"(?m)//.*$", "", block[closing + 1 :])
    retained: list[str] = []
    for parameter in parameters:
        field_assignment = re.search(
            rf"\b[A-Za-z_][A-Za-z0-9_]*\s*:\s*{re.escape(parameter)}\b"
            rf"(?!\s*\.copy\s*\()",
            body,
        )
        if field_assignment or constructor_retains(body, parameter):
            retained.append(parameter)
    return retained


def source_files() -> list[Path]:
    files: list[Path] = []
    for directory in SOURCE_ROOTS:
        for path in (ROOT / directory).rglob("*.mbt"):
            if path.name.endswith(("_test.mbt", "_wbtest.mbt")):
                continue
            files.append(path)
    return sorted(files)


def audit() -> list[str]:
    failures: list[str] = []
    for path in source_files():
        text = path.read_text(encoding="utf-8")
        for block in re.split(r"(?m)^///\|\s*$", text):
            fn_match = PUBLIC_FN.search(block)
            if fn_match is None:
                continue
            for parameter in retained_parameters(block):
                relative = path.relative_to(ROOT).as_posix()
                failures.append(
                    f"{relative}: {fn_match.group(1)} directly retains Array parameter "
                    f"'{parameter}'; copy it at the public boundary"
                )
    return failures


def self_test() -> None:
    unsafe_record = """
pub fn Box::new(values : Array[Int]) -> Box {
  { values: values }
}
"""
    unsafe_enum = """
pub fn Plan::select(exprs : Array[Expr]) -> Plan {
  Select(exprs)
}
"""
    safe_copy = """
pub fn Box::new(values : Array[Int]) -> Box {
  { values: values.copy() }
}
"""
    borrowed = """
pub fn sum(values : Array[Int]) -> Int {
  values.fold(init=0, (acc, value) => acc + value)
}
"""
    assert retained_parameters(unsafe_record) == ["values"]
    assert retained_parameters(unsafe_enum) == ["exprs"]
    assert retained_parameters(safe_copy) == []
    assert retained_parameters(borrowed) == []


def main() -> int:
    self_test()
    failures = audit()
    if failures:
        print("Array copy boundary check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("Array copy boundary check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
