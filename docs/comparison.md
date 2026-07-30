# MoonFrame and Polars / pandas

MoonFrame is an **original MoonBit implementation** — no Polars or pandas
source was translated. What it borrows is the *shape*: the DataFrame and
expression API and the column semantics are modeled on
[Polars](https://pola.rs) (the primary reference), with a few I/O
conventions from [pandas](https://pandas.pydata.org). This page records what
is aligned, what deliberately differs, and what is out of scope, so a Polars
user knows what to expect.

## Attribution

| Project | Borrowed | License |
|---|---|---|
| [Polars](https://github.com/pola-rs/polars) | DataFrame / expression API, column / null / NaN semantics | MIT |
| [pandas](https://github.com/pandas-dev/pandas) | some I/O conventions (`to_json` non-finite handling, `read_json(lines=True)`) | BSD-3-Clause |

MoonFrame itself is Apache-2.0 (see [LICENSE](../LICENSE)). It is a
behavioral reimplementation — modeled on the *documented behavior* of these
libraries — not a derivative work of either codebase.

## Aligned with Polars

- **The four verbs take expressions** — `select` / `filter` / `with_columns`
  take `Expr`s on both `DataFrame` and `LazyFrame`, and so does `agg`, reached
  as `group_by(keys).agg(aggregations)` through the grouped intermediate each
  layer returns; the `sort` / `group_by` / `join` / `drop` keys are expressions
  too.
- **Expression engine** — `col` / `lit_*`, arithmetic `+ - * /` plus
  `floor_div` / `modulo` / `pow` and the unary `abs` / `floor` / `ceil` /
  `sign` / `round`, Kleene `& |`, comparisons and the `is_in` / `is_between` /
  `is_null` / `is_nan` predicates, `when / then / otherwise`, the aggregations
  (`sum` / `mean` / `min` / `max` / `count` / `std` / `variance` /
  `median` / `n_unique` / `first` / `last`), a `str_*` namespace with both
  literal and regex matching (`str_contains` / `str_replace` / `str_replace_all`
  take `literal?`; `str_extract` / `str_count_matches` are regex-only), and the
  `map_elements` / `map_batches` / `map_many` UDF escape hatch. Per-operator
  rules — dtype, null, and `NaN` — are in [`api.md`](api.md).
- **`null` is missing** — a null propagates through arithmetic and
  comparison (Arrow / Polars); `&` / `|` are three-valued (Kleene).
- **`NaN` is a value, not missing** — `sum` / `mean` propagate `NaN`;
  `min` / `max` skip it (as in Polars); `n_unique` buckets every `NaN` as one
  value; comparisons treat `NaN` as a value. Only `null` is missing.
  (`median` also skips `NaN`, a deliberate deviation — see below.)
- **`group_by`** — a **null key forms its own group** (the Polars default;
  pandas drops null keys), `NaN` keys compare equal, and group order is
  first appearance (`maintain_order=True`).
- **`join`** — a **null key matches nothing** (`null != null`, the
  SQL / Polars rule), `NaN` keys match each other, the collision suffix
  defaults to `_right`, and coalesce follows Polars' per-`how` rule.
- **`/` is always `Float`** — integer operands promote; division by zero is
  IEEE `±inf` / `NaN`, never a trap.
- **Whole-frame vs single-column reductions** — `df.sum()` returns a
  one-row frame (Polars' `df.sum()`); a scalar comes from
  `df.get_column(c).sum()` (Polars' `df[c].sum()`).
- **`unique(subset?, keep?)`** keeps first-appearance order
  (`maintain_order=True`), dedups on a column subset when given one, and takes
  Polars' `keep` strategies (`First` / `Last` / `None`).
- **Lazy file sources** — `scan_csv` / `scan_ndjson` with both projection and
  predicate pushdown into the reader; there is no `scan_json` for the
  single-array shape (it must be parsed whole, the same reason Polars has
  `scan_ndjson` but not `scan_json`).
- **I/O inference** — `infer_schema_rows = 0` scans every row (Polars'
  `infer_schema_length=None`); `on_parse_error = Null` downgrades a bad cell
  to null (Polars' `ignore_errors=True`); a non-finite `Float` writes as
  JSON `null` (pandas' `to_json`).

## Deliberate differences

Where MoonFrame knowingly does something else than Polars. Two are about
`NaN`, one about mixed-dtype comparison, and one about how a call is
configured.

- **`sort` treats `NaN` as missing.** When sorting, a `Float` `NaN` is ordered
  by the key's `NullOrder` (like a null), whereas Polars treats `NaN` as a
  value that sorts last independently of `nulls_last`. This is a deliberate
  divergence, not an oversight.
- **`median` skips `NaN`.** As an order statistic it follows the `min` / `max`
  rule and ignores `NaN`, whereas Polars propagates `NaN` through `median`.
- **Mixed `Int` / `Float` comparison is exact.** An `Int64` compared against a
  `Float` is *not* promoted to `Double` first, so two distinct values never
  collide above 2^53: `Int64::MAX` is not equal to the `2^63` `Double` a
  promotion would round it to. Polars applies its Float64-supertype rule and
  compares the rounded values. Correctness was chosen over parity here; it
  shows in the comparison operators and the predicates built on them
  (`is_in` / `is_between`). Same-dtype comparisons are exact either way, and a
  join refuses a mixed-dtype key outright rather than deciding for you.
- **Configuration is an options struct**, not a bag of per-call arguments:
  `read_csv(path, options=CsvReadOptions::CsvReadOptions(delimiter=';'))` where
  Polars takes `pl.read_csv(path, separator=";")`. Not a language limit —
  MoonBit has labelled optional parameters, and the options constructors are
  built out of them (`CsvReadOptions::CsvReadOptions(delimiter=';')` names one
  field and defaults the rest). It is about what the parameter *is*: one value a
  caller can name once and reuse across reads, pass through a helper that knows
  nothing about its fields, and gain a field on without any signature changing.
  The same struct then serves the eager reader and its `scan_*` counterpart.

For `NaN` everywhere else — `sum` / `mean` / `group_by` / `join` /
comparisons — it is a value, as in Polars.

## Forced by MoonBit (not behavioral)

These read differently from Polars but are language constraints, not
semantic choices:

- Comparisons are **methods** (`eq` / `ne` / `lt` / `le` / `gt` / `ge`), not
  `==` / `<`, which MoonBit pins to `Bool` / `Int` returns.
- `&` / `|` are Kleene-logical (not bitwise); the method spellings are
  `land` / `lor` (`and` is a reserved word, so there is no `Expr::and`). <!-- doc-guard: unresolved -->
- Names dodging reserved words: `with_alias` (`alias`), `variance` (`var`),
  `LazyFrame::LazyFrame(df)` rather than `lazy(df)` or `df.lazy()` (`lazy`).

## Out of scope (vs Polars)

Not implemented. The tracked deferrals — the ones with a place in a later
release — are listed as such in [`api.md`](api.md); this is what a Polars user
will not find here today:

- **Dtypes** — only `Int` / `Float` / `Bool` / `String` / `Null`; no
  `Date` / `Datetime` / `Duration` / `List` / `Struct` / `Categorical`. This is
  the deferral the others hang off: the list-returning `str.split`, the datetime
  expression family, and a reader that takes a declared schema all need a dtype
  before they can exist.
- **Expressions** — no window / rolling / `over` functions, no cumulative or
  `shift` / `diff` family, and no `pivot` / `melt` reshaping.
- **Lazy** — no streaming execution: a scan pushes projections and predicates
  down into the reader, but still tokenises the whole file. No columnar sources
  (`scan_parquet` / `scan_ipc`) either — those wait on eager readers for the
  formats.
- **Optimizer** — the two passes are projection and predicate pushdown.
  Dead-expression elimination, predicate splitting through joins, and sinking
  filters below sorts are not implemented.
- **Reader schema override** — CSV / JSON dtypes come from content inference
  only; there is no `dtypes=` / `schema=` parameter. Build the frame yourself
  (`Series::from_*`, or `from_rows` with a `Schema`) when a column's type must
  be pinned. See [`type-inference.md`](type-inference.md).

See [`api.md`](api.md) for the API concepts and compatibility model, the
per-symbol reference on
[mooncakes.io](https://mooncakes.io/docs/ihb2032/MoonFrame), and
[`migration.md`](migration.md) for the version history.
