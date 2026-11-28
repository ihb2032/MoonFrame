"""The reference corpus of Iceberg tables: every table's whole directory as
the reference wrote it (or derived from one it wrote), a JSON sidecar
beside it holding what the reference itself answers for it, and an index.

    uv run --no-project --with "pyiceberg[pyiceberg-core]" --with pyarrow --with sqlalchemy --with zstandard python -I -X utf8 .github/fixtures/iceberg/gen_fixtures.py make
    uv run --no-project --with "pyiceberg[pyiceberg-core]" --with pyarrow --with sqlalchemy --with zstandard python -I -X utf8 .github/fixtures/iceberg/gen_fixtures.py verify

`make` writes the tables under a transient warehouse under the
repository's `_build/` and copies each table's directory to
`.github/fixtures/iceberg/reference/`, where it stays — a data file whose
path there would be too long for a checkout excepted, which the sidecar
names under `not_carried`.
The paths inside the metadata still spell the warehouse, so `verify`
re-reads every table from fixtures/reference/ through a file IO that maps
the warehouse location onto the copied directory, and compares what the
reference answers with the sidecar, byte for byte. Either step exits
non-zero on a mismatch.
"""
from __future__ import annotations

import datetime
import decimal
import json
import os
import shutil
import struct
import sys
import traceback
import uuid
import warnings

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import pyarrow as pa  # noqa: E402
import pyarrow.compute as pc  # noqa: E402
import pyarrow.parquet as pq  # noqa: E402
import pyiceberg  # noqa: E402
from pyiceberg.catalog.noop import NoopCatalog  # noqa: E402
from pyiceberg.catalog.sql import SqlCatalog  # noqa: E402
from pyiceberg.io.pyarrow import (  # noqa: E402
    PyArrowFileIO,
    compute_statistics_plan,
    data_file_statistics_from_parquet_metadata,
    parquet_path_to_id_mapping,
)
from pyiceberg.manifest import (  # noqa: E402
    DataFile,
    DataFileContent,
    FileFormat,
    ManifestContent,
    ManifestWriterV2,
)
from pyiceberg.schema import Schema  # noqa: E402
from pyiceberg.serializers import FromInputFile  # noqa: E402
from pyiceberg.table import StaticTable  # noqa: E402
from pyiceberg.table.snapshots import Operation  # noqa: E402
from pyiceberg.table.update.snapshot import _FastAppendFiles  # noqa: E402
from pyiceberg.transforms import (  # noqa: E402
    BucketTransform,
    DayTransform,
    HourTransform,
    IdentityTransform,
    MonthTransform,
    TruncateTransform,
    YearTransform,
)
from pyiceberg.types import DoubleType, LongType, NestedField, StringType  # noqa: E402
from pyiceberg.typedef import Record  # noqa: E402

from avro_container import Container, avro_int, avro_string  # noqa: E402

warnings.simplefilter("ignore")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
REF = os.path.join(HERE, "reference")
WH = os.path.join(REPO, "_build", "iceberg_fixture_warehouse")
# The most characters a corpus file's path may take up from the repository's
# root: a checkout on Windows opens no path of 260 characters or more,
# whatever the clone's own directory.
PATH_LIMIT = 200
LIMIT = 1_500_000
PATH_FIELD_ID = 2147483546
POS_FIELD_ID = 2147483545
FIELD_ID_KEY = b"PARQUET:field_id"
EPOCH_DAY = datetime.date(1970, 1, 1)
EPOCH_STAMP = datetime.datetime(1970, 1, 1)
INDEX = "index.json"


# ---------------------------------------------------------------- spells
def double_hex(value) -> str:
    """The IEEE 754 bits of a double, as a 32-bit float's exact widening when
    the value is one."""
    widened = float(value)
    return "%016x" % struct.unpack(">Q", struct.pack(">d", widened))[0]


def days_of(value) -> int:
    return (value - EPOCH_DAY).days


def micros_of(value) -> int:
    if value.tzinfo is not None:
        value = value.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    delta = value - EPOCH_STAMP
    return (delta.days * 86_400 + delta.seconds) * 1_000_000 + delta.microseconds


def spell(iceberg_type, value) -> dict:
    """A cell as the sidecar spells it: its kind and its value in a form that
    loses nothing — a double by its bits, a timestamp by its microseconds."""
    if value is None:
        return {"kind": "null"}
    name = str(iceberg_type)
    if name == "boolean":
        return {"kind": "bool", "value": bool(value)}
    if name in ("int", "long"):
        return {"kind": "int", "value": int(value)}
    if name in ("float", "double"):
        return {"kind": "float", "value": double_hex(value)}
    if name == "string":
        return {"kind": "string", "value": str(value)}
    if name == "date":
        return {"kind": "date", "value": days_of(value) if isinstance(value, datetime.date) else int(value)}
    if name in ("timestamp", "timestamptz"):
        return {"kind": "timestamp", "value": str(micros_of(value) if isinstance(value, datetime.datetime) else int(value))}
    if name.startswith("decimal"):
        # By its digits: the trailing zeros of a fixed-point spelling are not
        # part of the value, and the library's decimal does not render them.
        text = str(value)
        if "." in text:
            text = text.rstrip("0").rstrip(".")
        return {"kind": "decimal", "value": text}
    if name.startswith("list<"):
        element = iceberg_type.element_type
        return {"kind": "list", "value": [spell(element, item) for item in (value or [])]}
    if name.startswith("struct<"):
        out = []
        for field, item in zip(iceberg_type.fields, [value.get(f.name) if value else None for f in iceberg_type.fields]):
            out.append([field.name, spell(field.field_type, item)])
        return {"kind": "struct", "value": out}
    if name == "time":
        micros = (value.hour * 3_600 + value.minute * 60 + value.second) * 1_000_000 + value.microsecond
        return {"kind": "time", "value": str(micros)}
    if name.startswith("map<"):
        return {"kind": "map", "value": [[spell(iceberg_type.key_type, k), spell(iceberg_type.value_type, v)] for k, v in (value or [])]}
    return {"kind": "bytes", "value": bytes(value).hex()}


