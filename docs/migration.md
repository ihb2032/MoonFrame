# Migration guide

Source-level breaking changes between MoonFrame releases. Pre-1.0, breaking
changes ride the minor version. For the feature history behind each release see
[`changelog.md`](changelog.md); for the current public surface see
[`api.md`](api.md).

## v0.5.5 → v0.5.6

No source-level migration steps. v0.5.6 is an additive patch: every v0.5.5
symbol and signature is unchanged, and nothing is renamed, removed, re-signed,
or given a new required `match` arm. The new surface is a `moon bench` benchmark
suite (test-scope only — nothing a consumer imports changes), a declared
`supported_targets` in `moon.mod`, and documentation corrections (see the
[changelog](changelog.md)).

## v0.5.4 → v0.5.5

No source-level migration steps. v0.5.5 is an additive patch: every v0.5.4
symbol and signature is unchanged, and nothing is renamed, removed, re-signed,
or given a new required `match` arm. The new surface is purely additive — two
introspection predicates, `Series::is_canonical()` and
`BuiltinColumn::placeholders_normalized()`, that assert internal representation
invariants (see the [changelog](changelog.md)).

## v0.5.3 → v0.5.4

No source-level migration steps. v0.5.4 is an additive patch: every v0.5.3
symbol and signature is unchanged, and nothing is renamed, removed, re-signed,
or given a new required `match` arm. The new surface is purely additive — the
API-consistency aliases (`NumericColumn::from_ints` / `from_floats`,
`JoinOptions::with_left_on`, `DataFrame::limit`) and the `format_scalar_literal`
facade re-export listed in the [changelog](changelog.md).

## v0.5.2 → v0.5.3

No source-level migration steps: no renames, no signature changes, and no new
required `match` arms. v0.5.3 is a correctness and robustness patch, so the only
changes are behavioural fixes that code should not have depended on:

- A chain of `fill_null` / `fill_nan` now builds in linear time instead of an
  exponentially-sized tree; the results are identical.
- Out-of-range indices in the row-gather path (reached through `DataFrame::take`
  and the join planner) yield a null cell instead of panicking. Code that
  relied on the panic to flag a bad index should validate indices itself.
- `Series::variance` / `std` saturate to `+inf` on intermediate Welford
  overflow rather than returning a spurious finite value.
- A read projection (`read_csv_projected` / `read_ndjson_projected`, and the
  `lazy` scans built on them) that names no column present in the header now
  falls back to reading the full file instead of yielding an empty frame.

## v0.5.1 → v0.5.2

Additive plus two behaviour fixes; no renames.

- `DataError` gains a `NullInNonNullable(String)` variant. A new enum variant
  is the one change the post-v0.5 surface allows: an exhaustive `match` over
  `DataError` without a wildcard arm must add a `NullInNonNullable(_)` case.
- `DataFrame::from_rows` now raises `NullInNonNullable(name)` when row data
  places a null in a field declared `nullable = false` (previously it built the
  frame silently). Declare the field `nullable = true` — the default, via
  `Field::new` — to keep the old behaviour.
- Raw constructors (`Series` / `BuiltinColumn` / `NumericColumn`'s `from_ints` /
  `from_floats` / `from_bools` / `from_strings`) now defensively copy their
  input array. Code that mutated the source array after construction to alter
  the column (the previously-documented footgun) no longer has that effect —
  mutate the array before constructing, or build a fresh one.

## v0.4 → v0.5

v0.5 is a pre-1.0 breaking release — and the **last** one: from v0.6 on the
public surface only grows (the sole exception being new enum variants). It
converges the eager and lazy APIs onto a single, Polars-shaped expression
engine. The duplicate `*_exprs` verbs, the closure `filter`, the `AggSpec`
reduction specs, the rich `RowView`, the per-type `*_join` methods, the
column-scalar reductions, and a tail of non-Polars names are all **removed
outright** — there are no deprecated aliases. Everything below is a pure rename
or a mechanical rewrite; for the feature side of the same release see
[`changelog.md`](changelog.md).

### The four verbs take expressions

`select` / `filter` / `agg` / `with_columns` each now take an `Array[Expr]` (or
a single `Expr`), on both `DataFrame` and `LazyFrame`. The v0.4 `*_exprs` /
`*_where` twins that introduced the expression form are gone — the plain verb
*is* the expression form.

