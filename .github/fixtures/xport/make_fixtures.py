"""The XPORT fixtures the codec's tests read, and the check of what the
codec writes.

Two steps, in this order, because the second reads what a test run leaves
behind:

    uv run --no-project --with pandas --with pyreadstat \\
        python -I -X utf8 .github/fixtures/xport/make_fixtures.py make
    moon test -p xport
    uv run --no-project --with pandas --with pyreadstat \\
        python -I -X utf8 .github/fixtures/xport/make_fixtures.py verify

``make`` writes small transport files under ``fixtures/reference/`` and
exact-arithmetic vectors under ``fixtures/vectors/``. The files come from
the one reference writer (pyreadstat's ``write_xport`` at file format
version 5) or — where the name says ``syn`` — from this script, which lays
the records out itself; beside each is a JSON sidecar.

A sidecar's cells are this script's own reading of the bytes under the
rules the codec claims — an IBM spelling by exact rational arithmetic, a
date, time or datetime format by its family — so that no expectation
comes from the codec. Per column it records whether the reference reader
that converts dates (pyreadstat's ``read_xport``) returned the same cells,
and whether pandas' ``read_sas`` agrees cell for cell: pandas converts
nothing, so it meets a date, time or datetime column as raw seconds.

A cell is spelled ``<kind> <payload>``: ``Null``, ``Bool 1``, ``Int 12``,
``Float <16 hex digits of the IEEE bits>``, ``String <text>``, ``Date <days
since 1970-01-01>``, ``Timestamp <microseconds since 1970-01-01>``.

``verify`` reads every file the codec's tests wrote under
``fixtures/codec_written/`` with both reference readers, checks the file's
structure with this script's own parse of the layout, and compares the
cells with the table the codec was handed, cell by cell; it prints the
result and exits non-zero on a mismatch that is not one of the named
reference deviations.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import random
import shutil
import struct
import sys
import warnings
from fractions import Fraction
from pathlib import Path

import numpy as np
import pandas as pd
import pyreadstat

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
REFERENCE = HERE / "reference"
# What a test run of the codec leaves behind, for `verify` to read.
CODEC = ROOT / "_build" / "xport_written"

EPOCH_ORDINAL = dt.date(1970, 1, 1).toordinal()
SAS_EPOCH_DAYS = 3653
SAS_EPOCH_MICROS = 315619200000000
PANDAS_ZERO = 2.0**-260  # what pandas answers for a cell of eight zero bytes

DAY_FORMATS = {
    "DATE", "MMDDYY", "DDMMYY", "YYMMDD", "JULIAN", "YYQ", "WEEK", "WEEKDATE",
    "WEEKDATX", "DAY", "NENGO",
}
CLOCK_FORMATS = {"TIME", "HHMM", "MMSS", "HOUR", "TOD"}
INSTANT_FORMATS = {
    "DATETIME", "DATEAMPM", "MDYAMPM", "DTDATE", "B8601DT", "B8601DN", "E8601DT",
}

LIBRARY = b"HEADER RECORD*******LIBRARY HEADER RECORD!!!!!!!000000000000000000000000000000  "
MEMBER = b"HEADER RECORD*******MEMBER  HEADER RECORD!!!!!!!000000000000000001600000000140  "
DESCRIPTOR = b"HEADER RECORD*******DSCRPTR HEADER RECORD!!!!!!!000000000000000000000000000000  "
OBS = b"HEADER RECORD*******OBS     HEADER RECORD!!!!!!!000000000000000000000000000000  "
NAMESTR = struct.Struct(">hhhh8s40s8shhh2s8shhl52s")
MISSING = b"." + b"\0" * 7

# IBM spellings chosen by hand, each sixteen hex digits.
SPELLINGS = [
    # Integers and simple fractions.
    "4110000000000000", "c110000000000000", "4118000000000000", "401999999999999a",
    "4210000000000000", "c210000000000000", "4010000000000000", "4330000000000000",
    "c0e1000000000000",
    # 53 significant bits: exact, with and without trailing zeros.
    "4210000000000001", "4230000000000004",
    # 56 significant bits under exponent 0x42 (three bits to drop): lost
    # below a half, at a half with the kept part even and odd, above.
    "4280000000000001", "4280000000000004", "428000000000000c", "4280000000000007",
    # 55 significant bits (two bits to drop).
    "4240000000000001", "4240000000000002", "4260000000000002", "4240000000000003",
    # 54 significant bits (one bit to drop), also through trailing zeros.
    "4220000000000001", "4220000000000003", "427000000000000c",
    # Rounding carries into a new exponent, and the largest magnitude.
    "42ffffffffffffff", "7fffffffffffffff", "ffffffffffffffff",
    # Fractions with a leading zero hex digit, and unnormalized zeros.
    "4101000000000000", "4000000000000000", "8100000000000000", "8000000000000000",
    "0000000000000001", "0010000000000000",
]


# ---------------------------------------------------------------- cells ----


def enc_float(value) -> str:
    return "Float " + struct.pack(">d", float(value)).hex()


def enc_date(days) -> str:
    return f"Date {int(days)}"


def enc_stamp(micros) -> str:
    return f"Timestamp {int(micros)}"


def micros_of(value) -> int:
    """Microseconds since 1970-01-01 of a datetime the reader answered."""
    stamp = value.to_datetime64() if isinstance(value, pd.Timestamp) else np.datetime64(value)
    return int(np.datetime64(stamp, "us").astype("int64"))


def is_null(value) -> bool:
    if value is None or value is pd.NaT:
        return True
    return isinstance(value, (float, np.floating)) and math.isnan(value)


# ------------------------------------------------------------- IBM floats ----


def ibm_bytes(x) -> bytes:
    """The IBM spelling of a double, by integer arithmetic on its bits."""
    if x != x:
        return MISSING
    if x == 0.0:
        return b"\0" * 8
    bits = struct.unpack(">Q", struct.pack(">d", x))[0]
    sign, stored, frac = bits >> 63, (bits >> 52) & 0x7FF, bits & ((1 << 52) - 1)
    if stored in (0, 0x7FF):
        raise ValueError("outside the IBM range")
    exponent = stored - 1023
    base16 = (exponent + 4) // 4
    if not -64 <= base16 <= 63:
        raise ValueError("outside the IBM range")
    return bytes([(sign << 7) | (base16 + 64)]) + (((1 << 52) | frac) << (exponent + 4 - 4 * base16)).to_bytes(7, "big")


def ibm_fraction(cell : bytes) -> Fraction:
    """The exact value of an IBM spelling, as a rational number."""
    first = cell[0]
    exponent, fraction = first & 0x7F, int.from_bytes(cell[1:8], "big")
    return (-1 if first & 0x80 else 1) * fraction * Fraction(2) ** (4 * (exponent - 78))


def is_missing(cell : bytes) -> bool:
    return cell[1:8] == b"\0" * 7 and (cell[0] in (0x2E, 0x5F) or 0x41 <= cell[0] <= 0x5A)


def cell_double(cell : bytes) -> float:
    """The nearest double, correctly rounded: Python's fraction-to-float. A
    zero fraction keeps its sign bit, which a rational number cannot."""
    if cell[1:8] == b"\0" * 7 and cell[0] & 0x80:
        return -0.0
    return float(ibm_fraction(cell))


def family(fmt : str) -> str | None:
    base = fmt.rstrip("0123456789")
    for name, group in (("day", DAY_FORMATS), ("clock", CLOCK_FORMATS), ("instant", INSTANT_FORMATS)):
        if base in group:
            return name
    return None


def as_days(value : float) -> int | None:
    """The format-family rule on a cell's double: whole days, or nothing."""
    if value != math.floor(value) or abs(value) > 9e18:
        return None
    return int(value)


