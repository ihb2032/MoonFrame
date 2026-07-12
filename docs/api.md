# MoonFrame v0.5 — Public API

> Status: **v0.5 shipped** (the eager and lazy surfaces converged onto one
> Polars-shaped expression engine — the last breaking release). This
> document is the source of truth for the v0.5 public surface. Every
> user-facing symbol re-exported by the facade appears here. (A few symbols
> are `pub` only because they are shared across packages — MoonBit has no
> module-internal visibility — and are deliberately kept out of both the
> facade and this reference: they are internal kernels, not public API, and
> may change without notice.)

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
- **Bridge to a value** by re-wrapping in a `catch`:
  `let r : Result[DataFrame, DataError] = Ok(read_csv(path)) catch { e => Err(e) }`.
  Match on `r` to inspect the error.
- **Handle inline** with `try expr catch { e => ... }`.

Provably-total operations (`head` / `tail` / `Series::min` /
`Series::drop_nulls` / `to_markdown` / `to_html` / the inspection accessors
/ …) return their value directly and never raise.

The one deliberate exception is `DataFrame::check_invariants()`, which
keeps its `Result[Unit, String]` shape — it is a verification /
diagnostic affordance (its error is a `String` describing the first
violated invariant), not a data transform.

### Migration

Source-level changes between releases (v0.1 → … → v0.5) are collected
in [`migration.md`](migration.md).

---

## `types` — Value types and errors

- `suberror DataError` — `pub(all) suberror` with 10 variants:
  `ColumnNotFound` / `DuplicateColumn` / `TypeMismatch` / `LengthMismatch` /
  `IndexOutOfBounds` / `ParseError` / `InvalidOperation` / `IoError` /
  `Unsupported` / `NullInNonNullable`. As a `suberror` it is both raised
  (`raise ColumnNotFound("age")`) and recovered
  (`Ok(expr) catch { e => Err(e) }` → `Result[_, DataError]`); `pub(all)` lets
  callers construct and match
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
  by Unicode code point (`-1` / `0` / `1`), so supplementary-plane
  characters (emoji, …) sort by their true scalar value rather than by
  raw UTF-16 surrogate code unit. Every user-facing ordering
  (`Scalar::lt`, `Series::min` / `max`, `DataFrame::sort`)
  routes through this so they all agree.
- `fn is_decimal_int_literal(s) -> Bool` — `true` when `s` is an optional
  `+` / `-` sign followed by ASCII digits and nothing else (rejects
  `0x` / `0o` / `0b` prefixes and `1_000` underscore grouping). The
  CSV / JSON readers' type inference and the `@column` String→`Int` cast
  both route through this predicate so they agree on what counts as an
  integer literal.
- `fn format_scalar_literal(value) -> String` — display-syntax rendering
  of a literal `Scalar`, the one spelling shared by `Expr`'s `explain`
  renderer and `LazyFrame`'s plan printer so the two can never drift:
  `Int` / `Bool` bare, a `String` quoted and escaped, `Null` as `null`,
  and a `Float` kept distinct from an `Int` — a finite whole value keeps
  a `.0` suffix, negative zero keeps its sign, `NaN` / `Infinity` /
  `-Infinity` keep their own spelling.
- `struct Field` — column metadata: `name`, `dtype`, `nullable`. Total
  constructors `Field::new(name, dtype)` (defaults `nullable = true`)
  and `Field::with_nullable(name, dtype, nullable)`; accessors `name` /
  `dtype` / `nullable`; `rename(new_name)` returns a renamed copy.
  `nullable = false` is a constraint enforced by `DataFrame::from_rows`
  (a null in such a column raises `NullInNonNullable`); it is otherwise
  advisory — not inferred from a column's contents, and not propagated
  across operations (`Field::new` / `DataFrame::new` / the IO readers
  always set it `true`).
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

- `struct Bitmap { bits : Bytes, offset : Int, len : Int }` — byte-packed,
  1 bit per row, `1 = valid`. Slot `i` is physical bit `offset + i` (LSB
  first); `slice` is a zero-copy view that advances `offset`, so equality is
  logical over `[offset, offset + len)`. (Some ecosystem libraries use the
  opposite `true = null` convention.)
- Total constructors: `all_valid(len)` / `all_null(len)` (negative `len` →
  empty) / `from_bools(Array[Bool])` / `from_options[T](Array[T?])`
  (`Some(_) ↦ valid`).
- Total inspection: `len` / `null_count()` / `to_bools()` (the whole
  `true = valid` mask in one pass).
- Fallible (`raise DataError`): `is_valid(i)` / `is_null(i)`
  (`IndexOutOfBounds` outside `[0, len)`); `slice(start, length)`
  (`IndexOutOfBounds` / `InvalidOperation`); `take(indices)`
  (`IndexOutOfBounds`); `bit_and(other)` (`LengthMismatch`; `and` is
  reserved, hence `bit_and`).

### BuiltinColumn

- `struct BuiltinColumn { data : ColumnData, validity : Bitmap }` —
  Arrow-style column; null slots carry a per-dtype placeholder
  (`0` / `0.0` / `false` / `""`) that never leaks, as every read consults
  `validity` first. `derive(Eq)` compares the raw `data` array, so that
  placeholder is also what keeps two logically equal columns equal;
  `placeholders_normalized()` asserts it.
- `pub(all) enum ColumnData` — `Int(Array[Int64]) | Float(Array[Double]) |
  Bool(Array[Bool]) | String(Array[String])` (64-bit numerics).
- Total constructors (8): `from_ints` / `from_int_options` /
  `from_floats` / `from_float_options` / `from_bools` /
  `from_bool_options` / `from_strings` / `from_string_options`.
