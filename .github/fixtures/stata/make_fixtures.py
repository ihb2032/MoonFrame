"""The Stata dataset fixtures the codec's tests read, and the check of what
the codec writes.

Two steps, in this order, because the second reads what a test run leaves
behind. Run both from the repository root:

    uv run --no-project --with pandas --with pyreadstat \\
        python -I -X utf8 .github/fixtures/stata/make_fixtures.py make
    moon test -p ihb2032/MoonFrame/internal/stata
    uv run --no-project --with pandas --with pyreadstat \\
        python -I -X utf8 .github/fixtures/stata/make_fixtures.py verify

``make`` writes small dataset files under ``reference/`` beside this script
with the reference implementations (pandas' ``DataFrame.to_stata`` and
pyreadstat's ``write_dta``), and beside each one a JSON sidecar holding the
cells the reference *reader* itself gets from that file, so no expectation
in a test comes from the codec. A few releases or byte orders no reference
writer produces are covered by synthetic files derived from a reference
file; each is named ``synthetic_*`` and its sidecar says exactly what was
changed and which reader confirmed the result.

``verify`` reads every file the codec's export test wrote under
``_build/stata_written/`` with both reference readers and compares the
cells with the table the codec was handed, cell by cell; it prints the
result and exits non-zero on any mismatch.

A cell is spelled ``<kind> <payload>``: ``Null``, ``Bool 1``, ``Int 12``,
``Float <16 hex digits of the IEEE bits>``, ``String <text>``, ``Date <days
since 1970-01-01>``, ``Timestamp <microseconds since 1970-01-01>``.
"""
from __future__ import annotations

import hashlib
import json
import struct
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
import pyreadstat

HERE = Path(__file__).resolve().parent
REFERENCE = HERE / "reference"
# What a test run of the codec leaves behind, for `verify` to read.
CODEC = HERE.parents[2] / "_build" / "stata_written"

STATA_EPOCH_DAYS = 3653  # 1960-01-01 to 1970-01-01
STATA_EPOCH_MILLIS = 315_619_200_000

# The 27 missing codes per numeric storage, as the bits the file spells
# them in: `.` first, then `.a` to `.z`.
CODES = {
    "byte": list(range(101, 128)),
    "int": list(range(32741, 32768)),
    "long": list(range(2147483621, 2147483648)),
    "float": [0x7F000000 + 0x800 * k for k in range(27)],
    "double": [0x7FE0000000000000 + (1 << 40) * k for k in range(27)],
}
CODE_NAMES = ["."] + ["." + chr(ord("a") + k) for k in range(26)]


# ---------------------------------------------------------------- cells ----


def float_hex(value) -> str:
    return struct.pack(">d", float(value)).hex()


def enc_int(value) -> str:
    return f"Int {int(value)}"


def enc_float(value) -> str:
    return f"Float {float_hex(value)}"


def enc_str(value) -> str:
    return f"String {value}"


def enc_date(days) -> str:
    return f"Date {int(days)}"


def enc_stamp(micros) -> str:
    return f"Timestamp {int(micros)}"


def is_number_equal(got, want: float) -> bool:
    """Whether a reference reader's number is `want` exactly."""
    if isinstance(got, (int, np.integer)):
        return int(got) == int(want)
    return float(got) == want


# ------------------------------------------------------- reference reads ----


def read_raw(path: Path) -> pd.DataFrame:
    """The cells the reference reader gets, no conversion applied."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return pd.read_stata(
            path, convert_dates=False, convert_categoricals=False,
            preserve_dtypes=True,
        )


def read_converted(path: Path) -> pd.DataFrame:
    """The reference reader with its date conversion on."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return pd.read_stata(path, convert_dates=True, convert_categoricals=False)


def read_missing_codes(path: Path) -> pd.DataFrame:
    """The reference reader spelling each missing value its code."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        return pd.read_stata(path, convert_missing=True, convert_categoricals=False)


def facts(path: Path) -> dict:
    """The header facts the reference reader itself parses."""
    with pd.io.stata.StataReader(path) as reader:
        reader._ensure_open()
        return {
            "release": int(reader._format_version),
            "byteorder": reader._byteorder,
            "typlist": list(reader._typlist),
            "fmtlist": list(reader._fmtlist),
            "lbllist": list(reader._lbllist),
            "data_location": int(reader._data_location),
            "dtype": reader._dtype,
            "nobs": int(reader._nobs),
            "nvar": int(reader._nvar),
            "varlist": list(reader._varlist),
        }


def storage_name(typ) -> str:
    if isinstance(typ, int):
        return f"str{typ}"
    return {"b": "byte", "h": "int", "l": "long", "f": "float", "d": "double",
            "Q": "strL"}[typ]


def date_family(fmt: str) -> str | None:
    """The date family a display format names, by the codec's rule."""
    if fmt.startswith("%td"):
        return "Date"
    if fmt.startswith("%tc") or fmt.startswith("%tC"):
        return "Timestamp"
    return None


def is_whole(value) -> bool:
    return float(value).is_integer() and abs(float(value)) <= 2 ** 53


def sidecar_columns(raw: pd.DataFrame, header: dict) -> list[dict]:
    """The cells of a file as the codec's contract spells them, taken off
    the reference reader's own raw read."""
    columns = []
    for (name, series), typ, fmt in zip(raw.items(), header["typlist"], header["fmtlist"]):
        columns.append(column_contract(str(name), series, storage_name(typ), fmt))
    return columns


def column_contract(name: str, series, storage: str, fmt: str) -> dict:
    """One column as the codec's contract spells it: its dtype by its
    storage and display format, and its cells."""
    cells: list[str] = []
    if storage == "strL" or storage.startswith("str"):
        dtype = "String"
        cells = [enc_str("" if pd.isna(value) else str(value)) for value in series]
    else:
        family = date_family(fmt)
        present = [v for v in series if not pd.isna(v)]
        if storage in ("byte", "int", "long"):
            dtype = family or "Int"
        else:
            dtype = (family if all(is_whole(v) for v in present) else None) or "Float"
        for value in series:
            if pd.isna(value):
                cells.append("Null")
            elif dtype == "Date":
                cells.append(enc_date(int(value) - STATA_EPOCH_DAYS))
            elif dtype == "Timestamp":
                cells.append(enc_stamp((int(value) - STATA_EPOCH_MILLIS) * 1000))
            elif dtype == "Float":
                cells.append(enc_float(value))
            else:
                cells.append(enc_int(int(value)))
    return {"name": name, "storage": storage, "format": fmt, "dtype": dtype, "cells": cells}


