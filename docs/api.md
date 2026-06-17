# MoonFrame v0.4 — Public API

> Status: **v0.4 shipped** (expression engine + lazy query layer, on top
> of v0.3's output formats, full join matrix, and pluggable column
> storage). This document is the source of truth for the v0.4 public
> surface. When a symbol is published in code, it must appear here.

The facade package `ihb2032/MoonFrame` re-exports every symbol below
via `pub using @<subpkg> { ... }`, so a single
`import "ihb2032/MoonFrame" @moonframe` is enough to reach the whole
surface. Sub-package imports (`@types`, `@column`, `@series`, `@expr`,
`@frame`, `@io`, `@lazy`) remain supported for callers that only need a
slice — the facade is additive.

Runnable, CI-verified examples of the surface below live in
[`quickstart.mbt.md`](../quickstart.mbt.md) (doc tests executed by `moon test`
on every backend).

## Error model

Every operation that can fail on bad input or I/O is an effectful
function with signature `... -> T raise DataError`. There is no
`Result` wrapping on fallible verbs and no hidden `unwrap` / `abort`.

- **In a `raise` context** (another `... raise DataError` function, or a
  `test { ... }` block) call the method directly; an uncaught error
  propagates.
- **Bridge to a value** with `try?`: `let r : Result[DataFrame, DataError]
  = try? read_csv(path)`. Match on `r` to inspect the error.
- **Handle inline** with `try expr catch { e => ... }`.

Provably-total operations (`head` / `tail` / `Series::min` /
`drop_nulls` / `to_markdown` / `to_html` / the inspection accessors / …)
return their value directly and never raise.

The one deliberate exception is `DataFrame::check_invariants()`, which
keeps its `Result[Unit, String]` shape — it is a verification /
diagnostic affordance (its error is a `String` describing the first
violated invariant), not a data transform.

### Migration

Source-level changes from earlier releases — the `ops` → method move and the
`Result` → `raise` shift (v0.1 → v0.2), and the `Series::storage` / `JoinType`
breaks (v0.2 → v0.3) — are collected in [`migration.md`](migration.md).

---

## `types` — Value types and errors

- `suberror DataError` — `pub(all) suberror` with 10 variants:
  `ColumnNotFound` / `DuplicateColumn` / `TypeMismatch` / `LengthMismatch` /
  `IndexOutOfBounds` / `ParseError` / `InvalidOperation` / `IoError` /
  `EmptyDataFrame` / `Unsupported`. As a `suberror` it is both raised
  (`raise ColumnNotFound("age")`) and recovered (`try? expr` →
  `Result[_, DataError]`); `pub(all)` lets callers construct and match
  variants. `DataError::message()` renders a human-readable description;
  the `Show` impl renders the variant form for assertion snapshots.
- `enum DataType` — `Int | Float | Bool | String | Null`, with
  `is_numeric` / `is_integer` / `is_float` / `is_string` / `is_bool`.
- `enum Scalar` — cell value (`Int` carries `Int64`, `Float` carries
  `Double`). Total: `dtype` / `is_null` / `to_string` (value form, e.g.
  `Int(42) → "42"`, `Null → ""`). Fallible (`raise DataError`):
  `as_int` / `as_float` / `as_bool` / `as_string` and the comparisons
  `eq` / `lt` / `lte` / `gt` / `gte`, which return `Bool` and
  `raise TypeMismatch` when either side is `Null` or the dtypes are
  incomparable. `as_float` promotes `Int`; mixed numeric comparisons
  promote `Int` to `Double`. `String` comparisons use lexicographic
  order (see `compare_string_lex`), **not** the built-in shortlex `<`.
- `fn compare_string_lex(a, b) -> Int` — lexicographic string comparison
  by UTF-16 code unit (`-1` / `0` / `1`). Every user-facing ordering
  (`Scalar::lt`, `Series::min` / `max`, `DataFrame::sort`)
  routes through this so they all agree.
- `fn is_decimal_int_literal(s) -> Bool` — `true` when `s` is an optional
  `+` / `-` sign followed by ASCII digits and nothing else (rejects
  `0x` / `0o` / `0b` prefixes and `1_000` underscore grouping). The
  CSV / JSON readers' type inference and the `@column` String→`Int` cast
  both route through this predicate so they agree on what counts as an
  integer literal.
- `struct Field` — column metadata: `name`, `dtype`, `nullable`. Total
  constructors `Field::new(name, dtype)` (defaults `nullable = true`)
  and `Field::with_nullable(name, dtype, nullable)`; accessors `name` /
  `dtype` / `nullable`; `rename(new_name)` returns a renamed copy.
- `struct Schema` — ordered list of `Field`s with duplicate-name
  detection.
  - `Schema::new(fields) -> Schema raise DataError` —
    `raise DuplicateColumn(name)` on the first repeated name. Empty is
    valid.
  - Total inspection: `fields` / `field_names` / `len` / `is_empty`.
  - `index_of(name) -> Int raise DataError` and
    `field(name) -> Field raise DataError` `raise ColumnNotFound`;
    `field_at(i) -> Field raise DataError` `raise IndexOutOfBounds`.
  - `select(names) -> Schema raise DataError` — project a sub-schema in
    `names` order. Missing → `ColumnNotFound`; duplicate in the pick
    list → `DuplicateColumn`.
  - `rename(old_name, new_name) -> Schema raise DataError` —
    `ColumnNotFound` if `old_name` missing; `DuplicateColumn` if
    `new_name` collides. `(name, name)` is a no-op that still validates
    existence.

---

## `column` — Column storage backends

Apache Arrow style: a raw data buffer plus a separate bit-packed
validity bitmap (`1 = valid`, `0 = null`).

### Validity bitmap

- `struct Bitmap { bits : Bytes, offset : Int, len : Int }` — byte-packed
  at 1 bit per row, `1 = valid`. Logical slot `i` lives at physical bit
  `offset + i` (`bits[(offset + i) / 8]`, bit `(offset + i) % 8`, LSB
  first). A constructor builds a tight `⌈len / 8⌉`-byte buffer with
  `offset = 0`; `slice` is a zero-copy view that shares the parent buffer
  and advances `offset`, so equality is logical over the
  `[offset, offset + len)` window rather than structural.
  Note: some MoonBit ecosystem libraries (e.g. `smallbearrr/pandas`) use
  the **opposite** convention (`true = null`).
- Total constructors: `all_valid(len)` / `all_null(len)` (a negative
  `len` clamps to 0, the empty bitmap) /
  `from_bools(Array[Bool])` (`true ↦ valid`) /
  `from_options[T](Array[T?])` (`Some(_) ↦ valid`).
- Total inspection: `len` / `null_count()` / `to_bools()` (materialise
  the whole `true = valid` mask in one pass — the total counterpart to
  `is_valid` for bounded scans).
- Fallible (`raise DataError`): `is_valid(i)` / `is_null(i)`
  (`raise IndexOutOfBounds` outside `[0, len)`); `slice(start, length)`
  (`IndexOutOfBounds` / `InvalidOperation` on bad bounds); `take(indices)`
  (`IndexOutOfBounds` on the first bad index); `bit_and(other)`
  (`LengthMismatch` if lengths differ — `and` is a reserved keyword,
  hence `bit_and`).

### BuiltinColumn

- `struct BuiltinColumn { data : ColumnData, validity : Bitmap }` —
  Arrow-style column; null slots in `data` carry a per-dtype placeholder
  (`Int = 0`, `Float = 0.0`, `Bool = false`, `String = ""`) that never
  leaks because every read consults `validity` first.
- `pub(all) enum ColumnData` — `Int(Array[Int64]) | Float(Array[Double]) |
  Bool(Array[Bool]) | String(Array[String])`. Numeric columns are 64-bit.
- Total constructors (8): `from_ints` / `from_int_options` /
  `from_floats` / `from_float_options` / `from_bools` /
  `from_bool_options` / `from_strings` / `from_string_options`.
- Total inspection: `dtype` / `len` / `is_empty` / `null_count` /
  `data() -> ColumnData` / `validity() -> Bitmap`. The `data()` /
  `validity()` accessors expose the raw backing so callers in other
  packages match `ColumnData` once and read values / validity totally,
  instead of cascading through `*_values`.
  - ⚠ **`data()` shares the live backing array zero-copy** — the `Array`
    inside the returned `ColumnData` is the column's own buffer, *not* a
    defensive copy (a deliberate departure from `Schema::fields()`, which
    copies, traded for hot-path reads with no per-call allocation). Treat it
    as **read-only**: mutating it would corrupt the owning column's
    data/validity invariants. The same applies to `ColumnStorage::data()`.