- Total inspection: `dtype` / `len` / `is_empty` / `null_count` /
  `data() -> ColumnData` / `validity() -> Bitmap` /
  `placeholders_normalized() -> Bool` (every null slot holds its dtype's
  canonical placeholder — always `true` for a column from the public API;
  a test-facing assertion of the invariant `derive(Eq)` depends on).
  - ⚠ **`data()` returns the live backing array zero-copy** (not a defensive
    copy — a hot-path read trade-off). Treat it as **read-only**; mutating it
    corrupts the column's data/validity invariants. Same for
    `ColumnStorage::data()`.
- Fallible (`raise DataError`):
  - `is_null(i) -> Bool` / `get(i) -> Scalar` —
    `IndexOutOfBounds` outside `[0, len)`; `get` returns `Scalar::Null` for
    null slots.
  - `slice(start, end)` / `take(indices)` — sub-views; bounds as the bitmap.
  - `cast(target)` — the single cross-dtype conversion. `Int`: identity on
    Int, Float truncates toward zero (`NaN` / `±Inf` / out-of-`Int64`-range
    → `ParseError`), Bool `true → 1` / `false → 0`, String accepts only
    plain base-10 integers (others → `ParseError`). `Float`: Int promoted,
    identity on Float, Bool → `1.0` / `0.0`, String parsed (`1_000`
    underscore grouping rejected; `inf` / `-inf` / `nan` accepted; a finite
    literal past the `Double` range collapses to `±Inf` per IEEE 754; other
    malformed → `ParseError`). `String`: every dtype renders (via the total
    `to_string_column`). Validity is preserved; `Bool` / `Null` targets
    `raise Unsupported`.
  - `int_values()` / `float_values()` / `bool_values()` /
    `string_values()` — return `(Array[T], Bitmap)`; wrong dtype →
    `raise TypeMismatch`. Always consult the returned bitmap before
    reading the data array.
- **Total**: `to_string_column() -> BuiltinColumn` — every dtype has a
  value-form rendering, so unlike a numeric `cast` it never raises.

### NumericColumn

- `struct NumericColumn { data : NumericData }` — the **all-valid** unboxed
  numeric column (the `null_count == 0` fast path): **no validity bitmap**,
  so construction, sub-views, and reductions skip the per-slot validity
  check. The moment a null would enter, it materialises back to a
  `BuiltinColumn`.
- `pub(all) enum NumericData` — `Int(Array[Int64]) | Float(Array[Double])`
  (`Bool` / `String` are always `Builtin`).
- Total constructors: `from_int64s` / `from_doubles`, with `from_ints` /
  `from_floats` as aliases matching the spelling every other layer uses
  (`BuiltinColumn` / `Series`).
- Total inspection: `dtype` / `len` / `is_empty` / `null_count` (always
  `0`) / `data() -> ColumnData` / `to_builtin() -> BuiltinColumn` (widen
  with an all-valid bitmap — lossless) / `to_string_column() -> BuiltinColumn`.
- Fallible (`raise DataError`): `is_null(i)` (bounds only; value always
  `false`) / `get(i)` / `slice(start, end)` / `take(indices)`;
  `int_values()` / `float_values()` (raw array + synthesised all-valid
  bitmap); `bool_values()` / `string_values()` always `raise TypeMismatch`.
- Reductions (no validity scan): **total** `sum() -> Scalar` /
  `min() -> Scalar` / `max() -> Scalar`; fallible `mean() -> Double`
  (`InvalidOperation` on an empty column). `NaN` propagates through
  `sum` / `mean` but is skipped by `min` / `max`.

### ColumnStorage / StorageKind

- `pub(all) enum ColumnStorage { Builtin(BuiltinColumn);
  Numeric(NumericColumn) }` — the pluggable backend seam a `Series` holds.
  Every accessor forwards to both arms, so `.data()` / `.validity()` reads
  are backend-transparent (the `Numeric` arm synthesises an all-valid
  `validity()` on demand).
- `pub(all) enum StorageKind { Builtin; Numeric }` — the backend
  discriminant (`kind()`); `Builtin` *is* the Arrow layout (data + validity
  bitmap, `1 = valid`).
- Constructors: `from_builtin(BuiltinColumn)` / `from_numeric(NumericColumn)`.
- Total inspection: `kind()` / `dtype` / `len` / `is_empty` / `null_count`
  / `data() -> ColumnData` / `validity() -> Bitmap` / `to_builtin() ->
  BuiltinColumn` / `to_string_column() -> BuiltinColumn`.
- Total `slice_total(start, end) -> ColumnStorage` — the no-raise
  counterpart of `slice` (backs `head` / `tail` / `DataFrame::slice`): keeps
  the backend and shares the validity bitmap as a zero-copy view (copying the
  row data), but clamps out-of-range bounds into `[0, len]` (with `end` lifted
  to at least `start`) rather than raising.
- Fallible (`raise DataError`): `is_null(i)` / `get(i)`; backend-preserving
  `slice(start, end)` / `take(indices)` (a `Numeric` sub-range stays
  `Numeric`); `int_values()` / `float_values()` / `bool_values()` /
  `string_values()`. The cross-dtype `cast(target)` routes through
  `to_builtin()`, so the result is `Builtin`-backed (re-converge with
  `to_numeric` for a numeric target).
- `to_numeric() -> ColumnStorage raise DataError` — move an all-valid Int /
  Float `Builtin` column onto the `Numeric` fast path: `InvalidOperation`
  if it carries nulls, `TypeMismatch` if non-numeric, identity if already
  `Numeric`.

---

## `expr` — Expression engine