def dtype_text(iceberg_type) -> str:
    """The library dtype a type reads as here, spelled the way the codec's
    tests spell one — written from the specification's type list, not from
    the codec."""
    name = str(iceberg_type)
    table = {
        "boolean": "Bool", "int": "Int", "long": "Int", "float": "Float", "double": "Float",
        "string": "String", "date": "Date", "timestamp": "Timestamp", "timestamptz": "Timestamp",
    }
    if name in table:
        return table[name]
    if name.startswith("decimal"):
        return "Decimal"
    if name.startswith("list<"):
        return "List[" + dtype_text(iceberg_type.element_type) + "]"
    if name.startswith("struct<"):
        return "Struct{" + ", ".join(f"{f.name}: {dtype_text(f.field_type)}" for f in iceberg_type.fields) + "}"
    raise ValueError(f"no library dtype for {name}")


def cells(iceberg_type, column) -> list:
    """A column's cells from an arrow chunked array, spelled by the type."""
    name = str(iceberg_type)
    if name == "date":
        # Days since the epoch, as the integer cast of a date answers them.
        return pc.cast(column, pa.int32()).to_pylist()
    if name in ("timestamp", "timestamptz"):
        # Microseconds since the epoch.
        return pc.cast(column, pa.int64()).to_pylist()
    return column.to_pylist()


def column_cells(iceberg_type, column) -> list:
    values = cells(iceberg_type, column)
    if str(iceberg_type) == "date":
        return [{"kind": "date", "value": v} if v is not None else {"kind": "null"} for v in values]
    if str(iceberg_type) in ("timestamp", "timestamptz"):
        return [{"kind": "timestamp", "value": v} if v is not None else {"kind": "null"} for v in values]
    return [spell(iceberg_type, v) for v in values]


# ---------------------------------------------------------------- reading
class RemapIO(PyArrowFileIO):
    """The reference's file IO with every path under the warehouse location
    the metadata spells redirected onto the copied table directory."""

    def __init__(self, properties, source: str, target: str):
        super().__init__(properties)
        self.source = source.replace("\\", "/").rstrip("/")
        self.target = target

    def _map(self, location: str) -> str:
        plain = location.replace("\\", "/")
        if plain.startswith(self.source + "/"):
            return os.path.join(self.target, *plain[len(self.source) + 1:].split("/"))
        return location

    def new_input(self, location: str):
        return super().new_input(self._map(location))

    def new_output(self, location: str):
        return super().new_output(self._map(location))


def newest_metadata(table_dir: str) -> str:
    mdir = os.path.join(table_dir, "metadata")
    best, version = None, -1
    for name in os.listdir(mdir):
        if name.endswith(".metadata.json"):
            digits = name.split("-", 1)[0]
            n = int(digits) if digits.isdigit() else -1
            if n > version:
                best, version = os.path.join(mdir, name), n
    return best


def load_static(metadata_location: str, source: str, target: str) -> StaticTable:
    io = RemapIO({}, source, target)
    metadata = FromInputFile.table_metadata(io.new_input(metadata_location))
    return StaticTable(
        identifier=("static-table", metadata_location),
        metadata_location=metadata_location,
        metadata=metadata,
        io=io,
        catalog=NoopCatalog("static-table"),
    )


def relative(path: str, location: str) -> str:
    if path.startswith(location + "/") or path.startswith(location + "\\"):
        return path[len(location) + 1:]
    return path


def transform_text(transform) -> str:
    return str(transform)


def metric_ids(data_file) -> list:
    ids = set()
    for metrics in (data_file.column_sizes, data_file.value_counts, data_file.null_value_counts, data_file.nan_value_counts, data_file.lower_bounds, data_file.upper_bounds):
        if metrics:
            ids.update(int(k) for k in dict(metrics).keys())
    return sorted(ids)


def describe_partition(data_file, spec, schema) -> list:
    """A file's partition values, each with its field's name, source column
    and transform: spelled by the source column's type for the transforms
    that keep the value, as a date for a day, as a whole number for a
    bucket or a count of time."""
    values = list(data_file.partition)
    out = []
    for position, field in enumerate(spec.fields):
        value = values[position] if position < len(values) else None
        name = str(field.transform)
        if value is None:
            spelled = {"kind": "null"}
        elif name == "day":
            spelled = {"kind": "date", "value": int(value)}
        elif name.startswith("identity") or name.startswith("truncate"):
            spelled = spell(schema.find_type(field.source_id), value)
        else:
            spelled = {"kind": "int", "value": int(value)}
        out.append([field.name, int(field.source_id), name, spelled])
    return out


def describe_snapshot(table) -> dict:
    """The snapshot's manifests and files as the reference lists them: every
    manifest of the list in its order, every live entry in its order, with
    the sequence number the reference inherits for it."""
    snapshot = table.current_snapshot()
    if snapshot is None:
        return {"snapshot": None, "sequence_number": None, "manifest_list": None, "manifests": []}
    location = table.location()
    specs = table.metadata.specs()
    schema = table.metadata.schema()
    manifests = []
    for m in snapshot.manifests(table.io):
        spec = specs[m.partition_spec_id]
        files = []
        for e in m.fetch_manifest_entry(table.io, discard_deleted=True):
            df = e.data_file
            files.append(
                {
                    "path": relative(df.file_path, location),
                    "kind": int(df.content),
                    "record_count": int(df.record_count),
                    "sequence_number": int(e.sequence_number or 0),
                    "field_ids": metric_ids(df),
                    "partition": describe_partition(df, spec, schema),
                    "equality_ids": [int(i) for i in (df.equality_ids or [])],
                }
            )
        manifests.append({"path": relative(m.manifest_path, location), "length": int(m.manifest_length), "files": files})
    return {
        "snapshot": int(snapshot.snapshot_id),
        "sequence_number": int(snapshot.sequence_number or 0),
        "manifest_list": relative(snapshot.manifest_list, location),
        "manifests": manifests,
    }


