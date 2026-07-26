# Type inference (CSV / JSON / NDJSON)

> Documents the unreleased v0.6 API; `moon add` installs the published
> v0.5.8, whose reference is on mooncakes.io. See [Install](../README.md#install).

`read_csv` / `read_json` / `read_ndjson` infer each column's dtype from the
first `infer_schema_rows` rows (default `100`), in the order
`Int → Float → Bool → String`. The per-reader options that tune this
(`infer_schema_rows`, `on_parse_error`, and CSV's `allow_nonfinite_floats`) are
documented with each reader on
[mooncakes.io](https://mooncakes.io/docs/ihb2032/MoonFrame); this page explains
the rules those options govern.

## An all-null window infers `String`

The four dtypes above are the whole range: a reader never infers
`DataType::Null`. When every cell in the probe window is empty (or a
`null_values` token, or `null` in JSON) there is nothing to type the column
from, so it lands on `String` — the dtype that accepts whatever the rows past
the window turn out to hold, rather than one that would reject them.

```
id,note
1,
2,
3,filled in later
```

With the default window this reads `note` as a `String` column: null, null,
`"filled in later"`. The consequence worth knowing is the one below — a column
typed this way accepts any later cell, where a column inferred as `Int` from
its first rows does not.

## Beyond the inference window

**A non-null cell *beyond* the inference window that does not fit the inferred
dtype is a hard `ParseError` — not a silent fallback to `String`.** A column
that looks numeric in its first rows but holds text later fails loudly rather
than being quietly retyped. For inputs whose type only becomes clear further
down, choose one of:

- raise `infer_schema_rows` — or set it to `0` (or any value `<= 0`) to scan
  *every* row before locking the dtype (Polars' `infer_schema_length=None`);
- set `on_parse_error = OnParseError::Null` to downgrade the offending cell to a
  null while keeping the column's inferred dtype (Polars' `ignore_errors=True`);
  or
- convert after the read — `df.with_columns([col("x").cast(DataType::Float)])`
  turns whatever was inferred into the dtype you want (a cell that cannot
  convert raises).

There is no schema-override parameter on the readers: no `dtypes=` / `schema=`,
so inference is the only thing that assigns a dtype on the way in. When a frame
must be built to a declared schema instead, construct it directly —
`Series::from_*` per column, or `DataFrame::from_rows(schema, rows)`, which
validates the cells against the schema you pass.

## Numeric forms

Numeric parsing follows pandas / polars conventions:

- `0x` / `0o` / `0b` prefixes and `1_000` underscore grouping stay `String` —
  they are *not* read as numbers.
- Integers within the `Int64` range stay `Int`; a value that overflows `Int64`
  is promoted to `Float`, not silently truncated.
- `nan` / `inf` / `infinity` tokens — and a finite literal beyond the `Double`
  range, which collapses to `±Inf` per IEEE 754 (e.g. `1e999`) — are accepted as
  `Float` by default. CSV's `allow_nonfinite_floats = false` rejects them during
  inference, so a column of such tokens falls back to `String` instead of being
  read as `Float`.
