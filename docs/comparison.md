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

- **Bracket access** — `df["qty"]` reads a column, `s[0]` a cell, and
  `df[1:3]` / `df[2:]` / `df[:-1]` is the bracket-slice sugar: half-open,
  negatives from the end, omitted bounds to the ends. As in Polars, the sugar
  is a translation layer — the bounds normalize into the one
  `slice(offset, length)` kernel — and as in MoonBit, an index bracket does
  not wrap negatives (`s[-1]` raises; the slice spelling is where they count
  from the end).
- **The four verbs take expressions** — `select` / `filter` / `with_columns`
  take `Expr`s on both `DataFrame` and `LazyFrame`, and so does `agg`, reached
  as `group_by(keys).agg(aggregations)` through the grouped intermediate each
  layer returns; the `sort` / `group_by` / `join` / `drop` keys are expressions
  too. The grouped intermediates also carry Polars' per-op conveniences —
  `group_by(k).sum()` / `.mean()` / `.count()` / `.len()` / `.quantile(q)` /
  … — one aggregation over every non-key column, `agg` sugar on the eager
  side and a collect-time tag on the lazy side.
- **Expression engine** — `col` / `lit_*`, arithmetic `+ - * /` plus
  `floor_div` / `modulo` / `pow` / `atan2` / `hypot` and the unary `abs` /
  `floor` / `ceil` / `sign` / `round` alongside the always-`Float` math
  family (`sin` / `cos` / `tan` / `asin` / `acos` / `atan` / `sinh` / `cosh`
  / `tanh` / `asinh` / `acosh` / `atanh` / `ln` / `log2` / `log10` / `exp` /
  `cbrt` / `sqrt`), Kleene `& |`, comparisons and the `is_in` / `is_between` /
  `is_null` / `is_nan` / `is_finite` / `is_infinite` predicates, `when / then /
  otherwise`, `clip`, the `forward_fill` / `backward_fill` directional
  fills, the aggregations
  (`sum` / `mean` / `min` / `max` / `count` / `std` / `variance` /
  `median` / `quantile` / `n_unique` / `first` / `last`), a `str_*` namespace with both
  literal and regex matching (`str_contains` / `str_replace` / `str_replace_all`
  take `literal?`; `str_extract` / `str_count_matches` are regex-only), and the
  `map_elements` / `map_batches` / `map_many` UDF escape hatch, the
  `dt_*` Date components (`dt_year` / `dt_month` / `dt_day` /
  `dt_day_of_week`, the ISO weekday), and the distinct family
  (`unique_counts` / `is_first_distinct` / `is_last_distinct` / `mode`,
  the last tie-broken first-appearance where Polars lists every tied
  value). Per-operator
  rules — dtype, null, and `NaN` — are each stated on the operator's own
  docstring (the generated reference collects them).
- **`null` is missing** — a null propagates through arithmetic and
  comparison (Arrow / Polars); `&` / `|` are three-valued (Kleene).
- **`NaN` is a value, not missing** — `sum` / `mean` / `median` / `quantile`
  propagate `NaN`; `min` / `max` skip it (as in Polars); `n_unique` buckets every `NaN`
  as one value; comparisons treat `NaN` as a value. `sort` orders it by the
  IEEE-754 total order — larger than every other value, so it trails an
  ascending sort and leads a descending one, independently of where the nulls
  sit, and with `-0.0` and `+0.0` ordered equal (the total order relaxed
  exactly where `==` already says they are; a stable sort keeps their input
  order). Only `null` is missing.
- **`group_by`** — a **null key forms its own group** (the Polars default;
  pandas drops null keys), `NaN` keys compare equal, and group order is
  first appearance (`maintain_order=True`).
- **`join`** — a **null key matches nothing** (`null != null`, the
  SQL / Polars rule), `NaN` keys match each other, the collision suffix
  defaults to `_right`, and coalesce follows Polars' per-`how` rule. The
  full `how` set is carried — `Inner` / `Left` / `Right` / `Outer` /
  `Cross` / `Semi` / `Anti`, the last two the left-schema existence
  filters.
