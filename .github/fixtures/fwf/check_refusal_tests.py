"""Check that every refusal the codec can raise is asserted by a test, by
variant and by a fixed stretch of its text.

For each ``raise`` site in the production sources the message template is
split at its interpolations into its fixed stretches — runs of ten or more
ordinary characters between two interpolations — and **every** stretch of a
message must appear, in order, inside one ``invalid(...)`` call in a test
file: the value the tests expect a refusal to equal, ``InvalidOperation``
with its detail. One stretch would not do — three messages begin
``fwf: field ``, and each would be counted as asserted by the others'
tests. Three more things are checked of every site: the variant is
``InvalidOperation``, the only variant the codec raises (a ``raise`` of any
other error is reported), and the message begins ``fwf: ``. A site no test
asserts is listed, and the script exits non-zero if there is one or if any
of the three fails. ``tools/probe/checker_selftest.py`` turns the rule on
itself: with a site's own calls removed, that site and no other must lose
its assertion.

    uv run --no-project python -I -X utf8 .github/fixtures/fwf/check_refusal_tests.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "internal", "fwf"
)
PRODUCTION = ["cut.mbt", "fwf.mbt", "infer.mbt", "layout.mbt"]
PREFIX = "fwf: "


def call_arguments(text, name):
    """The text inside every ``name(...)`` call in ``text``: nested
    parentheses and string literals are followed, so an interpolation's
    parentheses inside a string do not close the call."""
    arguments, at = [], 0
    opener = name + "("
    while True:
        start = text.find(opener, at)
        if start < 0:
            return arguments
        i = start + len(opener)
        depth = 1
        quoted = False
        while i < len(text) and depth > 0:
            ch = text[i]
            if quoted:
                if ch == "\\":
                    i += 1
                elif ch == '"':
                    quoted = False
            elif ch == '"':
                quoted = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            i += 1
        arguments.append(text[start + len(opener):i - 1])
        at = i


def sites(path):
    """Every raise site of a production file: its line, its variant and —
    for an ``InvalidOperation`` — the fixed stretches of its message."""
    text = open(path, encoding="utf-8").read()
    for m in re.finditer(r"raise\s+(@[A-Za-z0-9_./]+)::([A-Za-z0-9_]+)\(", text):
        variant = m.group(2)
        line = text[:m.start()].count("\n") + 1
        rest = text[m.end():text.find(")\n", m.end())]
        quote = rest.find('"')
        literal = rest[quote + 1:] if quote >= 0 else ""
        yield os.path.basename(path), line, variant, literal, stretches(literal)


def stretches(literal):
    """The fixed stretches of a message template: the runs of ten or more
    ordinary characters between two interpolations. An interpolation is
    removed whole — what is spelled inside its braces is not part of the
    message, and a long name there would otherwise pose as a stretch."""
    solid = re.sub(r"\\\{[^}]*\}", "\x00", literal)
    return re.findall(r'[^\\{}"\x00]{10,}', solid)


def asserts(argument, chunks):
    """Whether one ``invalid(...)`` argument spells a message: every fixed
    stretch of the template appears in it, in the template's order."""
    at = 0
    for chunk in chunks:
        found = argument.find(chunk, at)
        if found < 0:
            return False
        at = found + len(chunk)
    return True


def main():
    tests = ""
    for name in sorted(os.listdir(PKG)):
        if name.endswith("_test.mbt") or name.endswith("_wbtest.mbt"):
            tests += open(os.path.join(PKG, name), encoding="utf-8").read()
    expected = call_arguments(tests, "invalid")
    raised = 0
    unasserted, wrong = [], []
    for name in PRODUCTION:
        for file, line, variant, literal, chunks in sites(os.path.join(PKG, name)):
            raised += 1
            if variant != "InvalidOperation":
                wrong.append("%s:%d raises %s" % (file, line, variant))
                continue
            if not literal.startswith(PREFIX):
                wrong.append("%s:%d the message does not begin with %r: %r"
                             % (file, line, PREFIX, literal))
            if not any(asserts(argument, chunks) for argument in expected):
                unasserted.append("%s:%d %r" % (file, line, literal[:80]))
    print("raise sites: %d; of them InvalidOperation with a text beginning %r: %d"
          % (raised, PREFIX, raised - len(wrong)))
    print("invalid(...) calls the tests hold: %d" % len(expected))
    for site in wrong:
        print("NOT INVALID OPERATION OR NOT PREFIXED " + site)
    for site in unasserted:
        print("NOT ASSERTED " + site)
    print("raise sites that break the rules: %d" % len(wrong))
    print("refusal messages no test asserts: %d" % len(unasserted))
    return 1 if wrong or unasserted else 0


if __name__ == "__main__":
    sys.exit(main())
