# MoonFrame v0.2 — Public API

> Status: **method-chain migration shipped**. This document is the
> source of truth for the v0.2 public surface. When a symbol is
> published in code, it must appear here.

The facade package `ihb2032/MoonFrame` re-exports every symbol below
via `pub using @<subpkg> { ... }`, so a single
`import "ihb2032/MoonFrame" @moonframe` is enough to reach the whole
surface. Sub-package imports (`@types`, `@column`, `@frame`, `@io`)
remain supported for callers that only need a slice — the facade is
additive.

Runnable, CI-verified examples of the surface below live in
[`quickstart.mbt.md`](../quickstart.mbt.md) (doc tests executed by `moon test`
on every backend).

## Error model (v0.2)

Every operation that can fail on bad input or I/O is an effectful
function with signature `... -> T raise DataError`. There is no
`Result` wrapping on fallible verbs and no hidden `unwrap` / `abort`.

- **In a `raise` context** (another `... raise DataError` function, or a
  `test { ... }` block) call the method directly; an uncaught error
  propagates.
- **Bridge to a value** with `try?`: `let r : Result[DataFrame, DataError]
  = try? read_csv(path)`. Match on `r` to inspect the error.
- **Handle inline** with `try expr catch { e => ... }`.

Provably-total operations (`head` / `tail` / `Series::min_value` /
`drop_nulls` / `to_markdown` / `to_html` / the inspection accessors / …)
return their value directly and never raise.

The one deliberate exception is `DataFrame::check_invariants()`, which
keeps its `Result[Unit, String]` shape — it is a verification /
diagnostic affordance (its error is a `String` describing the first
violated invariant), not a data transform.

### v0.1 → v0.2 migration

- `@ops.op(df, args)` (free function) → `df.op(args)` (method); the
  `ops` package is folded into `frame`.
- `op(...) -> Result[T, DataError]` + `.bind` / `.map` / `.unwrap` →
  `op(...) -> T raise DataError`, chained directly; use `try?` to land a
  `Result`.
- `filter` + `filter_try` → a single `filter(self, (RowView) -> Bool
  raise DataError)`.
- `sort_by` + `sort_by_many` → a single
  `sort_by(self, keys : Array[(String, SortOrder, NullOrder)])`; multi-key
  sort is just a longer tuple list.
- `Series::min()` / `max()` (`Result`-wrapped) removed → `min_value()` /
  `max_value()` (total, return `Scalar`).
- `to_markdown(df)` / `to_markdown_with_limit(df, n)` → `df.to_markdown()`
  / `df.to_markdown_with_limit(n)` (now `DataFrame` methods).
- `enum DataError` → `pub(all) suberror DataError` (same variants,
  `message()`, and `Show`).

---

## `types` — Value types and errors

- `suberror DataError` — `pub(all) suberror` with 10 variants:
  `ColumnNotFound` / `DuplicateColumn` / `TypeMismatch` / `LengthMismatch` /
  `IndexOutOfBounds` / `ParseError` / `InvalidOperation` / `IoError` /
  `EmptyDataFrame` / `Unsupported`. As a `suberror` it is both raised
  (`raise ColumnNotFound("age")`) and recovered (`try? expr` →
  `Result[_, DataError]`); `pub(all)` lets callers construct and match
  variants. `DataError::message()` renders a human-readable description;
  the `Show` impl renders the variant form for assertion snapshots.
- `enum DataType` — `Int | Float | Bool | String | Null`, with
  `is_numeric` / `is_integer` / `is_float` / `is_string` / `is_bool`.
- `enum Scalar` — cell value (`Int` carries `Int64`, `Float` carries
  `Double`). Total: `dtype` / `is_null` / `to_string` (value form, e.g.
  `Int(42) → "42"`, `Null → ""`). Fallible (`raise DataError`):
  `as_int` / `as_float` / `as_bool` / `as_string` and the comparisons
  `eq` / `lt` / `lte` / `gt` / `gte`, which return `Bool` and
  `raise TypeMismatch` when either side is `Null` or the dtypes are
  incomparable. `as_float` promotes `Int`; mixed numeric comparisons
  promote `Int` to `Double`. `String` comparisons use lexicographic
  order (see `compare_string_lex`), **not** the built-in shortlex `<`.
- `fn compare_string_lex(a, b) -> Int` — lexicographic string comparison
  by UTF-16 code unit (`-1` / `0` / `1`). Every user-facing ordering
  (`Scalar::lt`, `Series::min_value` / `max_value`, `DataFrame::sort_by`)
  routes through this so they all agree.
- `fn is_decimal_int_literal(s) -> Bool` — `true` when `s` is an optional
  `+` / `-` sign followed by ASCII digits and nothing else (rejects
  `0x` / `0o` / `0b` prefixes and `1_000` underscore grouping). The
  CSV / JSON readers' type inference and the `@column` String→`Int` cast
  both route through this predicate so they agree on what counts as an
  integer literal.
