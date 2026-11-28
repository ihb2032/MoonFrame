"""Generate the reference corpus of ORC files under ``fixtures/reference``
and the JSON sidecar beside each, then verify both.

``make`` writes the corpus with the reference writer (the ORC writer of
pyarrow, the reference C++ implementation) and derives files from written
ones by patching a field; it builds files stream by stream with the
encoder for the shapes no writer spells — the short repeat, patched base
and delta runs at their widths, the nanosecond spellings, the wire
variants — and breaks files in one place each, to pin the codec's
refusals; and it adds the small example files of the format's own
repository (Apache-2.0, written by the reference Java implementation,
and by earlier C++ ones). A sidecar holds the cells the reference reader
itself got from each file — as many views as the file has: unprojected,
and under the projections by which a file carrying a column the codec
refuses by name still reads — and names the refusal where the codec
refuses a view, with the exact text the codec answers. Every cell is
spelled ``<kind> <payload>``: ``Null``;
``Bool true``; ``Int <decimal>``; ``Float <16 hex digits of the IEEE
bits>``; ``String <JSON string>``; ``Date <days since 1970-01-01>``;
``Timestamp <microseconds since 1970-01-01>``; ``Decimal <plain decimal
text>``; ``List [cell, ...]``; ``Struct {"field": cell, ...}``. A column's
dtype is spelled ``Int`` / ``Float`` / ``Bool`` / ``String`` / ``Date`` /
``Timestamp`` / ``Decimal`` / ``List(<dtype>)`` / ``Struct({"name":
<dtype>, ...})``.

Where the reference reader and the codec part ways on a file's values,
the view's cells are the generator's own, spelled from the values it
wrote, and the view says so — and records what the reference reader gave,
for ``verify`` to find unchanged.

``verify`` re-reads every view of every file with the reference reader and
compares every cell with the sidecar; it exits non-zero on a mismatch.

The reference writer loads the IANA time zone database from files before
it writes a timestamp, and this machine has none; the tzdata package
carries one, so the generator points TZDIR at it. It reads the stripe
footers of a compressed file to spell its dtypes, and the snappy, lz4 and
zstd codecs ride the cramjam wheels.

    uv run --no-project --with pyarrow --with tzdata --with cramjam python -I -X utf8 .github/fixtures/orc/make_fixtures.py make
    uv run --no-project --with pyarrow --with tzdata --with cramjam python -I -X utf8 .github/fixtures/orc/make_fixtures.py verify
    uv run --no-project python -I -X utf8 .github/fixtures/orc/make_fixtures.py digest
"""
import datetime
import hashlib
import io
import json
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request
import zlib
from decimal import Decimal

try:
    import pyarrow as pa
    import pyarrow.orc as orc
except ImportError:
    # a `digest` reads bytes only; `make` and `verify` need the reference
    # reader, and say so here rather than at first use
    if any(step in sys.argv[1:] for step in ("make", "verify")):
        raise

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import orclayout as O  # noqa: E402
import orcenc as E  # noqa: E402

BUILD = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "_build")
FIX = os.path.join(HERE, "reference")
LOG = os.path.join(BUILD, "orc_fixture_logs")
EXAMPLES = os.path.join(BUILD, "orc_examples")
EXAMPLES_BIG = os.path.join(BUILD, "orc_examples_big")
EXAMPLES_TAG = "v2.1.0"
EXAMPLES_URL = "https://raw.githubusercontent.com/apache/orc/%s/examples/" % EXAMPLES_TAG

UNIT_MICROS = {"s": 1000000, "ms": 1000, "us": 1}
SIGNIFICANT = 34
# a draft `make` writes a corpus whose refused files have no exact text
# yet: the test beside the package prints them, and they go in the table
DRAFT = "--draft" in sys.argv


def log(text):
    print(text, flush=True)


def ensure_tzdir():
    """Point TZDIR at an IANA time zone database if the machine has none:
    the reference writer loads its time zone from files and refuses a
    timestamp without them. The tzdata package carries one."""
    if os.environ.get("TZDIR"):
        return os.environ["TZDIR"]
    try:
        import tzdata

        zone = os.path.join(os.path.dirname(tzdata.__file__), "zoneinfo")
        if os.path.exists(os.path.join(zone, "GMT")):
            os.environ["TZDIR"] = zone
            return zone
    except ImportError:
        pass
    return None


# ── the reference reader ────────────────────────────────────────────

def reference_table(data, projection):
    """What the reference reader returns for a view, or the error it
    refused with."""
    try:
        return orc.read_table(io.BytesIO(data), columns=projection), None
    except Exception as e:  # noqa
        return None, "%s: %s" % (type(e).__name__, str(e)[:200])


def reference_summary(data):
    """The reference reader's verdict on a file, read in a process of its
    own — a malformed file may crash the reader's core, and the crash is
    the verdict then: whether it opens the file, the error, and else its
    rows and columns."""
    fd, path = tempfile.mkstemp(suffix=".orc")
    try:
        os.write(fd, data)
        os.close(fd)
        run = subprocess.run(
            [sys.executable, "-I", "-X", "utf8", os.path.join(HERE, "reference_summary.py"), path],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300)
    finally:
        os.remove(path)
    if run.returncode != 0:
        tail = (run.stderr or "").strip()[-200:]
        return {"opens": False, "error": "the reader crashed: exit code %d %s" % (run.returncode, tail)}
    return json.loads(run.stdout.strip().splitlines()[-1])


def bits(value):
    return struct.unpack("<Q", struct.pack("<d", value))[0]