- Fallible (`raise DataError`):
  - `is_null(i) -> Bool` / `get(i) -> Scalar` —
    `raise IndexOutOfBounds` outside `[0, len)`; `get` returns
    `Scalar::Null` for null slots.
  - `slice(start, end)` / `take(indices)` — sub-views; same bounds
    diagnostics as the bitmap.
  - `cast(target)` — the single cross-dtype conversion. `Int`: identity on
    Int, Float truncates toward zero (`NaN` / `±Inf` / out-of-`Int64`-range
    → `ParseError`), Bool `true → 1` / `false → 0`, String accepts only
    plain base-10 integers (others → `ParseError`). `Float`: Int promoted,
    identity on Float, Bool → `1.0` / `0.0`, String parsed (`1_000`
    underscore grouping rejected; `inf` / `-inf` / `nan` accepted; other
    malformed → `ParseError`). `String`: every dtype renders (via the total
    `to_string_column`). Validity is preserved; `Bool` / `Null` targets
    `raise Unsupported`.
  - `int_values()` / `float_values()` / `bool_values()` /
    `string_values()` — return `(Array[T], Bitmap)`; wrong dtype →
    `raise TypeMismatch`. Always consult the returned bitmap before
    reading the data array.
- **Total** (no failure path): `to_string_column() -> BuiltinColumn` —
  every dtype has a value-form rendering, so unlike a numeric `cast`
  it never raises.

### NumericColumn

- `struct NumericColumn { data : NumericData }` — the **all-valid** unboxed
  numeric column (the `null_count == 0` fast path). Unlike `BuiltinColumn`
  it carries **no validity bitmap**: every slot is present by construction,
  so construction and sub-views allocate no validity `Bytes` and the
  reductions skip the per-slot validity check. The moment a null would
  enter, the column materialises back to a `BuiltinColumn`.
- `pub(all) enum NumericData` — `Int(Array[Int64]) | Float(Array[Double])`
  (numeric only; `Bool` / `String` are always `Builtin`).
- Total constructors: `from_int64s` / `from_doubles` (no null path).
- Total inspection: `dtype` / `len` / `is_empty` / `null_count` (always
  `0`) / `data() -> ColumnData` / `to_builtin() -> BuiltinColumn` (widen
  with an all-valid bitmap — lossless, `== from_ints` / `from_floats`) /
  `to_string_column() -> BuiltinColumn`.
- Fallible (`raise DataError`): `is_null(i)` (bounds only; the value is
  always `false`) / `get(i)` / `slice(start, end)` / `take(indices)` (same
  diagnostics as `BuiltinColumn`); `int_values()` / `float_values()` (the
  raw array paired with a synthesised all-valid bitmap); `bool_values()` /
  `string_values()` always `raise TypeMismatch` (numeric by construction).
- Reductions (the fast path — no validity scan): **total** `sum() ->
  Scalar` / `min() -> Scalar` / `max() -> Scalar`; fallible
  `mean() -> Double` (`InvalidOperation` on an empty column). `NaN`
  propagates through `sum` / `mean` but is skipped by `min` /
  `max` (Polars semantics).

### ColumnStorage / StorageKind

- `pub(all) enum ColumnStorage { Builtin(BuiltinColumn);
  Numeric(NumericColumn) }` — the pluggable backend seam a `Series` holds.
  Every accessor forwards to both arms, so reading a column through
  `.data()` / `.validity()` is backend-transparent (the `Numeric` arm
  synthesises an all-valid `validity()` on demand — the one point the
  backends diverge).
- `pub(all) enum StorageKind { Builtin; Numeric }` — the backend
  discriminant (`kind()`). The original draft's `ArrowLike` is intentionally
  absent: post-P3.5 `Builtin` *is* the Arrow layout (data + validity
  bitmap, `1 = valid`).
- Constructors: `from_builtin(BuiltinColumn)` / `from_numeric(NumericColumn)`.
- Total inspection: `kind()` / `dtype` / `len` / `is_empty` / `null_count`
  / `data() -> ColumnData` / `validity() -> Bitmap` / `to_builtin() ->
  BuiltinColumn` / `to_string_column() -> BuiltinColumn`.
- Total `slice_total(start, end) -> ColumnStorage` — the no-raise
  counterpart of `slice`, backing the total row transforms `head` / `tail`
  / `DataFrame::slice`. Keeps the backend and shares the validity buffer
  (zero-copy view) exactly like `slice`, but clamps out-of-range bounds into
  `[0, len]` (with `end` lifted to at least `start`) rather than raising, so
  it never raises or aborts.
- Fallible (`raise DataError`): `is_null(i)` / `get(i)`; backend-preserving
  `slice(start, end)` / `take(indices)` (a sub-range of a `Numeric` column
  stays `Numeric`); `int_values()` / `float_values()` / `bool_values()` /
  `string_values()`. The cross-dtype `cast(target)` routes through
  `to_builtin()`, so the result is `Builtin`-backed — a caller
  re-converges with `to_numeric` if a numeric target should land back on
  the fast path.
- `to_numeric() -> ColumnStorage raise DataError` — move an all-valid Int /
  Float `Builtin` column onto the `Numeric` fast path: `InvalidOperation`
  if it carries nulls, `TypeMismatch` if non-numeric, identity if already
  `Numeric`.

---

## `expr` — Expression engine

A reified, composable column expression. Where a host-language closure is
opaque, an `Expr` is **data**: a small recursive
tree you build with constructors, operators, and methods, then evaluate
eagerly (`with_columns` / `select` / `filter` / `agg`,
in `frame`), introspect (`explain`), or defer and optimize (`lazy`).
Building a tree is **total** — every constructor and combinator just
allocates a node, so an expression can always be built; every failure (a
missing column, a type clash) waits for evaluation. `expr` depends only on
`types`.

- `enum Expr` — the expression tree, **read-only** outside the package:
  callers can inspect it by pattern matching, and `frame`'s evaluator does
  exactly that across the package boundary. Construct expressions through
  `col` / `lit_*` / operators / methods rather than by spelling variants
  directly, so trees stay on the documented surface. The payload tag enums
  `BinOp` / `UnOp` / `AggOp` are likewise read-only implementation tags —
  no public API names a tag value, so the facade does not re-export them.

### Constructors (static methods + free-function aliases)

- `col(name) -> Expr` / `Expr::col(name)` — a column reference.
- `cols(names : Array[String]) -> Array[Expr]` — `[col(n) for n in names]`,
  the shorthand for projecting / dropping several columns by name through
  the expression verbs (`df.select(cols(["a", "b"]))`).
- `lit(s : Scalar) -> Expr` / `Expr::lit(s)` — a literal from any scalar.
- `lit_int(Int64)` / `lit_float(Double)` / `lit_str(String)` /
  `lit_bool(Bool) -> Expr` — typed literal shorthands (skip the
  `Scalar::Int(...)` noise).
- `lit_series(s : Series) -> Expr` — embed a pre-materialised `Series` as a
  literal column, so a ready-made column joins a pipeline beside the
  declarative expressions. At evaluation it is used as-is: a length-1 series
  broadcasts, a frame-tall one maps row for row, any other length is
  `LengthMismatch`. It is named after the series unless `with_alias`
  overrides, so `with_columns([lit_series(s)])` adds — or in-place replaces —
  a column named `s.name()`.

### Operators (trait impls, in scope through `type Expr`)

- Arithmetic `+` `-` `*` `/` (`Add` / `Sub` / `Mul` / `Div`):
  `col("a") + col("b")`. `/` is **always `Float`** — integer operands are
  promoted — matching Polars; division by zero yields IEEE `±inf` / `NaN`,
  never a trap.
- Logical `&` `|` (`BitAnd` / `BitOr`, **not** bitwise): Kleene
  three-valued `and` / `or`. The equivalent methods are `land` / `lor`
  (the impls' own spelling — `and` is a reserved word, so there is no
  `Expr::and` / `Expr::or`).
- Unary `-` (`Neg`): `-col("x")`.

### Methods