def pyreadstat_cells(path: Path) -> dict[str, list] | None:
    """A second reference reader's cells, or None when it cannot open the
    file."""
    try:
        df, _ = pyreadstat.read_dta(str(path), disable_datetime_conversion=True)
    except Exception:  # noqa: BLE001
        return None
    return {str(c): list(df[c]) for c in df.columns}


def is_missing(value) -> bool:
    return value is None or (isinstance(value, float) and np.isnan(value))


def reference_cell_equal(dtype_file: str, cell: str, theirs) -> bool:
    """Whether one of pyreadstat's cells, read off a file whose column the
    codec's contract maps to `cell`, is that cell."""
    if cell == "Null":
        return dtype_file in ("str", "strL") or is_missing(theirs)
    if is_nan_cell(cell):
        return is_missing(theirs)  # written as the code for `.`
    kind, _, payload = cell.partition(" ")
    if kind == "String":
        return str(theirs) == payload
    if kind == "Float":
        return float_hex(theirs) == payload
    # Int, Date, Timestamp: the file holds the raw count the codec shifted.
    if kind == "Date":
        return is_number_equal(theirs, int(payload) + STATA_EPOCH_DAYS)
    if kind == "Timestamp":
        return is_number_equal(theirs, int(payload) / 1000 + STATA_EPOCH_MILLIS)
    return is_number_equal(theirs, int(payload))


def compare_with_pyreadstat(path: Path, sidecar: dict) -> bool | None:
    """Whether pyreadstat's cells agree with the sidecar. None when it
    cannot open the file."""
    got = pyreadstat_cells(path)
    if got is None:
        return None
    for column in sidecar["columns"]:
        values = got.get(column["name"])
        if values is None:
            return False
        for cell, value in zip(column["cells"], values):
            storage = "str" if column["storage"].startswith("str") else column["storage"]
            if not reference_cell_equal(storage, cell, value):
                return False
    return True


def write_sidecar(path: Path, *, writer: str, synthetic: str | None,
                  source: str, extra: dict | None = None) -> dict:
    header = facts(path)
    raw = read_raw(path)
    if raw.shape[1] != header["nvar"] or raw.shape[0] != header["nobs"]:
        raise SystemExit(f"{path.name}: the reference reader got {raw.shape} "
                         f"where the header says {header['nobs']} x {header['nvar']}")
    sidecar = {
        "file": path.name,
        "writer": writer,
        "release": header["release"],
        "byteorder": "MSF" if header["byteorder"] == ">" else "LSF",
        "synthetic": synthetic,
        "sidecar_source": source,
        "pyreadstat_agrees": None,
        "nobs": header["nobs"],
        "columns": sidecar_columns(raw, header),
    }
    if extra:
        sidecar.update(extra)
    sidecar["pyreadstat_agrees"] = compare_with_pyreadstat(path, sidecar)
    path.with_suffix(".json").write_text(
        json.dumps(sidecar, ensure_ascii=False, indent=1), encoding="utf-8")
    return sidecar


# -------------------------------------------------------- the byte patch ----


def endian_char(dtype) -> str:
    """The struct format's byte-order character for a numpy field dtype
    (`|` is numpy's spelling for a one-byte type, which has no order)."""
    order = np.dtype(dtype).byteorder
    if order in ("=", "|"):
        return "<" if sys.byteorder == "little" else ">"
    return order


class Patcher:
    """Rewrite chosen cells of a reference-written file in place, with the
    reference reader's own record layout locating them. Its record dtype
    names the fields by position, so a column is found through the
    reader's variable list."""

    def __init__(self, path: Path):
        self.path = path
        self.header = facts(path)
        self.raw = bytearray(path.read_bytes())
        dtype = self.header["dtype"]
        self.fields = [dtype.fields[f"s{i}"][0] for i in range(self.header["nvar"])]
        self.offsets = [dtype.fields[f"s{i}"][1] for i in range(self.header["nvar"])]
        self.itemsize = dtype.itemsize

    def index(self, column: str) -> int:
        return self.header["varlist"].index(column)

    def offset(self, column: str, row: int) -> int:
        return self.header["data_location"] + row * self.itemsize + self.offsets[self.index(column)]

    def endian(self, column: str) -> str:
        return endian_char(self.fields[self.index(column)])

    def width(self, column: str) -> int:
        return self.fields[self.index(column)].itemsize

    def set_int(self, column: str, row: int, value: int, code: str) -> None:
        at = self.offset(column, row)
        self.raw[at:at + struct.calcsize(code)] = struct.pack(self.endian(column) + code, value)

    def set_bits(self, column: str, row: int, bits: int, code: str) -> None:
        at = self.offset(column, row)
        self.raw[at:at + struct.calcsize(code)] = struct.pack(self.endian(column) + code, bits)

    def save(self) -> None:
        self.path.write_bytes(bytes(self.raw))


def patch_codes(patcher: Patcher, column: str, rows: dict[int, int], code: str,
                spellings: list[int]) -> dict[str, str]:
    """Rewrite `rows` of `column` to missing codes — row `r` to
    `spellings[rows[r]]`, `code` being the struct format of one cell — and
    say which code each rewritten row now holds."""
    for row, k in rows.items():
        patcher.set_bits(column, row, spellings[k], code)
    return {str(row + 1): CODE_NAMES[k] for row, k in rows.items()}


def confirm_codes(path: Path, expected: dict[str, dict[str, str]],
                  reader_names_codes: bool = True) -> None:
    """Ask the reference readers which code each rewritten cell spells.

    The first reader must read every rewritten cell as missing, and —
    where `reader_names_codes` holds — spell its code. That spelling is
    not asked of a file whose `float` storage carries a code: the first
    reader's code-naming path widens such a NaN and loses its payload,
    and raises. The second reader names the letter of `.a` to `.z` in any
    storage, so it is asked everywhere."""
    raw = read_raw(path)
    spelled = read_missing_codes(path) if reader_names_codes else None
    try:
        named, _ = pyreadstat.read_dta(str(path), user_missing=True)
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(f"{path.name}: pyreadstat cannot name codes here: {exc}")
    for column, rows in expected.items():
        for row, code in rows.items():
            at = int(row) - 1
            if not pd.isna(raw[column].iloc[at]):
                raise SystemExit(f"{path.name}: column {column} row {row} reads "
                                 f"{raw[column].iloc[at]!r}, not missing")
            if code == ".":
                continue
            letter = str(named[column].iloc[at])
            if letter != code[1:]:
                raise SystemExit(f"{path.name}: pyreadstat spells column {column} row {row} "
                                 f"{letter!r}, expected {code!r}")
            if spelled is not None and str(spelled[column].iloc[at]) != code:
                raise SystemExit(f"{path.name}: pandas spells column {column} row {row} "
                                 f"{str(spelled[column].iloc[at])!r}, expected {code!r}")