| v0.4 | v0.5 |
|---|---|
| `df.select(["region", "revenue"])` | `df.select([col("region"), col("revenue")])` — or `df.select(cols(["region", "revenue"]))` |
| `df.select_exprs([col("a") + col("b")])` | `df.select([col("a") + col("b")])` |
| `df.filter(row => row.get_int("x") > 0)` | `df.filter(col("x").gt(lit_int(0)))` |
| `df.filter_where(expr)` | `df.filter(expr)` |
| `grouped.agg([AggSpec::sum("x").with_alias("t")])` | `grouped.agg([col("x").sum().with_alias("t")])` |
| `grouped.agg_exprs([expr])` | `grouped.agg([expr])` |
| `df.with_column(series)` | `df.with_columns([lit_series(series)])` |
| `lf.select_exprs(...)` / `lf.filter_where(...)` | `lf.select(...)` / `lf.filter(...)` |

The `AggSpec` struct and its `AggKind` enum (`AggSpec::sum` / `mean` / `min` /
`max` / `count` / `with_alias`) are removed; the equivalent reductions are the
`Expr` methods `col("x").sum()` / `.mean()` / `.min()` / `.max()` / `.count()`,
which additionally compose over a *derived* column — `(col("revenue") -
col("cost")).sum()` — the thing `AggSpec` could not express.

**Arbitrary row predicates.** The old closure `filter` could run any MoonBit
code per row. Its reified replacement is the `map_many` escape hatch — a closure
over the row's cells as `Scalar`s, carried by an inspectable `Expr`:

```moonbit
// v0.4
df.filter(row => row.get_string("product") == "widget")
// v0.5
df.filter(
  map_many(label="is_widget", [col("product")], cells => Scalar::Bool(
    cells[0].as_string() == "widget",
  )),
)
```

`map_elements` is the single-input form: `col("q").map_elements(label="...", s
=> ...)`.

### Sort / group_by / join / drop keys take expressions

The key-bearing verbs now name their keys with `Expr`, so a key can be a derived
column, not just a name. `sort_by` is renamed `sort` to match Polars.

| v0.4 | v0.5 |
|---|---|
| `df.sort_by([("revenue", Desc, NullsLast)])` | `df.sort([(col("revenue"), Desc, NullsLast)])` |
| `df.group_by(["region"])` | `df.group_by([col("region")])` |
| `df.drop(["tmp"])` | `df.drop([col("tmp")])` |
| `df.drop_nulls_in(["revenue"])` | `df.drop_nulls(subset=[col("revenue")])` |
| `lf.sort_by(...)` / `lf.group_by([name])` | `lf.sort(...)` / `lf.group_by([col(name)])` |

`drop_nulls()` with no argument is unchanged (drop every row with a null in any
column); it just gained an optional `subset`, which retired the separate
`drop_nulls_in`. `rename` is unchanged — it takes `Array[(String, String)]`,
matching Polars' dict form, not expressions.

### Join — one method, expression keys

The per-type convenience joins are removed; `join` with a `JoinOptions` is the
only form (as in Polars). Keys are `Expr`, and `left_on` / `right_on` support
differently-named or derived keys.

| v0.4 | v0.5 |
|---|---|
| `left.inner_join(right, ["id"])` | `left.join(right, JoinOptions::on([col("id")]))` — inner is the default `how` |
| `left.left_join(right, ["id"])` | `left.join(right, JoinOptions::on([col("id")]).with_how(Left))` |
| `left.right_join(...)` / `left.outer_join(...)` | `.with_how(Right)` / `.with_how(Outer)` |
| `left.cross_join(right)` | `left.join(right, JoinOptions::cross())` |
| `JoinOptions::on(["id"])` | `JoinOptions::on([col("id")])` |
| *(no equivalent)* | `JoinOptions::left_on([col("a")]).with_right_on([col("b")])` for differently-named keys |

`with_how` / `with_coalesce` / `with_suffix` and the null-key / NaN-key /
suffix semantics are unchanged. One behaviour change: the `coalesce = None`
default now follows Polars per `how` — a `Left` / `Right` join coalesces its
key into one column instead of keeping both (`Inner` already coalesced, `Outer`
still keeps both); pass `with_coalesce(false)` for the old two-column
Left / Right output.

### Row access — `row(i)` returns a tuple, new `rows()`

The rich `RowView` (and the unchecked `row_view`) are removed in favour of
Polars' positional row access. `df.row(i)` now returns an `Array[Scalar]` (by
column order); `df.rows()` returns every row. For a single typed value, read the
column and index it, then narrow the `Scalar`.

