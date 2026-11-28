"""Check that every refusal the reader can raise is pinned by a test: for
each `raise` site in the production sources, the fixed stretches of its
message template must all appear in one message a sidecar carries (the
fixtures test holds the codec to each by variant and exact text) or in one
string literal of a test file (a test asserting the text directly). A site
nothing pins is listed, and the script exits non-zero if there is one.

    uv run --no-project python -I -X utf8 .github/fixtures/xls/check_refusal_tests.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
PKG = os.path.join(ROOT, "internal", "xls")
FIX = os.path.join(HERE, "reference")
PRODUCTION = sorted(name for name in os.listdir(PKG)
                    if name.endswith(".mbt") and not name.endswith(("_test.mbt", "_wbtest.mbt")))

CHUNK = re.compile(r'[^\\{}"]+')

#: An interpolation of a template: `\{…}`.
INTERPOLATION = re.compile(r"\\\{[^}]*\}")

#: A string literal of the source, escaped quotes inside it included.
LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"')


def templates(path):
    """Every raise site of one production source: its file, line, kind,
    the fixed stretches of its message, and the template itself."""
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r"raise (bad|nope|no)\(", text):
        kind = m.group(1)
        # The message is the string literal that follows the call, as far
        # as the end of its statement.
        rest = text[m.end():text.find(")\n", m.end())]
        q = rest.find('"')
        # The literal runs from its opening quote to its closing one, an
        # escaped quote inside it being no end: none of the source after
        # it belong to the message.
        found = LITERAL.match(rest, q)
        literal = found.group(0)[1:-1].replace('\\"', '"') if found else rest[q + 1:]
        # Chunks of ordinary characters between interpolations — the
        # template cut at each interpolation — long enough to tell one
        # message from another.
        chunks = [c for c in INTERPOLATION.split(literal) if len(c.strip()) >= 8]
        line = text[:m.start()].count("\n") + 1
        yield os.path.basename(path), line, kind, chunks, literal[:90]


def evidence():
    """The messages a sidecar carries, and the string literals of the
    test files."""
    messages = []
    for name in os.listdir(FIX):
        if name.endswith(".json") and name != "index.json":
            with open(os.path.join(FIX, name), encoding="utf-8") as f:
                car = json.load(f)
            if car.get("codec") == "refuses":
                messages.append(car["message"])
    literals = []
    for name in os.listdir(PKG):
        if name.endswith(("_test.mbt", "_wbtest.mbt")):
            text = open(os.path.join(PKG, name), encoding="utf-8").read()
            literals += re.findall(r'"(?:[^"\\\n]|\\.)*"', text)
    return messages, literals


def main():
    messages, literals = evidence()
    unasserted = []
    counted = 0
    seen = set()
    by_kind = {"bad": 0, "nope": 0, "no": 0}
    for name in PRODUCTION:
        for file, line, kind, chunks, literal in templates(os.path.join(PKG, name)):
            counted += 1
            key = (kind, literal)
            if key in seen:
                continue
            seen.add(key)
            by_kind[kind] += 1
            pinned = any(all(chunk in message for chunk in chunks) for message in messages) or \
                any(all(chunk in literal_ for chunk in chunks) for literal_ in literals)
            if not pinned:
                unasserted.append("%s:%d %s %r" % (file, line, kind, literal))
    print("raise sites: %d; distinct messages: %d (%d located, %d by name, %d of a sheet out of range)"
          % (counted, len(seen), by_kind["bad"], by_kind["nope"], by_kind["no"]))
    print("sidecar messages: %d; test string literals: %d" % (len(messages), len(literals)))
    for site in unasserted:
        print("NOT ASSERTED " + site)
    print("refusal messages no test pins: %d" % len(unasserted))
    return 1 if unasserted else 0


if __name__ == "__main__":
    sys.exit(main())