# ------------------------------------------------------------ the tables ----

LATIN1_TEXT = "Zoë ñ Ünïcode"
UTF8_TEXT = "café 日本語 😀 ñ"
ASCII_TEXT = "plain ascii text"
LONG_ASCII = "x" * 2100                                     # 2100 bytes, past 2045
LONG_UTF8 = "lorem ipsum dolor sit amet " * 75 + " 日本語" * 40   # 2425 bytes, past 2045

# A long string is one no fixed-width storage holds: past 2045 bytes.
for _text in (LONG_ASCII, LONG_UTF8):
    assert len(_text.encode("utf-8")) > 2045, len(_text.encode("utf-8"))


def require_strl(path: Path, name: str) -> None:
    """The reference reader's own header parse must call the `strl` column
    a long string: a writer that stored it as a fixed-width string has not
    exercised the long-string layout."""
    header = facts(path)
    stored = storage_name(header["typlist"][header["varlist"].index("strl")])
    if stored != "strL":
        raise SystemExit(f"{name}: the strl column is stored as {stored}")

# Two facts about the reference writers shape the text below. The second
# writer stores UTF-8 in a release before 118, where the first writer and
# both readers say Latin-1, and the first writer stores the text of a
# release-117 strL as UTF-8 while its own reader decodes it as Latin-1. So
# the second writer's pre-118 files and every 117 strL carry ASCII text
# here, and Latin-1 bytes are covered where a reader confirms them: in the
# first writer's fixed-width strings, and in one 117 strL rewritten after
# the write.

PANDAS_LABELS = {"labelled": {1: "low", 2: "mid", 3: "high"}}


def all_types_frame(text: str, long_text: str, with_strl: bool,
                    strl_text: str | None = None) -> pd.DataFrame:
    frame = pd.DataFrame({
        "tbyte": np.array([1, -2, 100, -127, 0, 0], dtype=np.int8),
        "tint": np.array([1000, -2000, 32000, -32767, 7, 7], dtype=np.int16),
        "tlong": np.array([2000000000, -5, 2147483620, -2147483647, 42, 42], dtype=np.int32),
        "tfloat": np.array([1.5, -2.25, 3.14159, 1e-20, -0.0, 0.5], dtype=np.float32),
        "tdouble": np.array([1 / 3, -4.5, 1e300, 5e-324, -0.0, 0.5], dtype=np.float64),
        "strf": [text, "", "plain", text, "x", "y"],
        "miss": np.array([np.nan, 1.5, np.nan, np.nan, 2.5, 3.5], dtype=np.float64),
        "date": pd.to_datetime(["1960-01-01", "1970-01-01", "2024-02-29",
                                "1900-01-01", "2000-01-01", "1960-01-01"]),
        "stamp": pd.to_datetime([
            "1960-01-01 00:00:00.000", "1970-01-01 00:00:00.000",
            "2024-02-29 12:34:56.789", "1900-01-01 23:59:59.999",
            "2000-01-01 00:00:00.000", "1960-01-01 00:00:00.000",
        ], format="%Y-%m-%d %H:%M:%S.%f"),
        "labelled": np.array([1, 2, 1, 3, 2, 1], dtype=np.int8),
        "numfmt": np.array([1.25, 2.5, -3.75, 4.0, 0.1, 0.2], dtype=np.float64),
    })
    if with_strl:
        frame["strl"] = ["short", long_text, "", long_text, strl_text or text, "short"]
    return frame


def write_pandas(path: Path, version: int, byteorder: str, frame: pd.DataFrame,
                 **kwargs) -> None:
    frame.to_stata(
        path, version=version, byteorder=byteorder, write_index=False,
        time_stamp=pd.Timestamp("2020-01-02 03:04"), data_label="codec fixture",
        **kwargs,
    )


def make_pandas_all_types() -> list[str]:
    names = []
    for version in (114, 117, 118, 119):
        for byteorder in ("<", ">"):
            latin = version < 118
            name = f"pandas_v{version}_{'le' if byteorder == '<' else 'be'}"
            path = REFERENCE / f"{name}.dta"
            frame = all_types_frame(LATIN1_TEXT if latin else UTF8_TEXT,
                                    LONG_ASCII if latin else LONG_UTF8,
                                    with_strl=version >= 117,
                                    strl_text="plain" if latin else UTF8_TEXT)
            write_pandas(
                path, version, byteorder, frame,
                convert_dates={"date": "td", "stamp": "tc"},
                convert_strl=["strl"] if version >= 117 else None,
                value_labels=PANDAS_LABELS,
            )
            if version >= 117:
                require_strl(path, name)
            # The reference writer spells only `.`. Two cells of every
            # numeric column are rewritten to `.a` and `.z`, and the
            # reference readers are asked what they now hold.
            patcher = Patcher(path)
            codes: dict[str, dict[str, str]] = {}
            for column, code in (("tbyte", "b"), ("tint", "h"), ("tlong", "i"),
                                 ("tfloat", "I"), ("tdouble", "Q")):
                codes[column] = patch_codes(patcher, column, {4: 1, 5: 26}, code, CODES[column[1:]])
            patcher.save()
            confirm_codes(path, codes, reader_names_codes=False)
            write_sidecar(
                path,
                writer=f"pandas {pd.__version__} DataFrame.to_stata(version={version}, "
                       f"byteorder='{byteorder}', convert_strl=['strl'])",
                synthetic="rows 5 and 6 of byte, int, long, float and double were rewritten "
                          "after the write to the `.a` and `.z` codes, which the reference "
                          "writer does not spell",
                source=f"pandas {pd.__version__} read_stata(convert_dates=False, "
                       "convert_categoricals=False); every rewritten cell read as missing "
                       "by both reference readers, and spelled `.a` or `.z` by pyreadstat",
                extra={"missing_codes": codes},
            )
            names.append(name)
    return names


PYRS_VERSIONS = {113: 8, 115: 12, 117: 13, 118: 14, 119: 15}