- `struct Field` — column metadata: `name`, `dtype`, `nullable`. Total
  constructors `Field::new(name, dtype)` (defaults `nullable = true`)
  and `Field::with_nullable(name, dtype, nullable)`; accessors `name` /
  `dtype` / `nullable`; `rename(new_name)` returns a renamed copy.
- `struct Schema` — ordered list of `Field`s with duplicate-name
  detection.
  - `Schema::new(fields) -> Schema raise DataError` —
    `raise DuplicateColumn(name)` on the first repeated name. Empty is
    valid.
  - Total inspection: `fields` / `field_names` / `len` / `is_empty`.
  - `index_of(name) -> Int raise DataError` and
    `field(name) -> Field raise DataError` `raise ColumnNotFound`;
    `field_at(i) -> Field raise DataError` `raise IndexOutOfBounds`.
  - `select(names) -> Schema raise DataError` — project a sub-schema in
    `names` order. Missing → `ColumnNotFound`; duplicate in the pick
    list → `DuplicateColumn`.
  - `rename(old_name, new_name) -> Schema raise DataError` —
    `ColumnNotFound` if `old_name` missing; `DuplicateColumn` if
    `new_name` collides. `(name, name)` is a no-op that still validates
    existence.

---

## `column` — Column storage backends

Apache Arrow style: a raw data buffer plus a separate bit-packed
validity bitmap (`1 = valid`, `0 = null`).

### Validity bitmap

- `struct Bitmap { bits : Bytes, len : Int }` — byte-packed at 1 bit per
  row, `1 = valid`. Slot `i` lives in `bits[i / 8]` at bit `i % 8` (LSB
  first); a bitmap of `len` slots occupies exactly `⌈len / 8⌉` bytes.
  Note: some MoonBit ecosystem libraries (e.g. `smallbearrr/pandas`) use
  the **opposite** convention (`true = null`).
- Total constructors: `all_valid(len)` / `all_null(len)` /
  `from_bools(Array[Bool])` (`true ↦ valid`) /
  `from_options[T](Array[T?])` (`Some(_) ↦ valid`).
- Total inspection: `len` / `null_count()` / `to_bools()` (materialise
  the whole `true = valid` mask in one pass — the total counterpart to
  `is_valid` for bounded scans).
- Fallible (`raise DataError`): `is_valid(i)` / `is_null(i)`
  (`raise IndexOutOfBounds` outside `[0, len)`); `slice(start, length)`
  (`IndexOutOfBounds` / `InvalidOperation` on bad bounds); `take(indices)`
  (`IndexOutOfBounds` on the first bad index); `bit_and(other)`
  (`LengthMismatch` if lengths differ — `and` is a reserved keyword,
  hence `bit_and`).

### BuiltinColumn

- `struct BuiltinColumn { data : ColumnData, validity : Bitmap }` —
  Arrow-style column; null slots in `data` carry a per-dtype placeholder
  (`Int = 0`, `Float = 0.0`, `Bool = false`, `String = ""`) that never
  leaks because every read consults `validity` first.
- `pub(all) enum ColumnData` — `Int(Array[Int64]) | Float(Array[Double]) |
  Bool(Array[Bool]) | String(Array[String])`. Numeric columns are 64-bit.
- Total constructors (8): `from_ints` / `from_int_options` /
  `from_floats` / `from_float_options` / `from_bools` /
  `from_bool_options` / `from_strings` / `from_string_options`.
- Total inspection: `dtype` / `len` / `is_empty` / `null_count` /
  `data() -> ColumnData` / `validity() -> Bitmap`. The `data()` /
  `validity()` accessors expose the raw backing so callers in other
  packages match `ColumnData` once and read values / validity totally,
  instead of cascading through `*_values`.
- Fallible (`raise DataError`):
  - `is_null(i) -> Bool` / `get(i) -> Scalar` —
    `raise IndexOutOfBounds` outside `[0, len)`; `get` returns
    `Scalar::Null` for null slots.
  - `slice(start, end)` / `take(indices)` — sub-views; same bounds
    diagnostics as the bitmap.
  - `cast(target)` dispatches to `to_int` / `to_float` /
    `to_string_column`; `Bool` / `Null` targets `raise Unsupported`.
  - `to_int()` — identity on Int; Float truncates toward zero (`NaN`,
    `±Inf`, out-of-`Int64`-range → `ParseError`); Bool `true → 1`,
    `false → 0`; String accepts only plain base-10 integers (others →
    `ParseError`). Validity preserved.
  - `to_float()` — Int promoted; identity on Float; Bool → `1.0` /
    `0.0`; String parsed (`1_000` underscore grouping rejected; `inf` /
    `-inf` / `nan` accepted; other malformed → `ParseError`).
  - `int_values()` / `float_values()` / `bool_values()` /
    `string_values()` — return `(Array[T], Bitmap)`; wrong dtype →
    `raise TypeMismatch`. Always consult the returned bitmap before
    reading the data array.