A reified, composable column expression — a small recursive tree you build
with constructors, operators, and methods, then evaluate eagerly
(`with_columns` / `select` / `filter` / `agg`, in `frame`), introspect
(`explain`), or defer and optimize (`lazy`). Building a tree is **total** —
every failure (a missing column, a type clash) waits for evaluation. `expr`
depends only on `types`.

- `enum Expr` — the expression tree, **read-only** outside the package
  (inspect by pattern matching; construct through `col` / `lit_*` /
  operators / methods, not by spelling variants). The payload tag enums
  `BinOp` / `UnOp` / `AggOp` / `StrOp` are read-only implementation tags — no
  public API names one, so the facade does not re-export them.

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
  literal column. At evaluation: a length-1 series broadcasts, a frame-tall
  one maps row for row, any other length is `LengthMismatch`. Named after the
  series unless `with_alias` overrides, so `with_columns([lit_series(s)])`
  adds — or in-place replaces — a column named `s.name()`.

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
  `is_not_null() -> Expr` (total — the result is never null); NaN probes
  `is_nan()` / `is_not_nan() -> Expr` — `true`/`false` where a numeric cell is
  / isn't the IEEE `NaN` value. The NaN probes require a numeric operand
  (`TypeMismatch` otherwise; an `Int` cell is never `NaN`) and, unlike the null
  probes, *propagate* nulls (a missing cell → a null result).
- `fill_null(value : Expr) -> Expr` — replace null cells with `value` (a
  literal, another column — a coalesce — or a computed tree), a dedicated
  node evaluating exactly like
  `when(self.is_not_null()).then(self).otherwise(value)`: non-null cells are
  kept, the result is named after the filled expression (not `value`), and
  the branch dtypes unify like a ternary's (`Int` ↔ `Float` promote, any
  other mismatch is a `TypeMismatch`). A non-null `NaN` is a value, so it is
  kept, not filled. Unlike that ternary spelling, the node holds (and
  evaluates) the filled expression once, so a chained coalesce
  (`e.fill_null(a).fill_null(b)…`) stays linear in tree size and work.
- `fill_nan(value : Expr) -> Expr` — the dual of `fill_null`: replace `NaN`
  cells with `value`, evaluating exactly like
  `when(self.is_not_nan()).then(self).otherwise(value)`. A true null (for which
  `is_not_nan` is null) falls through the Kleene ternary to a null, so nulls
  are preserved, not filled; same self-naming, dtype-unification, and
  linear-chaining rules.
- Aggregations `sum` / `mean` / `min` / `max` / `count` / `std` /
  `variance` / `median` / `n_unique` / `first` / `last() -> Expr` — wrap
  the expression in a reduction (evaluation semantics below). `std` /
  `variance` are the sample statistics (`ddof = 1`, always `Float`, null
  below two non-null cells); `median` is always `Float` (`Int` widens);
  `n_unique` is the distinct non-null count (`Int`); `first` / `last` are
  positional, keeping the source dtype. `variance` is spelled out because
  `var` is a reserved word.
- `cast(target : DataType) -> Expr`; `with_alias(name : String) -> Expr`
  (names the output column; `alias` is a reserved word).

### String namespace

String operations on a String column, each a `str_*` method building a `Str`
node. Every operation maps cell by cell: null cells stay null, a non-String
operand is a `TypeMismatch` at evaluation, all are total. Matching is always
**literal** — there is no regex engine yet, so regex forms of `contains` /
`replace` are a future addition.

