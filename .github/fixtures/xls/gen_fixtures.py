"""Generate the reference corpus of .xls workbooks under
``.github/fixtures/xls/reference`` and the JSON sidecar beside each, then verify both.

``make`` writes the corpus in three parts. The workbooks the reference
writer wrote (``xlwt_*.xls``); the workbooks built record by record with
``xlsbuild.py`` for what the writer never spells (``syn_*.xls``); and the
files broken in one place each (``broken_*.xls``), each with the refusal
it must meet. A sidecar holds what the reference reader itself got from
its file: its sheets in workbook order, the date mode, and every cell that
is not empty — spelled ``["T", row, col, text]``, ``["B", row, col,
boolean]``, ``["N", row, col, 64 bits of the double, format index, format
code, cell type]`` or ``["E", row, col, text]``, a number's format index
and code being the reference reader's own. Two cells are the generator's
word against the reader's and are marked so: a formula whose cached value
is the blank string, which the reader answers as an empty text and the
codec as no cell (``["T", row, col, "", "blank"]``), and a continued LABEL
record, which the reader truncates. A hand-built workbook's plan — what
the encoder meant to write — is compared with what the reader read, cell
for cell, at make time. The second reader, the dataframe library riding
the first, is compared with the sidecar too.

``verify`` re-reads every file with both readers and compares every cell
with the sidecar; it exits non-zero on a mismatch.

``sweep`` (which ``make`` ends with) replays the malformed-input test's
replacement sweep — the same seeded draws, of the same two files — through
the reference reader and records in ``sweep.json``, for every copy, the
cells it got or its refusal, so that a copy the codec still reads is held
to what the reader read in it.

    uv run --no-project --with xlwt --with xlrd --with pandas --with olefile python -I -X utf8 .github/fixtures/xls/gen_fixtures.py make
    uv run --no-project --with xlwt --with xlrd --with pandas --with olefile python -I -X utf8 .github/fixtures/xls/gen_fixtures.py verify
    uv run --no-project --with xlwt --with xlrd python -I -X utf8 .github/fixtures/xls/gen_fixtures.py sweep
"""
import io
import json
import math
import os
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import synthetic as S  # noqa: E402
import xlsbuild as B  # noqa: E402

import warnings  # noqa: E402
warnings.filterwarnings("ignore", message="The xlrd engine is deprecated")

import olefile  # noqa: E402
import pandas as pd  # noqa: E402
import xlrd  # noqa: E402
import xlwt  # noqa: E402

B_ = B
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
FIX = os.path.join(HERE, "reference")
LOG = os.path.join(ROOT, "_build", "xls_fixture_logs")
LIMIT = 1_500_000

TALLY = {"plan_cells": 0, "compared": 0, "deviating": 0, "blank": 0}


def second_stats():
    """Counters of the second reader's comparison, as `compare_pandas`
    keeps them."""
    return {"second_agreed": 0, "mismatch": 0, "dates": 0, "errors": 0, "blank": 0,
            "nonfinite": 0, "absent": 0, "no_sheet": 0, "skipped": 0}


SECOND = second_stats()


def log(text):
    print(text, flush=True)


# ── the reference readers ────────────────────────────────────────────

def open_xlrd(path):
    """The reference reader's book, or the error it refused with. What it
    has to say on the way is kept out of the log."""
    with open(path, "rb") as f:
        return open_xlrd_data(f.read())


def open_xlrd_data(data):
    """The reference reader's book for the bytes `data`, or the error it
    refused with."""
    quiet = io.StringIO()
    try:
        book = xlrd.open_workbook(file_contents=data, formatting_info=True, logfile=quiet)
    except Exception as e:  # noqa
        return None, "%s: %s" % (type(e).__name__, e)
    return book, None


def workbook_stream(path):
    """The workbook stream, as the reference reader's own container code
    locates it: None for a file that is no compound file or holds no
    workbook."""
    with open(path, "rb") as f:
        return workbook_stream_data(f.read())


def workbook_stream_data(data):
    """`workbook_stream` for bytes already in memory."""
    if data[:8] != xlrd.compdoc.SIGNATURE:
        return None
    try:
        cd = xlrd.compdoc.CompDoc(data, logfile=io.StringIO())
        for qname in ["Workbook", "Book"]:
            mem, base, length = cd.locate_named_stream(qname)
            if mem:
                return mem[base:base + length]
    except Exception:  # noqa
        return None
    return None


def worksheet_positions(stream):
    """Where the BOUNDSHEET records of the worksheet kind place their
    sheets, in workbook order — the order the reference reader lists."""
    out = []
    for rid, body, _ in B.records(stream):
        if rid == B.EOF:
            break
        if rid == B.BOUNDSHEET and body[5] == 0:
            out.append(struct.unpack_from("<i", body)[0])
    return out