- Comparisons `eq` / `ne` / `lt` / `le` / `gt` / `ge(other) -> Expr` —
  produce a `Bool` column. They are methods, not operators, because `==`
  / `<` are pinned to `Bool` / `Int` returns; the upside is that a method
  binds tighter than `&`, so `a.gt(x) & b.lt(y)` needs no parentheses.
- `not() -> Expr` (no overloadable unary `!`); null probes `is_null()` /
  `is_not_null() -> Expr` (total — the result is never null).
- `fill_null(value : Expr) -> Expr` — replace null cells with `value` (a
  literal, another column — a coalesce — or a computed tree), lowering to
  `when(self.is_not_null()).then(self).otherwise(value)`: non-null cells are
  kept, the result is named after the filled expression (not `value`), and
  the branch dtypes unify like a ternary's (`Int` ↔ `Float` promote, any
  other mismatch is a `TypeMismatch`). A non-null `NaN` is a value, so it is
  kept, not filled.
- Aggregations `sum` / `mean` / `min` / `max` / `count` / `std` /
  `variance` / `median` / `n_unique` / `first` / `last() -> Expr` — wrap
  the expression in a reduction (evaluation semantics below). All eleven
  share one kernel, so each serves the whole-frame `select`, the per-group
  `agg`, and the lazy plan alike. `std` / `variance` are the sample
  statistics (`ddof = 1`, always `Float`, null below two non-null cells);
  `median` is always `Float` (`Int` widens); `n_unique` is the distinct
  non-null count (`Int`); `first` / `last` are positional, keeping the
  source dtype. `variance` is spelled out because `var` is a reserved word.
- `cast(target : DataType) -> Expr`; `with_alias(name : String) -> Expr`
  (names the output column; `alias` is a reserved word).

### String namespace

String operations on a String column, each a `str_*` method building a `Str`
node — the MoonBit spelling of Polars' `.str` accessor, there being no
namespace object. Every operation maps a cell to its result cell by cell: null
cells stay null, a non-String operand is a `TypeMismatch` at evaluation, and
all are total (no value can raise). Matching is always **literal** — there is
no regex engine yet, so the regex forms of `contains` / `replace` are a future
addition.

- `str_to_uppercase()` / `str_to_lowercase() -> Expr` — case mapping.
- `str_strip_chars() -> Expr` — strip leading / trailing ASCII whitespace
  (tab, newline, carriage-return, space).
- `str_len_chars() -> Expr` — the Unicode character count as an `Int` (a
  supplementary-plane character counts once, not as its two UTF-16 code
  units); an all-valid result rides the `Numeric` fast path.
- `str_contains(pattern : String)` / `str_starts_with(prefix : String)` /
  `str_ends_with(suffix : String) -> Expr` — `Bool` columns for the literal
  substring / prefix / suffix tests.
- `str_replace(pattern : String, value : String)` /
  `str_replace_all(pattern : String, value : String) -> Expr` — replace the
  first / every literal occurrence of `pattern` with `value`.

### Conditional

- `when(cond : Expr) -> WhenThen`, then `WhenThen::then(value) ->
  WhenThenElse`, then `WhenThenElse::otherwise(value) -> Expr` — a
  row-wise conditional lowering to a ternary node: the value is the `then`
  branch where `cond` is `true`, the `otherwise` branch otherwise.
  `WhenThen` / `WhenThenElse` are opaque builder steps (only `when` starts
  the chain).

### Closure escape hatch

Where the operators and methods above cover the documented algebra, two
constructors reach past it to an arbitrary host closure applied row by row —
the reified replacement for the v0.1 closure `filter` predicate. The closure
is opaque to introspection, equality, and the optimizer: a map node is
identified by its `label` and inputs.

- `Expr::map_elements(self, label~ : String, f : (Scalar) -> Scalar raise)
  -> Expr` — single input: `f` receives each cell of `self` as a `Scalar`
  (a null cell as `Scalar::Null`) and returns the output cell.
- `map_many(label~ : String, inputs : Array[Expr], f : (Array[Scalar]) ->
  Scalar raise) -> Expr` — several inputs: `f` receives one cell per input,
  in order; `inputs` may mix columns, literals, and aggregations (length-1
  results broadcast over the row count). A row predicate is `map_many(...)`
  returning `Scalar::Bool`.

The closure runs once per row at evaluation and may `raise` (propagating from
the consuming verb). The output column's dtype is the first non-null `Scalar`
returned — an all-null or empty result raises `Unsupported` (there is no
Null-dtype backend, the same limit as a `Null` literal). The result is named
after the leftmost input; `label` shows only in `explain`. Because the
closure can raise on the values it meets, the optimizer treats a map as a
value barrier (like `cast`): no filter sinks across it.

### Introspection (all total)

- `explain(self) -> String`, and the `Show` impl, render the documented
  operator form: `col(name)`, quoted string literals, parenthesised infix
  binaries `(l op r)`, prefix `(-e)` / `(not e)`, postfix `e.is_null()` /
  `e.sum()` / `e.str_contains("p")` / `e.cast(T)`, `e as name`,
  `when(c).then(a).otherwise(b)`, `map("label", [inputs])` for the
  closure escape hatch (the closure opaque), and `lit_series("name", len)`
  for an embedded literal series (its data opaque). `LazyFrame::explain`
  reuses it for plan lines.
- `referenced_columns(self) -> Set[String]` — every column the tree reads,
  including a ternary's condition (the lazy optimizer must keep it alive
  even when only the condition reads it).
- `output_name(self) -> String` — the output column name under Polars'
  rule: an alias wins, else the leftmost column reference, else
  `"literal"` for a column-less tree (a ternary draws its name from the
  value branches, never the condition). The eager materialisers in `frame`
  and the lazy optimizer share this one rule.
- `children(self) -> Array[Expr]` — the immediate sub-expressions of a
  node, left to right (a ternary lists its condition first); leaves return
  none. The shared structural primitive the two walks above and the lazy
  optimizer's stability analyses all recurse through, so the tree's
  recursive shape is declared in exactly one place.

### Evaluation semantics

Applied by the `frame` evaluator, vectorized (whole-column at a time),
raising `DataError` at evaluation time — building the tree never fails:

- **Type promotion**: `Int op Int → Int`, `Float op Float → Float`, mixed
  promotes `Int → Float`; non-numeric arithmetic → `TypeMismatch`.
- **Null propagation**: any null operand of an arithmetic or comparison
  makes the result null (Arrow / Polars).
- **Kleene `&` / `|`**: `true | null = true`, `false & null = false`,
  otherwise null; `not(null) = null`. Non-`Bool` operands → `TypeMismatch`.
- **Comparisons**: cross-numeric is legal, strings compare by
  `compare_string_lex`, `Bool` as `false < true`; the result is a `Bool`
  column.
- **String namespace** (`str_to_uppercase` / `str_contains` / …) maps each
  cell of a String operand through a literal `StrOp` — case, `strip_chars`
  (ASCII whitespace), `len_chars` (an `Int`), the `contains` / `starts_with`
  / `ends_with` predicates (`Bool`), and `replace` / `replace_all`. Null cells
  stay null, a non-String operand is a `TypeMismatch`, and all are total.
- **NaN** inherits the shared reduction rules — `sum` / `mean` (and the
  mean-based `std` / `variance`) propagate a `NaN`, `min` / `max` and the
  order statistic `median` skip it, `n_unique` buckets every `NaN` as one
  value; in comparisons `NaN` is a value.
- **Aggregations** reduce their input to length 1 through the shared
  `reduce.mbt` kernel (so an all-null `mean` / `std` / `variance` / `median`
  is a null cell, `count` / `n_unique` are never null, and `first` / `last`
  take the positional cell — null if that cell is null or the scope empty);
  a length-1 result broadcasts against frame-tall results.
- **Map** (`map_elements` / `map_many`) runs the closure once per row over
  the input cells (each a `Scalar`, a null as `Scalar::Null`); the output
  dtype is the first non-null result's, and an all-null / empty result
  raises `Unsupported`.
- **Literal series** (`lit_series`) is used verbatim — the data analogue of a
  scalar literal's length-1 column — and the consumers broadcast it: a
  length-1 series fills the scope, a frame-tall one passes through, anything
  else is `LengthMismatch`. Its backend is preserved (it is handed through,
  not re-derived), and it reads no frame column.

---

## `series` — Series and the column-level kernels

