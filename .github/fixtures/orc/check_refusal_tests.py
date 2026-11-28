"""Prove that every refusal the codec can raise has a test asserting its
message.

Every raise site in the package's production sources — a call on the two
functions that build a refusal, with the text it names the file by — is
read as a skeleton: the words of its literal, each interpolation standing
for anything. A site is covered when a sidecar's `message` matches its
skeleton; the package's test over the corpus asserts, for every refused
file, that the codec answers exactly that text, so a matching message is
a test of the site. A string literal that starts with `orc: ` in a test
file counts too: the tests compare those for equality. A site whose text
is a caller's (an argument passed through) is a combinator and is listed
apart. Exit non-zero on a site without a test.

    uv run --no-project python -I -X utf8 tools/check_refusal_tests.py
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
PACKAGE = os.path.join(ROOT, "internal", "orc")
FIXTURES = os.path.join(HERE, "reference")
BUILDERS = ("bad", "refuse", "bad_at")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def strip_comments(text):
    """The source with its `//` comments blanked, so a call named in a
    comment is not taken for one."""
    return re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), text)


def arguments(text, open_at):
    """The argument strings of a call whose opening parenthesis is at
    `open_at`, split at the top-level commas; a trailing comma's empty
    argument is dropped."""
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
    """Every raise site: (file, line, function, pattern or None). A
    definition of the builders is no site, and a call that passes a
    caller's text on is a forwarder, its pattern `None`. The pattern is
    the whole message as the builder spells it: a `refuse` names the file
    by its words alone, a `bad` prefixes the byte, and a cursor's adds
    what the bytes are."""
    found = []
    for name in sorted(os.listdir(PACKAGE)):
        if not name.endswith(".mbt") or name.endswith("_test.mbt") or name.endswith("_wbtest.mbt"):
            continue
        text = strip_comments(read(os.path.join(PACKAGE, name)))
        for m in re.finditer(r"\b(bad|refuse|bad_at)\(", text):
            before = text[:m.start()].rstrip()
            if before.endswith("fn"):
                continue
            function = m.group(1)
            args, _ = arguments(text, m.end() - 1)
            # the message: the first argument of `refuse`, the last of the rest
            arg = args[0] if function == "refuse" else args[-1]
            literal = literal_parts(arg)
            line = text.count("\n", 0, m.start()) + 1
            if literal is None:
                found.append((name, line, function, None))
                continue
            pattern = skeleton(literal)
            if function == "refuse":
                whole = pattern
            elif text[m.start() - 1] == ".":
                whole = r"byte \d+(?:: | of the inflated ).*: " + pattern
            else:
                whole = r"byte \d+: " + pattern
            found.append((name, line, function, whole))
    return found


def expected_texts():
    """The refusal texts the tests assert, without the `orc: ` every one
    starts with: every sidecar's message, and every `orc: ` literal in a
    test file."""
    texts = []
    for name in sorted(os.listdir(FIXTURES)):
        if name.endswith(".orc.json"):
            sidecar = json.loads(read(os.path.join(FIXTURES, name)))
            if sidecar.get("codec") == "refuses":
                texts.append((name[:-5], sidecar["message"]))
    for name in sorted(os.listdir(PACKAGE)):
        if name.endswith("_test.mbt") or name.endswith("_wbtest.mbt"):
            for literal in re.findall(r'"(orc: [^"\n]*)"', read(os.path.join(PACKAGE, name))):
                # the prefix itself, which a test checks for, is no text
                if len(literal) > len("orc: "):
                    texts.append((name, literal))
    for where, text in texts:
        if not text.startswith("orc: ") or len(text) < 6:
            raise SystemExit("%s: a refusal text that does not start with \"orc: \": %r" % (where, text))
    return [(where, text[len("orc: "):]) for where, text in texts]


def main():
    raised = sites()
    texts = expected_texts()
    missing = 0
    combinators = 0
    for name, line, function, pattern in raised:
        if pattern is None:
            combinators += 1
            print("combinator  %s:%d %s(...)  the text is its caller's" % (name, line, function))
            continue
        matched = [where for where, text in texts if re.fullmatch(pattern, text, flags=re.S)]
        if matched:
            print("covered     %s:%d %s  by %s" % (name, line, function, matched[0]))
        else:
            missing += 1
            print("MISSING     %s:%d %s  %s" % (name, line, function, pattern))
    print("raise sites: %d; with a test asserting their text: %d; combinators: %d; without a test: %d"
          % (len(raised), len(raised) - combinators - missing, combinators, missing))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
