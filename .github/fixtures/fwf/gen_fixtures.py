"""Generate the reference corpus of fixed-width text files under
``fixtures/reference`` and the JSON sidecar beside each, then verify both.

The reference reader is ``read_fwf`` of pandas 3.1.1. It is asked two things
about every file. First the boundaries it inferred — read off its own
parser: ``read_fwf(path, iterator=True, ...)`` keeps the parser alive, and
``parser._engine.data.colspecs`` is the list its ``FixedWidthReader``
inferred (``parser._engine.colspecs`` still says ``'infer'``). Second the
cells: ``read_fwf(path, dtype=str, keep_default_na=False, header=None,
colspecs=<the same boundaries>)`` is the table of every cell it cut, and
the reader class itself — ``FixedWidthReader(lines, colspecs, None, None)``
iterated — is its cut of every physical line, the blank lines the table
drops included. Where ``read_fwf`` refuses a file, the boundaries come from
``FixedWidthReader(f, "infer", ...)`` — the very call the parser makes — and
the sidecar says so in ``colspecs_from``. Nothing in a sidecar comes from
the codec under test.

Every file is read under two or more *readings*: ``infer`` (the reference's
own inference, default options) and ``widths`` (a width a field, derived
from the ``infer`` boundaries: each field runs from where the one before it
ended), and for some files further readings — a smaller ``infer_nrows``, a
``skiprows``, a ``comment`` marker. A reading spells its ``options``
(``skiprows``, ``comment``, ``infer_nrows``), its ``widths`` where it has
them, the reference's refusal if it refused, and otherwise ``colspecs``,
``cut`` (one row a physical line), ``row_lines`` (which physical line each
row of ``rows`` is), ``rows`` (the ``dtype=str`` table) and ``table`` (the
default ``read_fwf`` table a user sees: names, dtypes, typed cells — for the
reader that later takes the header, the names, the null spellings and the
dtypes from this package's cells).

The files are generated deliberately, family by family (``cases`` below);
whatever draws at all draws from one ``random.Random(SEED)``. ``make`` also
checks two things about the reference and exits non-zero if either fails:
that its ``dtype=str`` rows are what its own comment and blank rules give
for its reader's cut of the lines each row comes from (``row_lines`` is
decided by those two rules, the parser's own methods, and ``rows`` is what
``read_fwf`` returned — two roads through the reference that must meet), and,
for a file rendered from a table, that the cells it reads are that table's.

``verify`` regenerates the corpus into a temporary directory and compares it
byte for byte with the one on disk, then re-reads every file on disk with the
reference and compares every reading with its sidecar; it exits non-zero on
a mismatch.

    uv run --no-project --with pandas python -I -X utf8 .github/fixtures/fwf/gen_fixtures.py make
    uv run --no-project --with pandas python -I -X utf8 .github/fixtures/fwf/gen_fixtures.py verify
"""
import json
import os
import random
import sys
import tempfile
from types import SimpleNamespace

import pandas as pd
from pandas.io.parsers.python_parser import FixedWidthFieldParser, FixedWidthReader, PythonParser

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
FIX = os.path.join(HERE, "reference")
# The repository's build directory, which nothing tracks, holds the logs of
# a run.
LOG = os.path.join(ROOT, "_build", "fwf_fixture_logs")

SEED = 20261128
DEFAULT_OPTIONS = {"skiprows": None, "comment": None, "infer_nrows": 100}


def log(text):
    print(text, flush=True)


def dumps(value, indent=0):
    """A sidecar as JSON a person can scan: an object a member to a line, a
    list of objects an element to a line, and any other list — the lines,
    the boundaries, a cut, a table's cells — compact on one line."""
    pad = " " * indent
    if isinstance(value, dict) and value:
        return "{\n" + ",\n".join(pad + " " + json.dumps(k) + ": " + dumps(v, indent + 1)
                                  for k, v in value.items()) + "\n" + pad + "}"
    if isinstance(value, list) and any(isinstance(v, dict) for v in value):
        return "[\n" + ",\n".join(pad + " " + dumps(v, indent + 1) for v in value) + "\n" + pad + "]"
    return json.dumps(value, ensure_ascii=False)


# ── the reference reader ─────────────────────────────────────────────


def parser_colspecs(path, widths, kw):
    """The boundaries the reference's parser used, read off the parser."""
    if widths is not None:
        reader = pd.read_fwf(path, iterator=True, widths=widths, **kw)
    else:
        reader = pd.read_fwf(path, iterator=True, **kw)
    try:
        return [[int(a), int(b)] for a, b in reader._engine.data.colspecs]
    finally:
        reader.close()