def reference_view(book, stream):
    """What the reference reader got: the sheet names, the date mode, and
    the cells of each sheet that are not empty, in row-then-column order.
    A formula caching the blank string is the reader's empty text, marked
    as the codec's absent cell."""
    positions = worksheet_positions(stream)
    blanks = B.blank_formulas(stream)
    grids = []
    names = []
    for sheet, position in zip(book.sheets(), positions):
        names.append(sheet.name)
        cells = []
        for r in range(sheet.nrows):
            for c in range(sheet.ncols):
                cell = sheet.cell(r, c)
                kind = cell.ctype
                if kind in (0, 6):
                    continue
                if kind == 1:
                    if cell.value == "" and (position, r, c) in blanks:
                        cells.append(["T", r, c, "", "blank"])
                        TALLY["blank"] += 1
                    else:
                        cells.append(["T", r, c, cell.value])
                elif kind in (2, 3):
                    xf = book.xf_list[cell.xf_index]
                    fmt = book.format_map.get(xf.format_key)
                    cells.append(["N", r, c, S.bits(cell.value), xf.format_key,
                                  fmt.format_str if fmt else None, kind])
                elif kind == 4:
                    cells.append(["B", r, c, bool(cell.value)])
                else:
                    cells.append(["E", r, c, xlrd.biffh.error_text_from_code.get(
                        cell.value, "#UNKNOWN(%d)" % cell.value)])
        grids.append({"sheet": sheet.name, "cells": cells})
    return {"sheets": names, "datemode": book.datemode, "grids": grids}


def open_pandas(path):
    """The second reader's sheets — the dataframe library riding the first
    reader — or the error it refused with."""
    try:
        sheets = pd.read_excel(path, engine="xlrd", sheet_name=None, header=None)
    except Exception as e:  # noqa
        return None, "%s: %s" % (type(e).__name__, e)
    return sheets, None


def same(a, b):
    """Whether two cell spellings spell one cell: a number by its bits and
    its format, a text by its characters and its blank mark."""
    if a[0] != b[0] or a[1:3] != b[1:3]:
        return False
    if a[0] == "N":
        return a[3:6] == b[3:6]
    return a[3] == b[3] and a[4:] == b[4:]


def compare(plan, view, skip=frozenset(), where=""):
    """Compare a hand-built workbook's plan with what the reference reader
    read of it, sheet by sheet and cell for cell, past the cells in
    `skip`. Answers how many cells were compared; stops the generator on
    the first difference."""
    names = [sheet["sheet"] for sheet in plan["sheets"]]
    if names != view["sheets"]:
        raise SystemExit("%s: the plan names the sheets %r, the reference reader %r"
                         % (where, names, view["sheets"]))
    if plan["datemode"] != view["datemode"]:
        raise SystemExit("%s: the plan's date mode is %d, the reader's %d"
                         % (where, plan["datemode"], view["datemode"]))
    compared = 0
    for mine, theirs in zip(plan["sheets"], view["grids"]):
        a, b = mine["cells"], theirs["cells"]
        if len(a) != len(b):
            raise SystemExit("%s, sheet %r: the plan holds %d cells, the reader %d"
                             % (where, mine["sheet"], len(a), len(b)))
        for planned, read in zip(a, b):
            if (mine["sheet"], planned[1], planned[2]) in skip:
                continue
            if not same(planned, read):
                raise SystemExit("%s, sheet %r: the plan wrote %r, the reference reader read %r"
                                 % (where, mine["sheet"], planned[:4], read[:4]))
            compared += 1
    return compared


def plain(value):
    """A cell of the second reader's frame as a Python value: its columns
    are typed, so a whole number comes back an integer and a boolean beside
    numbers a float."""
    return value.item() if hasattr(value, "item") and not isinstance(value, (str, bytes)) else value