| v0.4 | v0.5 |
|---|---|
| `df.row(i)` → `RowView` | `df.row(i)` → `Array[Scalar]` |
| `df.row_view(i)` (unchecked) | *removed* — use `df.row(i)` |
| `df.row_view(i).get_int("c")` | `df.get_column("c").get(i).as_int()` — likewise `as_float` / `as_bool` / `as_string` |
| `df.row(i).get_string("c")` | `df.get_column("c").get(i).as_string()` |
| `view.is_null("c")` | `df.get_column("c").get(i).is_null()` |
| *(iterate rows)* | `df.rows()` → `Array[Array[Scalar]]` |

### Whole-frame reductions — `df.sum()` returns a frame

`df.sum(col)` returning a scalar is removed (it has no Polars analogue). Polars'
two forms take its place: `df[col].sum()` for a single scalar — here
`df.get_column(col).sum()` — and the no-argument `df.sum()` reducing every
numeric column to a **one-row `DataFrame`**.

| v0.4 | v0.5 |
|---|---|
| `df.sum("revenue")` → `Scalar` | `df.get_column("revenue").sum()` → `Scalar` |
| `df.mean("revenue")` → `Double` | `df.get_column("revenue").mean()` → `Double` |
| `df.min("x")` / `df.max("x")` / `df.count("x")` | `df.get_column("x").min()` / `.max()` / `.count()` |
| *(no equivalent)* | `df.sum()` / `mean()` / `min()` / `max()` / `count()` → one-row `DataFrame` |

The frame-wide `df.sum()` reduces only `Int` / `Float` columns (a `Bool` /
`String` column becomes a `Null` cell of its source dtype); `df.count()` is the
per-column non-null count. Note `df.get_column(c).sum()` *raises* on a
non-numeric column, while the frame-wide `df.sum()` tolerates it by nulling — the
two reductions differ on purpose.

### `fill_null` moves to the expression layer

The per-column `df.fill_null(name, value)` is removed; per-column filling is now
an `Expr` method, and there is a new whole-frame form.

| v0.4 | v0.5 |
|---|---|
| `df.fill_null("note", Scalar::String("n/a"))` | `df.with_columns([col("note").fill_null(lit_str("n/a"))])` |
| *(no equivalent)* | `df.fill_null(Scalar::Int(0))` — fills the null cells of every dtype-compatible column |

`Series::fill_null(Scalar)` is unchanged. The `Expr` form is more capable than
the old frame method: the fill value is any `Expr` (a literal, another column for
a coalesce, or a computed tree), and `Int` / `Float` operands unify.

### `replace_column` retired

`replace_column` is removed; `with_columns([lit_series(...)])` replaces a column
by name. Rename the series to the target name first if it differs.

| v0.4 | v0.5 |
|---|---|
| `df.replace_column("x", series)` | `df.with_columns([lit_series(series.rename("x"))])` |

Two behaviour differences, by design: where the old method raised
`ColumnNotFound` on a missing name, `with_columns` *appends* the column; and
where it raised `LengthMismatch` on any off-length series, `lit_series`
broadcasts a length-1 series.

### Naming finalisation

The last non-Polars public names are aligned — mechanical renames, or a fold
into `cast`.

| v0.4 | v0.5 |
|---|---|
| `series.min_value()` / `max_value()` | `series.min()` / `series.max()` |
| `series.take([...])` | `series.gather([...])` |
| `series.unique_count()` | `series.n_unique()` |
| `series.to_int()` / `to_float()` / `to_string_series()` | `series.cast(DataType::Int)` / `cast(DataType::Float)` / `cast(DataType::String)` |
| `series.null_rate()` | *removed* — compute `series.null_count() / series.len()` |
| `series.describe()` | *removed* — wrap in a frame: `DataFrame::new([series]).describe()` |
| `df.get(i, "c")` | `df.item(i, "c")` |
| `@io.format_csv_str(df, opts)` | `@io.format_csv(df, opts)` |