def describe_table(table) -> dict:
    """What the reference answers for a table: its schema in its own type
    spellings and — where every type is one the library carries — in the
    library's dtypes, the fields of its default partition spec, and its
    snapshot's manifests and files."""
    schema = table.metadata.schema()
    spec = table.spec()
    try:
        dtypes = [dtype_text(f.field_type) for f in schema.fields]
    except ValueError:
        dtypes = None
    return {
        "format_version": int(table.metadata.format_version),
        "location": table.location(),
        "schema": {
            "names": [f.name for f in schema.fields],
            "field_ids": [int(f.field_id) for f in schema.fields],
            "types": [str(f.field_type) for f in schema.fields],
            "dtypes": dtypes,
        },
        "partition_fields": [[pf.name, int(pf.source_id), transform_text(pf.transform)] for pf in spec.fields],
        "plan": describe_snapshot(table),
    }


def reference_rows(table) -> list:
    """The cells the reference's own scan answers, column by column."""
    arrow = table.scan().to_arrow()
    schema = table.metadata.schema()
    columns = []
    for position, field in enumerate(schema.fields):
        columns.append(column_cells(field.field_type, arrow.column(field.name)))
    names = [f.name for f in schema.fields]
    return [{name: cells[i] for i, name in enumerate(names)} for cells in zip(*columns)] if columns else []


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def plan_rows(table) -> list:
    """The snapshot's rows file by file in the plan's order — each Parquet
    file read by itself, the position deletes the reference's plan attaches
    to it dropped — so that a reader that walks the plan can compare cell
    for cell. The reference's own answer is the check on this."""
    schema = table.metadata.schema()
    names = [f.name for f in schema.fields]
    rows = []
    for task in table.scan().plan_files():
        data_file = task.file
        frame = pq.read_table(data_file.file_path)
        columns = []
        for field in schema.fields:
            arrow_field = None
            for candidate in frame.schema:
                if candidate.metadata and candidate.metadata.get(FIELD_ID_KEY) == str(field.field_id).encode():
                    arrow_field = candidate
                    break
            index = frame.schema.get_field_index(arrow_field.name) if arrow_field is not None else None
            values = column_cells(field.field_type, frame.column(index)) if index is not None else [{"kind": "null"}] * frame.num_rows
            columns.append(values)
        file_rows = [{name: cells[i] for i, name in enumerate(names)} for cells in zip(*columns)]
        drops = set()
        for delete_file in task.delete_files:
            deletes = pq.read_table(delete_file.file_path, columns=["file_path", "pos"])
            for path, position in zip(deletes.column("file_path").to_pylist(), deletes.column("pos").to_pylist()):
                if path == data_file.file_path:
                    drops.add(int(position))
        rows.extend(row for position, row in enumerate(file_rows) if position not in drops)
    return rows


def write_json(path: str, value) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, indent=1, ensure_ascii=False, sort_keys=True)
        handle.write("\n")


# ---------------------------------------------------------------- writing
class DeleteManifestWriter(ManifestWriterV2):
    """The reference's manifest writer for a manifest of delete files — the
    class the release defines but no write path of its own uses."""

    def content(self):
        return ManifestContent.DELETES

    @property
    def _meta(self):
        return {**super()._meta, "content": "deletes"}


class DeleteCommit(_FastAppendFiles):
    """A fast append whose added files go into a manifest of deletes and
    whose commit is recorded as a delete."""

    def new_manifest_writer(self, spec):
        return DeleteManifestWriter(
            spec=spec,
            schema=self.schema(),
            output_file=self.new_manifest_output(),
            snapshot_id=self._snapshot_id,
            avro_compression=self._compression,
        )


def arrow_table(schema: pa.Schema, columns: dict) -> pa.Table:
    return pa.table({name: pa.array(values, type=schema.field(name).type) for name, values in columns.items()}, schema=schema)


def day(n: int) -> datetime.date:
    return EPOCH_DAY + datetime.timedelta(days=n)


STAMP = datetime.datetime(2020, 3, 1, 12, 34, 56, 789012)


def write_parquet(path: str, frame: pa.Table) -> None:
    fo = CATALOG._load_file_io({}, path).new_output(path)
    with fo.create(overwrite=True) as stream:
        pq.write_table(frame, stream)


def delete_data_file(table, path: str, content, fields, partition, equality_ids=None) -> DataFile:
    """The manifest entry's description of a delete file, its metrics read
    from the Parquet file by the reference's own statistics reader."""
    delete_schema = Schema(*fields)
    stats = data_file_statistics_from_parquet_metadata(
        parquet_metadata=pq.read_metadata(path),
        stats_columns=compute_statistics_plan(delete_schema, table.metadata.properties),
        parquet_column_mapping=parquet_path_to_id_mapping(delete_schema),
    )
    return DataFile.from_args(
        content=content,
        file_path=path,
        file_format=FileFormat.PARQUET,
        partition=partition,
        file_size_in_bytes=os.path.getsize(path),
        sort_order_id=None,
        spec_id=table.metadata.default_spec_id,
        equality_ids=equality_ids,
        key_metadata=None,
        **stats.to_serialized_dict(),
    )


def commit_deletes(table, data_files) -> None:
    with table.transaction() as tx:
        with DeleteCommit(operation=Operation.DELETE, transaction=tx, io=table.io) as commit:
            for data_file in data_files:
                commit.append_data_file(data_file)


CATALOG: SqlCatalog = None
WALK_DIFFERS = {
    "refused_default": "the reference materialises the column's initial default for the rows written before the column was added; a reader of the files alone answers null",
    "refused_name_mapping": "the imported Parquet file carries no field ids; its columns are found only through the name mapping the metadata holds",
}
EXTRA: dict = {
    "position_deletes": "a position-delete Parquet file written by the generator and committed through the reference's own manifest, list and metadata writers",
    "equality_deletes": "an equality-delete Parquet file written by the generator and committed through the reference's own manifest, list and metadata writers",
}


def t_append_one():
    table = CATALOG.create_table("ns.append_one", pa.schema([("i", pa.int64()), ("s", pa.string())]))
    table.append(arrow_table(pa.schema([("i", pa.int64()), ("s", pa.string())]), {"i": [1, 2, 3], "s": ["a", "b", None]}))
    return table