def compare_pandas(sheets, grids, where, stats, skip=frozenset()):
    """Compare the second reader's cells with a sidecar's by value: a text,
    a boolean and a plain number cell by cell, a number being the same
    whether the second reader typed its column integers or floats, and a
    boolean the same when it typed the column numbers. A date-formatted
    number the second reader converts itself, an error and a blank it
    nulls, and a number that is not finite it nulls, are counted; the
    cells in `skip` — where the first reader reads otherwise by design —
    are passed over. `stats` is added to."""
    for grid in grids:
        frame = sheets.get(grid["sheet"])
        if frame is None:
            stats["no_sheet"] += 1
            continue
        rows, cols = frame.shape
        for cell in grid["cells"]:
            if (grid["sheet"], cell[1], cell[2]) in skip:
                stats["skipped"] += 1
                continue
            if cell[1] >= rows or cell[2] >= cols:
                stats["absent"] += 1
                continue
            value = plain(frame.iat[cell[1], cell[2]])
            kind = cell[0]
            if kind == "N":
                number = struct.unpack("<d", struct.pack("<Q", int(cell[3], 16)))[0]
                if not math.isfinite(number):
                    stats["nonfinite"] += 1
                elif len(cell) > 6 and cell[6] == 3:
                    stats["dates"] += 1
                elif type(value) in (int, float) and struct.pack("<d", float(value)) == struct.pack("<d", number):
                    stats["second_agreed"] += 1
                else:
                    stats["mismatch"] += 1
                    log("MISMATCH %s, %s, (%d,%d): the sidecar a number %r, the second reader %r"
                        % (where, grid["sheet"], cell[1], cell[2], number, value))
            elif kind == "T":
                if len(cell) > 4:
                    stats["blank"] += 1
                elif isinstance(value, str) and value == cell[3]:
                    stats["second_agreed"] += 1
                elif cell[3] == "" and isinstance(value, float) and math.isnan(value):
                    stats["blank"] += 1
                else:
                    stats["mismatch"] += 1
                    log("MISMATCH %s, %s, (%d,%d): the sidecar a text %r, the second reader %r"
                        % (where, grid["sheet"], cell[1], cell[2], cell[3][:40], value))
            elif kind == "B":
                same_value = (type(value) is bool and value == cell[3]) or (
                    type(value) in (int, float) and value == (1 if cell[3] else 0))
                if same_value:
                    stats["second_agreed"] += 1
                else:
                    stats["mismatch"] += 1
                    log("MISMATCH %s, %s, (%d,%d): the sidecar a boolean %r, the second reader %r"
                        % (where, grid["sheet"], cell[1], cell[2], cell[3], value))
            else:
                stats["errors"] += 1


def olefile_streams(path):
    """What the compound-file reader olefile finds: None when it refuses
    the file, else the streams it lists by name and length. A file of
    4096-byte sectors is past what it reads."""
    try:
        ole = olefile.OleFileIO(path)
    except Exception as e:  # noqa
        return None
    try:
        return {"/".join(name): ole.get_size(name) for name in ole.listdir()
                if ole.get_type(name) == olefile.STGTY_STREAM}
    finally:
        ole.close()


# ── the sidecars ─────────────────────────────────────────────────────

def write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def dump(path, entry):
    lines = ["{"]
    items = list(entry.items())
    for k, (key, value) in enumerate(items):
        comma = "," if k < len(items) - 1 else ""
        if key != "grids":
            lines.append(" " + json.dumps(key) + ": " + json.dumps(value, ensure_ascii=False) + comma)
            continue
        lines.append(' "grids": [')
        for i, grid in enumerate(value):
            cells = ",".join(json.dumps(c, ensure_ascii=False) for c in grid["cells"])
            head = json.dumps({"sheet": grid["sheet"]}, ensure_ascii=False)[:-1]
            lines.append("  " + head + ', "cells": [' + cells + "]}" + ("" if i == len(value) - 1 else ","))
        lines.append(" ]" + comma)
    lines.append("}")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def sound_sidecar(name, data, origin, writer, note, plan=None, source="reference",
                  skip=frozenset(), deviations=None, extra=None):
    """Write one sound file and its sidecar; answer the sidecar's entry in
    the index."""
    path = os.path.join(FIX, name)
    write(path, data)
    entry = {"file": name, "origin": origin, "writer": writer, "note": note,
             "bytes": len(data), "codec": "reads"}
    book, error = open_xlrd(path)
    stream = workbook_stream(path) if book else None
    entry["reference_opens"] = book is not None
    if book is None:
        entry["reference_error"] = error
    view = reference_view(book, stream) if book else None
    if plan is not None:
        TALLY["plan_cells"] += sum(len(sheet["cells"]) for sheet in plan["sheets"])
        if view is not None:
            TALLY["compared"] += compare(plan, view, skip, name)
            TALLY["deviating"] += len(skip)
    if source == "reference":
        if view is None:
            raise SystemExit("%s: the reference reader refuses a file its sidecar takes from it: %s"
                             % (name, error))
        sheets, datemode, grids = view["sheets"], view["datemode"], view["grids"]
    else:
        sheets = [sheet["sheet"] for sheet in plan["sheets"]]
        datemode = plan["datemode"]
        grids = plan["sheets"]
    entry["sidecar_source"] = "reference" if source == "reference" else "generator"
    if skip:
        entry["first_reader_differs"] = sorted(list(k) for k in skip)
    if deviations:
        entry["deviations"] = deviations
    entry["sheets"] = sheets
    entry["datemode"] = datemode
    count = len(sheets)
    entry["out_of_range"] = [count, count + 1, -1]
    entry["grids"] = grids
    entry["cells"] = sum(len(grid["cells"]) for grid in grids)
    second, error2 = open_pandas(path)
    entry["second_reader_opens"] = second is not None
    if second is None:
        entry["second_reader_error"] = error2
    else:
        compare_pandas(second, grids, name, SECOND, skip)
    streams = olefile_streams(path)
    entry["compound_reader"] = "refuses" if streams is None else "opens"
    if extra:
        entry.update(extra)
    dump(path + ".json", entry)
    return {key: entry[key] for key in ("file", "origin", "bytes", "codec", "cells")} | {"note": note}