`Series` — the per-column unit `DataFrame` wraps — lives in its own package
(extracted in v0.5) so the expression layer can build on it. Beyond the type
and its statistics, `series` owns the column-level kernels the frame transforms
reuse: the shared reduction kernel (`reduce.mbt`), the row gather / slice /
rebuild and backend-convergence helpers, and the composite-key cell encoding
(`key_cell` / `KeyCell`). It depends only on `types` / `column`.

### Series

- `struct Series { name, storage : @column.ColumnStorage }` — the `storage`
  field holds the pluggable backend (`Builtin` or `Numeric`). It was a bare
  `@column.BuiltinColumn` through v0.2; this is the v0.3 core breaking
  change (`from_builtin` and `storage().to_builtin()` bridge old call
  sites).
- Total constructors (10): `new(name, ColumnStorage)` (canonical, at the
  seam) / `from_builtin(name, BuiltinColumn)` (source-compatible wrapper) /
  `from_ints` / `from_int_options` / `from_floats` / `from_float_options` /
  `from_bools` / `from_bool_options` / `from_strings` /
  `from_string_options`. **Backend selection**: the no-null `from_ints` /
  `from_floats` land on the `Numeric` fast path; every other constructor
  (the nullable `*_options`, `Bool`, `String`, and `from_builtin`) lands on
  `Builtin`.
- Total inspection: `name` / `dtype` / `len` / `is_empty` /
  `null_count` / `storage() -> ColumnStorage` /
  `storage_kind() -> StorageKind` /
  `to_scalars() -> Array[Scalar]` (materialise every cell, `Null` for
  null cells).
- Fallible (`raise DataError`): `is_null(i) -> Bool` / `get(i) -> Scalar`
  (`IndexOutOfBounds`); `slice(start, end)` / `gather(indices)`;
  `fill_null(value)` (`TypeMismatch` for `Scalar::Null` or a
  dtype-mismatched value); `cast(target)` — the single cross-dtype entry
  (`Int` / `Float` / `String` targets; `Bool` / `Null` → `Unsupported`),
  a numeric result lands on `Builtin` (re-converge with `to_numeric`);
  `to_numeric()` (move onto the `Numeric` backend — `TypeMismatch` for a
  non-numeric column, `InvalidOperation` for one with nulls).
- Total transforms: `rename(new_name)` (`O(1)`, storage shared);
  `drop_nulls()` (gather non-null cells); `to_builtin()` (materialise onto
  the `Builtin` backend — lossless inverse of `to_numeric`). Structural
  transforms (`slice` / `gather` / `drop_nulls` / `fill_null`, and `head` /
  `tail` / `filter` / `sort` / `join` at the frame level) **preserve the
  backend** — a `Numeric` column stays on the fast path where it gains no
  null; cross-dtype casts borrow the `Builtin` road.

### Series stats (`series_stats.mbt`)

- Total: `count()` (non-null count); `n_unique()` (distinct non-null
  values, keyed by the same composite `key_cell` normalisation `group_by` /
  `join` use, so the distinct count agrees with grouping cell-for-cell —
  every `Float` `NaN` collapses to one bucket and `-0.0` folds into `+0.0`);
  `min()` / `max()` — the reduction proper,
  returning a `Scalar` directly (every v0.1 dtype has an order, so they
  never fail; empty / all-null / all-NaN → `Scalar::Null`; `String` uses
  lexicographic order; `Bool` is `false < true`).
- Fallible (`raise DataError`): `sum()` — `Int` / `Float` →
  `Scalar::Int` / `Scalar::Float`, empty / all-null is the additive
  identity, `Bool` / `String` → `TypeMismatch`; `mean()` — `Double`,
  empty / all-null numeric → `InvalidOperation`, non-numeric →
  `TypeMismatch`. `mean_opt() -> Double?` is the **total** form of `mean`
  (`Some(mean)`, or `None` exactly where `mean` would raise) — the accessor
  `frame`'s `DataFrame::describe` reads across the package boundary. `Float`
  `NaN` is a value, not missing: it **propagates** through `sum` / `mean`
  (any non-null `NaN` ⇒ `NaN`) but is **skipped** by `min` /
  `max` (and `sort`) — matching Polars, whose `sum`/`mean`
  propagate `NaN` while its regular `min`/`max` ignore it (only `Null` is
  ever treated as missing).

---

## `frame` — DataFrame and operators

The `ops` verbs are folded in here as `DataFrame` methods (one operator
per file), so a pipeline is a method chain. `frame` reads `@series.Series`
(the column unit it wraps) and `@expr.Expr` (to evaluate the expression
consumers below) on top of `types` / `column`; it has **zero external
dependencies** (NyaCSV / fs / @json live only in `io`).

### DataFrame

- `struct DataFrame` — column-oriented table; fields private outside the
  package (`schema`, `columns`, `nrows`, private `name_to_index` cache
  for `O(1)` name lookup).
- Constructors (`raise DataError`): `new(columns)`
  (`LengthMismatch` / `DuplicateColumn`; zero columns → `0×0`);
  `empty(schema)` (0-row frame; `Unsupported` for a `Null`-dtype field);
  `from_rows(schema, rows)` (`LengthMismatch` / `TypeMismatch` /
  `Unsupported`; zero-column schema → `0×0`, like `new`).
- Total inspection: `shape()` / `schema()` / `columns()` (fresh array) /
  `column_series()` (fresh array of the immutable `Series`) / `nrows()` /
  `ncols()` / `is_empty()`.
- `to_scalar_matrix() -> Array[Array[Scalar]]` (**total**) — every column's
  cells column-major (`result[c][r]` is column `c` / row `r`, `Null` for a
  null slot). The one-pass bulk read the row-oriented serialisers /
  renderers (`format_csv_str` / the JSON record emitter / `to_html` /
  `to_markdown`) share, so a record is assembled by plain `[c][r]` indexing
  rather than a per-cell `get`.
- Accessors (`raise DataError`): `get_column(name)`
  (`ColumnNotFound`); `get_column_at(i)` (`IndexOutOfBounds`);
  `item(row, name) -> Scalar` (Polars' `df.item`, a single cell —
  `ColumnNotFound` / `IndexOutOfBounds`); `row(i) -> Array[Scalar]` — row `i`'s cells in
  column order, a Polars-style tuple (`Null` for a null cell;
  `IndexOutOfBounds`).
- `rows() -> Array[Array[Scalar]]` (**total**) — every row as a tuple
  (`result[r][c]`), the row-major transpose of `to_scalar_matrix`. For more
  than a handful of rows, prefer this over a `row(i)` loop — it reads the
  frame once.
- Structural transforms: total `head(n)` / `tail(n)` (clamp `n` to
  `[0, nrows]`); `slice(start, end)` / `take(indices)` (`raise`,
  `IndexOutOfBounds` / `InvalidOperation`).
- Storage backend control (all **total**): `storage_kinds() ->
  Array[StorageKind]` (per-column backend, parallel to `columns()`);
  `to_numeric()` (best-effort — move every all-valid Int / Float column
  onto the `Numeric` fast path, keep nullable / non-numeric / already-
  `Numeric` columns); `to_builtin()` (materialise every column onto
  `Builtin`, the inverse). Names / dtypes / values are unchanged, so the
  schema and lookup cache are reused verbatim.
- `check_invariants() -> Result[Unit, String]` — verification helper
  (deliberately **not** migrated to `raise`). `Ok(())` iff the frame
  satisfies its seven structural invariants; otherwise `Err(msg)`.

### DataFrame operator methods (folded-in `ops`)

All route their result through invariant-preserving constructors /
transforms, so every output satisfies `check_invariants()`.

- `drop(columns : Array[Expr]) -> DataFrame raise DataError` — remove the
  named columns, order preserved. Each key resolves to a column name via
  `Expr::output_name` (a bare `col("x")`, or an alias) — the expression is
  not evaluated. Duplicate keys idempotent; `ColumnNotFound` on the first
  unknown. The `Array[Expr]` container leaves room for a future column
  selector.
- `rename(mapping : Array[(String, String)]) -> DataFrame raise DataError`
  — apply renames in order (each step's `new_name` is visible to later
  steps, enabling a 3-step swap). `ColumnNotFound` / `DuplicateColumn`.