- `str_to_uppercase()` / `str_to_lowercase() -> Expr` — case mapping,
  currently **ASCII-only** (a non-ASCII letter passes through unchanged,
  like `str_strip_chars`' ASCII whitespace set).
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
  row-wise conditional lowering to a ternary node with the three-way Kleene
  rule: the value is the `then` branch where `cond` is `true`, the
  `otherwise` branch where it is `false`, and a **null** condition cell
  yields a **null** output (the branch is unknown — `otherwise` is the
  false-arm, not a default for missing conditions; `fill_nan`'s
  null-preservation depends on exactly this). To have `otherwise` catch
  missing conditions, make them false first:
  `when(cond.fill_null(lit_bool(false)))`. `WhenThen` / `WhenThenElse` are
  opaque builder steps (only `when` starts the chain).

### Closure escape hatch

Two constructors reach past the documented algebra to an arbitrary host
closure applied row by row. The closure is opaque to introspection, equality,
and the optimizer: a map node is identified by its `label` and inputs.

- `Expr::map_elements(self, label~ : String, f : (Scalar) -> Scalar raise)
  -> Expr` — single input: `f` receives each cell of `self` as a `Scalar`
  (a null cell as `Scalar::Null`) and returns the output cell.
- `map_many(label~ : String, inputs : Array[Expr], f : (Array[Scalar]) ->
  Scalar raise) -> Expr` — several inputs: `f` receives one cell per input,
  in order; `inputs` may mix columns, literals, and aggregations (length-1
  results broadcast over the row count). A row predicate is `map_many(...)`
  returning `Scalar::Bool`.

The closure runs once per row and may `raise` (propagating from the consuming
verb). The output dtype is the first non-null `Scalar` returned (mixed
`Int`/`Float` promotes to `Float`); an all-null result borrows the leftmost
**column** input's dtype and yields an all-null column of it — only a
column-less map with no non-null result cell raises `Unsupported` (no
Null-dtype backend, as for a `Null` literal). A map's height follows its
inputs: a **column** input makes it frame-tall, so over an empty frame the
closure never runs and it returns an empty column mirroring the leftmost
input's dtype; an **all-literal** map (no column read) is length-1 like a
bare `lit`, so the closure runs once and broadcasts even over an empty
frame. The result is named after the leftmost input; `label` shows only in
`explain`. The optimizer treats a map as a value barrier (like `cast`): no
filter sinks across it.

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
  including a ternary's condition.
- `output_name(self) -> String` — the output column name under Polars'
  rule: an alias wins, else the leftmost column reference, else
  `"literal"` for a column-less tree (a ternary draws its name from the
  value branches, never the condition). The eager materialisers in `frame`
  and the lazy optimizer share this one rule.
- `children(self) -> Array[Expr]` — the immediate sub-expressions of a
  node, left to right (a ternary lists its condition first); leaves return
  none.

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
  column. Mixed `Int`-vs-`Float` compares after promoting the `Int` to
  `Double`, which is lossy beyond 2^53 — two distinct large values can
  compare equal near that boundary (Polars compares int/float exactly);
  same-dtype `Int` comparisons are always exact.
- **String namespace** (`str_to_uppercase` / `str_contains` / …) maps each
  cell of a String operand through a literal `StrOp` — case (ASCII-only),
  `strip_chars` (ASCII whitespace), `len_chars` (an `Int`), the `contains` /
  `starts_with` / `ends_with` predicates (`Bool`), and `replace` /
  `replace_all`. Null cells stay null, a non-String operand is a
  `TypeMismatch`, and all are total.
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
  dtype is the first non-null result's; an all-null (or empty) result
  borrows the leftmost column input's dtype, and only a column-less map
  with no non-null result cell raises `Unsupported`.
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

> **Plumbing note.** The kernel functions above (`gather_series` /
> `slice_series` / `rebuild_options` / `preserve_backend` /
> `try_column_to_numeric` / `validity_bools` / `reducer_for` /
> `scalars_to_series` / `key_cell`, plus `ReduceOp` / `KeyCell`) are `pub`
> because `frame` consumes them across the package boundary — MoonBit has
> no package-private visibility. They are engine seams rather than the
> curated user surface, and none are re-exported by the facade; prefer the
> `Series` methods and `DataFrame` verbs built on top of them.

### Series

- `struct Series { name, storage : @column.ColumnStorage }` — the `storage`
  field holds the pluggable backend (`Builtin` or `Numeric`); `from_builtin`
  and `storage().to_builtin()` bridge pre-v0.3 call sites.
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
  `is_canonical() -> Bool` (whether the column is on the canonical backend
  for its content — the fixed point of `to_numeric`'s convergence; `false`
  only for a `Builtin` all-valid `Int` / `Float` column, which can still
  move onto the `Numeric` fast path) /
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
  the `Builtin` backend — lossless inverse of `to_numeric`). The backend of
  a transform's result is a function of its **content**, not its source: a
  row-gathering transform (`gather` / `drop_nulls`, and `filter` / `sort` /
  `join` at the frame level) whose numeric result is all-valid **converges
  onto `Numeric`** regardless of where it started, while a column carrying
  (or gaining) a null — or any `Bool` / `String` — lands on `Builtin`. Only
  the slice family (`slice`, frame-level `head` / `tail`) and `fill_null`
  preserve the source backend as-is; cross-dtype casts borrow the `Builtin`
  road. (Content-determined backends are the invariant the lazy optimizer's
  predicate pushdown relies on; `is_canonical()` reports whether a column
  sits on that backend, so a test can assert it directly.)

### Series stats (`series_stats.mbt`)

- Total: `count()` (non-null count); `n_unique()` (distinct non-null values
  via the same composite `key_cell` normalisation `group_by` / `join` use —
  every `Float` `NaN` is one bucket, `-0.0` folds into `+0.0`); `min()` /
  `max()` — return a `Scalar` directly (never fail; empty / all-null /
  all-NaN → `Scalar::Null`; `String` lexicographic; `Bool` is
  `false < true`).
- Fallible (`raise DataError`): `sum()` — `Int` / `Float` →
  `Scalar::Int` / `Scalar::Float`, empty / all-null is the additive
  identity; an `Int` sum accumulates in `Int64` and **wraps on overflow**
  (silently — no raise); `Bool` / `String` → `TypeMismatch`; `mean()` — `Double`,
  empty / all-null numeric → `InvalidOperation`, non-numeric →
  `TypeMismatch`. `mean_opt() -> Double?` is the **total** form of `mean`
  (`Some(mean)`, or `None` exactly where `mean` would raise). `Float` `NaN`
  is a value, not missing: it **propagates** through `sum` / `mean` but is
  **skipped** by `min` / `max` (and `sort`) — only `Null` is ever treated
  as missing.

---

## `frame` — DataFrame and operators

The `ops` verbs are folded in here as `DataFrame` methods (one operator
per file), so a pipeline is a method chain. `frame` reads `@series.Series`
(the column unit it wraps) and `@expr.Expr` (to evaluate the expression
consumers below) on top of `types` / `column`; it has **zero external
dependencies** (NyaCSV / fs / @json live only in `io`).

### DataFrame

- `struct DataFrame` — column-oriented table; its fields (`schema`,
  `columns`, `nrows`, and a `name_to_index` cache for `O(1)` name lookup) are
  `priv`, so a validated frame can only be built through the constructors and
  read through the copy-returning accessors below.
- Constructors (`raise DataError`): `new(columns)`
  (`LengthMismatch` / `DuplicateColumn`; zero columns → `0×0`);
  `empty(schema)` (0-row frame; `DuplicateColumn` for a repeated field name;
  `Unsupported` for a `Null`-dtype field);
  `from_rows(schema, rows)` (`DuplicateColumn` / `LengthMismatch` /
  `TypeMismatch` / `Unsupported` / `NullInNonNullable`; zero-column schema →
  `0×0`, like `new`).
  `empty` / `from_rows` re-validate the schema through `Schema::new` as
  defence-in-depth (every `Schema` constructor already rejects duplicates).