def colspecs_apart_from_table(path, options, widths):
    """The boundaries where ``read_fwf`` refuses the file: its own
    arithmetic from the widths, or — for an inference — what the reader
    class infers by the very call the parser makes."""
    if widths is not None:
        specs, col = [], 0
        for w in widths:
            specs.append([col, col + w])
            col += w
        return specs, "read_fwf's arithmetic from the widths; it refuses the file"
    try:
        with open(path, encoding="utf-8", newline=None) as f:
            reader = FixedWidthReader(
                f, "infer", None, options["comment"],
                set(options["skiprows"] or ()), options["infer_nrows"])
            specs = [[int(a), int(b)] for a, b in reader.colspecs]
        return specs, ("FixedWidthReader(f, 'infer', ...).colspecs, the parser's own "
                       "inference; read_fwf refuses the file")
    except Exception as e:  # noqa: BLE001 — the refusal is the fact
        return None, "none: the reader class refuses too (%s)" % type(e).__name__


def reference_cut(raw_lines, colspecs):
    """The reference reader's own cut of every physical line, blank lines
    included: the class the parser reads through, given the boundaries."""
    reader = FixedWidthReader(iter(raw_lines), [tuple(c) for c in colspecs], None, None)
    return [list(row) for row in reader]


def str_table(path, colspecs, kw):
    """The reference's ``dtype=str`` table with no header: every cell the
    text it cut, a blank line dropped; a cell that is not a ``str`` (a row
    the reference padded) is ``None``."""
    frame = pd.read_fwf(path, header=None, dtype=str, keep_default_na=False,
                        colspecs=[tuple(c) for c in colspecs], **kw)
    return [[c if isinstance(c, str) else None for c in row]
            for row in frame.itertuples(index=False, name=None)]


def kept_and_padded(cut, comment, width, kept):
    """Which lines the reference's table keeps, and the row it shows for
    each — by the reference's own two rules, called on the reader's cut of
    every non-skipped line. The comment rule is the parser's own method
    (``PythonParser._check_comments``) with the reading's marker and an
    empty null-spelling set, which is what ``keep_default_na=False`` leaves
    the parser: the first field holding the marker is cut at it — dropped
    whole when the marker is its first character — and the fields after it
    are gone. The blank rule is the fixed-width parser's own method
    (``FixedWidthFieldParser._remove_empty_lines``): a row whose every
    field is blank is dropped. A row the comment rule shortened is padded
    with empty cells to the layout's width, as the reference pads it.
    Answers the physical lines kept and their rows."""
    stand_in = SimpleNamespace(comment=comment, na_values=set())
    lines, rows = [], []
    for i in kept:
        seen = PythonParser._check_comments(stand_in, [cut[i]])[0]
        if FixedWidthFieldParser._remove_empty_lines(None, [seen]):
            lines.append(i)
            rows.append(seen + [""] * (width - len(seen)))
    return lines, rows


def default_table(path, kw):
    """The table a user sees: ``read_fwf`` with its defaults apart from the
    reading's options — names, dtypes and typed cells; a missing cell is
    ``None``."""
    frame = pd.read_fwf(path, **kw)
    clean = frame.astype(object).where(frame.notna(), None)
    return {"columns": [str(c) for c in frame.columns],
            "dtypes": [str(t) for t in frame.dtypes],
            "cells": [list(row) for row in clean.itertuples(index=False, name=None)]}


def read_reference(path, raw_lines, name, options, widths=None):
    """One reading of one file by the reference: everything the sidecar
    records about it."""
    opts = dict(DEFAULT_OPTIONS)
    opts.update(options)
    kw = {"infer_nrows": opts["infer_nrows"]}
    if opts["skiprows"] is not None:
        kw["skiprows"] = opts["skiprows"]
    if opts["comment"] is not None:
        kw["comment"] = opts["comment"]
    entry = {"name": name, "options": opts, "widths": widths, "refuses": None,
             "colspecs_from": None, "colspecs": None, "cut": None,
             "row_lines": None, "rows": None, "table": None}
    try:
        entry["colspecs"] = parser_colspecs(path, widths, kw)
        entry["colspecs_from"] = "parser._engine.data.colspecs"
    except Exception as e:  # noqa: BLE001 — the refusal is the fact
        entry["refuses"] = {"type": type(e).__name__, "message": str(e)}
        entry["colspecs"], entry["colspecs_from"] = colspecs_apart_from_table(path, opts, widths)
    if entry["colspecs"] is not None:
        entry["cut"] = reference_cut(raw_lines, entry["colspecs"])
    if entry["refuses"] is None:
        kept = [i for i in range(len(raw_lines)) if i not in (opts["skiprows"] or ())]
        entry["row_lines"], _ = kept_and_padded(entry["cut"], opts["comment"],
                                                len(entry["colspecs"]), kept)
        entry["rows"] = str_table(path, entry["colspecs"], kw)
        entry["table"] = default_table(path, kw)
    return entry


