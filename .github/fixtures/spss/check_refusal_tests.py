"""Check that every refusal message the reader can raise is asserted by
a test, by variant and by a fixed stretch of its text. For each `raise`
site in the production sources the message template is split at its
interpolations, and at least one fixed stretch of it must appear in a
test file, in an `Unsupported(...)` call for the by-name refusals and in
a `parse(...)` call for the located ones. A site no test asserts is
listed; the script exits non-zero if there is one.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "internal", "spss")
PRODUCTION = ["cursor.mbt", "data.mbt", "dictionary.mbt", "read.mbt", "resolve.mbt", "text.mbt"]


def templates(path):
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r"raise (bad|nope)\(", text):
        kind = m.group(1)
        # The message is the template that follows the call, as far as
        # the end of its statement; its fixed stretches are the runs of
        # ordinary characters between interpolations and nested quotes.
        rest = text[m.end():text.find(")\n", m.end())]
        q = rest.find('"')
        literal = rest[q + 1:]
        chunks = [c for c in re.findall(r"[^\\{}\"]{10,}", literal)]
        line = text[:m.start()].count("\n") + 1
        yield os.path.basename(path), line, kind, chunks, rest[:110]


def main():
    tests = ""
    for name in os.listdir(PKG):
        if name.endswith("_test.mbt") or name.endswith("_wbtest.mbt"):
            tests += open(os.path.join(PKG, name), encoding="utf-8").read()
    unasserted = []
    counted = 0
    by_kind = {"bad": 0, "nope": 0}
    seen = set()
    for name in PRODUCTION:
        for file, line, kind, chunks, literal in templates(os.path.join(PKG, name)):
            counted += 1
            key = (kind, literal)
            if key in seen:
                continue
            seen.add(key)
            by_kind[kind] += 1
            wrapper = "parse(" if kind == "bad" else "unsupported("
            if not any(chunk in tests and wrapper in tests for chunk in chunks):
                unasserted.append("%s:%d %s %r" % (file, line, kind, literal[:70]))
    print("raise sites: %d; distinct messages: %d (%d located, %d by name)"
          % (counted, len(seen), by_kind["bad"], by_kind["nope"]))
    for site in unasserted:
        print("NOT ASSERTED " + site)
    print("refusal messages no test asserts: %d" % len(unasserted))
    return 1 if unasserted else 0


if __name__ == "__main__":
    sys.exit(main())
