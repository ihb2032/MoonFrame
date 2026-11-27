"""Generate the Avro fixtures the MoonFrame reader is checked against.

    uv run --no-project --with fastavro --with cramjam --with backports.zstd python -I -X utf8 make_fixtures.py
    uv run --no-project --with fastavro --with cramjam --with backports.zstd python -I -X utf8 make_fixtures.py verify <file.avro> [<file.avro> ...]

`make_fixtures.py` alone (re)writes every `fastavro_*.avro` file here with
fastavro, the reference implementation, and prints what fastavro itself
reads back from each; the cells the MoonFrame tests expect are these.
`verify` opens files MoonFrame wrote with fastavro and compares their rows
with the same table — the cross-check that runs by hand after a change to
the writer, since no Python runs in CI.

The row set is `types_rows`: three records over every type the reader
carries, one column per Avro type and logical type.
"""

import datetime
import decimal
import json
import pathlib
import sys

from fastavro import parse_schema, reader, writer

HERE = pathlib.Path(__file__).parent

COLOR = {
    "type": "record",
    "name": "Color",
    "fields": [
        {"name": "r", "type": "int"},
        {"name": "g", "type": "int"},
        {"name": "b", "type": ["null", "int"]},
    ],
}

KIND = {"type": "enum", "name": "Kind", "symbols": ["a", "b", "c"]}

TYPES_SCHEMA = {
    "type": "record",
    "name": "Person",
    "fields": [
        {"name": "name", "type": ["null", "string"]},
        {"name": "age", "type": ["null", "int"]},
        {"name": "id", "type": ["null", "long"]},
        {"name": "height", "type": ["null", "double"]},
        {"name": "score", "type": ["null", "float"]},
        {"name": "active", "type": ["null", "boolean"]},
        {"name": "tags", "type": ["null", {"type": "array", "items": ["null", "string"]}]},
        # A named type defined where it is first used, then referred to by
        # its name alone in the next field.
        {"name": "color", "type": ["null", COLOR]},
        {"name": "again", "type": ["null", "Color"]},
        {"name": "kind", "type": ["null", KIND]},
        {"name": "birth", "type": ["null", {"type": "int", "logicalType": "date"}]},
        {"name": "seen_millis", "type": ["null", {"type": "long", "logicalType": "timestamp-millis"}]},
        {"name": "seen_micros", "type": ["null", {"type": "long", "logicalType": "timestamp-micros"}]},
        {"name": "at_millis", "type": ["null", {"type": "int", "logicalType": "time-millis"}]},
        {"name": "at_micros", "type": ["null", {"type": "long", "logicalType": "time-micros"}]},
        {"name": "amount", "type": ["null", {"type": "bytes", "logicalType": "decimal", "precision": 12, "scale": 4}]},
    ],
}

DAY = datetime.datetime(1970, 1, 1)

TYPES_ROWS = [
    {
        "name": "Zoë",
        "age": 30,
        "id": 9007199254740993,
        "height": 1.75,
        "score": 0.5,
        "active": True,
        "tags": ["a", "b"],
        "color": {"r": 1, "g": 2, "b": 3},
        "again": {"r": 1, "g": 2, "b": None},
        "kind": "a",
        "birth": datetime.date(2024, 2, 29),
        "seen_millis": datetime.datetime(2024, 5, 17, 8, 9, 10, 123000),
        "seen_micros": datetime.datetime(2024, 5, 17, 8, 9, 10, 123456),
        "at_millis": datetime.time(13, 14, 15, 123000),
        "at_micros": datetime.time(13, 14, 15, 123456),
        "amount": decimal.Decimal("-12345.6789"),
    },
    {
        "name": None,
        "age": -1,
        "id": -9223372036854775808,
        "height": -0.0,
        "score": 1.5,
        "active": False,
        "tags": [],
        "color": None,
        "again": None,
        "kind": "c",
        "birth": datetime.date(1960, 1, 1),
        "seen_millis": datetime.datetime(1970, 1, 1),
        "seen_micros": None,
        "at_millis": datetime.time(0, 0, 0),
        "at_micros": datetime.time(23, 59, 59, 999999),
        "amount": decimal.Decimal("0.0001"),
    },
    {
        "name": "日本語 – naïve 🌍",
        "age": 2147483647,
        "id": 9223372036854775807,
        "height": 3.14159,
        "score": None,
        "active": None,
        "tags": ["x", None, ""],
        "color": {"r": -1, "g": 0, "b": None},
        "again": {"r": 7, "g": 8, "b": 9},
        "kind": None,
        "birth": None,
        "seen_millis": None,
        "seen_micros": datetime.datetime(9999, 12, 31, 23, 59, 59, 999999),
        "at_millis": None,
        "at_micros": None,
        "amount": decimal.Decimal("99999999.9999"),
    },
]

LOGICAL_SCHEMA = {
    "type": "record",
    "name": "Logical",
    "fields": [
        {"name": "uuid", "type": ["null", {"type": "string", "logicalType": "uuid"}]},
        {"name": "fixed_amount", "type": ["null", {"type": "fixed", "name": "Amt", "size": 4, "logicalType": "decimal", "precision": 9, "scale": 2}]},
        {"name": "local_millis", "type": ["null", {"type": "long", "logicalType": "local-timestamp-millis"}]},
        {"name": "unknown_logical", "type": ["null", {"type": "int", "logicalType": "no-such-logical-type"}]},
        {"name": "int_outside", "type": ["null", "int"]},
    ],
}