The same `min_value` → `min`, `max_value` → `max`, and `to_int` / `to_float` →
`cast` renames apply to the column backend types (`NumericColumn`,
`BuiltinColumn`, `ColumnStorage`) for callers who reach them directly;
`to_string_column` is kept (it returns a `BuiltinColumn`, not a `cast`'s `Self`).

### `Series` moved to its own package

`Series` was extracted from `frame` into a new `series` package so the
expression layer can build on the per-column unit. Facade users are unaffected —
`@moonframe.Series` still names the same type, with the same constructors and
methods. Only code that imported the type **directly** from `frame` needs the
new path.

| v0.4 | v0.5 |
|---|---|
| `ihb2032/MoonFrame/frame.Series` | `ihb2032/MoonFrame/series.Series` |
| facade `@moonframe.Series` | unchanged |

### Purely additive (no action needed)

v0.5 also *adds*, with nothing to migrate: the `map_elements` / `map_many`
closure escape hatch; the aggregations `std` / `variance` / `median` /
`n_unique` / `first` / `last`; the `Expr` string namespace (`str_to_uppercase` /
`str_contains` / `str_replace` / …); `lit_series` and the `cols` name helper;
`DataFrame::unique()` (first-appearance row dedup); and the lazy file sources
`scan_csv` / `scan_ndjson` (with `_with_options` variants) with projection
pushdown.

### One deliberate non-alignment

`sort` treats a `Float` `NaN` as **missing** (ordered by the tuple's
`NullOrder`), not as a value. This is the only place v0.5 knowingly differs from
Polars, where `NaN` is a value that sorts last independently of `nulls_last`.
Everything else above matches Polars' shape and behaviour.

## v0.3 → v0.4

**Additive — nothing to change.** v0.4 only *adds* symbols: the new `expr`
package (`Expr`, `col` / `lit_*` / `when`, the operators and methods), the new
`lazy` package (`LazyFrame` / `LazyGroupBy`, `lazy_frame`), and new `DataFrame`
/ `GroupedDataFrame` methods (`with_columns` / `select_exprs` / `filter_where`
/ `agg_exprs`). No v0.2 / v0.3 type, method, or enum variant changed, so
existing code compiles and behaves identically. The two new public
sub-packages are available directly for callers who want a slice of the
surface, while callers who import only the facade `ihb2032/MoonFrame` get the
same symbols there. (The `Series`-into-its-own-package split, which *will*
touch existing code, is deferred to v0.5.)

## v0.2 → v0.3

v0.3 is a pre-1.0 breaking release. The source-level breaks:

| v0.2 | v0.3 |
|---|---|
| `Series::storage() -> @column.BuiltinColumn` | `-> @column.ColumnStorage`; the `.data()` / `.validity()` reading surface is unchanged, so column-reading call sites still compile. Use `.to_builtin()` when you need the concrete `BuiltinColumn` |
| `Series::new(name, BuiltinColumn)` | `Series::new(name, ColumnStorage)`; pass `ColumnStorage::from_builtin(col)`, or keep `Series::from_builtin(name, col)` (signature unchanged) |
| `pub(all) enum JoinType { Inner; Left; Cross }` | gained `Right` / `Outer`; an exhaustive `match` over `JoinType` must now handle the two new variants |

The CSV / JSON / NDJSON `*ReadOptions` structs also gained `pub(all)` fields
(read resilience — `on_parse_error`, plus CSV's `allow_nonfinite_floats`): a
full struct literal must add them or switch to `::default()`. The defaults
reproduce the prior behaviour exactly.

## v0.1 → v0.2

| v0.1 | v0.2 |
|---|---|
| `@ops.select(df, names)` (free function) | `df.select(names)` (method) |
| `op(df, ...) -> Result[T, DataError]` + `.bind` / `.map` / `.unwrap` | `df.op(...) -> T raise DataError`, chained directly |
| pattern-match `Ok(x)` / `Err(e)` on the result | call directly in a `raise` context, or `Ok(expr) catch { e => Err(e) }` for a `Result` |
| `filter_try(df, row => row.get_int("x").map(v => v > 0))` | `df.filter(row => row.get_int("x") > 0)` |
| `sort_by(df, spec)` / `sort_by_many(df, specs)` | `df.sort_by([(col, order, nulls), ...])` |
| `Series::min()` / `max()` (`Result`-wrapped) | `Series::min_value()` / `max_value()` (total) |
| `@io.to_markdown(df)` | `df.to_markdown()` |
| `import ... @ops` | gone — verbs live on `DataFrame` in `@frame` |

`format_csv_str` / `format_json_records` / `parse_csv_str` / `read_csv` /
`write_csv` and the JSON / NDJSON equivalents are still `io` free functions (the
`read_*` / `write_*` / `parse_*` ones now `raise`; the `format_*` ones are total
and return a `String`).