def pyreadstat_frame(release: int) -> tuple[pd.DataFrame, dict, dict, dict]:
    latin = release < 118
    text = ASCII_TEXT if latin else UTF8_TEXT
    fmts = {
        "dlong": "%td", "ddbl": "%td", "tcd": "%tc", "tcl": "%tc", "tcc": "%tC",
        "tm": "%tm", "tq": "%tq", "tw": "%tw", "th": "%th", "ty": "%ty",
        "dold": "%d", "other": "%9.2f", "strf": "%12s",
    }
    frame = pd.DataFrame({
        "dlong": np.array([0, 1, 365, 20059, 0, -1], dtype=np.int32),
        "ddbl": np.array([0.0, 1.0, 365.0, 20059.0, 1.5, -1.0], dtype=np.float64),
        "tcd": np.array([0.0, 1.5, 86400000.0, 1700000000000.0, 0.25, -1.0], dtype=np.float64),
        "tcl": np.array([0, 1, 86399, 172800, 5, -1], dtype=np.int32),
        "tcc": np.array([0.0, 1.0, 86400000.0, 1.7e12, 2.5, -3.0], dtype=np.float64),
        "tm": np.array([0, 1, 12, 240, -1, 600], dtype=np.int32),
        "tq": np.array([0, 1, 4, 80, -1, 200], dtype=np.int32),
        "tw": np.array([0, 1, 52, 1040, -1, 2600], dtype=np.int32),
        "th": np.array([0, 1, 2, 40, -1, 100], dtype=np.int32),
        "ty": np.array([0, 1, 100, 1960, 2024, -1], dtype=np.int32),
        "dold": np.array([0, 1, 365, 20059, 0, -1], dtype=np.int32),
        "other": np.array([1.25, 2.5, -3.75, 4.0, 0.1, -0.2], dtype=np.float64),
        "strf": [text, "", "plain", text, "x", "y"],
        "labelled": np.array([1, 2, 1, 3, 2, 1], dtype=np.int32),
    })
    if release >= 117:
        frame["strl"] = ["short", LONG_ASCII if latin else LONG_UTF8, "",
                         LONG_ASCII if latin else LONG_UTF8, text, "short"]
        fmts["strl"] = "%9s"
    missing = {"missl": ["a", "m", "z"], "missd": ["a", "m", "z"]}
    for column, dtype in (("missl", "int32"), ("missd", "float64")):
        values = np.array([1, 2, 3, 4, 5, 6], dtype=dtype).astype(object)
        values[0], values[1], values[2], values[3] = "a", "m", "z", np.nan
        frame[column] = values
    fmts["missl"], fmts["missd"] = "%12.0g", "%10.0g"
    labels = {"labelled": {1: "low", 2: "mid", 3: "high"}}
    return frame, fmts, missing, labels


def make_pyreadstat_all_types() -> list[str]:
    names = []
    for release, version in PYRS_VERSIONS.items():
        name = f"pyreadstat_v{release}"
        path = REFERENCE / f"{name}.dta"
        frame, fmts, missing, labels = pyreadstat_frame(release)
        pyreadstat.write_dta(frame, str(path), version=version, file_label="codec fixture",
                             variable_format=fmts, missing_user_values=missing,
                             variable_value_labels=labels,
                             column_labels=[None] * frame.shape[1])
        if release >= 117:
            require_strl(path, name)
        spelled = read_missing_codes(path)
        for column in missing:
            got = [str(v) for v in spelled[column]]
            if got[:4] != [".a", ".m", ".z", "."]:
                raise SystemExit(f"{name}: {column} spells {got}")
        write_sidecar(
            path,
            writer=f"pyreadstat {pyreadstat.__version__} write_dta(version={version}) with "
                   "variable_format, missing_user_values and variable_value_labels",
            synthetic=None,
            source=f"pandas {pd.__version__} read_stata(convert_dates=False, "
                   "convert_categoricals=False)",
            extra={"missing_codes": {c: {"1": ".a", "2": ".m", "3": ".z", "4": "."}
                                     for c in missing}},
        )
        names.append(name)
    return names


def make_codes() -> list[str]:
    """Every missing code in every numeric storage."""
    names = []
    frame = pd.DataFrame({
        "tbyte": np.zeros(27, dtype=np.int8),
        "tint": np.zeros(27, dtype=np.int16),
        "tlong": np.zeros(27, dtype=np.int32),
        "tfloat": np.zeros(27, dtype=np.float32),
        "tdouble": np.zeros(27, dtype=np.float64),
    })
    every = {k: k for k in range(27)}
    for version, byteorder in ((114, "<"), (114, ">"), (118, "<"), (118, ">")):
        name = f"codes_pandas_v{version}_{'le' if byteorder == '<' else 'be'}"
        path = REFERENCE / f"{name}.dta"
        write_pandas(path, version, byteorder, frame)
        patcher = Patcher(path)
        codes = {}
        for column, code in (("tbyte", "b"), ("tint", "h"), ("tlong", "i"),
                             ("tfloat", "I"), ("tdouble", "Q")):
            codes[column] = patch_codes(patcher, column, every, code, CODES[column[1:]])
        patcher.save()
        confirm_codes(path, codes, reader_names_codes=False)
        write_sidecar(
            path,
            writer=f"pandas {pd.__version__} DataFrame.to_stata(version={version}, "
                   f"byteorder='{byteorder}')",
            synthetic="every cell was rewritten after the write to one of the 27 missing "
                      "codes, row k holding the k-th code",
            source=f"pandas {pd.__version__} read_stata(convert_dates=False, "
                   "convert_categoricals=False); every cell confirmed with "
                   "convert_missing=True",
        )
        names.append(name)
    for release, version in PYRS_VERSIONS.items():
        name = f"codes_pyreadstat_v{release}"
        path = REFERENCE / f"{name}.dta"
        letters = [chr(ord("a") + k) for k in range(26)]
        longs = np.array([1] * 27, dtype="int32").astype(object)
        doubles = np.array([1.0] * 27, dtype="float64").astype(object)
        longs[0], doubles[0] = np.nan, np.nan
        for k, letter in enumerate(letters):
            longs[k + 1], doubles[k + 1] = letter, letter
        pyreadstat.write_dta(pd.DataFrame({"tlong": longs, "tdouble": doubles}), str(path),
                             version=version,
                             missing_user_values={"tlong": letters, "tdouble": letters})
        spelled = read_missing_codes(path)
        for column in ("tlong", "tdouble"):
            got = [str(v) for v in spelled[column]]
            if got != CODE_NAMES:
                raise SystemExit(f"{name}: {column} spells {got}")
        write_sidecar(
            path,
            writer=f"pyreadstat {pyreadstat.__version__} write_dta(version={version}) with "
                   "missing_user_values a to z",
            synthetic=None,
            source=f"pandas {pd.__version__} read_stata(convert_dates=False, "
                   "convert_categoricals=False)",
        )
        names.append(name)
    return names