LOGICAL_ROWS = [
    {
        "uuid": "123e4567-e89b-12d3-a456-426614174000",
        "fixed_amount": decimal.Decimal("-12345.67"),
        "local_millis": datetime.datetime(2024, 5, 17, 8, 9, 10, 123000),
        "unknown_logical": 7,
        "int_outside": 3,
    },
    {
        "uuid": None,
        "fixed_amount": decimal.Decimal("0.01"),
        "local_millis": None,
        "unknown_logical": None,
        "int_outside": 9,
    },
]


REFUSED_FIELD = {
    "bytes": ("blob", {"name": "blob", "type": ["null", "bytes"]}),
    "map": ("counts", {"name": "counts", "type": ["null", {"type": "map", "values": "long"}]}),
    "union": ("either", {"name": "either", "type": ["null", "int", "string"]}),
    "duration": ("span", {"name": "span", "type": ["null", {"type": "fixed", "name": "Span", "size": 12, "logicalType": "duration"}]}),
    "nanos": ("at", {"name": "at", "type": ["null", {"type": "long", "logicalType": "timestamp-nanos"}]}),
    "record_no_fields": ("nothing", {"name": "nothing", "type": ["null", {"type": "record", "name": "Nothing", "fields": []}]}),
}


def refused_schema(what):
    return {
        "type": "record",
        "name": "Refused",
        "fields": [
            {"name": "kept", "type": ["null", "int"]},
            REFUSED_FIELD[what][1],
        ],
    }


def refused_rows(what):
    name = REFUSED_FIELD[what][0]
    extra = {
        "bytes": [b"\x00\xff", None],
        "map": [{"a": 1}, {}],
        "union": [3, "x"],
        "duration": [None, (1).to_bytes(12, "little")],
        "nanos": [1_000_000_000, None],
        "record_no_fields": [{}, {}],
    }[what]
    return [{"kept": kept, name: value} for kept, value in zip([17, None], extra)]


def shown(value):
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, datetime.datetime):
        # The reader hands back an instant in UTC; the reference table
        # spells the same instant naive.
        if value.tzinfo is not None:
            value = value.astimezone(datetime.timezone.utc).replace(tzinfo=None)
        return value.isoformat()
    if isinstance(value, (datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, decimal.Decimal):
        return str(value)
    if value is None or isinstance(value, (str, int, float, bool, list, dict)):
        return value
    return str(value)


def show(value):
    """A row's cells, in the forms the comparisons spell them in."""
    if isinstance(value, dict):
        return {key: show(cell) for key, cell in value.items()}
    if isinstance(value, list):
        return [show(cell) for cell in value]
    return shown(value)


def write(name, schema, rows, codec="null", **kwargs):
    path = HERE / name
    # One record schema, as a file's root is: the named types it uses are
    # defined inline where each is first used, so the file carries one
    # schema and not a list of them.
    parsed = parse_schema(schema)
    with path.open("wb") as handle:
        writer(handle, parsed, rows, codec=codec, **kwargs)
    return path


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "verify":
        failed = False
        for arg in sys.argv[2:]:
            path = pathlib.Path(arg)
            with path.open("rb") as handle:
                rows = [show(row) for row in reader(handle)]
            # Every column the file carries is compared with the reference
            # table's, row by row; a column the table has and the file does
            # not is not held against it.
            keys = list(rows[0]) if rows else []
            differences = [
                f"  row {i}, column {key!r}: file {row[key]!r}, reference {show(reference)[key]!r}"
                for i, (row, reference) in enumerate(zip(rows, TYPES_ROWS))
                for key in keys
                if row[key] != show(reference)[key]
            ]
            same = len(rows) == len(TYPES_ROWS) and not differences
            failed = failed or not same
            print(
                f"{path.name}: {len(rows)} rows over {len(keys)} columns, "
                f"{'identical to' if same else 'DIFFERENT from'} the reference table"
            )
            for line in differences[:10]:
                print(line)
        sys.exit(1 if failed else 0)
        return

    for codec in ("null", "deflate", "snappy", "zstandard", "bzip2"):
        write(f"fastavro_types_{codec}.avro", TYPES_SCHEMA, TYPES_ROWS, codec=codec)
    write("fastavro_multiblock.avro", TYPES_SCHEMA, TYPES_ROWS * 334, sync_interval=100)
    write("fastavro_logical.avro", LOGICAL_SCHEMA, LOGICAL_ROWS)
    for what in ("bytes", "map", "union", "duration", "nanos", "record_no_fields"):
        write(f"fastavro_refused_{what}.avro", refused_schema(what), refused_rows(what))
    for path in sorted(HERE.glob("fastavro_*.avro")):
        with path.open("rb") as handle:
            records = list(reader(handle))
        first = records[0] if records else {}
        print(f"{path.name}: {path.stat().st_size} bytes, {len(records)} records")
        print("  first record:", json.dumps({k: shown(v) for k, v in first.items()}, ensure_ascii=False))


if __name__ == "__main__":
    main()
