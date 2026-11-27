"""Writes the named character references the HTML reader decodes.

Run from the repository root; it rewrites `io/html_entities.mbt`:

    uv run --no-project python -I -X utf8 .github/fixtures/html/make_entities.py

The set is the HTML 4 one — the 252 names every browser and the reference
readers decode — taken from Python's `html.entities.entitydefs`, plus
`apos`, which HTML 4 leaves out and every later specification carries.
Each entry is a name and the text it stands for, sorted by name for the
lookup's binary search.
"""
from __future__ import annotations

import sys
from html.entities import entitydefs
from pathlib import Path

OUT = Path(__file__).resolve().parents[3] / "io" / "html_entities.mbt"


def moonbit_char(ch: str) -> str:
    if ch in ("\\", "\""):
        return "\\" + ch
    code = ord(ch)
    if 32 <= code < 127:
        return ch
    return f"\\u{{{code:X}}}"


def main() -> int:
    entities = {name: value for name, value in entitydefs.items()}
    entities.setdefault("apos", "'")
    names = sorted(entities)
    lines = [
        "// The named character references the HTML reader decodes: the HTML 4",
        "// set and `apos`, a name and the text it stands for, sorted by name",
        "// for the lookup's binary search. A numeric reference is decoded by",
        "// its code point and needs no entry.",
        "//",
        "// One-file-one-test exemption: this table has no dedicated test file of",
        "// its own. It is covered through the HTML reader's tests.",
        "",
        "///|",
        "/// Every name this reader decodes, with the text it stands for.",
        "let named_references : ReadOnlyArray[(String, String)] = [",
    ]
    for name in names:
        value = "".join(moonbit_char(ch) for ch in entities[name])
        lines.append(f"  (\"{name}\", \"{value}\"),")
    lines.append("]")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {OUT.name}: {len(names)} names")
    return 0


if __name__ == "__main__":
    sys.exit(main())
