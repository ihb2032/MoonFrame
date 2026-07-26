# Performance notes

> Documents the unreleased v0.6 API; `moon add` installs the published
> v0.5.8, whose reference is on mooncakes.io. See [Install](../README.md#install).

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

For a frame of `n` rows and `c` columns. Two costs are easy to conflate, so
they are separated below: **deciding** which rows come out (evaluating a
predicate, ordering keys, hashing) and **materialising** them. Any verb that
rebuilds rows pays the second across every column it carries — `k` output rows
cost `O(k · c)`, whatever the first column cost. A verb driven by expressions
also scales with how many it is given, and with the size of each tree; `e`
below counts expressions, not nodes.

| Operation | Decide | Materialise | Notes |
|---|---|---|---|
| `get_column` / name lookup | `O(1)` | — | `name → index` map |
| `filter` | `O(n · e)` predicate eval | `O(k · c)` | `k` = surviving rows; the gather rebuilds every column |
| `select` / `with_columns` | `O(n)` per expression | `O(n)` per output column | vectorized, whole-column |
| `sort` | `O(n log n)` comparisons over the key columns | `O(n · c)` | stable, multi-key; each key is evaluated once into a column |
| `group_by(keys).agg(aggs)` | `O(n · keys)` to build the composite key cells, then `O(n)` per aggregate | `O(g · (keys + aggs))` | `g` = groups; each reduction folds a group over its own indices |
| `join` | `O(n + m)` hash build + probe on the key columns | `O(r · c)` | `r` = output rows, which for a many-to-many match exceeds both inputs |
| `unique` | `O(n · c)` to build a row key from every column (`O(n · s)` for a `subset` of `s`) | `O(k · c)` | hash on the composite row key |
| `sum` / `mean` / `min` / `max` / `count` | `O(n)` per column | `O(c)` | single pass; `Numeric` skips validity |
| `format_*` (JSON / CSV / NDJSON) | — | `O(n · c)` | one whole-frame `to_scalar_matrix` read |
| `to_markdown` / `to_html` | — | `O(shown · c)` | scalarises only the rows shown — a row cap touches `shown`, not `n` |

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

The four packages that own a `bench_test.mbt` file are `series`, `frame`, `io`,
and `lazy`; the packages that only define values or build trees (`types`,
`expr`, `internal/text` / `internal/literal` / `internal/ir`) have nothing to
time. `internal/kernel` does real work — it is where the vectorized column
passes live — but it is measured through the `frame` expression benchmarks that
drive it, which is what a caller actually pays; a regression isolated to one
kernel would want its own micro-benchmark added here. Because the benches are
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
`Numeric` backend reduces several times faster than `Builtin`, the widest gap
being `sum` at 1M rows, while `count` on `Numeric` is `O(1)` — it has no
validity bitmap to scan (the general `count` is the `O(n)` per-column pass the
complexity table lists; a compact `Builtin` bitmap scans in about `O(n / 8)`).
No ratio is quoted here on
purpose — the repo pins no reference hardware and stores no baseline output, so
any number printed in prose would drift with the implementation and the
toolchain. Run `moon bench` for figures on your own machine.