- **Total** (no failure path): `to_string_column() -> BuiltinColumn` —
  every dtype has a value-form rendering, so unlike `to_int` / `to_float`
  it never raises.

---

## `frame` — Series, DataFrame, RowView, and operators

The `ops` verbs are folded in here as `DataFrame` methods (one operator
per file), so a pipeline is a method chain. `frame` has **zero external
dependencies** (NyaCSV / fs / @json live only in `io`).

### Series

- `struct Series { name, storage : @column.BuiltinColumn }`.
- Total constructors (10): `new` / `from_builtin` / `from_ints` /
  `from_int_options` / `from_floats` / `from_float_options` /
  `from_bools` / `from_bool_options` / `from_strings` /
  `from_string_options`.
- Total inspection: `name` / `dtype` / `len` / `is_empty` /
  `null_count` / `null_rate` (`0.0` for an empty series) / `storage` /
  `to_scalars() -> Array[Scalar]` (materialise every cell, `Null` for
  null cells).
- Fallible (`raise DataError`): `is_null(i) -> Bool` / `get(i) -> Scalar`
  (`IndexOutOfBounds`); `slice(start, end)` / `take(indices)`;
  `fill_null(value)` (`TypeMismatch` for `Scalar::Null` or a
  dtype-mismatched value); `cast(target)` / `to_int()` / `to_float()`.
- Total transforms: `rename(new_name)` (`O(1)`, storage shared);
  `drop_nulls()` (gather non-null cells); `to_string_series()` (every
  dtype renders, so total).

### Series stats (`series_stats.mbt`)

- Total: `count()` (non-null count); `unique_count()` (distinct non-null
  values keyed by `Scalar::to_string`, so all `Float` NaN collapse to one
  bucket); `min_value()` / `max_value()` — the reduction proper,
  returning a `Scalar` directly (every v0.1 dtype has an order, so they
  never fail; empty / all-null / all-NaN → `Scalar::Null`; `String` uses
  lexicographic order; `Bool` is `false < true`).
- Fallible (`raise DataError`): `sum()` — `Int` / `Float` →
  `Scalar::Int` / `Scalar::Float`, empty / all-null is the additive
  identity, `Bool` / `String` → `TypeMismatch`; `mean()` — `Double`,
  empty / all-null numeric → `InvalidOperation`, non-numeric →
  `TypeMismatch`; `describe() -> DataFrame` — one-row six-column summary
  (`count` / `null_count` / `unique_count` / `mean` / `min` / `max`),
  raising only because it builds through `DataFrame::new` (always
  succeeds in practice). `Float` `NaN` is a value, not missing: it
  **propagates** through `sum` / `mean` (any non-null `NaN` ⇒ `NaN`) but is
  **skipped** by `min_value` / `max_value` (and `sort_by`) — matching
  Polars, whose `sum`/`mean` propagate `NaN` while its regular `min`/`max`
  ignore it (only `Null` is ever treated as missing).

### DataFrame

- `struct DataFrame` — column-oriented table; fields private outside the
  package (`schema`, `columns`, `nrows`, private `name_to_index` cache
  for `O(1)` name lookup).
- Constructors (`raise DataError`): `new(columns)`
  (`LengthMismatch` / `DuplicateColumn`; zero columns → `0×0`);
  `empty(schema)` (0-row frame; `Unsupported` for a `Null`-dtype field);
  `from_rows(schema, rows)` (`LengthMismatch` / `TypeMismatch` /
  `Unsupported`; zero-column schema → `0×0`, like `new`).
- Total inspection: `shape()` / `schema()` / `columns()` (fresh array) /
  `column_series()` (fresh array of the immutable `Series`) / `nrows()` /
  `ncols()` / `is_empty()`.
- Accessors (`raise DataError`): `get_column(name)`
  (`ColumnNotFound`); `get_column_at(i)` (`IndexOutOfBounds`);
  `get(row, name) -> Scalar`; `row(i) -> RowView` (`IndexOutOfBounds`).
  Total: `row_view(i)` (defers the bounds check to the accessors).
- Structural transforms: total `head(n)` / `tail(n)` (clamp `n` to
  `[0, nrows]`); `slice(start, end)` / `take(indices)` (`raise`,
  `IndexOutOfBounds` / `InvalidOperation`).
- `check_invariants() -> Result[Unit, String]` — verification helper
  (deliberately **not** migrated to `raise`). `Ok(())` iff the frame
  satisfies its seven structural invariants; otherwise `Err(msg)`.