def check_reading(reading):
    """What is inconsistent in a reading the reference gave. ``rows`` —
    what ``read_fwf`` returned — must be what the reference's own rules
    give for the lines ``row_lines`` names: the reader's cut of each, under
    the comment rule, under the blank rule, padded. Two roads through the
    reference that must meet."""
    if reading["refuses"] is not None or reading["cut"] is None:
        return []
    options = reading["options"]
    kept = [i for i in range(len(reading["cut"])) if i not in (options["skiprows"] or ())]
    lines, expected = kept_and_padded(reading["cut"], options["comment"],
                                      len(reading["colspecs"]), kept)
    problems = []
    if lines != reading["row_lines"]:
        problems.append("the rules keep lines %r, the sidecar says %r" % (lines, reading["row_lines"]))
    if len(expected) != len(reading["rows"]):
        problems.append("the rules keep %d rows, read_fwf returned %d" % (len(expected), len(reading["rows"])))
    for i in range(min(len(expected), len(reading["rows"]))):
        got = [c if isinstance(c, str) else "" for c in reading["rows"][i]]
        if got != expected[i]:
            problems.append("row %d is from line %d: read_fwf shows %r, the reader's cut under the rules is %r"
                            % (i, lines[i], reading["rows"][i], expected[i]))
    return problems


# ── the families ─────────────────────────────────────────────────────


def render(table, gap=1, right=(), rstrip=False, sep=" "):
    """A table as fixed-width lines: a column as wide as its widest cell,
    text left-aligned and the columns in ``right`` right-aligned, ``gap``
    copies of ``sep`` between columns."""
    widths = [max(len(row[c]) for row in table) for c in range(len(table[0]))]
    lines = []
    for row in table:
        cells = [row[c].rjust(widths[c]) if c in right else row[c].ljust(widths[c])
                 for c in range(len(row))]
        line = (sep * gap).join(cells)
        lines.append(line.rstrip() if rstrip else line)
    return lines


WORDS = ["oak", "elm", "ash", "fir", "pine", "birch", "cedar", "maple", "spruce", "walnut"]
LETTERS = "abcdefghijklmnopqrstuvwxyz0123456789"


def grid_table(rng, rows=6):
    """A small table of a fixed shape: an id, a word, an amount and a flag."""
    return [["id", "name", "amount", "flag"]] + [
        [str(100 + i), rng.choice(WORDS), str(rng.randint(0, 99999)), rng.choice(["Y", "N"])]
        for i in range(rows)]


def ragged_table(rng):
    """A table whose columns have no common width: text of different
    lengths, numbers of different digit counts, two cells empty."""
    cities = ["Oslo", "Reykjavik", "San-Marino", "Brussels", "Porto", "Xi'an"]
    rows = [["city", "pop", "area", "density"]]
    for i, city in enumerate(cities):
        rows.append([city,
                     "" if i == 3 else str(rng.randint(1, 9_999_999)),
                     str(rng.randint(10, 999_999)),
                     "" if i == 1 else str(rng.randint(1, 9999))])
    return rows


def seeded_grid(rng):
    """A rigid grid whose every choice is the seed's: five columns of a
    random width, a random gap after each, and in each cell a random run of
    letters and digits, some cells left empty. Answers the table and its
    lines, each cut after its last character."""
    widths = [rng.randint(3, 9) for _ in range(5)]
    gaps = [rng.randint(1, 3) for _ in range(5)]
    rows = [["".join(rng.choice(LETTERS) for _ in range(widths[c])).upper() for c in range(5)]]
    for _ in range(12):
        row = []
        for c in range(5):
            n = 0 if rng.random() < 0.12 else rng.randint(1, widths[c])
            row.append("".join(rng.choice(LETTERS) for _ in range(n)))
        rows.append(row)
    lines = ["".join(row[c].ljust(widths[c] + gaps[c]) for c in range(5)).rstrip() for row in rows]
    return rows, lines