def make_reserved() -> list[str]:
    """Values outside a storage's valid range that are no missing code."""
    name = "reserved_pandas_v118_le"
    path = REFERENCE / f"{name}.dta"
    frame = pd.DataFrame({
        "tbyte": np.array([0, 0], dtype=np.int8),
        "tint": np.array([0, 0], dtype=np.int16),
        "tlong": np.array([0, 0], dtype=np.int32),
        "tfloat": np.array([0.0, 0.0], dtype=np.float32),
        "tdouble": np.array([0.0, 0.0], dtype=np.float64),
    })
    write_pandas(path, 118, "<", frame)
    patcher = Patcher(path)
    patcher.set_int("tbyte", 0, -128, "b")
    patcher.set_int("tint", 0, -32768, "h")
    patcher.set_int("tlong", 0, -2147483648, "i")
    patcher.set_bits("tfloat", 0, 0x7F800000, "I")          # +inf
    patcher.set_bits("tfloat", 1, 0x7FC00000, "I")          # a NaN of no code
    patcher.set_bits("tdouble", 0, 0xFFF0000000000000, "Q")  # -inf
    patcher.set_bits("tdouble", 1, 0x7FF8000000000000, "Q")  # a NaN of no code
    patcher.save()
    write_sidecar(
        path,
        writer=f"pandas {pd.__version__} DataFrame.to_stata(version=118)",
        synthetic="every cell was rewritten after the write: byte -128, int -32768, "
                  "long -2147483648, float +inf and a plain NaN, double -inf and a plain "
                  "NaN — each outside the valid range and no missing code",
        source=f"pandas {pd.__version__} read_stata(convert_dates=False, "
               "convert_categoricals=False)",
    )
    return [name]


def make_edges() -> list[str]:
    names = []

    def try_write(label: str, write, what: str) -> None:
        path = REFERENCE / f"{label}.dta"
        try:
            write(path)
        except Exception as exc:  # noqa: BLE001
            print(f"  {label}: the writer refuses {what} ({type(exc).__name__})")
            return
        write_sidecar(path, writer=label.replace("_", " "), synthetic=None,
                      source=f"pandas {pd.__version__} read_stata(convert_dates=False)")
        names.append(label)

    # No variable, no observation. The first reference writer cannot write
    # a table of no column at all; the second can.
    try_write("empty_pandas_v118", lambda p: write_pandas(p, 118, "<", pd.DataFrame()),
              "an empty table")
    for release, version in PYRS_VERSIONS.items():
        try_write(f"empty_pyreadstat_v{release}",
                  lambda p, v=version: pyreadstat.write_dta(pd.DataFrame(), str(p), version=v),
                  "an empty table")

    # Variables, no observation.
    frame = all_types_frame(UTF8_TEXT, LONG_UTF8, with_strl=False).iloc[0:0]
    try_write("norows_pandas_v118_le", lambda p: write_pandas(p, 118, "<", frame.copy()),
              "a table of no row")
    frame = all_types_frame(LATIN1_TEXT, LONG_ASCII, with_strl=False).iloc[0:0]
    try_write("norows_pandas_v114_le", lambda p: write_pandas(p, 114, "<", frame.copy()),
              "a table of no row")
    frame, fmts, _, _ = pyreadstat_frame(115)
    try_write("norows_pyreadstat_v115",
              lambda p: pyreadstat.write_dta(frame.iloc[0:0], str(p), version=12,
                                             variable_format=fmts),
              "a table of no row")

    # Observations, no variable: no reference writer produces it. The
    # empty table's observation count is rewritten, a field the tag
    # `</K><N>` places without any further assumption about the layout.
    src = REFERENCE / "empty_pyreadstat_v118.dta"
    if src.exists():
        raw = src.read_bytes()
        at = raw.index(b"</K><N>") + len(b"</K><N>")
        if raw[at:at + 8] != bytes(8):
            raise SystemExit("the empty file's observation count is not where the tag puts it")
        dst = REFERENCE / "synthetic_v118_obs_no_var.dta"
        dst.write_bytes(raw[:at] + struct.pack("<Q", 5) + raw[at + 8:])
        header = facts(dst)
        if header["nobs"] != 5 or header["nvar"] != 0:
            raise SystemExit(f"the reference reader sees {header['nobs']} x {header['nvar']}")
        sidecar = {
            "file": dst.name,
            "writer": f"pyreadstat {pyreadstat.__version__} write_dta(version=14) on an "
                      "empty table",
            "release": 118,
            "byteorder": "LSF",
            "synthetic": "the observation count of the empty table was rewritten from 0 to 5",
            "sidecar_source": "hand-written: the reference reader's header parse confirms "
                              "5 observations and no variable, and its cell read raises "
                              "StopIteration on such a file",
            "pyreadstat_agrees": None,
            "reference_opens": False,
            "nobs": 5,
            "columns": [],
        }
        dst.with_suffix(".json").write_text(json.dumps(sidecar, indent=1), encoding="utf-8")
        names.append("synthetic_v118_obs_no_var")
    return names


LONG_NAME = "a" + "1234567890" * 3 + "1"  # 32 characters
assert len(LONG_NAME) == 32


