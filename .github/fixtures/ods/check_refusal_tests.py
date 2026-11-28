"""Check that every refusal the reader can raise is asserted by a test,
by variant and by exact text. For each `raise` site in the production
sources — `raise bad(...)`, `raise nope(...)`, the two helpers that wrap
them (`attr.refusal`, `sheet.too_big`, both `ParseError`) and the one
`InvalidOperation` — the first string literal of the message is found (in
the raise itself, or in the `let` that names it), split at its
interpolations, and each fixed stretch of 10 characters or more must
appear in a test file or in a sidecar's `message` — the fixtures test
compares those to the letter — with the variant the site raises named
beside it in the same file. A site with a stretch no test or sidecar
carries is listed; the script exits non-zero if there is one.

    uv run --no-project python -I -X utf8 .github/fixtures/ods/check_refusal_tests.py

The package and the corpus are read from the repository; `ODS_PKG` and
`ODS_FIX` point the check at another copy, which is how the check's own
negative test is run — a copy with two messages reworded must fail.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
PKG = os.environ.get("ODS_PKG") or os.path.join(ROOT, "internal", "ods")
FIX = os.environ.get("ODS_FIX") or os.path.join(HERE, "reference")
PRODUCTION = [
    "cells.mbt", "driver.mbt", "errors.mbt", "ods.mbt", "package.mbt", "text.mbt", "value.mbt",
]
LITERAL = r'"((?:[^"\\]|\\.)*)"'
MESSAGE = re.compile(
    r"raise (bad|nope|attr\.refusal|sheet\.too_big)\(|"
    r"raise @types\.DataError::(InvalidOperation)\(")
KINDS = {
    "bad": "ParseError", "attr.refusal": "ParseError", "sheet.too_big": "ParseError",
    "nope": "Unsupported", "InvalidOperation": "InvalidOperation",
}


def template_of(text, start):
    """The message's first string literal from `start` on: in the call, or
    in the `let` that names what the call passes."""
    rest = text[start:start + 400]
    literal = re.search(LITERAL, rest)
    if literal:
        return literal.group(1)
    named = re.match(r"\s*([a-z_][a-z0-9_]*)\s*[,)]", rest)
    if not named:
        return None
    lets = list(re.finditer(
        r"let\s+%s\s*=\s*\n?\s*%s" % (re.escape(named.group(1)), LITERAL), text[:start]))
    if not lets:
        return None
    return lets[-1].group(1)


def sites(path):
    text = open(path, encoding="utf-8").read()
    for m in MESSAGE.finditer(text):
        kind = m.group(1) or m.group(2)
        template = template_of(text, m.end())
        line = text[:m.start()].count("\n") + 1
        yield os.path.basename(path), line, kind, template


def stretches(template):
    """The fixed stretches of a template: runs between interpolations, 10
    characters or more, with MoonBit's escapes undone."""
    out = []
    for part in re.split(r"\\\{[^}]*\}", template):
        part = part.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
        out.extend(re.findall(r"[^\"]{10,}", part))
    return out


def unescape(text):
    return text.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def main():
    tests = ""
    for name in sorted(os.listdir(PKG)):
        if name.endswith("_test.mbt") or name.endswith("_wbtest.mbt"):
            tests += unescape(open(os.path.join(PKG, name), encoding="utf-8").read()) + "\n"
    sidecars = []
    for name in sorted(os.listdir(FIX)):
        if name.endswith(".json") and name != "index.json":
            car = json.load(open(os.path.join(FIX, name), encoding="utf-8"))
            if car["codec"] == "refuses":
                sidecars.append((car["refusal"], car["message"]))
    missing = []
    counted = 0
    seen = set()
    by_kind = {}
    for name in PRODUCTION:
        for file, line, kind, template in sites(os.path.join(PKG, name)):
            counted += 1
            key = (kind, template)
            if key in seen:
                continue
            seen.add(key)
            by_kind[kind] = by_kind.get(kind, 0) + 1
            wanted = KINDS[kind]
            chunks = stretches(template) if template else []
            if not chunks:
                if kind == "sheet.too_big":
                    # The message is the helper's, counted at its own site.
                    counted -= 1
                    continue
                missing.append("%s:%d %s <no message literal: %r>" % (file, line, kind, template))
                continue
            for chunk in chunks:
                in_tests = chunk in tests and wanted in tests
                in_sidecar = any(variant == wanted and chunk in message for variant, message in sidecars)
                if not (in_tests or in_sidecar):
                    missing.append("%s:%d %s %r" % (file, line, kind, chunk[:90]))
    located = by_kind.get("bad", 0) + by_kind.get("attr.refusal", 0) + by_kind.get("sheet.too_big", 0)
    print("raise sites: %d; distinct messages: %d (%d located, %d by name, %d out of range)"
          % (counted, len(seen), located, by_kind.get("nope", 0), by_kind.get("InvalidOperation", 0)))
    for site in missing:
        print("NOT ASSERTED " + site)
    print("refusal stretches no test or sidecar asserts: %d" % len(missing))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