def t_append_three():
    schema = pa.schema([("i", pa.int64()), ("s", pa.string()), ("d", pa.date32())])
    table = CATALOG.create_table("ns.append_three", schema)
    table.append(arrow_table(schema, {"i": [1, 2], "s": ["a", "b"], "d": [day(0), day(1)]}))
    table.append(arrow_table(schema, {"i": [3], "s": ["c"], "d": [day(2)]}))
    table.append(arrow_table(schema, {"i": [4, 5], "s": ["d", "e"], "d": [day(3), day(4)]}))
    return table


def t_overwrite():
    schema = pa.schema([("i", pa.int64()), ("k", pa.string())])
    table = CATALOG.create_table("ns.overwrite", schema)
    table.append(arrow_table(schema, {"i": [1, 2, 3], "k": ["a", "b", "c"]}))
    table.overwrite(arrow_table(schema, {"i": [4, 5], "k": ["d", "e"]}))
    return table


def t_delete_rows():
    schema = pa.schema([("i", pa.int64()), ("k", pa.string())])
    table = CATALOG.create_table("ns.delete_rows", schema)
    table.append(arrow_table(schema, {"i": [1, 2, 3], "k": ["a", "b", "c"]}))
    table.append(arrow_table(schema, {"i": [4, 5], "k": ["d", "e"]}))
    table.delete("k == 'b' or i == 5")
    return table


def t_evolution():
    base = pa.schema([("id", pa.int32()), ("name", pa.string()), ("f", pa.float32()), ("dec", pa.decimal128(9, 2)), ("gone", pa.string())])
    table = CATALOG.create_table("ns.evolution", base)
    table.append(
        arrow_table(
            base,
            {
                "id": [1, 2],
                "name": ["a", "b"],
                "f": [0.5, 1.5],
                "dec": [decimal.Decimal("1.10"), None],
                "gone": ["x", "y"],
            },
        )
    )
    with table.update_schema() as update:
        update.add_column("added", StringType())
        update.rename_column("name", "title")
        update.delete_column("gone")
        update.update_column("id", field_type=LongType())
        update.update_column("f", field_type=DoubleType())
        update.update_column("dec", field_type=__import__("pyiceberg.types", fromlist=["DecimalType"]).DecimalType(12, 2))
    after = pa.schema([("id", pa.int64()), ("title", pa.string()), ("f", pa.float64()), ("dec", pa.decimal128(12, 2)), ("added", pa.string())])
    table.append(
        arrow_table(
            after,
            {
                "id": [3],
                "title": ["c"],
                "f": [2.5],
                "dec": [decimal.Decimal("3.00")],
                "added": ["new"],
            },
        )
    )
    return table


def t_types():
    schema = pa.schema(
        [
            ("b", pa.bool_()),
            ("i", pa.int32()),
            ("l", pa.int64()),
            ("f", pa.float32()),
            ("d", pa.float64()),
            ("s", pa.string()),
            ("dt", pa.date32()),
            ("ts", pa.timestamp("us")),
            ("tstz", pa.timestamp("us", tz="UTC")),
            ("dec", pa.decimal128(9, 2)),
            ("wide", pa.decimal128(20, 6)),
            ("lst", pa.list_(pa.int64())),
            ("st", pa.struct([("x", pa.int32()), ("y", pa.string())])),
            ("deep", pa.list_(pa.struct([("a", pa.int32()), ("inner", pa.struct([("z", pa.bool_())]))]))),
        ]
    )
    stamp = STAMP
    table = CATALOG.create_table("ns.types", schema)
    table.append(
        arrow_table(
            schema,
            {
                "b": [True, None, False],
                "i": [-5, 7, 2**31 - 1],
                "l": [-(2**40), 2**40, None],
                "f": [1.5, None, -0.0],
                "d": [2.25, -3.5, float("inf")],
                "s": ["hé", None, ""],
                "dt": [day(3), day(-1), None],
                "ts": [stamp, None, STAMP + datetime.timedelta(microseconds=1)],
                "tstz": [stamp.replace(tzinfo=datetime.timezone.utc), None, STAMP - datetime.timedelta(hours=5)],
                "dec": [decimal.Decimal("12.30"), None, decimal.Decimal("-0.05")],
                "wide": [decimal.Decimal("12345678901234.567891"), None, decimal.Decimal("1.000000")],
                "lst": [[1, 2], None, []],
                "st": [{"x": 1, "y": "a"}, None, {"x": None, "y": None}],
                "deep": [[{"a": 1, "inner": {"z": True}}, {"a": None, "inner": None}], None, []],
            },
        )
    )
    return table


def t_unicode():
    schema = pa.schema([("col naïf", pa.string()), ("a.b", pa.int64()), ("with space", pa.string())])
    table = CATALOG.create_table("ns.unicode", schema)
    table.append(
        arrow_table(
            schema,
            {
                "col naïf": ["Ünïcödé — ✓", "日本語", None],
                "a.b": [1, -2, 3],
                "with space": ["", "two words", "three"],
            },
        )
    )
    return table


def t_partition_identity():
    schema = pa.schema([("k", pa.string()), ("d", pa.date32()), ("i", pa.int64())])
    table = CATALOG.create_table("ns.partition_identity", schema)
    with table.update_spec() as update:
        update.add_field("k", IdentityTransform())
        update.add_field("d", IdentityTransform())
    table.append(arrow_table(schema, {"k": ["a", "a", None], "d": [day(0), day(1), day(0)], "i": [1, 2, 3]}))
    table.append(arrow_table(schema, {"k": ["b"], "d": [day(1)], "i": [4]}))
    return table


def t_partition_transforms():
    schema = pa.schema([("k", pa.string()), ("t", pa.string()), ("n", pa.int64()), ("dt", pa.date32()), ("dt2", pa.date32()), ("ts", pa.timestamp("us"))])
    table = CATALOG.create_table("ns.partition_transforms", schema)
    with table.update_spec() as update:
        update.add_field("k", IdentityTransform())
        update.add_field("n", BucketTransform(4))
        update.add_field("t", TruncateTransform(2))
        update.add_field("dt", YearTransform())
        update.add_field("dt2", MonthTransform())
        update.add_field("ts", DayTransform())
    table.append(
        arrow_table(
            schema,
            {
                "k": ["iceberg", "spark"],
                "t": ["iceberg", "spark"],
                "n": [34, 35],
                "dt": [day(19000), day(1)],
                "dt2": [day(19000), day(1)],
                "ts": [STAMP, STAMP + datetime.timedelta(hours=3, minutes=30)],
            },
        )
    )
    return table