def make_limits() -> list[str]:
    names = []
    frame = pd.DataFrame({
        "str2045": ["x" * 2045, "", "y" * 2045],
        "str2044": ["x" * 2044, "z", ""],
        "str1": ["", "a", ""],
        "strl2046": ["q" * 2046, "", "q" * 2046],
        "nulcut": ["ab\x00cd", "x", ""],
        "x_1": [1, 2, 3],
        LONG_NAME: [1.5, 2.5, 3.5],
    })
    path = REFERENCE / "limits_pandas_v118_le.dta"
    write_pandas(path, 118, "<", frame, convert_strl=["strl2046"])
    sidecar = write_sidecar(
        path, writer=f"pandas {pd.__version__} DataFrame.to_stata(version=118, "
                     "convert_strl=['strl2046'])",
        synthetic=None, source=f"pandas {pd.__version__} read_stata(convert_dates=False)")
    if [c["name"] for c in sidecar["columns"]] != list(frame.columns):
        raise SystemExit(f"the names did not survive the write: "
                         f"{[c['name'] for c in sidecar['columns']]}")
    names.append("limits_pandas_v118_le")

    # Release 114 caps a fixed-width string at 244 bytes.
    frame = pd.DataFrame({"s244": ["x" * 244, "", "y" * 244],
                          LONG_NAME: [1.5, 2.5, 3.5]})
    path = REFERENCE / "limits_pandas_v114_be.dta"
    write_pandas(path, 114, ">", frame)
    write_sidecar(path, writer=f"pandas {pd.__version__} DataFrame.to_stata(version=114, "
                               "byteorder='>')",
                  synthetic=None, source=f"pandas {pd.__version__} read_stata(convert_dates=False)")
    names.append("limits_pandas_v114_be")

    # Names outside ASCII, which release 118 carries.
    frame = pd.DataFrame({"café": [1, 2], "变量": [3.5, 4.5], "_x1": ["a", "b"]})
    path = REFERENCE / "names_pandas_v118_le.dta"
    write_pandas(path, 118, "<", frame)
    write_sidecar(path, writer=f"pandas {pd.__version__} DataFrame.to_stata(version=118)",
                  synthetic=None, source=f"pandas {pd.__version__} read_stata(convert_dates=False)")
    if [c["name"] for c in sidecar_columns(read_raw(path), facts(path))] != list(frame.columns):
        raise SystemExit("the names outside ASCII did not survive the write")
    names.append("names_pandas_v118_le")

    # Text that is not UTF-8 in a release-118 file: the codec's Latin-1
    # fallback, confirmed by the reference reader's own fallback.
    frame = pd.DataFrame({"strf": ["placeholder", "", "plain"]})
    path = REFERENCE / "synthetic_v118_latin1_in_utf8.dta"
    write_pandas(path, 118, "<", frame)
    patcher = Patcher(path)
    at = patcher.offset("strf", 0)
    patcher.raw[at:at + patcher.width("strf")] = \
        "Zoë".encode("latin-1").ljust(patcher.width("strf"), b"\x00")
    patcher.save()
    sidecar = write_sidecar(
        path, writer=f"pandas {pd.__version__} DataFrame.to_stata(version=118)",
        synthetic="the first cell of strf was rewritten after the write to Latin-1 bytes",
        source=f"pandas {pd.__version__} read_stata(convert_dates=False), through its own "
               "Latin-1 fallback for text that is not UTF-8")
    if sidecar["columns"][0]["cells"][0] != "String Zoë":
        raise SystemExit(f"the reference fallback gave {sidecar['columns'][0]['cells'][0]!r}")
    names.append("synthetic_v118_latin1_in_utf8")

    # Latin-1 bytes in a release-117 strL. The reference writer stores a
    # 117 strL's text as UTF-8, so one record's text is rewritten after
    # the write, and the reference reader — which decodes a 117 strL as
    # Latin-1 — is asked for the cell.
    src = REFERENCE / "pandas_v117_le.dta"
    raw = src.read_bytes()
    strls_at, strls_end = raw.index(b"<strls>"), raw.index(b"</strls>")
    at = raw.index(b"plain\x00", strls_at)
    if not strls_at < at < strls_end:
        raise SystemExit("the strL record's text is not where the strls section is")
    path = REFERENCE / "synthetic_v117_latin1_in_strl.dta"
    path.write_bytes(raw[:at] + "plaïn".encode("latin-1") + raw[at + 5:])
    sidecar = write_sidecar(
        path, writer=f"pandas {pd.__version__} DataFrame.to_stata(version=117, "
                     "convert_strl=['strl'])",
        synthetic="the text of one strL record was rewritten after the write to Latin-1 bytes",
        source=f"pandas {pd.__version__} read_stata(convert_dates=False, "
               "convert_categoricals=False)")
    column = next(c for c in sidecar["columns"] if c["name"] == "strl")
    if column["cells"][4] != "String plaïn":
        raise SystemExit(f"the reference reader got {column['cells'][4]!r} for the strL cell")
    names.append("synthetic_v117_latin1_in_strl")
    return names