def cells_of(arr):
    """The cells of one Arrow array, as the sidecar spells them. A
    timestamp is read as its integer count, never as a datetime: a
    datetime carries microseconds only, and the count is what the file
    holds. A nanosecond remainder has no spelling: it raises."""
    t = arr.type
    if pa.types.is_boolean(t):
        return [None if v is None else "Bool true" if v else "Bool false" for v in arr.to_pylist()]
    if pa.types.is_integer(t):
        return [None if v is None else "Int %d" % v for v in arr.to_pylist()]
    if pa.types.is_floating(t):
        return [None if v is None else "Float %016x" % bits(v) for v in arr.to_pylist()]
    if pa.types.is_string(t) or pa.types.is_large_string(t):
        return [None if v is None else "String " + json.dumps(v, ensure_ascii=False) for v in arr.to_pylist()]
    if pa.types.is_date32(t) or pa.types.is_date64(t):
        # the integer count, never a date: the first and the last int32
        # day lie past what a datetime holds
        factor = 86400000 if pa.types.is_date64(t) else 1
        raw = arr.view(pa.int64()) if pa.types.is_date64(t) else arr.view(pa.int32())
        return [None if v is None else "Date %d" % (v // factor) for v in raw.to_pylist()]
    if pa.types.is_timestamp(t):
        factor = UNIT_MICROS.get(t.unit)
        out = []
        for v in arr.cast(pa.int64()).to_pylist():
            if v is None:
                out.append(None)
            elif t.unit == "ns":
                if v % 1000 != 0:
                    raise ValueError("a timestamp with a nanosecond remainder: %d ns" % v)
                out.append("Timestamp %d" % (v // 1000))
            else:
                out.append("Timestamp %d" % (v * factor))
        return out
    if pa.types.is_decimal(t):
        return [None if v is None else "Decimal " + format(v, "f") for v in arr.to_pylist()]
    if pa.types.is_list(t) or pa.types.is_large_list(t) or pa.types.is_fixed_size_list(t):
        child = cells_of(arr.flatten())
        if pa.types.is_fixed_size_list(t):
            size = t.list_size
            spans = [(i * size, (i + 1) * size) for i in range(len(arr))]
        else:
            offsets = arr.offsets.to_pylist()
            spans = list(zip(offsets, offsets[1:]))
        valid = arr.is_valid().to_pylist()
        return [None if not valid[i] else "List [" + ", ".join("Null" if c is None else c for c in child[a:b]) + "]"
                for i, (a, b) in enumerate(spans)]
    if pa.types.is_struct(t):
        fields = [cells_of(arr.field(i)) for i in range(t.num_fields)]
        valid = arr.is_valid().to_pylist()
        out = []
        for i in range(len(arr)):
            if not valid[i]:
                out.append(None)
            else:
                out.append("Struct {" + ", ".join(
                    "%s: %s" % (json.dumps(t.field(j).name, ensure_ascii=False),
                                "Null" if fields[j][i] is None else fields[j][i])
                    for j in range(t.num_fields)) + "}")
        return out
    raise ValueError("an Arrow type the sidecar does not spell: %s" % t)


def significant_digits(text):
    """How many significant digits a plain decimal text carries, its
    trailing zeros not counted: what the library's decimal holds at most
    34 of."""
    digits = "".join(str(d) for d in Decimal(text).as_tuple().digits).rstrip("0")
    return len(digits) or 1


def wide_decimals(cells):
    """How many of a decimal column's cells need more significant digits
    than the library's decimal holds."""
    n = 0
    for cell in cells:
        if cell is not None and significant_digits(cell[len("Decimal "):]) > SIGNIFICANT:
            n += 1
    return n


# ── the codec's mapping, as far as the generator must know it ───────

def dtype_of(f, i):
    """The dtype the codec reads a type as, or None when it refuses it."""
    t = f.types[i]
    k = t.kind
    if k == 0:
        return "Bool"
    if k in (1, 2, 3, 4):
        return "Int"
    if k in (5, 6):
        return "Float"
    if k in (7, 16, 17):
        return "String"
    if k in (9, 18):
        return "Timestamp"
    if k == 15:
        return "Date"
    if k == 14:
        return "Decimal"
    if k == 10:
        if len(t.subtypes) != 1:
            return None
        inner = dtype_of(f, t.subtypes[0])
        return None if inner is None else "List(%s)" % inner
    if k == 12:
        if len(t.subtypes) != len(t.names) or len(set(t.names)) != len(t.names):
            return None
        parts = [dtype_of(f, s) for s in t.subtypes]
        if any(p is None for p in parts):
            return None
        return "Struct({%s})" % ", ".join(
            "%s: %s" % (json.dumps(n, ensure_ascii=False), p) for n, p in zip(t.names, parts))
    return None


def carried(f, projection):
    """Whether the codec carries a view by its types: the root must be a
    STRUCT, and every column the projection keeps must map to a dtype."""
    if not f.types or f.types[0].kind != 12:
        return False
    for i, name in enumerate(f.types[0].names):
        if (projection is None or name in projection) and dtype_of(f, f.types[0].subtypes[i]) is None:
            return False
    return True


# ── the reference writer ────────────────────────────────────────────

def write(table, **kw):
    sink = io.BytesIO()
    orc.write_table(table, sink, **kw)
    return sink.getvalue()


def ts(counts, unit="us", tz=None):
    """A timestamp array from integer counts in the unit given, in the time
    zone given (none: a wall-clock timestamp). A count may lie past what a
    datetime holds: the ends of a 64-bit microsecond count are among the
    edges the codec keeps."""
    arr = pa.array([0 if c is None else c for c in counts], pa.int64(),
                   mask=pa.array([c is None for c in counts], pa.bool_()))
    return arr.cast(pa.timestamp(unit, tz=tz) if tz else pa.timestamp(unit))


MAX_MICROS = 2**63 - 1
MIN_MICROS = -2**63


def table_timestamp_edges():
    """Instants before the epoch with a fraction, the first and the last
    instant a 64-bit nanosecond count holds (the years 1677 and 2262), and
    the same values in nanoseconds and milliseconds: what a writer spells
    as seconds toward zero and a negative nanosecond remainder. The
    reference reader's nanosecond cell bounds what it can read."""
    edges = [-1500000, -1, -999999, None, 1500001, -1000001, 0, -1000000, -9223372036854,
             9223372036854, 1, -2]
    small = edges[:8] + [1, -1, 1000001, -1000000]
    return pa.table({
        "us": ts(edges),
        "ns": ts([None if m is None else m * 1000 for m in small], "ns"),
        "ms": ts([None if m is None else m // 1000 for m in small], "ms"),
        "sec": ts([-1, None, 0, 1, -9223372036, 9223372036, 2, -3, None, -1, 4, -5], "s"),
    })


BOUNDS_US = (MAX_MICROS, MIN_MICROS, MAX_MICROS - 1, MIN_MICROS + 1, -62135596800000000,
             253402300799999999, None, 0)
BOUNDS_SEC = (9223372036854, -9223372036854, None, 0, -62135596800, 253402300799, 1, -1)


def table_timestamp_bounds():
    """Past what the reference reader holds: the instants at the ends of a
    64-bit microsecond count, in microseconds and in whole seconds, and the
    first and the last datetime — the largest and the smallest a library
    timestamp holds."""
    return pa.table({"us": ts(list(BOUNDS_US)), "sec": ts(list(BOUNDS_SEC), "s")})


def bounds_cells():
    """The cells of `table_timestamp_bounds` as the counts written spell
    them: seconds and microseconds alike as microseconds since the epoch.
    The instants are the table's own tuples, so the two cannot drift. A
    writer that rounds a whole second to its nearest second with a
    remainder of the other way still spells the instant."""
    return {
        "us": [None if m is None else "Timestamp %d" % m for m in BOUNDS_US],
        "sec": [None if s is None else "Timestamp %d" % (s * 1000000) for s in BOUNDS_SEC],
    }


def table_timestamp_overflow():
    """Whole seconds past what a 64-bit microsecond count holds."""
    return pa.table({"n": pa.array([1, None, 3, 4, 5, 6], pa.int32()),
                     "over": ts([9223372036855, 0, -9223372036855, None, 1, -1], "s")})


def table_small():
    """Five rows: an int32 and a string, each with a null."""
    return pa.table({"a": pa.array([1, 2, 3, None, 5], pa.int32()),
                     "s": pa.array(["x", "yy", None, "zzz", "w"], pa.string())})


def table_scalars():
    """One column a carried scalar type, nulls among the cells."""
    return pa.table({
        "b": pa.array([True, False, None, True, True, False, False, None, True, False, True, None], pa.bool_()),
        "tiny": pa.array([5, 5, 5, 5, 7, 9, 11, 13, None, 100, -100, -128], pa.int8()),
        "small": pa.array([1, 2, 3, 4, None, 6, 7, 8, 300, -300, 32767, -32768], pa.int16()),
        "int": pa.array([1, 2, 3, 4, None, 6, 7, 8, 70000, -70000, 2147483647, -2147483648], pa.int32()),
        "big": pa.array([0, 1, 2, 3, 4, 5, 6, 7, 8, None, -5, 9223372036854775807], pa.int64()),
        "flt": pa.array([1.5, -2.25, None, 3.5, 0.0, -0.0, float("inf"), float("-inf"), float("nan"),
                         1.401298464324817e-45, 1.175494350822287e-38, 3.4028234663852886e38], pa.float32()),
        "dbl": pa.array([1.5, -2.25, None, 3.5, 0.0, -0.0, float("inf"), float("-inf"), float("nan"),
                         5e-324, 2.2250738585072014e-308, 1.7976931348623157e308], pa.float64()),
        "str": pa.array(["Nevada", None, "", "California", "ünïcödé", "日本語 テキスト", "x" * 300,
                         "a b\tc\n", "quote\"back\\slash", "😀 emoji", " ", "z" * 5000], pa.string()),
        "ts": ts([1, None, 1583054696789000, -1000, 0, -1, 9223372036854, -9223372036854,
                  946684800000000, -62135596800000, -1, 4102444800000000]),
        "dt": pa.array([None, 0, -1, 19000, 20000, 36525, -25567, 73050, 1, -2, 100000, 2932896], pa.date32()),
        "dec": pa.array([None, Decimal("1.25"), Decimal("-7.50"), Decimal("0"), Decimal("99999999.99"),
                         Decimal("-99999999.99"), Decimal("0.01"), Decimal("-0.01"), Decimal("12.34"),
                         Decimal("5"), Decimal("-5"), Decimal("0.00")], pa.decimal128(10, 2)),
        "wide": pa.array([None, Decimal("123456789012345678901234567890.12"), Decimal("-0.01"),
                          Decimal("1E+30"), Decimal("-1E+30"), Decimal("999999999999999999999999999999.99"),
                          Decimal("0"), Decimal("12345678.90"), Decimal("-99999999.99"),
                          Decimal("-12345678901234567890123456789.01"),
                          Decimal("10000000000000000000000000000000.07"), Decimal("-1")], pa.decimal128(38, 2)),
    })


def table_dictionary():
    return pa.table({
        "few": pa.array(["Nevada", "California", None, "Nevada", "California", "Florida", "", None, "Florida", "nevada"], pa.string()),
        "all": pa.array(["row %d" % i for i in range(10)], pa.string()),
        "one": pa.array(["same", None, "same", "same", None, None, "same", "same", "same", "same"], pa.string()),
    })


def table_nested():
    return pa.table({
        "li": pa.array([[1, 2, 3], None, [], [4], [5, 6], [None], [7, None], []], pa.list_(pa.int64())),
        "ls": pa.array([["a", None], None, [], [""], ["ünï"], ["x", "y", "z"], None, ["日本"]], pa.list_(pa.string())),
        "ll": pa.array([[[1], []], None, [[2, 3]], [], [[], [4]], [[None], [5, 6]], [[7]], None], pa.list_(pa.list_(pa.int32()))),
        "lst": pa.array([[{"x": 1, "s": "a"}, {"x": None, "s": None}], None, [], [{"x": 2, "s": ""}],
                         [{"x": None, "s": "ünï"}], [{"x": 3, "s": "b"}, {"x": 4, "s": None}], [], [{"x": 5, "s": "c"}]],
                        pa.list_(pa.struct([("x", pa.int32()), ("s", pa.string())]))),
        "st": pa.array([{"a": 1, "b": "x", "c": {"d": 1.5, "e": True}}, None,
                        {"a": None, "b": None, "c": None}, {"a": 2, "b": "", "c": {"d": None, "e": False}},
                        {"a": 3, "b": "ünï", "c": {"d": -0.0, "e": None}},
                        {"a": None, "b": "z", "c": {"d": float("nan"), "e": True}},
                        {"a": -2147483648, "b": None, "c": {"d": float("inf"), "e": None}}, {}],
                       pa.struct([("a", pa.int32()), ("b", pa.string()),
                                  ("c", pa.struct([("d", pa.float64()), ("e", pa.bool_())]))])),
        "deep": pa.array([{"l": [[{"n": 1}]], "s": {"t": [[1, None], []]}}, None,
                          {"l": [], "s": {"t": None}}, {"l": [None, []], "s": {"t": [[]]}}, {},
                          {"l": [[{"n": None}], [{"n": 2}, {"n": 3}]], "s": {"t": [[], [4], [5, None]]}}, None,
                          {"l": None, "s": {}}],
                         pa.struct([("l", pa.list_(pa.list_(pa.struct([("n", pa.int32())])))),
                                    ("s", pa.struct([("t", pa.list_(pa.list_(pa.int32())))]))])),
    })


def table_nulls():
    n = [None] * 6
    return pa.table({
        "nb": pa.array(n, pa.bool_()), "ni": pa.array(n, pa.int64()), "nf": pa.array(n, pa.float64()),
        "ns": pa.array(n, pa.string()), "nt": ts(n), "nd": pa.array([None] * 6, pa.date32()),
        "nc": pa.array([None] * 6, pa.decimal128(8, 3)), "nl": pa.array([None] * 6, pa.list_(pa.int32())),
        "nst": pa.array([None] * 6, pa.struct([("a", pa.int32())])),
        "pb": pa.array([True] * 6, pa.bool_()), "pi": pa.array(list(range(6)), pa.int64()),
        "pf": pa.array([1.5] * 6, pa.float64()), "ps": pa.array(["s"] * 6, pa.string()), "pt": ts([1000] * 6),
        "pd": pa.array([7] * 6, pa.date32()), "pc": pa.array([Decimal("1.500")] * 6, pa.decimal128(8, 3)),
        "pl": pa.array([[1], [], [2, 3]] * 2, pa.list_(pa.int32())),
        "pst": pa.array([{"a": 1}, {"a": None}] * 3, pa.struct([("a", pa.int32())])),
    })


def table_extremes():
    top32 = 3.4028234663852886e38
    top64 = 1.7976931348623157e308
    return pa.table({
        "i8": pa.array([-128, 127, 0, -1, None, 1], pa.int8()),
        "i16": pa.array([-32768, 32767, 0, -1, None, 1], pa.int16()),
        "i32": pa.array([-2147483648, 2147483647, 0, -1, None, 1], pa.int32()),
        "i64": pa.array([-9223372036854775808, 9223372036854775807, 0, -1, None, 1], pa.int64()),
        "f32": pa.array([top32, -top32, 1.175494350822287e-38, 1.401298464324817e-45,
                         float("inf"), float("-inf")], pa.float32()),
        "f64": pa.array([top64, -top64, 2.2250738585072014e-308, 5e-324, float("inf"), float("-inf")], pa.float64()),
        "d": pa.array([-2147483648, 2147483647, 0, -719162, 2932896, None], pa.date32()),
    })


def table_encodings():
    """Integers and dates, 100 rows each, that the writer's encodings sort
    into the run spellings: a constant, a rising and a falling step,
    values of many widths, the patched-base pattern, and a mix."""
    rng = random.Random(0x4F5243)
    patched = [2030, 2000, 2020, 1000000, 2040, 2050, 2060, 2070, 2080, 2090,
               2100, 2110, 2120, 2130, 2140, 2150, 2160, 2170, 2180, 2190]
    wide = [-2**63 + 1, 2**63 - 1, -2**62, 2**62, -1234567890123456789, 1234567890123456789, None, 0]
    return pa.table({
        "repeat": pa.array([7] * 100, pa.int64()),
        "delta": pa.array(list(range(100)), pa.int64()),
        "down": pa.array([10000 - 7 * i for i in range(100)], pa.int64()),
        "direct": pa.array([rng.getrandbits(64) // 7 for _ in range(100)], pa.int64()),
        "direct64": pa.array(wide + [rng.getrandbits(63) - 2**62 for _ in range(92)], pa.int64()),
        "patched": pa.array((patched + patched[::-1]) * 2 + patched[:20], pa.int64()),
        "dates": pa.array([19000 + i for i in range(100)], pa.date32()),
        "mixed": pa.array([5] * 12 + [i * 3 for i in range(40)] + [rng.getrandbits(30) for _ in range(28)] + patched,
                          pa.int64()),
        "v2lit": pa.array([None if i % 7 == 3 else 2 ** (i % 62) for i in range(100)], pa.int64()),
        "narrow": pa.array([rng.getrandbits(9) for _ in range(100)], pa.int64()),
    })


def table_encodings_long():
    """Three integer columns of 1,050 rows: more values than one run of
    the version 2 encodings holds (512), so every stream is several runs
    of one spelling in a row."""
    rng = random.Random(0x4C4F4E47)
    return pa.table({
        "random": pa.array([rng.getrandbits(64) // 7 for _ in range(1050)], pa.int64()),
        "step": pa.array([i * 13 for i in range(1050)], pa.int64()),
        "same": pa.array([9] * 1050, pa.int64()),
    })


def table_stripes():
    rng = random.Random(0x53545249)
    words = ["alpha", "beta", "gamma", "delta", "ünï"]
    return pa.table({
        "i": pa.array(list(range(60)), pa.int64()),
        "s": pa.array([None if i % 11 == 4 else words[i % 5] for i in range(60)], pa.string()),
        "f": pa.array([i * 1.25 for i in range(60)], pa.float64()),
        "b": pa.array([i % 3 == 0 for i in range(60)], pa.bool_()),
    })


def table_decimals():
    """A decimal of every precision at a edge: 1, 2, 9, 10, 17, 18, 19, 20, 33, 34, 35 and 38,
    every value within the 34 significant digits the library holds."""

    def col(p, s, values):
        return pa.array([None] + [Decimal(v) for v in values], pa.decimal128(p, s))

    return pa.table({
        "p1": col(1, 0, ["7", "0"]),
        "p2": col(2, 2, ["0.07", "-0.07"]),
        "p9": col(9, 4, ["12345.6789", "-99999.9999"]),
        "p10": col(10, 0, ["1234567890", "-1234567890"]),
        "p17": col(17, 9, ["12345678.123456789", "0.000000001"]),
        "p18": col(18, 2, ["999999999999999.99", "-0.01"]),
        "p19": col(19, 2, ["1234567890123456.78", "1.00"]),
        "p20": col(20, 4, ["1234567890123456.7890", "7"]),
        "p33": col(33, 10, ["12345678901234567890123.1234567890", "-1.0000000001"]),
        "p34": col(34, 2, ["1234567890123456789012345678901.23", "-99999999999999999999999999999999.99"]),
        "p35": col(35, 2, ["100000000000000000000000000000000.00", "-1"]),
        "p38": col(38, 8, ["12345678901234567890123456.78901234", "-0.00000001"]),
    })


def table_names():
    return pa.table({
        "": pa.array([1, None], pa.int32()),
        "a" * 255: pa.array(["x", "y"], pa.string()),
        "日本語 ünïcödé": pa.array([[1], None], pa.list_(pa.int32())),
        "with space and\ttab": pa.array([None, True], pa.bool_()),
    })


# ── files derived from a written one ────────────────────────────────

POSTSCRIPT = {"footer_length": 1, "compression": 2, "block_size": 3, "metadata_length": 5, "writer_version": 6}


def set_postscript(data, **fields):
    """The file with PostScript fields set or dropped (a field given as
    None is dropped); the footer does not move, so only the PostScript
    and its length byte change."""
    f = O.File(data)
    ps = O.set_varints(f.ps, {POSTSCRIPT[k]: v for k, v in fields.items()})
    if len(ps) > 255:
        raise SystemExit("a PostScript of %d bytes" % len(ps))
    return data[:f.ps_at] + ps + bytes((len(ps),))


def drop_magic(data):
    """The file without the magic at the end of its PostScript — the
    spelling of the format's first files, which carry it at the head
    only."""
    f = O.File(data)
    ps = O.refield(f.ps, 8000, lambda v, w: b"")
    return data[:f.ps_at] + ps + bytes((len(ps),))


def retag_head(data, head):
    """The file with its first bytes replaced."""
    return head + data[len(head):]


def rewrite_footer(data, footer):
    """The file with its Footer replaced; the stripes do not move."""
    f = O.File(data)
    ps = O.set_varints(f.ps, {1: len(footer)})
    return data[:f.footer_at] + footer + ps + bytes((len(ps),))


def patch_footer(data, fn):
    return rewrite_footer(data, fn(O.File(data).footer))


def patch_type(data, index, fn):
    """The file with type `index` of the footer's type tree replaced by
    `fn(old bytes) -> bytes`."""
    count = [0]

    def enc(n, w, v):
        if n != 4:
            return O.keep(n, w, v)
        i = count[0]
        count[0] += 1
        return O.f_bytes(4, fn(v)) if i == index else O.keep(n, w, v)

    return patch_footer(data, lambda footer: O.rebuild(footer, enc))


def set_subtypes(raw, ids):
    """A type's message with its subtypes set: a leaf carries no subtype
    field, so the field is spelled afresh at the message's end."""
    return O.drop_field(raw, 2) + O.f_packed(2, ids)


def retype(data, column, kind, **fields):
    """The file with type `column`'s kind replaced, and its maximumLength,
    precision or scale set as given (maximum_length=, precision=, scale=)."""
    names = {"maximum_length": 4, "precision": 5, "scale": 6}
    changes = {1: kind}
    changes.update({names[k]: v for k, v in fields.items()})

    def fn(raw):
        out = O.set_varints(raw, changes)
        return out

    return patch_type(data, column, fn)


def patch_stripe(data, index, **fields):
    """The file with stripe `index`'s information changed (offset=,
    index_length=, data_length=, footer_length=, rows=); with `index`
    None, every stripe's."""
    names = {"offset": 1, "index_length": 2, "data_length": 3, "footer_length": 4, "rows": 5}
    changes = {names[k]: v for k, v in fields.items()}
    count = [0]

    def enc(n, w, v):
        if n == 3:
            i = count[0]
            count[0] += 1
            return O.f_bytes(3, O.set_varints(v, changes)) if index is None or i == index else O.keep(n, w, v)
        return O.keep(n, w, v)

    return patch_footer(data, lambda footer: O.rebuild(footer, enc))


def type_column_of(data, name):
    """The type id of the top-level field `name`."""
    t = O.File(data).types[0]
    return t.subtypes[t.names.index(name)]


def stripe_footer_edit(data, fn):
    """The file with its one stripe's footer replaced by `fn(old) -> bytes`
    behind the same streams. The file must be uncompressed, with one
    stripe: the footer grows or shrinks and the file's footer follows it."""
    f = O.File(data)
    if f.compression != 0 or len(f.stripes) != 1:
        raise SystemExit("stripe_footer_edit needs an uncompressed single-stripe file")
    s = f.stripe(0)
    new = fn(s.footer)
    out = data[:s.footer_at] + new + data[s.footer_at + s.footer_length:]
    out = patch_stripe(out, 0, footer_length=len(new))
    return patch_footer(out, lambda footer: O.set_varints(footer, {2: O.get(footer, 2, 0) + len(new) - len(s.footer)}))


def insert_stream(data, kind, column, payload):
    """The file with one more stream, `payload` under `kind` for `column`,
    after the stripe's last stream."""

    def fn(sf):
        entry = O.f_bytes(1, O.f_varint(1, kind) + O.f_varint(2, column) + O.f_varint(3, len(payload)))
        out = b""
        added = False
        for n, w, v, _ in O.fields(sf):
            if not added and n != 1:
                out += entry
                added = True
            out += O.keep(n, w, v)
        return out + (b"" if added else entry)

    s = O.File(data).stripe(0)
    out = data[:s.footer_at] + payload + data[s.footer_at:]
    out = patch_stripe(out, 0, data_length=s.data_length + len(payload))
    out = patch_footer(out, lambda footer: O.set_varints(footer, {2: O.get(footer, 2, 0) + len(payload)}))
    return stripe_footer_edit(out, fn)


def lengthen_stream(data, column, delta):
    """The file with the length of column `column`'s first stream changed
    by `delta` bytes; the stream's bytes do not move."""

    def fn(sf):
        done = [False]

        def enc(n, w, v):
            if n != 1 or done[0] or O.get(v, 2, 0) != column:
                return O.keep(n, w, v)
            done[0] = True
            return O.f_bytes(1, O.set_varints(v, {3: O.get(v, 3, 0) + delta}))

        return O.rebuild(sf, enc)

    return stripe_footer_edit(data, fn)


def set_encoding(data, column, kind):
    """The file with column `column`'s encoding kind replaced."""

    def fn(sf):
        count = [0]

        def enc(n, w, v):
            if n != 2:
                return O.keep(n, w, v)
            i = count[0]
            count[0] += 1
            return O.f_bytes(2, O.set_varints(v, {1: kind})) if i == column else O.keep(n, w, v)

        return O.rebuild(sf, enc)

    return stripe_footer_edit(data, fn)


def boolean_rle(flags):
    """The byte run length encoding of a present stream: the bits, most
    significant first, padded to a byte, as literal runs."""
    out = bytearray()
    byte, n = 0, 0
    bits = []
    for flag in flags:
        byte = (byte << 1) | flag
        n += 1
        if n == 8:
            bits.append(byte)
            byte, n = 0, 0
    if n:
        bits.append(byte << (8 - n))
    for at in range(0, len(bits), 128):
        chunk = bits[at:at + 128]
        out.append(256 - len(chunk))
        out.extend(chunk)
    return bytes(out)


CODECS = {"zlib": 1, "snappy": 2, "lz4": 4, "zstd": 5}


def compress_piece(piece, codec):
    """One compression block's payload under `codec`, in the format's raw
    spelling: DEFLATE without a zlib header, a snappy block without its
    framing, an lz4 block, a zstd frame."""
    if codec == "zlib":
        c = zlib.compressobj(6, zlib.DEFLATED, -15)
        return c.compress(piece) + c.flush()
    import cramjam

    if codec == "snappy":
        return bytes(cramjam.snappy.compress_raw(piece))
    if codec == "lz4":
        # the wheel spells a block with four bytes of its uncompressed
        # size before it; the format's block is the rest
        return bytes(cramjam.lz4.compress_block(piece))[4:]
    if codec == "zstd":
        return bytes(cramjam.zstd.compress(piece))
    raise SystemExit("no such codec: %s" % codec)


def blocks_of(raw, chunk, codec, mix=False, pack=True):
    """Logical bytes as compression blocks of at most `chunk` payload
    bytes each, a list of one byte string a block. A block is compressed
    where that makes it shorter; with `pack` off every block is left as it
    is, and with `mix` every other one is."""
    out = []
    for i, at in enumerate(range(0, len(raw), chunk)):
        piece = raw[at:at + chunk]
        packed = compress_piece(piece, codec)
        if len(packed) < len(piece) and pack and not (mix and i % 2 == 0):
            out.append(O.block_header(len(packed), False) + packed)
        else:
            out.append(O.block_header(len(piece), True) + piece)
    return out


def wrap_blocks(raw, chunk, codec="zlib", mix=False):
    return b"".join(blocks_of(raw, chunk, codec, mix))


def cut_blocks(data, chunk, codec="zlib", mix=False, pack=True, alter=None, block_size=256 * 1024):
    """An uncompressed file rewritten as a file under `codec` whose every
    stream, stripe footer, metadata and footer is a sequence of
    compression blocks of at most `chunk` payload bytes each — compressed
    where that makes them shorter, unless `pack` is off or `mix` leaves
    every other block as it is. `alter`, when given, sees each sequence —
    `alter(part, index, blocks)` answers the blocks to write in their
    place — so that one block can be broken on purpose."""
    f = O.File(data)
    if f.compression != 0:
        raise SystemExit("cut_blocks needs an uncompressed file")

    def wrapped(part, index, raw):
        blocks = blocks_of(raw, chunk, codec, mix, pack)
        return b"".join(blocks if alter is None else alter(part, index, blocks))

    out = bytearray(data[:3])
    cursor = 3
    infos = []
    for i in range(len(f.stripes)):
        s = f.stripe(i)
        rebuilt, lengths = b"", []
        for j, st in enumerate(s.raw_streams):
            wrapped_stream = wrapped("stream", j, data[st.at:st.at + st.length])
            lengths.append(len(wrapped_stream))
            rebuilt += wrapped_stream
        k = [0]

        def enc(n, w, v):
            if n != 1:
                return O.keep(n, w, v)
            j = k[0]
            k[0] += 1
            return O.f_bytes(1, O.refield(v, 3, lambda a, b, j=j: O.f_varint(3, lengths[j])))

        wrapped_sf = wrapped("stripe footer", i, O.rebuild(s.footer, enc))
        index_new = 0 if s.index_length == 0 else sum(
            n for st, n in zip(s.raw_streams, lengths) if st.kind in (6, 7, 8))
        out += rebuilt + wrapped_sf
        infos.append(O.set_varints(O.all_of(f.footer, 3)[i],
                                   {1: cursor, 2: index_new, 3: len(rebuilt) - index_new, 4: len(wrapped_sf)}))
        cursor += len(rebuilt) + len(wrapped_sf)
    k = [0]

    def enc_footer(n, w, v):
        if n == 3:
            j = k[0]
            k[0] += 1
            return O.f_bytes(3, infos[j])
        return O.keep(n, w, v)

    footer = O.rebuild(f.footer, enc_footer)
    footer = O.set_varints(footer, {2: cursor - 3})
    wrapped_meta = wrapped("metadata", 0, data[f.metadata_at:f.footer_at])
    wrapped_footer = wrapped("footer", 0, footer)
    out += wrapped_meta + wrapped_footer
    ps = O.set_varints(f.ps, {1: len(wrapped_footer), 2: CODECS[codec], 3: block_size, 5: len(wrapped_meta)})
    out += ps + bytes((len(ps),))
    return bytes(out)


def example(name):
    """A small example file of the format's own repository, from the
    probe's download when it is there, else from the tagged source."""
    for directory in (EXAMPLES, EXAMPLES_BIG):
        path = os.path.join(directory, name)
        if os.path.exists(path):
            with open(path, "rb") as f:
                return f.read()
    return urllib.request.urlopen(EXAMPLES_URL + urllib.request.quote(name)).read()


# ── the corpus ───────────────────────────────────────────────────────

def carried_names(data):
    f = O.File(data)
    t = f.types[0]
    return [n for i, n in zip(t.subtypes, t.names) if dtype_of(f, i) is not None]


def corpus():
    """Every file: (name, bytes, origin, note, refusal or None, views)."""
    small = table_small()
    scalars = table_scalars()
    nested = table_nested()
    items = []

    def add(file, data, origin, note, refuse=None, views=None, own=None):
        if refuse is not None:
            refuse = (refuse[0], refuse[1], TEXTS.get(file))
        items.append((file, data, origin, note, refuse, views, own))

    plain = "five rows: an int32 and a string, each with a null"
    add("pyorc_small_uncompressed.orc", write(small), "pyarrow", plain + "; no compression")
    for kind in ("zlib", "snappy", "lz4", "zstd"):
        add("pyorc_small_%s.orc" % kind, write(small, compression=kind.upper()), "pyarrow",
            plain + "; under %s: the tiny streams are stored as they are, the rest compressed" % kind.upper())
    add("pyorc_scalars.orc", write(scalars), "pyarrow",
        "one column a carried scalar type, nulls among the cells; a 5,000-byte string, control characters, emoji")
    add("pyorc_scalars_v011.orc", write(scalars, file_version="0.11"), "pyarrow", "the same table in the 0.11 format")
    add("pyorc_dictionary.orc", write(table_dictionary(), dictionary_key_size_threshold=0.8), "pyarrow",
        "strings under the dictionary threshold: two columns stay dictionary encoded, one falls back to direct")
    add("pyorc_dictionary_v011.orc", write(table_dictionary(), dictionary_key_size_threshold=0.8, file_version="0.11"),
        "pyarrow", "the same in the 0.11 format")
    add("pyorc_nested.orc", write(nested), "pyarrow",
        "lists of ints, strings, lists and structs; a struct of a struct; nulls and empty lists at every level")
    add("pyorc_nested_v011.orc", write(nested, file_version="0.11"), "pyarrow", "the same in the 0.11 format")
    add("pyorc_nulls.orc", write(table_nulls()), "pyarrow",
        "every carried type as a column of nothing but nulls, and as a column with none")
    add("pyorc_extremes.orc", write(table_extremes()), "pyarrow", "the numeric extremes, the largest and smallest floats")
    add("pyorc_encodings.orc", write(table_encodings()), "pyarrow",
        "integer columns the writer spells as short repeat, direct, patched base and delta runs; 1,100 values past one run")
    add("pyorc_encodings_v011.orc", write(table_encodings(), file_version="0.11"), "pyarrow", "the same in the 0.11 format")
    add("pyorc_encodings_long.orc", write(table_encodings_long()), "pyarrow",
        "1,050 rows in three integer columns: more values than one run of the version 2 encodings holds")
    add("pyorc_stripes.orc", write(table_stripes(), stripe_size=512, row_index_stride=8, batch_size=10,
                                   dictionary_key_size_threshold=0.8), "pyarrow",
        "60 rows in six stripes of three row groups each, a dictionary string column")
    add("pyorc_empty.orc", write(pa.table({})), "pyarrow", "no column and no row")
    add("pyorc_norows.orc", write(scalars.slice(0, 0)), "pyarrow", "a column a carried type, and no row")
    utc = datetime.timezone.utc
    add("pyorc_timestamp_instant.orc",
        write(pa.table({"inst": ts([0, None, 1583054696789000, -1000], "us", utc), "n": pa.array([1, 2, 3, 4], pa.int32())})),
        "pyarrow", "a time-zone-aware timestamp column: the TIMESTAMP_INSTANT type")
    add("pyorc_timestamp_edges.orc", write(table_timestamp_edges()), "pyarrow",
        "instants before the epoch with a fraction, in microseconds, nanoseconds, milliseconds and seconds; "
        "the first and the last instant a 64-bit nanosecond count holds")
    add("pyorc_timestamp_bounds.orc", write(table_timestamp_bounds()), "pyarrow",
        "past what the reference reader holds: the instants at the ends of a 64-bit microsecond count, in microseconds "
        "and in whole seconds, and the first and the last datetime; the view's cells are the generator's own",
        None, None, bounds_cells())
    add("pyorc_timestamp_overflow.orc", write(table_timestamp_overflow()), "pyarrow",
        "whole seconds past what a 64-bit microsecond count holds", ("Unsupported", "a timestamp past a 64-bit microsecond count"), [["n"]])
    add("pyorc_decimals.orc", write(table_decimals()), "pyarrow", "a decimal of every precision from 1 to 38 at its edges")
    add("pyorc_multiblock_zlib.orc", write(pa.table({"t": pa.array(["abcdefgh" * 16] * 550, pa.string())}), compression="ZLIB"),
        "pyarrow", "one string stream of 70,400 bytes: two compression blocks")
    add("pyorc_names.orc", write(table_names()), "pyarrow", "an empty name, a name of 255 bytes, a non-ASCII name, blanks in a name")
    add("pyorc_dupnames.orc",
        write(pa.table([pa.array([1, 2], pa.int32()), pa.array([3, 4], pa.int64())], names=["a", "a"])),
        "pyarrow", "two fields of one name: the names come back as spelled")
    refused = {"n": pa.array([1, None, 3], pa.int32())}
    add("pyorc_binary.orc", write(pa.table({**refused, "bin": pa.array([b"\x00\x01", None, b"abc"], pa.binary())})),
        "pyarrow", "a BINARY column", ("Unsupported", "a BINARY column"), [["n"]])
    add("pyorc_map.orc", write(pa.table({**refused, "m": pa.array([[("k", 1)], None, []], pa.map_(pa.string(), pa.int32()))})),
        "pyarrow", "a MAP column", ("Unsupported", "a MAP column"), [["n"]])
    union = pa.UnionArray.from_dense(pa.array([0, 0, 1], pa.int8()), pa.array([0, 1, 0], pa.int32()),
                                     [pa.array([1, None], pa.int32()), pa.array([3.5], pa.float64())])
    add("pyorc_union.orc", write(pa.table({**refused, "u": union})), "pyarrow", "a UNION column",
        ("Unsupported", "a UNION column"), [["n"]])
    add("pyorc_nested_binary.orc",
        write(pa.table({"n": refused["n"], "lb": pa.array([[b"a"], None, []], pa.list_(pa.binary())),
                        "sb": pa.array([{"b": b"x"}, None, {}], pa.struct([("b", pa.binary())])),
                        "li": pa.array([[1], None, [2, 3]], pa.list_(pa.int32()))})),
        "pyarrow", "a BINARY inside a list and inside a struct",
        ("Unsupported", "a BINARY inside a list and inside a struct"), [["n", "li"]])
    add("pyorc_dupfield.orc",
        write(pa.table({"st": pa.array([{"a": 1, "a": 2}, None, {"a": 3, "a": 4}],
                                       pa.struct([("a", pa.int32()), ("a", pa.int64())]))})),
        "pyarrow", "a struct whose two fields share a name", ("Unsupported", "a struct whose two fields share a name"), [])
    add("pyorc_timestamp_nanos.orc",
        write(pa.table({"n": refused["n"], "t": ts([1, 1000, 999], "ns")})),
        "pyarrow", "timestamps with a nanosecond remainder", ("Unsupported", "a nanosecond remainder"), [["n"]])
    add("pyorc_decimal_wide.orc",
        write(pa.table({"n": refused["n"], "d": pa.array([Decimal("100000000000000000000000000000000.07"),
                                                           Decimal("-1"), Decimal("0.00")], pa.decimal128(38, 2))})),
        "pyarrow", "a decimal of 35 significant digits", ("Unsupported", "a decimal of 35 significant digits"), [["n"]])

    real = "the format's own repository's example file (Apache-2.0)"
    add("orc_TestOrcFile.test1.orc", example("TestOrcFile.test1.orc"), "apache/orc examples",
        real + ": the Java writer; every type in a struct, BINARY and MAP among them; ZLIB",
        ("Unsupported", "BINARY and MAP columns"), [["boolean1", "byte1", "short1", "int1", "long1", "float1", "double1",
                                                       "string1", "middle", "list"]])
    add("orc_TestOrcFile.emptyFile.orc", example("TestOrcFile.emptyFile.orc"), "apache/orc examples",
        real + ": the Java writer; a schema of every type and no row",
        ("Unsupported", "BINARY and MAP columns"), [["boolean1", "byte1", "short1", "int1", "long1", "float1", "double1",
                                                       "string1", "middle", "list"]])
    add("orc_TestOrcFile.testStringAndBinaryStatistics.orc", example("TestOrcFile.testStringAndBinaryStatistics.orc"),
        "apache/orc examples", real + ": the Java writer; a BINARY and a STRING column",
        ("Unsupported", "a BINARY column"), [["string1"]])
    add("orc_TestOrcFile.testTimestamp.orc", example("TestOrcFile.testTimestamp.orc"), "apache/orc examples",
        real + ": the Java writer; the top-level type is a TIMESTAMP, not a struct",
        ("Unsupported", "the top-level type is not a struct"), [])
    add("orc_TestOrcFile.testWithoutCompressionBlockSize.orc", example("TestOrcFile.testWithoutCompressionBlockSize.orc"),
        "apache/orc examples", real + ": the Java writer; the top-level type is a LONG; SNAPPY with no block size",
        ("Unsupported", "the top-level type is not a struct"), [])
    for name in ("bad_bloom_filter_1.6.0.orc", "bad_bloom_filter_1.6.11.orc"):
        add("orc_" + name, example(name), "apache/orc examples",
            real + ": the C++ writer 1.6; a bloom filter to step over; a PRESENT stream on the root struct; DELTA runs")
    add("orc_complextypes_iceberg.orc", example("complextypes_iceberg.orc"), "apache/orc examples",
        real + ": the Java writer; lists of lists, structs in lists, MAPs; a dictionary of no entry",
        ("Unsupported", "MAP columns"), [["id", "int_array", "int_array_array"]])
    add("orc_decimal64_v2.orc", example("decimal64_v2.orc"), "apache/orc examples",
        real + ": the Java writer; decimals of precision up to 18 in the UNSTABLE-PRE-2.0 spelling")
    add("orc_decimal64_v2_cplusplus.orc", example("decimal64_v2_cplusplus.orc"), "apache/orc examples",
        real + ": the C++ writer; decimals of precision up to 18 in the UNSTABLE-PRE-2.0 spelling")
    add("orc_no_format.orc", example("orc_no_format.orc"), "apache/orc examples",
        real + ": an old Java writer; no format version and no magic in the PostScript; a list, a map and a struct",
        ("Unsupported", "a MAP column"), [["_col0", "_col2"]])
    add("orc_version1999.orc", example("version1999.orc"), "apache/orc examples",
        real + ": format version 19.99, a struct of no field, no row; the reference reader only warns",
        ("Unsupported", "a format version this reader does not read"))
    add("orc_zero.orc", example("zero.orc"), "apache/orc examples", real + ": no byte at all",
        ("ParseError", "an empty file"), [])
    add("orc_TestOrcFile.testMemoryManagementV11.orc", example("TestOrcFile.testMemoryManagementV11.orc"), "apache/orc examples",
        real + ": the Java writer; 2,500 rows in 25 stripes, no index, RLE v1, a dictionary of 100 entries")

    syn = "derived from pyorc_small_uncompressed.orc"
    base = write(small)
    add("synthetic_lzo.orc", set_postscript(base, compression=3), "synthetic", syn + ": the PostScript names LZO",
        ("Unsupported", "LZO"), [])
    add("synthetic_compression_9.orc", set_postscript(base, compression=9), "synthetic", syn + ": the PostScript names compression 9",
        ("Unsupported", "an unknown compression kind"), [])
    base_file = O.File(base)
    add("synthetic_no_magic.orc", drop_magic(base), "synthetic",
        syn + ": no magic at the end of the PostScript, as the format's first files carry it; the magic at the head remains")
    add("synthetic_bad_magic.orc", retag_head(drop_magic(base), b"ORX"), "synthetic",
        syn + ": no magic at the end of the PostScript, and the head spells ORX", ("ParseError", "not an ORC file"), [])
    add("synthetic_postscript_0.orc", base[:-1] + b"\x00", "synthetic", syn + ": the PostScript length byte says 0",
        ("ParseError", "a PostScript of no byte"), [])
    add("synthetic_postscript_3.orc", base[:-1] + b"\x03", "synthetic",
        syn + ": the PostScript length byte says 3, cutting the PostScript", ("ParseError", "the PostScript is malformed"), [])
    add("synthetic_footer_cut.orc", rewrite_footer(base, base_file.footer[:-5]), "synthetic",
        syn + ": the footer's last five bytes cut, its last field inside", ("ParseError", "the footer ends inside a field"), [])
    add("synthetic_footer_wire.orc",
        rewrite_footer(base, O.refield(base_file.footer, 4, lambda v, w: O.f_varint(4, 1))), "synthetic",
        syn + ": every type of the footer arrives as a varint, not a message", ("ParseError", "the footer is malformed"), [])
    add("synthetic_footer_long.orc", set_postscript(base, footer_length=base_file.footer_length + 400), "synthetic",
        syn + ": the footer length names bytes past the file", ("ParseError", "the tail leaves the file"), [])
    add("synthetic_metadata_long.orc", set_postscript(base, metadata_length=base_file.metadata_length + 200), "synthetic",
        syn + ": the metadata length names more than the file holds before the footer", ("ParseError", "the metadata leaves the file"), [])
    add("synthetic_compression_absent.orc", set_postscript(base, compression=None), "synthetic",
        syn + ": no compression kind in the PostScript", ("ParseError", "no compression kind"), [])
    add("synthetic_rows_plus_one.orc", patch_footer(base, lambda footer: O.set_varints(footer, {6: 6})), "synthetic",
        syn + ": the footer declares 6 rows and its stripe 5", ("ParseError", "the rows disagree"), [])
    add("synthetic_rows_huge.orc", patch_footer(base, lambda footer: O.set_varints(footer, {6: 2**40})), "synthetic",
        syn + ": the footer declares 2^40 rows and its stripe 5", ("ParseError", "the rows disagree"), [])
    add("synthetic_stream_long.orc", lengthen_stream(base, 2, 40), "synthetic",
        syn + ": the string column's first stream names 40 bytes past its stripe", ("ParseError", "a stream leaves its stripe"), [])
    add("synthetic_stream_short.orc", lengthen_stream(base, 2, -2), "synthetic",
        syn + ": the string column's PRESENT stream cut by two bytes", ("ParseError", "a stream ends inside a value"), [])
    add("synthetic_stripe_footer_long.orc", patch_stripe(base, 0, footer_length=base_file.stripes[0].footer_length + 400), "synthetic",
        syn + ": the stripe footer's length names bytes past the file", ("ParseError", "the stripe leaves the file"), [])
    add("synthetic_stripe_footer_short.orc", patch_stripe(base, 0, footer_length=base_file.stripes[0].footer_length - 6), "synthetic",
        syn + ": the stripe footer's length cut by six bytes", ("ParseError", "the stripe footer is malformed"), [])
    add("synthetic_stripe_offset.orc", patch_stripe(base, 0, offset=1), "synthetic",
        syn + ": the stripe starts inside the magic", ("ParseError", "a stripe starts before the body"), [])
    add("synthetic_stripe_absent.orc", patch_footer(base, lambda footer: O.refield(footer, 3, lambda v, w: b"")), "synthetic",
        syn + ": no stripe under 5 declared rows", ("ParseError", "the rows disagree"), [])
    add("synthetic_no_types.orc", patch_footer(base, lambda footer: O.refield(footer, 4, lambda v, w: b"")), "synthetic",
        syn + ": the footer carries no type", ("ParseError", "no type"), [])
    add("synthetic_type_names.orc", patch_type(base, 0, lambda raw: O.refield(raw, 3, lambda v, w: b"")), "synthetic",
        syn + ": the root struct has two subtypes and no field name", ("ParseError", "the type tree does not hold together"), [])
    add("synthetic_type_link.orc", patch_type(base, 2, lambda raw: set_subtypes(raw, [2])), "synthetic",
        syn + ": the string column names itself for subtype", ("ParseError", "the type tree does not hold together"), [])
    add("synthetic_type_past.orc", patch_type(base, 1, lambda raw: set_subtypes(raw, [9])), "synthetic",
        syn + ": the int column names a subtype the footer does not carry", ("ParseError", "the type tree does not hold together"), [])
    add("synthetic_top_long.orc", patch_type(base, 0, lambda raw: O.refield(raw, 1, lambda v, w: O.f_varint(1, 4))), "synthetic",
        syn + ": the root type retyped LONG, its two subtypes beneath it", ("Unsupported", "the top-level type is not a struct"), [])
    add("synthetic_encodings_short.orc", stripe_footer_edit(base, lambda sf: O.refield(sf, 2, lambda v, w: b"")), "synthetic",
        syn + ": the stripe footer names no encoding", ("ParseError", "the encodings do not match the types"), [])
    add("synthetic_kind_19.orc", retype(base, 2, 19), "synthetic", syn + ": the string column retyped kind 19",
        ("Unsupported", "a type of kind 19"), [])
    add("synthetic_encoding_4.orc", set_encoding(base, 2, 4), "synthetic", syn + ": the string column declares an encoding of kind 4",
        ("Unsupported", "an encoding of kind 4"), [])
    add("synthetic_encoding_dictionary_int.orc", set_encoding(base, 1, 3), "synthetic",
        syn + ": the int32 column declares DICTIONARY_V2", ("Unsupported", "a dictionary encoding on an int"), [])
    add("synthetic_encrypted.orc", patch_footer(base, lambda footer: footer + O.f_bytes(10, b"")), "synthetic",
        syn + ": the footer carries an encryption field", ("Unsupported", "encrypted columns"), [])
    add("synthetic_encrypted_stream.orc", insert_stream(base, 10, 0, b""), "synthetic",
        syn + ": an ENCRYPTED_DATA stream", ("Unsupported", "encrypted columns"), [])
    add("synthetic_dictionary_count_stream.orc", insert_stream(base, 4, 2, b"\x00"), "synthetic",
        syn + ": a DICTIONARY_COUNT stream beside the string column's, stepped over")
    add("synthetic_unknown_stream.orc", insert_stream(base, 77, 1, b"\x01\x02\x03"), "synthetic",
        syn + ": a stream of a kind the reader does not know, stepped over")
    add("synthetic_varchar.orc", retype(base, 2, 16, maximum_length=2), "synthetic",
        syn + ": the string column retyped VARCHAR(2)")
    add("synthetic_char.orc", retype(base, 2, 17, maximum_length=4), "synthetic",
        syn + ": the string column retyped CHAR(4)")
    add("synthetic_decimal_precision_0.orc", retype(write(table_decimals()), 2, 14, precision=0), "synthetic",
        "derived from pyorc_decimals.orc: the first decimal retyped to precision 0, the first format's decimal")
    add("synthetic_root_null.orc", insert_stream(base, 0, 0, boolean_rle([1, 1, 0, 1, 1])), "synthetic",
        syn + ": a PRESENT stream on the root struct, the third row absent")
    add("synthetic_root_all_null.orc", insert_stream(base, 0, 0, boolean_rle([0, 0, 0, 0, 0])), "synthetic",
        syn + ": a PRESENT stream on the root struct, every row absent")
    add("synthetic_blocks_original.orc", cut_blocks(base, 7, pack=False), "synthetic",
        syn + ": ZLIB, every stream, footer and metadata in blocks of at most 7 bytes, each stored as it is")
    add("synthetic_blocks_mixed.orc", cut_blocks(base, 9, mix=True), "synthetic",
        syn + ": ZLIB, blocks of at most 9 bytes, every other one a DEFLATE stream")
    add("synthetic_blocks_huge_block_size.orc", set_postscript(cut_blocks(base, 7, pack=False), block_size=2**40), "synthetic",
        syn + ": a compression block size of 2^40")
    repeated = write(pa.table({"t": pa.array(["abcdefgh" * 6] * 200, pa.string()), "n": pa.array(range(200), pa.int32())}))
    for codec in ("snappy", "lz4", "zstd"):
        add("synthetic_%s_compressed.orc" % codec, cut_blocks(repeated, 300, codec=codec), "synthetic",
            "derived from a written file of 200 rows: every stream, stripe footer, metadata and footer in %s blocks "
            "of at most 300 payload bytes, each compressed wherever that is shorter" % codec.upper())
    return items + built_items() + broken_items(base) + block_items(base)


# ── files built stream by stream ────────────────────────────────────

def pad_v1(values, n):
    """A version 1 integer stream of `n` values: `values`, then zeros."""
    return E.rle1(values) + E.rle1([0] * (n - len(values)))


def pad_v2(values, n):
    """A version 2 integer stream of `n` values: `values`, then zeros."""
    return E.rle2(values) + E.rle2([0] * (n - len(values)))


def long_(stream, encoding=E.DIRECT_V2):
    return E.Column(E.LONG, encoding, [(E.DATA, stream)])


def spell(values, kind):
    """Cells as the sidecar spells them, from the values the generator
    wrote: the spelling of a column the reference reader answers
    differently."""
    out = []
    for v in values:
        if v is None:
            out.append(None)
        elif kind == "Timestamp":
            out.append("Timestamp %d" % v)
        else:
            out.append("Decimal " + format(v, "f"))
    return out


def built_items():
    """The files built stream by stream with the encoder, one spelling of
    the run length encodings to a column: the reference reader reads
    every one of them back, which is the encoder's own check, and its
    cells are the sidecar's. Two files answer differently from the
    reference reader by the codec's decision: their cells are the
    generator's own, spelled from the values it wrote, and the view says
    so."""
    items = []

    def add(file, data, note, own=None):
        items.append((file, data, "hand-built", note, None, None, own))

    n = 140
    flags = ([True, False, True, True, False, True] * 23 + [True, True])[:n]
    present = [i for i, f in enumerate(flags) if f]
    add("built_rle_v1.orc", E.build_file([
        long_(pad_v1([7 + i for i in range(130)], n), E.DIRECT),
        long_(pad_v1([100 - i for i in range(100)], n), E.DIRECT),
        long_(pad_v1([-5, 0, 2 ** 62, -(2 ** 62)], n), E.DIRECT),
        long_(pad_v1([1, 2] + [9] * 3 + [-1], n), E.DIRECT),
        long_(pad_v1(list(range(128)) + [99], n), E.DIRECT),
        E.Column(E.INT, E.DIRECT, [(E.PRESENT, E.present(flags)), (E.DATA, pad_v1([10 + i for i in present], len(present)))]),
        E.Column(E.SHORT, E.DIRECT, [(E.DATA, pad_v1([-(2 ** 15), 2 ** 15 - 1, 0], n))]),
        E.Column(E.BYTE, E.DIRECT, [(E.PRESENT, E.present(flags)),
                                    (E.DATA, E.byte_rle_run(5, 130) + E.byte_rle_literals(bytes([255, 128, 0, 127])))]),
    ], n), "the 0.11 integer encoding: a run rising, a run falling, literals with the ends of the count, "
        "a run and literals chained, 128 literals and one more; an int and a short kind; a byte column "
        "as byte run length")
    n = 12
    add("built_rle_v2_short.orc", E.build_file([
        long_(E.rle2_short_repeat(5, 3) + pad_v2([0] * 9, 9)),
        long_(E.rle2_short_repeat(-100000, 3) + pad_v2([0] * 9, 9)),
        long_(E.rle2_short_repeat(-(2 ** 63) + 1, 10) + pad_v2([0] * 2, 2)),
        long_(E.rle2_short_repeat(2 ** 62, 10) + pad_v2([0] * 2, 2)),
        long_(E.rle2_short_repeat(1, 4, width=8) + pad_v2([0] * 8, 8)),
    ], n), "short repeat runs: one byte positive, three bytes negative, eight bytes at both ends, "
        "a value in more bytes than it needs")
    n = 20
    cols = [long_(pad_v2([1, 0, -1, 1, 0, -1], n))]
    for width in (26, 28, 30, 32, 40, 48, 56, 64):
        top = 2 ** (width - 1) - 1
        values = [top, -top, 1, 0, -(2 ** (width - 2))] if width > 32 else [top, -top, 7, 0]
        cols.append(long_(pad_v2(values, n)))
    add("built_rle_v2_direct.orc", E.build_file(cols, n),
        "direct runs at the widths the writer never picks — 26, 28 and 30 bits among them — and at both ends of the count")
    n = 64
    negatives = [-5000 + i for i in range(50)] + [700]
    at128, at127 = [-128] * 20 + [-1], [-127] * 20 + [1]
    uneven = [(i * 37) % 100 + (10 ** 8 if i in (3, 14) else 0) for i in range(20)]
    uneven5 = [(i * 11) % 30 + (10 ** 9 if i in (9, 22, 30) else 0) for i in range(33)]
    across = [-(2 ** 40)] * 64
    across[10] = 2 ** 40 + 12345
    cols = [
        long_(E.rle2_patched(negatives, width=6) + pad_v2([0] * (n - 51), n - 51)),
        long_(E.rle2_patched(at128, width=1) + pad_v2([0] * (n - 21), n - 21)),
        long_(E.rle2_patched(at127, width=1) + pad_v2([0] * (n - 21), n - 21)),
        long_(E.rle2_patched(uneven, width=7) + pad_v2([0] * (n - 20), n - 20)),
        long_(E.rle2_patched(uneven5, width=5) + pad_v2([0] * (n - 33), n - 33)),
        long_(E.rle2_patched(across, width=12)),
    ]
    for pw, gw in ((18, 8), (20, 8), (22, 8), (24, 8), (23, 2), (32, 8), (40, 8), (48, 8), (56, 8)):
        high = 1 << (pw - 1)
        base = -(2 ** 62) if pw >= 56 else 0
        values = [base, base + (high << 8), base + 1, base + 2, base + 3]
        cols.append(long_(E.rle2_patched(values, width=8, patch_width=pw, gap_width=gw) + pad_v2([0] * (n - 5), n - 5)))
    add("built_rle_v2_patched.orc", E.build_file(cols, n),
        "patched base runs: a negative base at both edges of a byte, widths of 7 and 5 bits that leave a half byte "
        "before the patch list, a patch across zero, and every slot a patch list's entry fits in")
    big = [7] * 255 + [10 ** 6] + [7] * 100
    several = [100] * 300
    for i in (5, 6, 40, 150, 299):
        several[i] += 10 ** 6
    add("built_patched_long.orc", E.build_file([
        long_(E.rle2_patched(big, width=8)),
        long_(E.rle2_patched(several, width=8) + pad_v2([0] * 56, 56)),
    ], 356), "patched base runs: a gap past 255, spelled by skip entries, and five patches in one list")
    n = 1400
    add("built_long_runs.orc", E.build_file([
        long_(E.rle2(list(range(-700, 700)))),
        long_(E.rle1(list(range(n))), E.DIRECT),
        long_(b"".join(E.rle1_run(130, 1, 1000 * i) + E.rle1_literals([i]) for i in range(11)), E.DIRECT),
    ], n), "1,400 values as direct runs, as version 1 literals and as version 1 runs chained")
    rising, v = [], 0
    for i in range(512):
        rising.append(v)
        v += 1 + (i % 3)
    falling = [10 ** 9 - 7 * i for i in range(300)]
    negative, v = [], -50
    for i in range(40):
        negative.append(v)
        v -= 1 + (i % 3)
    wide = [2 ** 40, 2 ** 40 + 10 ** 12, 2 ** 40 + 2 * 10 ** 12 + 5, 2 ** 40 + 3 * 10 ** 12]
    add("built_rle_v2_delta.orc", E.build_file([
        long_(E.rle2_delta([2, 3, 5, 7, 11, 13, 17, 19, 23, 29], width=4) + pad_v2([0] * 502, 502)),
        long_(E.rle2_delta(falling) + pad_v2([0] * 212, 212)),
        long_(E.rle2_delta(list(range(0, 500, 3))) + pad_v2([0] * 345, 345)),
        long_(E.rle2_delta(wide) + pad_v2([0] * 508, 508)),
        long_(E.rle2_delta(negative) + pad_v2([0] * 472, 472)),
        long_(E.rle2_delta(rising)),
    ], 512), "delta runs: four-bit steps, a falling run, a width of zero, forty-bit steps, a negative start, 512 values")
    chain = [9] * 4 + [1, 2, 3, 4] + [500 + (i * 7) % 100 for i in range(30)] + [1000 + 3 * i for i in range(20)]
    v2 = (E.rle2_short_repeat(9, 4) + E.rle2_direct([1, 2, 3, 4]) +
          E.rle2_patched([500 + (i * 7) % 100 for i in range(30)], width=6) + E.rle2_delta([1000 + 3 * i for i in range(20)]))
    n = 58
    v1 = (E.rle1_literals([1, 2, 3]) + E.rle1_run(5, 2, 4) + E.rle1_literals([-1, -2]) +
          E.rle1_run(10, -3, 50) + E.rle1_literals([2 ** 40]) + E.rle1([0] * 37))
    flags = [True, False, True, True, False, True] * 9 + [True, True, True, True]
    present = [i for i, f in enumerate(flags) if f]
    add("built_chain.orc", E.build_file([
        long_(v2),
        long_(v1, E.DIRECT),
        E.Column(E.LONG, E.DIRECT_V2, [(E.PRESENT, E.present(flags)), (E.DATA, v2)]),
        E.Column(E.LONG, E.DIRECT, [(E.PRESENT, E.present(flags)), (E.DATA, v1)]),
    ], 58), "every version 2 run in one stream and every version 1 run in another, with and without nulls")
    flags4 = [True, True, True]
    add("built_root_null.orc", E.build_file([
        E.Column(E.LONG, streams=[(E.PRESENT, E.present(flags4)), (E.DATA, E.rle2([1, 2, 3]))]),
        E.Column(E.STRING, streams=[(E.PRESENT, E.present(flags4)), (E.LENGTH, E.unsigned([1, 0, 2])), (E.DATA, b"abc")]),
        E.list_col([1, None, 2], E.int_values(E.INT, [7, 8, 9])),
    ], 4, root_present=[True, False, True, True]),
        "a PRESENT stream on the root struct — the second row absent — and each column's own over the rows it holds")
    bools = [True, False, True, None, True, False]
    floats_ = [1.5, -2.25, None, 1e-30, 0.0, float("inf")]
    doubles_ = [0.1, -1e300, None, float("inf"), float("-inf"), 5e-324]
    dates = [0, -1, None, 20000, -(2 ** 31), 2 ** 31 - 1]
    add("built_scalars.orc", E.build_file([
        E.bool_col(bools),
        E.Column(E.BYTE, streams=[(E.PRESENT, E.present([True, False, True, True, False, True])),
                                  (E.DATA, E.byte_rle_run(5, 3) + E.byte_rle_literals(bytes([255, 128])))]),
        E.float_col(floats_, kind=E.FLOAT),
        E.float_col(doubles_),
        E.int_values(E.DATE, dates),
        E.int_values(E.SHORT, [-(2 ** 15), 2 ** 15 - 1, 0, None, 1, -1]),
        E.int_values(E.INT, [-(2 ** 31), 2 ** 31 - 1, 0, None, 1, -1]),
    ], 6), "a boolean, a byte, a float, a double, a date, a short and an int column, nulls and infinities among them")
    words = ["", "a", "héllo 日本", None, "x" * 60] * 120
    entries = ["alpha", "b", "", "long entry " * 5]
    ids = [0, 2, 1, 3, 0, 2] * 100
    add("built_strings.orc", E.build_file([
        E.string_col(words), E.string_col(words, encoding=E.DIRECT), E.string_col([""] * 600),
        E.dictionary_col(entries, ids), E.dictionary_col(entries, ids, encoding=E.DICTIONARY),
        E.dictionary_col(entries, [0, 2, 1, 3] * 100, present_rows=[True, False, False, True, True, True] * 100),
    ], 600), "strings direct in both formats, a column of empty strings, a dictionary in both formats, with nulls")
    # every nanosecond count a multiple of a thousand: a remainder has no
    # microsecond timestamp to become, and the codec refuses it
    seconds = [0, -1, 1000000000, None, -1420070400]
    nanos = [0, 1000, 999999000, 0, 123456000]
    stripped = [1000, 120000, 500000000, 999999000, 123456000]
    add("built_timestamps.orc", E.build_file([
        E.timestamp_col(seconds, nanos),
        E.timestamp_col([1, 2, 3, 4, 5], stripped),
        E.timestamp_col(seconds, nanos, encoding=E.DIRECT),
        E.timestamp_col(seconds, nanos, kind=E.TIMESTAMP_INSTANT),
    ], 5), "timestamps: before the 2015 epoch, every trailing-zero count of the nanosecond spelling, both formats, "
        "the instant kind")
    unscaled = [12345, -1, None, 10 ** 30]
    add("built_decimals.orc", E.build_file([
        E.decimal_col(unscaled, 2), E.decimal_col(unscaled, 2, encoding=E.DIRECT),
        E.decimal_col([10 ** 37, -10 ** 37, None, 9 * 10 ** 37], 0),
        E.decimal_col([15, -250, None, 1], 8, precision=10),
    ], 4), "decimals: unbounded varints with a scale stream in both formats, 128-bit edges of one significant "
        "digit, a scale of eight")
    items_values = [3, None, 1, 2, 2, 3]
    inner = E.list_col([2, 1, 0, 0, 0, 0], E.int_values(E.INT, [1, 2, 3]))
    s = E.struct_col([E.int_values(E.LONG, [7, 8, 9])], ["v"])
    add("built_nested.orc", E.build_file([
        E.list_col([1, 0, None, 2, 0, 3], E.int_values(E.LONG, items_values)),
        E.list_col([2, None, 2, 0, 0, 0], E.dictionary_col(["x", "yy"], [0, 1, 1, 0])),
        E.list_col([None, 2, 0, 0, 0, 0], inner),
        E.struct_col([E.int_values(E.LONG, [1, 2, 0, 0, 0, 0]), E.string_col([None, "s", "", "", "", ""])], ["a", "b"]),
        E.struct_col([E.int_values(E.LONG, [2, 3])], ["a"], present_rows=[False, True, False, True, False, False]),
        E.list_col([1, 2, 0, 0, 0, 0], s),
    ], 6), "lists with nulls and empty lists, a list of dictionary strings, a list of lists, a struct with a null "
        "field and a struct with an absent row, a struct in a list")
    add("built_index_streams.orc", E.build_file([E.int_values(E.LONG, [1, 2, 3])], 3, extra_streams=[
        (E.ROW_INDEX, 1, b"\x08\x05\x10\x03"), (E.BLOOM_FILTER_UTF8, 1, b"\x00"), (E.BLOOM_FILTER, 0, b"\x01"),
        (7, 1, b"\x02"), (11, 1, b"\x03"),
    ]), "row index, bloom filter, index statistics and row group length streams beside the column's, stepped over")
    add("built_no_fields.orc", E.build_file([], 0),
        "a struct of no field and no row: its stripe names no index, no data and no row, and spells none of the three")
    add("built_subtypes_unpacked.orc", E.build_file(
        [E.int_values(E.LONG, [1, 2, 3])], 3, root=E.type_msg(E.STRUCT, [1], ["c0"], unpacked=True)),
        "the root struct's subtypes spelled one field each, not packed")
    seconds = [-1420070400 - 86400 * 400, -1420070400 - 5, 0]
    nanos = [-999999000, -500000000, -1000]
    # the codec's own arithmetic: the remainder's microseconds truncate
    # toward zero, then join the seconds
    micros = [(E.ORC_EPOCH + s) * 10 ** 6 + n // 1000 for s, n in zip(seconds, nanos)]
    add("built_negative_remainder.orc", E.build_file([E.timestamp_col(seconds, nanos)], 3),
        "seconds toward zero with a negative nanosecond remainder, the first writers' legacy spelling, which no "
        "writer spells today: summed, as the Java reader does — the C++ reference reader answers another instant",
        {"c0": spell(micros, "Timestamp")})
    add("built_decimal_precision_0.orc", E.build_file([
        E.decimal_col([12345, -1, None], 2, precision=0)], 3),
        "a decimal of precision 0, the first format's: the cells carry the scale each value's stream names; the "
        "reference reader forces a scale of zero", {"c0": spell([Decimal("123.45"), Decimal("-0.01"), None], "Decimal")})
    return items


# ── the codec's refusals, by exact text ─────────────────────────────
#
# The text each refused file is answered with — the variant, the byte and
# the words — as the codec spells it: the sidecar carries it, the test
# beside the package asserts it for every file, and `make` refuses to
# write a corpus with a refusal whose text is not here. A byte in a text
# is an offset into the file, so the text moves when the file does.

TEXTS = {
    "pyorc_timestamp_overflow.orc": "orc: column \"over\" holds a timestamp past the microseconds a 64-bit count holds",
    "pyorc_binary.orc": "orc: column \"bin\" is BINARY, which has no dtype here",
    "pyorc_map.orc": "orc: column \"m\" is a MAP, which has no dtype here",
    "pyorc_union.orc": "orc: column \"u\" is a UNION, which has no dtype here",
    "pyorc_nested_binary.orc": "orc: column \"lb[]\" is BINARY, which has no dtype here",
    "pyorc_dupfield.orc": "orc: column \"st\" holds a STRUCT whose field name \"a\" repeats, which spells no schema",
    "pyorc_timestamp_nanos.orc": "orc: column \"t\" holds a timestamp with a nanosecond remainder, 1 ns in its second, which a "
                                 "microsecond timestamp cannot carry",
    "pyorc_decimal_wide.orc": "orc: column \"d\" holds a decimal of more than 34 significant digits, which the library's decimal "
                                 "cannot carry",
    "orc_TestOrcFile.test1.orc": "orc: column \"bytes1\" is BINARY, which has no dtype here",
    "orc_TestOrcFile.emptyFile.orc": "orc: column \"bytes1\" is BINARY, which has no dtype here",
    "orc_TestOrcFile.testStringAndBinaryStatistics.orc": "orc: column \"bytes1\" is BINARY, which has no dtype here",
    "orc_TestOrcFile.testTimestamp.orc": "orc: the top-level type is TIMESTAMP, where the columns are a STRUCT's fields",
    "orc_TestOrcFile.testWithoutCompressionBlockSize.orc": "orc: the top-level type is LONG, where the columns are a STRUCT's fields",
    "orc_complextypes_iceberg.orc": "orc: column \"int_map\" is a MAP, which has no dtype here",
    "orc_no_format.orc": "orc: column \"_col1\" is a MAP, which has no dtype here",
    "orc_version1999.orc": "orc: a file of format version 19.99, which this reader does not read",
    "orc_zero.orc": "orc: byte 0: a file of 0 bytes, too short for a PostScript",
    "synthetic_lzo.orc": "orc: the LZO compression kind, which this reader does not decode",
    "synthetic_compression_9.orc": "orc: compression kind 9, which this reader does not decode",
    "synthetic_bad_magic.orc": "orc: byte 0: not an ORC file: neither the end of the PostScript nor the head spells the magic",
    "synthetic_postscript_0.orc": "orc: byte 340: the PostScript length byte names 0 bytes",
    "synthetic_postscript_3.orc": "orc: byte 337: the PostScript holds a field of wire type 7, a group",
    "synthetic_footer_cut.orc": "orc: byte 311: the Footer: a field of 5 bytes runs past the message's end",
    "synthetic_footer_wire.orc": "orc: byte 226: the Footer: field 4 arrives in wire type 0",
    "synthetic_footer_long.orc": "orc: byte 317: the PostScript: with a footer of 509 bytes a tail of 534 bytes, in a file of 342",
    "synthetic_metadata_long.orc": "orc: byte 317: the PostScript: a metadata length of 240 bytes, past the head of the file",
    "synthetic_compression_absent.orc": "orc: byte 317: the PostScript names no compression kind",
    "synthetic_rows_plus_one.orc": "orc: byte 208: the Footer declares 6 rows and its stripes 5",
    "synthetic_rows_huge.orc": "orc: byte 208: the Footer declares 1099511627776 rows and its stripes 5",
    "synthetic_stream_long.orc": "orc: byte 109: stripe 0's DATA stream of column 1, which starts at byte 104: the bytes end inside a "
                                 "value",
    "synthetic_stream_short.orc": "orc: byte 72: stripe 0's LENGTH stream of column 2, which starts at byte 69: the bytes end inside a "
                                 "value",
    "synthetic_stripe_footer_long.orc": "orc: byte 208: stripe 0 runs past the body's end at byte 168",
    "synthetic_stripe_footer_short.orc": "orc: byte 158: stripe 0's footer: a field of 4 bytes runs past the message's end",
    "synthetic_stripe_offset.orc": "orc: byte 208: stripe 0 starts at byte 1, inside the magic",
    "synthetic_stripe_absent.orc": "orc: byte 208: the Footer declares 5 rows and its stripes 0",
    "synthetic_no_types.orc": "orc: byte 208: the Footer carries no type",
    "synthetic_type_names.orc": "orc: byte 208: the Footer's type 0 is a STRUCT of 2 subtypes and 0 field names",
    "synthetic_type_link.orc": "orc: byte 208: the Footer's type 2 names 1 subtype, and a STRING has none",
    "synthetic_type_past.orc": "orc: byte 208: the Footer's type 1 names 1 subtype, and an INT has none",
    "synthetic_top_long.orc": "orc: the top-level type is LONG, where the columns are a STRUCT's fields",
    "synthetic_encodings_short.orc": "orc: byte 190: stripe 0's footer names 0 encodings for 3 types",
    "synthetic_kind_19.orc": "orc: column \"s\" is of type kind 19, which this reader does not carry",
    "synthetic_encoding_4.orc": "orc: column \"s\" carries encoding 4, which this reader does not read",
    "synthetic_encoding_dictionary_int.orc": "orc: column \"a\" is not a string and carries the DICTIONARY encoding",
    "synthetic_encrypted.orc": "orc: the Footer carries encrypted columns, which this reader does not read",
    "synthetic_encrypted_stream.orc": "orc: stripe 0 carries an ENCRYPTED_DATA stream: the spelling of encrypted columns, which this reader "
                                 "does not read",
    "broken_version_13.orc": "orc: a file of format version 0.13, which this reader does not read",
    "broken_postscript_huge.orc": "orc: byte 69: the PostScript length byte names 255 bytes, past the head of the file",
    "broken_version_three.orc": "orc: a file whose PostScript names 3 version numbers, which this reader does not read",
    "broken_struct_encoding.orc": "orc: column \"st\" is a STRUCT and carries encoding 2, where the format spells DIRECT",
    "broken_utf8.orc": "orc: byte 6: stripe 0's DATA stream of column 1, which starts at byte 6: a string of column \"s\" not "
                                 "well-formed as UTF-8",
    "broken_string_length_negative.orc": "orc: byte 13: stripe 0's LENGTH stream of column 1, which starts at byte 3: a string of column \"s\" "
                                 "has a length of -9223372036854775808 bytes",
    "broken_string_bytes_short.orc": "orc: byte 6: stripe 0's DATA stream of column 1, which starts at byte 6: the lengths of column \"s\" "
                                 "name 10 bytes and the stream holds 3",
    "broken_string_data_absent.orc": "orc: byte 3: stripe 0 lists no DATA stream for the 1 present value of column 1",
    "broken_dictionary_size.orc": "orc: byte 3: the dictionary of column \"d\" declares 2147483648 entries, past what a column holds",
    "broken_dictionary_bytes_short.orc": "orc: byte 9: stripe 0's DICTIONARY_DATA stream of column 1, which starts at byte 9: the 2 entries of "
                                 "the dictionary of column \"d\" name 4 bytes and the stream holds 1",
    "broken_dictionary_index.orc": "orc: byte 9: stripe 0's DATA stream of column 1, which starts at byte 6: an index of 5 into the 2 "
                                 "entries of the dictionary of column \"d\"",
    "broken_dictionary_data_absent.orc": "orc: byte 3: stripe 0 lists no DICTIONARY_DATA stream for the 1 dictionary entry of column 1",
    "broken_dictionary_lengths_absent.orc": "orc: byte 3: stripe 0 lists no LENGTH stream for the 1 dictionary entry of column 1",
    "broken_patched_no_patch.orc": "orc: byte 6: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes hold a patched base "
                                 "run with no patch",
    "broken_patched_widths.orc": "orc: byte 3: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes hold a patched base "
                                 "run whose patch and gap widths pass 64 bits",
    "broken_patched_gap_end.orc": "orc: byte 11: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes hold a patch list "
                                 "that ends inside a gap",
    "broken_delta_one.orc": "orc: byte 3: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes hold a delta run of "
                                 "one value with a bit width",
    "broken_cut_packed.orc": "orc: byte 9: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes end inside a "
                                 "value",
    "broken_cut_short_repeat.orc": "orc: byte 6: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes end inside a "
                                 "value",
    "broken_cut_float.orc": "orc: byte 11: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes end inside a "
                                 "value",
    "broken_cut_byte_rle.orc": "orc: byte 6: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes end inside a "
                                 "value",
    "broken_cut_present.orc": "orc: byte 5: stripe 0's PRESENT stream of column 1, which starts at byte 3: the bytes end inside a "
                                 "value",
    "broken_cut_delta.orc": "orc: byte 5: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes end inside a "
                                 "value",
    "broken_cut_patched_base.orc": "orc: byte 7: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes end inside a "
                                 "value",
    "broken_cut_varint.orc": "orc: byte 6: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes end inside a "
                                 "value",
    "broken_cut_decimal.orc": "orc: byte 4: stripe 0's DATA stream of column 1, which starts at byte 3: the bytes end inside a "
                                 "value",
    "broken_nanoseconds.orc": "orc: byte 3: stripe 0: the SECONDARY stream of column 1 holds a nanosecond count past 64 bits",
    "broken_decimal_wider_payload.orc": "orc: column \"c0\" holds a decimal wider than 128 bits",
    "broken_decimal_wider_continued.orc": "orc: column \"c0\" holds a decimal wider than 128 bits",
    "broken_decimal_scale_out.orc": "orc: column \"c0\" holds a decimal of scale 7000, outside what the library's decimal holds",
    "broken_decimal_digits.orc": "orc: column \"c0\" holds a decimal of 5 digits at scale -30, which the library's decimal cannot hold "
                                 "exactly",
    "broken_decimal_quantum.orc": "orc: column \"c0\" holds a decimal of 1 digit at scale 6200, which the library's decimal cannot hold "
                                 "exactly",
    "broken_list_length_negative.orc": "orc: byte 13: stripe 0's LENGTH stream of column 1, which starts at byte 3: a list of column \"l\" has "
                                 "a length of -9223372036854775808",
    "broken_list_items_huge.orc": "orc: byte 3: the lists of column \"l\" name 2147483648 items in stripe 0, past what a column holds",
    "broken_list_densest.orc": "orc: byte 51: the lists of column \"l\" name 50000000 items in stripe 0, more than the densest "
                                 "encoding spells over its streams",
    "broken_stripe_densest.orc": "orc: byte 208: stripe 0 declares 100000 rows over 78 bytes of streams, more than the densest encoding "
                                 "spells",
    "broken_stripe_rows_frame.orc": "orc: byte 208: stripe 0 declares 2147483649 rows, past a frame's own height",
    "broken_footer_rows_frame.orc": "orc: byte 3538: the Footer declares 2400000000 rows, past a frame's own height",
    "broken_stream_past_stripe.orc": "orc: byte 209: stripe 0: stream 2 of column 2 runs past the stripe's end at byte 169",
    "broken_inflated_cut.orc": "orc: byte 3: of the inflated stripe 0's LENGTH stream of column 2, which starts at byte 99: the bytes "
                                 "end inside a value",
    "broken_stripe_index_long.orc": "orc: byte 208: stripe 0 runs past the body's end at byte 168",
    "broken_stripe_offset_absent.orc": "orc: byte 23: stripe 0 starts at byte 0, inside the magic",
    "broken_stripe_footer_absent.orc": "orc: byte 23: stripe 0's footer names 0 encodings for 2 types",
    "broken_string_bytes_huge.orc": "orc: byte 37: stripe 0's DATA stream of column 1, which starts at byte 37: the lengths of column \"s\" "
                                 "name 9223372036854775807 bytes and the stream holds 4",
    "broken_timestamp_far.orc": "orc: column \"c0\" holds a timestamp past the microseconds a 64-bit count holds",
    "broken_timestamp_high.orc": "orc: column \"c0\" holds a timestamp past the microseconds a 64-bit count holds",
    "broken_timestamp_low.orc": "orc: column \"c0\" holds a timestamp past the microseconds a 64-bit count holds",
    "broken_strings_data_absent_empty.orc": "orc: byte 3: stripe 0 lists no DATA stream for the 3 present values of column 1",
    "broken_dictionary_data_absent_empty.orc": "orc: byte 3: stripe 0 lists no DICTIONARY_DATA stream for the 2 dictionary entries of column 1",
    "broken_wire_varint_wide.orc": "orc: byte 65: the Footer: the bytes hold a varint wider than 64 bits",
    "broken_wire_tag_huge.orc": "orc: byte 54: the Footer holds a field tag past 32 bits",
    "broken_wire_field_zero.orc": "orc: byte 54: the Footer holds a field of number zero",
    "broken_wire_group.orc": "orc: byte 54: the Footer holds a field of wire type 3, a group",
    "broken_wire_count64.orc": "orc: byte 28: the Footer's stripe 0: an offset of 9223372036854775808, past what a 64-bit count "
                                 "holds",
    "broken_wire_count32.orc": "orc: byte 49: the Footer's type 1: a kind of 4294967296, past 32 bits",
    "broken_wire_varint_wire.orc": "orc: byte 55: the Footer: field 6 arrives in wire type 2",
    "broken_wire_packed_wire.orc": "orc: byte 63: the PostScript: field 4 arrives in wire type 1",
    "broken_wire_field_name.orc": "orc: byte 44: the Footer's type 0: a field name not well-formed as UTF-8",
    "broken_wire_subtypes_unrising.orc": "orc: byte 39: the Footer's type 0's subtypes do not rise",
    "broken_link_back.orc": "orc: byte 11: the Footer's type 0 names subtype 0, at or before itself",
    "broken_link_absent.orc": "orc: byte 11: the Footer's type 0 names subtype 5, which the Footer does not carry",
    "broken_wire_list_two.orc": "orc: byte 19: the Footer's type 1 is a LIST of 2 subtypes",
    "broken_wire_map_one.orc": "orc: byte 15: the Footer's type 1 is a MAP of 1 subtype",
    "broken_wire_leaf_subtypes.orc": "orc: byte 19: the Footer's type 1 names 2 subtypes, and a LONG has none",
    "broken_top_map.orc": "orc: the top-level type is MAP, where the columns are a STRUCT's fields",
    "broken_stripe_footer_encryption.orc": "orc: stripe 0's footer carries encrypted columns, which this reader does not read",
    "broken_encrypted_index.orc": "orc: stripe 0 carries an ENCRYPTED_INDEX stream: the spelling of encrypted columns, which this reader "
                                 "does not read",
    "broken_encodings_long.orc": "orc: byte 27: stripe 0's footer names 3 encodings for 2 types",
    "broken_block_zlib_undecompress.orc": "orc: byte 292: the Footer: a ZLIB block that does not decompress within 262144 bytes",
    "broken_block_snappy_undecompress.orc": "orc: byte 292: the Footer: a SNAPPY block that does not decompress within 262144 bytes",
    "broken_block_lz4_undecompress.orc": "orc: byte 292: the Footer: a LZ4 block that does not decompress within 262144 bytes",
    "broken_block_zstd_undecompress.orc": "orc: byte 292: the Footer: a ZSTD block that does not decompress within 262144 bytes",
    "broken_block_header_cut.orc": "orc: byte 440: the Footer: a block header cut short",
    "broken_block_no_bytes.orc": "orc: byte 292: the Footer: a block that declares no bytes",
    "broken_block_past_end.orc": "orc: byte 404: the Footer: a block of 332034 bytes runs past the end at byte 440",
    "broken_block_past_size.orc": "orc: byte 292: the Footer: a compressed block of 9 bytes, past the block size of 8",
}


def broken_items(base):
    """The files that hold together as files — a tail, a footer, a stripe
    — and break in one place each, which the codec refuses by exact text:
    the table under the corpus holds the text, and the test beside the
    package asserts it. The reference reader's own verdict on each is
    recorded in its sidecar: it refuses most of them too, reads some with
    other values or not at all, and the codec's refusal is its own where
    the two differ."""
    items = []

    def add(file, data, note, variant, why):
        origin = "synthetic" if note.startswith("derived from") else "hand-built"
        items.append((file, data, origin, note, (variant, why, TEXTS.get(file)), None, None))

    one = E.int_values(E.LONG, [1, 2, 3])
    add("broken_version_13.orc", E.build_file([one], 3, version=(0, 13)),
        "the PostScript names format version 0.13", "Unsupported", "a format version this reader does not read")
    add("broken_postscript_huge.orc", E.build_file([one], 3)[:-1] + b"\xff",
        "the PostScript length byte names 255 bytes of a file of 72", "ParseError", "the PostScript past the head")
    add("broken_version_three.orc", E.build_file([one], 3, version=(0, 12, 1)),
        "the PostScript names three version numbers", "Unsupported", "a format version this reader does not read")
    struct = E.struct_col([E.int_values(E.LONG, [1, 2])], ["a"], encoding=E.DIRECT_V2)
    add("broken_struct_encoding.orc", E.build_file([struct], 2, names=["st"]),
        "a struct column under DIRECT_V2, where the format spells DIRECT", "Unsupported", "a struct under another encoding")
    add("broken_utf8.orc", E.build_file([E.string_col(["\ufffd"], data=b"\xff\xfe\xfd")], 1, names=["s"]),
        "a string's bytes not well-formed as UTF-8", "ParseError", "a string not UTF-8")
    add("broken_string_length_negative.orc", E.build_file([
        E.string_col(["abc"], lengths=E.rle2_direct_unsigned([2 ** 63], width=64), data=b"abc")], 1, names=["s"]),
        "a string's length with its top bit set", "ParseError", "a negative string length")
    add("broken_string_bytes_short.orc", E.build_file([E.string_col(["abc"], lengths=E.unsigned([10]))], 1, names=["s"]),
        "the lengths name ten bytes and the data stream holds three", "ParseError", "a string's bytes short")
    add("broken_string_data_absent.orc", E.build_file([E.Column(E.STRING, streams=[(E.LENGTH, E.unsigned([3]))])], 1, names=["s"]),
        "a length of three and no data stream", "ParseError", "a data stream absent")
    add("broken_dictionary_size.orc", E.build_file([E.dictionary_col(["a"], [0], dictionary_size=2 ** 31)], 1, names=["d"]),
        "the encoding names 2^31 dictionary entries", "ParseError", "a dictionary count past a column")
    short = E.dictionary_col(["ab", "cd"], [0])
    short.streams[2] = (E.DICT_DATA, b"a")
    add("broken_dictionary_bytes_short.orc", E.build_file([short], 1, names=["d"]),
        "the dictionary's lengths name four bytes and its stream holds one", "ParseError", "a dictionary's bytes short")
    add("broken_dictionary_index.orc", E.build_file([E.dictionary_col(["a", "b"], [5])], 1, names=["d"]),
        "an index of five into two entries", "ParseError", "a dictionary index past its entries")
    add("broken_dictionary_data_absent.orc", E.build_file([E.Column(
        E.STRING, E.encoding_msg(E.DICTIONARY_V2, 1), [(E.LENGTH, E.unsigned([3])), (E.DATA, E.rle2_unsigned([0]))])], 1, names=["d"]),
        "a dictionary of three bytes and no dictionary data stream", "ParseError", "a dictionary data stream absent")
    add("broken_dictionary_lengths_absent.orc", E.build_file([E.Column(
        E.STRING, E.encoding_msg(E.DICTIONARY_V2, 1), [(E.DATA, E.rle2_unsigned([0])), (E.DICT_DATA, b"abc")])], 1, names=["d"]),
        "a dictionary and no length stream", "ParseError", "a dictionary's length stream absent")
    add("broken_patched_no_patch.orc", E.build_file([E.int_col(E.LONG, bytes([0x82, 0x04, 0x21, 0x40, 0x07]))], 5),
        "a patched base run whose patch list is empty", "ParseError", "a patched base run with no patch")
    add("broken_patched_widths.orc", E.build_file([E.int_col(E.LONG, bytes([0x82, 0x04, 0x1F, 0xE1]))], 5),
        "a patched base run whose patch and gap widths pass 64 bits", "ParseError", "patched base widths past 64 bits")
    add("broken_patched_gap_end.orc", E.build_file([E.int_col(E.LONG, bytes([0x80, 0x04, 0x00, 0xE1, 0x00, 0x00, 0xFF, 0x00]))], 5),
        "a patch list of one skip entry, which ends inside its gap", "ParseError", "a patch list that ends inside a gap")
    add("broken_delta_one.orc", E.build_file([E.int_col(E.LONG, bytes([0xC6, 0x00, 0x02, 0x02]))], 1),
        "a delta run of one value with a bit width", "ParseError", "a delta run of one value")
    add("broken_cut_packed.orc", E.build_file([E.int_col(E.LONG, E.rle2_direct(list(range(1, 11)))[:-3])], 10),
        "a direct run of ten values with three bytes cut", "ParseError", "a stream ending inside a value")
    add("broken_cut_short_repeat.orc", E.build_file([E.int_col(E.LONG, E.rle2_short_repeat(7, 5) + b"\x10\x00\x07")], 8),
        "a short repeat of a three-byte value with one byte cut", "ParseError", "a stream ending inside a value")
    add("broken_cut_float.orc", E.build_file([E.Column(E.DOUBLE, streams=[(E.DATA, E.doubles([1.0]) + b"\x00\x01\x02\x03\x04")])], 2),
        "two doubles and five bytes of the second", "ParseError", "a stream ending inside a value")
    add("broken_cut_byte_rle.orc", E.build_file([E.Column(E.BYTE, streams=[(E.DATA, b"\x80\x01\x02")])], 128),
        "a byte run of 128 literals and two bytes", "ParseError", "a stream ending inside a value")
    add("broken_cut_present.orc", E.build_file([E.Column(
        E.LONG, streams=[(E.PRESENT, b"\xf0\xff"), (E.DATA, E.rle2([1] * 128))])], 128),
        "a present stream of 16 literal bytes and one", "ParseError", "a stream ending inside a value")
    add("broken_cut_delta.orc", E.build_file([E.int_col(E.LONG, E.rle2_delta(list(range(1, 9)))[:-2])], 8),
        "a delta run with its last steps cut", "ParseError", "a stream ending inside a value")
    add("broken_cut_patched_base.orc", E.build_file([E.int_col(E.LONG, bytes([0x83, 0x00, 0x60, 0x21, 0x01]))], 5),
        "a patched base run whose base is cut", "ParseError", "a stream ending inside a value")
    add("broken_cut_varint.orc", E.build_file([E.int_col(E.LONG, bytes([0xC1, 0x01, 0x80]))], 2),
        "a delta run whose first value's varint is cut", "ParseError", "a stream ending inside a value")
    add("broken_cut_decimal.orc", E.build_file([E.Column(
        E.DECIMAL, streams=[(E.DATA, b"\x80"), (E.SECONDARY, E.rle2([2]))], precision=10, scale=2)], 1),
        "a decimal's varint cut after its first byte", "ParseError", "a stream ending inside a value")
    nanos = E.timestamp_col([1], [5])
    nanos.streams[1] = (E.SECONDARY, E.rle2_direct_unsigned([(2 ** 60) << 3 | 7], width=64))
    add("broken_nanoseconds.orc", E.build_file([nanos], 1),
        "a nanosecond count that scales past 64 bits", "ParseError", "a nanosecond count past 64 bits")
    add("broken_decimal_wider_payload.orc", E.build_file([E.Column(
        E.DECIMAL, streams=[(E.DATA, b"\xff" * 18 + b"\x04"), (E.SECONDARY, E.rle2([2]))], precision=10, scale=2)], 1),
        "a decimal's varint of 19 bytes whose last carries more than two bits", "Unsupported", "a decimal wider than 128 bits")
    add("broken_decimal_wider_continued.orc", E.build_file([E.Column(
        E.DECIMAL, streams=[(E.DATA, b"\xff" * 18 + b"\x82"), (E.SECONDARY, E.rle2([2]))], precision=10, scale=2)], 1),
        "a decimal's varint of 19 bytes that does not end", "Unsupported", "a decimal wider than 128 bits")
    add("broken_decimal_scale_out.orc", E.build_file([E.decimal_col([1], 7000)], 1),
        "a decimal at scale 7000", "Unsupported", "a decimal scale outside the library's")
    add("broken_decimal_digits.orc", E.build_file([E.decimal_col([12345], 0, scales=[-30])], 1),
        "five digits at a scale of -30 in the scale stream, which scales them past 34", "Unsupported",
        "a decimal past 34 digits at its scale")
    add("broken_decimal_quantum.orc", E.build_file([E.decimal_col([10 ** 20], 6200)], 1),
        "a value whose zeros under a scale of 6200 pass the library's smallest quantum", "Unsupported",
        "a decimal past the library's smallest quantum")
    negative = E.Column(E.LIST, streams=[(E.LENGTH, E.rle2_direct_unsigned([2 ** 63], width=64))],
                        children=[E.int_values(E.LONG, [1])])
    add("broken_list_length_negative.orc", E.build_file([negative], 1, names=["l"]),
        "a list's length with its top bit set", "ParseError", "a negative list length")
    huge = E.list_col([2 ** 31 - 1, 5], E.int_values(E.LONG, [1]))
    add("broken_list_items_huge.orc", E.build_file([huge], 2, names=["l"]),
        "two lists naming 2^31 + 4 items", "ParseError", "list items past a column")
    add("broken_list_densest.orc", E.build_file([E.list_col([10 ** 7] * 5, E.int_values(E.LONG, [1]))], 5, names=["l"]),
        "five lists of ten million items over a few bytes of stream", "ParseError", "list items past the densest encoding")
    add("broken_stripe_densest.orc",
        patch_footer(patch_stripe(base, 0, rows=100000), lambda footer: O.set_varints(footer, {6: 100000})),
        "derived from pyorc_small_uncompressed.orc: the stripe declares 100,000 rows over its 78 bytes of streams, "
        "more than the densest encoding spells over them",
        "ParseError", "rows past the densest encoding")
    add("broken_stripe_rows_frame.orc",
        patch_footer(patch_stripe(base, 0, rows=2 ** 31 + 1), lambda footer: O.set_varints(footer, {6: 2 ** 31 + 1})),
        "derived from pyorc_small_uncompressed.orc: the stripe declares 2^31 + 1 rows", "ParseError", "stripe rows past a frame")
    striped = write(table_stripes(), stripe_size=512, row_index_stride=8, batch_size=10, dictionary_key_size_threshold=0.8)
    add("broken_footer_rows_frame.orc",
        patch_footer(patch_stripe(striped, None, rows=400000000), lambda footer: O.set_varints(footer, {6: 2400000000})),
        "derived from pyorc_stripes.orc: six stripes of 400,000,000 rows and a footer that agrees",
        "ParseError", "footer rows past a frame")
    add("broken_stream_past_stripe.orc", lengthen_stream(base, 2, 400),
        "derived from pyorc_small_uncompressed.orc: the string column's first stream names 400 bytes past the stripe",
        "ParseError", "a stream past its stripe")
    add("broken_inflated_cut.orc", cut_blocks(lengthen_stream(base, 2, -2), 9, codec="zlib", mix=True),
        "derived from pyorc_small_uncompressed.orc: the string column's PRESENT stream cut by two bytes, the "
        "file under ZLIB in blocks of at most 9 bytes", "ParseError", "an inflated stream ending inside a value")

    def stripe_without(data, *nums):
        """The file with the fields `nums` dropped from every stripe's information."""
        def enc(n, w, v):
            if n != 3:
                return O.keep(n, w, v)
            for num in nums:
                v = O.drop_field(v, num)
            return O.f_bytes(3, v)

        return patch_footer(data, lambda footer: O.rebuild(footer, enc))

    add("broken_stripe_index_long.orc", patch_stripe(base, 0, index_length=400),
        "derived from pyorc_small_uncompressed.orc: the stripe's index names 400 bytes past the body",
        "ParseError", "a stripe past the body")
    add("broken_stripe_offset_absent.orc", stripe_without(E.build_file([one], 3), 1),
        "a stripe's information with no offset, which reads as byte 0, inside the magic", "ParseError",
        "a stripe starting before the body")
    add("broken_stripe_footer_absent.orc", stripe_without(E.build_file([one], 3), 4),
        "a stripe's information with no footer length, an empty stripe footer", "ParseError",
        "the encodings do not match the types")
    add("broken_string_bytes_huge.orc", E.build_file([
        E.string_col(["a", "b", "c", "d"], lengths=E.rle2_direct_unsigned([2 ** 62] * 4, width=64), data=b"abcd")],
        4, names=["s"]),
        "lengths naming 2^62 bytes four times over, past what a count holds", "ParseError", "a string's bytes short")
    add("broken_timestamp_far.orc", E.build_file([E.Column(E.TIMESTAMP, streams=[
        (E.DATA, E.rle2_direct([9223372036855 - E.ORC_EPOCH + 1], width=64)), (E.SECONDARY, E.unsigned([0]))])], 1),
        "a whole second past what a 64-bit microsecond count holds", "Unsupported", "a timestamp past a 64-bit microsecond count")
    for edge, second in (("high", 2 ** 63 - 1), ("low", -(2 ** 63))):
        add("broken_timestamp_%s.orc" % edge, E.build_file([E.Column(E.TIMESTAMP, streams=[
            (E.DATA, E.rle2_direct([second], width=64)), (E.SECONDARY, E.unsigned([0]))])], 1),
            "seconds after 2015-01-01 at the %s end of a 64-bit count" % edge, "Unsupported",
            "a timestamp past a 64-bit microsecond count")
    add("broken_strings_data_absent_empty.orc", E.build_file([
        E.Column(E.STRING, streams=[(E.LENGTH, E.unsigned([0, 0, 0]))])], 3, names=["s"]),
        "lengths of zero for three strings and no data stream, which every writer lists", "ParseError",
        "a data stream absent")
    add("broken_dictionary_data_absent_empty.orc", E.build_file([E.Column(
        E.STRING, E.encoding_msg(E.DICTIONARY_V2, 2),
        streams=[(E.LENGTH, E.unsigned([0, 0])), (E.DATA, E.rle2_unsigned([0, 1, 1]))])], 3, names=["d"]),
        "a dictionary of two empty strings and no dictionary data stream, which every writer lists", "ParseError",
        "a dictionary data stream absent")
    add("broken_wire_varint_wide.orc", E.build_file([one], 3, footer_extra=b"\x30" + b"\xff" * 9 + b"\x02"),
        "a footer field whose varint has ten bytes and a tenth past one", "ParseError", "a varint wider than 64 bits")
    add("broken_wire_tag_huge.orc", E.build_file([one], 3, footer_extra=b"\xff\xff\xff\xff\x1f\x00"),
        "a footer field tag past 32 bits", "ParseError", "a field tag past 32 bits")
    add("broken_wire_field_zero.orc", E.build_file([one], 3, footer_extra=b"\x00\x00"),
        "a footer field of number zero", "ParseError", "a field of number zero")
    add("broken_wire_group.orc", E.build_file([one], 3, footer_extra=b"\x0b\x00"),
        "a footer field of the group wire type", "ParseError", "a group wire type")
    add("broken_wire_count64.orc", patch_stripe(E.build_file([one], 3), 0, offset=2 ** 63),
        "a stripe whose offset is 2^63", "ParseError", "a count past 64 bits")
    add("broken_wire_count32.orc", retype(E.build_file([one], 3), 1, 2 ** 32),
        "a type of kind 2^32", "ParseError", "a count past 32 bits")
    add("broken_wire_varint_wire.orc", E.build_file([one], 3, footer_extra=b"\x32\x01\x05"),
        "the footer's row count as a length-delimited field", "ParseError", "a field in the wrong wire type")
    add("broken_wire_packed_wire.orc", E.build_file([one], 3, ps_extra=O.tag(4, 1) + b"\x00" * 8),
        "the PostScript's version as a fixed-width field", "ParseError", "a field in the wrong wire type")
    root = O.f_varint(1, E.STRUCT) + O.f_packed(2, [1]) + O.f_bytes(3, b"\xff")
    add("broken_wire_field_name.orc", E.build_file([one], 3, root=root),
        "a struct's field name not well-formed as UTF-8", "ParseError", "a field name not UTF-8")
    add("broken_wire_subtypes_unrising.orc", E.build_file(
        [E.int_values(E.LONG, [1, 2, 3]), E.int_values(E.LONG, [1, 2, 3])], 3,
        root=E.type_msg(E.STRUCT, [2, 1], ["a", "b"])),
        "the root struct's subtypes falling", "ParseError", "subtypes that do not rise")
    add("broken_link_back.orc", E.build_file([], 0, types=[
        E.type_msg(E.STRUCT, [0, 1], ["a", "b"]), E.type_msg(E.LONG)],
        encodings=[E.encoding_msg(E.DIRECT)] * 2, streams=[]),
        "the root struct names itself for a subtype", "ParseError", "a subtype at or before itself")
    add("broken_link_absent.orc", E.build_file([], 0, types=[
        E.type_msg(E.STRUCT, [1, 5], ["a", "b"]), E.type_msg(E.LONG)],
        encodings=[E.encoding_msg(E.DIRECT)] * 2, streams=[]),
        "the root struct names a subtype the footer does not carry", "ParseError", "a subtype the footer does not carry")
    add("broken_wire_list_two.orc", E.build_file([], 3, types=[
        E.type_msg(E.STRUCT, [1], ["l"]), E.type_msg(E.LIST, [2, 3]), E.type_msg(E.LONG), E.type_msg(E.LONG)],
        encodings=[E.encoding_msg(E.DIRECT)] * 4, streams=[]),
        "a list of two subtypes", "ParseError", "a list of two subtypes")
    add("broken_wire_map_one.orc", E.build_file([], 3, types=[
        E.type_msg(E.STRUCT, [1], ["m"]), E.type_msg(E.MAP, [2]), E.type_msg(E.LONG)],
        encodings=[E.encoding_msg(E.DIRECT)] * 3, streams=[]),
        "a map of one subtype", "ParseError", "a map of one subtype")
    add("broken_wire_leaf_subtypes.orc", E.build_file([], 3, types=[
        E.type_msg(E.STRUCT, [1], ["n"]), E.type_msg(E.LONG, [2, 3]), E.type_msg(E.LONG), E.type_msg(E.LONG)],
        encodings=[E.encoding_msg(E.DIRECT)] * 4, streams=[]),
        "a long of two subtypes", "ParseError", "a leaf with subtypes")
    add("broken_top_map.orc", E.build_file([], 0, types=[E.type_msg(E.MAP, [1, 2]), E.type_msg(E.STRING), E.type_msg(E.LONG)],
                                            encodings=[E.encoding_msg(E.DIRECT)] * 3, streams=[]),
        "the top-level type is a MAP", "Unsupported", "the top-level type is not a struct")
    add("broken_stripe_footer_encryption.orc", E.build_file([one], 3, stripe_footer_extra=O.f_bytes(4, b"")),
        "the stripe footer carries an encryption field", "Unsupported", "encrypted columns")
    add("broken_encrypted_index.orc", E.build_file([one], 3, extra_streams=[(E.ENCRYPTED_INDEX, 0, b"")]),
        "an ENCRYPTED_INDEX stream", "Unsupported", "encrypted columns")
    add("broken_encodings_long.orc", E.build_file([one], 3, encodings=[E.encoding_msg(E.DIRECT)] * 3),
        "the stripe footer names three encodings for two types", "ParseError", "the encodings do not match the types")
    return items


def block_items(base):
    """The compression block reader's refusals, one file each: a file under
    each codec whose footer opens with a block that will not decompress,
    and one under ZLIB per broken header."""
    items = []

    def add(file, data, note, variant, why):
        items.append((file, data, "synthetic", "derived from pyorc_small_uncompressed.orc: " + note,
                      (variant, why, TEXTS.get(file)), None, None))

    def first_block(maker):
        return lambda part, index, blocks: ([maker(blocks[0][3:])] + blocks[1:]) if part == "footer" else blocks

    for codec in ("zlib", "snappy", "lz4", "zstd"):
        add("broken_block_%s_undecompress.orc" % codec,
            cut_blocks(base, 9, codec=codec, pack=False, alter=first_block(lambda payload: O.block_header(8, False) + b"\xff" * 8)),
            "%s, the footer's first block claiming eight compressed bytes that are all ones" % codec.upper(),
            "ParseError", "a block that does not decompress")
    add("broken_block_header_cut.orc",
        cut_blocks(base, 9, pack=False, alter=lambda part, index, blocks: blocks + [b"\x00\x00"] if part == "footer" else blocks),
        "ZLIB, two stray bytes after the footer's last block", "ParseError", "a block header cut short")
    add("broken_block_no_bytes.orc", cut_blocks(base, 9, pack=False, alter=first_block(lambda payload: O.block_header(0, True))),
        "ZLIB, the footer's first block declaring no bytes", "ParseError", "a block that declares no bytes")
    add("broken_block_past_end.orc", cut_blocks(base, 9, pack=False, alter=first_block(
        lambda payload: O.block_header(len(payload) + 100, True) + payload)),
        "ZLIB, the footer's first block naming a hundred bytes past its end", "ParseError", "a block past the end")
    add("broken_block_past_size.orc", cut_blocks(base, 9, pack=False, block_size=8, alter=first_block(
        lambda payload: O.block_header(9, False) + b"\xff" * 9)),
        "ZLIB, a block size of eight and the footer's first block compressed into nine", "ParseError", "a block past the block size")
    return items


# ── the sidecar ─────────────────────────────────────────────────────

def dumps(entry):
    """A sidecar as JSON, a column to a line and its cells compact, so
    that a file of thousands of cells stays a text a person can scan."""
    lines = ["{"]
    items = list(entry.items())
    for k, (key, value) in enumerate(items):
        comma = "," if k < len(items) - 1 else ""
        if key != "views":
            lines.append(" " + json.dumps(key) + ": " + json.dumps(value, ensure_ascii=False) + comma)
            continue
        lines.append(' "views": [')
        for vi, view in enumerate(value):
            head = {c: v for c, v in view.items() if c != "columns"}
            lines.append("  " + json.dumps(head, ensure_ascii=False)[:-1] + ', "columns": [')
            for ci, column in enumerate(view["columns"]):
                last_c = ci == len(view["columns"]) - 1
                cells = ",".join(json.dumps(c, ensure_ascii=False) for c in column["cells"])
                head_c = {c: v for c, v in column.items() if c != "cells"}
                lines.append("   " + json.dumps(head_c, ensure_ascii=False)[:-1] + ', "cells": [' + cells + "]}"
                             + ("" if last_c else ","))
            lines.append("  ]}" + ("," if vi < len(value) - 1 else ""))
        lines.append(" ]" + comma)
    lines.append("}")
    return "\n".join(lines) + "\n"


def sidecar(data, file, origin, note, refuse, views, own=None):
    """One file's sidecar: what it holds, the cells of every view and,
    where the codec refuses the file, the exact text of its refusal. A
    file whose layout does not even hold together for this script's own
    reading has a refusal and no view: the cells of a view come from the
    reference reader, and a type it cannot carry is refused by the codec.
    Where the reference reader cannot hold a value — the instants at the
    ends of a 64-bit microsecond count, which its nanosecond cell
    overflows on — or answers others than the codec does, the view's cells
    are the generator's own, spelled from the values it wrote, its
    `source` says so, and what the reference reader gave is recorded."""
    if refuse is not None and refuse[2] is None and not DRAFT:
        raise SystemExit("%s: no exact text for the codec's refusal in TEXTS" % file)
    try:
        f = O.File(data)
    except Exception as e:  # noqa
        # this script's own reading may fail on a broken file too, and
        # anything may be the failure; a sound one must read
        if refuse is None or views:
            raise SystemExit("%s: the layout does not hold together (%s: %s) and the plan neither names a refusal "
                             "nor drops the views" % (file, type(e).__name__, e))
        f = None
    entry = {"file": file, "origin": origin, "note": note, "bytes": len(data)}
    if f is not None:
        entry["compression"] = O.COMPRESSION.get(f.compression, f.compression)
        # the version's numbers; a field of another wire type is no number
        entry["version"] = [v for v in f.version if isinstance(v, int)]
        if isinstance(f.rows, int):
            entry["rows"] = f.rows
        entry["stripes"] = len(f.stripes)
        entry["fields"] = len(f.types[0].subtypes) if f.types else 0
        if refuse is None and not carried(f, None):
            raise SystemExit("%s: a type the codec refuses, and the plan names no refusal" % file)
    if refuse is not None:
        entry["codec"] = "refuses"
        entry["refusal"] = refuse[0]
        entry["why"] = refuse[1]
        entry["message"] = refuse[2]
    else:
        entry["codec"] = "reads"
    if file.startswith("broken_"):
        # a file built to be broken: the reference reader meets it in a
        # process of its own, and gives no view
        if views:
            raise SystemExit("%s: a broken file has no view" % file)
        summary = reference_summary(data)
        entry["reference_isolated"] = True
        entry["reference_opens"] = summary["opens"]
        if not summary["opens"]:
            entry["reference_error"] = summary["error"]
        else:
            entry["reference_rows"] = summary["rows"]
            entry["reference_columns"] = summary["columns"]
        entry["views"] = []
        entry["cells"] = 0
        return entry, 0
    table, error = reference_table(data, None)
    entry["reference_opens"] = error is None
    if error is not None:
        entry["reference_error"] = error
    else:
        entry["reference_rows"] = table.num_rows
        entry["reference_columns"] = ["%s: %s" % (table.schema.field(i).name, table.schema.field(i).type)
                                      for i in range(table.num_columns)]
    compared = 0
    wide = 0
    entry["views"] = []
    for projection in views:
        if not carried(f, projection):
            raise SystemExit("%s: the view %r carries a type the codec refuses" % (file, projection))
        wanted = [(n, s) for n, s in zip(f.types[0].names, f.types[0].subtypes) if projection is None or n in projection]
        table, error = reference_table(data, projection)
        columns = []
        if own is not None:
            # the cells are the generator's own, spelled from the values it
            # wrote: the reference reader cannot hold them, or answers
            # others — which is recorded for `verify` to find unchanged
            if projection is not None or list(own) != [n for n, _ in wanted]:
                raise SystemExit("%s: the generator's own cells must name the file's columns in order" % file)
            for name, (n, s) in zip(own, wanted):
                if len(own[name]) != f.rows:
                    raise SystemExit("%s: the generator spells %d cells of %s, the file %d rows"
                                     % (file, len(own[name]), name, f.rows))
                columns.append({"name": n, "dtype": dtype_of(f, s), "cells": own[name]})
                compared += len(own[name])
            view = {"projection": projection, "source": "generator", "reference_opens": error is None,
                    "columns": columns}
            if error is None:
                if table.schema.names != [n for n, _ in wanted]:
                    raise SystemExit("%s: the reference reader names the view %r %r, the file %r" % (
                        file, projection, table.schema.names, [n for n, _ in wanted]))
                try:
                    view["reference_cells"] = {name: cells_of(table.column(i).combine_chunks())
                                               for i, name in enumerate(table.schema.names)}
                except ValueError as e:
                    view["reference_error"] = "the reader cannot hold the values: %s" % e
            entry["views"].append(view)
            continue
        if error is not None:
            raise SystemExit("%s: the reference reader does not open the view %r: %s" % (file, projection, error))
        if [table.schema.field(i).name for i in range(table.num_columns)] != [n for n, _ in wanted]:
            raise SystemExit("%s: the reference reader names the view %r %r, the file %r" % (
                file, projection, table.schema.names, [n for n, _ in wanted]))
        for i in range(table.num_columns):
            arr = table.column(i).combine_chunks()
            try:
                cells = cells_of(arr)
            except ValueError as e:
                raise SystemExit("%s: the view %r holds %s, and the plan names no refusal" % (file, projection, e))
            if len(cells) != table.num_rows:
                raise SystemExit("%s: %d cells for %d rows" % (file, len(cells), table.num_rows))
            dtype = dtype_of(f, wanted[i][1])
            if dtype == "Decimal":
                count = wide_decimals(cells)
                if count and refuse is None:
                    raise SystemExit("%s: %s holds a decimal past 34 significant digits, and the plan names no refusal"
                                     % (file, arr.type))
                wide += count
            columns.append({"name": table.schema.field(i).name, "dtype": dtype, "cells": cells})
            compared += len(cells)
        entry["views"].append({"projection": projection, "columns": columns})
    entry["cells"] = compared
    if wide:
        entry["reference_wide_decimals"] = wide
    return entry, compared


# ── the replacement sweep, as the reference reader answers it ─────────

SWEEP_SEED = 0x4F52433230323636
SWEEP_CASES = 200
SWEEP_FILES = ["pyorc_small_uncompressed.orc", "pyorc_small_zlib.orc", "pyorc_small_snappy.orc",
               "pyorc_small_lz4.orc", "pyorc_small_zstd.orc"]
MASK64 = 2 ** 64 - 1


def splitmix64(state):
    """The next number of the codec's sweep generator (splitmix64) from
    `state`, and the state after it."""
    state = (state + 0x9E3779B97F4A7C15) & MASK64
    z = ((state ^ (state >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
    return z ^ (z >> 31), state


def sweep_cases(data):
    """The codec's replacement sweep over `data`, replayed: the offset and
    the value of every one of its 200 single-byte replacements, drawn as
    its generator draws them from the named seed."""
    state, out = SWEEP_SEED, []
    for _ in range(SWEEP_CASES):
        drawn, state = splitmix64(state)
        at = drawn % len(data)
        drawn, state = splitmix64(state)
        value = (drawn >> 8) & 0xFF
        if value == data[at]:
            value ^= 0xFF
        out.append((at, value))
    return out


def sweep_read():
    """The reference reader's answer to every file of the replacement
    sweep: a dict of `file.case` to what it did — opened the file and gave
    the cells, refused it with an error, or crashed on it. The mutated
    files are written to a directory of their own, and the reader meets
    them in a process of its own, resumed after every crash."""
    directory = tempfile.mkdtemp(prefix="orc_sweep_")
    order, cases = [], {}
    try:
        for name in SWEEP_FILES:
            with open(os.path.join(FIX, name), "rb") as f:
                data = f.read()
            for case, (at, value) in enumerate(sweep_cases(data)):
                key = "%s.%d" % (name, case)
                cases[key] = (name, at, value)
                order.append(key)
                with open(os.path.join(directory, key + ".orc"), "wb") as f:
                    f.write(data[:at] + bytes([value]) + data[at + 1:])
        with open(os.path.join(directory, "order.json"), "w", encoding="utf-8") as f:
            json.dump(order, f)
        answers, start, barren = {}, 0, 0
        while start < len(order):
            run = subprocess.run(
                [sys.executable, "-I", "-X", "utf8", os.path.join(HERE, "reference_sweep.py"), directory, str(start)],
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1800)
            before = len(answers)
            for line in run.stdout.splitlines():
                if line.startswith("{"):
                    answer = json.loads(line)
                    answers[answer["key"]] = answer
            if run.returncode == 0:
                break
            # a reader that answers nothing before it dies is broken, not
            # crashed on a file
            barren = barren + 1 if len(answers) == before else 0
            if barren >= 3:
                raise SystemExit("the reference reader's sweep process fails to start: %s" % (run.stderr or "")[-400:])
            crashed = order[len(answers)]
            # the verdict is the crash; its exit code and message are not
            # recorded, so the corpus reads the same from run to run
            answers[crashed] = {"key": crashed, "opens": False, "error": "the reader crashed"}
            start = order.index(crashed) + 1
        log("  the replacement sweep: %d cases; the reference reader opens %d, refuses %d, crashes on %d" % (
            len(order), sum(1 for a in answers.values() if a["opens"]),
            sum(1 for a in answers.values() if not a["opens"] and a["error"] != "the reader crashed"),
            sum(1 for a in answers.values() if not a["opens"] and a["error"] == "the reader crashed")))
    finally:
        shutil.rmtree(directory, ignore_errors=True)
    return cases, answers


def sweep_json(cases, answers):
    """The sweep's answers as the corpus records them: a file's cases with
    their offsets and values, and what the reference reader gave."""
    files = {}
    for key, (name, at, value) in cases.items():
        answer = answers[key]
        case = {"at": at, "value": value, "reference_opens": answer["opens"]}
        if answer["opens"]:
            case["cells"] = answer["cells"]
        else:
            case["reference_error"] = answer["error"]
        files.setdefault(name, []).append(case)
    return {"seed": "0x%016X" % SWEEP_SEED, "note": "the codec's replacement sweep over the small files, one byte replaced "
            "in 200 copies of each, with the cells the reference reader gave the copy or its error",
            "files": files}


# ── make and verify ─────────────────────────────────────────────────

def make():
    """Write the corpus under ``fixtures/reference``: every file, its
    sidecar and the index."""
    os.makedirs(FIX, exist_ok=True)
    os.makedirs(LOG, exist_ok=True)
    for name in os.listdir(FIX):
        os.remove(os.path.join(FIX, name))
    if ensure_tzdir() is None:
        raise SystemExit("no IANA time zone database: run with --with tzdata")
    index = []
    cells = 0
    log("pyarrow %s; python %s; TZDIR %s" % (pa.__version__, sys.version.split()[0], os.environ.get("TZDIR")))
    for file, data, origin, note, refuse, views, own in corpus():
        path = os.path.join(FIX, file)
        default_views = [] if refuse is not None else [None]
        entry, compared = sidecar(data, file, origin, note, refuse, views if views is not None else default_views, own)
        with open(path, "wb") as f:
            f.write(data)
        text = dumps(entry)
        with open(path + ".json", "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        item = {"file": file, "origin": origin, "codec": entry["codec"], "reference_opens": entry["reference_opens"]}
        if "refusal" in entry:
            item["refusal"] = entry["refusal"]
        if "rows" in entry:
            item["rows"] = entry["rows"]
        item["cells"] = compared
        index.append(item)
        cells += compared
        log("  %-56s %6d bytes, sidecar %6d; %s; %d view%s, %d cells%s" % (
            file, len(data), len(text),
            "the codec refuses it (%s: %s)" % (refuse[0], refuse[1]) if refuse else "reads",
            len(entry["views"]), "" if len(entry["views"]) == 1 else "s", compared,
            "" if entry["reference_opens"] else "; the reference reader refuses it too"))
    with open(os.path.join(FIX, "index.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)
        f.write("\n")
    # the reference reader's answer to the codec's replacement sweep
    cases, answers = sweep_read()
    with open(os.path.join(FIX, "sweep.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(sweep_json(cases, answers), f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")
    sizes = {}
    for item in index:
        data_bytes = os.path.getsize(os.path.join(FIX, item["file"]))
        car_bytes = os.path.getsize(os.path.join(FIX, item["file"] + ".json"))
        by = sizes.setdefault(item["origin"], [0, 0, 0, 0])
        by[0] += 1
        by[1] += data_bytes
        by[2] += car_bytes
        by[3] += item["cells"]
    total = sum(os.path.getsize(os.path.join(FIX, n)) for n in os.listdir(FIX))
    for origin, (n, d, c, k) in sorted(sizes.items()):
        log("  %-20s %3d files: %7d bytes of data, %7d of sidecars, %6d cells" % (origin, n, d, c, k))
    log("the corpus: %d files, %d cells, %d bytes in all (the index among them), under %s"
        % (len(index), cells, total, FIX))
    log("the codec reads %d files and refuses %d; the reference reader opens %d of them unprojected and refuses %d" % (
        sum(1 for e in index if e["codec"] == "reads"), sum(1 for e in index if e["codec"] == "refuses"),
        sum(1 for e in index if e["reference_opens"]), sum(1 for e in index if not e["reference_opens"])))
    return 0


def verify():
    """Compare every view of every file with what the reference reader
    returns; exit non-zero on a mismatch."""
    if ensure_tzdir() is None:
        raise SystemExit("no IANA time zone database: run with --with tzdata")
    with open(os.path.join(FIX, "index.json"), encoding="utf-8") as f:
        index = json.load(f)
    stats = {"files": 0, "refused": 0, "views": 0, "cells": 0, "agreed": 0, "mismatch": 0, "opens": 0, "cannot_open": 0, "own": 0}

    def problem(text):
        log("MISMATCH " + text)
        stats["mismatch"] += 1

    for item in index:
        path = os.path.join(FIX, item["file"])
        with open(path, "rb") as f:
            data = f.read()
        with open(path + ".json", encoding="utf-8") as f:
            car = json.load(f)
        stats["files"] += 1
        if car["codec"] == "refuses":
            stats["refused"] += 1
        if car.get("reference_isolated"):
            # the reference reader met this file in a process of its own:
            # its verdict must be the one the sidecar records
            summary = reference_summary(data)
            if summary["opens"] != car["reference_opens"]:
                problem("%s: reference_opens is %s in the sidecar, and the reader %s it now" % (
                    item["file"], car["reference_opens"], "opens" if summary["opens"] else "refuses"))
            stats["opens" if summary["opens"] else "cannot_open"] += 1
            continue
        table, error = reference_table(data, None)
        if (error is None) != car["reference_opens"]:
            problem("%s: reference_opens is %s in the sidecar, and the reader %s it now" % (
                item["file"], car["reference_opens"], "opens" if error is None else "refuses"))
        if error is not None:
            stats["cannot_open"] += 1
        else:
            stats["opens"] += 1
        for view in car["views"]:
            stats["views"] += 1
            table, error = reference_table(data, view["projection"])
            if view.get("source") == "generator":
                # the cells are the generator's own: the reference reader
                # must answer as the sidecar says it did
                if bool(view.get("reference_opens", False)) != (error is None):
                    problem("%s: the reference reader %s the view %r now, and the sidecar says it %s" % (
                        item["file"], "opens" if error is None else "refuses", view["projection"],
                        "opens" if view.get("reference_opens") else "refuses"))
                elif error is None:
                    if "reference_cells" in view:
                        for i, name in enumerate(table.schema.names):
                            got = cells_of(table.column(i).combine_chunks())
                            if got != view["reference_cells"].get(name):
                                problem("%s: the reference reader answers the view %r now differently from the "
                                        "cells the sidecar records for it" % (item["file"], view["projection"]))
                stats["own"] = stats.get("own", 0) + 1
                continue
            if error is not None:
                problem("%s: the reader refuses the view %r now: %s" % (item["file"], view["projection"], error))
                continue
            names = [c["name"] for c in view["columns"]]
            if table.schema.names != names:
                problem("%s: the reader names the view %r %r, the sidecar %r" % (
                    item["file"], view["projection"], table.schema.names, names))
                continue
            for i, column in enumerate(view["columns"]):
                got = cells_of(table.column(i).combine_chunks())
                if len(got) != len(column["cells"]):
                    problem("%s: %s: %d cells now, %d in the sidecar" % (item["file"], column["name"], len(got), len(column["cells"])))
                    continue
                for mine, theirs in zip(column["cells"], got):
                    stats["cells"] += 1
                    if mine == theirs:
                        stats["agreed"] += 1
                    else:
                        problem("%s: view %r, column %s, row %d: sidecar %r, reader %r" % (
                            item["file"], view["projection"], column["name"], column["cells"].index(mine), mine, theirs))
    log("reference files: %(files)d; the codec refuses %(refused)d by name; the reader opens the unprojected file: %(opens)d, "
        "refuses: %(cannot_open)d" % stats)
    log("views re-read: %(views)d; cells compared with the sidecars: %(cells)d; agreed: %(agreed)d; mismatches: %(mismatch)d" % stats)
    log("views whose cells are the generator's own, the reference reader unable to hold their values or answering "
        "others: %(own)d" % stats)
    # and the reference reader's answer to every case of the replacement
    # sweep, against what the corpus records
    with open(os.path.join(FIX, "sweep.json"), encoding="utf-8") as f:
        sweep = json.load(f)
    cases, answers = sweep_read()
    now = sweep_json(cases, answers)
    sweep_opens = 0
    for name, recorded in sweep["files"].items():
        for old, new in zip(recorded, now["files"][name]):
            stats["sweep"] = stats.get("sweep", 0) + 1
            sweep_opens += 1 if new["reference_opens"] else 0
            if old["reference_opens"] != new["reference_opens"] or old.get("cells") != new.get("cells"):
                problem("%s: the reference reader answers case %d now as it did not when the corpus was written" % (
                    name, recorded.index(old)))
    log("replacement sweep re-read: %d cases; the reference reader opens %d of the copies; mismatches: %d" % (
        stats.get("sweep", 0), sweep_opens, stats["mismatch"]))
    os.makedirs(LOG, exist_ok=True)
    with open(os.path.join(LOG, "verify_summary.json"), "w", encoding="utf-8") as f:
        json.dump(stats, f, indent=1)
    return 1 if stats["mismatch"] else 0


def digest():
    """The SHA-256 over every file of the corpus, file name and bytes: two
    `make` runs on one version of the writer give the same digest."""
    h = hashlib.sha256()
    for name in sorted(os.listdir(FIX)):
        h.update(name.encode("utf-8"))
        with open(os.path.join(FIX, name), "rb") as f:
            h.update(f.read())
    log(h.hexdigest())
    return 0


if __name__ == "__main__":
    steps = [a for a in sys.argv[1:] if not a.startswith("--")]
    step = steps[0] if steps else "make"
    sys.exit({"make": make, "verify": verify, "digest": digest}[step]())