def t_partition_scalars():
    schema = pa.schema(
        [
            ("b", pa.bool_()),
            ("i", pa.int32()),
            ("l", pa.int64()),
            ("f", pa.float32()),
            ("d", pa.float64()),
            ("m", pa.decimal128(10, 3)),
            ("ts", pa.timestamp("us")),
            ("tsz", pa.timestamp("us", tz="UTC")),
            ("v", pa.string()),
        ]
    )
    table = CATALOG.create_table("ns.partition_scalars", schema)
    with table.update_spec() as update:
        for name in ("b", "i", "l", "f", "d", "m", "ts", "tsz"):
            update.add_field(name, IdentityTransform())
    table.append(
        arrow_table(
            schema,
            {
                "b": [True, None],
                "i": [-5, 7],
                "l": [-(2**40), 2**40],
                "f": [1.5, None],
                "d": [2.25, -3.5],
                "m": [decimal.Decimal("12.345"), None],
                "ts": [STAMP, None],
                "tsz": [STAMP.replace(tzinfo=datetime.timezone.utc), None],
                "v": ["one", "two"],
            },
        )
    )
    return table


def t_partition_evolution():
    schema = pa.schema([("k", pa.string()), ("n", pa.int64())])
    table = CATALOG.create_table("ns.partition_evolution", schema)
    table.append(arrow_table(schema, {"k": ["a"], "n": [1]}))
    with table.update_spec() as update:
        update.add_field("k", IdentityTransform())
    table.append(arrow_table(schema, {"k": ["b"], "n": [2]}))
    with table.update_spec() as update:
        update.add_field("n", BucketTransform(3), "n_bucket")
    table.append(arrow_table(schema, {"k": ["c"], "n": [3]}))
    return table


def live_data_files(table) -> list:
    return [e.data_file for m in table.current_snapshot().manifests(table.io) for e in m.fetch_manifest_entry(table.io)]


def t_position_deletes():
    schema = pa.schema([("i", pa.int64()), ("s", pa.string())])
    table = CATALOG.create_table("ns.position_deletes", schema)
    table.append(arrow_table(schema, {"i": [1, 2, 3], "s": ["a", "b", "c"]}))
    table.append(arrow_table(schema, {"i": [4, 5], "s": ["d", "e"]}))
    files = sorted(live_data_files(table), key=lambda f: f.record_count)
    small, large = files[0], files[-1]
    path = f"{table.location()}/data/00000-0-position-deletes.parquet"
    fields = [NestedField(PATH_FIELD_ID, "file_path", StringType(), required=True), NestedField(POS_FIELD_ID, "pos", LongType(), required=True)]
    arrow = pa.Table.from_arrays(
        [pa.array([large.file_path, large.file_path, small.file_path]), pa.array([1, 0, 0], pa.int64())],
        schema=pa.schema(
            [
                pa.field("file_path", pa.string(), nullable=False, metadata={FIELD_ID_KEY: str(PATH_FIELD_ID).encode()}),
                pa.field("pos", pa.int64(), nullable=False, metadata={FIELD_ID_KEY: str(POS_FIELD_ID).encode()}),
            ]
        ),
    )
    write_parquet(path, arrow)
    commit_deletes(table, [delete_data_file(table, path, DataFileContent.POSITION_DELETES, fields, partition=Record())])
    return table


def t_position_deletes_partitioned():
    """A table partitioned by identity on two columns, with a position-delete
    file in one partition: it applies to that partition's two data files —
    and names a path of neither — and not to the other partition's file,
    whatever its sequence number."""
    schema = pa.schema([("k", pa.string()), ("d", pa.date32()), ("i", pa.int64())])
    table = CATALOG.create_table("ns.position_deletes_partitioned", schema)
    with table.update_spec() as update:
        update.add_field("k", IdentityTransform())
        update.add_field("d", IdentityTransform())
    table.append(arrow_table(schema, {"k": ["a", "a"], "d": [day(0), day(0)], "i": [1, 2]}))
    table.append(arrow_table(schema, {"k": ["a"], "d": [day(0)], "i": [3]}))
    table.append(arrow_table(schema, {"k": ["b"], "d": [day(1)], "i": [4]}))
    files = sorted(live_data_files(table), key=lambda f: f.record_count)
    first = files[-1]
    path = f"{table.location()}/data/00000-0-position-deletes.parquet"
    fields = [
        NestedField(PATH_FIELD_ID, "file_path", StringType(), required=True),
        NestedField(POS_FIELD_ID, "pos", LongType(), required=True),
    ]
    arrow = pa.Table.from_arrays(
        [pa.array([first.file_path, f"{table.location()}/data/none.parquet"]), pa.array([0, 0], pa.int64())],
        schema=pa.schema(
            [
                pa.field("file_path", pa.string(), nullable=False, metadata={FIELD_ID_KEY: str(PATH_FIELD_ID).encode()}),
                pa.field("pos", pa.int64(), nullable=False, metadata={FIELD_ID_KEY: str(POS_FIELD_ID).encode()}),
            ]
        ),
    )
    write_parquet(path, arrow)
    commit_deletes(
        table,
        [delete_data_file(table, path, DataFileContent.POSITION_DELETES, fields, partition=Record("a", 0))],
    )
    return table