def as_micros(value : float) -> int | None:
    """Whole microseconds the double spells without loss, or nothing."""
    if value == 0.0:
        return 0
    scaled = value * 1e6
    if scaled != math.floor(scaled) or abs(scaled) > 9e18 or scaled / 1e6 != value:
        return None
    return int(scaled)


def convert_float_cells(values, fmt : str):
    """(`dtype`, cells) of a numeric column of doubles under `fmt`."""
    plain = ["Null" if is_null(v) else enc_float(v) for v in values]
    kind = family(fmt)
    if kind is None:
        return "Float", plain
    out = []
    for v in values:
        if is_null(v):
            out.append("Null")
            continue
        if kind == "day":
            days = as_days(float(v))
            cell = None if days is None else enc_date(days - SAS_EPOCH_DAYS)
        else:
            micros = as_micros(float(v))
            if micros is None:
                cell = None
            else:
                cell = enc_stamp(micros - (SAS_EPOCH_MICROS if kind == "instant" else 0))
        if cell is None:
            return "Float", plain
        out.append(cell)
    return ("Date" if kind == "day" else "Timestamp"), out


# ----------------------------------------------------------- file layout ----


def build(columns, *, namestr_length : int = 140) -> bytes:
    """A Version 5 file holding `columns`: (name, "num" | "char", width,
    format, cells). A numeric cell is a float or its eight bytes, or None
    for missing; a character cell is bytes."""
    out = bytearray()
    out += LIBRARY
    out += b"SAS     SAS     SASLIB  6.06    bsd4.2".ljust(64, b" ") + b"01JAN80:00:00:00"
    out += b"01JAN80:00:00:00".ljust(80, b" ")
    out += MEMBER.replace(b"0000000140", f"{namestr_length:010d}".encode()) + DESCRIPTOR
    out += b"SAS     DATASET SASDATA 6.06    bsd4.2".ljust(64, b" ") + b"01JAN80:00:00:00"
    out += b"01JAN80:00:00:00".ljust(80, b" ")
    out += b"HEADER RECORD*******NAMESTR HEADER RECORD!!!!!!!" + f"{len(columns):010d}".encode() + b"00000000000000000000  "
    position = 0
    for index, (name, kind, width, fmt, _) in enumerate(columns):
        record = NAMESTR.pack(1 if kind == "num" else 2, 0, width, index + 1, name.encode().ljust(8)[:8],
                              b"", fmt.encode().ljust(8)[:8], 0, 0, 1 if kind == "num" else 0,
                              b"\0\0", b"", 0, 0, position, b"\0" * 52)
        out += record[:namestr_length].ljust(namestr_length, b"\0")
        position += width
    out += b" " * (-len(out) % 80)
    out += OBS
    for row in range(len(columns[0][4])):
        for _, kind, width, _, cells in columns:
            cell = cells[row]
            if kind == "num":
                cell = MISSING if cell is None else (cell if isinstance(cell, bytes) else ibm_bytes(cell))
                out += cell[:width].ljust(width, b"\0")
            else:
                out += (b"" if cell is None else cell).ljust(width)[:width]
    out += b" " * (-len(out) % 80)
    return bytes(out)


