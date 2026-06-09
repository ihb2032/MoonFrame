# Type inference (CSV / JSON / NDJSON)

`read_csv` / `read_json` / `read_ndjson` infer each column's dtype from the
first `infer_schema_rows` rows (default `100`), in the order
`Int → Float → Bool → String`. The per-reader options that tune this
(`infer_schema_rows`, `on_parse_error`, and CSV's `allow_nonfinite_floats`) are
documented with each reader in [`api.md`](api.md); this page explains the rules
those options govern.

## Beyond the inference window

**A non-null cell *beyond* the inference window that does not fit the inferred
dtype is a hard `ParseError` — not a silent fallback to `String`.** A column
that looks numeric in its first rows but holds text later fails loudly rather
than being quietly retyped. For inputs whose type only becomes clear further
down, choose one of:

- raise `infer_schema_rows` — or set it to `0` (or any value `<= 0`) to scan
  *every* row before locking the dtype (Polars' `infer_schema_length=None`);
- build the column with an explicit dtype; or
- set `on_parse_error = OnParseError::Null` to downgrade the offending cell to a
  null while keeping the column's inferred dtype (Polars' `ignore_errors=True`).

## Numeric forms

Numeric parsing follows pandas / polars conventions:

- `0x` / `0o` / `0b` prefixes and `1_000` underscore grouping stay `String` —
  they are *not* read as numbers.
- Integers within the `Int64` range stay `Int`; a value that overflows `Int64`
  is promoted to `Float`, not silently truncated.
- `nan` / `inf` / `infinity` tokens are accepted as `Float` by default. CSV's
  `allow_nonfinite_floats = false` rejects them during inference, so a column of
  such tokens falls back to `String` instead of being read as `Float`.
