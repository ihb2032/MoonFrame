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


def mask_strings_and_comments(text: str) -> str:
    """Blank strings and line comments while preserving offsets."""
    chars = list(text)
    index = 0
    while index < len(chars):
        if chars[index] == '"':
            chars[index] = " "
            index += 1
            escaped = False
            while index < len(chars):
                char = chars[index]
                chars[index] = "\n" if char == "\n" else " "
                index += 1
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    break
        elif chars[index] == "/" and index + 1 < len(chars) and chars[index + 1] == "/":
            while index < len(chars) and chars[index] != "\n":
                chars[index] = " "
                index += 1
        else:
            index += 1
    return "".join(chars)


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


def matching_delimiter(text: str, opening: int) -> int | None:
    pairs = {"(": ")", "[": "]", "{": "}"}
    opener = text[opening]
    closer = pairs[opener]
    depth = 0
    for index in range(opening, len(text)):
        char = text[index]
        if char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return index
    return None


def split_top_level(text: str) -> list[str]:
    """Split comma-separated syntax while respecting nested delimiters."""
    depth = 0
    start = 0
    parts: list[str] = []
    for index, char in enumerate(text):
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(text[start:index].strip())
            start = index + 1
    parts.append(text[start:].strip())
    return parts


def constructor_retains(block: str, parameter: str) -> bool:
    """Whether a bare or qualified constructor receives `parameter`."""
    code = mask_strings_and_comments(block)
    constructor = re.compile(
        r"(?<![A-Za-z0-9_:@.])"
        r"(?:@[a-z][A-Za-z0-9_]*\.)?"
        r"(?:(?:[A-Z][A-Za-z0-9_]*)::)*"
        r"(?P<name>[A-Z][A-Za-z0-9_]*)\s*\("
    )
    for match in constructor.finditer(code):
        if match.group("name") in {"Some", "Ok", "Err"}:
            continue
        opening = code.find("(", match.start())
        closing = matching_delimiter(code, opening)
        if closing is None:
            continue
        parts = split_top_level(code[opening + 1 : closing])
        direct = re.compile(
            rf"^(?:[a-z][A-Za-z0-9_]*\s*=\s*)?{re.escape(parameter)}$"
        )
        if any(direct.fullmatch(part) for part in parts):
            return True
    return False


def record_shorthand_retains(block: str, parameter: str) -> bool:
    """Whether a record item uses `{ parameter }` field shorthand."""
    code = mask_strings_and_comments(block)
    for opening, char in enumerate(code):
        if char != "{":
            continue
        closing = matching_delimiter(code, opening)
        if closing is None:
            continue
        if parameter in split_top_level(code[opening + 1 : closing]):
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
    body = block[closing + 1 :]
    code = mask_strings_and_comments(body)
    retained: list[str] = []
    for parameter in parameters:
        copied_binding = re.search(
            rf"\blet\s+{re.escape(parameter)}\s*=\s*"
            rf"{re.escape(parameter)}\s*\.copy\s*\(\s*\)",
            code,
        )
        if copied_binding:
            continue
        field_assignment = re.search(
            rf"\b[A-Za-z_][A-Za-z0-9_]*\s*:\s*{re.escape(parameter)}\b"
            rf"(?!\s*\.copy\s*\()",
            code,
        )
        if (
            field_assignment
            or constructor_retains(body, parameter)
            or record_shorthand_retains(body, parameter)
        ):
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
    unsafe_qualified_enum = """
pub fn Plan::select(exprs : Array[Expr]) -> Plan {
  @plan.LogicalPlan::Select(exprs)
}
"""
    unsafe_shorthand = """
pub fn Box::new(values : Array[Int]) -> Box {
  { values }
}
"""
    safe_copy = """
pub fn Box::new(values : Array[Int]) -> Box {
  { values: values.copy() }
}
"""
    safe_shadow_copy = """
pub fn Box::new(values : Array[Int]) -> Box {
  let values = values.copy()
  { values }
}
"""
    borrowed = """
pub fn sum(values : Array[Int]) -> Int {
  values.fold(init=0, (acc, value) => acc + value)
}
"""
    assert retained_parameters(unsafe_record) == ["values"]
    assert retained_parameters(unsafe_enum) == ["exprs"]
    assert retained_parameters(unsafe_qualified_enum) == ["exprs"]
    assert retained_parameters(unsafe_shorthand) == ["values"]
    assert retained_parameters(safe_copy) == []
    assert retained_parameters(safe_shadow_copy) == []
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
