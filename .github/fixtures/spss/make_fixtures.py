"""Generate the reference corpus of SPSS system files under
``fixtures/reference`` and the JSON sidecar beside each, then verify both.

``make`` writes the default corpus: files the reference writer wrote, and
files derived from a written one by re-labelling its encoding,
byte-swapping it, patching a field, or building it by hand. PSPP's own
example and test files — written by SPSS and by PSPP, and PSPP's to
license — are added only by ``make --with-pspp``: an optional check
against files no Python wrote, not part of what is committed. A sidecar
holds the cells the reference reader itself got from its file where that
reader opens it — its strings as they are, its numbers as they are, and a
date, datetime or time cell as the day or microsecond count the codec's
stated rule gives for the reader's number (a count the reader's own
conversion is checked against wherever it converts) — and the cells of
this script's own reading of the layout where it does not open the file.
Every cell is spelled ``<kind> <payload>``: ``Null``, ``Float <16 hex
digits of the IEEE bits>``, ``String <text>``, ``Date <days since
1970-01-01>``, ``Timestamp <microseconds since 1970-01-01>``.

``verify`` re-reads every file with both reference readers and compares
every cell with the sidecar; it exits non-zero on a mismatch that is not
one of the deviations the sidecars record. PSPP's files are passed over
unless ``verify --with-pspp`` is given.

    uv run --no-project --with pandas --with pyreadstat python -I -X utf8 .github/fixtures/spss/make_fixtures.py make
    uv run --no-project --with pandas --with pyreadstat python -I -X utf8 .github/fixtures/spss/make_fixtures.py verify
    uv run --no-project --with pandas --with pyreadstat python -I -X utf8 .github/fixtures/spss/make_fixtures.py make --with-pspp
    uv run --no-project --with pandas --with pyreadstat python -I -X utf8 .github/fixtures/spss/make_fixtures.py verify --with-pspp
"""
import contextlib
import datetime
import json
import math
import os
import random
import shutil
import struct
import sys
import tarfile
import tempfile
import urllib.request
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import savlayout as L  # noqa: E402

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import pyreadstat  # noqa: E402
from pyreadstat.pyclasses import MissingRange  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
FIX = os.path.join(HERE, "reference")
# The build directory, which nothing tracks, holds the logs of a run.
LOG = os.path.join(ROOT, "_build", "spss_fixture_logs")

EPOCH = datetime.datetime(1970, 1, 1)
EPOCH_DATE = datetime.date(1970, 1, 1)
DAY_MICROS = 86400 * 10 ** 6


def log(text):
    print(text, flush=True)


# ── the reference readers ────────────────────────────────────────────

def pyreadstat_read(path):
    """What the first reference reader returns, or the error it refused with."""
    try:
        raw, meta = pyreadstat.read_sav(path, disable_datetime_conversion=True)
        conv, _ = pyreadstat.read_sav(path)
    except Exception as e:  # noqa
        return None, "%s: %s" % (type(e).__name__, e)
    return {"label": "pyreadstat", "names": list(raw.columns), "raw": raw, "conv": conv,
            "types": meta.readstat_variable_types, "formats": meta.original_variable_types}, None


def pandas_read(path):
    """What the second reference reader returns — its numbers raw and its
    dates converted, as its keyword arguments allow — or the error it
    refused with."""
    try:
        raw = pd.read_spss(path, convert_categoricals=False, disable_datetime_conversion=True)
        conv = pd.read_spss(path, convert_categoricals=False)
    except Exception as e:  # noqa
        return None, "%s: %s" % (type(e).__name__, e)
    return {"label": "pandas", "names": list(raw.columns), "raw": raw, "conv": conv, "types": None}, None


def dumps(entry):
    """A sidecar as JSON, a column to a line and its cells compact, so
    that a file of thousands of cases stays a text a person can scan."""
    lines = ["{"]
    items = list(entry.items())
    for k, (key, value) in enumerate(items):
        comma = "," if k < len(items) - 1 else ""
        if key != "columns":
            lines.append(" " + json.dumps(key) + ": " + json.dumps(value, ensure_ascii=False) + comma)
            continue
        lines.append(' "columns": [')
        for i, column in enumerate(value):
            head = {c: v for c, v in column.items() if c != "cells"}
            last = i == len(value) - 1
            cells = ",".join(json.dumps(c, ensure_ascii=False) for c in column["cells"])
            lines.append("  " + json.dumps(head, ensure_ascii=False)[:-1] + ', "cells": [' + cells + "]}"
                         + ("" if last else ","))
        lines.append(" ]" + comma)
    lines.append("}")
    return "\n".join(lines)


def bits(value):
    return struct.unpack("<Q", struct.pack("<d", value))[0]


def micros_of(value):
    if hasattr(value, "to_pydatetime"):
        value = value.to_pydatetime(warn=False)
    return (value - EPOCH) // datetime.timedelta(microseconds=1)


