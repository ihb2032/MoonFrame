# Type inference (CSV / JSON / NDJSON)

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

The three readers agree on the priority order and the window, but not on what a
number *looks like* — a CSV cell is text the reader parses, while a JSON or
NDJSON value arrives already typed from a standards-conformant parser. So the
numeric rules are per-format.

### CSV tokens

Token parsing follows pandas / polars conventions:

- `0x` / `0o` / `0b` prefixes and `1_000` underscore grouping stay `String` —
  they are *not* read as numbers.
- Integers within the `Int64` range stay `Int`; a value that overflows `Int64`
  is promoted to `Float`, not silently truncated.
- `nan` / `inf` / `infinity` tokens — and a finite literal beyond the `Double`
  range, which collapses to `±Inf` per IEEE 754 (e.g. `1e999`) — are accepted as
  `Float` by default. `allow_nonfinite_floats = false` rejects them during
  inference, so a column of such tokens falls back to `String` instead of being
  read as `Float`.

### JSON / NDJSON numbers

Standard JSON has a single number type and no `nan` / `inf` / `infinity`
literals, so those rules do not carry over:

- a bare `NaN` / `Infinity` token is a *parse* failure, not a `Float` cell.
  There is no `allow_nonfinite_floats` on `JsonReadOptions` because there is
  nothing for it to accept, and `write_json` / `write_ndjson` write a non-finite
  cell as JSON `null` (pandas' `to_json` convention) — so it reads back as a
  null, not as `±Inf`.
- an integer within `Int64`'s range round-trips exactly even past 2^53: the
  writer records its verbatim digits alongside the number and the reader recovers
  them. Only a JSON integer beyond `Int64`'s own range infers `Float`.
- a whole-valued `Float` (`2.0`) is written `2` and re-infers as `Int`. This is
  the one direction CSV keeps that JSON cannot: the text `"2.0"` still carries a
  decimal point, and a JSON number does not.