def cases():
    """Every file, family by family. A case names its file, its family, its
    lines (no terminators), the terminator the file is written with, what it
    pins, the table it was rendered from where its cells should read back
    as that table's (``None`` where they should not or there is none), and
    its readings beyond ``infer``."""
    out = []

    def add(file, family, lines, note, table=None, newline="\n", readings=()):
        out.append({"file": file, "family": family, "lines": lines, "note": note,
                    "table": table, "newline": newline, "readings": list(readings)})

    rng = random.Random(SEED)
    table = grid_table(rng)
    add("grid_one_space.txt", "grid", render(table, gap=1),
        "a classic rigid grid: four columns, one space between them, every line the same length", table)
    add("grid_two_spaces.txt", "grid", render(table, gap=2),
        "the same grid with two spaces between the columns", table)
    seeded, seeded_lines = seeded_grid(rng)
    add("grid_seeded.txt", "grid", seeded_lines,
        "a rigid grid drawn from the seed: five columns of random widths, a random gap after each, "
        "empty cells, every line cut after its last character", seeded)
    table = ragged_table(rng)
    add("ragged_short_cells.txt", "ragged", render(table, gap=2, right=(1, 2, 3)),
        "columns of ragged widths: numbers right-aligned and text left-aligned, so cells fall short of "
        "their field at one side or the other; two cells empty", table)
    add("ragged_single_space.txt", "ragged",
        [" ".join(row) for row in [["name", "age", "city"], ["Ada", "31", "Oslo"], ["Alan", "5", "Reykjavik"],
                                   ["Jo", "250", "Tokyo"], ["Anastasia", "104", "San Marino"]]],
        "one space between cells of different lengths, a cell with a space inside: columns whose "
        "content touches merge in the inference")

    wide = [["identifier", "description", "quantity"], ["7", "bolt", "12"], ["12", "nut", "340"],
            ["3", "washer", "5"]]
    add("wide_header.txt", "wide", render(wide, gap=2),
        "a header far wider than every cell: the fields are the header's", wide)
    cell = [["n", "s"], ["1", "abcdefghij"], ["2", "xy"], ["3", "z"]]
    add("wide_cell.txt", "wide", render(cell, gap=2),
        "a cell far wider than its header, inside the inference window", cell)
    late = [["n", "s"], ["1", "xy"], ["2", "ab"], ["3", "abcdefghijklmnop"], ["4", "pq"]]
    add("wide_cell_late.txt", "wide", render(late, gap=2),
        "a cell wider than anything above it, on the fourth line: read with the default window it widens "
        "the field; read with a window of three rows the reference truncates it",
        late, readings=[{"name": "infer:3", "options": {"infer_nrows": 3}}])

    add("indent.txt", "indent", ["    " + line for line in render(grid_table(rng), gap=1)],
        "four spaces of indentation on every line: they name no field")
    base = grid_table(rng)
    trailing = [line + " " * (2 * i % 7) for i, line in enumerate(render(base, gap=1))]
    trailing[2] += " " * 10
    add("trailing_spaces.txt", "trailing", trailing,
        "trailing spaces after the last cell, none to twelve of them", base)
    add("blank_lines.txt", "blanks",
        ["", "A  B", "1  2", "   ", "3333  4", "", "\t", "5  6", "   "],
        "blank lines before, between and after the rows, empty and whitespace-only; a blank line "
        "counts as a row of the inference window",
        readings=[{"name": "infer:3", "options": {"infer_nrows": 3}},
                  {"name": "infer:5", "options": {"infer_nrows": 5}}])
    add("tabs_inside.txt", "tabs",
        ["first\tlast   age", "firstlast      30", "fi\tla         4"],
        "a tab inside a field: another line has content across the same position, so the tab stays "
        "in the cell")
    tabbed = [["key", "value", "unit"], ["a", "12", "kg"], ["ratio", "0.5", "%"], ["b", "340", "m"],
              ["count", "7", ""]]
    add("tabs_as_separators.txt", "tabs", render(tabbed, sep="\t"),
        "tabs as separators: a tab between columns aligned across the lines, the last cell of the last "
        "line empty", tabbed)
    add("tabs_ragged.txt", "tabs", ["\t".join(row) for row in tabbed],
        "single tabs between cells of ragged widths: as with single spaces, the columns merge in the "
        "inference and a cell keeps its tab")
    middle = [["a", "b", "c"], ["1", "", "3"], ["4", "5", "6"], ["7", "", "9"]]
    add("empty_middle.txt", "empty", render(middle, gap=2),
        "empty fields in the middle of a line: the column exists through its header and its other cells",
        middle)
    ends = [["a", "b", "c"], ["1", "2", "3"], ["4", "", ""], ["", "5", ""]]
    add("empty_at_end.txt", "empty", render(ends, gap=2, rstrip=True),
        "empty fields at the end of a line, the line cut after its last cell, so the fields lie past "
        "its end; a line empty at both ends", ends)
    add("short_line.txt", "short",
        ["label     amount", "small     5", "tiny", "m", "a-very-long-label-name 77", "medium   123"],
        "lines shorter than the layout — four characters, one — beside a cell wider than the header")
    cjk = [["名前", "年齢", "都市"], ["田中太郎", "34", "東京"], ["Ünicode", "5", "Zürich"],
           ["Ωμέγα", "120", "Θήβα"], ["Москва", "7", "Ялта"]]
    add("unicode_header_cells.txt", "unicode", render(cjk, gap=2),
        "a header and cells outside ASCII: CJK, Latin with diacritics, Greek, Cyrillic — the boundaries "
        "count characters", cjk)
    non_ascii = [["col_a", "col_b", "col_c"], ["東京", "１２３", "naïve"], ["Αθήνα", "٤٥٦", "façade"],
                 ["Москва", "七八九", "žluťoučký"], ["ירושלים", "૭૮૯", "Přímý"]]
    add("unicode_ascii_header.txt", "unicode", render(non_ascii, gap=2),
        "an ASCII header and cells that are not: CJK, full-width, Arabic-Indic and Gujarati digits, "
        "Greek, Cyrillic, Hebrew, Latin with diacritics", non_ascii)
    astral = [["\U0001F600", "\U0001D11E", "\U00020000"], ["\U0001F680", "\U0001F4A9", "\U0001F1E6\U0001F1E7"],
              ["a\U0001F600b", "\U0001D400", "x"], ["\U00010437", "\U0001D11E\U0001D11E", "z"]]
    add("unicode_astral.txt", "unicode", render(astral, gap=2),
        "characters outside the Basic Multilingual Plane in the header and the cells — an emoji, a clef, "
        "a deseret letter, an ideograph of the second plane, a regional-indicator pair — each one "
        "character where UTF-16 spells two units", astral)
    combining = [["marks", "text"], ["0", "e"], ["1", "e\u0301"], ["5", "e\u0301\u0302\u0303\u0308\u0301"],
                 ["3", "\u1100\u1161\u11a8"], ["2", "\u0e01\u0e34\u0e48"], ["1", "\u0915\u094d\u200d\u0937"],
                 ["4", "q\u0301\u0323\u0308\u0330"]]
    add("unicode_combining.txt", "unicode", render(combining, gap=2),
        "fields of combining characters — a base under one to five marks, three Hangul jamo, a Thai "
        "vowel and tone mark, a Devanagari conjunct with a zero-width joiner — each code point one "
        "character, no grapheme cluster counted as one", combining)
    add("separator_only.txt", "separator_only",
        ["peerid   0x3, hexnodeid", "peerid   0x3, hexnodeid", "        ,", ":", ".", ";",
         "peerid   0x3, hexnodeid"],
        "the reference's own test shape — fields followed by a comma — beside lines whose only content "
        "is a comma, a colon, a dot or a semicolon: without a delimiter each is an ordinary character")
    add("one_column.txt", "one_column", ["value", "   12", " 1000", "    7", "12345", "   -3"],
        "a table of one column: numbers right-aligned in it, the leading spaces naming nothing")
    add("other_spaces.txt", "other_spaces",
        ["key   val", "x\xa0y  1", "x\u3000y  2", "\xa0", "\x0b", "z     3", "q\u202fr  4"],
        "characters that are whitespace to a strip and not to the reference reader — a no-break space, "
        "an ideographic space, a narrow one, a vertical tab — inside cells; the two lines that hold "
        "nothing else are cut with that character and dropped from the reference's table")
    preamble = ["Fixed-width extract of the ledger", "Run of 2026-11-28 at 09:30"] + \
        render([["A", "B", "C"], ["1", "2", "3"], ["4", "5", "6"]], gap=2)
    add("skiprows_preamble.txt", "skiprows", preamble,
        "two lines of preamble above a three-column table: read as it stands, then with the preamble "
        "skipped by its line numbers, then with every line skipped",
        readings=[{"name": "skiprows", "options": {"skiprows": [0, 1]}},
                  {"name": "skiprows_all", "options": {"skiprows": list(range(len(preamble)))}}])
    add("comment_lines.txt", "comment",
        ["Aaa  Bbb  Ccc", "# a note of some length", "1    2    3", "x#y  123  z", "# whole",
         "4    5    6", "4444 5555 6666"],
        "comment lines and a comment inside a field: read without a marker, then with '#' — a comment "
        "line counts as a row of the window and names nothing, as windows of five and six rows show "
        "against one of seven",
        readings=[{"name": "comment", "options": {"comment": "#"}},
                  {"name": "comment:5", "options": {"comment": "#", "infer_nrows": 5}},
                  {"name": "comment:6", "options": {"comment": "#", "infer_nrows": 6}},
                  {"name": "comment:7", "options": {"comment": "#", "infer_nrows": 7}}])
    crlf = grid_table(rng)
    add("crlf_line_endings.txt", "line_endings", render(crlf, gap=1),
        "a grid written with CRLF line endings: the reference translates them on reading",
        crlf, newline="\r\n")
    add("cr_line_endings.txt", "line_endings", render(grid_table(rng), gap=1),
        "a grid written with carriage returns alone as its line endings: the reference translates "
        "them on reading", newline="\r")
    add("all_blank.txt", "refusal", ["   ", "\t", "  \t  ", ""],
        "four lines and no character that is not a separator: the reference's inference names no field "
        "and its reader refuses the file")
    add("empty.txt", "refusal", [], "no line at all: the reference reader refuses the file")
    return out


