# Performance notes

MoonFrame is built on an Apache Arrow-style **columnar** layout. This page
records the complexity of each operation and the storage design behind it.
These are analytical notes; measured micro-benchmarks (via `moon bench`) are
a planned addition.

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
output is **bitwise-equal** to the eager pipeline:

- **Predicate pushdown** sinks each `filter` toward the scan, so rows drop
  as early as the operator provably commutes with the predicate.
- **Projection pushdown** narrows each scan to the columns its consumers
  actually read. For a file source (`scan_csv` / `scan_ndjson`) the column
  set is pushed into the reader, so a column no stage reads is **never
  parsed** —
  `scan_csv("sales.csv").select([col("region"), col("revenue")]).collect()`
  parses only those two columns.

See [`api.md`](api.md) for the per-operation semantics and
[`comparison.md`](comparison.md) for how the semantics line up with Polars.