def parse_layout(raw : bytes) -> dict:
    namestr_length = int(raw[3 * 80 + 68:3 * 80 + 78])
    count = int(raw[7 * 80 + 48:7 * 80 + 58])
    area = -(-count * namestr_length // 80) * 80
    variables, position = [], 0
    for k in range(count):
        start = 640 + k * namestr_length
        p = NAMESTR.unpack(raw[start:start + namestr_length].ljust(140, b"\0"))
        variables.append({"kind": "num" if p[0] == 1 else "char", "width": p[2],
                          "name": p[4].rstrip(b" ").decode("utf-8", "replace"),
                          "format": p[6].rstrip(b" ").decode("latin-1")})
        position += p[2]
    return {"namestr_length": namestr_length, "count": count, "variables": variables,
            "row_width": position, "data_start": 640 + area + 80}


def model_rows(raw : bytes, layout : dict):
    """Observations by the rule the codec reads under: the last byte that
    is not a blank ends the last observation. None when none fits."""
    start, data = layout["data_start"], len(raw) - layout["data_start"]
    if data % 80:
        return None
    last = len(raw) - 1
    while last >= start and raw[last] == 0x20:
        last -= 1
    if last < start:
        return 0
    if layout["count"] == 0:
        return None
    count = (last - start) // layout["row_width"] + 1
    return count if count * layout["row_width"] <= data else None


def model_columns(raw : bytes, layout : dict, rows : int) -> list:
    """This script's own reading of a file's cells, per column:
    (name, dtype, cells, source)."""
    out, offset = [], 0
    for var in layout["variables"]:
        width = var["width"]
        if var["kind"] == "char":
            cells = []
            for row in range(rows):
                start = layout["data_start"] + row * layout["row_width"] + offset
                cells.append("String " + raw[start:start + width].rstrip(b" ").decode("utf-8"))
            out.append((var["name"], "String", cells, "this script's reading of the bytes"))
            offset += width
            continue
        values = []
        for row in range(rows):
            start = layout["data_start"] + row * layout["row_width"] + offset
            cell = raw[start:start + width].ljust(8, b"\0")
            values.append(math.nan if is_missing(cell) else cell_double(cell))
        dtype, cells = convert_float_cells(values, var["format"])
        out.append((var["name"], dtype, cells, "this script's reading of the bytes"))
        offset += width
    return out


# --------------------------------------------------------- reference reads ----


def read_pandas(path : Path):
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            return pd.read_sas(str(path), format="xport", encoding="UTF-8"), None
    except Exception as exc:  # noqa: BLE001
        return None, f"{type(exc).__name__}: {str(exc)[:70]}"


def read_pyreadstat(path : Path):
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
        return pyreadstat.read_xport(str(path))[0], None
    except Exception as exc:  # noqa: BLE001
        return None, f"{type(exc).__name__}: {str(exc)[:70]}"


def reader_cells(var : dict, values : list):
    """(`dtype`, cells) as the reference reader's own values spell them."""
    if var["kind"] == "char":
        return "String", ["String " + (v if isinstance(v, str) else v.decode("utf-8", "replace")) for v in values]
    present = [v for v in values if not is_null(v)]
    dates = lambda v: isinstance(v, dt.date) and not isinstance(v, dt.datetime)  # noqa: E731
    times = lambda v: isinstance(v, dt.time) and not isinstance(v, dt.datetime)  # noqa: E731
    stamps = lambda v: isinstance(v, (dt.datetime, np.datetime64, pd.Timestamp))  # noqa: E731
    cells = []
    if present and all(dates(v) for v in present):
        return "Date", ["Null" if is_null(v) else enc_date(v.toordinal() - EPOCH_ORDINAL) for v in values]
    if present and all(times(v) for v in present):
        for v in values:
            if is_null(v):
                cells.append("Null")
            else:
                cells.append(enc_stamp(((v.hour * 60 + v.minute) * 60 + v.second) * 10**6 + v.microsecond))
        return "Timestamp", cells
    if present and all(stamps(v) for v in present):
        # The reader's datetimes already count from 1970-01-01.
        for v in values:
            if is_null(v):
                cells.append("Null")
            else:
                cells.append(enc_stamp(micros_of(v)))
        return "Timestamp", cells
    return convert_float_cells(values, var["format"])


def pandas_cells(value) -> str:
    if is_null(value):
        return enc_float(math.nan)
    if isinstance(value, str):
        return "String " + value
    return enc_float(value)


def pandas_agrees(cell : str, value, instant : bool = False) -> tuple[bool, bool]:
    """(agrees, is the pandas zero deviation) for one cell. pandas converts
    nothing, so a `Timestamp` cell meets it as the raw seconds: counted
    from 1960-01-01 under a datetime format (`instant`), from midnight
    under a time one."""
    if cell == "Null":
        # A missing text cell is written as blanks, which read as "".
        return (value == "" if isinstance(value, str) else is_null(value)), False
    kind, payload = cell.split(" ", 1)
    if kind == "String":
        return isinstance(value, str) and value == payload, False
    if not isinstance(value, float):
        return False, False
    if kind == "Float":
        expected = struct.unpack(">d", bytes.fromhex(payload))[0]
    elif kind in ("Int", "Bool"):
        expected = float(int(payload))
    elif kind == "Date":
        expected = float(int(payload) + SAS_EPOCH_DAYS)
    else:
        expected = float(Fraction(int(payload) + (SAS_EPOCH_MICROS if instant else 0), 10**6))
    if expected == 0.0 and value == PANDAS_ZERO:
        return True, True
    if expected == 0.0:
        # The writer spells -0.0 as plain zero, so a reader answers 0.0.
        return value == 0.0, False
    return struct.pack(">d", expected) == struct.pack(">d", value), False


def pyreadstat_agrees(cell : str, value) -> bool:
    if cell == "Null":
        return value == "" if isinstance(value, str) else is_null(value)
    kind, payload = cell.split(" ", 1)
    if kind == "String":
        return isinstance(value, str) and value == payload
    if kind == "Date":
        return isinstance(value, dt.date) and not isinstance(value, dt.datetime) and value.toordinal() - EPOCH_ORDINAL == int(payload)
    if kind == "Timestamp":
        return isinstance(value, (dt.datetime, np.datetime64, pd.Timestamp)) and micros_of(value) == int(payload)
    if not isinstance(value, (float, np.floating)):
        return False
    expected = struct.unpack(">d", bytes.fromhex(payload))[0] if kind == "Float" else float(int(payload))
    if expected == 0.0:
        return float(value) == 0.0
    return struct.pack(">d", expected) == struct.pack(">d", float(value))


# ---------------------------------------------------------------- sidecar ----


INDEX : list[dict] = []


def sidecar(path : Path, *, writer : str, note : str) -> dict:
    """Write the sidecar of a file the model reads: this script's cells, and
    which reference readers agreed with them."""
    raw = path.read_bytes()
    layout = parse_layout(raw)
    rows = model_rows(raw, layout)
    model = model_columns(raw, layout, rows)
    pdf, perr = read_pandas(path)
    ydf, yerr = read_pyreadstat(path)
    columns, zero_cells, dropped = [], 0, 0
    for i, (name, dtype, cells, source) in enumerate(model):
        ydtype, ycells = None, None
        if ydf is not None and i < ydf.shape[1]:
            ydtype, ycells = reader_cells(layout["variables"][i], ydf.iloc[:, i].tolist())
        agrees = ycells is not None and ydtype == dtype and ycells == cells
        pcells, pagees, pzero, pextra = [], True, 0, 0
        if pdf is not None and i < pdf.shape[1]:
            pvals = pdf.iloc[:, i].tolist()
            pcells = [pandas_cells(v) for v in pvals]
            shared = min(len(pvals), len(cells))
            pextra = max(0, len(pvals) - len(cells))
            instant = family(layout["variables"][i]["format"]) == "instant"
            pagees = pextra == 0 and all(pandas_agrees(cells[r], pvals[r], instant)[0] for r in range(shared))
            pzero = sum(pandas_agrees(cells[r], pvals[r], instant)[1] for r in range(shared))
        zero_cells += pzero
        columns.append({
            "name": name, "kind": layout["variables"][i]["kind"],
            "format": layout["variables"][i]["format"], "width": layout["variables"][i]["width"],
            "dtype": dtype, "source": source, "cells": cells,
            # The microseconds pandas' raw seconds of a Timestamp cell count from.
            "pandas_from": SAS_EPOCH_MICROS if dtype == "Timestamp" and family(layout["variables"][i]["format"]) == "instant" else 0,
            "pandas": {"rows": len(pcells), "cells": pcells, "agrees": pagees, "zero_cells": pzero, "extra_rows": pextra},
            "pyreadstat": {"agrees": agrees, "dtype": ydtype, "rows": len(ycells) if ycells is not None else None},
        })
    if pdf is not None:
        dropped = max(0, rows - pdf.shape[0])
    side = {
        "file": path.name, "writer": writer, "note": note, "readable": True, "refusal": None,
        "rows": rows, "columns": columns,
        "reference": {
            "pandas": None if pdf is None else {"rows": pdf.shape[0]},
            "pandas_error": perr if pdf is None else None,
            "pyreadstat": None if ydf is None else {"rows": ydf.shape[0]},
            "pyreadstat_error": yerr if ydf is None else None,
            "pandas_zero_cells": zero_cells, "pandas_dropped_rows": dropped,
            "pyreadstat_disagreements": [c["name"] for c in columns if not c["pyreadstat"]["agrees"]],
            "pandas_disagreements": [c["name"] for c in columns if pdf is not None and not c["pandas"]["agrees"]],
        },
    }
    (path.with_suffix(".json")).write_text(json.dumps(side, ensure_ascii=False, indent=1), encoding="utf-8")
    return side


def refusal(path : Path, *, writer : str, variant : str, contains : str, note : str) -> dict:
    side = {"file": path.name, "writer": writer, "note": note, "readable": False,
            "refusal": {"variant": variant, "contains": contains}, "rows": 0, "columns": []}
    path.with_suffix(".json").write_text(json.dumps(side, ensure_ascii=False, indent=1), encoding="utf-8")
    return side


def remember(side : dict) -> None:
    INDEX.append({"file": side["file"], "readable": side["readable"], "rows": side["rows"],
                  "refusal": side["refusal"],
                  "cells": sum(len(c["cells"]) for c in side["columns"])})


# ------------------------------------------------------ reference-written ----

WRITER = "pyreadstat"


def write_reference(name : str, frame : pd.DataFrame, note : str = "", **options) -> Path:
    path = REFERENCE / f"{name}.xpt"
    pyreadstat.write_xport(frame, str(path), file_format_version=5, **options)
    remember(sidecar(path, writer=f"{WRITER} {pyreadstat.__version__} write_xport(file_format_version=5)", note=note))
    return path


def us(values : list) -> pd.Series:
    """Microseconds since 1970-01-01 as datetime64[us]; None is missing."""
    units = [np.datetime64("NaT") if v is None else v for v in values]
    return pd.Series(np.array([int(v) if not isinstance(v, np.datetime64) else v for v in units], dtype="datetime64[us]"))


def make_reference() -> None:
    write_reference("plain_pyrs", pd.DataFrame({
        "num": pd.Series([1, -2, 3, 0, 5], dtype="int64"),
        "ratio": pd.Series([1.5, np.nan, -0.25, 0.0, 2.5], dtype="float64"),
        "flag": [True, False, True, False, False],
        "label": ["ab", "cdef", "", "ghij", "klmnöp"],
    }), note="int64, float64, bool and UTF-8 text; the longest text sits in the last row")

    write_reference("dtypes_pyrs", pd.DataFrame({
        "i8": pd.Series([1, -2, 0], dtype="int8"), "i16": pd.Series([300, -300, 0], dtype="int16"),
        "i32": pd.Series([70000, -70000, 1], dtype="int32"),
        "i64": pd.Series([2**52, -(2**52), 1], dtype="int64"),
        "u8": pd.Series([200, 1, 0], dtype="uint8"), "f32": pd.Series([1.5, -2.5, 0.5], dtype="float32"),
        "b": [True, False, True],
    }), note="every integer width, float32 and bool; all reach the file as 8-byte numbers")

    write_reference("text_pyrs", pd.DataFrame({
        "s": ["é", "日本語😀", "a", "", " leading", "trailing ", "x" * 200],
    }), note="UTF-8 text: two, three and four bytes a character, empty, outer blanks, 200 bytes")

    write_reference("names_pyrs", pd.DataFrame({
        "Mixed": [1.0, 2.0], "lower": [1.0, 2.0], "UPPER9ch": [1.0, 2.0], "a_1": [1.0, 2.0],
        "_x": [1.0, 2.0], "A1b2C3d4": [1.0, 2.0], "x": [0.0, 0.0],
    }), note="names as spelled, at eight characters and with every kind of character")

    write_reference("empty_pyrs", pd.DataFrame({
        "n": pd.Series([], dtype="float64"), "s": pd.Series([], dtype=object),
    }), note="no row, two variables")

    frame = {f"n{k}": [float(k * 7 + r) for r in range(7)] for k in range(10)}
    frame.update({f"s{k}": [("abcdefgh" * (k + 1))[:k + 3]] * 7 for k in range(6)})
    write_reference("wide_pyrs", pd.DataFrame(frame), note="sixteen variables, a row wider than a record")

    dates = [dt.date(1960, 1, 1), dt.date(1970, 1, 1), dt.date(2024, 2, 29), dt.date(1959, 12, 31),
             dt.date(1, 1, 1), dt.date(9999, 12, 31), None, dt.date(2000, 1, 1)]
    write_reference("dates_pyrs", pd.DataFrame({"d": pd.Series(dates, dtype=object)}),
                    note="datetime.date values under the DATE format: both epochs, a leap day, the calendar's ends, a missing cell")

    far = int((dt.datetime(2500, 1, 1) - dt.datetime(1970, 1, 1)).total_seconds()) * 10**6
    stamps = [0, 315619200000000 + 789000, 1709201696789000, -1, 315619200000000, far]
    write_reference("datetimes_pyrs", pd.DataFrame({
        "t": us(stamps), "u": us([1000000, -1000000, None, 0, 315619200000000, 86400000000]),
    }), note="datetime64[us] under the DATETIME format: whole and fractional seconds, before 1970, a missing cell")

    write_reference("datetime_units_pyrs", pd.DataFrame({
        "sec": us([315619200000000, 0]), "ms": pd.Series(np.array([315619200000, 5], dtype="datetime64[ms]")),
        "span": pd.to_timedelta([1.5, None], unit="s"),
    }), note="datetime64[s] and [ms]; the reference writer spells a timedelta as character text")


# --------------------------------------------------------------- synthetic ----


def write_synthetic(name : str, data : bytes, note : str) -> Path:
    path = REFERENCE / f"{name}.xpt"
    path.write_bytes(data)
    remember(sidecar(path, writer="this script", note=note))
    return path


def hexes(text : str) -> list:
    return [bytes.fromhex(h) for h in text.split()]


def make_synthetic() -> None:
    codes = [b"\x2e" + b"\0" * 7, b"\x5f" + b"\0" * 7] + [bytes([c]) + b"\0" * 7 for c in range(0x41, 0x5B)]
    lookalikes = [b"\x2e" + b"\0" * 6 + b"\x01", b"\xc1" + b"\0" * 7, b"\x40" + b"\0" * 7, b"\x80" + b"\0" * 7,
                  b"\x7f" + b"\xff" * 7, b"\xff" + b"\xff" * 7]
    write_synthetic("missing_syn", build([
        ("m", "num", 8, "", codes + lookalikes + [1.0]),
    ]), note="the 28 missing spellings, then lookalikes that are numbers: '.' with a nonzero tail, 0xC1, "
             "two unnormalized zeros, and the two spellings the reference writer uses for infinity")

    widths = [(f"t{w}", "num", w, "", [1.5, -0.25, 7.0]) for w in range(2, 8)]
    write_synthetic("truncated_syn", build(widths),
                    note="numeric variables 2 to 7 bytes wide: a truncated cell is the leading bytes of the 8-byte spelling")

    spellings = SPELLINGS
    write_synthetic("ibm_syn", build([("v", "num", 8, "", hexes(" ".join(spellings)))]),
                    note="IBM spellings by hand: integers, fractions that need rounding from 56 bits, "
                         "fractions with a leading zero hex digit, and both signs")

    shapes = [
        ("rowcount_l4_n1", [("c", "char", 4, "", [b"ab"])]),
        ("rowcount_l4_n3", [("c", "char", 4, "", [b"ab", b"cd", b"ef"])]),
        ("rowcount_l16_n2", [("c", "char", 16, "", [b"ab", b"cd"])]),
        ("rowcount_l12_n5", [("n", "num", 8, "", [1.0] * 5), ("s", "char", 4, "", [b"a", b"b", b"c", b"d", b""])]),
        ("rowcount_blank_last", [("c", "char", 8, "", [b"one", b"two", b""])]),
    ]
    for name, columns in shapes:
        write_synthetic(name, build(columns),
                        note="blank padding against blank cells: the file holds N rows, and the last row of blank character cells reads as padding")

    fam = [
        ("f_ddmmyy", "DDMMYYB", [1.0, 2.0, None]), ("f_date9", "DATE9", [1.0, 2.0, None]),
        ("f_timex", "TIMEX", [1.0, 2.0, None]), ("f_wkdatx", "WEEKDATEx", [1.0, 2.0, None]),
        ("f_e8601", "E8601DT", [86400.0, 1.5, None]), ("f_b8601", "B8601DN", [0.0, 2.0, None]),
        ("f_hour", "HOUR", [7200.0, 1.0, None]), ("f_tod", "TOD", [43200.0, 1.0, None]),
        ("f_lower", "date", [1.0, 2.0, None]), ("f_unknown", "FOO", [1.0, 2.0, None]),
    ]
    write_synthetic("formats_syn", build([(n, "num", 8, f, v) for n, f, v in fam]),
                    note="display formats the reference writer does not attach: letter-suffixed names, a width inside the name, lower case, an unknown name")

    path = REFERENCE / "namestr135_syn.xpt"
    path.write_bytes(build([("a", "num", 8, "", [1.0, 2.0]), ("b", "char", 3, "", [b"x", b"yz"])], namestr_length=135))
    remember(sidecar(path, writer="this script", note="NAMESTRs of 135 bytes, as older files spell them"))

    write_synthetic("longtext_syn", build([
        ("w200", "char", 200, "", [b"x" * 200, b"a"]),
        ("w201", "char", 201, "", [b"y" * 201, b""]),
        ("w255", "char", 255, "", [b"z" * 255, b"b" * 255]),
    ]), note="character variables past the 200 bytes a Version 5 writer holds: the reader takes the width the NAMESTR gives")
    write_synthetic("blankname_syn", build([
        ("", "num", 8, "", [1.0, 2.0]), ("ab", "char", 3, "", [b"x", b"yz"]),
    ]), note="a variable whose name is eight blanks")
    write_synthetic("small_syn", build([
        ("c", "char", 1, "", [b"a", b"", b"z"]),
        ("s", "char", 8, "", [b"", b"  mid  ", b""]),
        ("m", "num", 2, "", [None, 1.0, None]),
    ]), note="a one-byte character variable, blank cells around text, a missing value in a 2-byte numeric variable")

    formats = {"t_time": "TIME", "t_hhmm": "HHMM", "t_tod": "TOD", "t_mmss": "MMSS", "t_hour": "HOUR",
               "d_dt": "DATETIME", "d_ampm": "DATEAMPM", "d_mdyam": "MDYAMPM", "d_dtdate": "DTDATE",
               "y_date": "DATE", "y_mmddyy": "MMDDYY", "y_wkdate": "WEEKDATE", "y_julian": "JULIAN",
               "y_yyq": "YYQ", "y_day": "DAY", "y_week": "WEEK", "y_frac": "DATE", "t_subus": "TIME",
               "t_neg": "TIME", "lower": "date", "date9": "DATE9", "unknown": "FOO"}
    values = {
        "t_time": [3661.5, 0.0, 86399.0, None], "t_hhmm": [3600.0, 7200.0, 1.0, None], "t_tod": [43200.0, 1.0, 2.0, None],
        "t_mmss": [125.5, 1.0, 2.0, None], "t_hour": [7200.0, 1.0, 2.0, None],
        "d_dt": [0.0, 86400.0, 1.5, None], "d_ampm": [0.0, 43200.0, 1.0, None], "d_mdyam": [0.0, 43200.0, 1.0, None],
        "d_dtdate": [0.0, 86400.0, 172800.0, None],
        "y_date": [0.0, 1.0, -1.0, None], "y_mmddyy": [365.0, 366.0, -365.0, None], "y_wkdate": [7.0, 14.0, 21.0, None],
        "y_julian": [100.0, 200.0, 300.0, None], "y_yyq": [1.0, 2.0, 3.0, None], "y_day": [1.0, 2.0, 3.0, None],
        "y_week": [1.0, 2.0, 3.0, None], "y_frac": [1.5, 2.0, 3.0, None], "t_subus": [1e-9, 1.5, 2.0, None],
        "t_neg": [-1.0, 1.0, 2.0, None], "lower": [1.0, 2.0, 3.0, None], "date9": [1.0, 2.0, 3.0, None],
        "unknown": [1.0, 2.0, 3.0, None],
    }
    write_reference("formats_pyrs", pd.DataFrame({k: pd.Series(v, dtype="float64") for k, v in values.items()}),
                    note="every display format family, attached by the reference writer: whole and fractional cells, a sub-microsecond cell, a negative time",
                    variable_format=formats)


# ------------------------------------------------------------------ refusals ----


def make_refusals() -> None:
    path = REFERENCE / "v8_pyrs.xpt"
    pyreadstat.write_xport(pd.DataFrame({"n": [1.0, 2.0]}), str(path), file_format_version=8)
    remember(refusal(path, writer=f"{WRITER} {pyreadstat.__version__} write_xport(file_format_version=8)",
                     variant="Unsupported", contains="a later version of the transport format", note="Version 8: its header records name it"))

    path = REFERENCE / "zerovars_pyrs.xpt"
    pyreadstat.write_xport(pd.DataFrame(), str(path), file_format_version=5)
    remember(sidecar(path, writer=f"{WRITER} {pyreadstat.__version__} write_xport of a table with no column",
                     note="no variable: neither reference reader opens it; the model reads 0 x 0"))

    base = build([("n", "num", 8, "", [1.0, 2.0])])
    cases = {
        "cport_syn": (base[:80].replace(b"LIBRARY HEADER", b"**COMPRESSED**TYPE"), "CPORT",
                      "the library header record of a CPORT file"),
        "notxport_syn": (base[:80].replace(b"LIBRARY", b"LIBRARX"), "not an XPORT file",
                         "a library header record of no known format"),
        "badutf8_syn": (build([("s", "char", 2, "", [b"\xe9", b"ab"])]), "not well-formed UTF-8",
                        "a character cell holding 0xE9, which is not UTF-8"),
        "badtype_syn": (build([("n", "num", 8, "", [1.0, 2.0])])[:640] + b"\x00\x03" + base[642:], "which is neither numeric (1) nor character (2)",
                        "a NAMESTR naming variable type 3"),
    }
    for name, (data, contains, note) in cases.items():
        path = REFERENCE / f"{name}.xpt"
        path.write_bytes(data)
        variant = "Unsupported" if name in ("cport_syn", "notxport_syn", "badtype_syn") else "ParseError"
        remember(refusal(path, writer="this script", variant=variant, contains=contains, note=note))


# ------------------------------------------------------------------ vectors ----


def write_vector(name : str, cases : list, note : str) -> None:
    (VECTORS / f"{name}.json").write_text(json.dumps({"note": note, "cases": cases}, indent=0), encoding="utf-8")


def make_vectors(seed : int = 0x58505431) -> None:
    rng = random.Random(seed)
    specials = SPELLINGS + ["2e00000000000000", "5f00000000000000", "41000000000000",
                            "5a00000000000000", "0000000000000000"]
    bits = [int(h, 16) for h in specials]
    bits += [rng.getrandbits(64) for _ in range(400)]
    to_double, units = [], []
    for b in bits:
        cell = b.to_bytes(8, "big")
        missing = is_missing(cell)
        value = 0.0 if missing else cell_double(cell)
        nearest = struct.pack(">d", value).hex()
        if value == 0.0 and cell[0] & 0x80:
            # A zero fraction is zero, and the sign bit is the sign of it.
            nearest = "8000000000000000"
        to_double.append({"bits": cell.hex(), "missing": missing,
                          "double": None if missing else nearest})
        if missing:
            continue
        days = as_days(value)
        micros = as_micros(value)
        units.append({"bits": cell.hex(), "days": days, "micros": micros})
    write_vector("ibm_to_double", to_double, "the nearest double of each IBM spelling, by exact rational arithmetic; seed 0x58505431")
    write_vector("ibm_units", units, "whole days and whole microseconds of each IBM spelling's double; seed 0x58505431")

    doubles = [0.0, -0.0, 1.0, -1.0, 0.1, 16.0**-65, 16.0**63, 16.0**63 / 2, 1.7976931348623157e308,
               5e-324, 2.2250738585072014e-308, 2.0**-1022, 2.0**-1074, 1e-300, 7.9e75, 1e75, 9007199254740992.0]
    doubles += [struct.unpack(">d", struct.pack(">Q", rng.getrandbits(64)))[0] for _ in range(400)]
    cases = []
    for x in doubles:
        if x != x or math.isinf(x) or x == 0.0:
            # Zero is spelled by the writer's own rule, plain bytes: the
            # bare conversion takes no part in it.
            expected = None
        else:
            try:
                expected = ibm_bytes(x).hex()
            except ValueError:
                expected = None
        cases.append({"double": struct.pack(">d", x).hex(), "ibm": expected})
    write_vector("double_to_ibm", cases, "the IBM spelling of each double, by integer arithmetic on its bits, or null outside the range; seed 0x58505431")
    write_moonbit_vectors(to_double, {u["bits"]: u for u in units}, cases)
    print(f"wrote xport/vectors_wbtest.mbt: {len(to_double)} and {len(cases)} vectors; run moon fmt")


def write_moonbit_vectors(to_double : list, units : dict, doubles : list) -> None:
    """The same vectors as the package's whitebox test file: a whitebox
    file cannot import the test-only packages, so the JSON vectors are
    spelled in MoonBit there. `moon fmt` follows a regeneration."""
    path = ROOT / "internal" / "xport" / "vectors_wbtest.mbt"
    text = [
        "// Whitebox vectors for the IBM conversions. WRITTEN by the fixture",
        "// generator beside the reference files (step `make`) from exact arithmetic",
        "// in Python; do not edit here. After a regeneration run `moon fmt`.",
        "",
        "///|",
        "/// One vector: the 64 bits of a numeric cell as sixteen hex digits,",
        "/// whether it spells a missing value, the bits of the double nearest",
        "/// its value, and its whole days and whole microseconds — `None` where",
        "/// the cell is missing or the rule refuses the count.",
        "fn ibm_vectors() -> ReadOnlyArray[(String, Bool, String, Int64?, Int64?)] {",
        "  [",
    ]
    for case in to_double:
        unit = units.get(case["bits"])
        days = "None" if unit is None or unit["days"] is None else f"Some({unit['days']}L)"
        micros = "None" if unit is None or unit["micros"] is None else f"Some({unit['micros']}L)"
        nearest = case["double"] if case["double"] is not None else ""
        text.append(f'    ("{case["bits"]}", {"true" if case["missing"] else "false"}, "{nearest}", {days}, {micros}),')
    text += [
        "  ]",
        "}",
        "",
        "///|",
        "/// One vector: the bits of a double as sixteen hex digits, and the 64",
        "/// bits of its IBM spelling — the empty string where the double lies",
        "/// outside what a numeric cell holds.",
        "fn double_vectors() -> ReadOnlyArray[(String, String)] {",
        "  [",
    ]
    for case in doubles:
        text.append(f'    ("{case["double"]}", "{case["ibm"] or ""}"),')
    text += [
        "  ]",
        "}",
        "",
        "///|",
        "/// The number that sixteen hex digits spell.",
        "fn vector_hex(text : String) -> UInt64 {",
        "  let units = text.code_units()",
        "  let mut value = 0UL",
        "  for i in 0..<units.length() {",
        "    let c = units[i].to_int()",
        "    let digit = if c >= 48 && c <= 57 {",
        "      c - 48",
        "    } else if c >= 97 && c <= 102 {",
        "      c - 87",
        "    } else {",
        '      abort("not a hex digit")',
        "    }",
        "    value = (value << 4) | digit.to_uint64()",
        "  }",
        "  value",
        "}",
        "",
        "///|",
        "/// The eight bytes of `bits`, most significant first.",
        "fn vector_bytes(bits : UInt64) -> Bytes {",
        "  Bytes::makei(8, i => (bits >> ((7 - i) * 8)).to_byte())",
        "}",
        "",
        "///|",
        'test "an IBM spelling converts as exact arithmetic says" {',
        "  let vectors = ibm_vectors()",
        "  if vectors.length() < 400 {",
        '    fail("only \\{vectors.length()} vectors were generated")',
        "  }",
        "  for (bits, missing, nearest, days, micros) in vectors {",
        "    let cell = ibm_bits(vector_bytes(vector_hex(bits)), 0, 8)",
        "    assert_eq(cell.is_missing(), missing)",
        "    if missing {",
        "      continue",
        "    }",
        "    assert_eq(cell.to_double().reinterpret_as_uint64(), vector_hex(nearest))",
        "    let whole_days : Result[Int64, Unit] = match days {",
        "      Some(d) => Ok(d)",
        "      None => Err(())",
        "    }",
        "    assert_eq(cell.to_days(), whole_days)",
        "    let whole_micros : Result[Int64, Unit] = match micros {",
        "      Some(m) => Ok(m)",
        "      None => Err(())",
        "    }",
        "    assert_eq(cell.to_micros(), whole_micros)",
        "  }",
        "}",
        "",
        "///|",
        'test "a double takes its IBM spelling as integer arithmetic says" {',
        "  let vectors = double_vectors()",
        "  if vectors.length() < 400 {",
        '    fail("only \\{vectors.length()} vectors were generated")',
        "  }",
        "  for (bits, spelling) in vectors {",
        '    let expected : Result[UInt64, Unit] = if spelling == "" {',
        "      Err(())",
        "    } else {",
        "      Ok(vector_hex(spelling))",
        "    }",
        "    assert_eq(ibm_bits_of(vector_hex(bits).reinterpret_as_double()), expected)",
        "  }",
        "}",
        "",
    ]
    path.write_text("\n".join(text), encoding="utf-8", newline="\n")


# ------------------------------------------------------------------- make ----


def cmd_make() -> int:
    print(f"pandas {pd.__version__}, pyreadstat {pyreadstat.__version__}, numpy {np.__version__}, python {sys.version.split()[0]}")
    print("pandas DataFrame.to_sas exists:", hasattr(pd.DataFrame, "to_sas"))
    for folder in (REFERENCE,):
        if folder.exists():
            shutil.rmtree(folder)
        folder.mkdir(parents=True)
    make_reference()
    make_synthetic()
    make_refusals()
    make_vectors()
    (REFERENCE / "index.json").write_text(json.dumps(INDEX, indent=1), encoding="utf-8")
    files = len(INDEX)
    readable = [e for e in INDEX if e["readable"]]
    print(f"reference files: {files} ({len(readable)} the codec reads, {files - len(readable)} it refuses); "
          f"cells: {sum(e['cells'] for e in readable)}; vectors: {len(list(VECTORS.iterdir()))}")
    for entry in INDEX:
        print(f"  {entry['file']}: readable={entry['readable']} rows={entry['rows']} cells={entry['cells']}")
    return 0


# ----------------------------------------------------------------- verify ----


def parse_table(path : Path) -> dict:
    table = json.loads(path.read_text(encoding="utf-8"))
    return table


def check_structure(raw : bytes, table : dict) -> list[str]:
    """Where a codec-written file's layout differs from what this script
    lays out for the same table."""
    errors = []
    if len(raw) % 80:
        errors.append(f"the file is {len(raw)} bytes, not a whole number of records")
    if raw[:80] != LIBRARY:
        errors.append("the library header record is not the layout's")
    if raw[80:240] != b"SAS     SAS     SASLIB  6.06    bsd4.2".ljust(64, b" ") + b"01JAN80:00:00:00" + b"01JAN80:00:00:00".ljust(80, b" "):
        errors.append("the library's description records are not the codec's constant ones")
    if raw[240:400] != MEMBER + DESCRIPTOR:
        errors.append("the member and descriptor header records are not the layout's")
    if raw[400:560] != b"SAS     DATASET SASDATA 6.06    bsd4.2".ljust(64, b" ") + b"01JAN80:00:00:00" + b"01JAN80:00:00:00".ljust(80, b" "):
        errors.append("the member's description records are not the codec's constant ones")
    layout = parse_layout(raw)
    if layout["namestr_length"] != 140:
        errors.append(f"the NAMESTR length is spelled {layout['namestr_length']}, not 140")
    if raw[560:640] != b"HEADER RECORD*******NAMESTR HEADER RECORD!!!!!!!" + f"{len(table['columns']):010d}".encode() + b"00000000000000000000  ":
        errors.append("the NAMESTR header record is not the layout's")
    if raw[layout["data_start"] - 80:layout["data_start"]] != OBS:
        errors.append("the observation header record does not follow the NAMESTRs")
    if layout["count"] != len(table["columns"]):
        return [f"the file names {layout['count']} variables, the table has {len(table['columns'])}"]
    position, width = 0, 0
    for k, (var, column) in enumerate(zip(layout["variables"], table["columns"])):
        start = 640 + k * 140
        p = NAMESTR.unpack(raw[start:start + 140])
        dtype = column["dtype"]
        numeric = dtype in ("Bool", "Int", "Float", "Date", "Timestamp", "Null")
        want_format = {"Date": "DATE", "Timestamp": "DATETIME"}.get(dtype, "")
        texts = [c.split(" ", 1)[1].encode("utf-8") for c in column["cells"] if c != "Null"] if dtype == "String" else []
        want_width = 8 if numeric else max([len(t) for t in texts] + [1])
        for label, got, want in (("type", p[0], 1 if numeric else 2), ("width", p[2], want_width),
                                 ("place", p[3], k + 1), ("name", p[4], column["name"].encode().ljust(8)),
                                 ("label", p[5], b" " * 40), ("format", p[6], want_format.encode().ljust(8)),
                                 ("nfl", p[7], 0), ("nfd", p[8], 0), ("nfj", p[9], 1 if numeric else 0),
                                 ("npos", p[14], position), ("rest", p[15], b"\0" * 52)):
            if got != want:
                errors.append(f"{column['name']}: NAMESTR {label} is {got!r}, not {want!r}")
        if raw[start + 70:start + 72] != b"\0\0" or raw[start + 72:start + 80] != b" " * 8 or raw[start + 80:start + 84] != b"\0\0\0\0":
            errors.append(f"{column['name']}: NAMESTR nfill, niform, nifl or nifd is not blank or zero")
        position += want_width
        width = position
    if table["height"] * width % 80:
        tail = raw[layout["data_start"] + table["height"] * width:]
        if tail != b" " * len(tail):
            errors.append("the padding after the last observation is not blank")
    return errors


def verify_table(path : Path, table : dict) -> tuple[int, int, list[str], dict]:
    """(cells compared, tables a reader cannot open, errors, counts)."""
    errors, compared = [], 0
    counts = {"pandas_zero_cells": 0, "pandas_dropped_rows": 0, "pandas_cannot_open": 0,
              "pyreadstat_cannot_open": 0, "pyreadstat_negative_zero": 0}
    raw = path.read_bytes()
    errors += check_structure(raw, table)
    pdf, perr = read_pandas(path)
    ydf, yerr = read_pyreadstat(path)
    if pdf is None:
        counts["pandas_cannot_open"] = 1
        if table["pandas_opens"]:
            errors.append(f"pandas cannot open the file: {perr}")
    if ydf is None:
        counts["pyreadstat_cannot_open"] = 1
        if table["pyreadstat_opens"]:
            errors.append(f"pyreadstat cannot open the file: {yerr}")
    for i, column in enumerate(table["columns"]):
        cells = column["cells"]
        if pdf is not None and i < pdf.shape[1]:
            if pdf.columns[i] != column["name"]:
                errors.append(f"pandas reads the name {pdf.columns[i]!r}, the table spells {column['name']!r}")
            values = pdf.iloc[:, i].tolist()
            counts["pandas_dropped_rows"] += max(0, len(cells) - len(values))
            for r, value in enumerate(values[:len(cells)]):
                agrees, zero = pandas_agrees(cells[r], value, column["dtype"] == "Timestamp")
                counts["pandas_zero_cells"] += int(zero)
                compared += 1
                if not agrees:
                    errors.append(f"pandas, {column['name']} row {r + 1}: {value!r} against the table's {cells[r]}")
        if ydf is not None and i < ydf.shape[1]:
            if ydf.columns[i] != column["name"]:
                errors.append(f"pyreadstat reads the name {ydf.columns[i]!r}, the table spells {column['name']!r}")
            values = ydf.iloc[:, i].tolist()
            if len(values) != len(cells):
                errors.append(f"pyreadstat reads {len(values)} rows of {column['name']}, the table has {len(cells)}")
            for r, value in enumerate(values[:len(cells)]):
                compared += 1
                if not pyreadstat_agrees(cells[r], value):
                    errors.append(f"pyreadstat, {column['name']} row {r + 1}: {value!r} against the table's {cells[r]}")
    return compared, int(pdf is None), errors, counts


def cmd_verify() -> int:
    print(f"pandas {pd.__version__}, pyreadstat {pyreadstat.__version__}, numpy {np.__version__}")
    tables, compared, cannot, errors_all, counts = 0, 0, 0, [], {}
    for side in sorted(CODEC.glob("*.json")):
        path = side.with_suffix(".xpt")
        table = parse_table(side)
        tables += 1
        cells, unopenable, errors, c = verify_table(path, table)
        compared += cells
        cannot += unopenable
        errors_all += [f"{path.name}: {e}" for e in errors]
        for k, v in c.items():
            counts[k] = counts.get(k, 0) + v
        print(f"  {path.name}: {len(table['columns'])} columns x {table['height']}; "
              f"{'read by both' if not unopenable else 'a reader cannot open it'}; "
              f"{'ok' if not errors else str(len(errors)) + ' errors'}")
    deviations = ", ".join(f"{k} {v}" for k, v in sorted(counts.items()) if v)
    print(f"codec-written tables: {tables}; cells compared: {compared}; tables a reference reader cannot read: {cannot}; "
          f"mismatches: {len(errors_all)}")
    print("known reference deviations: " + (deviations or "none"))
    for e in errors_all[:30]:
        print("  MISMATCH " + e)
    return 1 if errors_all else 0


def main(argv : list[str]) -> int:
    step = argv[1:2]
    if step == ["make"]:
        return cmd_make()
    if step == ["verify"]:
        return cmd_verify()
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