### DataFrame operator methods (folded-in `ops`)

All route their result through invariant-preserving constructors /
transforms, so every output satisfies `check_invariants()`.

- `select(names) -> DataFrame raise DataError` — project columns in
  `names` order. `ColumnNotFound` (missing) / `DuplicateColumn` (repeat).
- `drop(names) -> DataFrame raise DataError` — remove named columns,
  order preserved; duplicates in `names` idempotent; `ColumnNotFound` on
  the first unknown.
- `rename(mapping : Array[(String, String)]) -> DataFrame raise DataError`
  — apply renames in order (each step's `new_name` is visible to later
  steps, enabling a 3-step swap). `ColumnNotFound` / `DuplicateColumn`.
- `with_column(series) -> DataFrame raise DataError` — append rightmost.
  `DuplicateColumn` / `LengthMismatch`.
- `replace_column(name, series) -> DataFrame raise DataError` —
  positional in-place swap; the target `name` wins over `series.name()`;
  cross-dtype allowed. `ColumnNotFound` / `LengthMismatch`.
- `filter(predicate : (RowView) -> Bool raise DataError) -> DataFrame
  raise DataError` — keep rows where `predicate` is `true`. The predicate
  may raise (a typed `RowView` accessor surfaces `ColumnNotFound` /
  `TypeMismatch`); the first raise short-circuits the scan. Schema
  preserved verbatim; the predicate is not invoked on a 0-row frame.
- `sort_by(keys : Array[(String, SortOrder, NullOrder)]) -> DataFrame raise
  DataError` — stable multi-key sort. Each key is a
  `(column, order, null_order)` tuple; earlier keys dominate. A single-key
  sort passes a one-element array. `ColumnNotFound` on the first unknown key
  column. Empty key set is the identity.
- `drop_nulls() -> DataFrame raise DataError` — drop rows null in **any**
  column. `drop_nulls_in(names) -> DataFrame raise DataError` — gate only
  on the listed columns (`ColumnNotFound` on the first unknown; empty
  list is identity; duplicates idempotent).
- `fill_null(column, value) -> DataFrame raise DataError` — replace nulls
  in `column`; dtype-preserving. `ColumnNotFound` (checked first) /
  `TypeMismatch`.
- `null_count() -> DataFrame raise DataError` — `1 × ncols` `Int`
  summary; 0-column collapses to `0×0`.
- `count(column) -> Int raise DataError` / `sum(column) -> Scalar raise
  DataError` / `mean(column) -> Double raise DataError` /
  `min(column) -> Scalar raise DataError` / `max(column) -> Scalar raise
  DataError` — per-column reductions delegating to the matching `Series`
  stat; the only added failure beyond the Series rules is
  `ColumnNotFound`. `min` / `max` return `Scalar::Null` on empty /
  all-null.
- `describe() -> DataFrame raise DataError` — per-column summary, one row
  per source column, fixed `N × 8` schema (`column` / `dtype` / `count` /
  `null_count` / `unique_count` (`Int`); `mean` (`Float`, nullable);
  `min` / `max` (`String`, nullable, rendered via `Scalar::to_string`)).
  0-column collapses to `0 × 8`.
- `to_markdown() -> String` / `to_markdown_with_limit(limit) -> String`
  — **total** GitHub-flavored pipe-table renderers (IO-1: pure rendering
  lives in `frame`). Column widths align to `max(header, cells)` with a
  3-char minimum; null cells render empty; `|` / `\` / CR / LF are
  GFM-escaped. `with_limit` appends `... (N more rows)` when truncated
  (negative `limit` clamps to 0).
- `to_html() -> String` / `to_html_with_options(options : HtmlOptions) ->
  String` — **total** HTML `<table>` renderers (IO-1: pure rendering lives
  in `frame`, parallel to `to_markdown`). `to_html` emits a `<thead>` +
  `<tbody>`, one `<td>` per cell in declaration order; a null cell renders
  as `<td></td>`; `&` / `<` / `>` / `"` are escaped to HTML entities.
  0 columns → empty string; N columns / 0 rows → header + empty `<tbody>`.
  `to_html_with_options` adds a `class` / `<caption>` and, via `max_rows`,
  a row cap with a `<tfoot>` `... (K more rows)` banner (negative
  `max_rows` clamps to 0).
- `struct HtmlOptions` (fields private) — built via `HtmlOptions::default()`
  (all rows, no `class` / `caption`, `escape = true`) and chained
  `with_max_rows(n)` / `with_table_class(cls)` / `with_caption(text)` /
  `with_escape(flag)`. `with_escape(false)` emits caption / header / cell
  / class strings verbatim, for trusted input that intentionally carries
  HTML.

### GroupBy (`group_by` / `agg`)