def t_equality_deletes():
    schema = pa.schema([("i", pa.int64()), ("s", pa.string())])
    table = CATALOG.create_table("ns.equality_deletes", schema)
    table.append(arrow_table(schema, {"i": [1, 2, 3], "s": ["a", "b", "c"]}))
    table.append(arrow_table(schema, {"i": [4, 5], "s": ["d", "e"]}))
    column = table.schema().find_field("i")
    path = f"{table.location()}/data/00000-0-equality-deletes.parquet"
    arrow = pa.Table.from_arrays(
        [pa.array([2, 5], pa.int64())],
        schema=pa.schema([pa.field("i", pa.int64(), nullable=False, metadata={FIELD_ID_KEY: str(column.field_id).encode()})]),
    )
    write_parquet(path, arrow)
    commit_deletes(
        table,
        [delete_data_file(table, path, DataFileContent.EQUALITY_DELETES, [NestedField(column.field_id, "i", LongType(), required=True)], partition=Record(), equality_ids=[column.field_id])],
    )
    return table


def t_version_one():
    schema = pa.schema([("i", pa.int64()), ("s", pa.string())])
    table = CATALOG.create_table("ns.version_one", schema, properties={"format-version": "1"})
    table.append(arrow_table(schema, {"i": [1, 2], "s": ["a", None]}))
    table.append(arrow_table(schema, {"i": [3], "s": ["c"]}))
    return table


def t_version_one_partitioned():
    schema = pa.schema([("k", pa.string()), ("n", pa.int64())])
    table = CATALOG.create_table("ns.version_one_partitioned", schema, properties={"format-version": "1"})
    with table.update_spec() as update:
        update.add_field("k", IdentityTransform())
    table.append(arrow_table(schema, {"k": ["a"], "n": [1]}))
    table.append(arrow_table(schema, {"k": ["b"], "n": [2]}))
    return table


def t_version_three():
    table = CATALOG.create_table("ns.version_three", pa.schema([("i", pa.int64())]))
    table.append(arrow_table(pa.schema([("i", pa.int64())]), {"i": [1, 2]}))
    path = newest_metadata(table.location())
    metadata = json.load(open(path, encoding="utf-8"))
    metadata["format-version"] = 3
    metadata["next-row-id"] = 0
    write_json(path, metadata)
    EXTRA["version_three"] = "the metadata of a version-2 table rewritten as format version 3"
    return load_static(path, table.location(), table.location())


def t_empty():
    return CATALOG.create_table("ns.empty", pa.schema([("i", pa.int64())]))


def t_no_columns():
    # A table of no column at all, created and never written to.
    return CATALOG.create_table("ns.no_columns", pa.schema([]))


def t_no_rows():
    schema = pa.schema([("i", pa.int64())])
    table = CATALOG.create_table("ns.no_rows", schema)
    table.append(arrow_table(schema, {"i": []}))
    return table


def t_all_null():
    schema = pa.schema([("i", pa.int64()), ("s", pa.string()), ("d", pa.date32())])
    table = CATALOG.create_table("ns.all_null", schema)
    table.append(arrow_table(schema, {"i": [None, None, None], "s": [None, None, None], "d": [None, None, None]}))
    return table


LONG_NAME = "n" * 255
LONG_TEXT = "é" * 2000


def t_limits():
    # A column name 255 characters long, a string of 2,000 non-ASCII
    # characters, the empty string, and a name with a blank — partitioned
    # by the short column, whose values stay path-sized.
    schema = pa.schema([("k", pa.string()), (LONG_NAME, pa.string()), ("with space", pa.string())])
    table = CATALOG.create_table("ns.limits", schema)
    with table.update_spec() as update:
        update.add_field("k", IdentityTransform())
    table.append(
        arrow_table(
            schema,
            {
                "k": ["", "b"],
                LONG_NAME: [LONG_TEXT, ""],
                "with space": [" ", "two  spaces"],
            },
        )
    )
    return table


def t_refs():
    schema = pa.schema([("i", pa.int64())])
    table = CATALOG.create_table("ns.refs", schema)
    table.append(arrow_table(schema, {"i": [1]}))
    first = table.current_snapshot().snapshot_id
    table.append(arrow_table(schema, {"i": [2]}))
    table.manage_snapshots().create_tag(first, "tag1").commit()
    table.manage_snapshots().create_branch(first, "audit").commit()
    return table


def t_codec_null():
    schema = pa.schema([("i", pa.int64())])
    table = CATALOG.create_table("ns.codec_null", schema, properties={"write.avro.compression-codec": "null"})
    table.append(arrow_table(schema, {"i": [1]}))
    return table


def t_codec_zstandard():
    schema = pa.schema([("i", pa.int64())])
    table = CATALOG.create_table("ns.codec_zstandard", schema, properties={"write.avro.compression-codec": "zstandard"})
    table.append(arrow_table(schema, {"i": [1]}))
    return table


def t_refused_binary():
    schema = pa.schema([("i", pa.int64()), ("bin", pa.binary())])
    table = CATALOG.create_table("ns.refused_binary", schema)
    table.append(arrow_table(schema, {"i": [1], "bin": [b"\x00\x01"]}))
    return table


def t_refused_map():
    schema = pa.schema([("i", pa.int64()), ("mp", pa.map_(pa.string(), pa.int64()))])
    table = CATALOG.create_table("ns.refused_map", schema)
    table.append(arrow_table(schema, {"i": [1], "mp": pa.array([[("a", 1)]], pa.map_(pa.string(), pa.int64()))}))
    return table


def t_refused_time():
    schema = pa.schema([("i", pa.int64()), ("t", pa.time64("us"))])
    table = CATALOG.create_table("ns.refused_time", schema)
    table.append(arrow_table(schema, {"i": [1], "t": [1_000_000_023]}))
    return table


def t_refused_decimal_38():
    schema = pa.schema([("i", pa.int64()), ("big", pa.decimal128(38, 10))])
    table = CATALOG.create_table("ns.refused_decimal_38", schema)
    table.append(arrow_table(schema, {"i": [1], "big": [decimal.Decimal("1.0000000000")]}))
    return table


def t_refused_default():
    schema = pa.schema([("i", pa.int64())])
    table = CATALOG.create_table("ns.refused_default", schema)
    table.append(arrow_table(schema, {"i": [1]}))
    with table.update_schema() as update:
        update.add_column("label", StringType(), default_value="none")
    table.append(arrow_table(pa.schema([("i", pa.int64()), ("label", pa.string())]), {"i": [2], "label": ["two"]}))
    return table