def broken_sidecar(spec):
    """Write one broken file and its sidecar: the variant and the text of
    the refusal the codec owes it, and what the reference readers do."""
    name = spec["name"]
    path = os.path.join(FIX, name)
    write(path, spec["data"])
    book, error = open_xlrd(path)
    second, error2 = open_pandas(path)
    streams = olefile_streams(path)
    entry = {"file": name, "origin": "synthetic", "writer": "tools/xlsbuild.py",
             "note": spec["note"], "bytes": len(spec["data"]), "codec": "refuses",
             "refusal": spec["refusal"], "message": spec["message"],
             "reference_opens": book is not None}
    if book is not None:
        entry["reference_sheets"] = book.sheet_names()
    else:
        entry["reference_error"] = error
    entry["second_reader_opens"] = second is not None
    if second is None:
        entry["second_reader_error"] = error2
    entry["compound_reader"] = "refuses" if streams is None else "opens"
    dump(path + ".json", entry)
    return {key: entry[key] for key in ("file", "origin", "bytes", "codec")} | {
        "refusal": spec["refusal"], "note": spec["note"]}


# ── the workbooks the reference writer wrote ─────────────────────────

def style(code):
    return xlwt.easyxf(num_format_str=code)


#: The built-in date and time formats by the reference writer's own
#: spelling of them, which it maps to their ids 14 to 22 and 45 to 47.
BUILTIN_DATES = ["M/D/YY", "D-MMM-YY", "D-MMM", "MMM-YY", "h:mm AM/PM",
                 "h:mm:ss AM/PM", "h:mm", "h:mm:ss", "M/D/YY h:mm", "mm:ss",
                 "[h]:mm:ss", "mm:ss.0"]
CUSTOM = ["General", "0", "0.00", "#,##0.00", "0%", "0.00E+00", "@",
          "yyyy-mm-dd", "d/m/yyyy", "[$-409]d-mmm-yyyy", "yyyy\"年\"mm\"月\"dd\"日\"",
          "[h]:mm:ss", "[m]:ss", "h:mm:ss.000", "dddd", "0.000",
          "#,##0.00;[Red]-#,##0.00", "\\@", "\"Yes\";\"Yes\";\"No\"", "0.00 \"kg\"",
          "[<=9999999]###-####;(###) ###-####", "mmm-yy", "0.0,,"]
SERIALS = [1, 59, 60, 61, 25569, 43831, 43831.52425925926, 2958465.9999884,
           0.5, 0.9999999, -3.5, 0.0]


