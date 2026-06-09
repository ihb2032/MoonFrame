# Changelog

Version-by-version feature history for MoonFrame, newest first. The
authoritative public-API reference is [`api.md`](api.md); the source-level
breaking-change steps for each release are collected in
[`migration.md`](migration.md). Pre-1.0, breaking changes ride the minor
version.

## v0.3 — shipped

Output formats, the full join matrix, read resilience, and a pluggable
column-storage backend, all on top of the v0.2 method-chain core. The
source-level upgrade steps are in [`migration.md`](migration.md).

### HTML rendering (output format)

`df.to_html()` renders a `<table>` — a `<thead>` header over a `<tbody>` of
rows, with a null cell rendered as `<td></td>` — and
`df.to_html_with_options(...)` adds a CSS `class`, a `<caption>`, and (via
`HtmlOptions::with_max_rows`) a row cap with a `<tfoot>` `... (K more rows)`
banner. Header and cell text is HTML-escaped (`&` / `<` / `>` / `"`) by
default; `with_escape(false)` passes trusted markup through. Like
`to_markdown`, it is a pure, dependency-free `DataFrame` method (the IO-1
boundary keeps rendering in `frame`).

### Vega-Lite chart export (output format)

`format_vega_lite(df, ChartSpec::bar("region", "revenue"))` emits a complete
[Vega-Lite v5](https://vega.github.io/vega-lite/) specification — `$schema` +
optional `title` + `mark` + `encoding` + an inline `data.values` array — as a
JSON string you can paste straight into the
[Vega editor](https://vega.github.io/editor/) or feed to any Vega-Lite runtime.
`ChartSpec::bar` / `line` / `point` / `area` choose the mark; `with_color` adds
a grouping column and `with_title` a heading; each channel's field `type` is
inferred from the column dtype (numeric → `quantitative`, else `nominal`), and
cells follow the JSON-records conventions (null / non-finite floats → JSON
`null`). Being an `io` serialiser (parallel to `format_json_records`), a spec
that names a missing column raises `ColumnNotFound`; `write_vega_lite` is the
file wrapper.

### Join matrix completed — Right / Outer

`JoinType` gained `Right` / `Outer`, so the matrix is now the full
`inner` / `left` / `right` / `outer` / `cross`. `left.inner_join(right, ["id"])`,
`.left_join` / `.right_join` / `.outer_join`, or the configurable
`left.join(right, JoinOptions::on(["id"]).with_how(Outer).with_coalesce(true))`
do a hash equi-join with Polars-aligned semantics: a **null** key matches
nothing (`null != null`, as in SQL / Polars), a `NaN` key matches other NaNs,
the right-column collision suffix defaults to `"_right"`, and key columns are
coalesced on an inner join but kept (the right as `id_right`) on a
left / right / outer join — `coalesce` defaults to Polars' per-`how` rule and is
overridable via `with_coalesce` (a coalesced key takes each row's value from
whichever side is present: the left for `inner` / `left`, the right for `right`,
the present side per row for `outer`). Output is the left columns then the right
columns, rows in deterministic order. `left.cross_join(right)`
(`JoinType::Cross`) gives the keyless Cartesian product.

### CSV / JSON / NDJSON read resilience

All three readers' option structs gained escape hatches for messy inputs.
`infer_schema_rows = 0` (or any value `<= 0`) now scans *every* row rather than
a leading window (Polars' `infer_schema_length=None`), so a dtype that only
resolves deep in the data is inferred instead of guessed from a prefix.
`on_parse_error` (`OnParseError::Raise`, the default, or `Null`) chooses what
happens when a non-null cell past the inference window doesn't fit its column's
locked-in dtype: fail the whole read with `ParseError` (lossless) or downgrade
that one cell to a null and keep going (Polars' `ignore_errors=True`), with the
column keeping its inferred dtype. CSV additionally gains
`allow_nonfinite_floats` (default `true`): set it `false` to stop a column of
`nan` / `inf` / `infinity` tokens from being silently inferred as `Float`,
falling back to `String` instead. These are `pub(all)` struct field additions —
see [`migration.md`](migration.md).

### Pluggable column storage (engineering depth)

A `Series` now holds a `ColumnStorage` — a closed `{ Builtin; Numeric }` seam —
instead of a bare `BuiltinColumn`. `Builtin` is the general-purpose Arrow column
(any dtype, nullable); `Numeric` is an all-valid, unboxed `Int64` / `Double`
column that carries **no validity bitmap**, so it skips the bitmap allocation on
construction and the per-slot validity check in its reductions (the
`null_count == 0` fast path). The no-null `Series::from_ints` / `from_floats`
build `Numeric` automatically, and structural transforms (`slice` / `take` /
`drop_nulls` / `head` / `tail` / `filter` / `sort_by`) keep a column on the fast
path. `storage_kind()` reports the backend; `to_numeric()` / `to_builtin()` move
between them (per-column on a `Series`, whole-frame on a `DataFrame`) — a
lossless representation swap that leaves names, dtypes, and values unchanged.

## v0.2 — method-chain migration

The whole v0.1 surface moved to the method-chain + `raise` form (see
[`migration.md`](migration.md) for the call-site changes).

- The operator verbs (`select` / `drop` / `rename` / `with_column` /
  `replace_column` / `filter` / `sort_by` / `drop_nulls` / `drop_nulls_in` /
  `fill_null` / `null_count` / `count` / `sum` / `mean` / `min` / `max` /
  `describe`) became **methods on `DataFrame`**; the old `ops` package folded
  into `frame`.
- Every fallible operation returns `T raise DataError` instead of
  `Result[T, DataError]`.
- `filter` takes a single `(RowView) -> Bool raise DataError` predicate (the
  v0.1 `filter` / `filter_try` split is gone — a fallible accessor in the
  predicate just raises).
- `sort_by` takes an `Array[(column, SortOrder, NullOrder)]`; multi-key sort
  falls out of listing several tuples (`sort_by_many`, the `SortSpec` struct,
  and the `IntoSortSpecs` trait are all gone).
- `to_markdown` / `to_markdown_with_limit` are `DataFrame` methods; the
  CSV / JSON string serialisers (`format_csv_str` / `format_json_records`) stay
  as `io` free functions.

**GroupBy.** `df.group_by(keys).agg([AggSpec::sum("x"), AggSpec::mean("y"), ...])`
returns a one-row-per-group summary with `Count` / `Sum` / `Mean` / `Min` /
`Max` reductions (reusing the `Series` statistics, with Polars-aligned `NaN`
rules: a `NaN` propagates through `Sum` / `Mean` but is skipped by `Min` /
`Max`), optional per-column aliases via `with_alias`, deterministic
first-appearance group order (Polars' `maintain_order=True`), and null keys kept
as their own group.

**Join (inner / left / cross).** The hash equi-join landed with the
`inner` / `left` / `cross` cases; the `right` / `outer` completion came in v0.3
(see the v0.3 entry above for the full semantics).

**NDJSON I/O.** `read_ndjson` / `write_ndjson` (and the string-level
`parse_ndjson_str` / `format_ndjson`) read and write the JSON Lines format — one
JSON object per line — reusing the JSON-records type inference and
`scalar_to_json` cell conventions. Reading is lenient (blank lines skipped, CRLF
tolerated); writing emits one compact object per row, each terminated by `\n`.

## v0.1 — foundation

The initial column-oriented core: an Apache Arrow-style column layout
(byte-packed validity `Bitmap`, `1 = valid`) under `Series` / `DataFrame`, an
`O(1)` `name_to_index` cache, `DataFrame::check_invariants()` as a formal
structural spec (INV1–INV7) asserted by every operator test, and the first
CSV / JSON readers with `Int → Float → Bool → String` type inference (see
[`type-inference.md`](type-inference.md)).
