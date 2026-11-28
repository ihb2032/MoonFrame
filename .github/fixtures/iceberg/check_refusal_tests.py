"""Prove that every refusal the codec can raise has a test asserting its
message.

Every raise site in the package's production sources — a call on the two
functions that build a refusal — is read as a skeleton: the words of its
literal, each interpolation standing for anything. A site is covered when a
refusal text matches its skeleton: the sidecars' and the patched files'
index entries' `text`, which the blackbox tests compare the codec's answer
with for equality, or a `iceberg: ` literal in a test file, which the
whitebox tests compare for equality. A site whose text is a caller's (an
argument passed through) is a combinator and is listed apart. Exit non-zero
on a site without a test.

    uv run --no-project python -I -X utf8 .github/fixtures/iceberg/check_refusal_tests.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
PACKAGE = os.path.join(REPO, "internal", "iceberg")
FIXTURES = os.path.join(HERE, "reference")
BUILDERS = ("malformed", "refuse")
PREFIX = "iceberg: "


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def strip_comments(text):
    """The source with its `//` comments blanked, so a call named in a
    comment is not taken for one."""
    return re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), text)


def arguments(text, open_at):
    """The argument strings of a call whose opening parenthesis is at
    `open_at`, split at the top-level commas."""
    depth, start, args, i = 0, open_at + 1, [], open_at
    while i < len(text):
        c = text[i]
        if c == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append(text[start:i].strip())
                return [arg for arg in args if arg], i
        elif c == "," and depth == 1:
            args.append(text[start:i].strip())
            start = i + 1
        i += 1
    raise SystemExit("unbalanced call at %d" % open_at)


def literal_parts(arg):
    """The string literals of an argument: adjacent literals joined, with
    none when the argument is a bare name — a caller's text passed on."""
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", arg):
        return None
    parts = re.findall(r'"((?:[^"\\]|\\.)*)"', arg, flags=re.S)
    if not parts:
        return None
    return "".join(parts)


def skeleton(literal):
    """A regular expression for the messages a literal spells: each
    interpolation in braces matches anything, and the rest is the words."""
    text = literal.replace('\\"', '"').replace("\\\\", "\\")
    pieces, at = [], 0
    while at < len(text):
        if text.startswith("\\{", at):
            depth, end = 1, at + 2
            while end < len(text) and depth > 0:
                depth += {"{": 1, "}": -1}.get(text[end], 0)
                end += 1
            pieces.append("\x00")
            at = end
        else:
            pieces.append(text[at])
            at += 1
    joined = "".join(pieces)
    return re.escape(joined).replace(re.escape("\x00"), ".*?")


def sites():
    """Every raise site: (file, line, function, pattern or None). The two
    builders' definitions are no sites, and a call that passes a caller's
    text on is a forwarder, its pattern `None`."""
    found = []
    for name in sorted(os.listdir(PACKAGE)):
        if not name.endswith(".mbt") or name.endswith("_test.mbt") or name.endswith("_wbtest.mbt"):
            continue
        text = strip_comments(read(os.path.join(PACKAGE, name)))
        for m in re.finditer(r"\b(malformed|refuse)\(", text):
            before = text[:m.start()].rstrip()
            if before.endswith("fn"):
                continue
            function = m.group(1)
            args, _ = arguments(text, m.end() - 1)
            literal = literal_parts(args[0])
            line = text.count("\n", 0, m.start()) + 1
            if literal is None:
                found.append((name, line, function, None))
                continue
            found.append((name, line, function, skeleton(PREFIX + literal)))
    return found


def expected_texts():
    """The refusal texts the tests assert, without the prefix: every
    refusal in a sidecar or in the patched files' index, and every `iceberg: `
    literal in a test file."""
    texts = []
    index = json.loads(read(os.path.join(FIXTURES, "index.json")))
    for entry in index["tables"]:
        if entry.get("codec") == "refuses":
            sidecar = json.loads(read(os.path.join(FIXTURES, entry["sidecar"])))
            texts.append((entry["sidecar"], sidecar["refusal"]["text"]))
    for entry in index["patched"]:
        if entry.get("codec") == "refuses":
            texts.append((entry["file"], entry["refusal"]["text"]))
    for name in sorted(os.listdir(PACKAGE)):
        if name.endswith("_test.mbt") or name.endswith("_wbtest.mbt"):
            source = read(os.path.join(PACKAGE, name))
            # A literal may be broken across lines by the formatter.
            for literal in re.findall(r'"((?:[^"\\]|\\\n|\\.)*)"', source, flags=re.S):
                if PREFIX in literal:
                    joined = literal.replace("\\\n", "")
                    if joined.startswith(PREFIX) or joined.startswith("Parse error: " + PREFIX):
                        texts.append((name, joined))
    for where, text in texts:
        if not text.startswith(PREFIX) and not text.startswith("Parse error: " + PREFIX):
            raise SystemExit("%s: a refusal text that does not start with %r: %r" % (where, PREFIX, text))
    # A test's literal may carry the library's variant name in front of the
    # codec's text; the codec's own text is what the skeleton is written on.
    return [(where, text[len("Parse error: "):] if text.startswith("Parse error: ") else text) for where, text in texts]


def main():
    raised = sites()
    texts = expected_texts()
    missing = 0
    combinators = 0
    covered_sites = 0
    for name, line, function, pattern in raised:
        if pattern is None:
            combinators += 1
            print("combinator  %s:%d %s(...)  the text is its caller's" % (name, line, function))
            continue
        matched = [where for where, text in texts if re.fullmatch(pattern, text, flags=re.S)]
        if matched:
            covered_sites += 1
        else:
            missing += 1
            print("MISSING     %s:%d %s  %s" % (name, line, function, pattern))
    distinct = len({pattern for _, _, _, pattern in raised if pattern is not None})
    print("raise sites: %d (%d distinct texts); with a test asserting their text: %d; combinators: %d; without a test: %d"
          % (len(raised), distinct, covered_sites, combinators, missing))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
