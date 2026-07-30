# MoonFrame — API Concepts & Compatibility

> This describes `main`. What a published release contains is in
> [`changelog.md`](changelog.md); what changed between two of them, and how to
> move, is in [`migration.md`](migration.md).

This guide covers the **cross-cutting behaviour** of the public API — the
compatibility model, the error model, evaluation semantics, the query
optimizer — the things no single symbol's docstring captures on its own.

The **per-symbol reference** — every type, constructor, method, and free
function, with its signature and documentation — is generated from the
docstrings and browsable on
[mooncakes.io](https://mooncakes.io/docs/ihb2032/MoonFrame). Runnable,
CI-verified examples of the representative workflows live in
[`quickstart.mbt.md`](../quickstart.mbt.md) (doc tests executed by `moon test`
on every backend) — a broad tour rather than a per-symbol catalogue, which is
what the generated reference above is for.

## API stability & compatibility

The facade package `ihb2032/MoonFrame` is the supported compatibility surface:
the symbols it re-exports — browsable on
[mooncakes.io](https://mooncakes.io/docs/ihb2032/MoonFrame) — are exactly what
the stability promise below covers. The public sub-packages (`@types`,
`@series`, `@expr`, `@frame`, `@io`, `@lazy`) stay directly importable for a
caller who only needs a slice, and a symbol the facade re-exports is the *same*
stable symbol reached that way. A sub-package symbol the facade does **not**
re-export is one of two kinds, and they are promised differently.

The **fluent-chain intermediates** — `WhenThen` / `WhenThenElse` /
`GroupedDataFrame` / `LazyGroupBy`, `pub` only because the verb returning one
must be — are promised at the level of the chain, not the name. What is stable
is that `when(c).then(a).otherwise(b)` and `group_by(k).agg(e)` keep compiling
and keep meaning what they mean: the step methods, their signatures, and the
type the chain ends in. What is *not* promised is the name of the step in
between: it is absent from the facade, so a caller who annotates or stores one
(rather than chaining straight through) is reaching past the supported surface,
and a release may rename or replace it. The chain methods are pinned in
`.github/scripts/facade_surface.snapshot` alongside everything else the facade
reaches, and that lock is deliberately narrow: exactly these four types may be
public without being re-exported.

The other kind — the **`#internal` engine seams** — carries no promise at all.

Two distinct mechanisms keep non-public code off the compatibility surface.
**Engine seams** are symbols that must be `pub` because two public packages
share them — MoonBit offers no visibility between `priv` (this package only) and
`pub` (anyone), so an `expr` accessor that both `frame` and `lazy` read a built
expression through (`Expr::node`, `Expr::output_name`) has to cross that
boundary as `pub`. Each carries `#internal(engine, "MoonFrame execution engine
API")`, which raises an alert if a *downstream* module reaches for it, and
`#doc(hidden)`, which keeps it out of the generated `.mbti`; so it is absent
from both the facade and the generated reference. The alert is silent for a
caller under this module's `ihb2032/MoonFrame/` prefix — MoonFrame's own
sub-packages, their tests, and the examples are the intended callers. The one
in-module caller the prefix does not cover is the root package itself, whose
name *is* the module name, so its `moon.pkg` allows the alert explicitly.

Being useful to a test is not what makes a symbol a seam. A test that needs to
reach inside a package can be a whitebox test, compiled within it, so a helper
only its own package's tests want does not need to be `pub` at all — and if no
production code calls it either, it is dead weight in a production source file
and gets deleted. `.github/scripts/check_engine_seams.sh` enforces exactly
that: a seam with no production caller outside its own package fails the build
unless it is listed, with its reason, in `engine_seams.allowlist` — which is
where the exceptions and their reasons live, rather than here. What earns a
line there is a symbol whose whole purpose is to be *asserted*, by tests in
another package that have no other way to see what they check.
**Internal packages** go further: code a downstream caller never needs to name
lives in an `internal/` path (`internal/column` storage, `internal/kernel` —
the vectorized expression kernels — `internal/text` / `internal/literal` /
`internal/numeric` / `internal/order` primitives, and `internal/ir`, the
expression AST and its operator tags).
MoonBit forbids a downstream module from importing an `internal/` package at
all, so those symbols carry no per-symbol marker — the module boundary itself
is the wall, and a generated `.mbti` for an internal
package is not an external compatibility surface. The public packages here do
depend on them, which is the point: what an internal package holds is
implementation the library needs and a caller does not, and no public
signature may name one. **Do not depend on either** — neither carries a
compatibility promise, and both may change signature or disappear in any
release.

What the promise covers is the facade surface, not a particular release
number: pre-1.0, additions and fixes ride a patch version and a change to that
surface rides the minor one, and every release says which it was in
[`changelog.md`](changelog.md). One case is easy to mistake for additive:
adding a variant to a `pub(all)` enum (`DataError` and its error-detail enums,
`DataType`, `Scalar`, `SortOrder`, `NullOrder`, `ClosedInterval`, …) is
**source-breaking** — MoonBit `match` is exhaustive, so a caller's existing
match stops compiling — and therefore counts as a surface change,
semantically-additive though it looks. Only a caller whose match carries a
wildcard arm (`_ => …`) stays source-compatible across such an addition.

**`Expr` has no equality, and neither does `JoinOptions`.** An expression is
opaque: its AST lives in a module-internal package, and the only way to compare
two of them structurally would have been to compare that tree. That is a
promise the library is not willing to make — it would mean *how an operator
lowers* is part of the API, so normalising a tree, merging two node kinds, or
giving a verb a dedicated node instead of a lowered one would silently change
what compares equal. `JoinOptions` holds expressions as its key lists, so it
loses equality for the same reason.

Compare rendered expressions instead — `Expr::to_string()`, which is what
`explain()` prints and what the plan renderer uses:

```moonbit
assert_eq((col("a") + lit_int(1)).to_string(), "(col(a) + 1)")
```

Rendering answers the question worth asking — "did my builder produce the
expression I meant" — and it stays readable when it fails. It does not
distinguish what it does not print: a `lit_series` renders as its name and
length, so two literal series with different cells render alike.

(`DataFrame` equality is unaffected: a frame holds columns, not expressions,
and compares schema, columns and row count.)

A **public struct field** is the same case in a different costume. A `pub
struct` with public fields is read-only from outside — a caller cannot build or
mutate one — but it *can* destructure one, and MoonBit requires a struct
pattern to name every field or carry `..`. So a new field is source-breaking
for that caller, and the representation, not just the accessors, is the
promise. The types that keep public fields do so because reading them is the
API — the options records (`CsvReadOptions`, `CsvWriteOptions`,
`JsonReadOptions`, `HtmlOptions`, `JoinOptions`, `ChartSpec`) are built through
their named constructors and inspected through their fields — while a type with
its own accessors keeps its representation private, which is what makes a
future field genuinely additive there (`Field`, `Schema`, `Series`,
`DataFrame`, `Expr`, `LazyFrame`).

The line runs per field, not per type, and it falls in the same place every
time: **a field holding a mutable array is private, behind an accessor that
copies.** `CsvReadOptions.null_values` and `JoinOptions`' three key lists are
the two cases (`null_values()`, `on_keys()` / `left_keys()` / `right_keys()`).
Reading a public `Array` field hands back the array *itself*, not a view of it,
which is enough to change a value someone else is holding — including one a
`LazyFrame` captured into a built plan. Their neighbours (`how`, `suffix`,
`escape`, …) are immutable values and stay public. Which fields are public is
pinned
field-by-field in `.github/scripts/facade_surface.snapshot`, with their types,
so adding one is a deliberate act rather than a side effect — and that snapshot,
not a summary sentence, is the list.

## Packages

The public surface is split across six packages; the facade re-exports them so
`import "ihb2032/MoonFrame" @moonframe` reaches everything (see
[Facade](#facade)). Each package is also directly importable.

- **`types`** — the value types (`DataType`, `Scalar`, `Field`, `Schema`) and
  the error model (`DataError` and its `TypeMismatchDetail` / `ParseErrorDetail`
  detail enums, `CellParseLocation`), plus `SortOrder` / `NullOrder` /
  `ClosedInterval`.
- **`series`** — `Series`, the per-column unit `DataFrame` wraps: its
  constructors (`from_ints` / …), statistics, and the column-level kernels the
  frame transforms reuse.
- **`expr`** — `Expr`, the opaque composable column expression: the
  constructors (`col` / `lit_*` / `when` / `map_many`), operators, methods, and
  the `str_*` string namespace. Its AST is module-internal (`internal/ir`).
- **`frame`** — `DataFrame` and the operator verbs (`select` / `filter` /
  `with_columns` / `group_by` / `join` / `sort` / … — all methods), the eager
  expression evaluator, and the Markdown / HTML renderers.
- **`io`** — the CSV / JSON / NDJSON readers and writers, the Vega-Lite chart
  export, and their options types. The one package with external dependencies.
- **`lazy`** — `LazyFrame`, the deferred query plan: the builders, `collect` /
  `explain`, and the optimizer (see [Query optimizer](#query-optimizer)).

Storage backends (`internal/column`), the vectorized expression kernels
(`internal/kernel`), the text / literal / numeric / position primitives
(`internal/text` / `internal/literal` / `internal/numeric` / `internal/order`),
and the expression AST (`internal/ir`) live in module-internal packages a
downstream module cannot import. Responsibility
runs `frame` schedules → `internal/kernel` computes a column → `series` owns
what a column is → `internal/column` owns how it is laid out. What keeps it
that way is an import allowlist, which lives in
`.github/scripts/check_layering.sh` and is checked against the build manifests
on every run — one copy, in the place that can fail.

## Constructor spelling

A type whose construction has one canonical entry point is built through its
own name, always spelled `Type::Type(...)`:

```moonbit
let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2])])
let lf = LazyFrame::LazyFrame(df)
let schema = Schema::Schema([Field::Field("a", DataType::Int)])
let opts = CsvReadOptions::CsvReadOptions(delimiter=';')
```

`DataFrame`, `LazyFrame`, `Schema`, `Field`, `HtmlOptions`, `CsvReadOptions`,
`CsvWriteOptions`, and `JsonReadOptions` all read this way, through the facade
(`@moonframe.DataFrame::DataFrame(...)`) and through a direct package import
(`@frame.DataFrame::DataFrame(...)`) alike. No constructor is exposed as a free
function.

A type whose construction genuinely has several shapes keeps a named
constructor per shape instead: `DataFrame::empty` / `DataFrame::from_rows`, the
eight `Series::from_*`, `JoinOptions::on` / `left_on` / `cross`, and
`ChartSpec::bar` / `line` / `point` / `area`.

## Naming conventions

Names here are regular enough that guessing usually works, which makes the few
places where two similar names mean different things worth stating outright.

**`to_x` never fails; `as_x` can.** `Scalar::to_string` renders *any* cell for
display — `Int(42)` gives `"42"`, and a null cell gives `""` — while
`Scalar::as_string` is a typed read that raises `TypeMismatch` unless the cell
really is a `String`. The pair is the sharpest edge in the library: the two
names differ by two letters, both compile on any `Scalar`, and the wrong one
does not fail — it silently stringifies a number. Reach for `as_*` when a wrong
dtype is a bug you want reported, and `to_string` only when you want display
text whatever the cell holds.

**A `Double`-returning reduction raises where it has no answer; it does not
return an option.** `Series::mean` raises `InvalidOperation` on an empty or
all-null column and `TypeMismatch` on a non-numeric one — two different causes,
told apart by the error. There is no `mean_opt` on the supported surface: catch
the error where you want a fallback, which keeps the two causes distinguishable
at the point you handle them; `std` / `variance` / `median` read the same way.
The reductions that return a `Scalar` are total instead, that type being able to
carry the empty case: `min` / `max` / `first` / `last` give `Scalar::Null`, and
`sum` gives the additive identity (`Scalar::Int(0)` / `Scalar::Float(0.0)`),
though `sum` still raises `TypeMismatch` on a non-numeric column. Each symbol's
docstring states its own rule.

**`null`, `nan`, and `_options` mark three different absences.** `null` is a
missing cell; `nan` is a `Float` value that happens not to be a number; and the
`_options` suffix on a constructor means the cells themselves arrive as `T?`
(`Series::from_floats` takes `Array[Double]`, `from_float_options` takes
`Array[Double?]`). So `fill_null` and `fill_nan` are different operators, and
`drop_nulls` never looks at a `NaN`. Where the two do meet is inside the
reductions, and they do not agree with each other: `sum` and `mean` let a `NaN`
propagate, while `min`, `max`, `median` and `sort` order it as missing —
[`docs/comparison.md`](comparison.md) sets out that split and where it diverges
from Polars.

**`str` is the expression layer; `string` is the dtype.** Expression-level
string work is `str_*` (`str_contains`, `str_slice`, …) and its literal
constructor is `lit_str`, because that is the namespace Polars uses. The dtype
and anything that names it spell it out: `DataType::String`,
`Series::from_strings`, `Scalar::String`.

**`drop` is the only removal *verb*.** When a name says it takes something
away, that name is `drop`: `DataFrame::drop` for columns, `drop_nulls` for
rows. No `remove`, `delete`, `without`, or `exclude` spelling exists anywhere
on the surface. Plenty of other verbs return fewer rows than they were given —
`filter`, `unique`, `head`, `tail`, `slice`, `gather` — they just do not
describe themselves as removal.

**Row-major is the supported *matrix* shape.** `DataFrame::rows` hands back
`result[r][c]` — one entry per row, cells in column order — with
`DataFrame::row(i)` for a single row and `item(r, name)` for a single cell.
There is no column-major counterpart to `rows`, and none is needed: a `Series`
already *is* a column, so read one with `get_column(name)` and walk every column
in declaration order with `column_series()` — total, where a `get_column` per
name is both fallible and a lookup each time.

**Every deferrable positional verb has the same name in both layers, bar one.**
`head`, `tail`, `slice`, `reverse` and `with_row_index` are spelled identically
on `DataFrame` and `LazyFrame`, as are `filter`, `select`, `sort`, `join`,
`group_by` and `unique`, so a pipeline reads the same either way. Of that
positional group only `DataFrame::gather` — which takes explicit row indices —
has no `LazyFrame` counterpart; `collect` first if you need one. This says
nothing about the eager surface as a whole: `describe`, `rows` / `row` /
`item`, and `to_html` / `to_markdown` are eager readers with no lazy spelling
by design, since each one materialises.

For how a type is constructed, see [Constructor spelling](#constructor-spelling)
above; for which names the facade re-exports, see [Facade](#facade).

## Error model

Every operation that can fail on bad input or I/O is an effectful function with
signature `... -> T raise DataError`. There is no `Result` wrapping on fallible
verbs and no hidden `unwrap` / `abort`.

- **In a `raise` context** (another `... raise DataError` function, or a
  `test { ... }` block) call the method directly; an uncaught error propagates.
- **Bridge to a value** by re-wrapping in a `catch`:
  `let r : Result[DataFrame, DataError] = Ok(read_csv(path)) catch { e => Err(e) }`.
  Match on `r` to inspect the error.
- **Handle inline** with `try expr catch { e => ... }`.

Provably-total operations (`head` / `tail` / `Series::min` /
`Series::drop_nulls` / `to_markdown` / `to_html` / the inspection accessors /
…) return their value directly and never raise.

`DataError` is a `pub(all) suberror`, so a caller both raises and matches its
variants. `TypeMismatch` and `ParseError` carry structured detail enums
(`TypeMismatchDetail` / `ParseErrorDetail`) rather than a flat string, so a
handler can branch on the specific failure — expected / actual dtype, or a
failing cell's location, column, and value — while `DataError::message()`
renders the same human-readable text either way.

`DataFrame::check_invariants()` — which verifies the seven structural
invariants and returns `Err(msg)` naming the first violation — is a
`#doc(hidden)` **internal** diagnostic, not public API: a downstream user builds
a `DataFrame` only through the controlled constructors and operators, each of
which already establishes those invariants, so there is nothing outside the
module to hand it. It is absent from the generated interface; the in-module and
blackbox test assertions that use it reach it across the package boundary.

### Migration

Source-level changes between releases are collected in
[`migration.md`](migration.md).

## Evaluation semantics

Expression trees (`expr`) are applied by the `frame` evaluator — which walks
the tree and calls the `internal/kernel` column kernels — vectorized
(whole-column at a time), raising `DataError` at evaluation time — building the
tree never fails:

- **Result length**: every consumer (`select` / `with_columns` / `filter` /
  `sort` / `group_by` / `agg` / `join` keys) accepts a result of the evaluation
  height or of length 1, which broadcasts over it — down to zero rows on an
  empty frame — and raises `LengthMismatch` on any other length. What fixes the
  evaluation height differs: `with_columns` takes the frame's, so a length-1
  result always broadcasts to `nrows`; `select` reads it off the results, so
  when *every* expression reduces to length 1 the output is the one-row summary
  frame (`df.select([col("a").sum()])` is `1×1`, not `nrows` copies). The built-in
  algebra only produces those two; the two nodes carrying a caller's own data
  can produce a third (a `lit_series` keeps its series' length, a `map_batches`
  closure returns what it likes), which is where the error comes from. Under
  `agg` the contract narrows to one cell per group.
- **Type promotion**: `Int op Int → Int`, `Float op Float → Float`, mixed
  promotes `Int → Float`; non-numeric arithmetic →
  `TypeMismatch(Operation(operation, left, right))`. `/` and `pow` are always
  `Float`; `floor_div` / `modulo` keep `Int` for same-dtype integer operands
  (integer division / modulo by zero is a **null** cell, not a trap).
- **Null propagation**: any null operand of an arithmetic or comparison makes
  the result null (Arrow / Polars).
- **Kleene `&` / `|`**: `true | null = true`, `false & null = false`, otherwise
  null; `not(null) = null`. Non-`Bool` operands → `TypeMismatch`. (The method
  spellings are `land` / `lor`, since `and` is a reserved word.)
- **Comparisons**: cross-numeric is legal, strings compare by Unicode
  code-point order, `Bool` as `false < true`; the result is a `Bool` column.
  Mixed `Int`-vs-`Float` compares **exactly** — the `Int64` is not promoted to
  `Double`, so two distinct values never collide above 2^53 (e.g. `Int64::MAX`
  is not equal to the `2^63` `Double` a promotion would round it to). A
  deliberate departure from Polars' Float64-supertype promotion, chosen for
  correctness; same-dtype comparisons are always exact.
- **String namespace** (`str_to_uppercase` / `str_contains` / …) maps each cell
  of a String operand through a `StrOp`. Null cells stay null and a non-String
  operand is a `TypeMismatch`. The literal ops are per-value total; the regex
  path is not — `str_contains` / `str_replace` / `str_replace_all` with
  `literal=false`, and the regex-only `str_extract` / `str_count_matches`,
  compile their pattern once per evaluation and raise `InvalidOperation` if it
  does not compile. The regex dialect is **POSIX** (`[[:digit:]]`, not the PCRE
  `\d`) and the literal-matching default is the opposite of Polars' regex-first
  one, so an unescaped `.` cannot silently change meaning.
- **NaN** inherits the shared reduction rules — `sum` / `mean` (and the
  mean-based `std` / `variance`) propagate a `NaN`, `min` / `max` and the order
  statistic `median` skip it, `n_unique` buckets every `NaN` as one value; in
  comparisons `NaN` is a value. Only `null` is ever treated as missing.
- **Aggregations** reduce their input to length 1 through the shared reduction
  kernel (so an all-null `mean` / `std` / `variance` / `median` is a null cell,
  `count` / `n_unique` are never null, and `first` / `last` take the positional
  cell — null if that cell is null or the scope empty); a length-1 result
  broadcasts against frame-tall results.
- **Map** (`map_elements` / `map_many`) runs the closure once per row over the
  input cells (each a `Scalar`, a null as `Scalar::Null`). The output dtype is
  the first non-null result's, except that results mixing `Int` and `Float`
  promote to `Float` like the arithmetic above rather than nulling the minority
  type; an all-null (or empty) result borrows the leftmost **input**
  expression's dtype, a literal included, and only a map with no input at all
  and no non-null result cell (`map_many(label~, [], …)`) has nothing to borrow
  from and raises `Unsupported`. The optimizer treats a map as a value
  barrier — no filter sinks across it.
- **Batched map** (`map_batches`) runs the closure once over the whole
  evaluated `Series` and takes back a `Series`, canonicalised onto its content
  backend; whatever length that series has meets the result-length contract
  above. `returns_scalar=true` marks it a per-group reduction accepted by `agg`,
  where the contract asks for exactly one cell per group.
- **Literal series** (`lit_series`) is used verbatim — the data analogue of a
  scalar literal's length-1 column — and meets the same contract at its own
  length. Its backend is preserved (handed through, not re-derived), and it
  reads no frame column.

## The `N × 0` shape

A frame with rows and no columns is well-formed, and the operations that reach
one keep their height rather than collapsing to `0×0`: `select([])`, a `drop`
of every column, `from_rows` under an empty schema, JSON records with no fields
(`[{}, {}]` reads as `2×0`), and a file read whose projection matches no
header. `is_empty()` is `nrows() == 0`, so an `N×0` frame is *not* empty, and a
`with_columns` can still compute a column over its rows. The whole-frame
summaries (`sum` / `mean` / `min` / `max` / `count` / `null_count`) reduce a
0-column frame to their `1×0` summary row. Only two places cannot represent the
shape: the table renderers (`to_markdown` / `to_html`) draw cells and an `N×0`
frame has none, so they return the empty string at any height (`shape()` still
reports the height); and CSV, which has no field-less row, so `format_csv` /
`write_csv` reject an `N×0` frame with `InvalidOperation`. Only
`DataFrame::DataFrame([])` is `0×0` — it infers the height from the columns,
and there are none.

## Query optimizer

`collect` runs two total rewrites before executing. They preserve the cells a
successful plan produces; what they can change is whether an error in data the
optimized plan never reads is seen at all — see the file-source exception
below.

One plan shape opts out entirely: when a `LazyFrame` value is shared across both
sides of a `join`, the plan is a DAG rather than a tree, and both passes return
it untouched — rewriting is tree-wise, so it would materialise the shared
subplan once per occurrence. Such a plan executes as built (the memoised
executor still runs each shared subplan once), and `explain(optimized=true)`
renders the as-built tree. Everything below describes a plan without that
sharing, which is every chain the builders produce otherwise:

- **Predicate pushdown** sinks each `filter` toward the scan so rows drop as
  early as possible — below a selection when its expressions are row-local (no
  aggregation, no `cast`) and every predicate column is a bare `col(name)`;
  below a `with_columns` (same row-local rule) when the stage defines none of
  the predicate's columns; below an aggregation when the predicate is row-local,
  reads key columns only, and every aggregation cell is provably null-free and
  value-safe (`sum` / `count` / `n_unique` and non-null literal combinators
  qualify; `mean` / `min` / `max` / `std` / `variance` / `median` can go null
  on an all-null group, `first` / `last` on a null cell, and a `cast` can reject
  a value, so they pin the filter above). Positional row windows, `sort`,
  `join`, and another filter stop the descent.
- **Projection pushdown** then runs a top-down required-columns analysis and
  narrows each scan to the columns its consumers read, dropping dead columns
  before any row-level work — inserting a narrowing selection of bare column
  references over an in-memory scan, or writing the column set into a file
  source's (`scan_csv` / `scan_ndjson`) own projection so the reader parses only
  those columns (rendered `SCAN_CSV "path" [cols]`). `Select` / `Aggregate`
  originate requirements; `Filter` / `Sort` widen the requirement by what they
  read; row windows pass it through; a `with_columns` subtracts the names it
  defines and adds the names it reads; `Join` is a barrier (each side restarts
  its own pass).

The rewrites never change results: `collect` stays equal to the eager
chain, and a failing plan still fails (a single broken stage reports the same
eager error; a plan with several independently broken stages may report a
different one of its own errors once a filter sinks past a broken stage — which
error surfaced was an artifact of stage order to begin with). The sole
deliberate exception is a file source's projection (`scan_csv` / `scan_ndjson`),
which absorbs **both** push-downs: a column no consumer reads is never parsed,
and a filter sitting on the leaf is absorbed into the scan, which builds the
predicate's columns, prunes the rows, and parses the remaining columns for the
survivors alone. So a parse error confined to a dropped column *or* to a row the
predicate drops goes unraised; dtype inference still walks the whole file, so
dtypes are unchanged. The plan shows it as `SCAN_CSV "f.csv" [cols] WHERE (pred)`.
Only the first predicate is absorbed (combining two would reorder which
operand's error surfaces first). A predicate naming no column (`lit_bool(true)`,
a no-input `map`) is absorbed too — it prunes against a key frame with no
columns, which still carries the file's row count (`N×0`) for the literal to
broadcast over. Deferred (out of scope): dead-expression elimination, narrowing
/ predicate-splitting through joins, sinking filters below sorts, and streaming
a file source — the reader still tokenises the whole file.

## Facade

`moonframe.mbt` re-exports the public API via `pub using`, so a single
`import "ihb2032/MoonFrame" @moonframe` reaches the whole surface. Because the
operator verbs and `to_markdown` are **methods on `DataFrame`**, re-exporting
`type DataFrame` makes them automatically reachable; likewise the `Expr`
operators / methods ride along with `type Expr`, and the `LazyFrame` methods
with its type — so only the value types and the free functions are listed
explicitly (browse the full re-exported set on
[mooncakes.io](https://mooncakes.io/docs/ihb2032/MoonFrame)). The expression AST
— `ExprNode` and its `BinOp` / `UnOp` / `AggOp` / `StrOp` tags — lives in the
module-internal `internal/ir` package, which downstream cannot import and no
public API names, so there is nothing to re-export for it.

The chained intermediates — `WhenThen` / `WhenThenElse` (from
`when(c).then(a).otherwise(b)`) and `GroupedDataFrame` / `LazyGroupBy` (from
`group_by(k).agg(e)`) — are **not** re-exported. Reaching the library through
the facade never requires naming one: a caller only chains the next method off
the previous step's return value, and
dot-method resolution follows that value's type, so the chain works through the
facade without the name in scope. They remain `pub` in `@expr` / `@frame` /
`@lazy` for anyone who does import those packages directly.

`using @pkg { type T }` also creates constructor aliases, so
`@moonframe.Scalar::Int(42)`, `@moonframe.SortOrder::Desc`, and
`@moonframe.DataError::ColumnNotFound("y")` all resolve through the facade.

## Out of scope (so far)

The expression AST is where variants grow the most, which is
exactly why it is *not* a public enum: `Expr` is opaque and its `ExprNode` AST
lives in module-internal `internal/ir`, so a downstream caller cannot match it
and a new node cannot break one. Inspect an expression with `Expr::to_string`.

These are the tracked deferrals:

- **More expression families** — the list-returning `str.split` (blocked on a
  list dtype; the scalar `str_split_get` is done) and — further out — window and
  datetime expressions (the repo has no datetime type yet). These extend the
  current operator / method set rather than changing it.
- **Lazy scan depth** — streaming execution (the scan does projection- and
  predicate-pushdown but still tokenises the whole file), plus columnar sources
  (Parquet / IPC) once eager readers exist.
- **Optimizer extensions** — dead-expression elimination, narrowing /
  predicate-splitting through joins, and sinking filters below sorts.