def t_refused_name_mapping():
    schema = pa.schema([("i", pa.int64()), ("s", pa.string())])
    table = CATALOG.create_table("ns.refused_name_mapping", schema)
    os.makedirs(os.path.join(table.location(), "data"), exist_ok=True)
    path = os.path.join(table.location(), "data", "plain.parquet")
    pq.write_table(pa.table({"i": [1], "s": ["a"]}), path)
    table.add_files([path])
    return table


def t_refused_codec_bzip2():
    schema = pa.schema([("i", pa.int64())])
    table = CATALOG.create_table("ns.refused_codec_bzip2", schema, properties={"write.avro.compression-codec": "bzip2"})
    table.append(arrow_table(schema, {"i": [1]}))
    return table


def t_refused_version_four():
    table = CATALOG.create_table("ns.refused_version_four", pa.schema([("i", pa.int64())]))
    table.append(arrow_table(pa.schema([("i", pa.int64())]), {"i": [1]}))
    path = newest_metadata(table.location())
    metadata = json.load(open(path, encoding="utf-8"))
    metadata["format-version"] = 4
    write_json(path, metadata)
    EXTRA["refused_version_four"] = "the metadata of a version-2 table rewritten as format version 4"
    return None


TABLES = [
    # (name, builder, origin, what the codec answers where it refuses)
    ("append_one", t_append_one, "reference", None),
    ("append_three", t_append_three, "reference", None),
    ("overwrite", t_overwrite, "reference", None),
    ("delete_rows", t_delete_rows, "reference", None),
    ("evolution", t_evolution, "reference", None),
    ("types", t_types, "reference", None),
    ("unicode", t_unicode, "reference", None),
    ("partition_identity", t_partition_identity, "reference", None),
    ("partition_transforms", t_partition_transforms, "reference", None),
    ("partition_scalars", t_partition_scalars, "reference", None),
    ("partition_evolution", t_partition_evolution, "reference", None),
    ("position_deletes", t_position_deletes, "derived", None),
    ("position_deletes_partitioned", t_position_deletes_partitioned, "derived", None),
    ("equality_deletes", t_equality_deletes, "derived", None),
    ("version_one", t_version_one, "reference", None),
    ("version_one_partitioned", t_version_one_partitioned, "reference", None),
    ("version_three", t_version_three, "derived", None),
    ("empty", t_empty, "reference", None),
    ("no_columns", t_no_columns, "reference", None),
    ("no_rows", t_no_rows, "reference", None),
    ("all_null", t_all_null, "reference", None),
    ("limits", t_limits, "reference", None),
    ("refs", t_refs, "reference", None),
    ("codec_null", t_codec_null, "reference", None),
    ("codec_zstandard", t_codec_zstandard, "reference", None),
    ("refused_binary", t_refused_binary, "reference", ("Unsupported", 'iceberg: column "bin": the type binary, which this reader does not carry')),
    ("refused_map", t_refused_map, "reference", ("Unsupported", 'iceberg: column "mp": the type map, which this reader does not carry')),
    ("refused_time", t_refused_time, "reference", ("Unsupported", 'iceberg: column "t": the type time, which this reader does not carry')),
    ("refused_decimal_38", t_refused_decimal_38, "reference", ("Unsupported", "iceberg: column \"big\": decimal(38, 10) holds up to 38 digits, where a Decimal here holds 34")),
    ("refused_default", t_refused_default, "reference", ("Unsupported", 'iceberg: column "label": the initial default "none", which the files written before the column was added do not hold and this reader does not materialise')),
    ("refused_name_mapping", t_refused_name_mapping, "reference", ("Unsupported", "iceberg: the property schema.name-mapping.default maps field ids to the columns of data files that carry none, and this reader does not apply it")),
    ("refused_codec_bzip2", t_refused_codec_bzip2, "reference", None),  # the message names a byte: filled in below
    ("refused_version_four", t_refused_version_four, "derived", ("Unsupported", "iceberg: format version 4, where this reader reads 1 to 3")),
]


def sidecar(name: str, table, origin: str, derived: str | None, refusal, location: str | None) -> dict:
    out = {
        "table": name,
        "origin": origin,
        "writer": f"pyiceberg {pyiceberg.__version__}, pyarrow {pa.__version__}, python {sys.version.split()[0]}",
    }
    if derived:
        out["derived"] = derived
    if name in EXTRA:
        out["derived"] = EXTRA[name]
    if table is None:
        out["reference"] = "refuses the metadata"
        out["codec"] = "refuses"
        out["refusal"] = {"variant": refusal[0], "text": refusal[1], "step": "metadata"}
        return out
    description = describe_table(table)
    out["format_version"] = description["format_version"]
    out["location"] = description["location"]
    out["schema"] = description["schema"]
    out["partition_fields"] = description["partition_fields"]
    out["plan"] = description["plan"]
    # Tables whose files alone do not give the reference's rows: the check
    # below would fail for a reason the codec refuses the table for.
    if name in WALK_DIFFERS:
        out["rows"] = reference_rows(table)
        out["rows_source"] = "the reference's scan, in its order"
        out["walk_differs"] = WALK_DIFFERS[name]
        out["reference"] = "plans and reads"
    else:
        try:
            rows = reference_rows(table)
            walked = plan_rows(table)
            if sorted(map(canonical, rows)) != sorted(map(canonical, walked)):
                raise ValueError(f"{name}: the rows read file by file differ from the reference's own answer")
            out["rows"] = rows
            out["plan_rows"] = walked
            out["rows_source"] = "rows: the reference's scan, in its order; plan_rows: the snapshot's files read one by one in the plan's order with the deletes the reference's plan attaches dropped — equal to rows as a multiset"
            out["reference"] = "plans and reads"
        except ValueError as error:
            if "equality deletes" not in str(error):
                raise
            out["rows"] = None
            out["plan_rows"] = None
            out["rows_source"] = "none: the reference refuses to plan a table that holds an equality-delete file"
            out["reference"] = "refuses to plan (PyIceberg does not yet support equality deletes); reads the list and the manifests"
    if refusal is not None:
        out["codec"] = "refuses"
        out["refusal"] = {
            "variant": refusal[0],
            "text": refusal[1],
            "step": REFUSAL_STEPS.get(name, "metadata"),
        }
    else:
        out["codec"] = "reads"
    return out