def make_synthetic_releases() -> list[str]:
    """Releases and byte orders no reference writer produces, derived from a
    reference file the reference reader then confirms."""
    names = []
    for suffix in ("le", "be"):
        # 115: the reference reader treats 114 and 115 alike, so only the
        # release byte changes.
        src = REFERENCE / f"pandas_v114_{suffix}.dta"
        dst = REFERENCE / f"synthetic_v115_from_pandas_v114_{suffix}.dta"
        dst.write_bytes(bytes([115]) + src.read_bytes()[1:])
        write_sidecar(
            dst, writer=f"pandas_v114_{suffix}.dta with its release byte rewritten to 115",
            synthetic="the release byte of the 114 file was rewritten to 115",
            source=f"pandas {pd.__version__} read_stata(convert_dates=False); pyreadstat "
                   "opens it as release 115 too")
        names.append(dst.stem)

        # 113: the same, with every display format narrowed to the twelve
        # bytes release 113 gives it. The 114 layout's section sizes are
        # the reference reader's own, checked against where it puts the
        # data before anything is rebuilt.
        header = facts(src)
        raw = src.read_bytes()
        nvar = header["nvar"]
        types_at = 109
        names_at = types_at + nvar
        sorts_at = names_at + 33 * nvar
        fmts_at = sorts_at + 2 * (nvar + 1)
        labels_at = fmts_at + 49 * nvar
        varlabels_at = labels_at + 33 * nvar
        data_at = varlabels_at + 81 * nvar + 5
        if data_at != header["data_location"]:
            raise SystemExit("the 114 layout is not where the reference reader puts the data")
        narrowed = b"".join(raw[fmts_at + 49 * i:fmts_at + 49 * i + 12] for i in range(nvar))
        dst = REFERENCE / f"synthetic_v113_from_pandas_v114_{suffix}.dta"
        dst.write_bytes(bytes([113]) + raw[1:fmts_at] + narrowed + raw[labels_at:])
        header = facts(dst)
        if header["release"] != 113 or header["data_location"] != data_at - 37 * nvar:
            raise SystemExit("the reference reader does not see the rebuilt file as 113")
        write_sidecar(
            dst, writer=f"pandas_v114_{suffix}.dta relaid: release byte 113, twelve-byte "
                        "format slots",
            synthetic="the release byte of the 114 file was rewritten to 113 and every "
                      "display format slot narrowed from 49 bytes to the 12 release 113 "
                      "gives it",
            source=f"pandas {pd.__version__} read_stata(convert_dates=False)")
        names.append(dst.stem)

    # Big-endian 113 and 115: a reference file's every multi-byte field
    # byte-swapped and its byte-order flag set, the reference reader asked
    # for the same cells back. The file holds long, double and str# columns
    # only, so the count fields, the sort list and the data are every
    # multi-byte field it has.
    for release, version in ((113, 8), (115, 12)):
        plain = pd.DataFrame({
            "l": np.array([1, -2, 2147483620, -2147483647], dtype=np.int32),
            "d": np.array([1.5, -2.25, 1e300, 5e-324], dtype=np.float64),
            "s": [ASCII_TEXT, "", "x", "y"],
        })
        src = REFERENCE / f"pyreadstat_plain_v{release}.dta"
        pyreadstat.write_dta(plain, str(src), version=version)
        write_sidecar(src, writer=f"pyreadstat {pyreadstat.__version__} "
                                  f"write_dta(version={version})",
                      synthetic=None, source=f"pandas {pd.__version__} read_stata(convert_dates=False)")
        names.append(src.stem)
        header = facts(src)
        raw = bytearray(src.read_bytes())
        nvar, nobs = header["nvar"], header["nobs"]
        struct.pack_into(">H", raw, 4, nvar)
        struct.pack_into(">I", raw, 6, nobs)
        at = header["data_location"]
        for _ in range(nobs):
            for typ in header["typlist"]:
                if typ in ("l", "d"):
                    width = 4 if typ == "l" else 8
                    raw[at:at + width] = raw[at:at + width][::-1]
                    at += width
                else:
                    at += typ
        raw[1] = 1
        dst = REFERENCE / f"synthetic_v{release}_be_from_pyreadstat_v{release}.dta"
        dst.write_bytes(bytes(raw))
        write_sidecar(
            dst, writer=f"pyreadstat_plain_v{release}.dta, byte-swapped",
            synthetic="every multi-byte field of the little-endian file (the variable "
                      "count, the observation count and the data cells) was byte-swapped "
                      "and its byte-order flag set to 1",
            source=f"pandas {pd.__version__} read_stata(convert_dates=False)")
        names.append(dst.stem)

    # 116: no reference reader opens it. The bytes are a 115 file's with
    # the release byte changed, and the sidecar is that file's.
    src = REFERENCE / "pyreadstat_v115.dta"
    dst = REFERENCE / "synthetic_v116_from_pyreadstat_v115.dta"
    dst.write_bytes(bytes([116]) + src.read_bytes()[1:])
    sidecar = json.loads(src.with_suffix(".json").read_text(encoding="utf-8"))
    sidecar.update({
        "file": dst.name,
        "writer": "pyreadstat_v115.dta with its release byte rewritten to 116",
        "synthetic": "the release byte of the 115 file was rewritten to 116",
        "sidecar_source": "copied from pyreadstat_v115.json: the bytes differ only in the "
                          "release byte, and neither reference reader opens release 116",
        "pyreadstat_agrees": None,
            "reference_opens": False,
        "release": 116,
    })
    dst.with_suffix(".json").write_text(json.dumps(sidecar, ensure_ascii=False, indent=1),
                                        encoding="utf-8")
    names.append(dst.stem)
    return names


def cross_check_dates(names: list[str]) -> None:
    """Where the reference reader converts a date itself, its conversion
    must agree with the day and microsecond counts the sidecar carries."""
    checked = 0
    epoch_us = np.datetime64("1970-01-01T00:00:00", "us").astype("int64")
    for name in names:
        path = REFERENCE / f"{name}.dta"
        sidecar = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
        if sidecar.get("reference_opens") is False:
            continue  # no reference reader opens it; the sidecar says so
        raw, converted = read_raw(path), read_converted(path)
        if converted.shape != raw.shape:
            continue
        for column in sidecar["columns"]:
            if column["dtype"] not in ("Date", "Timestamp"):
                continue
            got = converted[column["name"]]
            if not np.issubdtype(got.dtype, np.datetime64):
                continue
            micros = got.astype("datetime64[us]").astype("int64") - epoch_us
            for cell, value in zip(column["cells"], micros):
                if cell == "Null":
                    continue
                want = int(cell.split(" ", 1)[1])
                if column["dtype"] == "Date":
                    want *= 86_400_000_000
                if int(value) != want:
                    raise SystemExit(f"{name}: {column['name']}: the reference's own date "
                                     f"conversion gives {value} us, the sidecar {want}")
                checked += 1
    print(f"  the reference reader's own date conversion agrees on {checked} cells")


def cmd_make() -> int:
    REFERENCE.mkdir(parents=True, exist_ok=True)
    for old in REFERENCE.iterdir():
        old.unlink()
    print(f"pandas {pd.__version__}, pyreadstat {pyreadstat.__version__}, numpy {np.__version__}")
    names: list[str] = []
    for step in (make_pandas_all_types, make_pyreadstat_all_types, make_codes,
                 make_reserved, make_edges, make_limits, make_synthetic_releases):
        produced = step()
        print(f"  {step.__name__}: {len(produced)} file(s)")
        names.extend(produced)
    names = sorted(set(names))
    cross_check_dates(names)
    index = []
    total = 0
    for name in names:
        path = REFERENCE / f"{name}.dta"
        sidecar = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
        cells = sum(len(c["cells"]) for c in sidecar["columns"])
        total += cells
        index.append({
            "file": f"{name}.dta",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size": path.stat().st_size,
            "release": sidecar["release"],
            "byteorder": sidecar["byteorder"],
            "synthetic": sidecar["synthetic"],
        })
        flag = "" if sidecar["pyreadstat_agrees"] is not False else "  (pyreadstat disagrees)"
        print(f"  {name}.dta  release {sidecar['release']} {sidecar['byteorder']}  "
              f"{sidecar['nobs']} x {len(sidecar['columns'])}{flag}")
    (REFERENCE / "index.json").write_text(json.dumps(index, indent=1), encoding="utf-8")
    print(f"wrote {len(names)} files and {total} cells under {REFERENCE}")
    return 0


# --------------------------------------------------------------- verify ----

# The storage each library dtype writes under, where the format leaves no
# choice; the format each date dtype writes beside its name.
EXPECTED = {
    "Bool": ("byte", None), "Float": ("double", None), "Date": ("long", "%td"),
    "Timestamp": ("double", "%tc"), "Null": ("double", None),
}

# The code for `.` in each numeric storage the codec writes, as the
# little-endian bytes the file spells it in.
MISSING_CODES = {"d": ("<Q", 0x7FE0000000000000), "l": ("<i", 2147483621), "b": ("<b", 101)}