def spell(value, dtype, family):
    """A number cell as the codec's rule spells it: a `Float` by its bits,
    or — under a date, datetime or time format — a day or microsecond
    count when the number is a whole number of that unit. A datetime
    counts from 14 October 1582 and a time from midnight; both are
    spelled since 1970-01-01, the time on that day."""
    if dtype == "Date":
        days = L.whole_days(value)
        return "Date %d" % days if days is not None else "Float %016x" % bits(value)
    if dtype == "Timestamp":
        micros = L.whole_micros(value)
        if micros is None:
            return "Float %016x" % bits(value)
        return "Timestamp %d" % (micros - L.EPOCH_MICROS if family == "DateTime" else micros)
    return "Float %016x" % bits(value)


def is_null(value):
    return value is None or (isinstance(value, float) and math.isnan(value))


def reference_cells(ref, index, own, own_dtype, family, null_as_null=False):
    """The cells the reference reader got for column `index`. Its strings
    stand as they are. Its numbers are spelled by the codec's rule, and
    where the reader converts the cell itself its conversion is checked
    against that rule. A cell the reader nulls does not say why: the
    sidecar keeps this script's own cell there (or ``Null``, which is all
    the reader says). Answers the cells; how many of the reader's own
    date and datetime conversions were checked; a conversion that
    disagreed with the rule, if one did; how many cells fall short of a
    whole day or microsecond, which the reader truncates and the rule
    keeps as numbers; and how many times past one day the reader wraps."""
    name = ref["names"][index]
    raw = ref["raw"][name].tolist()
    conv = ref["conv"][name].tolist()
    cells = []
    checked = 0
    truncated = 0
    wrapped = 0
    disagreement = None
    for i, (rv, cv) in enumerate(zip(raw, conv)):
        if isinstance(rv, str):
            cells.append("String " + rv)
            continue
        if is_null(rv):
            cells.append("Null" if null_as_null else own[i])
            continue
        cell = spell(rv, own_dtype, family)
        if isinstance(cv, datetime.time):
            # The reader rounds a time to the microsecond and wraps one
            # outside the day; the rule keeps such a number.
            tm = (cv.hour * 3600 + cv.minute * 60 + cv.second) * 10 ** 6 + cv.microsecond
            if cell.startswith("Timestamp ") and int(cell[10:]) != tm:
                wrapped += 1
        elif isinstance(cv, (datetime.datetime, datetime.date)) and cell.startswith("Float "):
            truncated += 1
        elif isinstance(cv, datetime.datetime):
            checked += 1
            if cell != "Timestamp %d" % micros_of(cv):
                disagreement = (i, cell, cv)
        elif isinstance(cv, datetime.date):
            checked += 1
            if cell != "Date %d" % ((cv - EPOCH_DATE).days):
                disagreement = (i, cell, cv)
        cells.append(cell)
    return cells, checked, disagreement, truncated, wrapped


def converted_kind(ref, index):
    """What the reference reader converts the column's cells to, if anything."""
    name = ref["names"][index]
    if ref["types"] is not None and ref["types"].get(name) == "string":
        return None
    for cv in ref["conv"][name].tolist():
        if isinstance(cv, datetime.datetime):
            return "datetime"
        if isinstance(cv, datetime.date):
            return "date"
        if isinstance(cv, datetime.time):
            return "time"
    return None


# ── the sidecar ──────────────────────────────────────────────────────

def sidecar(path, file, origin, note, refuse=None):
    """Read one file every way and write its sidecar."""
    b = open(path, "rb").read()
    entry = {"file": file, "origin": origin, "note": note, "bytes": len(b)}
    try:
        d = L.parse(b)
        entry["writer"] = d["product"].decode("latin-1")
        entry["compression"] = {0: "none", 1: "bytecode", 2: "zlib"}[d["compression"]]
        entry["byte_order"] = "big" if d["big"] else "little"
    except ValueError:
        # not a system file at all: nothing to say of a dictionary it has none of
        entry["writer"] = None
    ref, ref_error = pyreadstat_read(path)
    entry["reference_opens"] = ref is not None
    if ref is None:
        entry["reference_error"] = ref_error
    if refuse:
        entry["codec"] = "refuses"
        entry["refusal"] = refuse
        if ref is not None:
            entry["reference_rows"] = int(ref["raw"].shape[0])
            entry["reference_columns"] = ref["names"]
        return entry, 0, 0, 0
    own = L.read(b)
    entry["codec"] = "reads"
    entry["ncases"] = own["rows"]
    entry["sidecar_source"] = "reference" if ref is not None else "generator"
    columns = []
    compared = 0
    checked = 0
    for i, column in enumerate(own["columns"]):
        spec = {"name": column["name"], "dtype": column["dtype"], "format": column["format"]}
        if ref is not None:
            if ref["names"][i] != column["name"]:
                raise SystemExit("%s: the reference reader names column %d %r, the layout %r"
                                 % (file, i, ref["names"][i], column["name"]))
            cells, cross, disagreement, cut, wrap = reference_cells(ref, i, column["cells"], column["dtype"],
                                                                    L.FAMILY.get(column["format"]))
            if disagreement is not None:
                raise SystemExit("%s, column %s, row %d: the reference reader converts the cell to %r, "
                                 "the codec's rule to %r" % (file, column["name"], disagreement[0], disagreement[2], disagreement[1]))
            checked += cross
            spec["reference_truncates"] = cut
            spec["reference_wraps"] = wrap
            spec["reference_converts"] = converted_kind(ref, i)
            spec["source"] = "reference"
            for mine, theirs in zip(column["cells"], cells):
                compared += 1
                if mine != theirs:
                    raise SystemExit("%s, column %s: this script's reading says %r, the reference reader's cell %r"
                                     % (file, column["name"], mine, theirs))
        else:
            spec["cells"] = column["cells"]
            spec["source"] = "generator"
            for mine in column["cells"]:
                compared += 1
            cells = column["cells"]
        spec["cells"] = cells
        columns.append(spec)
    entry["columns"] = columns
    entry["cells"] = sum(len(c["cells"]) for c in columns)
    return entry, compared, checked, 0