- Total inspection: `shape()` / `schema()` / `columns()` (fresh array) /
  `column_series()` (fresh array of the immutable `Series`) / `nrows()` /
  `ncols()` / `is_empty()`.
- `to_scalar_matrix() -> Array[Array[Scalar]]` (**total**) — every column's
  cells column-major (`result[c][r]` is column `c` / row `r`, `Null` for a
  null slot). The one-pass bulk read the row-oriented serialisers /
  renderers share.
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
- Structural transforms: total `head(n)` / `limit(n)` (a Polars-style
  alias of `head`, the eager twin of `LazyFrame::limit`) / `tail(n)`
  (clamp `n` to `[0, nrows]`); `slice(start, end)` / `take(indices)`
  (`raise`, `IndexOutOfBounds` / `InvalidOperation`).
- Storage backend control (all **total**): `storage_kinds() ->
  Array[StorageKind]` (per-column backend, parallel to `columns()`);
  `to_numeric()` (best-effort — move every all-valid Int / Float column
  onto the `Numeric` fast path, keep nullable / non-numeric / already-
  `Numeric` columns); `to_builtin()` (materialise every column onto
  `Builtin`, the inverse). Names / dtypes / values are unchanged.
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
  unknown.
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
  `mean` / `min` / `max`; a 0-column frame collapses to `0×0`. For one
  column's scalar, read its `Series`: `df.get_column(c).sum()`
  (= Polars `df[c].sum()`).
- `describe() -> DataFrame raise DataError` — per-column summary, one row
  per source column, fixed `N × 8` schema (`column` / `dtype` / `count` /
  `null_count` / `n_unique` (`Int`); `mean` (`Float`, nullable);
  `min` / `max` (`String`, nullable, rendered via `Scalar::to_string`, so a
  single column carries extrema across differing dtypes)). 0-column collapses
  to `0 × 8`.
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
  as `<td></td>`; `&` / `<` / `>` / `"` / `'` are escaped to HTML entities.
  0 columns → empty string; N columns / 0 rows → header + empty `<tbody>`.
  `to_html_with_options` adds a `class` / `<caption>` and, via `max_rows`,
  a row cap with a `<tfoot>` `... (K more rows)` banner (negative
  `max_rows` clamps to 0).
- `struct HtmlOptions` (fields read-only) — built via `HtmlOptions::default()`
  (all rows, no `class` / `caption`, `escape = true`) and chained
  `with_max_rows(n)` / `with_table_class(cls)` / `with_caption(text)` /
  `with_escape(flag)`. `with_escape(false)` emits caption / header / cell
  / class strings verbatim, for trusted input that intentionally carries
  HTML.

### Expression consumers (`with_columns` / `select` / `filter`)

The eager face of the `expr` engine — `DataFrame` methods that evaluate
`@expr.Expr` trees over the whole frame. All route through `DataFrame::new`,
so every output satisfies `check_invariants()`; all raise the evaluator's
`DataError` (`ColumnNotFound` / `TypeMismatch` / `LengthMismatch`), plus
`DuplicateColumn` on an output-name clash.

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
  `Filter` node defers. A row-wise host predicate is reachable through the
  `map_many` escape hatch.
- `unique() -> DataFrame` — **total**. Drop duplicate rows, keeping the first
  occurrence of each in first-appearance order (Polars'
  `unique(maintain_order=True)`). Row identity is the composite cell tuple
  `group_by` / `join` key on, so a `Float` `NaN` equals `NaN`, `-0.0` folds
  into `+0.0`, and a **null** cell is an ordinary value (rows that are null in
  the same places and equal elsewhere are duplicates). The schema and column
  order are unchanged; an all-distinct or 0-row frame is returned as-is.
  (Polars' `subset` / `keep` parameters — dedup on a column subset, keep the
  last, or drop all duplicates — are deferred.)

