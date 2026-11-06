#!/usr/bin/env python3
"""Reject public MoonBit boundaries that directly retain caller-owned arrays.

This is intentionally a small lexical guard, not a MoonBit parser. It examines
one top-level `///|` block at a time — *every* `pub fn` signature the block
carries, not just the first — and finds public functions with `Array[...]`
parameters — positional, optional (`subset? : Array[...]`), or labelled
(`keys~ : Array[...]`), `_`-prefixed spellings included — and rejects direct
retention in record fields or enum/constructor payloads unless the retained
value is an explicit `.copy()`. `Some` / `Ok` / `Err` are transparent — nested
transparently too, so `Ok(Some(values))` is one hand-off — and three more
shapes count as retention like the record literal does: a plain `=` assignment
whose whole right-hand side is the parameter (a `mut` field or a global
stash); a conditional assignment whose `if` / `match` right-hand side mentions
the parameter bare (`self.f = if c { values } else { other }`); and a method
call whose argument list hands the parameter over (`stash.push(values)`,
`self.init(values)`), read conservatively — the guard cannot see which callee
keeps its argument, so a read-only method taking the array is flagged too, and
the fix is the same visible copy. A `@pkg.fn(values)` call is not a method
call: the qualifier makes it the free function it is, unqualified spelling
and all. Retention through a same-block alias counts
as well (`let v2 = values` followed by `Frame(cols = v2)`), where the alias
binding is the hand-off point a shadow copy must precede — and the alias's
right-hand side may wrap the parameter in a transparent wrapper or bare
parentheses (`let v2 = Some(values)`, `let v2 = (values)`), the same shapes a
constructor payload may.

A `let values = values.copy()` shadow binding also clears the parameter, but
only when it is at the body's top level *and* precedes every retention. Both
conditions matter: rebinding after the array was handed on leaves the original
aliased, and a copy inside one branch says nothing about the others — neither
of which this lexical guard could otherwise tell apart from the real idiom.

Algorithms that only read an array are unaffected (a method *receiver* is a
read; only the argument position counts). If a future boundary delegates to a
helper that copies, keep the copy visible at the public boundary instead of
weakening this check — a copy hidden one call away is invisible here by
design, and the runtime contracts in `array_ownership_test.mbt` are what pin
those boundaries.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
# The fixture module under `.github/` is a *downstream* consumer built against
# the published surface; its boundaries are its own, not this module's.
EXCLUDED_PREFIX = ".github/"
# A public boundary is spelled `pub fn name(` or — the shape an `extend` /
# `impl` block publishes — `with fn name(` (the block's own `pub` qualifier
# sits pages of methods away from the individual `fn`). Matching a non-`pub`
# `with fn` too is over-matching in the safe direction: it can only ask a
# copy to be visible where the module boundary already forbids the caller.
PUBLIC_FN = re.compile(
    r"\bpub\s+fn(?:\[[^\]]+\])?\s+([A-Za-z0-9_:]+)\s*\("
    r"|\bwith\s+fn(?:\[[^\]]*\])?\s+([A-Za-z0-9_:]+)\s*\("
)
# `?` marks an optional parameter and `~` a labelled one; both still hand the
# callee a caller-owned array. A `_`-prefixed name (`_values`) is a binding the
# body may still reference, so it is scanned like any other — only a bare `_`
# discards, and a discarded parameter cannot be retained.
ARRAY_PARAM = re.compile(r"\b(_?[a-z][A-Za-z0-9_]*)\s*[?~]?\s*:\s*Array\s*\[")
TRANSPARENT_WRAPPERS = ("Some", "Ok", "Err")


def wrapped_forms(parameter: str) -> str:
    """Regex source matching `parameter` bare or inside transparent wrappers.

    `Some` / `Ok` / `Err` do not own the array they carry, so a field or
    payload holding `Some(values)` aliases the caller's array just as
    `values` does — and the wrappers nest (`Ok(Some(values))` is one
    hand-off, not two), so the form is expanded three levels deep, past
    any nesting a real boundary writes.
    """
    escaped = re.escape(parameter)
    wrappers = "(?:Some|Ok|Err)\\s*\\(\\s*{inner}\\s*\\)"
    form = escaped
    for _ in TRANSPARENT_WRAPPERS:
        form = rf"(?:{escaped}|{wrappers.format(inner=form)})"
    return form


def mask_strings_and_comments(text: str) -> str:
    """Blank string literals, `Char` literals and line comments, keeping offsets.

    `Char` literals matter as much as strings: `'}'` would otherwise close a
    brace that was never opened (making a nested shadow copy look top-level to
    `top_level_copy`), `'{'` would open one that never closes, and `'"'` would
    start a string that swallows the rest of the block. Every structural scan
    here — brace depth, `matching_paren`, `matching_delimiter` — reads the
    masked text, so they all agree on what is code.

    Masking is idempotent: the pass leaves no quote or comment marker behind,
    so re-masking already-masked text changes nothing.
    """
    chars = list(text)
    index = 0
    while index < len(chars):
        if chars[index] in ('"', "'"):
            quote = chars[index]
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
                elif char == quote:
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


def method_argument_retains(block: str, parameter: str) -> int | None:
    """Offset of the first method call loading `parameter` as an argument.

    `stash.push(values)` and `self.init(values)` keep the array wherever the
    callee decides — a setter, a builder, a growing buffer — and the retain
    detectors that read fields and constructors never see an argument list.
    The receiver is irrelevant to ownership, so only the argument position
    counts: `values.copy()` and `values.fold(…)` are reads. Deliberately
    conservative, like the guard as a whole: a read-only method that takes the
    array (`others.zip(values)`) is flagged too, and the remedy is the same
    visible `.copy()` the constructor case asks for. A `@pkg.fn(values)` call
    is *not* one: the `@pkg.` prefix is a package qualifier, and the call a
    free function under it — the same spelling `fn(values)` wears without the
    qualifier, which this guard has never read. An import alias must not be
    what decides whether a boundary is flagged.
    """
    code = mask_strings_and_comments(block)
    call = re.compile(r"\.\s*[a-z][A-Za-z0-9_]*\s*\(")
    qualified = re.compile(r"@[A-Za-z_][A-Za-z0-9_]*$")
    for match in call.finditer(code):
        if qualified.search(code, 0, match.start()):
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


def function_spans(block: str) -> list[tuple[str, str, str]]:
    """Every public function a `///|` block declares, as (name, signature, body).

    A block may carry more than one `pub fn` — stacking small functions under
    one separator is ordinary style — and scanning only the first left the rest
    outside the guard entirely. The body of each runs from its signature's
    closing parenthesis to the next signature (or the block's end), so one
    function's retentions are never read as another's. The text between two
    signatures — attributes, doc comments, a `priv` helper — belongs to the
    earlier function's body: lexically conservative, in this guard's usual
    direction.
    """
    masked = mask_strings_and_comments(block)
    matches = list(PUBLIC_FN.finditer(masked))
    spans: list[tuple[str, str, str]] = []
    for index, match in enumerate(matches):
        opening = masked.find("(", match.start())
        closing = matching_paren(masked, opening)
        if closing is None:
            continue
        end = matches[index + 1].start() if index + 1 < len(matches) else len(masked)
        # Either alternative of PUBLIC_FN may have matched; the name sits in
        # whichever group it filled.
        name = match.group(1) or match.group(2)
        spans.append((name, masked[opening + 1 : closing], masked[closing + 1 : end]))
    return spans


def retained_in(signature: str, code: str) -> list[str]:
    """The Array parameters one public function body directly retains."""
    parameters = ARRAY_PARAM.findall(signature)
    retained: list[str] = []
    for parameter in parameters:
        # An alias hands the same array on under a second name, and the
        # binding itself is the hand-off: a shadow copy that runs later
        # rebinds the parameter, never the alias, so anything the alias
        # feeds afterwards still reaches the caller's array. An alias
        # bound *after* the copy names the copy instead and is safe. The
        # right-hand side may wrap the parameter the way a constructor
        # payload may (`Some(values)`, `(values)`) — the wrapper does not
        # own the array either, only the copy does.
        copied_at = top_level_copy(code, parameter)
        bare = re.escape(parameter)
        aliases: list[tuple[str, int]] = []
        for alias in re.finditer(
            rf"(?m)^\s*let\s+([a-z][A-Za-z0-9_]*)\s*=\s*"
            rf"(?:{wrapped_forms(parameter)}|\(\s*{bare}\s*\))\s*$",
            code,
        ):
            if copied_at is not None and copied_at < alias.start():
                continue
            aliases.append((alias.group(1), alias.start()))
        # Where the caller's array is first handed to something that keeps
        # it. Every detector reads the same masked body — masking is
        # idempotent, so the helpers' own pass is a no-op — and their
        # offsets index one string. An alias binding counts as a hand-off
        # only once a retention fires *through that alias* — a borrow that
        # never reaches a field is a read.
        sites: list[int] = []
        for name, offset in [(parameter, 0)] + aliases:
            retained_via_name: list[int] = []
            field_assignment = re.search(
                rf"\b[A-Za-z_][A-Za-z0-9_]*\s*:\s*{wrapped_forms(name)}"
                rf"(?![A-Za-z0-9_]|\s*\.copy\s*\()",
                code,
            )
            if field_assignment is not None:
                retained_via_name.append(field_assignment.start())
            # A plain `=` write whose whole right-hand side is the parameter
            # (or a transparent wrapper of it): a `mut` field or a global
            # stash — assignment syntax, not the record literal the field
            # detector reads.
            assignment = re.search(
                rf"(?m)^[ \t]*(?!let\b)"
                rf"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*"
                rf"\s*=\s*{wrapped_forms(name)}\s*$",
                code,
            )
            if assignment is not None:
                retained_via_name.append(assignment.start())
            # A conditional write is the same hand-off spread over branches:
            # the right-hand side is an `if` / `match` expression, so no
            # single branch is "the whole right-hand side", and one that
            # mentions the parameter bare still hands the caller's array
            # into the field on the paths that take it. A `.copy()` inside
            # the branch is the visible copy this guard asks for.
            conditional = re.search(
                rf"(?m)^[ \t]*(?!let\b)"
                rf"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*"
                rf"\s*=\s*(?:if|match)\b.*"
                rf"(?<![A-Za-z0-9_]){re.escape(name)}"
                rf"(?![A-Za-z0-9_])(?!\s*\.\s*copy\s*\()",
                code,
            )
            if conditional is not None:
                retained_via_name.append(conditional.start())
            via_method = method_argument_retains(code, name)
            if via_method is not None:
                retained_via_name.append(via_method)
            via_constructor = constructor_retains(code, name)
            if via_constructor is not None:
                retained_via_name.append(via_constructor)
            via_shorthand = record_shorthand_retains(code, name)
            if via_shorthand is not None:
                retained_via_name.append(via_shorthand)
            if retained_via_name:
                sites.extend(retained_via_name)
                if offset:
                    sites.append(offset)
        if not sites:
            continue
        # A shadow copy protects a retention only if it already ran: rebinding
        # *after* the array was handed on leaves the original aliased, and a
        # copy nested in one branch says nothing about the others.
        if copied_at is not None and copied_at < min(sites):
            continue
        retained.append(parameter)
    return retained


def retained_parameters(block: str) -> list[str]:
    """Every Array parameter any public function in the block retains."""
    retained: list[str] = []
    for _name, signature, code in function_spans(block):
        retained.extend(retained_in(signature, code))
    return retained


def source_files(root: Path = ROOT) -> list[Path]:
    """Every production `.mbt` file the repository tracks.

    Asked of git rather than read off a list of directories, because a list is
    something a new package can be added without: a top-level package whose name
    nobody appended would have gone unscanned behind a green run, and the guard
    would have reported passing on a surface it never looked at. Tracking is the
    condition that actually matters — an untracked file is not part of the
    published surface — so it is the condition the guard uses. Test files are
    excluded (a test is not a public boundary), as is `.github/`.
    """
    listed = subprocess.run(
        ["git", "ls-files", "-z", "*.mbt"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split("\0")
    return sorted(
        root / name
        for name in listed
        if name
        and not name.startswith(EXCLUDED_PREFIX)
        and not name.endswith(("_test.mbt", "_wbtest.mbt"))
    )


def audit(root: Path = ROOT) -> list[str]:
    failures: list[str] = []
    for path in source_files(root):
        text = path.read_text(encoding="utf-8")
        for block in re.split(r"(?m)^///\|\s*$", text):
            for name, signature, code in function_spans(block):
                for parameter in retained_in(signature, code):
                    relative = path.relative_to(root).as_posix()
                    failures.append(
                        f"{relative}: {name} directly retains Array parameter "
                        f"'{parameter}'; copy it at the public boundary"
                    )
    return failures


def main() -> int:
    # The guard's own behaviour is pinned in `check_array_copy_boundaries_test.py`,
    # which CI runs first — so a guard that has stopped catching anything fails
    # there rather than passing vacuously here. The cases used to be spelled twice,
    # once in each file, which is one copy too many for the same reason any other
    # duplicated fact is.
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
