# Changelog

Version-by-version feature history for MoonFrame, newest first. The
authoritative public-API reference is [`api.md`](api.md); the source-level
breaking-change steps for each release are collected in
[`migration.md`](migration.md). Pre-1.0, breaking changes ride the minor
version.

## v0.6.0 — API convergence

The API-convergence release. MoonBit 0.10.4's `fn Type::Type(...)` custom
constructors, optional parameters with defaults, and `internal` packages let a
tail of parallel spellings collapse into one entry each: where two ways of
building or configuring the same value existed, v0.6 keeps one. From v0.7 on the
stable public surface evolves compatibly. The source-level upgrade steps are
collected in [`migration.md`](migration.md).

### Breaking

- `Field::new(name, dtype)` and `Field::with_nullable(name, dtype, nullable)`
  are replaced by the single custom constructor
  `Field(name, dtype, nullable? = true)`. The bare `Field(...)` spelling
  resolves wherever the expected type is concrete (inside `Schema::new([...])`,
  an annotated binding, a typed array literal); a generic position such as
  `assert_eq` takes the full `Field::Field(...)`.
- `struct Field` is `pub` rather than `pub(all)`: its fields stay readable
  (directly and through the `name` / `dtype` / `nullable` accessors) but it can
  no longer be built from a record literal outside `types`. Construction goes
  through `Field(...)`, so a future field can be added without breaking callers.

## v0.5.8 — string-ordering and parse-overflow fixes

A fix patch. Every v0.5.7 symbol and signature is unchanged — the root facade
interface (`pkg.generated.mbti`) is byte-for-byte identical — so no code that
imports MoonFrame needs to change. Two internal correctness fixes, surfaced by a
static review, refine edge-case behaviour.

### Fixes

- String ordering (`compare_string_lex`, and everything routing through it —
  `Series::sort` / `min` / `max`, `DataFrame::sort`, and the `Scalar`
  comparisons) now compares by Unicode code point rather than raw UTF-16 code
  unit. Supplementary-plane characters (emoji and other astral-plane code
  points) sort by their true scalar value instead of being ranked below
  high-BMP characters by their leading surrogate unit. Ordering within the Basic
  Multilingual Plane — the common case — is unchanged.
- Float parsing (`parse_plain_double_opt`, behind CSV / JSON type inference and
  the String→Float cast) now decides IEEE 754 overflow structurally: a valid
  finite decimal literal that overflows `Double` rounds to a signed `Infinity`,
  and anything else stays unparsed. Parse results are unchanged; the fix removes
  a dependency on the standard library's human-readable "value out of range"
  message, which a future toolchain could reword.

## v0.5.7 — internal syntax modernization

An internal-refactor patch. Every v0.5.6 symbol, signature, and behaviour is
unchanged, so no code changes are required to upgrade — this release only
rewrites the implementation with current MoonBit syntax. There is no observable
difference: the root facade interface (`pkg.generated.mbti`) is byte-for-byte
identical, and every rendered output (HTML / Markdown / CSV / plan / expression)
is pinned unchanged by the existing exact-output tests. The `expr` / `frame` /
`lazy` sub-package interfaces show only `#as_free_fn` / `#alias` attributes
moving onto their methods — `col` / `lit` / `limit` remain callable exactly as
before.

### Modernized internals

- The cast helpers `cast_cells` and `cast_cells_total` are merged into one shell
  over MoonBit's error polymorphism (`raise?`): the error effect now follows the
  per-cell callback, so a total cast stays total and a fallible one stays
  fallible without a duplicated body.
- The `col` / `lit` free constructors are generated from `Expr::col` /
  `Expr::lit` with `#as_free_fn` instead of hand-written forwarders, and `limit`
  is an `#alias` of `head` on both `DataFrame` and `LazyFrame`.
- The `JoinOptions` and `HtmlOptions` `with_*` setters use struct-update
  (`{ ..self, field: value }`); the `DataType` / `Scalar` boolean predicates use
  the `is` pattern; and `Series::to_scalars` uses an index+value comprehension.
- The HTML, logical-plan, and expression renderers assemble their output with
  the `<+` template-write operator (byte-for-byte identical output).

## v0.5.6 — benchmark suite

An additive patch. Every v0.5.5 symbol and signature is unchanged, so no code
changes are required to upgrade. This release adds a `moon bench` micro-benchmark
suite and tightens module metadata and documentation.

### Benchmarks

