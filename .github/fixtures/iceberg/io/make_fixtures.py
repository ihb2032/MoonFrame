"""Make the Parquet files the reading of a table's rows is checked against,
each a shape the reference's writer never writes: a position-delete file
whose cells are of the wrong kind, and a data file lacking a column the
table holds. Their schema elements name field ids, as the reference's
files do.

    uv run --no-project --with pyarrow python make_fixtures.py
"""
from datetime import date

from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

HERE = Path(__file__).resolve().parent

# The key a table format's writer spells an id under, which the Parquet
# writer moves onto the schema element.
FIELD_ID = "PARQUET:field_id"
DELETE_PATH_ID = 2147483546
DELETE_POSITION_ID = 2147483545


def write(name, schema, columns):
    pq.write_table(pa.table(columns, schema=schema), HERE / name, compression="none")


def field(name, kind, field_id):
    return pa.field(name, kind, nullable=True, metadata={FIELD_ID: str(field_id)})


def bad_deletes():
    """A delete file whose path column is a whole number, and one whose
    position column is a text."""
    write(
        "delete_path_int.parquet",
        pa.schema([field("file_path", pa.int64(), DELETE_PATH_ID), field("pos", pa.int64(), DELETE_POSITION_ID)]),
        {"file_path": pa.array([0], pa.int64()), "pos": pa.array([0], pa.int64())},
    )
    write(
        "delete_position_text.parquet",
        pa.schema([field("file_path", pa.string(), DELETE_PATH_ID), field("pos", pa.string(), DELETE_POSITION_ID)]),
        {"file_path": pa.array(["none"], pa.string()), "pos": pa.array(["0"], pa.string())},
    )


def data_lacking_a_column():
    """A data file of the partitioned table without its partition column
    `k` (ids 2 and 3 only, one row), and one of the Unicode table without
    its third column (ids 1 and 2, three rows)."""
    write(
        "data_without_k.parquet",
        pa.schema([field("d", pa.date32(), 2), field("i", pa.int64(), 3)]),
        {"d": pa.array([date(1970, 1, 2)], pa.date32()), "i": pa.array([4], pa.int64())},
    )
    write(
        "data_without_third.parquet",
        pa.schema([field("a", pa.string(), 1), field("b", pa.string(), 2)]),
        {"a": pa.array(["x", None, "z"], pa.string()), "b": pa.array(["1", "2", None], pa.string())},
    )


def main():
    bad_deletes()
    data_lacking_a_column()


if __name__ == "__main__":
    main()
