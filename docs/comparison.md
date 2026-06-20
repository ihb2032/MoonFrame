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

- **The four verbs take expressions** — `select` / `filter` / `agg` /
  `with_columns` each take `Expr`s, on both `DataFrame` and `LazyFrame`, as
  do the `sort` / `group_by` / `join` / `drop` keys.
- **Expression engine** — `col` / `lit_*`, arithmetic `+ - * /`, Kleene
  `& |`, comparisons, `when / then / otherwise`, the aggregations
  (`sum` / `mean` / `min` / `max` / `count` / `std` / `variance` /
  `median` / `n_unique` / `first` / `last`), a `str_*` namespace, and the
  `map_elements` / `map_many` UDF escape hatch.
- **`null` is missing** — a null propagates through arithmetic and
  comparison (Arrow / Polars); `&` / `|` are three-valued (Kleene).
- **`NaN` is a value, not missing** — `sum` / `mean` propagate `NaN`;
  `min` / `max` / `median` skip it; `n_unique` buckets every `NaN` as one
  value; comparisons treat `NaN` as a value. Only `null` is missing.
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
- **`unique()`** keeps first-appearance order (`maintain_order=True`).
- **Lazy file sources** — `scan_csv` / `scan_ndjson` with projection
  pushdown; there is no `scan_json` for the single-array shape (it must be
  parsed whole, the same reason Polars has `scan_ndjson` but not
  `scan_json`).
- **I/O inference** — `infer_schema_rows = 0` scans every row (Polars'
  `infer_schema_length=None`); `on_parse_error = Null` downgrades a bad cell
  to null (Polars' `ignore_errors=True`); a non-finite `Float` writes as
  JSON `null` (pandas' `to_json`).

## Deliberate differences

- **`sort` treats `NaN` as missing.** This is MoonFrame's one intentional
  behavioral deviation: when sorting, a `Float` `NaN` is ordered by the
  key's `NullOrder` (like a null), whereas Polars treats `NaN` as a value
  that sorts last independently of `nulls_last`. Everywhere else
  (`sum` / `mean` / `group_by` / `join` / comparisons) `NaN` is a value, as
  in Polars. This was the v0.2 design choice and is kept through v0.5.

## Forced by MoonBit (not behavioral)

These read differently from Polars but are language constraints, not
semantic choices:

- Comparisons are **methods** (`eq` / `ne` / `lt` / `le` / `gt` / `ge`), not
  `==` / `<`, which MoonBit pins to `Bool` / `Int` returns.
- `&` / `|` are Kleene-logical (not bitwise); the method spellings are
  `land` / `lor` (`and` is a reserved word, so there is no `Expr::and`).
- Names dodging reserved words: `with_alias` (`alias`), `variance` (`var`),
  `lazy_frame` / `LazyFrame::from` (`lazy`).
- Options structs instead of keyword arguments (`JoinOptions`,
  `CsvReadOptions`, …), since MoonBit has no kwargs.

## Out of scope (vs Polars)

Not implemented; some are on the v0.6+ roadmap (see
[changelog](changelog.md)):

- **Dtypes** — only `Int` / `Float` / `Bool` / `String` / `Null`; no
  `Date` / `Datetime` / `List` / `Struct` / `Categorical`.
- **Expressions** — no window / rolling functions, no `pivot` / `melt`;
  arithmetic is `+ - * /` only (no `pow` / `mod` / `abs` / `round` /
  `floor_div` yet); string matching is literal (no regex engine yet).
- **Lazy** — projection pushdown only (no predicate-into-parser or streaming
  execution); no `scan_parquet` / `scan_ipc`.
- **`unique`** — whole-row only (no `subset` / `keep`).

See [`api.md`](api.md) for the full public surface and
[`migration.md`](migration.md) for the version history.
