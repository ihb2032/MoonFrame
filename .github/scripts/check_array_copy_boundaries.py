#!/usr/bin/env python3
"""Reject public MoonBit boundaries that directly retain caller-owned arrays.

This is intentionally a small lexical guard, not a MoonBit parser. It examines
one top-level `///|` block at a time, finds public functions with `Array[...]`
parameters — positional, optional (`subset? : Array[...]`), or labelled
(`keys~ : Array[...]`) — and rejects direct retention in record fields or
enum/constructor payloads unless the retained value is an explicit `.copy()`.
`Some` / `Ok` / `Err` are transparent: a payload holding `Some(values)` retains
`values` exactly as a bare `values` would.

A `let values = values.copy()` shadow binding also clears the parameter, but
only when it is at the body's top level *and* precedes every retention. Both
conditions matter: rebinding after the array was handed on leaves the original
aliased, and a copy inside one branch says nothing about the others — neither
of which this lexical guard could otherwise tell apart from the real idiom.

Algorithms that only read an array are unaffected. If a future boundary
delegates to a helper that copies, keep the copy visible at the public boundary
instead of weakening this check — a copy hidden one call away is invisible here
by design, and the runtime contracts in `array_ownership_test.mbt` are what pin
those boundaries.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOTS = (
    "types",
    "series",
    "expr",
    "frame",
    "lazy",
    "io",
    "internal",
    "examples",
)
PUBLIC_FN = re.compile(r"\bpub\s+fn(?:\[[^\]]+\])?\s+([A-Za-z0-9_:]+)\s*\(")
# `?` marks an optional parameter and `~` a labelled one; both still hand the
# callee a caller-owned array.
ARRAY_PARAM = re.compile(r"\b([a-z][A-Za-z0-9_]*)\s*[?~]?\s*:\s*Array\s*\[")
TRANSPARENT_WRAPPERS = ("Some", "Ok", "Err")


def wrapped_forms(parameter: str) -> str:
    """Regex source matching `parameter` bare or inside a transparent wrapper.

    `Some` / `Ok` / `Err` do not own the array they carry, so a field or payload
    holding `Some(values)` aliases the caller's array just as `values` does.
    """
    escaped = re.escape(parameter)
    wrappers = "|".join(TRANSPARENT_WRAPPERS)
    return rf"(?:{escaped}|(?:{wrappers})\s*\(\s*{escaped}\s*\))"


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


def constructor_retains(block: str, parameter: str) -> int | None:
    """Offset of the first bare or qualified constructor receiving `parameter`."""
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
            rf"^(?:[a-z][A-Za-z0-9_]*\s*=\s*)?{wrapped_forms(parameter)}$"
        )
        if any(direct.fullmatch(part) for part in parts):
            return match.start()
    return None


def record_shorthand_retains(block: str, parameter: str) -> int | None:
    """Offset of the first record item using `{ parameter }` field shorthand."""
    code = mask_strings_and_comments(block)
    for opening, char in enumerate(code):
        if char != "{":
            continue
        closing = matching_delimiter(code, opening)
        if closing is None:
            continue
        if parameter in split_top_level(code[opening + 1 : closing]):
            return opening
    return None


def top_level_copy(code: str, parameter: str) -> int | None:
    """Offset of a `let p = p.copy()` shadow binding at the body's top level.

    Only a top-level binding protects every path out of the function. One
    inside an `if` / `match` arm leaves the other arms holding the caller's
    array, and this guard is lexical — it cannot see which branch a retention
    sits in — so a nested shadow copy is not accepted as protection.
    """
    pattern = re.compile(
        rf"\blet\s+{re.escape(parameter)}\s*=\s*"
        rf"{re.escape(parameter)}\s*\.copy\s*\(\s*\)"
    )
    for match in pattern.finditer(code):
        # `code` starts after the signature's `)`, so the function body's own
        # opening brace is the only one enclosing a top-level statement.
        prefix = code[: match.start()]
        if prefix.count("{") - prefix.count("}") == 1:
            return match.start()
    return None


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
        field_assignment = re.search(
            rf"\b[A-Za-z_][A-Za-z0-9_]*\s*:\s*{wrapped_forms(parameter)}"
            rf"(?![A-Za-z0-9_]|\s*\.copy\s*\()",
            code,
        )
        # Where the caller's array is first handed to something that keeps it.
        # `constructor_retains` / `record_shorthand_retains` mask the same body,
        # so every offset indexes the same string and they compare directly.
        sites = [
            None if field_assignment is None else field_assignment.start(),
            constructor_retains(body, parameter),
            record_shorthand_retains(body, parameter),
        ]
        found = [site for site in sites if site is not None]
        if not found:
            continue
        # A shadow copy protects a retention only if it already ran: rebinding
        # *after* the array was handed on leaves the original aliased, and a
        # copy nested in one branch says nothing about the others.
        copied_at = top_level_copy(code, parameter)
        if copied_at is not None and copied_at < min(found):
            continue
        retained.append(parameter)
    return retained


def source_files() -> list[Path]:
    # The facade package lives in the repository root, so its own `.mbt` files
    # are part of the public surface the guard covers.
    candidates: list[Path] = list(ROOT.glob("*.mbt"))
    for directory in SOURCE_ROOTS:
        root = ROOT / directory
        if not root.is_dir():
            continue
        candidates.extend(root.rglob("*.mbt"))
    return sorted(
        path
        for path in candidates
        if not path.name.endswith(("_test.mbt", "_wbtest.mbt"))
    )


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
    unsafe_optional = """
pub fn Plan::drop_nulls(subset? : Array[Expr]) -> Plan {
  { plan: DropNulls(subset) }
}
"""
    unsafe_wrapped = """
pub fn Plan::drop_nulls(subset : Array[Expr]) -> Plan {
  { plan: DropNulls(Some(subset)) }
}
"""
    borrowed = """
pub fn sum(values : Array[Int]) -> Int {
  values.fold(init=0, (acc, value) => acc + value)
}
"""
    # A shadow copy that runs after the array was already handed on protects
    # nothing — the retained value is still the caller's array.
    unsafe_retain_then_copy = """
pub fn Box::new(values : Array[Int]) -> Box {
  let result = Box(values)
  let values = values.copy()
  ignore(values)
  result
}
"""
    # ...nor does one confined to a single branch: the other branch retains.
    unsafe_branch_copy = """
pub fn Box::new(flag : Bool, values : Array[Int]) -> Box {
  if flag {
    let values = values.copy()
    Box(values)
  } else {
    Box(values)
  }
}
"""
    assert retained_parameters(unsafe_record) == ["values"]
    assert retained_parameters(unsafe_enum) == ["exprs"]
    assert retained_parameters(unsafe_qualified_enum) == ["exprs"]
    assert retained_parameters(unsafe_shorthand) == ["values"]
    assert retained_parameters(unsafe_optional) == ["subset"]
    assert retained_parameters(unsafe_wrapped) == ["subset"]
    assert retained_parameters(safe_copy) == []
    assert retained_parameters(safe_shadow_copy) == []
    assert retained_parameters(borrowed) == []
    assert retained_parameters(unsafe_retain_then_copy) == ["values"]
    assert retained_parameters(unsafe_branch_copy) == ["values"]


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