- `sort(keys : Array[(Expr, SortOrder, NullOrder)]) -> DataFrame raise
  DataError` — stable multi-key sort. Each key is an `(Expr, order,
  null_order)` tuple, the expression evaluated over the whole frame: a bare
  `col("c")`, or a derived key like `col("a") + col("b")` that sorts by the
  computed value without materialising it into the output. Earlier keys
  dominate; a length-1 key (a literal or an aggregation like `col("c").sum()`)
  broadcasts as a stable no-op. A single-key sort passes a one-element array.
  Evaluation errors surface here — `ColumnNotFound` on the first unknown key,
  `TypeMismatch` on a dtype clash. Empty key set is the identity.
- `drop_nulls(subset? : Array[Expr]) -> DataFrame raise DataError` — drop
  rows with a null cell in a gating column. With `subset` omitted, every
  column gates (drop a row null in **any** column); with `subset` given,
  only the listed columns gate — each key resolved to a name via
  `Expr::output_name` — so a row null in an unlisted column is kept and an
  empty subset is the identity. `ColumnNotFound` on the first unknown;
  duplicate keys idempotent.
- `fill_null(value : Scalar) -> DataFrame raise DataError` — fill every null
  cell of the **dtype-compatible** columns with `value` (an `Int` value fills
  `Int` columns, and so on); columns of any other dtype — and all columns when
  `value` is `Scalar::Null` — are left untouched (the fill is always
  dtype-preserving). Names, dtypes, and the row count are unchanged. For
  per-column or cross-dtype fills, or filling with a computed value, use
  `Expr::fill_null` through `with_columns`.
- `null_count() -> DataFrame raise DataError` — `1 × ncols` `Int`
  summary; 0-column collapses to `0×0`.
- `sum() -> DataFrame` / `mean() -> DataFrame` / `min() -> DataFrame` /
  `max() -> DataFrame` / `count() -> DataFrame` (all `raise DataError`) —
  whole-frame reductions to a 1-row frame, one cell per source column,
  names and order preserved (Polars' `df.sum()` shape). `sum` / `mean` /
  `min` / `max` are numeric-only: a numeric column reduces (`sum` / `min` /
  `max` keep the source dtype, `mean` → `Float`), a non-numeric (`Bool` /
  `String`) column becomes a `Null` cell kept in its dtype — so `sum` /
  `min` / `max` preserve the schema. (This nulls `min` / `max` on `Bool` /
  `String` rather than ordering them; use `Series::min` /
  `max` for a typed extremum over any dtype.) `count` is the
  non-null count as `Int` for every column. An empty / all-null numeric
  column gives the additive identity under `sum` and a `Null` cell under
  `mean` / `min` / `max`; a 0-column frame collapses to `0×0`. The
  `raise` is forwarded from the 1-row `DataFrame::new`, never taken. For
  one column's scalar, read its `Series`: `df.get_column(c).sum()`
  (= Polars `df[c].sum()`).
- `describe() -> DataFrame raise DataError` — per-column summary, one row
  per source column, fixed `N × 8` schema (`column` / `dtype` / `count` /
  `null_count` / `n_unique` (`Int`); `mean` (`Float`, nullable);
  `min` / `max` (`String`, nullable, rendered via `Scalar::to_string`)).
  `min` / `max` are stringified so a single column can carry extrema across
  source columns of differing dtype. 0-column collapses to `0 × 8`.
- `to_markdown() -> String` / `to_markdown_with_limit(limit) -> String`
  — **total** GitHub-flavored pipe-table renderers (IO-1: pure rendering
  lives in `frame`). Column widths align to `max(header, cells)` with a
  3-char minimum; null cells render empty; `|` / `\` / CR / LF are
  GFM-escaped. `with_limit` appends `... (N more rows)` when truncated
  (negative `limit` clamps to 0).
- `to_html() -> String` / `to_html_with_options(options : HtmlOptions) ->
  String` — **total** HTML `<table>` renderers (IO-1: pure rendering lives
  in `frame`, parallel to `to_markdown`). `to_html` emits a `<thead>` +
  `<tbody>`, one `<td>` per cell in declaration order; a null cell renders
  as `<td></td>`; `&` / `<` / `>` / `"` are escaped to HTML entities.
  0 columns → empty string; N columns / 0 rows → header + empty `<tbody>`.
  `to_html_with_options` adds a `class` / `<caption>` and, via `max_rows`,
  a row cap with a `<tfoot>` `... (K more rows)` banner (negative
  `max_rows` clamps to 0).
- `struct HtmlOptions` (fields private) — built via `HtmlOptions::default()`
  (all rows, no `class` / `caption`, `escape = true`) and chained
  `with_max_rows(n)` / `with_table_class(cls)` / `with_caption(text)` /
  `with_escape(flag)`. `with_escape(false)` emits caption / header / cell
  / class strings verbatim, for trusted input that intentionally carries
  HTML.

### Expression consumers (`with_columns` / `select` / `filter`)

The eager face of the `expr` engine — `DataFrame` methods that evaluate
`@expr.Expr` trees over the whole frame. (The evaluator and these
consumers live in `frame` because a method is package-bound to its type
and the evaluator reads `Series` internals.) All route through
`DataFrame::new`, so every output satisfies `check_invariants()`; all
raise the evaluator's `DataError` (`ColumnNotFound` / `TypeMismatch` /
`LengthMismatch`), plus `DuplicateColumn` on an output-name clash.

- `with_columns(exprs : Array[Expr]) -> DataFrame raise DataError` —
  evaluate each expression and append it (or, on a name clash with an
  existing column, replace it in place); every other column is kept. Each
  result is named by `Expr::output_name`. A length-1 (literal /
  aggregation) result broadcasts to the frame height; on a 0-row frame it
  broadcasts to 0.
- `select(exprs : Array[Expr]) -> DataFrame raise DataError` — the output
  is **only** the evaluated expressions (a fresh frame). MoonFrame's single
  `select` verb: a names-only projection is `select(cols(["a", "b"]))` (or
  `select([col("a"), col("b")])`). A mix of aggregations and element-wise
  expressions broadcasts the aggregations to the frame height; an
  **all-aggregation** selection collapses to a single row (Polars'
  `select(sum)` shape).
- `filter(predicate : Expr) -> DataFrame raise DataError` —
  vectorized boolean row selection: evaluate `predicate` (which must be a
  `Bool` column of frame height; non-`Bool` → `TypeMismatch`) and keep the
  `true` rows (a `false` / null cell drops the row, matching Polars). A
  length-1 predicate broadcasts. This is the eager executor the lazy
  `Filter` node defers — and, being a reified `Expr` rather than a closure,
  the predicate the optimizer can push down. A row-wise host predicate is
  reachable through the `map_many` escape hatch.

A computed numeric result lands on the `Numeric` backend when all-valid,
`Builtin` otherwise; a `col(...)` reference preserves its source column's
backend.

### GroupBy (`group_by` / `agg`)

Split-apply-combine, native to the method chain
(`df.group_by(keys).agg(exprs)`).

