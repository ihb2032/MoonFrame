# Performance notes

MoonFrame is built on an Apache Arrow-style **columnar** layout. This page
records the complexity of each operation and the storage design behind it.
These are analytical notes on complexity and layout; for measured throughput a
`moon bench` suite lives alongside the tests (see [Benchmarks](#benchmarks)).

## Data model

- **Column-oriented.** A `DataFrame` is an array of typed `Series` columns.
  Row-oriented work reads each column in bulk rather than cell-by-cell: the
  JSON / CSV / NDJSON record emitters take one whole-frame
  `to_scalar_matrix()` read, while table rendering (`to_markdown` /
  `to_html`) scalarises only the visible row window, per column.
- **Validity bitmap.** Nulls live in a byte-packed bitmap (1 bit per row,
  `1 = valid`) kept separate from the data buffer — Arrow's representation.
- **`O(1)` column lookup.** A `name → index` map backs `get_column` and
  every name resolution, so accessing a column in a wide frame never scans.

## The `Numeric` fast path

An all-valid `Int` / `Float` column is stored as a `NumericColumn` that
carries **no validity bitmap**:

- construction allocates no bitmap `Bytes`;
- reductions (`sum` / `mean` / `min` / `max`) skip the per-slot validity
  check — the `null_count == 0` fast path;
- structural transforms (`slice` / `gather` / `head` / `tail` / `filter` /
  `sort` / `join`) keep the column on the fast path where it gains no null,
  and any all-valid numeric result **re-converges** onto `Numeric`.

The moment a null would enter, the column materializes back to the general
`Builtin` backend, so the fast path is a representation optimization, never a
correctness fork — values and dtypes are identical either way.

## Slicing

`slice` / `head` / `tail` (and `DataFrame::slice`) copy the sliced row data
into a fresh buffer but share the parent's validity bitmap as a zero-copy
view, advancing the bitmap `offset` instead of repacking it (a `Numeric`
column carries no bitmap, so only its data is copied, and an all-valid
`Numeric` sub-range stays `Numeric`). Equality is logical: a slice compares
equal to a freshly built column with the same cells, regardless of the shared
bitmap's `offset`.

## Operation complexity

For a frame of `n` rows and `c` columns:

| Operation | Complexity | Notes |
|---|---|---|
| `get_column` / name lookup | `O(1)` | `name → index` map |
| `filter` | `O(n)` eval + `O(k)` gather | `k` = surviving rows |
| `select` / `with_columns` | `O(n)` per expression | vectorized, whole-column |
| `sort` | `O(n log n)` | stable, multi-key |
| `group_by(...).agg(...)` | `O(n)` | hash partition on a composite key cell; each reduction folds a group over its own indices |
| `join` | `O(n + m)` | hash equi-join, build + probe (plus output size) |
| `unique` | `O(n)` | hash on the composite row key |
| `sum` / `mean` / `min` / `max` / `count` | `O(n)` | single pass; `Numeric` skips validity |
| `format_*` (JSON / CSV / NDJSON) | `O(n · c)` | one whole-frame `to_scalar_matrix` read |
| `to_markdown` / `to_html` | `O(shown · c)` | scalarises only the rows shown — a row cap touches `shown`, not `n` |

## Lazy execution

`collect()` runs two result-preserving rewrites before executing, and the
output is **bitwise-equal** to the eager pipeline (with one documented
exception, noted below):

- **Predicate pushdown** sinks each `filter` toward the scan, so rows drop
  as early as the operator provably commutes with the predicate.
- **Projection pushdown** narrows each scan to the columns its consumers
  actually read. For a file source (`scan_csv` / `scan_ndjson`) the column
  set is pushed into the reader, so a column no stage reads is **never
  parsed** —
  `scan_csv("sales.csv").select([col("region"), col("revenue")]).collect()`
  parses only those two columns.

Because a pruned column is never parsed, a parse error confined to it — or to a
row a pushed-down predicate drops, in a column the predicate does not read — is
what an optimized plan will not surface that a full eager read would: the
intentional divergence from bitwise equality, and it only applies to file
sources (`scan_csv` / `scan_ndjson`).

See [`api.md`](api.md) for the per-operation semantics and
[`comparison.md`](comparison.md) for how the semantics line up with Polars.

## Benchmarks

Beyond the complexity notes above, a `moon bench` micro-benchmark suite measures
real throughput. Run it from the repo root with `moon bench`.

Each library package carries a `bench_test.mbt` file. Because the benches are
ordinary test blocks, `moon check` compiles them and `moon bench` executes
them — and CI runs both, so a benchmark that stops compiling or running fails
the build. There is deliberately **no** performance threshold, since timings
are machine-dependent and a pass/fail bar would be flaky. The suite covers, at
1K / 100K / 1M rows where scaling is informative:

- **`series`** — construction, and reductions (`sum` / `mean` / `min` / `max` /
  `count`) contrasting the `Numeric` fast path against the general `Builtin`
  backend, plus `gather` / `slice`.
- **`frame`** — `filter`, `with_columns`, `unique`, inner `join`, `sort`, and
  `group_by(...).agg(...)`.
- **`io`** — `parse_csv_str` and `parse_ndjson_str` throughput.
- **`lazy`** — the same `filter` + `group_by` + `sum` pipeline run eagerly and
  through the lazy optimizer.

The headline result confirms the design intent: on all-valid numeric columns the
`Numeric` backend reduces several times faster than `Builtin` — roughly an order
of magnitude for `sum` at 1M rows — while `count` stays `O(1)`. Exact figures
vary by machine; run the suite locally for numbers on your hardware.