# ── derived files ────────────────────────────────────────────────────

def set_encoding(b, name, code):
    """Re-label the file's encoding: the machine record's code page, and
    the encoding record's name (the record removed when `name` is None)."""
    d = L.parse(b)
    out = bytearray(b)
    if 3 in d["ext"]:
        struct.pack_into("<I", out, d["ext"][3]["data_at"] + 28, code)
    if 20 in d["ext"]:
        rec = d["ext"][20]
        new = b"" if name is None else struct.pack("<4i", 7, 20, 1, len(name)) + name.encode("ascii")
        out = out[:rec["at"]] + new + out[rec["end"]:]
    elif name is not None:
        at = d["records"][-1]["at"]
        out = out[:at] + struct.pack("<4i", 7, 20, 1, len(name)) + name.encode("ascii") + out[at:]
    return bytes(out)


def encode(text, codec):
    if codec == "latin-1":
        return text.encode("latin-1")
    if codec == "cp1252":
        return L.encode_cp1252(text)
    return text.encode("utf-8")


def retext(b, texts, raws, codec):
    """Rewrite every string cell of an uncompressed file with the text each
    column is given, encoded in `codec`; `raws` plants raw bytes instead."""
    d = L.parse(b)
    out = bytearray(b)
    units = sum(s["octets"] for s in d["slots"])
    data = d["data_at"]
    offset = 0
    for slot in d["slots"]:
        if slot["owner"] >= 0 or slot["width"] == 0:
            offset += slot["octets"]
            continue
        name = slot["name"]
        for r in range(d["ncases"]):
            at = data + (r * units + offset) * 8
            raw = raws[name][r] if name in raws and r in raws[name] else encode(texts[name][r], codec)
            if len(raw) > slot["width"]:
                raise SystemExit("text too wide for %s" % name)
            out[at:at + slot["width"]] = raw + b" " * (slot["width"] - len(raw))
        offset += slot["octets"]
    return bytes(out)