- `group_by(keys : Array[Expr]) -> GroupedDataFrame raise DataError` —
  partition the frame by one or more key **expressions**. Each key is
  evaluated over the whole frame like a `sort` key: a bare `col("region")`
  groups by an existing column, a derived key such as `(col("a") + col("b"))`
  groups by the computed value, and a length-1 key (a literal, or an
  aggregation like `col("x").sum()`) broadcasts over the frame, collapsing it
  into one group. The materialised key columns head the `agg` output, each
  named by its expression's output name (alias, else leftmost column
  reference, else `"literal"`) and keeping its evaluated dtype. Group order
  is **first appearance** (equivalent to Polars' `maintain_order=True`), so
  the result is deterministic. Group identity is the composite tuple of the
  key cells, hashed on each cell's native value, so a `Float` `NaN` collapses
  all NaNs into one group (Polars treats `NaN` as equal for grouping; `-0.0`
  and `+0.0` likewise share a group), and a **null** key forms its **own**
  group rather than being dropped (the Polars default — pandas drops null
  keys — and the deliberate difference from `join`, where `null` matches
  nothing). One key or several; an empty `keys` list makes a single
  grand-total group; a 0-row frame yields zero groups. `ColumnNotFound` /
  `TypeMismatch` on the first offending key; `DuplicateColumn` if two keys
  produce the same output name (rejected up front, mirroring `select`).
- `GroupedDataFrame::agg(exprs : Array[Expr]) -> DataFrame raise DataError`
  — reduce each group to a row. Each `@expr.Expr` is evaluated once per
  group (the group's row indices as the evaluation scope) and must reduce
  to a single value: a bare-column reduction such as `col("revenue").sum()`,
  or a *compound* one such as `(col("revenue") - col("cost")).sum()` or a
  `col("x").max() - col("x").min()` range. Output columns are the key
  columns (in key order, named by each key's output name and keeping its
  evaluated dtype) followed by one column per
  expression (in expression order, named by `Expr::output_name` — alias,
  else leftmost column reference, else `"literal"`); one row per group, in
  group order. Each reduction inherits the shared reduction kernel's
  null / `NaN` / dtype rules:
  - `count()` → `Int`, non-null cells only (like `Series::count` / Polars'
    `count`, **not** a row count like `len`);
  - `sum()` → source numeric dtype (`Int`/`Float`), additive identity for an
    empty / all-null group; a `NaN` cell propagates to a `NaN` total (`NaN`
    is a value, not missing);
  - `mean()` → nullable `Float`, a null cell for an all-null group; a `NaN`
    cell propagates to a `NaN` mean;
  - `min()` / `max()` → source dtype, a null cell for an empty / all-null
    group, `NaN` skipped — like Polars' regular `min`/`max` (every dtype is
    ordered, so they apply to all four);
  - `std()` / `variance()` → nullable `Float`, the sample statistics
    (`ddof = 1`): a null cell for a group with fewer than two non-null cells,
    a `NaN` cell propagating through the mean (numeric only, else
    `TypeMismatch`);
  - `median()` → nullable `Float` (`Int` widens), a null cell for an empty /
    all-null group, `NaN` skipped like `min` / `max` (numeric only);
  - `n_unique()` → `Int`, the distinct non-null count, never null (every
    `NaN` one bucket, `-0.0` folding into `+0.0`, as `Series::n_unique`);
  - `first()` / `last()` → source dtype, the group's first / last cell in
    row order — null if that cell is null.
  An empty `exprs` list degenerates to a **distinct** over the key columns
  (the unique key tuples). Routes through `DataFrame::new`, so every output
  satisfies `check_invariants()`. Raises: `InvalidOperation` if an
  expression is not reduction-shaped (it must reduce every group to one
  value structurally — a bare column reference does not; implicit
  Polars-style list-aggregation is out of scope), `TypeMismatch` (e.g.
  `sum()` on a non-numeric column), `ColumnNotFound` (an expression's
  column is absent), `DuplicateColumn` (two output names collide — e.g. two
  reductions over the same column, or an alias shadowing a key column).

### Join (`join`)

Hash equi-join, native to the method chain (`left.join(right, options)`).

- `join(other, options : JoinOptions) -> DataFrame raise DataError` — join
  `self` (left) with `other` (right) on the key **expressions** in
  `options.on` (applied to both frames) or the paired `left_on` /
  `right_on`. Each key is an expression evaluated like a `sort` /
  `group_by` key — a bare `col("id")` joins on a column, a derived key such
  as `col("ts") / lit_int(86400)` on the computed value. Two rows match
  when every key holds an equal value, using the **same composite-key
  encoding as `group_by`** (a tuple of the key cells, keyed on each native
  value, structurally injective across key columns). The one deliberate
  difference from `group_by`: a **null** key matches **nothing**
  (`null != null`, the SQL / Polars default) — such an unmatched row is
  dropped by `Inner` and kept (with the other side's columns null) by
  `Left` / `Right` / `Outer`. A `Float` `NaN` key is not null, so (as in
  `group_by`, matching Polars' "NaN compares equal" rule) it renders
  `"NaN"` and **matches other `NaN` keys**.
  - **`how`** selects which unmatched rows survive: `Inner` (matched pairs
    only), `Left` (+ unmatched left rows, right null), `Right` (+ unmatched
    right rows, left null — the mirror of `Left`), `Outer` (+ unmatched rows
    from **both** sides), `Cross` (the keyless Cartesian product, below).
  - **Columns** = left columns (original order and names) then the right
    frame's columns (original order). Coalescing applies only to an `on`
    join whose every key is a bare `col(...)` (the one shape where a key
    names the same column on both sides); `left_on` / `right_on` and any
    derived key turn it off (Polars' rule), so both key columns are kept
    and a derived key contributes no column of its own. Whether an eligible
    key is coalesced is governed by `options.coalesce`. When a key is
    **coalesced** it appears once at the left key's position, taking each
    row's value from whichever side is present — the left on `Inner` /
    `Left`, the right on `Right`, the present side per row on `Outer` (the
    two are equal on a matched pair) — and the right key column is dropped.
    When **not** coalesced, the right key column is kept, suffixed (`<key>`
    + `options.suffix`, default `"_right"`) and null wherever its row had no
    match. Any other right column whose name occurs in the left frame is
    likewise suffixed; the left column keeps its name.
  - **Rows** = left rows in order (each with its right matches in ascending
    right-row order, then — for `Left` / `Outer` — unmatched left rows in
    place with null right columns), followed for `Outer` by the unmatched
    right rows in right-row order. `Right` instead emits every right row in
    right-row order (each with its left matches in ascending left-row order,
    else the right row alone with null left columns). Fully determined by
    input order (snapshot-stable).
  - `how = Cross` is the **Cartesian product** (every left row × every
    right row); it takes **no** keys, ignores `coalesce`, and keeps every
    column of both frames (a clashing right column is suffixed). This is the
    explicit form of what `group_by([])`'s grand-total group is for
    aggregation.
  - **Backend**: like the other structural transforms (`filter` / `sort`
    / `take` / `drop_nulls`), each output column keeps its source's storage
    backend where it picks up no unmatched-row null — an all-valid `Numeric`
    source column stays `Numeric`; a column that gains a null from an
    unmatched row (or whose source was already `Builtin`) is `Builtin`. Only
    the representation is affected; values and dtypes are unchanged.
  - Routes through `DataFrame::new`, so every output satisfies
    `check_invariants()`. Raises: `ColumnNotFound` (a key expression
    references an absent column; first offending key in key order, the left
    key evaluated before the right), `TypeMismatch` (a key's left and right
    dtypes differ, or a derived key's own dtypes don't unify),
    `InvalidOperation` (no keys for a non-`Cross` join — use `Cross` for a
    product — any keys on a `Cross` join, both `on` and `left_on` /
    `right_on` given, or `left_on` / `right_on` of unequal length),
    `DuplicateColumn` (two keys with the same output name — rejected at the
    repeat, like `group_by([col("id"), col("id")])`; or two output columns
    still colliding after suffixing — surfaced by `DataFrame::new`).
- `enum JoinType` — `Inner` / `Left` / `Right` / `Outer` / `Cross`.
- `struct JoinOptions` (fields private) — built via
  `JoinOptions::on(keys : Array[Expr])` (same keys on both frames),
  `JoinOptions::left_on(keys).with_right_on(keys)` (differently-named or
  -derived keys, paired position by position), or `JoinOptions::cross()`
  (keyless `Cross`) — each defaulting to `Inner`, suffix `"_right"`,
  `coalesce` auto — with `with_how(JoinType)` / `with_suffix(name)` /
  `with_coalesce(Bool)` to override. `coalesce` defaults to `None` (auto:
  coalesce on an inner join, keep both keys on a `Left` / `Right` / `Outer`
  join — Polars' rule) and only takes effect for an all-bare-`col` `on`
  join; `left_on` / `right_on` and derived keys never coalesce. Chainable:
  `JoinOptions::on([col("id")]).with_how(Outer).with_coalesce(true)`.

### Sorting types

- `enum SortOrder` — `Asc` / `Desc`. `enum NullOrder` — `NullsFirst` /
  `NullsLast` (for `Float`, `NaN` is treated as missing, like `Null`).
- A sort key is an `(Expr, SortOrder, NullOrder)` tuple; `sort` takes an
  `Array` of them. Multi-key sort lists several; a single-key sort passes a
  one-element array (e.g. `[(col("score"), Desc, NullsLast)]`).

---

## `io` — Serialization (IO-1 boundary)

Read / parse / write functions `raise DataError`; the string serialisers
(`format_csv_str` / `format_json_records` / `format_ndjson`) are **total**
and return a `String`. The one exception is `format_vega_lite`, which
`raise`s — a `ChartSpec` names the columns to plot, and a missing name is
`ColumnNotFound`. Tokenisation delegates to `moonbit-community/NyaCSV`;
JSON / Vega-Lite specs go through the builtin `@json`; file wrappers
delegate to `moonbitlang/x/fs` and promote its `IOError` to
`raise DataError::IoError(message)`.

The dtype-inference rules these readers share — the `Int → Float → Bool →
String` order, what happens to a cell past the inference window, and the
accepted numeric forms — are explained in
[`type-inference.md`](type-inference.md); the per-reader options that tune them
are documented below.

### CSV

- `struct CsvReadOptions` — `has_header` (default `true`; `false`
  synthesises `"column1"`, …) / `delimiter` (`,`) / `infer_schema_rows`
  (`100`; `0` or any value `<= 0` lifts the cap and scans every row —
  Polars' `infer_schema_length=None`) / `null_values` (`[""]`) /
  `strict_column_count` (`false`; when `true`, a ragged data row — cell
  count ≠ header width — raises `ParseError` instead of being null-padded /
  truncated) / `on_parse_error` (`Raise`; see `OnParseError` below) /
  `allow_nonfinite_floats` (`true`; when `false`, the `nan` / `inf` /
  `infinity` float literals are rejected during inference, so a column of
  them falls back to `String` instead of being retyped to `Float`).
  `CsvReadOptions::default()`.
- `enum OnParseError { Raise; Null }` (`pub(all)`) — the parse-failure
  policy shared by the three readers' options. A non-null cell past the
  inference window that doesn't fit its column's locked-in dtype either
  fails the whole read with `ParseError` (`Raise`, the default — strict and
  lossless) or is downgraded to a null cell, keeping the column's inferred
  dtype (`Null`, Polars' `ignore_errors=True`).
- `struct CsvWriteOptions` — `header` (`true`) / `delimiter` (`,`) /
  `null_value` (`""`). `CsvWriteOptions::default()`.
- `parse_csv_str(content, options) -> DataFrame raise DataError` —
  tokenise → per-column inference (`Int → Float → Bool → String`) → null
  mapping → `DataFrame::new`. `DuplicateColumn` / `ParseError` (the latter
  also covers a ragged row when `options.strict_column_count`, and a cell
  that doesn't fit its dtype unless `options.on_parse_error = Null`).
- `format_csv_str(df, options) -> String` — **total**. Cells render via
  `Scalar::to_string`; null → `options.null_value`; RFC 4180 quoting;
  LF-terminated.
- `read_csv(path)` / `read_csv_with_options(path, options) -> DataFrame
  raise DataError` — file wrappers (`IoError`).
- `write_csv(path, df)` / `write_csv_with_options(path, df, options) ->
  Unit raise DataError` — file wrappers (`IoError`).

### JSON (records shape `[{...}, ...]`)

- `struct JsonReadOptions` — `infer_schema_rows` (`100`; `0` or `<= 0`
  scans every record) / `on_parse_error` (`Raise`; the shared
  `OnParseError`, documented under CSV). `JsonReadOptions::default()`.
- `parse_json_records_str(content, options) -> DataFrame raise DataError`
  — `@json.parse` → object validation → headers in first-seen order
  across all records (sparse records → null cells) → inference (same
  order as CSV; `Number` locks `Int` when integral and in `Int64` range,
  else `Float`; `true` / `false` only for `Bool`; mixed → `String`
  fallback) → `DataFrame::new`. `ParseError`.
- `format_json_records(df) -> String` — **total**. One object per row,
  keys in `df.columns()` order; `Null → null`, bools / strings / finite
  numbers via `@json`. A non-finite `Float` (`NaN` / `±Infinity`) has no
  JSON literal, so it is emitted as `null` (like pandas' `to_json`),
  keeping the output valid JSON; a round-trip reads it back as a null.
  `Int` cells render as JSON numbers; a magnitude beyond 2^53 keeps its
  `Int` dtype but loses precision on a JSON round-trip (the `@json` number
  model is `Double`), as in pandas' `to_json`.
- `read_json(path)` / `read_json_with_options(path, options) -> DataFrame
  raise DataError`; `write_json_records(path, df) -> Unit raise
  DataError` — file wrappers (`IoError`).

### NDJSON (JSON Lines, one object per line `{...}\n{...}\n…`)

The streaming-friendly sibling of the JSON-records shape (Polars'
`read_ndjson` / `write_ndjson`, pandas' `read_json(lines=True)`).
Everything after the line framing is shared with the records
reader / writer — header collection (first-seen order across all lines,
sparse lines → null cells), the `Int → Float → Bool → String` inference,
and the `scalar_to_json` cell conventions — so a column inferred from
NDJSON matches the same data read as a JSON array.

- `struct NdjsonReadOptions` — `infer_schema_rows` (`100`; `0` or `<= 0`
  scans every record) / `on_parse_error` (`Raise`; the shared
  `OnParseError`, documented under CSV). `NdjsonReadOptions::default()`.
  Structurally identical to `JsonReadOptions`; kept a separate type so the
  two formats can diverge later.
- `parse_ndjson_str(content, options) -> DataFrame raise DataError` —
  split on `\n` → parse each non-blank line (`@json.parse`) → the shared
  records → frame core. Blank / whitespace-only lines are skipped and a
  trailing `\r` (CRLF) is tolerated as JSON whitespace, so the writer's
  trailing newline (and incidental blank lines) round-trip without
  phantom rows. A malformed line surfaces as `ParseError("line N: …")`
  (1-based); a line whose value is not an object, or a typed mismatch
  past the inference window (unless `options.on_parse_error = Null`), is
  also `ParseError`. Empty / all-blank input → 0×0 frame.
- `format_ndjson(df) -> String` — **total**. One compact object per row,
  keys in `df.columns()` order, each line terminated by `\n` (including
  the last — matching the CSV writer's per-row LF and Polars'
  `write_ndjson`); a 0-row frame renders the empty string. Per-cell
  rules match `format_json_records` (non-finite `Float` → `null`; `Int`
  beyond ±2^53 keeps its dtype but loses precision on a round-trip).
- `read_ndjson(path)` / `read_ndjson_with_options(path, options) ->
  DataFrame raise DataError`; `write_ndjson(path, df) -> Unit raise
  DataError` — file wrappers (`IoError`).

### Chart export (Vega-Lite v5)

`format_vega_lite` emits a complete, standalone [Vega-Lite v5](https://vega.github.io/vega-lite/)
specification as a JSON string — `$schema` + optional `title` + `mark` +
`encoding` + an inline `data.values` array — that drops straight into the
[Vega editor](https://vega.github.io/editor/) or any Vega-Lite runtime.
It is a serialiser (the IO-1 boundary keeps it in `io`, parallel to
`format_json_records`), and it shares that emitter's `scalar_to_json` cell
mapping, so a `data.values` cell follows the same rules (null and
non-finite-float cells → JSON `null`).

- `enum ChartKind { Bar; Line; Point; Area }` (`pub(all)`) — the mark
  type, mapped to the Vega-Lite `mark` (`"bar"` / `"line"` / `"point"` /
  `"area"`).
- `struct ChartSpec` (fields private) — built via a mark-named
  constructor `ChartSpec::bar(x, y)` / `line(x, y)` / `point(x, y)` /
  `area(x, y)` (`x` / `y` are column names) and chained
  `with_color(column)` (a grouping / colour column) / `with_title(text)`.
- `format_vega_lite(df, spec) -> String raise DataError` — **not total**.
  Resolves the spec's `x` / `y` / `color` columns against `df`
  left-to-right; the first name absent from the frame raises
  `ColumnNotFound(name)`. Each channel's Vega-Lite field `type` is
  inferred from the column dtype: numeric (`Int` / `Float`) →
  `"quantitative"`, otherwise (`String` / `Bool`, and an all-null `Null`
  column) → `"nominal"`. The frame is inlined as `data.values` (a frame
  with the encoded columns but zero rows yields `"values":[]`). The output
  is always valid JSON.
- `write_vega_lite(path, df, spec) -> Unit raise DataError` — file wrapper
  (propagates `ColumnNotFound`; filesystem failure → `IoError`).

---

## `lazy` — Lazy query layer

A deferred query plan over an in-memory frame. `lazy_frame(df)` (or
`LazyFrame::from(df)`) starts a plan; builder methods that mirror the
eager verbs name-for-name grow it without computing anything; `collect()`
optimizes and runs it. Building is **total** — a `LazyFrame` is plain data
— so a plan can always be built, chained, and `explain`ed; every failure
waits for `collect`. `lazy` depends on `frame` + `expr` (it interprets a
plan through the public eager operators and holds `@expr.Expr` nodes);
`frame` does **not** depend on `lazy`, so there is no cycle.

- `struct LazyFrame` (fields private) — wraps a private `LogicalPlan` (one
  node per eager verb; the IR never leaks into the public surface).
- `struct LazyGroupBy` (fields private) — the deferred `group_by` step
  (keys attached, nothing partitioned), produced by `LazyFrame::group_by`
  and completed by `agg`.

### Entry points

- `LazyFrame::from(df : DataFrame) -> LazyFrame` — the static constructor
  (a `Scan` leaf over the captured frame). Named after the
  `Series::from_*` / `DataFrame::from_rows` family; **not** a
  `DataFrame::lazy` method (that would force a `frame ↔ lazy` import
  cycle).
- `lazy_frame(df : DataFrame) -> LazyFrame` — a free-function alias for
  `from`, for the `read_csv(path)` hand-feel. (`lazy(df)` would be the
  obvious name, but `lazy` is a MoonBit reserved word.)

### Builders (all total — a plan is just data)

Each returns a new `LazyFrame` wrapping one more node:

- `filter(predicate : Expr)` · `with_columns(exprs : Array[Expr])` ·
  `select(exprs : Array[Expr])` — defer the eager expression consumers.
- `sort(by : Array[(Expr, SortOrder, NullOrder)])` · `head(n)` ·
  `tail(n)` · `limit(n)` (≡ `head`) · `slice(start, end)`.
- `join(other : LazyFrame, options : JoinOptions)` — the right side
  carries its own deferred pipeline.
- `group_by(keys : Array[Expr]) -> LazyGroupBy`, then
  `LazyGroupBy::agg(exprs : Array[Expr]) -> LazyFrame` — mirrors
  `group_by(keys).agg(exprs)` as one fused `Aggregate` node (key
  expressions and aggregations evaluated at collect time).

### Running and inspecting

- `collect(self) -> DataFrame raise DataError` — optimize the plan (below),
  then interpret it bottom-up through the public eager operators. With the
  optimizer's equivalence guarantee, the result is **bitwise-equal** to
  running the same verbs eagerly in the same order; every failure (missing
  columns, type mismatches, slice bounds) is the eager operator's
  `DataError`, surfacing here rather than at build time.
- `explain(self, optimized? : Bool = false) -> String` — render the plan
  as an indented tree: root verb first, inputs two spaces deeper,
  expressions in their `Expr::explain` form, compact `SCAN [rows×cols]`
  leaves (never the data), `AGGREGATE [exprs] BY [keys]` for a group-by
  (both `exprs` and `keys` rendered as expression lists).
  The default renders the plan **as built** (the package's contract — a
  faithful mirror of the chain); `optimized=true` renders the rewritten
  plan `collect` actually runs, so printing both is the before/after view.
  Total either way (the rewrite is a pure tree walk, and a plan that would
  fail to `collect` still explains).

### Query optimizer

`collect` runs two total, result-preserving rewrites before executing:

- **Predicate pushdown** sinks each `filter` toward the scan so rows
  drop as early as possible — below a selection when its expressions are
  row-local (no aggregation, no `cast`) and every predicate column is a
  bare `col(name)`; below a `with_columns` (same row-local rule) when the
  stage defines none of the predicate's columns; below an aggregation when
  the predicate is row-local, reads key columns only, and every
  aggregation cell is provably null-free and value-safe (`sum` / `count` /
  `n_unique` and non-null literal combinators qualify; `mean` / `min` /
  `max` / `std` / `variance` / `median` can go null on an all-null group,
  `first` / `last` on a null cell, and a `cast` can reject a value, so they
  pin the filter above). Positional row windows, `sort`, `join`, and another
  filter stop the descent.
- **Projection pushdown** then runs a top-down required-columns analysis
  (via `Expr::referenced_columns` / `Expr::output_name`) and inserts a
  narrowing selection of bare column references directly over a scan whose
  consumers read a proper subset of its columns, dropping dead columns
  before any row-level work. `Select` / `Aggregate` originate requirements;
  `Filter` / `Sort` widen the requirement by what they read; row windows
  pass it through; a `with_columns` subtracts the names it defines and adds
  the names it reads; `Join` is a barrier (each side restarts its own
  pass).

The rewrites never change results: `collect` stays bitwise-equal to the
eager chain, and a failing plan still fails (a single broken stage reports
the same eager error; a plan with several independently broken stages may
report a different one of its own errors once a filter sinks past a broken
stage — which error surfaced was an artifact of stage order to begin
with). Deferred (out of scope): dead-expression elimination, narrowing /
predicate-splitting through joins, and sinking filters below sorts.

---

## `moonframe` — Facade package

`moonframe.mbt` re-exports every symbol above via `pub using`, so a
single `import "ihb2032/MoonFrame" @moonframe` reaches the whole surface.
Because the operator verbs and `to_markdown` are **methods on
`DataFrame`**, re-exporting `type DataFrame` makes them automatically
reachable; likewise the `Expr` operators / methods ride along with
`type Expr`, and the `LazyFrame` / `LazyGroupBy` methods (including the
`LazyFrame::from` constructor) with their types — so only the value types
and the free functions are listed explicitly. The inert `BinOp` / `UnOp`
/ `AggOp` tag enums are deliberately **not** re-exported (no public API
names them).

- From `@types`: `DataError` · `DataType` · `Scalar` · `Field` · `Schema` ·
  `compare_string_lex` · `is_decimal_int_literal`
- From `@column`: `Bitmap` · `BuiltinColumn` · `ColumnData` ·
  `NumericColumn` · `NumericData` · `ColumnStorage` · `StorageKind`
- From `@expr`: `Expr` · `WhenThen` · `WhenThenElse` · `col` · `cols` ·
  `lit` · `lit_int` · `lit_float` · `lit_str` · `lit_bool` · `lit_series` ·
  `when` · `map_many`
- From `@series`: `Series`
- From `@frame`: `DataFrame` · `SortOrder` ·
  `NullOrder` · `GroupedDataFrame` · `JoinType` ·
  `JoinOptions` · `HtmlOptions`
- From `@io`: `CsvReadOptions` · `CsvWriteOptions` · `JsonReadOptions` ·
  `NdjsonReadOptions` · `OnParseError` · `ChartKind` · `ChartSpec` ·
  `format_csv_str` ·
  `format_json_records` · `format_ndjson` · `format_vega_lite` ·
  `parse_csv_str` · `parse_json_records_str` · `parse_ndjson_str` ·
  `read_csv` · `read_csv_with_options` · `read_json` ·
  `read_json_with_options` · `read_ndjson` · `read_ndjson_with_options` ·
  `write_csv` · `write_csv_with_options` · `write_json_records` ·
  `write_ndjson` · `write_vega_lite`
- From `@lazy`: `LazyFrame` · `LazyGroupBy` · `lazy_frame`

`using @pkg { type T }` also creates constructor aliases, so
`@moonframe.Scalar::Int(42)`, `@moonframe.SortOrder::Desc`,
`@moonframe.DataError::ColumnNotFound("y")` all resolve through the
facade.

---

## Out of scope for v0.4 (so far)

The v0.4 expression / lazy surface above is **shipped** (see the `expr`,
the `frame` expression-consumer, and the `lazy` sections); these are the
deferrals, tracked for v0.5+:

- **Lazy CSV scan (`scan_csv`)** — a streaming `io` → `frame` lazy source,
  so a plan can read from a file lazily rather than only from an in-memory
  frame.
- **More expression families** — window functions, string methods, and
  datetime expressions (the repo has no datetime type yet). The v0.4
  operator / method set is frozen; these extend it.
- **Floor division (`//`)** — deferred along with its integer
  zero-division raise/abort decision (v0.4's `/` is always `Float`, which
  sidesteps it).
- **Optimizer extensions** — dead-expression elimination, narrowing /
  predicate-splitting through joins, and sinking filters below sorts (v0.4
  pushes predicates and projections only).