# ── the sweep ────────────────────────────────────────────────────────

SWEEP_REPLACEMENT_FILE = "unicode_ascii_header.txt"
SWEEP_PREFIX_FILE = "grid_one_space.txt"
# What a single-character replacement writes in place of the character: the
# four separators, characters that make a comment, a delimiter or a name,
# and characters of one, two and three bytes.
SWEEP_ALPHABET = [" ", "\t", "\r", "\n", "#", ",", ":", "0", "9", "A", "z", "\u00a0", "\u4e1c",
                  "\u0301", "\U0001F600", "\uff11"]
# Where a random character of the random texts is drawn: control
# characters (tab, line feed, vertical tab, form feed, carriage return),
# ASCII, Latin-1, combining marks, Greek, CJK, and the second plane.
SWEEP_RANGES = [(0x09, 0x0E), (0x20, 0x7F), (0xA0, 0x100), (0x300, 0x370), (0x370, 0x400),
                (0x4E00, 0x9FA6), (0x10000, 0x10400)]
SEED_REPLACEMENTS = 0x4657463230323631
SEED_RANDOM = 0x4657463230323632
MASK64 = (1 << 64) - 1


class SplitMix:
    """The tests' generator (splitmix64), step for step: the cases the tests
    draw are the cases recorded here."""

    def __init__(self, state):
        self.state = state

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)


