"""Generate and verify the reference corpus of the sas7bdat codec.

Usage (from the repository root):

    uv run --no-project --with pandas --with pyreadstat python -I -X utf8 .github/fixtures/sas7bdat/make_fixtures.py make
    uv run --no-project --with pandas --with pyreadstat python -I -X utf8 .github/fixtures/sas7bdat/make_fixtures.py verify

``make`` writes ``reference/`` beside this script:

* files the reference writer produces (pyreadstat's ``write_sas7bdat``):
  the 32-bit layout, and rows compressed with each method;
* files from the pandas test corpus — real SAS data sets, fetched from
  the pandas repository on first use into ``_build/sas7bdat_corpus/`` —
  as they are, whatever their header says;
* synthetic files laid out by ``sas7bdat_build.py`` for what no writer
  produces, or produces only in large files: the 28 missing-value
  spellings, numeric columns 1 to 8 bytes wide in every layout, every
  display-format family, the character sets, the page kinds, rows
  compressed in 64-bit files, a column with no format subheader, an
  unknown compression name, a malformed UTF-8 cell, a byte a code page
  leaves undefined.

Beside each file goes a JSON sidecar. A sidecar's cells come from what a
reference reader itself returned (pandas' raw reader; pyreadstat's where
pandas cannot open the file), spelled under the codec's read rules with
the names, widths and formats the layout model (``sas7bdat_layout.py``)
reads off the bytes. Per column it records whether each reference
reader's own converted result agrees, and where the reader's idea of the
layout differs from the model's. ``index.json`` lists the corpus;
``w32_pyrs.map.json`` maps the bytes of one small file for the refusal
tests.

``verify`` re-reads every file with both reference readers and compares
with the sidecars on disk, so the corpus and the sidecars stay honest.
It exits non-zero on any mismatch.
"""

import datetime as dt
import json
import math
import os
import random
import struct
import sys
import urllib.request
import warnings

import numpy as np
import pandas as pd
import pyreadstat

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "scripts"))
import gen_sas7bdat_charsets as C  # noqa: E402
import sas7bdat_build as B  # noqa: E402
import sas7bdat_layout as L  # noqa: E402

warnings.simplefilter("ignore")

FIX = os.path.join(HERE, "reference")
# The repository's build directory, which nothing tracks, holds the copies
# of the pandas test corpus the step below fetches.
CORPUS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "_build", "sas7bdat_corpus"
)
# Where the pandas test corpus lives upstream: a file this script needs and
# does not find there is fetched once.
CORPUS_URL = "https://raw.githubusercontent.com/pandas-dev/pandas/main/pandas/tests/io/sas/data/"

# The single-byte code pages, by the header's code: the name the reference
# reader's table gives the page and the 128 characters of bytes 0x80 to 0xFF
# (U+FFFD where a byte is undefined), as ``gen_charsets.py`` finds them in
# the codecs — the same tables it writes the reader's from.
PAGES = {code: (codec, high) for code, codec, high in C.classify()[0]}


def corpus_bytes(source):
    """The bytes of a file of the pandas test corpus, fetched when missing."""
    path = os.path.join(CORPUS, source)
    if not os.path.exists(path):
        os.makedirs(CORPUS, exist_ok=True)
        with urllib.request.urlopen(CORPUS_URL + source, timeout=60) as response:
            data = response.read()
        with open(path, "wb") as fh:
            fh.write(data)
        return data
    with open(path, "rb") as fh:
        return fh.read()
UTF8_CODE = 20

# The codec's read rules, spelled once for the sidecars. They mirror the
# MoonBit reader; the fixture test fails whenever the two drift apart.
DATE_FORMATS = [
    "B8601DA", "DATE", "DAY", "DDMMYY", "DDMMYYB", "DDMMYYC", "DDMMYYD", "DDMMYYN",
    "DDMMYYP", "DDMMYYS", "DOWNAME", "E8601DA", "IS8601DA", "JULDAY", "JULIAN", "MINGUO",
    "MMDDYY", "MMDDYYB", "MMDDYYC", "MMDDYYD", "MMDDYYN", "MMDDYYP", "MMDDYYS", "MMYY",
    "MMYYC", "MMYYD", "MMYYN", "MMYYP", "MMYYS", "MONNAME", "MONTH", "MONYY", "NENGO", "QTR",
    "QTRR", "WEEKDATE", "WEEKDATX", "WEEKDAY", "WEEKV", "WORDDATE", "WORDDATX", "YEAR",
    "YYMM", "YYMMC", "YYMMD", "YYMMDDB", "YYMMDDC", "YYMMDDD", "YYMMDDN", "YYMMDDP", "YYMMDDS",
    "YYMMN", "YYMMP", "YYMMS", "YYMON", "YYMMDD", "YYQ", "YYQC", "YYQD", "YYQN", "YYQP", "YYQS",
    "YYQR", "YYQRC", "YYQRD", "YYQRN", "YYQRP", "YYQRS",
]
TIME_FORMATS = [
    "B8601TM", "E8601TM", "HHMM", "HOUR", "IS8601TM", "MMSS", "TIME", "TIMEAMPM", "TOD",
]
DATETIME_FORMATS = [
    "B8601DN", "B8601DT", "B8601DX", "B8601DZ", "B8601LX", "DATEAMPM", "DATETIME", "DTDATE",
    "DTMONYY", "DTWKDATX", "DTYEAR", "E8601DN", "E8601DT", "E8601DX", "E8601DZ", "E8601LX",
    "IS8601DT", "MDYAMPM",
]
SAS_MARCH_4000 = 745154
SAS_MARCH_8000 = 2206123
LIMIT = 9000000000000000000.0
NAT = -9223372036854775808


# The codec's conversions, in Python.


def family(format_name):
    if format_name in DATE_FORMATS:
        return "Days"
    if format_name in TIME_FORMATS:
        return "Clock"
    if format_name in DATETIME_FORMATS:
        return "Instant"
    return "Number"


def gregorian_day(day):
    return day + (day >= SAS_MARCH_4000) + (day >= SAS_MARCH_8000) - 3653


def to_day(value):
    if value != math.floor(value) or value > LIMIT or value < -LIMIT:
        return None
    return gregorian_day(int(value))


def whole_micros(value):
    scaled = value * 1000000.0
    if (
        scaled != math.floor(scaled)
        or scaled > LIMIT
        or scaled < -LIMIT
        or scaled / 1000000.0 != value
    ):
        return None
    return int(scaled)