A computed numeric result lands on the `Numeric` backend when all-valid,
`Builtin` otherwise; a `col(...)` reference is canonicalised the same way —
to the backend its **content** implies, not the source's: an all-valid
numeric column converges onto `Numeric` even when its source sat on
`Builtin` (the content-determined invariant the lazy optimizer's predicate
pushdown relies on).

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
  all NaNs into one group (`-0.0` and `+0.0` likewise share a group), and a
  **null** key forms its **own** group rather than being dropped (unlike
  `join`, where `null` matches nothing). One key or several; an empty `keys`
  list makes a single grand-total group; a 0-row frame yields zero groups.
  `ColumnNotFound` / `TypeMismatch` on the first offending key;
  `DuplicateColumn` if two keys produce the same output name.
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
    column of both frames (a clashing right column is suffixed).
  - **Backend**: like the other row-gathering transforms (`filter` / `sort`
    / `take` / `drop_nulls`), each output column lands on the backend its
    **content** implies — an all-valid numeric result converges onto
    `Numeric` (even from a `Builtin` source), while a column that gains a
    null from an unmatched row (or is `Bool` / `String`) is `Builtin`. Only
    the representation is affected; values and dtypes are unchanged.
  - Routes through `DataFrame::new`, so every output satisfies
    `check_invariants()`. Raises: `ColumnNotFound` (a key expression
    references an absent column; first offending key in key order, the left
    key evaluated before the right), `TypeMismatch` (a key's left and right
    dtypes differ, or a derived key's own dtypes don't unify),
    `InvalidOperation` (no keys for a non-`Cross` join — use `Cross` for a
    product — any keys on a `Cross` join, both `on` and `left_on` /
    `right_on` given, or `left_on` / `right_on` of unequal length),
    `DuplicateColumn` (a bare `col(name)` key repeated — rejected at the
    repeat, like `group_by([col("id"), col("id")])`; derived keys are not
    name-checked, since two distinct derived keys sharing a leftmost name are
    different keys and contribute no output column; or two output columns
    still colliding after suffixing — surfaced by `DataFrame::new`),
    `LengthMismatch` (a `lit_series` key whose embedded series is neither
    length 1 nor the frame's height).
- `enum JoinType` — `Inner` / `Left` / `Right` / `Outer` / `Cross`.
- `struct JoinOptions` (fields read-only) — built via
  `JoinOptions::on(keys : Array[Expr])` (same keys on both frames),
  `JoinOptions::left_on(keys).with_right_on(keys)` (differently-named or
  -derived keys, paired position by position), or `JoinOptions::cross()`
  (keyless `Cross`) — each defaulting to `Inner`, suffix `"_right"`,
  `coalesce` auto — with `with_how(JoinType)` / `with_suffix(name)` /
  `with_coalesce(Bool)` to override, and `with_left_on(keys)` /
  `with_right_on(keys)` to (re)supply either side's keys anywhere in the
  chain. `coalesce` defaults to `None` (auto:
  coalesce on an inner / left / right join, keep both keys on an `Outer`
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
(`format_json_records` / `format_ndjson`) are **total** and return a
`String`. Two `raise`: `format_vega_lite` — a `ChartSpec` names the columns
to plot, and a missing name is `ColumnNotFound` — and `format_csv`, which
rejects a delimiter that collides with the quote character or a line
terminator, or that is a non-BMP character. Tokenisation delegates to
`moonbit-community/NyaCSV`;
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
  mapping → `DataFrame::new`. `InvalidOperation` if `options.delimiter` is a
  double quote, a line terminator, or a non-BMP (supplementary-plane)
  character (the same configurations `format_csv` rejects, so a value the
  writer can't emit unambiguously can't be read back either);
  `DuplicateColumn` / `ParseError` (the latter also covers a ragged
  row when `options.strict_column_count`, and a cell that doesn't fit its
  dtype unless `options.on_parse_error = Null`).
- `format_csv(df, options) -> String raise DataError` — cells render via
  `Scalar::to_string`; null → `options.null_value`; RFC 4180 quoting;
  LF-terminated. Raises `InvalidOperation` if `options.delimiter` is a double
  quote or a line terminator (`\n` / `\r`), which can't unambiguously frame
  fields, or a non-BMP character, whose UTF-16 surrogate pair the
  per-code-unit tokenizer can't match.
- `read_csv(path)` / `read_csv_with_options(path, options) -> DataFrame
  raise DataError` — file wrappers (`IoError`).
- `read_csv_projected(path, options, projection : Array[String]) ->
  DataFrame raise DataError` — `read_csv_with_options` that builds only the
  named `projection` columns (in the file's header order; the rest are never
  inferred or parsed). The engine seam behind `lazy`'s `scan_csv` projection
  pushdown — **not** re-exported by the facade. Whole-input checks (a
  malformed header, a ragged row) are unaffected, but a parse error confined
  to a dropped column does not surface (see `lazy`).
- `write_csv(path, df)` / `write_csv_with_options(path, df, options) ->
  Unit raise DataError` — file wrappers (`IoError`; a string cell or column
  name holding an unpaired UTF-16 surrogate is refused with
  `InvalidOperation` before encoding, as for every `write_*`).

### JSON (records shape `[{...}, ...]`)

- `struct JsonReadOptions` — `infer_schema_rows` (`100`; `0` or `<= 0`
  scans every record) / `on_parse_error` (`Raise`; the shared
  `OnParseError`, documented under CSV). `JsonReadOptions::default()`.
- `parse_json_records_str(content, options) -> DataFrame raise DataError`
  — `@json.parse` → object validation → headers in first-seen order
  across all records (sparse records → null cells) → inference (same
  order as CSV; `Number` locks `Int` when integral and in `Int64` range,
  else `Float`; `true` / `false` only for `Bool`; mixed → `String`
  fallback) → `DataFrame::new`. `ParseError`. A `Double`-overflowing
  integer that infers as `Float` (a fractional sibling in the column)
  recovers its nearest finite value from the digits `@json` preserves in
  `repr`, rather than reading back as `Infinity`.
- `format_json_records(df) -> String` — **total**. One object per row,
  keys in `df.columns()` order; `Null → null`, bools / strings / finite
  numbers via `@json`. A non-finite `Float` (`NaN` / `±Infinity`) has no
  JSON literal, so it is emitted as `null` (like pandas' `to_json`),
  keeping the output valid JSON; a round-trip reads it back as a null.
  Consequently a `Float` column that is *entirely* non-finite and/or null
  writes as all-`null` and re-infers as `String` on read (an all-null column
  has no dtype signal) — a `Float → String` narrowing; a column with any
  finite value keeps `Float`. `Int` cells render as JSON numbers; a magnitude
  beyond 2^53 keeps its `Int` dtype but loses precision on a JSON round-trip
  (the `@json` number model is `Double`), as in pandas' `to_json`.
- `read_json(path)` / `read_json_with_options(path, options) -> DataFrame
  raise DataError`; `write_json_records(path, df) -> Unit raise
  DataError` — file wrappers (`IoError`; an unpaired UTF-16 surrogate in
  the content is refused with `InvalidOperation` before encoding).

### NDJSON (JSON Lines, one object per line `{...}\n{...}\n…`)

The streaming-friendly sibling of the JSON-records shape. Everything after
the line framing is shared with the records reader / writer — header
collection (first-seen order, sparse lines → null cells), the
`Int → Float → Bool → String` inference, and the `scalar_to_json` cell
conventions.

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
  DataError` — file wrappers (`IoError`; an unpaired UTF-16 surrogate in
  the content is refused with `InvalidOperation` before encoding).
- `read_ndjson_projected(path, options, projection : Array[String]) ->
  DataFrame raise DataError` — the NDJSON twin of `read_csv_projected`:
  builds only the named columns, the engine seam behind `lazy`'s
  `scan_ndjson` projection pushdown (not re-exported by the facade; a parse
  error confined to a dropped column does not surface — see `lazy`).

### Chart export (Vega-Lite v5)

`format_vega_lite` emits a complete, standalone [Vega-Lite v5](https://vega.github.io/vega-lite/)
specification as a JSON string — `$schema` + optional `title` + `mark` +
`encoding` + an inline `data.values` array — that drops straight into the
[Vega editor](https://vega.github.io/editor/) or any Vega-Lite runtime.
It shares `format_json_records`' `scalar_to_json` cell mapping, so a
`data.values` cell follows the same rules (null and non-finite-float cells
→ JSON `null`).

- `enum ChartKind { Bar; Line; Point; Area }` (`pub(all)`) — the mark
  type, mapped to the Vega-Lite `mark` (`"bar"` / `"line"` / `"point"` /
  `"area"`).
- `struct ChartSpec` (fields read-only) — built via a mark-named
  constructor `ChartSpec::bar(x, y)` / `line(x, y)` / `point(x, y)` /
  `area(x, y)` (`x` / `y` are column names) and chained
  `with_color(column)` (a grouping / colour column) / `with_title(text)` /
  `with_color_type(VegaType)`.
- `enum VegaType` (`Quantitative` / `Nominal` / `Ordinal` / `Temporal`,
  `pub(all)`) — overrides the `color` channel's Vega-Lite field `type` instead
  of inferring it from the column dtype. Use `Nominal` / `Ordinal` to render a
  *numeric* grouping column (a cluster id, a year) as distinct per-group
  colors rather than the continuous gradient `quantitative` would produce; the
  `x` / `y` channels keep dtype inference.
- `format_vega_lite(df, spec) -> String raise DataError` — **not total**.
  Resolves the spec's `x` / `y` / `color` columns against `df`
  left-to-right; the first name absent from the frame raises
  `ColumnNotFound(name)`. Each channel's Vega-Lite field `type` is
  inferred from the column dtype: numeric (`Int` / `Float`) →
  `"quantitative"`, otherwise (`String` / `Bool`, and an all-null `Null`
  column) → `"nominal"` — unless `spec.with_color_type(...)` overrides the
  `color` channel. A column name containing `.`, `[`, or `]` is
  escaped in the encoding `field` (Vega-Lite reads those as nested-object /
  array access), so a column literally named `price.usd` resolves correctly
  instead of plotting nothing. The frame is inlined as `data.values` (a frame
  with the encoded columns but zero rows yields `"values":[]`). The output
  is always valid JSON.
- `write_vega_lite(path, df, spec) -> Unit raise DataError` — file wrapper
  (propagates `ColumnNotFound`; filesystem failure → `IoError`).

---

## `lazy` — Lazy query layer

A deferred query plan over an in-memory frame. `lazy_frame(df)` (or
`LazyFrame::from(df)`) starts a plan; builder methods mirroring the eager
verbs grow it without computing anything; `collect()` optimizes and runs it.
Building is **total** — every failure waits for `collect`. `lazy` depends on
`frame` + `expr`; `frame` does **not** depend on `lazy`, so there is no
cycle.

- `struct LazyFrame` (fields private) — wraps a private `LogicalPlan` (one
  node per eager verb; the IR never leaks into the public surface).
- `struct LazyGroupBy` (fields private) — the deferred `group_by` step
  (keys attached, nothing partitioned), produced by `LazyFrame::group_by`
  and completed by `agg`.

### Entry points

- `LazyFrame::from(df : DataFrame) -> LazyFrame` — the static constructor
  (a `Scan` leaf over the captured frame); **not** a `DataFrame::lazy`
  method (that would force a `frame ↔ lazy` import cycle).
- `lazy_frame(df : DataFrame) -> LazyFrame` — a free-function alias for
  `from`, for the `read_csv(path)` hand-feel. (`lazy(df)` would be the
  obvious name, but `lazy` is a MoonBit reserved word.)
- `scan_csv(path : String) -> LazyFrame` /
  `scan_csv_with_options(path : String, options : CsvReadOptions) ->
  LazyFrame` — a **lazy CSV source**: the plan's leaf is a deferred read of
  `path` (a `ScanCsv` node), the streaming-friendly counterpart of eager
  `read_csv`. Nothing is read until `collect`, and projection pushdown
  (below) narrows the parse to the columns the pipeline consumes — so
  `scan_csv("sales.csv").select([col("region"), col("revenue")]).collect()`
  never builds the columns it drops. `scan_csv(p).….collect()` equals
  `read_csv(p).…` on well-formed input; because a dropped column is never
  parsed, a parse error confined to one does not surface.
- `scan_ndjson(path : String) -> LazyFrame` /
  `scan_ndjson_with_options(path : String, options : NdjsonReadOptions) ->
  LazyFrame` — the line-oriented sibling of `scan_csv` (a `ScanNdjson` node),
  the lazy counterpart of eager `read_ndjson`. Same projection-pushdown
  behaviour and dropped-column caveat. (There is no `scan_json` for the
  single-array shape `[{...}]`: it must be parsed whole, so nothing can be
  pruned at read time.)

### Builders (all total — a plan is just data)

Each returns a new `LazyFrame` wrapping one more node:

- `filter(predicate : Expr)` · `with_columns(exprs : Array[Expr])` ·
  `select(exprs : Array[Expr])` — defer the eager expression consumers.
- `sort(by : Array[(Expr, SortOrder, NullOrder)])` · `head(n)` ·
  `tail(n)` · `limit(n)` (≡ `head`) · `slice(start, end)`.
- `drop(exprs : Array[Expr])` · `rename(pairs : Array[(String, String)])` ·
  `unique()` · `drop_nulls(subset? : Array[Expr])` ·
  `fill_null(value : Scalar)` — defer the column / row transforms. The
  optimizer treats each as a barrier (filters do not sink past them and scans
  below keep their full output), so they are correct but not yet pushed
  through; a deeper `select` / `aggregate` still narrows its own scan.
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
  `DataError`, surfacing here rather than at build time. A subplan shared
  by reference (e.g. `lf.join(lf, …)` — nested self-joins build a DAG, not
  a tree) executes **once** per `collect`, including a file source's read;
  such DAG-shaped plans skip the rewrite passes and run as built.
- `explain(self, optimized? : Bool = false) -> String` — render the plan
  as an indented tree: root verb first, inputs two spaces deeper,
  expressions in their `Expr::explain` form, compact `SCAN [rows×cols]`
  leaves (never the data), `AGGREGATE [exprs] BY [keys]` for a group-by
  (both `exprs` and `keys` rendered as expression lists).
  The default renders the plan **as built** (the package's contract — a
  faithful mirror of the chain); `optimized=true` renders the rewritten
  plan `collect` actually runs, so printing both is the before/after view.
  Total either way (the rewrite is a pure tree walk, and a plan that would
  fail to `collect` still explains). A subplan shared by reference renders
  once; a re-encounter prints the node's label plus
  `(shared, rendered above)` instead of re-expanding, so a DAG-shaped plan
  explains in linear space.

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
  (via `Expr::referenced_columns` / `Expr::output_name`) and narrows each
  scan to the columns its consumers read, dropping dead columns before any
  row-level work — inserting a narrowing selection of bare column references
  over an in-memory scan, or writing the column set into a file source's
  (`scan_csv` / `scan_ndjson`) own projection so the reader parses only those
  columns (rendered `SCAN_CSV "path" [cols]` / `SCAN_NDJSON "path" [cols]`).
  `Select` / `Aggregate` originate requirements;
  `Filter` / `Sort` widen the requirement by what they read; row windows
  pass it through; a `with_columns` subtracts the names it defines and adds
  the names it reads; `Join` is a barrier (each side restarts its own
  pass).

The rewrites never change results: `collect` stays bitwise-equal to the
eager chain, and a failing plan still fails (a single broken stage reports
the same eager error; a plan with several independently broken stages may
report a different one of its own errors once a filter sinks past a broken
stage — which error surfaced was an artifact of stage order to begin
with). The sole deliberate exception is a file source's projection
(`scan_csv` / `scan_ndjson`): a column no consumer reads is never parsed, so
a parse error confined to it goes unraised — the defining property of
projection pushdown into a source. Deferred (out of scope): dead-expression
elimination, narrowing / predicate-splitting through joins, sinking filters
below sorts, and pushing predicates into a file parser (or streaming it).

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
/ `AggOp` / `StrOp` tag enums are deliberately **not** re-exported (no public
API names them).

- From `@types`: `DataError` · `DataType` · `Scalar` · `Field` · `Schema` ·
  `compare_string_lex` · `is_decimal_int_literal` · `format_scalar_literal`
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
  `VegaType` · `format_csv` ·
  `format_json_records` · `format_ndjson` · `format_vega_lite` ·
  `parse_csv_str` · `parse_json_records_str` · `parse_ndjson_str` ·
  `read_csv` · `read_csv_with_options` · `read_json` ·
  `read_json_with_options` · `read_ndjson` · `read_ndjson_with_options` ·
  `write_csv` · `write_csv_with_options` · `write_json_records` ·
  `write_ndjson` · `write_vega_lite`
- From `@lazy`: `LazyFrame` · `LazyGroupBy` · `lazy_frame` · `scan_csv` ·
  `scan_csv_with_options` · `scan_ndjson` · `scan_ndjson_with_options`

`using @pkg { type T }` also creates constructor aliases, so
`@moonframe.Scalar::Int(42)`, `@moonframe.SortOrder::Desc`,
`@moonframe.DataError::ColumnNotFound("y")` all resolve through the
facade.

---

## Out of scope for v0.5 (so far)

The whole v0.5 surface above is **shipped**, and it is the last breaking
release: from v0.6 on the API only grows (additive — no renames, removals,
or signature changes). These are the tracked deferrals, all v0.6+:

- **More expression families** — arithmetic / numeric operators
  (`floor_div`, `pow`, `mod`, `abs`, `round`, `floor`, `ceil`, `sign`,
  `is_in`, `is_between`), regex-backed and more positional string methods
  (`str_slice`, byte length, `split` / `pad`), and — further out — window
  and datetime expressions (the repo has no datetime type yet). The v0.5
  operator / method set is frozen; these extend it.
- **Lazy scan depth** — predicate pushdown into the file parser and
  streaming execution (v0.5's scan does projection pushdown only), plus
  columnar sources (Parquet / IPC) once eager readers exist.
- **`unique` options** — a `subset` of key columns and a `keep` strategy
  (v0.5's `unique()` dedups whole rows, keeping first-appearance order).
- **Optimizer extensions** — dead-expression elimination, narrowing /
  predicate-splitting through joins, and sinking filters below sorts (v0.5
  pushes predicates and projections only).
