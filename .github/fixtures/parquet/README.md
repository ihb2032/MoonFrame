# Parquet files

The one Parquet file a reading of the library's own writer cannot produce:
`field_ids.parquet`, whose schema elements each name a field id — what a
table format laid over Parquet files identifies a column by, and what the
library's writer leaves out. One of its columns names no id, for the
`-1` a reader answers there.

To regenerate it:

```sh
uv run --with pyarrow python make_fixtures.py
```

The rest of the Parquet codec is checked by round-trips through the
library's own writer and by hand-built bytes, under `internal/parquet`.