def to_instant(value):
    micros = whole_micros(value)
    if micros is None:
        return None
    if value >= SAS_MARCH_4000 * 86400.0:
        micros += 86400000000
    if value >= SAS_MARCH_8000 * 86400.0:
        micros += 86400000000
    return micros - 315619200000000


def bits(value):
    return struct.pack(">d", value).hex()


def is_nan(value):
    return isinstance(value, float) and math.isnan(value)


def decoded(code):
    """Whether the reader decodes the character set of ``code``: UTF-8, or a single-byte code page."""
    return code == UTF8_CODE or code in PAGES


def decode(raw, code):
    """Bytes as the header's character-set code says: UTF-8, or one byte to one character through the code page.

    A byte the code page leaves undefined raises: the codec refuses the file
    too, and the generator lists such a file as refused.
    """
    if code == UTF8_CODE:
        return raw.decode("utf-8")
    _codec, high = PAGES[code]
    out = []
    for byte in raw:
        if byte < 0x80:
            out.append(chr(byte))
        elif high[byte - 0x80] == C.REPLACEMENT:
            raise ValueError(f"byte 0x{byte:02X} is undefined in code page {code}")
        else:
            out.append(high[byte - 0x80])
    return "".join(out)


def text_of(value, code):
    """A raw text cell as the codec reads it: padding cut, decoded as the header says."""
    if isinstance(value, bytes):
        return decode(value.rstrip(b"\x00 "), code)
    return value or ""


def error_text(e):
    return f"{type(e).__name__}: {str(e)[:160]}"


# ---------------------------------------------------------------- reading with
# the reference readers


def pandas_raw(path):
    """pandas' reader with nothing converted: bytes for text, doubles for numbers."""
    from pandas.io.sas.sas7bdat import SAS7BDATReader

    with SAS7BDATReader(
        path,
        encoding=None,
        convert_header_text=False,
        blank_missing=False,
        convert_dates=False,
    ) as reader:
        frame = reader.read()
        facts = {
            "names": [bytes(n) for n in reader.column_names],
            "formats": [bytes(f) if f is not None else b"" for f in reader.column_formats],
            "widths": [int(w) for w in reader._column_data_lengths],
            "row_count": int(reader.row_count),
        }
    cells = [
        [None if v is None or is_nan(v) else v for v in frame.iloc[:, k].tolist()]
        for k in range(frame.shape[1])
    ]
    return facts, cells


def pyreadstat_raw(path):
    """pyreadstat's reader with no datetime conversion: str for text, doubles for numbers."""
    frame, meta = pyreadstat.read_sas7bdat(path, disable_datetime_conversion=True)
    facts = {
        # An empty name comes back missing: not a string to encode.
        "names": [n.encode("utf-8") if isinstance(n, str) else b"" for n in frame.columns],
        "formats": [
            ((meta.original_variable_types.get(n) or "").rstrip(".")).encode("utf-8")
            for n in frame.columns
        ],
        "widths": [int(meta.variable_storage_width.get(n) or 0) for n in frame.columns],
        "row_count": int(meta.number_rows),
    }
    cells = [
        [None if v is None or is_nan(v) else v for v in frame[name].tolist()]
        for name in frame.columns
    ]
    return facts, cells


def pandas_own(path):
    """pandas' own result: dates converted, text decoded, a blank cell missing."""
    try:
        return pd.read_sas(path, format="sas7bdat", encoding="infer")
    except Exception as e:  # noqa: BLE001
        return e


def pyreadstat_own(path):
    """pyreadstat's own result: dates to dates, datetimes and times."""
    try:
        return pyreadstat.read_sas7bdat(path)[0]
    except Exception as e:  # noqa: BLE001
        return e


# ---------------------------------------------------------------- the sidecar


def expected_columns(path, out, code):
    """The sidecar's columns: the reference reader's raw cells, read under the codec's rules."""
    problems = {}
    facts = cells = None
    source = None
    for name, reader in (("pandas", pandas_raw), ("pyreadstat", pyreadstat_raw)):
        try:
            facts, cells = reader(path)
            source = name
            break
        except Exception as e:  # noqa: BLE001
            problems[name] = error_text(e)
    if source is None:
        raise RuntimeError(f"neither reference reader opens {os.path.basename(path)}: {problems}")
    layout_cols = out["columns"]
    if len(layout_cols) != len(facts["names"]):
        raise RuntimeError(
            f"{os.path.basename(path)}: the layout model names {len(layout_cols)} columns, "
            f"{source} {len(facts['names'])}"
        )
    # Where the reader that gave the cells disagrees with the model about
    # the layout: names, widths, formats.
    for k, column in enumerate(layout_cols):
        if facts["names"][k] != column["name_raw"] and facts["names"][k] != column["name_raw"].decode(
            "utf-8", "replace"
        ).encode("utf-8"):
            raise RuntimeError(f"{os.path.basename(path)}: column {k + 1} is {facts['names'][k]!r} for {source}")
    model_formats = [c["format_raw"] or b"" for c in layout_cols]
    # A reader that finds fewer format subheaders than columns names fewer
    # formats; the columns past them are recorded, not indexed.
    format_gaps = [
        k + 1
        for k in range(min(len(facts["formats"]), len(layout_cols)))
        if (facts["formats"][k] or b"") != model_formats[k]
    ]
    if len(facts["formats"]) != len(layout_cols):
        format_gaps.append(
            f"the reader names {len(facts['formats'])} formats for {len(layout_cols)} columns"
        )
    width_gaps = [k + 1 for k in range(len(layout_cols)) if facts["widths"][k] != int(layout_cols[k]["width"])]
    columns = []
    for k, column in enumerate(layout_cols):
        name = decode(column["name_raw"], code)
        format_name = decode(model_formats[k], code)
        raw = cells[k]
        spec = {"name": name, "format": format_name, "width": int(column["width"])}
        if column["type"] == 1:
            kind = family(format_name)
            converted = None
            if kind != "Number":
                convert = {"Days": to_day, "Clock": whole_micros, "Instant": to_instant}[kind]
                converted = [None if v is None else convert(v) for v in raw]
                if any(c is None for c, v in zip(converted, raw) if v is not None):
                    converted = None
            if converted is None:
                spec["dtype"] = "Float"
                spec["cells"] = ["Null" if v is None else f"Float {bits(v)}" for v in raw]
            else:
                spec["dtype"] = "Date" if kind == "Days" else "Timestamp"
                spec["cells"] = ["Null" if c is None else f"{spec['dtype']} {c}" for c in converted]
        else:
            spec["dtype"] = "String"
            spec["cells"] = ["String " + text_of(v, code) for v in raw]
        columns.append(spec)
    layout_gap = {
        "reader": source,
        "formats_differ_in_columns": format_gaps,
        "widths_differ_in_columns": width_gaps,
    }
    return source, columns, problems, layout_gap