def random_point(rng):
    """A character drawn as the tests draw one: a range, then an offset in it."""
    low, high = SWEEP_RANGES[rng.next() % len(SWEEP_RANGES)]
    return chr(low + rng.next() % (high - low))


def ask_reference(lines):
    """What the reference says about a text of ``lines``: written to a file
    and read like every other file — the boundaries its parser inferred or
    its refusal, and its reader's cut of every line."""
    fd, path = tempfile.mkstemp(suffix=".txt")
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write("".join(line + "\n" for line in lines))
    with open(path, encoding="utf-8", newline=None) as f:
        raw_lines = f.readlines()
    entry = {"lines": [line[:-1] if line.endswith("\n") else line for line in raw_lines],
             "refuses": None, "colspecs": None, "cut": None}
    try:
        entry["colspecs"] = parser_colspecs(path, None, {"infer_nrows": 100})
    except Exception as e:  # noqa: BLE001 — the refusal is the fact
        entry["refuses"] = {"type": type(e).__name__, "message": str(e)}
        entry["colspecs"], _ = colspecs_apart_from_table(path, DEFAULT_OPTIONS, None)
    if entry["colspecs"] is not None:
        entry["cut"] = reference_cut(raw_lines, entry["colspecs"])
    os.remove(path)
    return entry