def written():
    """The reference writer's workbooks: (name, fill, note)."""
    out = []

    def kinds(wb):
        ws = wb.add_sheet("kinds")
        ws.write(0, 0, "text")
        ws.write(0, 1, 1.5)
        ws.write(0, 2, 3)
        ws.write(0, 3, 2 ** 30)
        ws.write(0, 4, 1.005)
        ws.write(0, 5, True)
        ws.write(0, 6, False)
        for i, code in enumerate([0, 7, 15, 23, 29, 36, 42]):
            ws.row(1).set_cell_error(i, code)
        ws.write(2, 0, xlwt.Formula("A1"))
        plain = xlwt.easyxf("")
        ws.row(3).set_cell_blank(0, plain)
        ws.row(3).set_cell_mulblanks(1, 3, plain)
        ws.write_merge(4, 4, 0, 1, "merged")
        ws.write(6, 2, "")
        ws.write(1, 9, 2 ** 29)
        ws.write(1, 10, -(2 ** 29))
        ws.write(1, 11, 2 ** 29 - 1)
        ws.write(65535, 255, "corner")
    out.append(("xlwt_kinds.xls", kinds, "the reference writer: every cell kind — a text, RK numbers plain and divided by 100 in a MULRK run, NUMBER records, booleans, the seven error codes, a formula (its cached value a blank string), BLANK and MULBLANK records, a merged range, the corner cell"))

    def text(wb):
        ws = wb.add_sheet("text")
        ws.write(0, 0, "plain ASCII")
        ws.write(0, 1, "日本語のテキスト")
        ws.write(0, 2, "emoji \U0001F600 \U0001F680 a pair")
        ws.write(0, 3, "café naïve résumé")
        ws.write(0, 4, "éÿ")
        ws.write(0, 5, "\x80\x9f\xa0\xff")
        ws.write(1, 0, "\x00\x01\x02\x1f\x7f")
        ws.write(1, 1, "tab\there\nnewline\r\nend")
        ws.write(1, 2, "\ufeff leading byte order mark")
        ws.write(1, 3, "\u3000 ideographic space and line separator")
        ws.write(2, 0, "x" * 4000)
        ws.write(2, 1, "a" * 300)
        ws.write(2, 2, "duplicate")
        ws.write(2, 3, "duplicate")
        ws.write(2, 4, " trailing space ")
        ws.write(2, 5, "  leading")
        ws.write(3, 0, "single")
    out.append(("xlwt_text.xls", text, "the reference writer: compressed and UTF-16 text, Japanese, emoji, the Latin-1 high bytes, control characters, a byte order mark, a string of 4000 characters, one shared string referenced twice"))

    def rich(wb):
        ws = wb.add_sheet("rich")
        bold = xlwt.Font()
        bold.bold = True
        red = xlwt.Font()
        red.colour_index = 2
        big = xlwt.Font()
        big.height = 400
        ws.write_rich_text(0, 0, [("plain", bold), ("red", red), ("日本", big)])
        ws.write_rich_text(1, 0, ["a string", ("in two", bold), ("styles", red)])
        ws.write_rich_text(2, 0, [("日本語", bold), ("の装飾", red)])
        ws.write_rich_text(3, 0, [("", bold), ("after an empty run", red)])
        ws.write(4, 0, [("rich by a list", bold), (" too", red)])
    out.append(("xlwt_rich.xls", rich, "the reference writer: rich-text strings, compressed and UTF-16, in two and three runs"))

    def longest(wb):
        ws = wb.add_sheet("long")
        ws.write(0, 0, "x" * 9000)
        ws.write(0, 1, "日" * 5000)
        ws.write(0, 2, "y" * 32767)
        ws.write(0, 3, "漢" * 20000)
        ws.write(0, 4, "tail")
        ws.write(1, 0, "z" * 8224)
    out.append(("xlwt_long_strings.xls", longest, "the reference writer: shared strings longer than a record's 8224 bytes — 9000, 8224, 32767 (the most a cell holds) and 40000 bytes — spanning CONTINUE records in both spellings, a string beginning inside a CONTINUE record"))

    def numbers(wb):
        ws = wb.add_sheet("numbers")
        values = [0, 1, -1, 255, 65536, 2 ** 29 - 1, -(2 ** 29), 2 ** 29, 2 ** 30, 2 ** 31,
                  2 ** 53, 2 ** 53 + 2, -(2 ** 53), 0.1, 1.5, -2.25, 3.141592653589793,
                  0.005, -0.005, 123456789.123, 1e-10, 1e10, 1e100, 1e300,
                  1.7976931348623157e308, -1.7976931348623157e308, 5e-324,
                  2.2250738585072014e-308, float("inf"), float("-inf"), float("nan")]
        for i, value in enumerate(values):
            ws.write(i // 8, i % 8, value)
    out.append(("xlwt_numbers.xls", numbers, "the reference writer: whole numbers at the RK edges and past them, fractions, negatives, the largest and smallest doubles, and three a sheet never holds — two infinities and a not-a-number — which a NUMBER record carries all the same"))

    def formats(wb):
        ws = wb.add_sheet("formats")
        styles = [style(code) for code in BUILTIN_DATES + CUSTOM]
        for r, serial in enumerate(SERIALS):
            for c, st in enumerate(styles):
                ws.write(r, c, serial, st)
    out.append(("xlwt_formats.xls", formats, "the reference writer: twelve date serials — 1, around the phantom 29 February 1900, the epoch, 2020-03-01 with a time, the last second of 9999, fractions, a negative — each under the built-in date and time ids 14 to 22 and 45 to 47 and under twenty-four custom codes"))

    def d1904(wb):
        wb.dates_1904 = True
        ws = wb.add_sheet("dates")
        styles = [style(code) for code in ["M/D/YY", "h:mm", "yyyy-mm-dd", "[h]:mm:ss", "0.00"]]
        for r, value in enumerate([42429.52425925926, 43831.0, 0.0, 1.0, 60.0, 0.5, -1.0]):
            for c, st in enumerate(styles):
                ws.write(r, c, value, st)
    out.append(("xlwt_dates_1904.xls", d1904, "the reference writer: a workbook counting dates from 1904-01-01, its numbers under built-in and custom date and time formats"))

    def sheets(wb):
        first = wb.add_sheet("Zebra")
        hidden = wb.add_sheet("Hidden sheet")
        hidden.visibility = 1
        jp = wb.add_sheet("日本語のシート")
        jp.visibility = 2
        long_name = wb.add_sheet("a" * 31)
        wb.add_sheet("Empty")
        first.write(0, 0, "first")
        hidden.write(0, 0, 1)
        hidden.write(1, 0, "hidden text")
        jp.write(0, 0, "very hidden")
        long_name.write(0, 0, 2.5)
    out.append(("xlwt_sheets.xls", sheets, "the reference writer: five worksheets out of alphabetical order, one hidden, one very hidden, one named in Japanese, one named with the longest name a sheet holds, one empty"))

    def limits(wb):
        ws = wb.add_sheet("limits")
        for c in range(256):
            ws.write(0, c, c + 0.5)
        ws.write(1, 255, "right edge")
        ws.write(65534, 255, "last but one")
        ws.write(65535, 0, 65535)
        ws.write(65535, 255, "corner")
    out.append(("xlwt_limits.xls", limits, "the reference writer: the widest row, 256 cells in one MULRK record; the longest row's last cell, in column 255"))

    def overwrite(wb):
        ws = wb.add_sheet("ow", cell_overwrite_ok=True)
        ws.write(0, 0, "replaced by a number")
        ws.write(0, 0, 7, style("0.00"))
        ws.write(0, 1, "first text")
        ws.write(0, 1, "second text")
        ws.write(1, 0, 1)
        ws.write(1, 0, "now a text")
        ws.write(1, 1, "then a blank")
        ws.write(1, 1, "")
        ws.write(2, 0, "kept")
    out.append(("xlwt_overwrite.xls", overwrite, "the reference writer: cells written twice keep their last record — a text by a number, a text by a text, a number by a text, a text by a blank; the shared string table counts one reference to its two strings"))

    def formulas(wb):
        ws = wb.add_sheet("formulas")
        ws.write(0, 0, 1)
        ws.write(0, 1, 2)
        ws.write(1, 0, xlwt.Formula("A1+B1"))
        ws.write(1, 1, xlwt.Formula("SUM(A1:B1)"))
        ws.write(1, 2, xlwt.Formula('"text"'))
        ws.write(2, 1, "beside")
    out.append(("xlwt_formulas.xls", formulas, "the reference writer: three formula cells, each caching a blank string, beside two numbers and a text"))

    def small(wb):
        ws = wb.add_sheet("small")
        ws.write(0, 0, "a")
        ws.write(0, 1, 1)
        ws.write(1, 0, "b")
        ws.write(1, 1, 2.5)
    out.append(("xlwt_small.xls", small, "the reference writer: two rows, a text and a number in each"))
    return out


# ── make ─────────────────────────────────────────────────────────────

def make():
    if os.path.isdir(FIX):
        shutil.rmtree(FIX)
    os.makedirs(FIX)
    os.makedirs(LOG, exist_ok=True)
    index = []
    log("reference tools: xlrd %s, xlwt %s, pandas %s, olefile %s" % (
        xlrd.__version__, xlwt.__VERSION__, pd.__version__, getattr(olefile, "__version__", "?")))
    log("files the reference writer wrote:")
    for name, fill, note in written():
        wb = xlwt.Workbook()
        fill(wb)
        path = os.path.join(FIX, name)
        wb.save(path)
        with open(path, "rb") as f:
            data = f.read()
        index.append(sound_sidecar(name, data, "xlwt", "xlwt %s" % xlwt.__VERSION__, note))
        log("  %-28s %7d bytes%s" % (name, len(data), ""))
    log("files built record by record:")
    for entry in S.sound():
        index.append(sound_sidecar(
            entry["name"], entry["data"], "synthetic", "tools/xlsbuild.py", entry["note"],
            entry["plan"], entry.get("sidecar", "reference"), entry.get("skip", frozenset()),
            entry.get("deviations")))
        log("  %-30s %7d bytes" % (entry["name"], len(entry["data"])))
    log("files broken in one place:")
    for spec in S.broken():
        index.append(broken_sidecar(spec))
        log("  %-34s %7d bytes  %s" % (spec["name"], len(spec["data"]), spec["refusal"]))
    with open(os.path.join(FIX, "index.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)
    total = sum(os.path.getsize(os.path.join(FIX, n)) for n in os.listdir(FIX))
    cells = sum(e.get("cells", 0) for e in index)
    refused = sum(1 for e in index if e["codec"] == "refuses")
    log("the corpus: %d files, %d of them refused by name or as malformed; %d cells; %d bytes in all (%s)"
        % (len(index), refused, cells, total, "under the limit" if total < LIMIT else "OVER THE LIMIT"))
    log("cells the hand-built plans wrote and the reference reader read alike, compared at make time: %d of %d; cells the reader reads otherwise, by design: %d; formula cells caching a blank string, which it answers as an empty text: %d"
        % (TALLY["compared"], TALLY["plan_cells"], TALLY["deviating"], TALLY["blank"]))
    log("the second reader against the sidecars at make time: texts, booleans and plain numbers it agreed with: %d; disagreed: %d;"
        " date-formatted numbers it converts itself: %d; error cells it nulls: %d; empty texts it nulls: %d; numbers not finite it nulls: %d"
        % (SECOND["second_agreed"], SECOND["mismatch"], SECOND["dates"], SECOND["errors"], SECOND["blank"], SECOND["nonfinite"]))
    if total >= LIMIT or SECOND["mismatch"]:
        return 1
    return sweep()


# ── the sweep: the reference reader on every replacement the test draws ─

#: The seed of the test's replacement sweep, the bytes of "XLS2026".
SEED_REPLACEMENT = 0x584C5332303236

#: The files the malformed-input sweep is run on: one the reference writer
#: wrote and one built by hand — both small, both of one sheet.
SWEEP_FILES = ["xlwt_small.xls", "syn_tiny.xls"]

#: How many replacements of each the test draws.
SWEEP_CASES = 200


def splitmix(seed):
    """The test's own 64-bit generator (splitmix64), drawn the way the
    test draws it."""
    state = seed
    while True:
        state = (state + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        z = state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
        yield z ^ (z >> 31)


def replacement(data, rng):
    """The next replacement the test draws of `data`: the offset and the
    value — never the byte that is already there."""
    at = next(rng) % len(data)
    value = (next(rng) >> 8) & 0xFF
    if value == data[at]:
        value ^= 0xFF
    return at, value


def reference_first_sheet(data):
    """What the reference reader gets from the bytes `data`: the date mode
    and the cells of the first sheet, or the error it refused with."""
    book, error = open_xlrd_data(data)
    if book is None:
        return None, error
    try:
        stream = workbook_stream_data(data)
        if stream is None:
            return None, "no workbook stream the reader's own container code locates"
        view = reference_view(book, stream)
    except Exception as e:  # noqa
        return None, "%s: %s" % (type(e).__name__, e)
    if not view["grids"]:
        return None, "no sheet"
    return {"datemode": view["datemode"], "cells": view["grids"][0]["cells"]}, None


def sweep():
    """Replay the test's replacement sweep through the reference reader and
    record, for every copy, the cells it got or its refusal: a copy the
    codec still reads is held to what the reader read in it."""
    out = {"seed_replacement": "0x%016x" % SEED_REPLACEMENT, "cases": SWEEP_CASES, "files": {}}
    stats = {"cases": 0, "opens": 0, "refusals": 0, "cells": 0}
    for name in SWEEP_FILES:
        with open(os.path.join(FIX, name), "rb") as f:
            data = f.read()
        rng = splitmix(SEED_REPLACEMENT)
        cases = []
        for _ in range(SWEEP_CASES):
            at, value = replacement(data, rng)
            changed = data[:at] + bytes([value]) + data[at + 1:]
            got, error = reference_first_sheet(changed)
            entry = {"at": at, "value": value}
            stats["cases"] += 1
            if got is None:
                entry["reference_opens"] = False
                entry["reference_error"] = error
                stats["refusals"] += 1
            else:
                entry["reference_opens"] = True
                entry["datemode"] = got["datemode"]
                entry["cells"] = got["cells"]
                stats["opens"] += 1
                stats["cells"] += len(got["cells"])
            cases.append(entry)
        out["files"][name] = cases
    with open(os.path.join(FIX, "sweep.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    log("the reference reader on the test's %d replacements: opens %d (with %d cells), refuses %d"
        % (stats["cases"], stats["opens"], stats["cells"], stats["refusals"]))
    return 0


# ── verify ───────────────────────────────────────────────────────────

def verify():
    """Compare every file the index lists with what both reference
    readers return; exit non-zero on a mismatch."""
    os.makedirs(LOG, exist_ok=True)
    with open(os.path.join(FIX, "index.json"), encoding="utf-8") as f:
        index = json.load(f)
    stats = {"files": 0, "refused": 0, "cells": 0, "agreed": 0, "mismatch": 0,
             "opens": 0, "cannot_open": 0, "second_opens": 0, "second_refusals": 0,
             "dates": 0, "errors": 0, "blank": 0, "nonfinite": 0, "absent": 0, "no_sheet": 0,
             "compound_opens": 0, "compound_refusals": 0, "generator": 0, "codec_refuses_reader_opens": 0}

    def problem(text):
        log("MISMATCH " + text)
        stats["mismatch"] += 1

    stats["second_agreed"] = 0
    stats["skipped"] = 0
    for entry in index:
        name = entry["file"]
        path = os.path.join(FIX, name)
        with open(path + ".json", encoding="utf-8") as f:
            car = json.load(f)
        stats["files"] += 1
        book, error = open_xlrd(path)
        second, error2 = open_pandas(path)
        streams = olefile_streams(path)
        if (book is not None) != car["reference_opens"]:
            problem("%s: the reference reader opens it now but the sidecar says reference_opens=%s (%s)"
                    % (name, car["reference_opens"], error))
        if (second is not None) != car["second_reader_opens"]:
            problem("%s: the second reader opens it now but the sidecar says second_reader_opens=%s (%s)"
                    % (name, car["second_reader_opens"], error2))
        if ("opens" if streams is not None else "refuses") != car["compound_reader"]:
            problem("%s: the compound-file reader %s it now, the sidecar says %s"
                    % (name, "opens" if streams is not None else "refuses", car["compound_reader"]))
        stats["opens" if book is not None else "cannot_open"] += 1
        stats["second_opens" if second is not None else "second_refusals"] += 1
        stats["compound_opens" if streams is not None else "compound_refusals"] += 1
        if car["codec"] == "refuses":
            stats["refused"] += 1
            if book is not None:
                stats["codec_refuses_reader_opens"] += 1
            continue
        if book is not None:
            view = reference_view(book, workbook_stream(path))
            if view["sheets"] != car["sheets"] or view["datemode"] != car["datemode"]:
                problem("%s: the sheets or the date mode differ from the sidecar's" % name)
            if len(view["grids"]) == len(car["grids"]):
                for mine, theirs in zip(view["grids"], car["grids"]):
                    if len(mine["cells"]) != len(theirs["cells"]):
                        problem("%s, %s: the reader holds %d cells, the sidecar %d"
                                % (name, theirs["sheet"], len(mine["cells"]), len(theirs["cells"])))
                        continue
                    for a, b in zip(mine["cells"], theirs["cells"]):
                        stats["cells"] += 1
                        if same(a, b):
                            stats["agreed"] += 1
                        elif car["sidecar_source"] == "generator":
                            continue
                        else:
                            problem("%s, %s: the reader read %r, the sidecar %r"
                                    % (name, theirs["sheet"], a[:4], b[:4]))
        if car["sidecar_source"] == "generator":
            stats["generator"] += 1
        if second is not None:
            compare_pandas(second, car["grids"], name, stats,
                          frozenset(tuple(k) for k in car.get("first_reader_differs", [])))
    log("reference files: %(files)d; the codec refuses %(refused)d; the reference reader opens %(opens)d and refuses %(cannot_open)d;"
        " the second reader opens %(second_opens)d and refuses %(second_refusals)d; the compound-file reader opens %(compound_opens)d and refuses %(compound_refusals)d" % stats)
    log("cells the reference reader returned, compared with the sidecars: %(cells)d; agreed: %(agreed)d; mismatches: %(mismatch)d; sidecars taken from the generator: %(generator)d" % stats)
    log("cells the second reader agrees with the sidecars on: %(second_agreed)d; and answers otherwise, and is not held to: date-formatted numbers it converts itself %(dates)d; error cells it nulls %(errors)d;"
        " empty texts it nulls %(blank)d; numbers not finite it nulls %(nonfinite)d; cells past its frame %(absent)d; sheets it does not name %(no_sheet)d" % stats)
    log("files the codec refuses and the reference reader opens: %(codec_refuses_reader_opens)d" % stats)
    with open(os.path.join(LOG, "verify_summary.json"), "w", encoding="utf-8") as f:
        json.dump(stats, f, indent=1)
    return 1 if stats["mismatch"] else 0


if __name__ == "__main__":
    steps = [a for a in sys.argv[1:] if not a.startswith("--")]
    step = steps[0] if steps else "make"
    sys.exit({"make": make, "verify": verify, "sweep": sweep}[step]())