Split-apply-combine, native to the method chain
(`df.group_by(keys).agg(specs)`).

- `group_by(keys : Array[String]) -> GroupedDataFrame raise DataError` —
  partition the frame by one or more key columns. Group order is **first
  appearance** (equivalent to Polars' `maintain_order=True`), so the result
  is deterministic. Group identity is the composite of each key cell's
  `Scalar::to_string` (the canonical value form `unique_count` keys on), so
  a `Float` `NaN` collapses all NaNs into one group (Polars treats `NaN` as
  equal for grouping), and a **null** key forms its **own** group rather
  than being dropped (the Polars default — pandas drops null keys — and the
  deliberate difference from `join`, where `null` matches nothing). One key
  or several; an empty `keys` list makes a single grand-total group; a
  0-row frame yields zero groups. `ColumnNotFound` on the first unknown
  key; `DuplicateColumn` if a key is named twice (rejected up front,
  mirroring `select`).
- `GroupedDataFrame::agg(specs : Array[AggSpec]) -> DataFrame raise
  DataError` — reduce each group to a row. Output columns are the key
  columns (in `keys` order, original dtype) followed by one column per
  spec (in `specs` order); one row per group, in group order. Each
  reduction reuses the matching `Series` statistic, inheriting its null /
  `NaN` / dtype rules:
  - `Count` → `Int`, non-null cells only (like `Series::count` / Polars'
    `count`, **not** a row count like `len`);
  - `Sum` → source numeric dtype (`Int`/`Float`), additive identity for an
    empty / all-null group; a `NaN` cell propagates to a `NaN` total (`NaN`
    is a value, not missing);
  - `Mean` → nullable `Float`, a null cell for an all-null group; a `NaN`
    cell propagates to a `NaN` mean;
  - `Min` / `Max` → source dtype, a null cell for an empty / all-null
    group, `NaN` skipped — like Polars' regular `min`/`max` (every dtype is
    ordered, so they apply to all four).
  An empty `specs` list degenerates to a **distinct** over the key columns
  (the unique key tuples). Routes through `DataFrame::new`, so every output
  satisfies `check_invariants()`. Raises: `TypeMismatch` (a `Sum` / `Mean`
  on a non-numeric column), `ColumnNotFound` (a spec's column is absent),
  `DuplicateColumn` (two output names collide — e.g. two default-named
  specs, or an alias shadowing a key column).
- `enum AggKind` — `Count` / `Sum` / `Mean` / `Min` / `Max`.
- `struct AggSpec` (fields private) — built via `AggSpec::count` / `sum` /
  `mean` / `min` / `max(column)`, with `with_alias(name)` to override the
  output column name. The default output name is `"<column>_<kind>"` (e.g.
  `AggSpec::sum("quantity")` → `quantity_sum`).

### Join (`join` / `inner_join` / `left_join` / `right_join` / `outer_join` / `cross_join`)

Hash equi-join, native to the method chain (`left.join(right, options)`).

- `join(other, options : JoinOptions) -> DataFrame raise DataError` — join
  `self` (left) with `other` (right) on the `options.on` key columns. Two
  rows match when every key holds an equal value, using the **same
  composite-key encoding as `group_by`** (each cell's `Scalar::to_string`,
  length-prefixed so a multi-key composite is injective). The one
  deliberate difference from `group_by`: a **null** key matches **nothing**
  (`null != null`, the SQL / Polars default) — such an unmatched row is
  dropped by `Inner` and kept (with the other side's columns null) by
  `Left` / `Right` / `Outer`. A `Float` `NaN` key is not null, so (as in
  `group_by`, matching Polars' "NaN compares equal" rule) it renders
  `"NaN"` and **matches other `NaN` keys**.
  - **`how`** selects which unmatched rows survive: `Inner` (matched pairs
    only), `Left` (+ unmatched left rows, right null), `Right` (+ unmatched
    right rows, left null — the mirror of `Left`), `Outer` (+ unmatched rows
    from **both** sides), `Cross` (the keyless Cartesian product, below).
  - **Columns** = left columns (original order and names) then the right
    frame's columns (original order), governed by `options.coalesce`. When
    a key is **coalesced** it appears once at the left key's position,
    taking each row's value from whichever side is present — the left on
    `Inner` / `Left`, the right on `Right`, the present side per row on
    `Outer` (the two are equal on a matched pair) — and the right key column
    is dropped. When **not** coalesced, the right key column is kept,
    suffixed (`<key>` + `options.suffix`, default `"_right"`) and null
    wherever its row had no match. Any other right column whose name occurs
    in the left frame is likewise suffixed; the left column keeps its name.
  - **Rows** = left rows in order (each with its right matches in ascending
    right-row order, then — for `Left` / `Outer` — unmatched left rows in
    place with null right columns), followed for `Outer` by the unmatched
    right rows in right-row order. `Right` instead emits every right row in
    right-row order (each with its left matches in ascending left-row order,
    else the right row alone with null left columns). Fully determined by
    input order (snapshot-stable).
  - `how = Cross` is the **Cartesian product** (every left row × every
    right row); it takes **no** keys, ignores `coalesce`, and keeps every
    column of both frames (a clashing right column is suffixed). This is the
    explicit form of what `group_by([])`'s grand-total group is for
    aggregation.
  - Routes through `DataFrame::new`, so every output satisfies
    `check_invariants()`. Raises: `ColumnNotFound` (a key absent from the
    left or the right; first offending key in `on` order, left checked
    before right), `TypeMismatch` (a key's dtype differs across the two
    frames), `InvalidOperation` (empty `on` for a non-`Cross` join — use
    `Cross` for a product — or a non-empty `on` for a `Cross` join),
    `DuplicateColumn` (two output columns still collide after suffixing —
    surfaced by `DataFrame::new`).
- `inner_join(other, on : Array[String]) -> DataFrame raise DataError` —
  `self.join(other, JoinOptions::on(on))` (auto-coalesces, so the key
  appears once).
- `left_join(other, on : Array[String]) -> DataFrame raise DataError` —
  `self.join(other, JoinOptions::on(on).with_how(Left))`. Per the
  auto-coalesce default this keeps **both** key columns (the right as
  `<key><suffix>`, null on unmatched rows); pass `with_coalesce(true)` to
  merge them.
- `right_join(other, on : Array[String]) -> DataFrame raise DataError` —
  `self.join(other, JoinOptions::on(on).with_how(Right))`; the mirror of
  `left_join` (keep every right row, left columns null on no match). Keeps
  both keys by default; `with_coalesce(true)` merges them from the
  always-present right side.
- `outer_join(other, on : Array[String]) -> DataFrame raise DataError` —
  `self.join(other, JoinOptions::on(on).with_how(Outer))`; the full outer
  join (every unmatched row from both sides kept). Keeps both keys by
  default; `with_coalesce(true)` merges them, each cell from whichever side
  is present.
- `cross_join(other) -> DataFrame raise DataError` —
  `self.join(other, JoinOptions::cross())`; the Cartesian product, no keys.
- `enum JoinType` — `Inner` / `Left` / `Right` / `Outer` / `Cross`.
- `struct JoinOptions` (fields private) — built via `JoinOptions::on(keys)`
  (defaults to `Inner`, suffix `"_right"`, `coalesce` auto) or
  `JoinOptions::cross()` (keyless `Cross`), with
  `with_how(JoinType)` / `with_suffix(name)` / `with_coalesce(Bool)` to
  override. `coalesce` defaults to `None` (auto: coalesce on an inner join,
  keep both keys on a `Left` / `Right` / `Outer` join — Polars' rule);
  `with_coalesce(true|false)` forces it. Chainable:
  `JoinOptions::on(["id"]).with_how(Outer).with_coalesce(true)`.

### Sorting types

- `enum SortOrder` — `Asc` / `Desc`. `enum NullOrder` — `NullsFirst` /
  `NullsLast` (for `Float`, `NaN` is treated as missing, like `Null`).
- A sort key is a `(column, SortOrder, NullOrder)` tuple; `sort_by` takes an
  `Array` of them. Multi-key sort lists several; a single-key sort passes a
  one-element array (e.g. `[("score", Desc, NullsLast)]`).

### RowView

- `struct RowView` — borrowed single-row view; no per-row allocation.
  Built via `DataFrame::row(i)` (eager bounds check) or `row_view(i)`.
- Total: `index() -> Int`.
- Fallible (`raise DataError`): `get(name) -> Scalar` (null →
  `Scalar::Null`; `ColumnNotFound`); `is_null(name) -> Bool`;
  `get_int` / `get_float` / `get_bool` / `get_string` compose `get` with
  the matching `Scalar::as_*`, so they `raise TypeMismatch` on the wrong
  dtype or a null cell (`get_float` promotes `Int`).

---

## `io` — Serialization (IO-1 boundary)

Read / parse / write functions `raise DataError`; the string serialisers
(`format_csv_str` / `format_json_records` / `format_ndjson`) are **total**
and return a `String`. The one exception is `format_vega_lite`, which
`raise`s — a `ChartSpec` names the columns to plot, and a missing name is
`ColumnNotFound`. Tokenisation delegates to `moonbit-community/NyaCSV`;
JSON / Vega-Lite specs go through the builtin `@json`; file wrappers
delegate to `moonbitlang/x/fs` and promote its `IOError` to
`raise DataError::IoError(message)`.

### CSV

- `struct CsvReadOptions` — `has_header` (default `true`; `false`
  synthesises `"column1"`, …) / `delimiter` (`,`) / `infer_schema_rows`
  (`100`; `0` or any value `<= 0` lifts the cap and scans every row —
  Polars' `infer_schema_length=None`) / `null_values` (`[""]`) /
  `strict_column_count` (`false`; when `true`, a ragged data row — cell
  count ≠ header width — raises `ParseError` instead of being null-padded /
  truncated) / `on_parse_error` (`Raise`; see `OnParseError` below) /
  `allow_nonfinite_floats` (`true`; when `false`, the `nan` / `inf` /
  `infinity` float literals are rejected during inference, so a column of
  them falls back to `String` instead of being retyped to `Float`).
  `CsvReadOptions::default()`.
- `enum OnParseError { Raise; Null }` (`pub(all)`) — the parse-failure
  policy shared by the three readers' options. A non-null cell past the
  inference window that doesn't fit its column's locked-in dtype either
  fails the whole read with `ParseError` (`Raise`, the default — strict and
  lossless) or is downgraded to a null cell, keeping the column's inferred
  dtype (`Null`, Polars' `ignore_errors=True`).
- `struct CsvWriteOptions` — `header` (`true`) / `delimiter` (`,`) /
  `null_value` (`""`). `CsvWriteOptions::default()`.
- `parse_csv_str(content, options) -> DataFrame raise DataError` —
  tokenise → per-column inference (`Int → Float → Bool → String`) → null
  mapping → `DataFrame::new`. `DuplicateColumn` / `ParseError` (the latter
  also covers a ragged row when `options.strict_column_count`, and a cell
  that doesn't fit its dtype unless `options.on_parse_error = Null`).
- `format_csv_str(df, options) -> String` — **total**. Cells render via
  `Scalar::to_string`; null → `options.null_value`; RFC 4180 quoting;
  LF-terminated.
- `read_csv(path)` / `read_csv_with_options(path, options) -> DataFrame
  raise DataError` — file wrappers (`IoError`).
- `write_csv(path, df)` / `write_csv_with_options(path, df, options) ->
  Unit raise DataError` — file wrappers (`IoError`).

### JSON (records shape `[{...}, ...]`)

- `struct JsonReadOptions` — `infer_schema_rows` (`100`; `0` or `<= 0`
  scans every record) / `on_parse_error` (`Raise`; the shared
  `OnParseError`, documented under CSV). `JsonReadOptions::default()`.
- `parse_json_records_str(content, options) -> DataFrame raise DataError`
  — `@json.parse` → object validation → headers in first-seen order
  across all records (sparse records → null cells) → inference (same
  order as CSV; `Number` locks `Int` when integral and in `Int64` range,
  else `Float`; `true` / `false` only for `Bool`; mixed → `String`
  fallback) → `DataFrame::new`. `ParseError`.
- `format_json_records(df) -> String` — **total**. One object per row,
  keys in `df.columns()` order; `Null → null`, bools / strings / finite
  numbers via `@json`. A non-finite `Float` (`NaN` / `±Infinity`) has no
  JSON literal, so it is emitted as `null` (like pandas' `to_json`),
  keeping the output valid JSON; a round-trip reads it back as a null.
  `Int` cells render as JSON numbers; a magnitude beyond 2^53 keeps its
  `Int` dtype but loses precision on a JSON round-trip (the `@json` number
  model is `Double`), as in pandas' `to_json`.
- `read_json(path)` / `read_json_with_options(path, options) -> DataFrame
  raise DataError`; `write_json_records(path, df) -> Unit raise
  DataError` — file wrappers (`IoError`).

### NDJSON (JSON Lines, one object per line `{...}\n{...}\n…`)

The streaming-friendly sibling of the JSON-records shape (Polars'
`read_ndjson` / `write_ndjson`, pandas' `read_json(lines=True)`).
Everything after the line framing is shared with the records
reader / writer — header collection (first-seen order across all lines,
sparse lines → null cells), the `Int → Float → Bool → String` inference,
and the `scalar_to_json` cell conventions — so a column inferred from
NDJSON matches the same data read as a JSON array.

- `struct NdjsonReadOptions` — `infer_schema_rows` (`100`; `0` or `<= 0`
  scans every record) / `on_parse_error` (`Raise`; the shared
  `OnParseError`, documented under CSV). `NdjsonReadOptions::default()`.
  Structurally identical to `JsonReadOptions`; kept a separate type so the
  two formats can diverge later.
- `parse_ndjson_str(content, options) -> DataFrame raise DataError` —
  split on `\n` → parse each non-blank line (`@json.parse`) → the shared
  records → frame core. Blank / whitespace-only lines are skipped and a
  trailing `\r` (CRLF) is tolerated as JSON whitespace, so the writer's
  trailing newline (and incidental blank lines) round-trip without
  phantom rows. A malformed line surfaces as `ParseError("line N: …")`
  (1-based); a line whose value is not an object, or a typed mismatch
  past the inference window (unless `options.on_parse_error = Null`), is
  also `ParseError`. Empty / all-blank input → 0×0 frame.
- `format_ndjson(df) -> String` — **total**. One compact object per row,
  keys in `df.columns()` order, each line terminated by `\n` (including
  the last — matching the CSV writer's per-row LF and Polars'
  `write_ndjson`); a 0-row frame renders the empty string. Per-cell
  rules match `format_json_records` (non-finite `Float` → `null`; `Int`
  beyond ±2^53 keeps its dtype but loses precision on a round-trip).
- `read_ndjson(path)` / `read_ndjson_with_options(path, options) ->
  DataFrame raise DataError`; `write_ndjson(path, df) -> Unit raise
  DataError` — file wrappers (`IoError`).

### Chart export (Vega-Lite v5)

`format_vega_lite` emits a complete, standalone [Vega-Lite v5](https://vega.github.io/vega-lite/)
specification as a JSON string — `$schema` + optional `title` + `mark` +
`encoding` + an inline `data.values` array — that drops straight into the
[Vega editor](https://vega.github.io/editor/) or any Vega-Lite runtime.
It is a serialiser (the IO-1 boundary keeps it in `io`, parallel to
`format_json_records`), and it shares that emitter's `scalar_to_json` cell
mapping, so a `data.values` cell follows the same rules (null and
non-finite-float cells → JSON `null`).

- `enum ChartKind { Bar; Line; Point; Area }` (`pub(all)`) — the mark
  type, mapped to the Vega-Lite `mark` (`"bar"` / `"line"` / `"point"` /
  `"area"`).
- `struct ChartSpec` (fields private) — built via a mark-named
  constructor `ChartSpec::bar(x, y)` / `line(x, y)` / `point(x, y)` /
  `area(x, y)` (`x` / `y` are column names) and chained
  `with_color(column)` (a grouping / colour column) / `with_title(text)`.
- `format_vega_lite(df, spec) -> String raise DataError` — **not total**.
  Resolves the spec's `x` / `y` / `color` columns against `df`
  left-to-right; the first name absent from the frame raises
  `ColumnNotFound(name)`. Each channel's Vega-Lite field `type` is
  inferred from the column dtype: numeric (`Int` / `Float`) →
  `"quantitative"`, otherwise (`String` / `Bool`, and an all-null `Null`
  column) → `"nominal"`. The frame is inlined as `data.values` (a frame
  with the encoded columns but zero rows yields `"values":[]`). The output
  is always valid JSON.
- `write_vega_lite(path, df, spec) -> Unit raise DataError` — file wrapper
  (propagates `ColumnNotFound`; filesystem failure → `IoError`).

---

## `moonframe` — Facade package

`moonframe.mbt` re-exports every symbol above via `pub using`, so a
single `import "ihb2032/MoonFrame" @moonframe` reaches the whole surface.
Because the operator verbs and `to_markdown` are **methods on
`DataFrame`**, re-exporting `type DataFrame` makes them automatically
reachable — only the value types and the `io` free functions are listed
explicitly.

- From `@types`: `DataError` · `DataType` · `Scalar` · `Field` · `Schema`
- From `@column`: `Bitmap` · `BuiltinColumn` · `ColumnData`
- From `@frame`: `Series` · `DataFrame` · `RowView` · `SortOrder` ·
  `NullOrder` · `AggKind` · `AggSpec` · `GroupedDataFrame` · `JoinType` ·
  `JoinOptions` · `HtmlOptions`
- From `@io`: `CsvReadOptions` · `CsvWriteOptions` · `JsonReadOptions` ·
  `NdjsonReadOptions` · `OnParseError` · `ChartKind` · `ChartSpec` ·
  `format_csv_str` ·
  `format_json_records` · `format_ndjson` · `format_vega_lite` ·
  `parse_csv_str` · `parse_json_records_str` · `parse_ndjson_str` ·
  `read_csv` · `read_csv_with_options` · `read_json` ·
  `read_json_with_options` · `read_ndjson` · `read_ndjson_with_options` ·
  `write_csv` · `write_csv_with_options` · `write_json_records` ·
  `write_ndjson` · `write_vega_lite`

`using @pkg { type T }` also creates constructor aliases, so
`@moonframe.Scalar::Int(42)`, `@moonframe.SortOrder::Desc`,
`@moonframe.DataError::ColumnNotFound("y")` all resolve through the
facade.

---

## Out of scope for v0.2 (so far)

- `NumericColumn`, `ColumnStorage` abstraction — v0.3
- Expression / lazy query API — v0.4

(HTML output and Vega-Lite chart export have since landed in v0.3.)