- **`Int` / `Float` division is always `Float`** — integer operands promote;
  a `Decimal` pair stays `Decimal`. Division by zero is IEEE `±inf` / `NaN`,
  never a trap.
- **Whole-frame vs single-column reductions** — `df.sum()` returns a
  one-row frame (Polars' `df.sum()`); a scalar comes from
  `df.get_column(c).sum()` (Polars' `df[c].sum()`).
- **`sample(n, with_replacement?, seed?)`** and **`shuffle(seed?)`** are
  deterministic functions of their seed — same seed, same rows, on every
  platform (chacha8, from `core/random`); without replacement, `n` past the
  row count raises rather than saturating. An omitted seed is
  `seed = 0`, so two independent calls that both leave it out draw the
  same rows (Polars draws a fresh seed per call); name a seed when the
  draws must differ. Polars' `fraction` parameter is carried —
  `fraction?` beside `n?`, drawing `max(1, round(fraction × nrows))` rows
  of a non-empty frame.
- **`unique(subset?, keep?)`** keeps first-appearance order
  (`maintain_order=True`), dedups on a column subset when given one, and takes
  Polars' `keep` strategies (`First` / `Last` / `None`).
- **Lazy file sources** — `scan_csv` / `scan_ndjson` / `scan_json` (and the
  columnar `scan_parquet`, covered below) with
  both projection and predicate pushdown into the reader. The pushdowns
  prune the *assembly* — only the consumed columns are built, and only the
  surviving rows' cells are parsed past the predicate's own columns. Two
  levels of "parse" sit under that: the file's records are still
  tokenised whole (a text format cannot skip to a column without
  walking every record), while a cell's *value* is parsed only when a
  surviving column needs it — the level the other docs' "never parsed"
  claims name. Every text file
  source (CSV / JSON / NDJSON), eager and lazy alike, is transparently
  gzip-aware: a file whose
  bytes open with the gzip magic is decompressed before parsing, and the
  `write_*` entry points compress when the target path ends in `.gz`.
  (Polars has
  `scan_ndjson` but no `scan_json`; MoonFrame carries the source, with the
  assembly-level pruning above.)
- **I/O inference** — `infer_schema_rows = 0` scans every row (Polars'
  `infer_schema_length=None`); `on_parse_error = Null` downgrades a bad cell
  to null (Polars' `ignore_errors=True`); a non-finite `Float` writes as
  JSON `null` (pandas' `to_json`); a JSON field of arrays or objects reads
  as a `List` / `Struct` column, as Polars' JSON reader reads it.

## Deliberate differences

Where MoonFrame knowingly does something else than Polars.

- **The chart export has no Polars counterpart.** Polars ships no plotting
  surface (it defers to other libraries); MoonFrame carries one — the
  frame-first `plot(df).bar(x="region", y="revenue").write_html("out.html")`
  chain (the nearest analogue elsewhere is pandas' `df.plot.bar(x=, y=)`),
  over a typed mirror of Vega-Lite v6 whose facts live in the vendored
  schema.
- **A CSV header of all-empty names raises.** `",,"` as a header row is
  `DuplicateColumn("")` — the empty name repeats. Polars instead
  disambiguates repeated header names (`_duplicated_0` suffixes) and
  reads on; rename the columns after a `read_csv` on mangled source data,
  or fix the header.
- **`describe` summarises differently.** MoonFrame's summary carries the
  statistics as columns — one row per source column, eleven columns:
  `column` (the name) / `dtype` / `count` / `null_count` / `n_unique` /
  `mean` / the three quartiles
  (linear) / `min` / `max`, with `min` / `max` rendered as `String` so
  one table carries every dtype; Polars puts the statistics on the
  rows instead (`count` / `null_count` / `mean` / `std` / `min` / the
  three quartiles / `max`, all numeric) — MoonFrame omits `std` (the
  per-column `Series::std` carries it), and the `String` rendering is a
  table-shape choice.
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
- **`is_in` inherits `==`, so a `NaN` member matches nothing.** Every member
  is compared exactly as `a.eq(lit(member))` would, and IEEE `NaN != NaN`;
  Polars' `is_in` compares by total equality and matches it. The split is
  deliberate: `is_in` stays the OR of `eq` and cannot drift from it — the
  key-based verbs (`n_unique` / `group_by` / `join`) are where `NaN` buckets
  as one value, on the other side of that line.
- **`when` treats a null condition as unknown, Polars' as false.** A null
  condition cell yields a null output (the Kleene reading, consistent with
  `&` / `|`); Polars' `when` takes null as false and reads the `otherwise`
  branch. Add an explicit `is_null()` branch when the Polars reading is the
  one wanted.
- **Whole-frame `sum` / `mean` leave a non-numeric column a `Null` cell,
  but `min` / `max` answer for every orderable dtype.** A `Date` /
  `Timestamp` / `Duration` column reduces to `Null` under `sum` / `mean`
  and to its own value under `min` / `max` — the same order those
  columns' own `Series::min` / `max` read; `Decimal` is the one wider
  dtype — `sum` folds the engine's value arithmetic (each addition
  rounds to 34 digits, so a large total can lose low digits), its `mean`
  a `Null`; `Bool` / `String` columns null under all four; a nested
  column (`List` / `Struct`) nulls under `sum` / `mean` and answers under
  `min` / `max` by the order its sort reads.

For `NaN` everywhere — `sum` / `mean` / `median` / `quantile` / `sort` / `group_by` /
`join` / comparisons — it is a value, as in Polars.

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

The gaps and tracked deferrals, per area. Some entries below are mostly
present — the entry says what is there and names the part that is not;
the truly absent follow the same list. What a Polars user will not find
here today:

- **Dtypes** — `Int` / `Float` / `Bool` / `String` / `Null` plus the three
  `I64`-rider dtypes `Date` (days), `Timestamp` (microseconds, UTC — the
  granularity of Polars' `Datetime("us")`, without time zones or calendar
  arithmetic), `Duration` (a microsecond span, produced and consumed by
  the temporal arithmetic: `Timestamp − Timestamp`, `instant ± Duration`),
  and `Decimal` (an IEEE 754 decimal128 floating-point decimal:
  `+` / `-` / `*` / `/` and `sum` over the engine's exact-then-round
  arithmetic, `round` the quantize, a `Float` operand promoting to
  `Float`), and the two nested dtypes `List(element)` / `Struct(schema)`:
  a column of lists or of records, built from values or read from JSON
  and carried whole — sorted, compared, grouped, and joined by the rules
  the dtype's docstring states — where Polars also computes into one.
  Still missing: `Categorical`, and the expressions that build a nested
  column from scalar cells (`str.split` into a list, a struct's field
  access, the `list.*` namespace) — the verbs read a nested column; none
  produces one.
- **Expressions** — the window wrapper `over` is present: an aggregating
  inner broadcasts over its group, a group-length inner lands
  cell-for-cell (Polars' `over` semantics; nesting windows in windows or
  in `agg` refuses). The history-dependent
  family — `shift` / `diff`, the `cum_*` running aggregates, `rank`,
  `arg_sort` — is present, as are the positional reductions `arg_min` /
  `arg_max`, the rolling core (`rolling_sum` / `mean` / `min` / `max` /
  `std` / `variance` / `median`, with `min_samples` and `center`; Polars'
  `weights` is not carried) and the exponentially-weighted
  `ewm_mean` / `ewm_std` / `ewm_variance` (the biased estimator; Polars'
  unbiased `bias=false` correction is not carried). The reshapes are
  present too — `pivot` / `unpivot` on both layers — with unpivot's value
  column requiring a
  unifying dtype (`Int` / `Float` widen; no stringly supertype).
- **Lazy** — batch-wise execution, not Polars' parallel streaming engine:
  a tree-shaped plan walks a morsel pipeline where row-local verbs (a
  filter, a row-stable selection) ride each batch in flight, positional
  windows (`head` / `tail` / `slice` with forward bounds,
  `gather_every`, `with_row_index`) ride it too carrying their place
  across the boundaries, and row-global verbs (a sort, an aggregation, a
  join) materialise —
  `LazyFrame::collect_batches` hands the batches to the consumer as they
  answer, and `sink_parquet` / `sink_csv` / `sink_json` / `sink_ndjson` turn
  the same stream to a file (one row group per batch; the exact
  `format_csv` / `format_json` / `format_ndjson` bytes), so a plan ending
  in flow verbs runs in bounded memory. `sink_parquet` / `sink_csv` /
  `sink_ipc` / `sink_ndjson` take a `PartitionBy` beside the path, as
  Polars' sinks take its partitioning configuration: the rows go to
  files under a directory, one a distinct value of the key columns
  (`region=Americas/year=2020/00000000.parquet`, a null
  `__HIVE_DEFAULT_PARTITION__`, the key columns left out on request),
  or so many rows a file. The layout is the reference's — eight-digit
  file names, the format's extension — where the spelling of a value
  differs: the characters a path cannot hold are percent-encoded here,
  including the ones Windows forbids, where the reference leaves some
  of them raw. A full file is written as soon as the next row comes,
  the rest when the plan has answered. The
  scans push projections, predicates, and row windows down into the
  reader, but the text formats still tokenise the whole file, and a
  blocking verb holds its whole input (no spilling). The columnar
  side is native: `scan_parquet` skips decoding the unpicked chunks — the
  file's bytes are still read whole, but only the projected chunks' pages
  decode — and a sunk `head` / `tail` / `slice` skips the row groups outside its
  window outright (multi-row-group files read; a written file's layout
  is `write_parquet`'s `row_group_rows~`),
  over a module-internal reader / writer
  (`read_parquet` / `write_parquet`) — a `FLOAT` column refuses on read
  rather than silently narrowing. Arrow IPC reads and writes over a
  module-internal codec too (`read_ipc` / `write_ipc`, and `scan_ipc` /
  `sink_ipc` with the same window skipping), where Polars builds on
  Arrow's own implementation: a column whose type the mapping does not
  carry — a union, an interval, a time of day, a view type — refuses by
  name instead of reading approximately.
- **SQL** — `read_sql` runs a query through the moondb contract (any
  moondb driver: the contract's own in-memory `MockDriver`, moonsqlite,
  moonpostgres, …) rather than through a database binding of MoonFrame's
  own, the way Polars reaches for connectorx / ADBC and pandas for
  SQLAlchemy / DBAPI2. The cell-to-dtype mapping is MoonFrame's own
  (`Time` / `Numeric` texts parse into `Timestamp` / `Decimal`).
  `write_sql` is the other direction — pandas' `to_sql`, Polars'
  `write_database` — over plain `CREATE TABLE` / `INSERT` statements
  spelled for the driver's dialect, where the two reach for ADBC's and
  SQLAlchemy's bulk paths; `read_sql_table` reads a table by name.
  `scan_sql` streams a query through the driver's cursor, batch by batch,
  with a sunk `head` stopping the read at its end — pandas'
  `read_sql(chunksize=…)` streams by chunks the same way, each typed on
  its own, where MoonFrame holds every batch to its first batch's dtypes
  and refuses a column that would have widened.
- **Fixed-width files** — `read_fwf` reads a file of fixed-width lines
  as a frame over a column logic inside the module, as pandas' `read_fwf`
  does; Polars' I/O reference carries no fixed-width entry. The layout is
  inferred from the first lines the same way — a field begins where a
  line has a separator and then a character that is none, the whitespace
  around a field is not its cell, leading indentation names no field —
  or named by `widths` or `colspecs`; the columns are typed by the CSV
  reader's rule, where pandas infers its own. `names` name the columns in
  place of the header's while the header row is still consumed under
  `has_header`, where pandas' default consumes no header once `names` is
  given; a headerless column is `column1`, `column2`, … where pandas
  numbers its; an empty text, or one of blank lines alone, answers the
  `0×0` frame where pandas raises. `skiprows`, `infer_nrows` and a
  transparently gzip path read as in CSV.
- **Excel** — `read_excel` reads a sheet and `write_excel` writes one,
  over the `mbtexcel` workbook library, where pandas reaches for openpyxl
  and Polars for calamine. The sheet is taken by name
  (`ExcelReadOptions`), the first by default, and `excel_sheets` names
  them; pandas also takes one by position. A date is a number under a
  date format in each: the formats every locale shares are read as dates
  and times, and the formats a locale re-spells as the numbers they also
  are, since the same format id is a date in one workbook and an
  accounting format in another's. A column takes the narrowest dtype
  holding every value in it, the CSV reader's rule.
- **Avro** — `read_avro` reads a file's record as a frame and
  `write_avro` writes one, over a codec inside the module, as Polars'
  `read_avro` / `write_avro` do; pandas' I/O reference carries no Avro
  entry. A file's blocks are stored as encoded or compressed by deflate,
  snappy, or zstandard, and under another codec the read refuses by the
  codec's name. Where the format says more than a column holds, the
  mapping refuses rather than reading approximately: a nanosecond
  timestamp (a timestamp here holds microseconds), a union of more than a
  null and one type, a `bytes` or fixed field that is not a decimal
  (there is no binary column), a decimal past 34 significant digits. A
  time of day reads as the instant on the epoch day, the library having
  no time-of-day type. There is no lazy source: a file is read whole.
- **Stata** — `read_stata` reads a dataset as a frame and `write_stata`
  writes one, over a codec inside the module, where pandas carries its
  own reader and writer; Polars' I/O reference carries no Stata entry.
  Releases 113 to 119 read in either byte order and 118 is written. A
  numeric cell outside its storage's valid range reads as missing, the
  rule pandas' reader applies, and a variable under a date format reads
  as a `Date` or a `Timestamp`. Value labels are not applied — there is
  no categorical dtype — so a labelled variable reads as the numbers it
  stores, where pandas' `convert_categoricals` builds one. A name is
  never changed: a write refuses a name the format forbids (one to 32 of
  letters, digits and `_`, not opening with a digit, not a reserved word,
  not repeated). There is no chunked or iterated read.

- **XML** — `read_xml` reads the elements a path names as the rows of a
  frame and `write_xml` writes one back, over an event reader, where
  pandas' `read_xml` / `to_xml` ride lxml or ElementTree; Polars' I/O
  reference carries no XML entry. A row's columns are its attributes, its
  own text, and its direct child elements — the cells pandas takes — and
  a path is element names and `*`, from the document element, from its
  children, or at any depth below it, where pandas takes XPath. A cell's
  text has the whitespace around it cut, where pandas keeps it; a column
  takes the narrowest dtype holding its values by the CSV reader's rule,
  where pandas infers its own (a `NaN` text is a missing cell there and a
  `Float` cell here, and a column of nothing but missing cells is numeric
  there and `String` here); and a path that selects nothing reads as a
  frame of no row, where pandas raises. A document's declared encoding is
  UTF-8, UTF-16, or ISO-8859-1, or it refuses by name, where pandas decodes
  what its codecs carry. No stylesheet is applied and there is no iterated
  read.
- **HTML tables** — `read_html` reads every table a page holds, a frame a
  table in the order the page opens them, with a tokenizer of its own that
  walks the document once, where pandas' `read_html` rides lxml, bs4, or
  html5lib; Polars' I/O reference carries no HTML entry. The header rows,
  the cells' spans, the text a cell holds, the missing-value spellings,
  and the thousands separator follow the reference. A table with no header
  names its columns `column1`, `column2`, … where the reference numbers
  them, a header cell left empty the same way where the reference writes
  `Unnamed: N`, and a header of several rows has its levels joined by a
  space where the reference keeps a tuple. A span that is not a number is
  one, where the reference raises; a header naming one column twice
  raises here and is renamed there; a column takes the CSV reader's dtype
  rule, so a `NaN` text is a missing cell in both and `inf` a float; and a
  table's grid is bounded where the reference lays out whatever a span
  claims. `match`, `attrs`, `header`, `skiprows`, `converters`, and
  `extract_links` are not carried, and there is no `to_html` round trip:
  `to_html` renders a frame for display.
- **LaTeX** — `to_latex` renders a frame as a booktabs-ruled `tabular` —
  a `longtable` on request — with an index column, a derived column
  specification and a caption / label / placement, as pandas' `to_latex`
  does; Polars has none. The cells render as this library's other
  renderers spell them (a float as it is stored, a boolean lower-case,
  six digits only on a timestamp), where pandas writes six decimals under
  a float and spells a boolean `True`. A null renders as `NaN`, as in
  pandas, and `na_rep` renames it. A column name and a string cell are
  escaped by default — pandas' renderer leaves its default unescaped — and
  `escape=false` lets a cell carry LaTeX. Styling, per-column formatters,
  sparsified headers and merged cells are not carried; a header omitted
  leaves no rule under the top rule, where pandas keeps one, and a frame
  of no column renders as the empty string.

- **SAS** — `read_sas` reads a Version 5 transport file (XPORT) or a
  SAS data set (`sas7bdat`, Versions 7 to 9), whichever the file opens
  as, and `write_sas` writes a transport file, over codecs inside the
  module, where pandas' `read_sas` reads both formats and has no writer;
  Polars' I/O reference carries no SAS entry. A numeric variable reads as
  `Float` and the 28 missing spellings as nulls in both. A variable under
  a date format reads as a `Date`, under a time or a datetime format as a
  `Timestamp` — only while every present cell is a whole number of the
  unit, one that is not leaving the column `Float`. In a transport file
  pandas' reader converts no dates; in a data set it converts by its own
  list of formats, and the time formats it leaves as numbers read as
  times here, as a fractional day it rounds to a date stays `Float` here.
  In a transport file the observations end at the last byte that is not a
  blank, where pandas counts blank groups in the last record and can drop
  or invent rows; a cell of eight zero bytes reads 0.0, where pandas reads
  2^-260; a 56-bit fraction is rounded to the nearest double, where
  pandas cuts it. A transport file's name is written as spelled where the
  format's writers fold case, and two that differ only in case are
  refused. A data set's text follows its header's character set — UTF-8,
  or one of the 49 single-byte code pages, windows-1252 among them —
  where pandas falls back to Latin-1 for a code its table does not name;
  pandas reads a blank character cell as missing, and the empty string is
  kept here. Nothing but the columns is carried out of a transport file:
  no label, no format other than the two the dates ride, no informat, and
  a timestamp of constants.
- **SPSS system files** — `read_spss` reads a system file as a frame over
  a codec inside the module, as pandas' `read_spss` does — which rides
  pyreadstat; Polars' I/O reference carries no SPSS entry. The format is
  read only here, as in both: pyreadstat's writer is not wrapped. The
  file's three layouts read — plain, bytecode-compressed, and the
  zlib-compressed `.zsav` — in either byte order. A numeric variable
  reads as `Float`, the system-missing value and a declared missing value
  as null, and a string variable as `String` in both; pandas also offers
  `convert_categoricals`, which is not carried: a labelled variable reads
  as the numbers it stores. A variable under a date format reads as a
  `Date`, under a datetime or a time format as a `Timestamp` — only while
  every present cell is a whole number of the unit, one that is not
  leaving the column `Float` — where pandas converts cell by cell,
  truncating or rounding, and leaves `QYR`, `MOYR`, `WKYR` and `MTIME` as
  numbers. A time past one day pandas wraps into the day, and reads here
  as the seconds since midnight; a HIGHEST, a LOWEST or a NaN cell pandas
  reads as missing, and reads here as the number it is, the
  system-missing value being the one number the format calls missing.
  Text follows the encoding the file declares — UTF-8, Latin-1,
  windows-1252 — and another refuses by name: pandas reads a file
  declaring windows-1250 as long as its text is ASCII, and refuses
  windows-1252's five unassigned bytes, which read here as the control
  characters of their number. There is no chunked or iterated read.
- **ORC** — `read_orc` reads a file's top-level fields as a frame over a
  codec inside the module, as pandas' `read_orc` does — which rides
  pyarrow — and Polars' `read_orc` / `scan_orc`; neither writes ORC, and
  nothing is written here. The format's versions 0.11 and 0.12 read under
  none, zlib, snappy, LZ4 or zstandard compression, and a projection
  leaves a column it does not name undecoded, so a file carrying a column
  this reader refuses reads under a projection that leaves it out. A
  boolean reads as `Bool`, an integer of any width as `Int`, a float as
  `Float`, a string as `String`, a date as `Date`, a timestamp as
  `Timestamp` in microseconds — the wall clock the writer stored, taken
  for UTC, the writer's time zone not applied — a decimal as `Decimal`,
  and a list or a struct as the `List` / `Struct` dtypes. A BINARY, MAP or
  UNION column, an encrypted column, a nanosecond timestamp and a decimal
  past what the library holds refuse by name, where pandas carries the
  first three. Two top-level fields of one name reach the frame as they
  are spelled, and the frame refuses them. There is no lazy source and no
  iterated read: a file is read whole.
- **Optimizer** — the passes are slice, predicate, and projection pushdown
  (the predicate pass also splits a filter into the sides of a join) plus
  the folding / clustering rules, each gated by a flag on
  `collect(optimizations~)`; `LazyFrame::collect`'s docstring is
  the contract's home. Dead-expression elimination and sinking
  filters below sorts are not implemented.
- **Reader dtype override** — `CsvReadOptions` / `JsonReadOptions` take a
  `dtypes=` map pinning named columns ahead of inference (Polars'
  `schema_overrides`): `Int` / `Float` / `Bool` / `String` parse from
  cell text, and the rider dtypes `Date` / `Timestamp` / `Decimal`
  parse the writers' own text forms (so a written-back rider column
  round-trips losslessly when pinned; `Duration` has no parser and
  refuses). On the JSON / NDJSON readers a `List` / `Struct` dtype pins
  a nested column and reaches its elements and fields. Inference itself
  never produces a rider. Columns not
  named keep their inferred dtype, and a name the input does not carry is
  refused. See
  [`type-inference.md`](type-inference.md).
- **Formats not carried** — of the formats pandas' I/O reference and
  Polars' carry beyond the entries above: HDF5 (pandas' `HDFStore`), whose
  `fixed` layout spells a frame as Python objects, a string column as a
  pickle stream, which a reader outside Python takes up only by
  unpickling; pickle and the clipboard, a Python object serialisation and
  an operating-system service; the OpenDocument and `.xls` workbook
  flavours, which Polars takes through `read_ods` and its Excel reader; a
  text file read as lines (Polars' `Lines`); the catalog-based table formats
  Delta Lake, Iceberg and Lance; a cloud database (pandas' `read_gbq`) or a
  remote file source (a path names a file on a local filesystem here); and
  an encrypted Parquet file. A reader takes a file whole: there is no
  chunked or iterated read, as pandas' `chunksize` and its statistics
  formats' readers offer.

See [`migration.md`](migration.md) for the upgrade history, the per-symbol
reference — generated from the docstrings — on
[mooncakes.io](https://mooncakes.io/docs/ihb2032/MoonFrame), and the README's
"Compatibility" section for the versioning rules.