def sweep_text(by_name):
    """``sweep.json``: the malformed-input sweeps the tests run, replayed
    here through the reference. Every prefix of one file's lines; 200 copies
    of another with one character replaced; 200 random texts — each as the
    tests draw them, with what the reference made of each."""
    lines = by_name[SWEEP_REPLACEMENT_FILE]["lines"]
    rng = SplitMix(SEED_REPLACEMENTS)
    replacements = []
    for _ in range(200):
        line = rng.next() % len(lines)
        at = rng.next() % len(lines[line])
        with_ = rng.next() % len(SWEEP_ALPHABET)
        mutated = list(lines)
        mutated[line] = lines[line][:at] + SWEEP_ALPHABET[with_] + lines[line][at + 1:]
        replacements.append({"line": line, "at": at, "with": with_, **ask_reference(mutated)})
    whole = by_name[SWEEP_PREFIX_FILE]["lines"]
    prefixes = [{"count": count, **ask_reference(whole[:count])} for count in range(len(whole) + 1)]
    rng = SplitMix(SEED_RANDOM)
    randoms = []
    for _ in range(200):
        drawn = []
        for _ in range(1 + rng.next() % 4):
            length = rng.next() % 24
            drawn.append("".join(random_point(rng) for _ in range(length)))
        randoms.append(ask_reference(drawn))
    return {
        "note": "the sweeps the malformed-input tests run, drawn as they draw them: the boundaries the "
                "reference inferred for each or its refusal, and its reader's cut of every line",
        "replacement_file": SWEEP_REPLACEMENT_FILE, "prefix_file": SWEEP_PREFIX_FILE,
        "alphabet": SWEEP_ALPHABET,
        # the seeds in hexadecimal: a JSON number is read as a double, which
        # does not hold a 64-bit seed exactly
        "seeds": {"replacements": "0x%016x" % SEED_REPLACEMENTS,
                  "random": "0x%016x" % SEED_RANDOM},
        "replacements": replacements, "prefixes": prefixes, "random": randoms,
    }


# ── make and verify ──────────────────────────────────────────────────


def widths_from(colspecs):
    """A width a field from the inferred boundaries: each field runs from
    where the one before it ended, the first from the line's first
    character — so a gap the inference left open before a field is part of
    its width and is cut from the cell."""
    widths, edge = [], 0
    for _, end in colspecs:
        widths.append(end - edge)
        edge = end
    return widths


def build(target, quiet=False):
    """Write the corpus into ``target``: a file and a sidecar for each case
    and ``index.json``. Answers the index, the problems found among the
    reference's own answers, and the number of cells the reference cut."""
    os.makedirs(target, exist_ok=True)
    for name in os.listdir(target):
        os.remove(os.path.join(target, name))
    index, problems, cells = [], [], 0
    for case in cases():
        path = os.path.join(target, case["file"])
        text = case["newline"].join(case["lines"])
        if case["lines"]:
            text += case["newline"]
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        with open(path, encoding="utf-8", newline=None) as f:
            raw_lines = f.readlines()
        lines = [line[:-1] if line.endswith("\n") else line for line in raw_lines]
        if lines != case["lines"]:
            problems.append("%s: the reference reads the lines %r, the file was written as %r"
                            % (case["file"], lines, case["lines"]))
        readings = [read_reference(path, raw_lines, "infer", {})]
        if readings[0]["colspecs"]:
            widths = widths_from(readings[0]["colspecs"])
        else:
            # the inference names no field: a fixed pair of widths, which
            # the reference refuses the file under as well
            widths = [4, 3]
        readings.append(read_reference(path, raw_lines, "widths", {}, widths))
        for more in case["readings"]:
            readings.append(read_reference(path, raw_lines, more["name"], more["options"]))
        for reading in readings:
            problems += ["%s / %s: %s" % (case["file"], reading["name"], one)
                         for one in check_reading(reading)]
            cells += sum(len(row) for row in (reading["cut"] or []))
        if case["table"] is not None and readings[0]["refuses"] is None:
            got = [[c for c in row] for row in readings[0]["rows"]]
            want = [list(row) for row in case["table"]]
            if got != want:
                problems.append("%s: the reference reads %r, the file was rendered from %r"
                                % (case["file"], got, want))
        sidecar = {
            "file": case["file"], "family": case["family"], "origin": "generated",
            "generator": "tools/gen_fixtures.py", "seed": SEED,
            "reference": {"implementation": "pandas", "version": pd.__version__,
                          "function": "read_fwf"},
            "newline": case["newline"], "note": case["note"],
            "roundtrip": case["table"] is not None,
            "lines": case["lines"], "readings": readings,
        }
        with open(path + ".json", "w", encoding="utf-8", newline="\n") as f:
            f.write(dumps(sidecar) + "\n")
        index.append({"file": case["file"], "family": case["family"], "seed": SEED,
                      "refuses": readings[0]["refuses"] is not None,
                      "lines": len(case["lines"]), "readings": len(readings),
                      "cells": sum(len(row) for r in readings for row in (r["cut"] or []))})
        if not quiet:
            log("  %-26s %2d lines, %d readings%s — %s"
                % (case["file"], len(case["lines"]), len(readings),
                   "; the reference refuses the inference" if readings[0]["refuses"] else "",
                   case["note"]))
    with open(os.path.join(target, "sweep.json"), "w", encoding="utf-8", newline="\n") as f:
        f.write(dumps(sweep_text({case["file"]: case for case in cases()})) + "\n")
    with open(os.path.join(target, "index.json"), "w", encoding="utf-8", newline="\n") as f:
        f.write(dumps(index) + "\n")
    return index, problems, cells


