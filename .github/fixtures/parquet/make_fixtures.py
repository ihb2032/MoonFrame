"""Make the Parquet file the field-id reading is checked against.

Its schema elements each name a field id, the way a table format laid over
Parquet files writes them, with one column left without an id.

    uv run --no-project --with pyarrow python make_fixtures.py
"""
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

HERE = Path(__file__).resolve().parent

# The key a table format's writer spells an id under, which the Parquet
# writer moves onto the schema element.
FIELD_ID = "PARQUET:field_id"


def field_ids():
    """Three columns: two under a field id, one without."""
    schema = pa.schema(
        [
            pa.field("i", pa.int64(), nullable=True, metadata={FIELD_ID: "1"}),
            pa.field("s", pa.string(), nullable=True, metadata={FIELD_ID: "2"}),
            pa.field("plain", pa.int64(), nullable=True),
        ]
    )
    table = pa.table(
        {"i": [1, 2, 3], "s": ["a", None, "c"], "plain": [7, 8, 9]}, schema=schema
    )
    pq.write_table(table, HERE / "field_ids.parquet", compression="none")


def main():
    field_ids()


if __name__ == "__main__":
    main()