# The reading a refused table refuses at: the metadata file itself, unless
# the refusal lies in a file further down the chain.
REFUSAL_STEPS = {"refused_codec_bzip2": "manifest_list"}


def directory_size(path: str) -> int:
    return sum(os.path.getsize(os.path.join(dp, f)) for dp, _, names in os.walk(path) for f in names)


CORPUS_ROOT = os.path.join(".github", "fixtures", "iceberg", "reference")


def carried(name: str, relative: str) -> bool:
    """Whether a table's file, at `relative` under the table, is carried:
    its path from the repository's root stays under `PATH_LIMIT`."""
    return len(os.path.join(CORPUS_ROOT, name, relative)) < PATH_LIMIT


def copy_table(source: str, target: str, name: str) -> list[str]:
    """Copy a table's directory into the corpus, leaving out a data file
    whose path under the repository would be `PATH_LIMIT` characters or
    more: the metadata and the manifests are what the codec reads, and a
    reader of the rows meets the missing file as the I/O error it is.
    Answers the paths left out, relative to the table."""
    not_carried = []
    for directory, _, names in os.walk(source):
        for one in names:
            relative = os.path.relpath(os.path.join(directory, one), source)
            if not carried(name, relative):
                not_carried.append(relative)
    shutil.copytree(
        source,
        target,
        ignore=lambda directory, names: [
            one
            for one in names
            if os.path.relpath(os.path.join(directory, one), source) in not_carried
        ],
    )
    return not_carried


def make() -> int:
    global CATALOG
    for path in (REF, WH):
        if os.path.exists(path):
            shutil.rmtree(path)
    os.makedirs(REF)
    os.makedirs(WH)
    CATALOG = SqlCatalog("fixtures", uri="sqlite:///:memory:", warehouse=WH)
    CATALOG.create_namespace("ns")
    index = {
        "writer": f"pyiceberg {pyiceberg.__version__}, pyarrow {pa.__version__}, python {sys.version.split()[0]}",
        "platform": sys.platform,
        "tables": [],
        "patched": [],
    }
    total_bytes = 0
    for name, builder, origin, refusal in TABLES:
        try:
            table = builder()
        except Exception:  # noqa: BLE001
            traceback.print_exc()
            print(f"FAILED to build {name}")
            return 1
        source = os.path.join(WH, "ns", name)
        target = os.path.join(REF, name)
        not_carried = copy_table(source, target, name)
        location = f"{WH}/ns/{name}"
        if name == "refused_codec_bzip2":
            list_path = newest_metadata(target)
            metadata = json.load(open(list_path, encoding="utf-8"))
            list_file = os.path.join(target, relative(metadata["snapshots"][-1]["manifest-list"], location))
            at = Container(open(list_file, "rb").read()).value_at["avro.codec"]
            refusal = ("ParseError", f'iceberg: byte {at}: the header names the block codec "bzip2", which this reader does not inflate')
        card = sidecar(name, table, origin, None, refusal, location)
        card["not_carried"] = not_carried
        write_json(os.path.join(REF, f"{name}.json"), card)
        index["tables"].append({"name": name, "origin": card["origin"], "codec": card["codec"], "sidecar": f"{name}.json"})
        total_bytes += directory_size(target) + os.path.getsize(os.path.join(REF, f"{name}.json"))
        print(f"wrote {name}: {card['origin']}, codec {card['codec']}, {directory_size(target)} bytes")
    import patched_shapes  # noqa: E402

    patched = patched_shapes.write_all(REF, location_of=lambda n: f"{WH}/ns/{n}")
    index["patched"] = patched
    write_json(os.path.join(REF, INDEX), index)
    # Everything on disk under the corpus, the lists beside the patched
    # manifests and the index included.
    total_bytes = directory_size(REF)
    shutil.rmtree(WH)
    print(f"the corpus: {len(index['tables'])} tables, {len(patched)} patched files, {total_bytes} bytes under {REF}")
    if total_bytes > LIMIT:
        print(f"FAILED: the corpus is over the {LIMIT} byte limit")
        return 1
    return 0


def verify() -> int:
    index = json.load(open(os.path.join(REF, INDEX), encoding="utf-8"))
    mismatches = 0
    tables = 0
    for entry in index["tables"]:
        name = entry["name"]
        card = json.load(open(os.path.join(REF, entry["sidecar"]), encoding="utf-8"))
        target = os.path.join(REF, name)
        if card["reference"] == "refuses the metadata":
            try:
                load_static(newest_metadata(target), card["location"], target)
                print(f"MISMATCH {name}: the reference reads a metadata it refused")
                mismatches += 1
            except Exception:  # noqa: BLE001
                tables += 1
            continue
        table = load_static(newest_metadata(target), card["location"], target)
        again = describe_table(table)
        for key in ("format_version", "location", "schema", "partition_fields", "plan"):
            if canonical(again[key]) != canonical(card[key]):
                print(f"MISMATCH {name}: {key}")
                print("  sidecar:", canonical(card[key])[:400])
                print("  again:  ", canonical(again[key])[:400])
                mismatches += 1
        if card.get("not_carried"):
            print(f"{name}: {len(card['not_carried'])} data file(s) not carried, so its rows are not compared again")
        elif card["rows"] is not None:
            rows = reference_rows(table)
            if canonical(rows) != canonical(card["rows"]):
                print(f"MISMATCH {name}: rows")
                mismatches += 1
        tables += 1
    print(f"reference tables re-read: {tables}; patched files: {len(index['patched'])}; mismatches: {mismatches}")
    return 1 if mismatches else 0


if __name__ == "__main__":
    step = sys.argv[1] if len(sys.argv) > 1 else ""
    if step == "make":
        sys.exit(make())
    elif step == "verify":
        sys.exit(verify())
    print(__doc__)
    sys.exit(2)