def swap_endian(b, data_=True):
    """The same file with every integer and floating-point number in the
    other byte order: what a writer on a big-endian machine produces. The
    dictionary alone when `data_` is false."""
    out = bytearray(b)
    d = L.parse(b)

    def swap(at, n):
        out[at:at + n] = b[at:at + n][::-1]

    for at in (64, 68, 72, 76, 80):
        swap(at, 4)
    swap(84, 8)
    if 3 in d["ext"]:
        struct.pack_into("<I", out, d["ext"][3]["data_at"] + 24, 1)
    for rec in d["records"]:
        k, at = rec["kind"], rec["at"]
        swap(at, 4)
        if k == 2:
            for i in range(1, 6):
                swap(at + 4 * i, 4)
            if rec["has_label"] == 1:
                swap(rec["label_at"], 4)
            if rec["n_missing"]:
                for i in range(abs(rec["n_missing"])):
                    swap(rec["missing_at"] + 8 * i, 8)
        elif k == 3:
            swap(at + 4, 4)
            for v in rec["values_at"]:
                swap(v, 8)
        elif k == 4:
            swap(at + 4, 4)
            for i in range(rec["count"]):
                swap(rec["vars_at"] + 4 * i, 4)
        elif k == 6:
            swap(at + 4, 4)
        elif k == 7:
            for i in range(1, 4):
                swap(at + 4 * i, 4)
            if rec["subtype"] in (3, 11):
                for i in range(len(rec["data"]) // 4):
                    swap(rec["data_at"] + 4 * i, 4)
            elif rec["subtype"] in (4, 16):
                for i in range(len(rec["data"]) // 8):
                    swap(rec["data_at"] + 8 * i, 8)
        elif k == 999:
            swap(at + 4, 4)
    data = d["data_at"]
    if data_ and d["compression"] == 0:
        # A number's eight bytes change order; a string's do not.
        units = sum(s["octets"] for s in d["slots"])
        offset = 0
        for slot in d["slots"]:
            if slot["width"] == 0:
                for r in range(max(d["ncases"], 0)):
                    swap(data + (r * units + offset) * 8, 8)
            offset += slot["octets"]
    elif data_:
        out[data:] = swap_codes(bytearray(b[data:]), d)
    return bytes(out)


def swap_codes(codes, d):
    """A bytecode stream with every number's literal eight bytes in the
    other order; a string's bytes do not change."""
    units = sum(s["octets"] for s in d["slots"]) or 1

    def numeric(unit):
        column = unit % units
        offset = 0
        for slot in d["slots"]:
            if offset <= column < offset + slot["octets"]:
                return slot["width"] == 0
            offset += slot["octets"]
        return False

    group = literal = 0
    index = 8
    unit = 0
    while True:
        if index == 8:
            if len(codes) - literal < 8:
                break
            group, literal, index = literal, literal + 8, 0
        code = codes[group + index]
        index += 1
        if code == 0:
            continue
        if code == 252:
            break
        if code == 253:
            if numeric(unit):
                codes[literal:literal + 8] = codes[literal:literal + 8][::-1]
            literal += 8
        unit += 1
    return bytes(codes)


def swap_zsav(b):
    """The same zlib-compressed file in the other byte order: its
    dictionary, its data header and trailer, and the numbers inside its
    inflated codes."""
    d = L.parse(b)
    head = swap_endian(b[:d["data_at"]], data_=False)
    codes = swap_codes(bytearray(L.inflated(b, d)), d)
    compressed = zlib.compress(codes)
    header_at = len(head)
    block_at = header_at + 24
    trailer_at = block_at + len(compressed)
    return (head + struct.pack(">qqq", header_at, trailer_at, 48) + compressed
            + struct.pack(">qqII", -100, 0, 0x3FF000, 1)
            + struct.pack(">qqII", header_at, block_at, len(codes), len(compressed)))


def patch_ncases(b, n):
    out = bytearray(b)
    struct.pack_into("<i" if b[64:68] == b"\x02\x00\x00\x00" else ">i", out, 80, n)
    return bytes(out)


# ── the corpus ────────────────────────────────────────────────────────

REAL = [
    ("tests/data/v13.sav", "spss13_v13.sav", "SPSS 13.0: uncompressed; very long strings of 258 and 2000 bytes"),
    ("tests/data/v14.sav", "spss14_v14.sav",
     "SPSS 14.0.0: bytecode-compressed; very long strings of 256, 1335 and 2000 bytes"),
    ("tests/data/CVE-2017-10792.sav", "spss12_cve_2017_10792.sav",
     "SPSS 12.0, fuzzer-mutated: its machine record carries subtype 18; value labels present"),
    ("tests/data/CVE-2017-10791.sav", "spss12_cve_2017_10791.sav",
     "SPSS 12.0, fuzzer-mutated: the long string value labels record is cut short; the reference reader refuses it"),
    ("examples/hotel.sav", "pspp_0_8_4_hotel.sav", "PSPP 0.8.4: bytecode-compressed, UTF-8, value labels, variable labels"),
    ("examples/repairs.sav", "pspp_1_4_2_repairs.sav", "PSPP 1.4.2: bytecode-compressed"),
    ("examples/personnel.sav", "pspp_1_5_2_personnel.sav", "PSPP 1.5.2: UTF-8, an SDATE date column"),
    ("examples/horticulture.sav", "pspp_1_3_0_horticulture.sav", "PSPP 1.3.0: a 16-byte string column"),
    ("tests/language/commands/llz.zsav", "pspp_0_8_4_llz.zsav", "PSPP 0.8.4: zlib-compressed, 4670 cases"),
]

PSPP_URL = "https://ftp.gnu.org/gnu/pspp/pspp-2.0.1.tar.gz"


@contextlib.contextmanager
def pspp_samples():
    """PSPP's ten sample files, extracted from its source distribution into
    a temporary directory that does not outlive the call: PSPP's files are
    PSPP's to license, so none is kept in the workspace. The ten data files
    are read out of the archive by name; nothing of it is executed."""
    members = ["pspp-2.0.1/" + source for source, _, _ in REAL]
    members.append("pspp-2.0.1/tests/data/hotel-encrypted.sav")
    with tempfile.TemporaryDirectory() as tmp:
        archive = os.path.join(tmp, "pspp.tar.gz")
        log("fetching PSPP's source distribution for its ten sample files: %s" % PSPP_URL)
        urllib.request.urlretrieve(PSPP_URL, archive)
        out = os.path.join(tmp, "pspp")
        with tarfile.open(archive, "r:gz") as tar:
            for member in members:
                data = tar.extractfile(member).read()
                path = os.path.join(out, member)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as f:
                    f.write(data)
        yield os.path.join(out, "pspp-2.0.1")


def table_strings():
    return pd.DataFrame({
        "num": [1.0, -2.5, 3.0e300, np.nan, 0.0],
        "s8": ["12345678", "a", "", "   ", "  pad  "],
        "s12": ["123456789012", "b", "", None, "x"],
        "s1": ["x", "", "y", "", "z"],
        "s255": ["x" * 255, "y" * 254, "", None, "z"],
        "s300": ["a" * 300, "b" * 254 + "c" * 46, "", None, "d" * 256],
        "a_very_long_column_name_here": ["u", "v", "", None, "w"],
        "ünïcödé_nâmé": ["é", "日本", "", None, "ü"],
    })


def table_formats():
    dates = pd.to_datetime(["2020-03-01", "1582-10-14", "1970-01-01", None], format="ISO8601")
    stamps = pd.to_datetime(["2020-03-01 12:34:56.789", "1582-10-14 00:00:00", "1969-12-31 23:59:59.5", None],
                            format="ISO8601")
    times = [90.0, 3600.5, 86400.0 * 3 + 1.25, np.nan]
    small = [3.0, 1.0, 7.0, np.nan]
    df = pd.DataFrame({
        "adate40": dates, "date40": dates, "edate40": dates, "jdate40": dates, "sdate10": dates,
        "qyr20": dates, "moyr20": dates, "wkyr20": dates,
        "datetime40": stamps, "ymdhms40": stamps,
        "time8": times, "dtime40": times, "mtime40": times,
        "wkday40": small, "month40": small, "f8_2": [1.5, -0.25, np.nan, 1.0e300],
    })
    formats = {c: c[:-2].upper() + c[-2:] for c in df.columns}
    formats["f8_2"] = "F8.2"
    return df, formats


def table_fractional():
    df = pd.DataFrame({
        "half_day": pd.to_datetime(["2020-03-01 12:00:00", "2020-03-02 00:00:00", "2020-03-02 06:00:00", None],
                                   format="ISO8601"),
        "submicro_d": [1.5e-9, 0.1, 86400.0 * 3, np.nan],
        "submicro_t": [1.5e-9, 0.1, -5.0, np.nan],
        "neg_date": [-86400.0, 0.0, 86400.0, np.nan],
        "neg_stamp": [-0.5, 0.0, 1.0, np.nan],
    })
    return df, {"half_day": "ADATE40", "submicro_d": "DATETIME40", "submicro_t": "TIME8",
                "neg_date": "SDATE10", "neg_stamp": "DATETIME40"}


def table_extremes():
    top = sys.float_info.max
    return pd.DataFrame({"v": [-99.0, 151.0, -100.0, 152.0, 0.0, -0.0, math.inf, -math.inf,
                               top, math.nextafter(-top, 0.0), 5e-324, 2.2250738585072014e-308,
                               1.5, np.nan, 100.0, -3.0, 2.0 ** 53 + 1.0]})


def table_missing():
    df = pd.DataFrame({"m3": [1.0, 2.0, 3.0, 4.0, 5.0],
                       "mrange": [1.0, 2.0, 5.0, 8.0, 9.0],
                       "mrangev": [1.0, 5.0, 9.0, 10.0, 11.0],
                       "mopen": [1.0, 4.0, 4.5, 9.0, np.nan],
                       "s3": ["zz", "a", "zz ", "b", ""],
                       "s12": ["zz", "a", "zzzzzzzzzzzz", "b", ""]})
    ranges = {"m3": [1.0, 2.0, 3.0], "mrange": [MissingRange(lo=2.0, hi=8.0)],
              "mrangev": [MissingRange(lo=2.0, hi=8.0), 11.0],
              "mopen": [MissingRange(lo=-math.inf, hi=4.0)], "s3": ["zz"], "s12": ["zz"]}
    return df, ranges


def table_labels():
    return (pd.DataFrame({"num": [1.0, 2.0, 1.0], "s": ["a", "b", "a"]}),
            {"file_label": "my label", "column_labels": {"num": "the number"},
             "variable_value_labels": {"num": {1.0: "one", 2.0: "two"}, "s": {"a": "ay"}},
             "note": ["line one", "line two"], "variable_measure": {"num": "ordinal"},
             "variable_display_width": {"num": 12}, "variable_format": {"s": "A5"}})


def table_text():
    return pd.DataFrame({"t8": ["éééé", "ü", "x", ""], "t12": ["日本語", "a", "", "bb"],
                         "n": [1.0, np.nan, 3.0, 4.0]})


def table_vls():
    """Very long strings around the segment counts: 253 bytes take two
    segments, the last one byte wide; 505 takes three, the last carrying
    no text at all; 2000 takes eight. A second case holds text shorter
    than the width, so the segments' unused space is padding."""
    return pd.DataFrame({
        "s253": ["a" * 253, "ab"],
        "s256": ["b" * 256, ""],
        "s505": ["c" * 505, "c" * 300],
        "s2000": ["d" * 2000, ""],
    })


def table_many_rows():
    """Three hundred cases of what a bytecode stream spells in bulk: small
    whole numbers, which the reference writer stores as codes; other
    numbers, as literals; missing numbers; blank strings and text; and a
    date column."""
    n = 300
    days = pd.Timestamp("2000-01-01") + pd.to_timedelta(np.arange(n), unit="D")
    return (pd.DataFrame({
        "code": [float(i % 7) for i in range(n)],
        "measure": [np.nan if i % 11 == 5 else 1.5 + (i % 13) * 0.25 for i in range(n)],
        "label": ["" if i % 9 == 4 else "row %03d" % i for i in range(n)],
        "stamp": days,
    }), {"stamp": "ADATE11"})


def encrypted_wrapper():
    """The fixed thirty-six-byte header of the encrypted wrapper, as PSPP's
    documentation spells it, before bytes nothing decrypts: a hand-built
    stand-in for an encrypted system file, refused by its signature."""
    header = struct.pack("<q", 28) + b"ENCRYPTEDSAV" + struct.pack("<i", 21) + bytes(12)
    assert len(header) == 36
    return header + random.Random(0x53505353).randbytes(256)


def write(df, name, **kw):
    """Write `df` with the reference writer, its creation date and time
    pinned, so that a corpus generated again is the same bytes and the
    sweeps over it keep their counts. The year is 1999: the first
    reference reader cannot open a file whose stamp it resolves to a
    date before 1970 on this machine."""
    path = os.path.join(FIX, name)
    pyreadstat.write_sav(df, path, **kw)
    data = bytearray(open(path, "rb").read())
    data[92:101] = b"01 Jan 99"
    data[101:109] = b"00:00:00"
    with open(path, "wb") as f:
        f.write(data)
    return bytes(data)


def make(with_pspp=False):
    """Write the corpus under ``fixtures/reference``: the default corpus —
    the files the reference writer wrote and the files derived from them —
    and, with ``with_pspp``, PSPP's own example and test files beside
    them."""
    os.makedirs(FIX, exist_ok=True)
    os.makedirs(LOG, exist_ok=True)
    for name in os.listdir(FIX):
        os.remove(os.path.join(FIX, name))
    index = []
    tally = {"compared": 0, "checked": 0}

    def add(file, origin, note, refuse=None):
        path = os.path.join(FIX, file)
        entry, compared, checked, _ = sidecar(path, file, origin, note, refuse)
        item = {"file": file, "origin": origin, "codec": entry["codec"]}
        for key in ("refusal", "ncases", "cells"):
            if key in entry:
                item[key] = entry[key]
        index.append(item)
        with open(path + ".json", "w", encoding="utf-8", newline="\n") as f:
            f.write(dumps(entry) + "\n")
        tally["compared"] += compared
        tally["checked"] += checked
        log("  %-34s %s" % (file, "the codec refuses it (%s)" % refuse if refuse
                            else "%d cases, %d cells%s" % (entry["ncases"], entry["cells"], ""
                                                           if entry["sidecar_source"] == "reference" else ", the reference reader refuses it")))

    log("pandas %s, pyreadstat %s, numpy %s" % (pd.__version__, pyreadstat.__version__, np.__version__))
    log("files the reference writer wrote:")
    for name, kw in (("pyrs_plain.sav", {}), ("pyrs_rows.sav", {"row_compress": True}),
                     ("pyrs_zsav.zsav", {"compress": True})):
        write(table_strings(), name, **kw)
        add(name, "pyreadstat", "strings of 1, 8, 12, 255 and 300 bytes, a long column name, non-ASCII text")
    df, formats = table_formats()
    write(df, "pyrs_formats.sav", variable_format=formats)
    add("pyrs_formats.sav", "pyreadstat", "one column a date, datetime, time or date-component format")
    df, formats = table_fractional()
    write(df, "pyrs_fractional.sav", variable_format=formats)
    add("pyrs_fractional.sav", "pyreadstat",
        "a half day under a date format, sub-microsecond values, instants before the epoch")
    df, ranges = table_missing()
    write(df, "pyrs_missing.sav", missing_ranges=ranges)
    add("pyrs_missing.sav", "pyreadstat",
        "declared missing values: three values, a range, a range and a value, an open range, strings")
    df, kw = table_labels()
    write(df, "pyrs_labels.sav", **kw)
    add("pyrs_labels.sav", "pyreadstat", "value labels, a file label, notes, column labels")
    write(table_extremes(), "pyrs_extremes_rows.sav", row_compress=True)
    add("pyrs_extremes_rows.sav", "pyreadstat",
        "the largest and smallest doubles, both zeros, the infinities, the numbers at the edge of the codes")
    write(pd.DataFrame({"allnan": [np.nan, np.nan, np.nan], "blank": ["", "  ", ""]}), "pyrs_allmissing.sav")
    add("pyrs_allmissing.sav", "pyreadstat", "a column of nothing but missing values, and one of blank strings")
    empty = pd.DataFrame({"a": pd.Series([], dtype="float64"), "s": pd.Series([], dtype="object")})
    for name, kw in (("pyrs_norows.sav", {}), ("pyrs_norows.zsav", {"compress": True})):
        write(empty, name, **kw)
        add(name, "pyreadstat", "columns and no row")
    write(pd.DataFrame(), "pyrs_nocols.sav")
    add("pyrs_nocols.sav", "pyreadstat", "no column and no row", "ParseError")
    base = write(pd.DataFrame({"a": [1.0, 2.5, -3.0, 4.0], "s": ["aa", "bb", "cc", "dd"]}), "pyrs_four_rows.sav")
    add("pyrs_four_rows.sav", "pyreadstat", "four rows: two numbers and a two-byte string")
    write(table_vls(), "pyrs_vls.sav")
    add("pyrs_vls.sav", "pyreadstat",
        "very long strings of 253, 256, 505 and 2000 bytes: two, two, three and eight segments, the last of the 505 all padding")
    df, formats = table_many_rows()
    write(df, "pyrs_many_rows.zsav", compress=True, variable_format=formats)
    add("pyrs_many_rows.zsav", "pyreadstat",
        "300 cases through a zlib stream: codes, system-missing and literal numbers, blank and literal strings, a date column")

    log("files derived from a written one:")
    for name, n, note in (("pyrs_ncases_unknown.sav", -1, "the header declares no case count"),
                          ("pyrs_ncases_short.sav", 3, "the header declares 3 of the 4 cases in the data"),
                          ("pyrs_ncases_long.sav", 6, "the header declares 6 cases and the data holds 4")):
        with open(os.path.join(FIX, name), "wb") as f:
            f.write(patch_ncases(base, n))
        add(name, "synthetic", note, "ParseError" if n > 4 else None)
    text = write(table_text(), "text_base.sav")
    numbers = [1.0, None, 3.0, 4.0]
    cp1252_text = {"t8": ["€€", "“”", "é", ""], "t12": ["™Ÿ x", "a", "", "bb"], "n": numbers}
    ascii_text = {"t8": ["abcd", "x", "y", ""], "t12": ["z", "a", "", "bb"], "n": numbers}
    plan = [
        ("synthetic_windows1252.sav", "WINDOWS-1252", 1252, "cp1252", cp1252_text, {},
         "re-labelled windows-1252 and its text re-encoded"),
        ("synthetic_windows1252_c1.sav", "WINDOWS-1252", 1252, "cp1252", cp1252_text, {"t8": {2: b"\x81\x8d x"}},
         "as the windows-1252 file, with two bytes the code page leaves unassigned; the reference reader refuses it"),
        ("synthetic_latin1.sav", "ISO-8859-1", 28591, "latin-1",
         {"t8": ["é¥ÿð", "x", "ü", ""], "t12": ["ß ab", "a", "", "bb"], "n": numbers}, {"t8": {1: b"\x81\x9d x"}},
         "re-labelled ISO-8859-1 and its text re-encoded; two C1 bytes planted"),
        ("synthetic_codepage2.sav", None, 2, "ascii", ascii_text, {"t12": {0: b"\x80 z"}},
         "no encoding record and character code 2: read as windows-1252; one 0x80 byte planted"),
        ("synthetic_cp1250.sav", "WINDOWS-1250", 1250, "ascii", ascii_text, {},
         "re-labelled windows-1250 with ASCII text: refused by name"),
    ]
    for name, label, code, codec, texts, raws, note in plan:
        data = set_encoding(retext(text, texts, raws, codec), label, code)
        with open(os.path.join(FIX, name), "wb") as f:
            f.write(data)
        add(name, "synthetic", note, "Unsupported" if "1250" in name else None)
    quirks = retext(text, {"t8": ["ab", "cd", "ef", ""], "t12": ["日本", "a", "", "bb"], "n": numbers},
                    {"t8": {0: b"ab\x00\x00cd  ", 1: b"ab\xc3     "}}, "utf-8")
    name = "synthetic_text_quirks.sav"
    with open(os.path.join(FIX, name), "wb") as f:
        f.write(quirks)
    add(name, "synthetic", "a string cell with NUL bytes inside it, and one whose last character is cut off")
    for name, source, note, swapper in (
        ("synthetic_big_endian.sav", "pyrs_four_rows.sav",
         "byte-swapped: every number in big-endian order", swap_endian),
        ("synthetic_big_endian_rows.sav", "pyrs_extremes_rows.sav",
         "byte-swapped bytecode-compressed file", swap_endian),
        ("synthetic_big_endian_zsav.zsav", "pyrs_zsav.zsav",
         "byte-swapped zlib-compressed file, the numbers inside its inflated codes too", swap_zsav),
    ):
        with open(os.path.join(FIX, source), "rb") as f:
            data = swapper(f.read())
        with open(os.path.join(FIX, name), "wb") as f:
            f.write(data)
        add(name, "synthetic", note)
    os.remove(os.path.join(FIX, "text_base.sav"))
    longer = write(pd.DataFrame({"lower_case_name": [1.0, 2.0], "another_long_one": ["a", "b"]}), "names_base.sav")
    rec = L.parse(longer)["ext"][13]
    name = "synthetic_no_long_names.sav"
    with open(os.path.join(FIX, name), "wb") as f:
        f.write(longer[:rec["at"]] + longer[rec["end"]:])
    os.remove(os.path.join(FIX, "names_base.sav"))
    add(name, "synthetic", "no long variable names record: the names come from the eight-byte fields")
    name = "synthetic_encrypted_wrapper.sav"
    with open(os.path.join(FIX, name), "wb") as f:
        f.write(encrypted_wrapper())
    add(name, "synthetic", "hand-built: the encrypted wrapper's fixed header before bytes nothing decrypts", "Unsupported")
    own = len(index)
    if with_pspp:
        log("optional, with --with-pspp: PSPP's own example and test files, written by SPSS and by PSPP:")
        with pspp_samples() as pspp:
            for source, name, note in REAL:
                shutil.copyfile(os.path.join(pspp, source), os.path.join(FIX, name))
                add(name, "real", note)
            name = "pspp_hotel_encrypted.sav"
            shutil.copyfile(os.path.join(pspp, "tests/data/hotel-encrypted.sav"), os.path.join(FIX, name))
            add(name, "real", "PSPP: a system file inside an encrypted wrapper", "Unsupported")
    with open(os.path.join(FIX, "index.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)
    cells = [e.get("cells", 0) for e in index]
    log("the default corpus: wrote %d files and %d cells under %s" % (own, sum(cells[:own]), FIX))
    if with_pspp:
        log("beside them, written only with --with-pspp: %d of PSPP's own files, with %d cells"
            % (len(index) - own, sum(cells[own:])))
    log("cells this script's reading and the reference reader both hold, compared at make time: %d; "
        "the reference reader's own date and datetime conversions checked against the codec's rule: %d"
        % (tally["compared"], tally["checked"]))
    return 0


# ── verify ───────────────────────────────────────────────────────────

def verify(with_pspp=False):
    """Compare every file ``make`` listed with what both reference readers
    return. PSPP's own files are passed over unless ``with_pspp`` is set,
    and asking for them when the corpus holds none is an error."""
    os.makedirs(LOG, exist_ok=True)
    with open(os.path.join(FIX, "index.json"), encoding="utf-8") as f:
        whole = json.load(f)
    if with_pspp and not any(e["origin"] == "real" for e in whole):
        log("the corpus holds no PSPP file: run `gen_fixtures.py make --with-pspp` first")
        return 1
    index = [e for e in whole if with_pspp or e["origin"] != "real"]
    passed_over = len(whole) - len(index)
    stats = {"files": 0, "refused": 0, "cells": 0, "agreed": 0, "kept": 0, "wrapped": 0, "mismatch": 0,
             "opens": 0, "cannot_open": 0, "rule": 0, "converted": 0, "truncated": 0}

    def problem(text):
        log("MISMATCH " + text)
        stats["mismatch"] += 1

    for entry in index:
        path = os.path.join(FIX, entry["file"])
        with open(path + ".json", encoding="utf-8") as f:
            car = json.load(f)
        stats["files"] += 1
        if car["codec"] == "refuses":
            stats["refused"] += 1
        for reader in (pyreadstat_read, pandas_read):
            ref, error = reader(path)
            if (ref is not None) != car["reference_opens"]:
                problem("%s: %s opens it now but the sidecar says reference_opens=%s (%s)"
                        % (entry["file"], reader.__name__, car["reference_opens"], error))
            if ref is None:
                stats["cannot_open"] += 1
                continue
            stats["opens"] += 1
            if car["codec"] == "refuses":
                continue
            names = [c["name"] for c in car["columns"]]
            if ref["names"] != names:
                problem("%s: %s names the columns %r, the sidecar %r" % (entry["file"], ref["label"], ref["names"], names))
                continue
            for i, column in enumerate(car["columns"]):
                got, cross, disagreement, cut, wrap = reference_cells(ref, i, column["cells"], column["dtype"],
                                                                      L.FAMILY.get(column["format"]), True)
                stats["truncated"] += cut
                stats["wrapped"] += wrap
                if disagreement is not None:
                    problem("%s, %s, column %s: the reader converts row %d to %r, the rule to %r"
                            % (entry["file"], ref["label"], column["name"], disagreement[0], disagreement[2], disagreement[1]))
                for mine, theirs in zip(column["cells"], got):
                    stats["cells"] += 1
                    if mine == theirs:
                        stats["agreed"] += 1
                    elif theirs == "Null" and mine.startswith("Float "):
                        stats["kept"] += 1
                    else:
                        problem("%s, %s, column %s, row %d: sidecar %r, reader %r"
                                % (entry["file"], ref["label"], column["name"], column["cells"].index(mine), mine, theirs))
    for entry in index:
        with open(os.path.join(FIX, entry["file"] + ".json"), encoding="utf-8") as f:
            car = json.load(f)
        if car["codec"] != "reads":
            continue
        for column in car["columns"]:
            n = len(column["cells"])
            if column["dtype"] in ("Date", "Timestamp"):
                if column.get("reference_converts") is None:
                    stats["rule"] += n
                else:
                    stats["converted"] += n
    log("reference files: %(files)d; the codec refuses %(refused)d by name; reader opens over both readers: %(opens)d, "
        "reader refusals: %(cannot_open)d" % stats)
    log("cells both reference readers returned, compared with the sidecars: %(cells)d; agreed: %(agreed)d; mismatches: %(mismatch)d" % stats)
    log("cells the readers null and the sidecar keeps as a number: %(kept)d; times outside one day the readers wrap: %(wrapped)d; "
        "cells short of a whole day or microsecond, which the readers truncate and the codec leaves as numbers: %(truncated)d" % stats)
    log("date, datetime and time cells of columns the readers convert themselves: %(converted)d; of columns they leave as numbers, "
        "spelled by the codec's rule: %(rule)d" % stats)
    if passed_over:
        log("passed over: %d of PSPP's own files, which `verify --with-pspp` includes" % passed_over)
    stats["passed_over"] = passed_over
    with open(os.path.join(LOG, "verify_summary.json"), "w", encoding="utf-8") as f:
        json.dump(stats, f, indent=1)
    return 1 if stats["mismatch"] else 0


if __name__ == "__main__":
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    steps = [a for a in sys.argv[1:] if not a.startswith("--")]
    step = steps[0] if steps else "make"
    sys.exit(make("--with-pspp" in flags) if step == "make" else verify("--with-pspp" in flags))