def is_nan_cell(cell: str) -> bool:
    """Whether a spelled `Float` cell is a NaN."""
    if not cell.startswith("Float "):
        return False
    bits = int(cell[len("Float "):], 16)
    return (bits & 0x7FF0000000000000) == 0x7FF0000000000000 and (bits & 0xFFFFFFFFFFFFF) != 0


def library_cell_equal(dtype: str, cell: str, value) -> bool:
    """Whether one cell the reference reader `read_raw` got from a
    codec-written file is the table's cell `cell`."""
    if dtype == "String":
        return enc_str("" if pd.isna(value) else str(value)) == ("String " if cell == "Null" else cell)
    if cell == "Null":
        return bool(pd.isna(value))
    # The format has no NaN: the codec writes a NaN `Float` cell as the
    # code for `.`, which the reference reader answers as a missing cell.
    if is_nan_cell(cell):
        return dtype == "Float" and bool(pd.isna(value))
    kind, _, payload = cell.partition(" ")
    if pd.isna(value):
        return False
    if dtype == "Bool":
        return f"Bool {int(value)}" == cell
    if dtype == "Int":
        return is_number_equal(value, int(payload))
    if dtype == "Float":
        return float_hex(value) == payload
    if dtype == "Date":
        return is_number_equal(value, int(payload) + STATA_EPOCH_DAYS)
    if dtype == "Timestamp":
        return float(value) == int(payload) / 1000 + STATA_EPOCH_MILLIS
    return False  # a Null column's cells are all Null, answered above


def compare_table(path: Path, table: dict) -> tuple[int, list[str]]:
    """What both reference readers get from a codec-written file, against
    the table the codec was handed — and, for every cell the codec writes
    as a missing code, the file's own bytes, read with the reference
    reader's record layout, since both readers answer NaN for anything
    outside a storage's valid range."""
    header = facts(path)
    raw = read_raw(path)
    mismatches: list[str] = []
    compared = 0
    if header["release"] != 118 or header["byteorder"] != "<":
        mismatches.append(f"release {header['release']} byte order {header['byteorder']}")
    names = [c["name"] for c in table["columns"]]
    if names != list(raw.columns):
        return 0, [f"columns {list(raw.columns)} != {names}"]
    if raw.shape[0] != table["height"]:
        mismatches.append(f"height {raw.shape[0]} != {table['height']}")
    other = pyreadstat_cells(path)
    records = None
    if header["nobs"] > 0:
        data = path.read_bytes()
        records = np.frombuffer(
            data[header["data_location"]:
                 header["data_location"] + header["nobs"] * header["dtype"].itemsize],
            dtype=header["dtype"])
    for index, (column, typ, fmt) in enumerate(zip(table["columns"], header["typlist"], header["fmtlist"])):
        name, dtype = column["name"], column["dtype"]
        storage = storage_name(typ)
        want_storage, want_format = EXPECTED.get(dtype, (None, None))
        if want_storage is not None and storage != want_storage:
            mismatches.append(f"{name}: storage {storage}, not {want_storage}")
        if want_format is not None and fmt != want_format:
            mismatches.append(f"{name}: format {fmt}, not {want_format}")
        for row, (cell, value) in enumerate(zip(column["cells"], raw[name])):
            compared += 1
            if not library_cell_equal(dtype, cell, value):
                mismatches.append(f"{name} row {row + 1}: pandas got {value!r}, "
                                  f"the table says {cell}")
            if other is not None and not reference_cell_equal(storage, cell, other[name][row]) \
                    and not (dtype == "String" and cell == "Null" and other[name][row] == ""):
                mismatches.append(f"{name} row {row + 1}: pyreadstat got {other[name][row]!r}, "
                                  f"the table says {cell}")
            # A missing numeric cell, and a NaN `Float` cell, must be the
            # storage's code for `.` in the file's own bytes.
            as_missing = cell == "Null" or (typ == "d" and is_nan_cell(cell))
            if as_missing and typ in MISSING_CODES:
                stored = records[f"s{index}"][row].tobytes()
                if stored != struct.pack(*MISSING_CODES[typ]):
                    mismatches.append(f"{name} row {row + 1}: the file stores {stored.hex()}, "
                                      "not the code for `.`")
    return compared, mismatches


def cmd_verify() -> int:
    if not CODEC.exists():
        print(f"nothing to verify: {CODEC} does not exist; run the codec package's tests first")
        return 1
    tables = sorted(p for p in CODEC.glob("*.json"))
    if not tables:
        print(f"nothing to verify: no tables under {CODEC}")
        return 1
    failed = 0
    total = 0
    unopened = 0
    for table_path in tables:
        name = table_path.stem
        dta = CODEC / f"{name}.dta"
        table = json.loads(table_path.read_text(encoding="utf-8"))
        if not dta.exists():
            print(f"  {name}: no file written")
            failed += 1
            continue
        if table.get("reference_opens") is False:
            # A file the reference reader's cell read raises on. Its
            # header parse still runs, and is asked what it sees.
            header = facts(dta)
            shape = (header["nobs"], header["nvar"])
            if shape != (table["height"], len(table["columns"])):
                failed += 1
                print(f"  {name}: the reference reader's header parse sees {shape[0]} x "
                      f"{shape[1]}, the table is {table['height']} x {len(table['columns'])}")
            else:
                unopened += 1
                print(f"  {name}: {shape[0]} x {shape[1]} as the reference reader's header "
                      "parse sees it; its cell read raises on a file of observations and "
                      "no variable, so no cell was compared")
            continue
        try:
            compared, mismatches = compare_table(dta, table)
        except Exception as exc:  # noqa: BLE001
            print(f"  {name}: the reference reader cannot open it: {type(exc).__name__}: "
                  f"{str(exc)[:90]}")
            failed += 1
            continue
        total += compared
        if mismatches:
            failed += 1
            print(f"  {name}: {compared} cells compared, {len(mismatches)} MISMATCHES")
            for line in mismatches[:12]:
                print(f"      {line}")
        else:
            print(f"  {name}: {compared} cells compared, 0 mismatches "
                  f"(pandas and pyreadstat both read the codec's file)")
    print(f"codec-written tables: {len(tables)}; cells compared: {total}; "
          f"tables the reference reader cannot read cell by cell: {unopened}; "
          f"tables with a mismatch: {failed}")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else ""
    if command == "make":
        return cmd_make()
    if command == "verify":
        return cmd_verify()
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