def pandas_verdicts(path, columns):
    """Per column, whether pandas' own result agrees with the sidecar: (verdict, note)."""
    frame = pandas_own(path)
    if isinstance(frame, Exception):
        return [("cannot open", error_text(frame)) for _ in columns]
    if frame.shape[1] != len(columns):
        raise RuntimeError(f"{os.path.basename(path)}: pandas returns {frame.shape[1]} columns")
    verdicts = []
    for k, spec in enumerate(columns):
        series = frame.iloc[:, k]
        want = spec["cells"]
        note = ""
        if len(series) != len(want):
            note = f"{len(series)} rows against the sidecar's {len(want)}"
        got = series.tolist()
        for g, w in zip(got, want):
            if spec["dtype"] == "String":
                mine = "" if g is None or is_nan(g) else g
                if mine != w[7:]:
                    note = f"{g!r} where the sidecar spells {w!r}"
                    break
            elif spec["dtype"] == "Float":
                if series.dtype.kind != "f":
                    note = f"pandas reads {series.dtype}, the sidecar Float"
                    break
                spelled = "Null" if is_nan(g) else f"Float {bits(g)}"
                if spelled != w:
                    note = f"{spelled} where the sidecar spells {w}"
                    break
            else:
                if series.dtype.kind != "M":
                    note = f"pandas reads {series.dtype}, the sidecar {spec['dtype']}"
                    break
                millis = int(np.datetime64(g, "ms").astype("int64")) if not (g is pd.NaT) else NAT
                if w == "Null":
                    if millis != NAT:
                        note = "a date where the sidecar spells Null"
                        break
                    continue
                micros = int(w.split(" ")[1])
                if w.startswith("Date"):
                    micros *= 86400000000
                if abs(millis - micros // 1000) > 1:
                    note = f"{g} where the sidecar spells {w}"
                    break
        verdicts.append(("agrees", "") if not note else ("differs", f"column {spec['name']!r}: {note}"))
    return verdicts


def pyreadstat_verdicts(path, columns):
    """Per column, whether pyreadstat's own result agrees with the sidecar: (verdict, note)."""
    frame = pyreadstat_own(path)
    if isinstance(frame, Exception):
        return [("cannot open", error_text(frame)) for _ in columns]
    if len(frame.columns) != len(columns):
        raise RuntimeError(f"{os.path.basename(path)}: pyreadstat returns {len(frame.columns)} columns")
    verdicts = []
    for k, spec in enumerate(columns):
        note = ""
        if frame.columns[k] != spec["name"]:
            # A name the reader spells otherwise (an empty one comes back missing).
            note = f"column {spec['name']!r}: pyreadstat names it {frame.columns[k]!r}"
        if len(frame) != len(spec["cells"]):
            # Fewer or more rows than the sidecar: said so, whatever the first cells spell.
            verdicts.append(
                (
                    "differs",
                    f"column {spec['name']!r}: {len(frame)} rows against the sidecar's {len(spec['cells'])}",
                )
            )
            continue
        for g, w in zip(frame.iloc[:, k].tolist(), spec["cells"]):
            if spec["dtype"] == "String":
                ok = ("" if g is None else g) == w[7:]
            elif w == "Null":
                ok = g is None or g is pd.NaT or is_nan(g)
            elif spec["dtype"] == "Float":
                ok = isinstance(g, float) and f"Float {bits(g)}" == w
            elif w.startswith("Date"):
                ok = (
                    isinstance(g, dt.date)
                    and not isinstance(g, dt.datetime)
                    and (g - dt.date(1970, 1, 1)).days == int(w.split(" ")[1])
                )
            elif isinstance(g, dt.time):
                ok = (g.hour * 3600 + g.minute * 60 + g.second) * 1000000 + g.microsecond == int(w.split(" ")[1])
            elif isinstance(g, pd.Timestamp):
                # In the timestamp's own unit: years far from the epoch do not fit nanoseconds.
                ok = int(np.datetime64(g, "us").astype("int64")) == int(w.split(" ")[1])
            else:
                ok = False
            if not ok:
                note = f"column {spec['name']!r}: {g!r} where the sidecar spells {w}"
                break
        verdicts.append(("agrees", "") if not note else ("differs", note))
    return verdicts


def raw_verdicts(path, columns, code):
    """Per column, whether each reader's raw cells are the sidecar's, under the codec's rules."""
    verdicts = {"pandas": [], "pyreadstat": []}
    for name, reader in (("pandas", pandas_raw), ("pyreadstat", pyreadstat_raw)):
        try:
            _facts, cells = reader(path)
        except Exception as e:  # noqa: BLE001
            verdicts[name] = [("cannot open", error_text(e)) for _ in columns]
            continue
        for k, spec in enumerate(columns):
            note = ""
            for r, w in zip(cells[k], spec["cells"]):
                if spec["dtype"] == "String":
                    ok = text_of(r, code) == w[7:]
                elif w == "Null":
                    ok = r is None
                elif spec["dtype"] == "Float":
                    ok = f"Float {bits(r)}" == w
                elif w.startswith("Date"):
                    ok = to_day(r) == int(w.split(" ")[1])
                else:
                    ok = (whole_micros(r) if spec["format"] in TIME_FORMATS else to_instant(r)) == int(w.split(" ")[1])
                if not ok:
                    note = f"column {spec['name']!r}: {r!r} where the sidecar spells {w}"
                    break
            verdicts[name].append(("agrees", "") if not note else ("differs", note))
    return verdicts


def verdict_summary(verdicts):
    """{verdict: count} and the notes behind the ones that are not ``agrees``."""
    counts = {}
    notes = []
    for verdict, note in verdicts:
        counts[verdict] = counts.get(verdict, 0) + 1
        if verdict != "agrees" and note not in notes:
            notes.append(note)
    return counts, notes


# ---------------------------------------------------------------- the corpus


def write_bytes(name, data):
    path = os.path.join(FIX, name + ".sas7bdat")
    with open(path, "wb") as fh:
        fh.write(bytes(data))
    return path


def read_bytes(path):
    with open(path, "rb") as fh:
        return bytearray(fh.read())


def varied(rng, count):
    """``count`` letters with no three alike in a row, so no run-length command swallows them."""
    alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    out = []
    while len(out) < count:
        c = rng.choice(alphabet)
        if len(out) >= 2 and out[-1] == c and out[-2] == c:
            continue
        out.append(c)
    return "".join(out)


def nan():
    return float("nan")


def write_pyreadstat():
    """The tables the reference writer produces: {fixture name: (path, note)}."""
    rng = random.Random(0x5A37)
    files = {}

    def put(name, frame, note, **kwargs):
        path = os.path.join(FIX, name + ".sas7bdat")
        pyreadstat.write_sas7bdat(frame, path, **kwargs)
        files[name] = (path, note)

    put(
        "w32_pyrs",
        pd.DataFrame({"a": [1.0, 2.0], "b": ["x", "yy"]}),
        "pyreadstat write_sas7bdat(is_64bit=False): the 32-bit layout, uncompressed — a MIX page of 65536 bytes behind a 1024-byte header",
        is_64bit=False,
    )
    pieces = (
        "ab" + " " * 20 + varied(rng, 22) + " " * 20 + varied(rng, 40) + " " * 20
        + varied(rng, 60) + " " * 20 + varied(rng, 70) + " " * 20 + varied(rng, 10)
    )
    put(
        "rle32_pyrs",
        pd.DataFrame(
            {
                "long": [varied(rng, 2000), varied(rng, 1500), varied(rng, 900)],
                "pieces": [pieces, pieces, pieces],
                "at": ["@" * 40, "a@@b", "@" * 5],
                "blank": [" " * 40, "a  b", "   "],
                "z": ["z" * 30, "q" * 10, "zz"],
                "n1": [0.0, 1.0, 0.0],
                "n2": [0.0, 2.0, 0.0],
                "n3": [0.0, 3.0, 0.0],
                "latest_d": [2932896.0, 18109.0, 0.0],
                "latest_dt": [253402300799.999904, 1564703999.999, 0.0],
                "tail": ["end", "fin", "fin"],
            }
        ),
        "pyreadstat write_sas7bdat(is_64bit=False, row_compress=True): rows compressed with the CHAR method (SASYZCRL) — every command but one, and the latest date and datetime the format holds under their formats; pandas cannot open it, its decoder lacking the command that inserts a run of at-signs",
        is_64bit=False,
        row_compress=True,
        variable_format={"latest_d": "DATE", "latest_dt": "DATETIME"},
    )
    half = varied(rng, 350)
    put(
        "rdc32_pyrs",
        pd.DataFrame(
            {
                "pattern": ["abcabcabcabcabcabcabcabcabcabc", "abcdefgh" * 5, "x" * 40],
                "far": [half + half, half[:300] + half[:300], half[:100]],
                "y": ["y" * 10, "yyyyyy", "y"],
                "n1": [0.0, 1.0, 0.0],
                "n2": [0.0, 2.0, 0.0],
                "n3": [0.0, 3.0, 0.0],
                "tail": ["end", "fin", "fin"],
            }
        ),
        "pyreadstat write_sas7bdat(is_64bit=False, compress=True): rows compressed with the BINARY method (SASYZCR2) — short and long runs, copies from near and from far",
        is_64bit=False,
        compress=True,
    )
    return files


def make_synthetic():
    """The synthetic files, laid out from scratch: {name: (path, note)}."""
    out = {}

    def put(name, data, note, layout="a header and one MIX page of 4096 bytes"):
        out[name] = (
            write_bytes(name, data),
            "laid out from scratch by the generator (sas7bdat_build.py): " + layout + "; " + note,
        )

    # The kinds of value a column can hold, in a file that says UTF-8: an
    # integer, floats (NaN, infinities, -0.0, the extremes), a boolean, text
    # of one, two and three bytes a character, padded, blank, and the missing
    # spellings as text.
    i = [1, -2, 2**53, -(2**53), 2**53 + 1]
    f = [0.0, nan(), float("inf"), float("-inf"), 1e-310]
    g = [-0.0, 5e-324, 1.7976931348623157e308, 0.1, -12345.678]
    b = [True, False, True, False, True]
    s = [b"abc", "é".encode("utf-8"), "日本語".encode("utf-8"), b"a b", b""]
    t = ["  pad  ", " . ", ".", ".A", "._"]
    u = [".Z", ".a", "a.", "", "   "]
    kinds = [("i", "n", 8), ("f", "n", 8), ("g", "n", 8), ("b", "n", 8), ("s", "s", 9), ("t", "s", 8), ("u", "s", 3)]
    kinds_rows = [
        [i[k], f[k], g[k], b[k], s[k], t[k], u[k]]
        for k in range(5)
    ]
    put(
        "kinds_syn",
        B.build(kinds, kinds_rows, True, True, True, charset=20),
        "64-bit, little-endian, 4-byte aligned; int, float (NaN, infinities, -0.0, the extremes), bool, UTF-8 text (padded, blank, and the missing spellings as text)",
    )

    # Every date, time and datetime family, whole units and a missing cell
    # each; two columns on the 4000-year boundaries of the format's calendar.
    cells = {}
    formats = {}
    order = []
    k = 0
    for name in ["DATE", "MMDDYY", "YYMMDD", "JULIAN", "WEEKDATE", "WEEKDATX", "B8601DA", "E8601DA", "IS8601DA", "MINGUO"]:
        cells[f"v{k}"] = [1.0, 20000.0, nan(), 0.0]
        formats[f"v{k}"] = name
        order.append(f"v{k}")
        k += 1
    for name in ["TIME", "HHMM", "MMSS", "HOUR", "TOD", "TIMEAMPM", "E8601TM", "B8601TM", "IS8601TM"]:
        cells[f"v{k}"] = [0.0, 3661.5, nan(), 12345.678]
        formats[f"v{k}"] = name
        order.append(f"v{k}")
        k += 1
    for name in ["DATETIME", "DATEAMPM", "MDYAMPM", "DTDATE", "B8601DT", "E8601DT", "IS8601DT", "B8601DN"]:
        cells[f"v{k}"] = [1.0, 12345.678, nan(), 0.0]
        formats[f"v{k}"] = name
        order.append(f"v{k}")
        k += 1
    cells["cal_date"] = [745153.0, 745154.0, 2206122.0, 2206123.0]
    formats["cal_date"] = "DATE"
    cells["cal_dt"] = [745153.0 * 86400 + 1, 745154.0 * 86400 + 1, 2206122.0 * 86400 + 1, 2206123.0 * 86400 + 1]
    formats["cal_dt"] = "DATETIME"
    order += ["cal_date", "cal_dt"]
    put(
        "formats_syn",
        B.build(
            [(name, "n", 8) for name in order],
            [[cells[name][r] for name in order] for r in range(4)],
            True,
            True,
            True,
            charset=20,
            page_size=8192,
            formats=formats,
        ),
        "64-bit, little-endian, 4-byte aligned; every date, time and datetime family the reference writer attaches, whole units and a missing cell each; two columns on the 4000-year boundaries",
        layout="a header and one MIX page of 8192 bytes",
    )

    # A fractional day, a time below a microsecond and a datetime below a
    # microsecond leave the column numbers; half-second datetimes and whole
    # days convert.
    put(
        "frac_syn",
        B.build(
            [("d", "n", 8), ("t", "n", 8), ("dt", "n", 8), ("h", "n", 8), ("w", "n", 8)],
            [[1.5, 1e-9, 0.5, 0.5, 1.0], [2.25, 0.5, 1e-9, 1.5, 2.0]],
            True,
            True,
            True,
            charset=20,
            formats={"d": "DATE", "t": "TIME", "dt": "DATETIME", "h": "DATETIME", "w": "DATE"},
        ),
        "64-bit, little-endian, 4-byte aligned; a fractional day, a time below a microsecond and a datetime below a microsecond beside whole ones",
    )

    three = [("a", "n", 8), ("b", "s", 8), ("c", "n", 8)]
    put(
        "no_rows_syn",
        B.build(three, [], True, True, True, charset=20, formats={"c": "DATE"}),
        "64-bit, little-endian, 4-byte aligned; three columns (one under a date format) and no row",
    )
    put(
        "all_missing_syn",
        B.build(
            [("a", "n", 8), ("b", "n", 8), ("c", "n", 8), ("e", "s", 4)],
            [[nan(), nan(), nan(), ""] for _ in range(2)] + [[nan(), nan(), nan(), None]],
            True,
            True,
            True,
            charset=20,
            formats={"a": "DATE", "b": "DATETIME"},
        ),
        "64-bit, little-endian, 4-byte aligned; columns of nothing but missing values (two under date formats) and one of nothing but blank text",
    )

    # Names at the format's 32 characters, and a character variable as wide
    # as one can be: two rows of 32800 bytes on one MIX page.
    put(
        "names_syn",
        B.build(
            [("a" * 32, "n", 8), ("_lead9", "n", 8), ("Mixed_Case", "n", 8), ("d1g1ts", "n", 8), ("wide", "s", 32767)],
            [[1.0, 3.0, 5.0, 7.0, "x" * 32767], [2.0, 4.0, 6.0, 8.0, "y" * 100]],
            False,
            True,
            False,
            page_size=69632,
        ),
        "32-bit, little-endian; names at the format's 32 characters and a character variable 32767 bytes wide",
        layout="a header and one MIX page of 69632 bytes",
    )

    # The 28 missing spellings as the format's own producer writes them,
    # then numbers that are not missing: a quiet NaN, both infinities, -0.0.
    spellings = [0x7FFFFFFE00000000, 0x7FFFFFFF00000000]
    spellings += [0xFFFFFF0000000000 | ((0xFD - k) << 40) for k in range(26)]
    lookalikes = [0x7FF8000000000000, 0x7FF0000000000000, 0xFFF0000000000000, 0x8000000000000000]
    put(
        "missing_syn",
        B.build(
            [("m", "n", 8), ("keep", "n", 8)],
            [[B.from_bits(value), float(k)] for k, value in enumerate(spellings + lookalikes)],
            True,
            True,
            True,
            charset=20,
        ),
        "64-bit, little-endian, 4-byte aligned; the 28 missing spellings (., ._ and .A to .Z as SAS spells them) in rows 1 to 28, then a quiet NaN, +inf, -inf and -0.0",
    )

    # Numeric columns narrower than eight bytes, in every layout the format
    # has, since no reference writer makes them.
    texts = ["ab", "", "é x"]
    laid_out = [
        (
            "minimal_le32_syn",
            False,
            True,
            False,
            [1, 2, 3, 4, 5, 6, 7, 8],
            "32-bit, little-endian, unpadded; numeric columns 1 to 8 bytes wide and a text column; pyreadstat cannot open it, refusing numeric columns under 3 bytes",
        ),
        (
            "minimal_be32_syn",
            False,
            False,
            True,
            [3, 4, 5, 6, 7, 8],
            "32-bit, big-endian, 4-byte aligned; numeric columns 3 to 8 bytes wide and a text column",
        ),
        (
            "minimal_le64_syn",
            True,
            True,
            True,
            [3, 4, 5, 6, 7, 8],
            "64-bit, little-endian, 4-byte aligned; numeric columns 3 to 8 bytes wide and a text column",
        ),
        (
            "minimal_be64_syn",
            True,
            False,
            True,
            [3, 4, 5, 6, 7, 8],
            "64-bit, big-endian, 4-byte aligned; numeric columns 3 to 8 bytes wide and a text column",
        ),
    ]
    for name, wide, little, pad, widths, note in laid_out:
        columns = [(f"w{w}", "n", w) for w in widths] + [("t", "s", 6)]
        rows = [
            [B.compact_values(w)[k] for w in widths] + [texts[k]]
            for k in range(3)
        ]
        put(name, B.build(columns, rows, wide, little, pad), note)

    # Column names past the 32 characters the reference writer allows, and
    # an empty one: a name is a reference into the text block, of any length.
    columns = [("n" * 33, "n", 8), ("short", "n", 8), ("z" * 40, "s", 4), ("", "n", 8)]
    put(
        "long_names_syn",
        B.build(columns, [[1.0, 2.0, "ab", 3.0], [4.0, 5.0, "", 6.0]], False, True, False),
        "32-bit, little-endian; column names of 33 and 40 characters, one of 5, and an empty one",
    )

    # A numeric column with no format subheader: the last column's is left out.
    put(
        "noformat_syn",
        B.build([("a", "n", 8), ("b", "n", 8)], [[1.0, 2.0]], True, True, True, charset=20, format_count=1),
        "64-bit, little-endian, 4-byte aligned; one observation, and the second numeric column with no format subheader",
    )

    # A cell that is not well-formed UTF-8 in a file that says UTF-8.
    put(
        "badutf8_syn",
        B.build([("s", "s", 3), ("n", "n", 8)], [[b"\xff x", 1.0], [b"abc", 2.0]], True, True, True, charset=20),
        "64-bit, little-endian, 4-byte aligned; the lead byte of a two-byte UTF-8 character in a text cell replaced by FF; refused: ParseError: a text field is not well-formed UTF-8",
    )

    # A compression name this reader does not decode, in the text block's preamble.
    put(
        "unknown_comp_syn",
        B.build(
            [("a", "n", 8), ("b", "s", 10)],
            [[1.0, "xxxxxxxxxx"], [2.0, "yyyyyyyyyy"]],
            True,
            True,
            True,
            charset=20,
            preamble=b"SASYZCR9",
        ),
        "64-bit, little-endian, 4-byte aligned; the text block names the row compression SASYZCR9; refused: Unsupported: its row compression SASYZCR9",
    )

    # The character sets: the kinds table declared Latin-1, so its two- and
    # three-byte characters read one byte to one character; all 128 high
    # bytes under Latin-1, with a high byte in a name; and the code pages
    # real files name, through the generated table.
    put(
        "latin1_syn",
        B.build(
            [("high", "s", 128), ("nàme", "s", 9), ("t", "s", 8), ("u", "s", 3)],
            [
                [bytes(range(0x80, 0x100)), s[1], t[1], u[1]],
                [bytes(range(0xFF, 0x7F, -1)), s[2], t[3], u[0]],
                [b"", s[0], t[2], u[4]],
            ],
            True,
            True,
            True,
            charset=29,
        ),
        "64-bit, little-endian, 4-byte aligned; all 128 bytes from 0x80 on under Latin-1 (code 29), a high byte in a column name, and UTF-8 text read one byte to one character",
    )
    put(
        "cp1252_syn",
        B.build(
            [("nomé", "s", 6), ("t", "s", 3)],
            [["café".encode("cp1252"), "€éÿ".encode("cp1252")], ["ÿ".encode("cp1252"), b"a"]],
            False,
            True,
            False,
            charset=62,
        ),
        "32-bit, little-endian; windows-1252 (code 62): the euro sign, an e-acute and a y-diaeresis in cells, a high byte in a column name",
    )
    put(
        "cp1251_syn",
        B.build(
            [("имя".encode("cp1251"), "s", 12)],
            [["Привет".encode("cp1251")], ["мир".encode("cp1251")]],
            False,
            True,
            False,
            charset=61,
        ),
        "32-bit, little-endian; windows-1251 (code 61): Cyrillic text, and a Cyrillic column name",
    )
    put(
        "latin9_syn",
        B.build([("t", "s", 4)], [["€ŠšŽ".encode("iso8859_15")]], False, True, False, charset=40),
        "32-bit, little-endian; ISO-8859-15 (code 40): the euro sign and its three letters that Latin-1 lacks",
    )
    put(
        "ascii_syn",
        B.build([("t", "s", 4)], [["abcd"]], False, True, False, charset=28),
        "32-bit, little-endian; US-ASCII (code 28)",
    )
    put(
        "undefined_syn",
        B.build([("t", "s", 2)], [[b"\x81x"], [b"ab"]], False, True, False, charset=62),
        "32-bit, little-endian; windows-1252, whose byte 0x81 is undefined, in a text cell; refused: ParseError: a text field holds byte 0x81",
    )
    put(
        "shiftjis_syn",
        B.build([("t", "s", 4)], [["abcd"]], False, True, False, charset=138),
        "32-bit, little-endian; the character-set field names Shift-JIS (code 138); refused: Unsupported: the character-set field names shift_jis (code 138)",
    )
    put(
        "unassigned_syn",
        B.build([("t", "s", 4)], [["abcd"]], False, True, False, charset=250),
        "32-bit, little-endian; the character-set field names 250, which no table assigns; refused: Unsupported: the character-set field names an unassigned code (code 250)",
    )

    # The page kinds: the subheaders on a META page with the rows on two
    # DATA pages; a META2 page; a second text block on an AMD page (pandas
    # cannot open that one).
    rows = [[1.0, "x", nan()], [2.0, "yy", 3.0]]
    put(
        "pages_syn",
        B.build(three, rows * 4, False, True, False, meta_type=B.META, row_pages=2),
        "the subheaders on one page and eight rows over the other two; 32-bit, little-endian",
        layout="a header, a META page and two DATA pages of 4096 bytes",
    )
    put(
        "meta2_syn",
        B.build(three, rows, False, False, True, meta_type=0x4000),
        "32-bit, big-endian, 4-byte aligned",
        layout="a header, a META2 page and a DATA page of 4096 bytes",
    )
    put(
        "amd_syn",
        B.build(three, rows, False, True, False, second_text=("a", "c")),
        "the names of two columns lie in a second text block, on the AMD page; pandas cannot open it; 32-bit, little-endian",
        layout="a header, a MIX page and an AMD page of 4096 bytes",
    )

    # Rows compressed in the layouts the reference writer's compressed files
    # do not come in: 64-bit, either byte order. Every stream copies the
    # row's head as it is and fills its tail — the blank padding of a
    # 24-byte text cell — with one command; the writer's files carry the
    # rest of both grammars.
    pair = [("a", "n", 8), ("b", "s", 24)]
    pair_rows = [[1.0, "x"], [2.0, "yy"]]
    put(
        "rle64_syn",
        B.build(pair, pair_rows, True, True, True, meta_type=B.META, compress="CHAR"),
        "64-bit, little-endian, 4-byte aligned; the rows compressed with the CHAR method (SASYZCRL), each a copy command and a fill of blanks, stored as subheaders on the META page",
        layout="a header and one META page of 4096 bytes",
    )
    put(
        "rdc64_syn",
        B.build(pair, pair_rows, True, False, True, meta_type=B.META, compress="BINARY"),
        "64-bit, big-endian, 4-byte aligned; the rows compressed with the BINARY method (SASYZCR2), each literals under control words and runs of blanks, stored as subheaders on the META page",
        layout="a header and one META page of 4096 bytes",
    )

    # A data set of no variable: its rows are 0 bytes long.
    put(
        "no_columns_syn",
        B.build([], [], False, True, False),
        "32-bit, little-endian; no column and no row; refused: ParseError: the row length is 0",
    )
    return out


# The files of the pandas test corpus, as they are: (name there, fixture
# name or None for the same name, note). A note holding
# ``refused: <variant>: <text>`` marks a file this reader refuses, with a
# substring of its message.
CORPUS_FILES = [
    ("airline.sas7bdat", None, "SAS data set from the pandas test corpus: 32-bit, little-endian, windows-1252 (code 0)"),
    ("cars.sas7bdat", None, "SAS data set from the pandas test corpus: 32-bit, little-endian, windows-1252 (code 0); a MIX page and two DATA pages, numeric columns 3 and 4 bytes wide"),
    ("test16.sas7bdat", None, "SAS 9.4 data set from the pandas test corpus: 64-bit, little-endian, 4-byte aligned, an 8192-byte header; its text cells hold UTF-8 though the header says Latin-1"),
    ("datetime.sas7bdat", None, "SAS data set from the pandas test corpus: windows-1251 (code 61); the date formats YYMMDD, DATE, E8601DA and MINGUO and the datetime format DATETIME, at the extremes a datetime holds"),
    ("test10.sas7bdat", None, "SAS 9.4 data set from the pandas test corpus: 32-bit, big-endian, 4-byte aligned, a 65536-byte header and pages of 65536 bytes; the date format MMDDYY"),
    ("many_columns.sas7bdat", None, "SAS data set from the pandas test corpus: 64-bit, little-endian, unpadded, UTF-8; 392 columns whose names, attributes and formats sit on six pages, three TIME formats parked past the text block's declared size"),
    ("corrupt.sas7bdat", None, "refused: ParseError: holds no page"),
]


def corpus():
    out = {}
    for source, name, note in CORPUS_FILES:
        fixture = name or source[: -len(".sas7bdat")]
        data = bytearray(corpus_bytes(source))
        out[fixture] = (write_bytes(fixture, data), note)
    return out


def compression_commands(path, out):
    """Which commands the file's compressed rows use: {command: count}."""
    with open(path, "rb") as fh:
        data = fh.read()
    counts = {}
    for run in out["raw_runs"]:
        if not run["compressed"]:
            continue
        ipos, end = run["at"], run["at"] + run["length"]
        if out["compression"] == b"SASYZCRL":
            while ipos < end:
                control = data[ipos]
                ipos += 1
                command, low = control >> 4, control & 0x0F
                if command in (0, 1):
                    ipos += 1 + data[ipos] + 64 + low * 256 + (4096 if command == 1 else 0)
                elif command == 2:
                    ipos += low + 96
                elif command == 4:
                    ipos += 2
                elif command in (5, 6, 7):
                    ipos += 1
                elif command == 8:
                    ipos += low + 1
                elif command == 9:
                    ipos += low + 17
                elif command == 10:
                    ipos += low + 33
                elif command == 11:
                    ipos += low + 49
                elif command == 12:
                    ipos += 1
                elif command < 13:
                    raise AssertionError(f"control byte {control:#x}")
                counts[command] = counts.get(command, 0) + 1
            assert ipos == end, (ipos, end)
        else:
            control = mask = 0
            while ipos < end:
                mask >>= 1
                if mask == 0:
                    if end - ipos < 2:
                        break
                    control = (data[ipos] << 8) | data[ipos + 1]
                    ipos += 2
                    mask = 0x8000
                if control & mask == 0:
                    if ipos >= end:
                        break
                    counts["literal"] = counts.get("literal", 0) + 1
                    ipos += 1
                    continue
                command = data[ipos] >> 4
                ipos += 1
                name = {0: "short run", 1: "long run", 2: "long copy"}.get(command, "short copy")
                ipos += {0: 1, 1: 2, 2: 2}.get(command, 1)
                counts[name] = counts.get(name, 0) + 1
    return counts


def refusal_of(note):
    """The refusal a note announces — ``refused: <variant>: <substring of the message>``."""
    if "refused: " not in note:
        return None
    variant, contains = note.split("refused: ", 1)[1].split(": ", 1)
    return {"variant": variant, "contains": contains}


def sidecar_for(name, path, note):
    """The sidecar of one file."""
    with open(path, "rb") as fh:
        data = fh.read()
    entry = {"file": name + ".sas7bdat", "source": note}
    refused = refusal_of(note)
    if refused is not None:
        return {**entry, "readable": False, "refusal": refused}
    out = L.walk(data)
    code = out["encoding_code"]
    if not decoded(code):
        raise RuntimeError(f"{name}: a file of charset code {code} is listed as readable")
    source, columns, problems, gap = expected_columns(path, out, code)
    pandas_own = pandas_verdicts(path, columns)
    pyrs_own = pyreadstat_verdicts(path, columns)
    raw = raw_verdicts(path, columns, code)
    for k, column in enumerate(columns):
        column["pandas"] = pandas_own[k][0]
        column["pyreadstat"] = pyrs_own[k][0]
    pandas_counts, pandas_notes = verdict_summary(pandas_own)
    pyrs_counts, pyrs_notes = verdict_summary(pyrs_own)
    entry.update(
        {
            "readable": True,
            "layout": L.describe(out),
            "rows": int(out["row_count"]),
            "cells_from": source,
            "other_reader": problems.get("pyreadstat" if source == "pandas" else "pandas"),
            "layout_gap": gap,
            "pandas": {"counts": pandas_counts, "notes": pandas_notes[:6]},
            "pyreadstat": {"counts": pyrs_counts, "notes": pyrs_notes[:6]},
            "raw": {
                reader: {"counts": verdict_summary(v)[0], "notes": [n for n in verdict_summary(v)[1]][:4]}
                for reader, v in raw.items()
            },
            "commands": {str(k): v for k, v in sorted(compression_commands(path, out).items())},
            "columns": columns,
        }
    )
    return entry


def patch_map(path):
    """The offsets a refusal test patches in the 32-bit pyreadstat table."""
    with open(path, "rb") as fh:
        data = fh.read()
    out = L.walk(data)
    page = out["pages"][0]
    word = out["word"]
    m = {
        "header_length": out["header_length"],
        "page_length": out["page_length"],
        "page_at": page["at"],
        "page_end": page["at"] + out["page_length"],
        "lead": out["bit"],
        "word": word,
        "pointer": out["pointer"],
        "type_at": page["at"] + out["bit"],
        "blocks_at": page["at"] + out["bit"] + 2,
        "count_at": page["at"] + out["bit"] + 4,
        "rows_at": out["runs"][-1]["at"],
        "row_length": out["rowsize"]["row_length"],
        "row_count": out["row_count"],
        "mix_rows": out["rowsize"]["mix_rows"],
        "file_length": len(data),
        "pointers": [],
    }
    for info in page["pointers"]:
        kind = info.get("kind")
        item = {
            "kind": kind,
            "at": info["at"],
            "sub_at": page["at"] + info["offset"],
            "length": info["length"],
        }
        if kind == "ROWSIZE":
            item["row_length_at"] = item["sub_at"] + 5 * word
            item["row_count_at"] = item["sub_at"] + 6 * word
            item["mix_rows_at"] = item["sub_at"] + 15 * word
        if kind == "COLSIZE":
            item["count_at"] = item["sub_at"] + word
        if kind == "COLTEXT":
            item["size_at"] = item["sub_at"] + word
        if kind in ("COLNAME", "COLATTR"):
            item["first_at"] = item["sub_at"] + word + 8
        if kind == "COLFMT":
            item["first_at"] = item["sub_at"] + 3 * word + 22
        m["pointers"].append(item)
    m["texts"] = [{"at": t["at"], "size": t["size"]} for t in out["texts"]]
    return m


def make():
    os.makedirs(FIX, exist_ok=True)
    for name in os.listdir(FIX):
        if name.endswith(".sas7bdat") or name.endswith(".json"):
            os.remove(os.path.join(FIX, name))
    files = write_pyreadstat()
    files.update(make_synthetic())
    files.update(corpus())
    index = []
    summary = {
        "files": 0, "readable": 0, "refused": 0, "cells": 0, "dtypes": {}, "commands": {},
        "pandas": {}, "pyreadstat": {}, "raw_pandas": {}, "raw_pyreadstat": {},
    }
    for name in sorted(files):
        path, note = files[name]
        entry = sidecar_for(name, path, note)
        with open(os.path.join(FIX, name + ".json"), "w", encoding="utf-8") as fh:
            json.dump(entry, fh, ensure_ascii=True, indent=None, separators=(",", ":"))
        index.append({"file": name + ".sas7bdat", "readable": entry["readable"]})
        summary["files"] += 1
        if not entry["readable"]:
            summary["refused"] += 1
            print(f"{name}: REFUSED {entry['refusal']}")
            continue
        summary["readable"] += 1
        summary["cells"] += sum(len(c["cells"]) for c in entry["columns"])
        for c in entry["columns"]:
            summary["dtypes"][c["dtype"]] = summary["dtypes"].get(c["dtype"], 0) + 1
            summary["pandas"][c["pandas"]] = summary["pandas"].get(c["pandas"], 0) + 1
            summary["pyreadstat"][c["pyreadstat"]] = summary["pyreadstat"].get(c["pyreadstat"], 0) + 1
        for k, v in entry["commands"].items():
            summary["commands"][k] = summary["commands"].get(k, 0) + v
        print(f"{name}: {entry['layout']}")
        print(
            f"   cells from {entry['cells_from']}; pandas {entry['pandas']['counts']}; pyreadstat {entry['pyreadstat']['counts']}; "
            f"raw pandas {entry['raw']['pandas']['counts']}, raw pyreadstat {entry['raw']['pyreadstat']['counts']}; "
            f"layout gap {entry['layout_gap']}; commands {entry['commands']}"
        )
    with open(os.path.join(FIX, "index.json"), "w", encoding="utf-8") as fh:
        json.dump(index, fh, indent=None)
    with open(os.path.join(FIX, "w32_pyrs.map.json"), "w", encoding="utf-8") as fh:
        json.dump(patch_map(files["w32_pyrs"][0]), fh, indent=None)
    print(
        f"reference corpus: {summary['files']} files, {summary['readable']} readable, {summary['refused']} refused; "
        f"{summary['cells']} cells; columns by dtype {summary['dtypes']}; "
        f"columns pandas agrees with {summary['pandas'].get('agrees', 0)}, differs {summary['pandas'].get('differs', 0)}, cannot open {summary['pandas'].get('cannot open', 0)}; "
        f"pyreadstat agrees with {summary['pyreadstat'].get('agrees', 0)}, differs {summary['pyreadstat'].get('differs', 0)}, cannot open {summary['pyreadstat'].get('cannot open', 0)}; "
        f"compression commands over the corpus {summary['commands']}"
    )
    return summary


def verify():
    """Re-read every file and compare with the sidecar on disk."""
    with open(os.path.join(FIX, "index.json"), encoding="utf-8") as fh:
        index = json.load(fh)
    mismatches = []
    cells = 0
    for item in index:
        name = item["file"][: -len(".sas7bdat")]
        path = os.path.join(FIX, item["file"])
        with open(os.path.join(FIX, name + ".json"), encoding="utf-8") as fh:
            on_disk = json.load(fh)
        again = sidecar_for(name, path, on_disk["source"])
        if again["readable"] != on_disk["readable"]:
            mismatches.append(f"{name}: readable {again['readable']} against {on_disk['readable']}")
            continue
        if not again["readable"]:
            if again["refusal"] != on_disk["refusal"]:
                mismatches.append(f"{name}: refusal {again['refusal']} against {on_disk['refusal']}")
            continue
        if again["rows"] != on_disk["rows"]:
            mismatches.append(f"{name}: {again['rows']} rows against {on_disk['rows']}")
        if len(again["columns"]) != len(on_disk["columns"]):
            mismatches.append(f"{name}: {len(again['columns'])} columns against {len(on_disk['columns'])}")
            continue
        for a, b in zip(again["columns"], on_disk["columns"]):
            for key in ("name", "dtype", "cells", "format", "width", "pandas", "pyreadstat"):
                if a[key] != b[key]:
                    mismatches.append(f"{name}, column {b['name']!r}: {key} differs")
                    break
            cells += len(b["cells"])
        for key in ("pandas", "pyreadstat", "raw", "layout_gap", "cells_from"):
            if json.dumps(again[key], sort_keys=True) != json.dumps(on_disk[key], sort_keys=True):
                mismatches.append(f"{name}: {key} differs")
    print(f"verify: {len(index)} files re-read, {cells} cells compared with the sidecars, {len(mismatches)} mismatches")
    for m in mismatches[:40]:
        print("   " + m)
    return 1 if mismatches else 0


if __name__ == "__main__":
    step = sys.argv[1] if len(sys.argv) > 1 else ""
    if step == "make":
        make()
    elif step == "verify":
        sys.exit(verify())
    else:
        print(__doc__)
        sys.exit(2)
