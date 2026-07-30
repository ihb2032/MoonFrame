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
- **`O(1)` column lookup.** A `name → index` map backs every name resolution —
  the frame's own cache behind `get_column`, and the schema's behind `index_of` /
  `field` / `select` / `rename` — so a wide frame never scans a name array,
  whether the question reaches it through the columns or through the schema.

## The `Numeric` fast path

An `Int` / `Float` column carrying no nulls *can* be stored as a
`NumericColumn`, which has **no validity bitmap**:

- construction allocates no bitmap `Bytes`;
- reductions (`sum` / `mean` / `min` / `max`) skip the per-slot validity
  check — the `null_count == 0` fast path;
- `count` needs no scan at all: with no bitmap there is nothing to count.

Content decides which columns land there, never the caller — but only on the
paths that *canonicalise*: `from_ints` / `from_floats`, the row gathers
(`gather` / `filter` / `drop_nulls` / `unique` / `sort` / `join`), and the
expression engine's computed columns, each of which converges onto `Numeric`
when its result has no null. Three kinds of path deliberately do not: the
nullable constructors (`from_*_options` build a `Builtin` column even when every
cell is `Some`), `cast` (its result materializes on `Builtin` whatever it started
from), and the backend-*preserving* transforms (`slice` / `head` / `tail` /
`fill_null`, which hand their source's backend through). So an all-valid numeric
column is not necessarily a `Numeric` one, and reaching the fast path is not a
latch a column can never leave.

None of that is observable through the supported API: the fast path is a
representation optimization, never a correctness fork — values, dtypes and
equality are identical either way. The moment a null enters, the column
materializes back onto the general `Builtin` backend.

## Slicing

`slice` / `head` / `tail` (and `DataFrame::slice`) copy the sliced row data
into a fresh buffer but share the parent's validity bitmap as a zero-copy
view, advancing the bitmap `offset` instead of repacking it (a `Numeric`
column carries no bitmap, so only its data is copied, and an all-valid
`Numeric` sub-range stays `Numeric`). So the *validity* is zero-copy, not the
column: the row data is always a fresh buffer. Equality is logical: a slice
compares equal to a freshly built column with the same cells, regardless of the
shared bitmap's `offset`.

## Operation complexity

For a frame of `n` rows and `c` columns. Two costs are easy to conflate, so
they are separated below: **deciding** which rows come out (evaluating a
predicate, ordering keys, hashing) and **materialising** them. Any verb that
rebuilds rows pays the second across every column it carries — `k` output rows
cost `O(k · c)`, whatever the first column cost. A verb driven by expressions
scales with the *whole* of what it is given, so `E` below is the total node
count across that verb's expressions: evaluating one expression walks its tree
node by node, one vectorized pass each, and a verb handed several walks all of
them. (A `map` / `map_batches` node then calls a caller's closure — once per row
or once per column — and that cost is the closure's own, not counted in `E`.)
Each row reuses the symbols in its own line — `k` is the surviving rows of a
`filter`, `q` the key count of a `sort` / `join`.

| Operation | Decide | Materialise | Notes |
|---|---|---|---|
| `get_column` / name lookup | `O(1)` | — | `name → index` map |
| `filter` | `O(n · E)` predicate eval | `O(k · c)` | `k` = surviving rows; the gather rebuilds every column |
| `select` / `with_columns` | `O(n · E)` over the expressions given | `O(n)` per output column | vectorized, whole-column: one pass per node, never per cell |
| `sort` | `O(n · E)` to evaluate the `q` keys into columns, then `O(n log n · q)` comparisons — a tie on one key falls through to the next | `O(n · c)` | stable, multi-key |
| `group_by(keys).agg(aggs)` | `O(n · E)` for the key and aggregate expressions, plus `O(n · q)` to build the composite key cells | `O(g · (q + a))` | `g` = groups, `a` = aggregates; each reduction folds a group over its own indices |
| `join` | evaluating the key expressions over both frames — `O(n · E)` and `O(m · E)` — then `O((n + m) · q)` to build and probe the composite keys | `O(r · c)` | `r` = **output** rows: matched pairs, plus the unmatched rows `Left` / `Right` / `Outer` keep. A many-to-many match makes it exceed both inputs, and the probe builds a row plan of length `r` before any column is touched |
| `unique` | `O(n · c)` to build a row key from every column (`O(n · s)` for a `subset` of `s`) | `O(k · c)` | hash on the composite row key |
| `sum` / `mean` / `min` / `max` | `O(n)` per column | `O(c)` | single pass; `Numeric` skips validity |
| `count` | `O(1)` on `Numeric`, `O(n)` bits on `Builtin` | `O(c)` | non-null count: a `Numeric` column has none, a `Builtin` one scans its packed bitmap (`n / 8` bytes) |
| `format_*` (JSON / CSV / NDJSON) | — | `O(n · c)` | one whole-frame `to_scalar_matrix` read |
| `to_markdown` / `to_html` | — | `O(shown · c)` | scalarises only the rows shown — a row cap touches `shown`, not `n` |

## Lazy execution

`collect()` runs two rewrites before executing, and a plan that succeeds
produces what the eager pipeline produces — same schema, same
cells, which is what `DataFrame`'s `Eq` compares and what the differential
suite asserts. Not a claim about physical layout: the backend a column lands
on is an internal representation, and two equal frames may hold their cells
differently.

A plan that fails still fails, and a plan with a single broken stage reports
the eager error. Two things can change *which* error you see, or whether a
particular one happens at all: a plan with several independently broken stages
may surface a different one of its own errors once a filter sinks past a broken
stage (which one surfaced was an artifact of stage order to begin with), and a
file source's push-down can prune the data an error was hiding in — see below.

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
what an optimized plan will not surface that a full eager read would. That is
the deliberate one, and it applies only to file sources (`scan_csv` /
`scan_ndjson`); [`api.md`](api.md) states both cases as the plan-level
contract.

See [`api.md`](api.md) for the per-operation semantics and
[`comparison.md`](comparison.md) for how the semantics line up with Polars.

## Benchmarks

Beyond the complexity notes above, a `moon bench` micro-benchmark suite measures
real throughput. Run it from the repo root with `moon bench`.

The four packages that own a `bench_test.mbt` file are `series`, `frame`, `io`, <!-- doc-guard: unresolved -->
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
  backend, plus `gather` / `slice` — including a nullable `Builtin` slice whose
  validity view starts off byte alignment, the input `count`'s byte-at-a-time
  scan has to handle.
- **`frame`** — `filter`, `with_columns`, `unique`, inner `join`, `sort`, and
  `group_by(...).agg(...)`.
- **`io`** — `parse_csv_str` and `parse_ndjson_str` throughput.
- **`lazy`** — the same `filter` + `group_by` + `sum` pipeline run eagerly and
  through the lazy optimizer.

The headline result confirms the design intent: on all-valid numeric columns the
`Numeric` backend reduces several times faster than `Builtin`, the widest gap
being `sum` at 1M rows, while `count` on `Numeric` is `O(1)` — it has no
validity bitmap to scan, where a `Builtin` column reads about `n / 8` bytes of
packed bitmap, as the table above says.
No ratio is quoted here on
purpose — the repo pins no reference hardware and stores no baseline output, so
any number printed in prose would drift with the implementation and the
toolchain. Run `moon bench` for figures on your own machine.