def make():
    log("pandas %s; seed %d" % (pd.__version__, SEED))
    log("the corpus, family by family:")
    index, problems, cells = build(FIX)
    names = os.listdir(FIX)
    size = sum(os.path.getsize(os.path.join(FIX, name)) for name in names)
    sidecars = sum(os.path.getsize(os.path.join(FIX, name)) for name in names if name.endswith(".json"))
    log("the corpus: wrote %d files and %d readings; the reference cut %d cells in them; "
        "it refuses the inference on %d files"
        % (len(index), sum(item["readings"] for item in index), cells,
           sum(1 for item in index if item["refuses"])))
    log("bytes on disk: %d, of which %d are the sidecars and the index" % (size, sidecars))
    for problem in problems:
        log("MISMATCH " + problem)
    log("problems: %d" % len(problems))
    return 1 if problems else 0


def verify():
    problems, mismatches = [], 0
    # 1. The corpus on disk is what the seed writes: the same files, the
    #    same bytes, data and sidecars alike.
    with tempfile.TemporaryDirectory() as temp:
        _, found, _ = build(temp, quiet=True)
        problems += found
        regenerated = sorted(os.listdir(temp))
        on_disk = sorted(os.listdir(FIX))
        if regenerated != on_disk:
            mismatches += 1
            log("MISMATCH the directory holds %r, the seed writes %r" % (on_disk, regenerated))
        for name in regenerated:
            with open(os.path.join(temp, name), "rb") as f:
                again = f.read()
            try:
                with open(os.path.join(FIX, name), "rb") as f:
                    mine = f.read()
            except OSError:
                mine = None
            if again != mine:
                mismatches += 1
                log("MISMATCH %s: the file on disk is not what the seed writes" % name)
        log("files regenerated and compared byte for byte: %d; different: %d"
            % (len(regenerated), mismatches))
    # 2. The reference reads the files on disk as the sidecars on disk say.
    with open(os.path.join(FIX, "index.json"), encoding="utf-8") as f:
        index = json.load(f)
    cells = table_cells = refused = readings = 0
    for item in index:
        path = os.path.join(FIX, item["file"])
        with open(path + ".json", encoding="utf-8") as f:
            sidecar = json.load(f)
        with open(path, encoding="utf-8", newline=None) as f:
            raw_lines = f.readlines()
        lines = [line[:-1] if line.endswith("\n") else line for line in raw_lines]
        if lines != sidecar["lines"]:
            mismatches += 1
            log("MISMATCH %s: the lines on disk are not the sidecar's" % item["file"])
        for recorded in sidecar["readings"]:
            readings += 1
            again = read_reference(path, raw_lines, recorded["name"], recorded["options"],
                                   recorded["widths"])
            if again != recorded:
                mismatches += 1
                log("MISMATCH %s / %s: the reference reads the file differently from the sidecar"
                    % (item["file"], recorded["name"]))
            problems += ["%s / %s: %s" % (item["file"], recorded["name"], one)
                         for one in check_reading(recorded)]
            cells += sum(len(row) for row in (recorded["cut"] or []))
            table_cells += sum(len(row) for row in (recorded["rows"] or []))
            if recorded["refuses"] is not None:
                refused += 1
    log("reference files: %d; readings re-read with the reference: %d; readings the reference refuses: %d"
        % (len(index), readings, refused))
    log("cells the reference cut, compared with the sidecars: %d; cells of its tables: %d"
        % (cells, table_cells))
    log("readings that differ from their sidecars: %d" % mismatches)
    log("sidecar rows that are not the reference's own cut of their lines: %d" % len(problems))
    return 1 if mismatches or problems else 0


if __name__ == "__main__":
    os.makedirs(LOG, exist_ok=True)
    step = sys.argv[1] if len(sys.argv) > 1 else ""
    sys.exit(make() if step == "make" else verify() if step == "verify" else 2)