Each library package now carries a `bench_test.mbt` file driving `moon bench`:
`series` reductions contrasting the `Numeric` fast path against `Builtin`,
`frame` `sort` / `group_by` / `join` / `filter`, `io` string parsing, and an
eager-vs-lazy pipeline — at 1K / 100K / 1M rows where scaling is informative.
The benches are ordinary test blocks, so `moon check` compiles them and
`moon bench` runs them — both in CI, so a broken benchmark fails the build.
There is no performance threshold (timings are machine-dependent). See
[`performance.md`](performance.md#benchmarks).

### Metadata and docs

- `moon.mod` now declares `supported_targets` (`wasm` / `wasm-gc` / `js` /
  `native`), matching the backends CI tests instead of implicitly claiming all.
- Doc corrections: the lazy pipeline's bitwise-equality claim is qualified for
  pruned-column parse errors, `scan` is described as deferred + projection
  pushdown rather than streaming, the coverage wording matches the tooling, and
  the `Int` sum's `Int64` overflow wrap is called out.

## v0.5.5 — Assertable representation invariants

An additive patch. Every symbol and signature is unchanged from v0.5.4, so no
code changes are required to upgrade; three internal invariants that were held
by convention — and observed only indirectly — are now surfaced so a test can
assert them directly.

### Backend-canonicalisation invariant

`Series::is_canonical()` reports whether a column sits on its content-determined
storage backend — the fixed point of the internal `try_column_to_numeric`
convergence, where a `Builtin` all-valid `Int` / `Float` column is the one
non-canonical shape (it can still move onto the `Numeric` fast path). This is
the invariant the query optimizer relies on for `collect ≡ eager`; it was upheld
by scattered canonicalisation calls and observed only through `storage_kind` or
the differential fuzzer, and is now directly assertable.

### Null-placeholder invariant

`BuiltinColumn::placeholders_normalized()` reports whether every null slot holds
its dtype's canonical placeholder (`0` / `0.0` / `false` / `""`). Because
`BuiltinColumn` derives `Eq` over the raw `data` array (null slots included),
that placeholder is what keeps two logically equal columns equal; the predicate
makes the invariant every constructor, cast, and row transform maintains
assertable rather than trusted at each write site.

### Advisory nullability is pinned

`Field.nullable = false` is advisory — only `DataFrame::from_rows` enforces it,
and every schema-rebuilding op resets it via `Field::new`. The "not propagated"
half of that contract is now pinned by a test: a `nullable = false` column
projected through `select` comes back `nullable = true`.

## v0.5.4 — API-consistency aliases and facade completeness

An additive patch. Every symbol and signature is unchanged from v0.5.3, so no
code changes are required to upgrade; a few consistency aliases and a facade
re-export fill small gaps, over a round of internal restructuring.

### API-consistency aliases

- `NumericColumn::from_ints` / `from_floats` join `from_int64s` / `from_doubles`
  as aliases, matching the `from_ints` / `from_floats` spelling every other
  layer (`Series`, `BuiltinColumn`) already uses.
- `JoinOptions::with_left_on(keys)` mirrors `with_right_on`, so either side's
  key set can be (re)supplied anywhere in a builder chain.
- `DataFrame::limit(n)` is a Polars-style alias of `head(n)` — the eager twin
  of `LazyFrame::limit`.

### Facade completeness

`format_scalar_literal` — the scalar display-syntax renderer behind the `expr`
and `lazy` `explain` output — is now re-exported from the `@moonframe` facade,
so it is reachable without importing `@types` directly.

### Internal restructuring (no behaviour change)

The expression evaluator (`frame/expr_eval.mbt`) and the query optimizer
(`lazy/optimize.mbt`) were each split into an entry shell plus focused
per-operator / per-pass files; the elementwise kernels gained `Numeric` fast
arms; and a batch of structure cleanups from an architecture-smell review
landed. No API, behaviour, or output change.

## v0.5.3 — correctness and robustness

A patch release. Every symbol and signature is unchanged from v0.5.2, so no
code changes are required to upgrade; the behavioural deltas are listed in
[`migration.md`](migration.md). What changed is a batch of correctness,
numerical, and robustness fixes from an adversarial review, plus a curated
strict-warning gate.

### Chained null-filling is linear

`col("x").fill_null(a).fill_null(b)…` (and the `fill_nan` equivalent) built an
exponentially-sized expression tree, because the old lowering to a guarded
ternary embedded the operand twice. `fill_null` / `fill_nan` are now dedicated
expression nodes carrying `(operand, value)` once, so a chain of _n_ fills is
_O(n)_ to build, render, evaluate, and compare. Results are unchanged.

### Shared lazy subplans run once

When a `LazyFrame`'s logical plan reused a subplan — a frame branched into two
downstream operations and then recombined — the executor recomputed that
subplan once per reference. It now memoises by node identity, so each distinct
subplan is executed exactly once.

### Numerical and bounds hardening

- `Series::variance` / `std` saturate to `+inf` when a finite input overflows
  Welford's intermediate delta, instead of returning a spurious finite value.
- Out-of-range indices in the row-gather path (reached through `DataFrame::take`
  and the join planner) yield null cells on both storage backends, never a
  panic.
- A read projection that names no column present in the header falls back to a
  full read rather than yielding an empty frame.
- Smaller fixes round out the release: unpaired UTF-16 surrogates are rejected
  at the file-write boundary, the grouped-aggregation dtype probe is deferred
  until the cells leave it undecided, and a grouped handle is re-validated
  before aggregation.

### Immutability at every boundary

The defensive-copy guarantee introduced in v0.5.2 for the raw constructors now
extends to every `pub` constructor and builder boundary, so no caller-supplied
array is aliased into a frame's internals.

### Tooling

A curated strict-warning gate (`missing_doc`, `prefer_readonly_array`,
`unused_default_value`, and more) is enabled through `moon.mod`'s `warnings`
field, keeping the whole tree warning-clean in CI.

## v0.5.2 — non-nullable enforcement and immutable ingestion

### `from_rows` enforces declared non-nullability

`DataFrame::from_rows` now honours a field's declared `nullable = false`: row
data that places a `Scalar::Null` in such a column raises the new
`DataError::NullInNonNullable(name)` rather than silently building a frame whose
schema contradicts its data. Callers that relied on the old silent behaviour
should declare the field `nullable = true` (the default).

This closes the only path where schema and data could disagree. `Field::new` /
`DataFrame::new` and the IO readers always declare columns `nullable = true`, so
a `nullable = false` field only ever comes from an explicit
`Field::with_nullable(..., false)` in a caller-supplied schema, and `empty`
builds 0-row columns that cannot violate it. The flag stays advisory otherwise:
it is not inferred from a column's contents nor propagated across operations.

### Raw constructors copy their input

The raw `Series` / column constructors (`from_ints` / `from_floats` /
`from_bools` / `from_strings`, and their `BuiltinColumn` / `NumericColumn`
equivalents) now defensively copy the array they are handed, so a constructed
`Series` is a true immutable value — mutating the source array afterwards no
longer changes the series' cells. The `from_*_options` constructors already
copied while boxing into `Option`; this brings the raw fast-path constructors in
line. Internal zero-copy reuse (`to_builtin` widening, `to_numeric` conversion)
is preserved through direct construction, so the copy is paid once at the
ingestion boundary, not on internal moves.

## v0.5.1 — install docs

A documentation-only patch. The README's install instructions now use `moon add
ihb2032/MoonFrame` (the package is published on
[mooncakes.io](https://mooncakes.io/docs/ihb2032/MoonFrame)), replacing the
pre-publication `git clone` / local-dependency steps. No library, API, or
behaviour changes.

## v0.5 — one expression engine

The breaking release that finishes what v0.4 started: the eager and lazy
surfaces **converge onto a single, Polars-shaped expression engine**, and the
parallel spellings that grew up alongside it are retired. (This section once
called v0.5 the last breaking release; v0.6 is one more — the API-convergence
release above — after which the surface evolves compatibly.) The source-level
upgrade steps are collected in [`migration.md`](migration.md).

### One engine for the four verbs

`select` / `filter` / `agg` / `with_columns` each take `Expr`s now, on both
`DataFrame` and `LazyFrame`; the v0.4 `select_exprs` / `filter_where` /
`agg_exprs` twins, the `AggSpec` reduction specs, and the closure `filter` are
all gone. The closure's per-row power moves *into* the engine as two escape
hatches — `col("q").map_elements(label, f)` (one input) and
`map_many(label, inputs, f)` (several) — still a closure over the row's cells as
`Scalar`s, but carried by an inspectable, pushdown-able `Expr` rather than an
opaque function. And because the verb *is* the expression form, a reduction can
run over a derived column: `(col("revenue") - col("cost")).sum()`.

### Expression keys everywhere

`sort` (renamed from `sort_by`), `group_by`, `join`, and the `drop` family name
their keys with `Expr`, so a key can be derived rather than just a column name.
`join` collapses the per-type `inner_join` / `left_join` / `right_join` /
`outer_join` / `cross_join` methods into the single `join(other, JoinOptions)`
(Polars has no `*_join`) and gains `left_on` / `right_on` for differently-named
keys. `sort` keeps one deliberate non-Polars behaviour — a `NaN` sorts as
missing, by the tuple's `NullOrder` (the v0.2 choice).

### A wider expression vocabulary

- **Aggregations** `std` / `variance` / `median` / `n_unique` / `first` /
  `last` join `sum` / `mean` / `min` / `max` / `count` (sample statistics for
  `std` / `variance`; `median` skips `NaN`; `first` / `last` are positional).
- **A string namespace**: `str_to_uppercase` / `str_to_lowercase` /
  `str_strip_chars` / `str_len_chars` / `str_contains` / `str_starts_with` /
  `str_ends_with` / `str_replace` / `str_replace_all` (literal matching, no
  regex), each a first-class, introspectable `Str` node.
- **`fill_null` on the expression layer**: `col("x").fill_null(value)` (the
  value is any `Expr` — a literal, another column for a coalesce, or a tree),
  plus a whole-frame `df.fill_null(value)`. The old per-column frame method is
  removed.
- **NaN probes and `fill_nan`**: the `is_nan` / `is_not_nan` tests and
  `fill_nan(value)`, the dual of `fill_null` that replaces a `Float` `NaN`
  (a value, distinct from a missing `null`) while leaving nulls in place.
- **`lit_series`** embeds a `Series` as a (broadcasting) expression, and
  **`cols(["a", "b"])`** expands names to `col` expressions.

### Row access, reductions, and dedup, Polars-shaped

The rich `RowView` is retired: `df.row(i)` returns an `Array[Scalar]` (a
positional row) and the new `df.rows()` returns them all. The column-scalar
reductions give way to Polars' pair — `df.sum()` / `mean()` / `min()` / `max()`
/ `count()` reduce to a **one-row `DataFrame`**, while a single scalar comes from
`df.get_column(c).sum()`. `df.unique()` drops duplicate rows, keeping
first-appearance order.

### Lazy file sources

`scan_csv` / `scan_ndjson` (and their `_with_options` variants) start a lazy
plan straight from a file. The optimizer's **projection pushdown** reaches into
the source: a column the plan never reads is never parsed, so
`scan_csv("sales.csv").select([col("region"), col("revenue")]).collect()` reads
only those two columns. (An array-shaped JSON document has no row-wise scan to
push a projection into, so there is no `scan_json`.)

### A canonical storage backend

A column's storage backend — the unboxed `Numeric` fast path versus the general
`Builtin` backend — is now a function of its *content*, not of how it was built:
any row gather (`filter` / `gather` / `take` / `drop_nulls`, a grouped key, an
aggregation) that leaves an all-valid Int / Float column re-converges it onto
`Numeric`. This closes a predicate-pushdown soundness gap — sinking a `Filter`
below a stage carrying a *derived* column or group key (say
`group_by([col("a") + col("b")])`) recomputes that column over the surviving
rows, and without the canonical form it could land on a different backend than
the eager chain, which `Series` equality observes, making `collect` diverge from
`execute`. (`slice` / `head` / `tail` stay zero-copy views that keep the source
backend.)

### `Series` in its own package; naming finalised

`Series` is extracted from `frame` into a new `series` package, so the
expression layer can build on the per-column unit (the facade name
`@moonframe.Series` is unchanged). The last non-Polars names are aligned:
`min_value` / `max_value` → `min` / `max`, `take` → `gather`, `unique_count` →
`n_unique`, `to_int` / `to_float` / `to_string_series` → `cast`,
`DataFrame::get(i, c)` → `item(i, c)`, and `format_csv_str` → `format_csv` (so
the string serialisers share the prefix-free `format_*` shape of
`format_json_records` / `format_ndjson` / `format_vega_lite`); `null_rate` is
removed.

### Chart colour type override

`ChartSpec::with_color_type(VegaType)` overrides the Vega-Lite field `type` of
a chart's `color` channel (`Quantitative` / `Nominal` / `Ordinal` /
`Temporal`), so a numeric grouping column (a cluster id, a year) renders as
distinct per-group colours instead of the continuous gradient `quantitative`
would give.

### A null-tolerant `map`

An all-null `map_elements` / `map_many` result — every cell the closure returns
is null — now falls back to its input column's dtype and yields an all-null
column, rather than raising `Unsupported` for want of a dtype witness, matching
Polars' tolerance of a null-returning map. A grouped `agg` over such a map
(every cell in a group null) therefore completes, reducing the all-null group
normally, instead of failing mid-aggregation; only a column-less
`map_many([], …)` with no input to borrow a dtype from still raises. Alongside,
a batch of internal micro-optimizations — `fill_null` and `join` / `take`
validity gathers, the CSV null-token test, `count_distinct` — with no API or
behaviour change.

## v0.4 — shipped

A Polars-style expression engine and a lazy query layer, both **purely
additive** on top of the v0.3 core — two new packages (`expr`, `lazy`) and new
`DataFrame` / `GroupedDataFrame` methods, with nothing changed in the v0.2 /
v0.3 surface (nothing for [`migration.md`](migration.md)). Also folds in the
post-v0.3 whole-library review's join follow-ups.

### Expression engine (the `expr` package)

A reified, composable column expression. `col("name")` and `lit_int` /
`lit_float` / `lit_str` / `lit_bool` / `lit` build the leaves; the overloaded
operators `+ - * /` (arithmetic — `/` is always `Float`, dividing by zero to
IEEE `±inf` / `NaN` rather than trapping), `&` / `|` (Kleene-logical, **not**
bitwise), and unary `-` compose them; and the methods `eq` / `ne` / `lt` /
`le` / `gt` / `ge` (comparisons → `Bool`), `not` / `is_null` / `is_not_null`,
the aggregations `sum` / `mean` / `min` / `max` / `count`, `cast`, and
`with_alias` extend them. `when(cond).then(a).otherwise(b)` is a row-wise
conditional. Building a tree is **total** (it never fails); `explain()` and the
`Show` impl render the operator form, and `referenced_columns` / `output_name`
introspect it. An `Expr` is read-only outside `expr` — built through the
surface above, never by naming a variant.

### Eager expression consumers (the `frame` package)

The whole-frame evaluator and its `DataFrame` / `GroupedDataFrame` consumers:
`with_columns` (derive or replace columns), `select_exprs` (project to the
evaluated expressions — an all-aggregation selection collapses to one row),
`filter_where` (vectorized boolean row selection — a reified, pushdown-able
alternative to the closure `filter`), and `agg_exprs` (the expression form of
`agg`, generalising `AggSpec` to compound reductions like
`(col("revenue") - col("cost")).sum()`). Evaluation is vectorized with
`Int` / `Float` promotion, null propagation, Kleene logic, and the `Series`
reduction's `NaN` rules.

### Lazy query layer (the `lazy` package)

`lazy_frame(df)` (or `LazyFrame::from(df)`) starts a deferred plan; total
builder methods mirroring the eager verbs grow it; `explain()` prints it; and
`collect()` runs it. With no optimizer in front, a collect is bitwise-equal to
the eager pipeline. The optimizer adds two result-preserving rewrites —
**predicate pushdown** (sink each filter toward the scan, past the stages it
provably commutes with) and **projection pushdown** (insert a narrowing
selection over a scan whose consumers read only a subset of its columns) — so
`explain()` versus `explain(optimized=true)` is a before/after view of what the
optimizer moved and pruned. `LazyFrame::group_by(keys).agg(exprs)` is the lazy
mirror of the eager grouping.

### Join — duplicate-key check and backend preservation

- `join` now rejects a **key repeated in `on`** with `DuplicateColumn`,
  matching `group_by(["id", "id"])` and `select`'s "no duplicate keys"
  contract (previously `on = ["id", "id"]` silently behaved as the single key
  `["id"]`). A *missing* repeated key still surfaces as `ColumnNotFound` at its
  first appearance.
- Join output columns now **preserve the storage backend** of their source
  where they pick up no unmatched-row null — an all-valid `Numeric` source
  column stays `Numeric` instead of demoting to `Builtin`, matching `filter` /
  `sort_by` / `take` / `drop_nulls` / `fill_null`. Only the representation
  changes; values and dtypes are identical.

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
locked-in dtype: fail with `ParseError(Cell(...))` (lossless) or
downgrade that one cell to a null and keep going (Polars'
`ignore_errors=True`), with the column keeping its inferred dtype. CSV
additionally gains
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
