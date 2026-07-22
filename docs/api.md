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
surface. Sub-package imports (`@types`, `@series`, `@expr`, `@frame`,
`@io`, `@lazy`) remain supported for callers that only need a
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

- `enum CellParseLocation { Row; Record; Line }` — identifies whether a
  structured cell parse position is a CSV row, JSON-array record, or physical
  NDJSON line; positions are 1-based.
- `enum ParseErrorDetail { Message(String); Cell(CellParseLocation, String,
  Int, DataType, String) }` — the direct payload of `DataError::ParseError`.
  `Message` carries syntax or shape diagnostics; `Cell` exposes a typed-cell
  failure's location, column, 1-based position, expected dtype, and value.
- `enum TypeMismatchDetail { Message(String); Expected(DataType, DataType,
  String); Column(DataType, DataType); Operation(String, DataType, DataType) }`
  — the direct payload of `DataError::TypeMismatch`.
- `suberror DataError` — `pub(all) suberror` with 10 variants:
  `ColumnNotFound` / `DuplicateColumn` /
  `TypeMismatch(TypeMismatchDetail)` / `LengthMismatch` /
  `IndexOutOfBounds` / `ParseError(ParseErrorDetail)` /
  `InvalidOperation` / `IoError` /
  `Unsupported` / `NullInNonNullable`. As a `suberror` it is both raised
  (`raise ColumnNotFound("age")`) and recovered
  (`Ok(expr) catch { e => Err(e) }` → `Result[_, DataError]`); `pub(all)` lets
  callers construct and match
  variants. `DataError::message()` renders a human-readable description;
  the `Show` impl renders the variant form for assertion snapshots.
  `TypeMismatch(Expected(expected, got, column))` carries a value mismatch
  (`column` is `""` when not column-bound). Raw column-buffer accessors use
  `TypeMismatch(Column(expected, got))`; binary arithmetic, ordering, and
  incomparable non-null comparisons use
  `TypeMismatch(Operation(operation, left, right))`. Their `message()` output
  preserves the historical wording. Diagnostics outside those shared shapes
  use `TypeMismatch(Message(detail))`. CSV, JSON records, and NDJSON
  readers raise `ParseError(Cell(location, column, position, expected, value))`
  for a value that does not fit its inferred dtype; other syntax and shape
  failures use `ParseError(Message(detail))`.
- `enum DataType` — `Int | Float | Bool | String | Null`, with
  `is_numeric` / `is_integer` / `is_float` / `is_string` / `is_bool`.
- `enum Scalar` — cell value (`Int` carries `Int64`, `Float` carries
  `Double`). Total: `dtype` / `is_null` / `to_string` (value form, e.g.
  `Int(42) → "42"`, `Null → ""`). Fallible (`raise DataError`):
  `as_int` / `as_float` / `as_bool` / `as_string` and the comparisons
  `eq` / `lt` / `lte` / `gt` / `gte`, which return `Bool` and
  `raise TypeMismatch` when either side is `Null`, or
  `TypeMismatch(Operation("compare", left, right))` when two non-null dtypes are
  incomparable. `as_float` promotes `Int`; mixed numeric comparisons are
  **exact** (no `Int`→`Double` promotion). `String` comparisons are
  lexicographic **by Unicode code point** — so supplementary-plane characters
  (emoji, …) sort by their true scalar value rather than by raw UTF-16
  surrogate code unit — **not** the built-in shortlex `<`. Every user-facing
  ordering (`Scalar::lt`, `Series::min` / `max`, `DataFrame::sort`) routes
  through the same comparison, so they all agree.

  As of v0.6 the free functions that implemented these details —
  `compare_string_lex`, `escape_debug`, `is_decimal_int_literal`, the two
  literal parsers, and the shared literal renderer `format_scalar_literal` —
  live in the private packages `internal/text` and `internal/literal`; the
  exact-comparison primitives and `fold_extremum` remain in `types` as
  `#internal` engine seams. None are part of the public surface, and the
  behaviour they define is documented where it is observable (string ordering
  here, type inference in [`type-inference.md`](type-inference.md)).
- `struct Field` — column metadata: `name`, `dtype`, `nullable`. One total
  constructor, `Field(name, dtype, nullable? = true)`; accessors `name` /
  `dtype` / `nullable`; `rename(new_name)` returns a renamed copy. The
  fields are readable but not constructible from outside `types`, so a
  future field can be added without breaking callers. The bare
  `Field(...)` spelling resolves wherever the expected type is concrete —
  inside `Schema::new([...])`, an annotated binding, a typed array
  literal; in a generic position such as `assert_eq` write the full
  `Field::Field(...)`. `nullable = false` is a constraint enforced by
  `DataFrame::from_rows` (a null in such a column raises
  `NullInNonNullable`); it is otherwise advisory — not inferred from a
  column's contents, and not propagated across operations (the
  constructor default / `DataFrame::new` / the IO readers always set it
  `true`).
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

## `column` — Column storage backends (internal)

The column storage layer moved to the private package `internal/column` in
v0.6 and is **no longer part of the public API**: `Bitmap`, `BuiltinColumn`,
`NumericColumn`, `ColumnData`, `NumericData`, `ColumnStorage`, and
`StorageKind` cannot be named or imported by downstream code. `Series` owns a
backend internally and exposes only value-level access (`get` / `to_scalars`
/ the typed constructors), so callers never touch a storage type. The methods
that used to hand one out — `Series::storage` / `storage_kind` / `to_numeric`
/ `to_builtin` / `is_canonical` and `DataFrame::storage_kinds` / `to_numeric`
/ `to_builtin` — are engine seams as of v0.6: still `pub` for cross-package
use inside the library, marked `#internal`, and absent from the generated
interface, so they are not part of the surface this document covers.

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

### Constructors (free functions)

- `col(name) -> Expr` — a column reference.
- `cols(names : Array[String]) -> Array[Expr]` — `[col(n) for n in names]`,
  the shorthand for projecting / dropping several columns by name through
  the expression verbs (`df.select(cols(["a", "b"]))`).
- **Column selectors** (`@frame` free functions, reading a frame's schema to
  produce the `col(...)` list for the columns they match, in schema order):
  `numeric_cols(df) -> Array[Expr]` (every `Int` / `Float` column),
  `cols_of_dtype(df, dtype : DataType) -> Array[Expr]` (an exact dtype),
  `cols_matching(df, pattern : String) -> Array[Expr] raise DataError` (columns
  whose **name** matches the POSIX regex — invalid pattern → `InvalidOperation`),
  and the literal name selectors `cols_starts_with(df, prefix : String)` /
  `cols_ends_with(df, suffix : String)` / `cols_contains(df, substr : String) ->
  Array[Expr]` (columns whose **name** starts with / ends with / contains the
  literal string — **total**, unlike the regex `cols_matching`; an empty
  argument matches every column). Each fills a verb's container like `cols` and
  composes with hand-written entries:
  `df.select([col("id"), ..numeric_cols(df)])`,
  `df.drop(cols_matching(df, "_tmp$"))`. Eager (they read `df.schema()`), so the
  frame appears twice at the call site.
- `lit(s : Scalar) -> Expr` — a literal from any scalar.
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
- `col("a").floor_div(col("b"))` — floor (integer) division (`//`, a named
  method since `//` is a MoonBit comment). Same-dtype `Int / Int → Int`
  rounding toward −∞ (`-7 // 2 = -4`, not the `-3` truncation gives); any
  `Float` operand promotes to `floor(a / b)`. `Int` division by zero is a
  **null** cell (no integer infinity); `Float` follows IEEE (`±inf` / `NaN`).
- `col("a").modulo(col("b"))` — remainder (Polars `%`, a named method since
  `%` maps to no `Expr` operator). Same-dtype `Int / Int → Int` carrying the
  dividend's sign (`-7 % 2 = -1`); any `Float` operand promotes to the IEEE
  remainder. `Int` modulo by zero is a **null** cell (matching `floor_div`);
  `Float` modulo by zero is `NaN`.
- `col("a").pow(col("b"))` — exponentiation, **always `Float`** (integer
  operands are promoted, like `/`): total for every base / exponent, resolved
  under IEEE 754 (`0.0 ** 0.0 = 1.0`, an out-of-range result is `±inf`, an
  invalid one `NaN`).
- Logical `&` `|` (`BitAnd` / `BitOr`, **not** bitwise): Kleene
  three-valued `and` / `or`. The equivalent methods are `land` / `lor`
  (the impls' own spelling — `and` is a reserved word, so there is no
  `Expr::and` / `Expr::or`).
- Unary `-` (`Neg`): `-col("x")`.
- Unary numeric methods `col("x").abs()` / `.floor()` / `.ceil()` / `.sign()`
  / `.round(decimals? : Int = 0)` — absolute value; round toward −∞ / +∞ to an
  integer value; the `-1` / `0` / `+1` sign; and round **ties to even**
  (banker's rounding, Polars' default: `2.5` and `-2.5` both round to `±2`) to
  `decimals` places — `0` (the default) meaning whole numbers. A negative
  `decimals` clamps to `0`; at other settings the result carries the usual
  binary-floating-point caveat, and a value whose scaling would overflow is
  returned unchanged rather than becoming `NaN`.
  Each keeps the operand's dtype (`Int → Int`, `Float → Float`; `floor` /
  `ceil` / `round` leave an `Int` unchanged). `NaN` passes through
  (`sign(NaN) = NaN`); a null stays null; a non-numeric operand raises
  `TypeMismatch`. (`round` to a number of decimal places is a deferred additive
  refinement — this is the whole-number form.)

### Methods

- Comparisons `eq` / `ne` / `lt` / `le` / `gt` / `ge(other) -> Expr` —
  produce a `Bool` column. They are methods, not operators, because `==`
  / `<` are pinned to `Bool` / `Int` returns; the upside is that a method
  binds tighter than `&`, so `a.gt(x) & b.lt(y)` needs no parentheses.
- `is_in(members : Array[Scalar]) -> Expr` — a `Bool` column, `true` where the
  cell equals one of the literal `members`. Evaluated as an OR of `eq`, so each
  member is compared exactly as `a.eq(lit(member))` would: `Int` / `Float`
  members compare across types exactly, and a member whose dtype cannot compare
  with the column raises `TypeMismatch(Operation("compare", column, member))`.
  A `Null`
  member matches nothing, an empty set is `false` for every present cell, and a
  null cell yields null.
- `is_between(lo : Expr, hi : Expr, closed? : ClosedInterval = Both) -> Expr`
  — a `Bool` column, `true` where `a` falls in the range. `closed` (Polars'
  parameter, `enum ClosedInterval { Both; Left; Right; None }`) picks which
  endpoints count: `Both` is `lo <= a <= hi`, `Left` / `Right` open the other
  end, `None` excludes both. Equivalent to the matching `ge` / `gt` and `le` /
  `lt` pair under `land` — same exact ordering, Kleene null propagation, and
  `TypeMismatch(Operation("compare", left, right))` on an unorderable pair —
  but a dedicated node so the operand is evaluated once.
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
operand is a `TypeMismatch` at evaluation. The literal ops are per-value total;
the `*_regex` ops compile their pattern **once** per evaluation, so an invalid
pattern raises `InvalidOperation` (the one non-total path). The regex dialect is
**POSIX** (the core engine's) — character classes are `[[:digit:]]` /
`[[:alpha:]]`, **not** the PCRE `\d` / `\w`, which are a parse error — a
deliberate divergence from Polars' Rust-`regex` dialect.

- `str_to_uppercase()` / `str_to_lowercase() -> Expr` — case mapping,
  currently **ASCII-only** (a non-ASCII letter passes through unchanged,
  like `str_strip_chars`' ASCII whitespace set).
- `str_strip_chars(chars? : String) -> Expr` — strip leading / trailing
  characters. With `chars` omitted, the ASCII whitespace set (tab, newline,
  carriage-return, space); with `chars` given, every character in that set
  (order-independent, like Polars' `strip_chars`).
- `str_len_chars() -> Expr` — the Unicode character count as an `Int` (a
  supplementary-plane character counts once, not as its two UTF-16 code
  units); an all-valid result rides the `Numeric` fast path.
- `str_len_bytes() -> Expr` — the **UTF-8 byte** length as an `Int` (Polars'
  `str.len_bytes`); a supplementary-plane character counts as its 4 UTF-8
  bytes, an ASCII character as 1. Differs from `str_len_chars` for any
  non-ASCII cell; an all-valid result rides the `Numeric` fast path.
- `str_contains(pattern : String)` / `str_starts_with(prefix : String)` /
  `str_ends_with(suffix : String) -> Expr` — `Bool` columns for the literal
  substring / prefix / suffix tests.
- `str_replace(pattern : String, value : String)` /
  `str_replace_all(pattern : String, value : String) -> Expr` — replace the
  first / every literal occurrence of `pattern` with `value`.
- `str_reverse() -> Expr` — reverse each cell's characters (by codepoint, so
  surrogate pairs are respected).
- `str_pad_start(width : Int, fill? : Char)` /
  `str_pad_end(width : Int, fill? : Char) -> Expr` — left- / right-pad each cell
  with `fill` (default space) until it is `width` **characters** long; a cell
  already at least that long is unchanged (never truncated). The width counts
  characters, consistent with `str_len_chars`.
- `str_zfill(width : Int) -> Expr` — left-pad each cell with `'0'` to `width`
  **characters**, like `str_pad_start('0')` but **sign-aware**: a leading `+` /
  `-` keeps its place and the zeros fill after it (`"-5"` to width 4 is
  `"-005"`). The width counts the sign; a cell already that wide is unchanged.
- Regex forms: `str_contains` / `str_replace` / `str_replace_all` each take
  `literal? : Bool = true`. With `literal=false` the pattern is a POSIX regular
  expression matched partially (`str_contains`) or replaced at the first /
  every match with the literal `value` (no capture-group references yet).
  **The default is the opposite of Polars'**, which is regex-first; MoonFrame
  keeps literal matching as the default so an unescaped `.` or `[` in a plain
  substring cannot silently change meaning.
- `str_extract(pattern : String, group? : Int) -> Expr` — a nullable `String`
  column of the substring matched by `pattern`. `group` (default `0`, the
  **whole match** — Polars defaults to the first capture group `1`) picks a
  capture group; a cell that does not match, or whose group did not participate,
  is **null**.
- `str_count_matches(pattern : String) -> Expr` — an `Int` column of the
  non-overlapping match count (`0` where the pattern does not match); an
  all-valid result rides the `Numeric` fast path.
- `str_slice(offset : Int, length? : Int) -> Expr` — a substring by **character**
  position (Polars' `str.slice`). `offset` is 0-based; a negative `offset`
  counts from the end. `length` (omitted → to the end; `≤ 0` → empty) is a
  character count. Both clamp to the cell, so it never raises on a value —
  character-based, so a surrogate pair is never split (consistent with
  `str_len_chars`).
- `str_split_get(sep : String, index : Int) -> Expr` — a nullable `String`
  column of the `index`-th field of each cell split on the literal `sep`
  (0-based). A cell with fewer than `index + 1` fields — and any negative
  `index` — is **null** (the scalar form of Polars' `str.split(...).list.get`;
  the list-returning `str.split` awaits a list dtype). An empty `sep` yields
  the whole cell at index `0`.

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

Where `map_elements` hands the closure one `Scalar` per row, `map_batches`
hands it the whole evaluated column at once — the vectorised escape hatch:

- `Expr::map_batches(self, label~ : String, returns_scalar~ : Bool = false, f :
  (Series) -> Series raise) -> Expr` — `f` receives `self`'s entire evaluated
  `Series` and returns a `Series`, so a whole-column kernel (a cumulative sum,
  a rank) runs once rather than cell by cell.

Building the node is total; `f` runs at evaluation and may `raise`. The result
rides the same length contract as `lit_series` — a frame-tall result passes
through, a length-1 result broadcasts, any other length raises `LengthMismatch`
in the consuming verb — is named after `self`, and has its backend canonicalised
(an all-valid numeric result lands on `Numeric`) so `collect ≡ execute`. Like a
map, it is a value-and-shape barrier the optimizer never sinks a filter across.
Set `returns_scalar` when `f` reduces its input to a length-1 series: it marks
the node as a per-group reduction, so it is accepted as a **custom aggregation**
inside `group_by(...).agg([...])`, where `f` receives each group's rows and must
return a length-1 series (a non-length-1 result raises `LengthMismatch`). Left
`false`, the node is a plain row-wise expression and is rejected by `agg`'s
reduction-shape gate like any non-reducing expression.

### Introspection (all total)

- `explain(self) -> String`, and the `Show` impl, render the documented
  operator form: `col(name)`, quoted string literals, parenthesised infix
  binaries `(l op r)`, prefix `(-e)` / `(not e)`, postfix `e.is_null()` /
  `e.sum()` / `e.str_contains("p")` / `e.cast(T)`, `e as name`,
  `when(c).then(a).otherwise(b)`, `map("label", [inputs])` /
  `map_batches("label", [inputs])` (the latter with `, returns_scalar=true`
  when flagged) for the closure escape hatches (the closure opaque), and
  `lit_series("name", len)` for an embedded literal series (its data opaque).
  `LazyFrame::explain` reuses it for plan lines.
- `children` / `referenced_columns` / `output_name` are engine seams as of
  v0.6 (`#internal`, absent from the generated interface): the evaluator and
  the lazy optimizer walk expressions with them — Polars keeps the equivalents
  behind its `.meta` namespace. The naming rule they implement is still part of
  the contract: an alias wins, else the leftmost column reference, else
  `"literal"` for a column-less tree (a ternary draws its name from the value
  branches, never the condition), and every verb that names an output column
  follows it.
- `children(self) -> Array[Expr]` — the immediate sub-expressions of a
  node, left to right (a ternary lists its condition first); leaves return
  none.

### Evaluation semantics

Applied by the `frame` evaluator, vectorized (whole-column at a time),
raising `DataError` at evaluation time — building the tree never fails:

- **Type promotion**: `Int op Int → Int`, `Float op Float → Float`, mixed
  promotes `Int → Float`; non-numeric arithmetic →
  `TypeMismatch(Operation(operation, left, right))`.
- **Null propagation**: any null operand of an arithmetic or comparison
  makes the result null (Arrow / Polars).
- **Kleene `&` / `|`**: `true | null = true`, `false & null = false`,
  otherwise null; `not(null) = null`. Non-`Bool` operands → `TypeMismatch`.
- **Comparisons**: cross-numeric is legal, strings compare by
  code-point order, `Bool` as `false < true`; the result is a `Bool`
  column. Mixed `Int`-vs-`Float` compares **exactly** — the `Int64` is not
  promoted to `Double`, so two distinct values never collide above 2^53 (e.g.
  `Int64::MAX` is not equal to the `2^63` `Double` a promotion would round it
  to). A deliberate departure from Polars' Float64-supertype promotion, chosen
  for correctness; same-dtype comparisons are always exact.
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
- **Batched map** (`map_batches`) runs the closure once over the whole
  evaluated `Series` and takes back a `Series`, canonicalised onto its
  content backend; the result broadcasts like a `lit_series` (frame-tall
  passes through, length-1 broadcasts, else `LengthMismatch`).
  `returns_scalar=true` marks it a per-group reduction for `agg`.
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
rebuild and backend-convergence helpers, and the composite-key cell encoding.
It depends only on `types` / `internal/column`.

> **Plumbing note.** Those kernels (`gather_series` / `gather_series_opt` /
> `slice_series` / `rebuild_options` / `preserve_backend` /
> `try_column_to_numeric` / `validity_bools` / `reducer_for` /
> `scalars_to_series` / `key_cell`, plus `ReduceOp` / `KeyCell`) stay `pub`
> because `frame` consumes them across the package boundary — MoonBit has no
> package-private visibility — but as of v0.6 they are marked `#internal` and
> absent from the generated interface, so `series` publishes no free functions
> at all. Use the `Series` methods and `DataFrame` verbs built on top of them.

### Series

- `struct Series` — a named column. The backing storage lives in the private
  `internal/column` package, so callers work through the value-level API below
  and never name a storage type.
- Total constructors: `from_ints` / `from_int_options` / `from_floats` /
  `from_float_options` / `from_bools` / `from_bool_options` / `from_strings` /
  `from_string_options` — from a plain or nullable array of the dtype.
- Total inspection: `name` / `dtype` / `len` / `is_empty` / `null_count` /
  `to_scalars() -> Array[Scalar]` (materialise every cell, `Null` for null
  cells).
- Fallible (`raise DataError`): `is_null(i) -> Bool` / `get(i) -> Scalar`
  (`IndexOutOfBounds`); `slice(start, end)` / `gather(indices)`;
  `fill_null(value)` (`TypeMismatch` for `Scalar::Null` or a dtype-mismatched
  value); `cast(target)` — the single cross-dtype entry (`Int` / `Float` /
  `String` targets; `Bool` / `Null` → `Unsupported`).
- Total transforms: `rename(new_name)` (`O(1)`); `drop_nulls()` (gather
  non-null cells); `head(n)` / `tail(n)` (clamp `n` to `[0, len]`);
  `reverse()`; `sort(order? : SortOrder = Asc, nulls? : NullOrder = NullsLast)`
  — stable, and the same kernel `DataFrame::sort` uses, so `NaN` counts as
  missing alongside `Null` here too.

### Series stats (`series_stats.mbt`)

- Total: `count()` (non-null count); `n_unique()` (distinct non-null values
  via the same composite `key_cell` normalisation `group_by` / `join` use —
  every `Float` `NaN` is one bucket, `-0.0` folds into `+0.0`); `min()` /
  `max()` — return a `Scalar` directly (never fail; empty / all-null /
  all-NaN → `Scalar::Null`; `String` lexicographic; `Bool` is
  `false < true`); `first()` / `last()` — the positional endpoint cell as a
  `Scalar` (skip nothing, so a present `NaN` is returned verbatim; an empty
  series or a null endpoint cell → `Scalar::Null`).
- Fallible (`raise DataError`): `sum()` — `Int` / `Float` →
  `Scalar::Int` / `Scalar::Float`, empty / all-null is the additive
  identity; an `Int` sum accumulates in `Int64` and **wraps on overflow**
  (silently — no raise); `Bool` / `String` → `TypeMismatch`; `mean()` — `Double`,
  empty / all-null numeric → `InvalidOperation`, non-numeric →
  `TypeMismatch`. (`mean_opt`, the total form `describe` summarises with, is
  an engine seam as of v0.6 — `#internal`, absent from the generated
  interface.) `std()` /
  `variance()` — `Double`, the **sample** statistics (`ddof = 1`, Polars'
  default; Welford's algorithm); fewer than two non-null cells →
  `InvalidOperation`, non-numeric → `TypeMismatch`. `median()` — `Double`
  (numeric only; the mean of the two middles for an even count); empty /
  all-null → `InvalidOperation`, non-numeric → `TypeMismatch`. `Float` `NaN`
  is a value, not missing: it **propagates** through `sum` / `mean` /
  `std` / `variance` but is **skipped** by `min` / `max` / `median` (and
  `sort`); `first` / `last` are positional and skip nothing — only `Null` is
  ever treated as missing.

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
- Accessors (`raise DataError`): `get_column(name)`
  (`ColumnNotFound`); `get_column_at(i)` (`IndexOutOfBounds`);
  `item(row, name) -> Scalar` (Polars' `df.item`, a single cell —
  `ColumnNotFound` / `IndexOutOfBounds`); `row(i) -> Array[Scalar]` — row `i`'s cells in
  column order, a Polars-style tuple (`Null` for a null cell;
  `IndexOutOfBounds`).
- `rows() -> Array[Array[Scalar]]` (**total**) — every row as a tuple
  (`result[r][c]`). For more than a handful of rows, prefer this over a
  `row(i)` loop — it reads the frame once. (The column-major bulk read the
  serialisers share, `to_scalar_matrix`, is an engine seam as of v0.6 —
  `#internal`, absent from the generated interface.)
- Structural transforms: total `head(n)` / `limit(n)` (a Polars-style
  alias of `head`, the eager twin of `LazyFrame::limit`) / `tail(n)`
  (clamp `n` to `[0, nrows]`); `slice(start, end)` / `gather(indices)`
  (`raise`, `IndexOutOfBounds` / `InvalidOperation`) — `gather` is the row
  twin of `Series::gather`, sharing its name as in Polars.
- `reverse() -> DataFrame` — **total**. The rows bottom-up, schema
  untouched; a 0- or 1-row frame is returned unchanged.
- `with_row_index(name? : String = "index", offset? : Int64 = 0) -> DataFrame
  raise DataError` — prepend a dense, never-null `Int` counter running from
  `offset`, ahead of the frame's own columns (Polars' placement).
  `DuplicateColumn(name)` if the frame already has that column.
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
- `rename_with(f : (String) -> String) -> DataFrame raise DataError` — the
  **callable** form: rename **every** column through `f` (`new = f(old)`),
  for a uniform transform (a prefix, a case fold) over the whole schema. `f`
  is total, so the only failure is `DuplicateColumn` when `f` collapses two
  columns to one name; there is no `ColumnNotFound` (no name is looked up). The
  identity `name => name` is a no-op.
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
- `to_markdown(max_rows? : Int) -> String` — a **total** GitHub-flavored
  pipe-table renderer (IO-1: pure rendering lives in `frame`). Column widths
  align to `max(header, cells)` with a 3-char minimum; null cells render
  empty; `|` / `\` / CR / LF are GFM-escaped. An omitted `max_rows` renders
  every row; otherwise the table is capped there and `... (N more rows)` is
  appended (a negative `max_rows` clamps to 0).
- `to_html(options? : HtmlOptions = HtmlOptions()) -> String` — the **total**
  HTML `<table>` renderer (IO-1: pure rendering lives in `frame`, parallel to
  `to_markdown`). It emits a `<thead>` + `<tbody>`, one `<td>` per cell in
  declaration order; a null cell renders as `<td></td>`; `&` / `<` / `>` /
  `"` / `'` are escaped to HTML entities. 0 columns → empty string; N columns
  / 0 rows → header + empty `<tbody>`. The options add a `class` /
  `<caption>` and, via `max_rows`, a row cap with a `<tfoot>`
  `... (K more rows)` banner (negative `max_rows` clamps to 0).
- `struct HtmlOptions` (fields read-only) — built via
  `HtmlOptions(max_rows? , table_class? , caption? , escape? = true)`;
  `HtmlOptions()` renders all rows with no `class` / `caption` and escaping
  on. `escape=false` emits caption / header / cell / class strings verbatim,
  for trusted input that intentionally carries HTML.

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
- `unique(subset? : Array[Expr], keep? : KeepStrategy) -> DataFrame raise DataError` — drop duplicate rows.
  `keep` (default `First`) selects which occurrence survives: `First` / `Last`
  keep one representative per distinct row, `None` keeps only rows that have no
  duplicate at all (Polars' `keep='none'`). Kept rows always come out in
  ascending original-row order, so the result is deterministic without a sort.
  Row identity is the composite cell tuple `group_by` / `join` key on, so a
  `Float` `NaN` equals `NaN`, `-0.0` folds into `+0.0`, and a **null** cell is
  an ordinary value (rows that are null in the same places and equal elsewhere
  are duplicates). The schema and column order are unchanged; a frame no
  strategy would thin (all-distinct, or 0-row) is returned as-is. (Polars'
  `subset` parameter — dedup on a column subset — is deferred: resolving column
  names would make `unique` fallible, and this is the total, all-columns form.)

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
- `struct JoinOptions` (fields read-only) — built via one of three
  constructors, each carrying every knob as a named parameter:
  `JoinOptions::on(keys : Array[Expr], how? = Inner, suffix? = "_right",
  coalesce?)` (same keys on both frames),
  `JoinOptions::left_on(keys, right_on~, how?, suffix?, coalesce?)`
  (differently-named or -derived keys, paired position by position — both
  sides are given at once, so an unpaired specification cannot be written),
  or `JoinOptions::cross(suffix? = "_right")` (keyless `Cross`). The three
  shapes are the legal ones; mixing `on` with `left_on` / `right_on` is
  unspellable. An omitted `coalesce` is auto (coalesce on an inner / left /
  right join, keep both keys on an `Outer` join — Polars' rule) and only
  takes effect for an all-bare-`col` `on` join; `left_on` / `right_on` and
  derived keys never coalesce. Example:
  `JoinOptions::on([col("id")], how=Outer, coalesce=true)`.

### Sorting types

- `enum SortOrder` (`Asc` / `Desc`) and `enum NullOrder` (`NullsFirst` /
  `NullsLast`; for `Float`, `NaN` is treated as missing, like `Null`) live in
  `types` as of v0.6 — both `Series::sort` and `DataFrame::sort` name them, and
  one per-column kernel in `series` implements the ordering, so the two verbs
  cannot drift. The facade re-exports them unchanged.
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
  them falls back to `String` instead of being retyped to `Float`) /
  `strict_quotes` (`false`; when `true`, a linear pre-scan rejects malformed
  quoting before tokenisation). Built with
  `CsvReadOptions(has_header? , delimiter? , infer_schema_rows? ,
  null_values? , strict_column_count? , on_parse_error? ,
  allow_nonfinite_floats? , strict_quotes?)` — every parameter defaults, so
  `CsvReadOptions()` is the all-defaults reader and only what differs needs
  naming, as in `CsvReadOptions(delimiter=';', strict_quotes=true)`. The
  struct is read-only from outside `io` (no record literal); `null_values`
  is private and read back through the `null_values()` accessor, which — like
  the constructor — copies, so the reader's token list cannot be changed
  after construction.
- `enum OnParseError { Raise; Null }` (`pub(all)`) — the parse-failure
  policy shared by the three readers' options. A non-null cell past the
  inference window that doesn't fit its column's locked-in dtype either
  fails with `ParseError(Cell(...))` (`Raise`, the default — strict and
  lossless) or is downgraded to a null cell, keeping the column's inferred
  dtype (`Null`, Polars' `ignore_errors=True`).
- `struct CsvWriteOptions` — `header` (`true`) / `delimiter` (`,`) /
  `null_value` (`""`) / `sanitize_formulas` (`false`; when `true`, a String
  cell beginning with `=`, `+`, `-`, `@`, tab, or carriage return gains a
  leading apostrophe so spreadsheets treat it as text — intentionally lossy).
  Built with `CsvWriteOptions(header? , delimiter? , null_value? ,
  sanitize_formulas?)`; `CsvWriteOptions()` is the all-defaults writer.
- `parse_csv_str(content, options) -> DataFrame
  raise DataError` — tokenise → per-column inference (`Int → Float → Bool →
  String`) → null mapping → `DataFrame::new`. The default keeps NyaCSV's
  permissive quote handling. With `CsvReadOptions(strict_quotes=true)`, a linear pre-scan
  rejects an unterminated quoted field, non-separator text after a closing
  quote, or a quote inside an unquoted field as `ParseError`; escaped `""` and
  newlines inside quoted fields remain valid. `InvalidOperation` if
  `options.delimiter` is a
  double quote, a line terminator, or a non-BMP (supplementary-plane)
  character (the same configurations `format_csv` rejects, so a value the
  writer can't emit unambiguously can't be read back either);
  `DuplicateColumn` / `ParseError(Message(...))` (including a ragged row when
  `options.strict_column_count`) / `ParseError(Cell(...))` (a cell that does
  not fit its dtype unless `options.on_parse_error = Null`).
- `format_csv(df, options) -> String raise
  DataError` — cells render via `Scalar::to_string`; null →
  `options.null_value`; RFC 4180 quoting; LF-terminated. With the opt-in
  `CsvWriteOptions(sanitize_formulas=true)`, String cells beginning with `=`, `+`, `-`, `@`,
  tab, or carriage return gain a leading apostrophe before quoting so
  spreadsheets treat them as text. This intentionally lossy safety mode does
  not affect headers, nulls, numbers, booleans, or other strings; the default
  `false` preserves the previous byte-for-byte output. Raises
  `InvalidOperation` if `options.delimiter` is a double
  quote or a line terminator (`\n` / `\r`), which can't unambiguously frame
  fields, or a non-BMP character, whose UTF-16 surrogate pair the
  per-code-unit tokenizer can't match.
- `read_csv(path, options? : CsvReadOptions = CsvReadOptions()) -> DataFrame
  raise DataError` — the file wrapper; strict quote validation rides on
  `options.strict_quotes` (`IoError`).
- `read_csv_projected(path, options, projection : Array[String])` — an
  `#internal` engine seam (absent from the generated interface as of v0.6):
  `read_csv` that builds only the named `projection` columns, behind `lazy`'s
  `scan_csv` projection pushdown. Whole-input checks (strict quote validation,
  a malformed header, or a ragged row) are unaffected, but a parse error
  confined to a dropped column does not surface (see `lazy`).
- `write_csv(path, df, options? : CsvWriteOptions = CsvWriteOptions()) -> Unit
  raise DataError` — the file wrapper; the spreadsheet-formula safety mode
  rides on `options.sanitize_formulas` (`IoError`; a string cell or column name holding an
  unpaired UTF-16 surrogate is refused with `InvalidOperation` before encoding,
  as for every `write_*`).

### JSON (records shape `[{...}, ...]`)

- `struct JsonReadOptions` — `infer_schema_rows` (`100`; `0` or `<= 0`
  scans every record) / `on_parse_error` (`Raise`; the shared
  `OnParseError`, documented under CSV). Built with
  `JsonReadOptions(infer_schema_rows? , on_parse_error?)`; read-only from
  outside `io`. The NDJSON reader takes the same type — the two formats
  differ in framing, not in what there is to configure.
- `parse_json_records_str(content, options) -> DataFrame raise DataError`
  — `@json.parse` → object validation → headers in first-seen order
  across all records (sparse records → null cells) → inference (same
  order as CSV; `Number` locks `Int` when integral and in `Int64` range,
  else `Float`; `true` / `false` only for `Bool`; mixed → `String`
  fallback) → `DataFrame::new`. Structural or syntax failures use
  `ParseError(Message(...))`;
  typed cell failures use `ParseError(Cell(Record, ...))`. An integer
  outside Double's exact integer range but still inside its finite numerical
  range, when inferred as
  `Float` (a fractional sibling in the column), recovers its nearest finite
  value from the digits `@json` preserves in `repr`. An integer beyond Double's
  numerical range becomes `±Infinity`; a subsequent `format_json_records`
  writes that cell as `null` under the non-finite rule below.
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
- `read_json(path, options? : JsonReadOptions = JsonReadOptions()) -> DataFrame
  raise DataError`; `write_json_records(path, df) -> Unit raise
  DataError` — file wrappers (`IoError`; an unpaired UTF-16 surrogate in
  the content is refused with `InvalidOperation` before encoding).

### NDJSON (JSON Lines, one object per line `{...}\n{...}\n…`)

The streaming-friendly sibling of the JSON-records shape. Everything after
the line framing is shared with the records reader / writer — header
collection (first-seen order, sparse lines → null cells), the
`Int → Float → Bool → String` inference, and the `scalar_to_json` cell
conventions.

- Options: the same `JsonReadOptions` the records reader takes (see above).
- `parse_ndjson_str(content, options) -> DataFrame raise DataError` —
  split on `\n` → parse each non-blank line (`@json.parse`) → the shared
  records → frame core. Blank / whitespace-only lines are skipped and a
  trailing `\r` (CRLF) is tolerated as JSON whitespace, so the writer's
  trailing newline (and incidental blank lines) round-trip without
  phantom rows. A malformed line surfaces as
  `ParseError(Message("line N: …"))` (1-based); a line whose value is not an
  object also uses `Message`. A typed
  mismatch past the inference window (unless `options.on_parse_error = Null`)
  uses `ParseError(Cell(Line, ...))` with the physical 1-based line. Empty /
  all-blank input → 0×0 frame.
- `format_ndjson(df) -> String` — **total**. One compact object per row,
  keys in `df.columns()` order, each line terminated by `\n` (including
  the last — matching the CSV writer's per-row LF and Polars'
  `write_ndjson`); a 0-row frame renders the empty string. Per-cell
  rules match `format_json_records` (non-finite `Float` → `null`; `Int`
  beyond ±2^53 keeps its dtype but loses precision on a round-trip).
- `read_ndjson(path, options? : JsonReadOptions = JsonReadOptions()) ->
  DataFrame raise DataError`; `write_ndjson(path, df) -> Unit raise
  DataError` — file wrappers (`IoError`; an unpaired UTF-16 surrogate in
  the content is refused with `InvalidOperation` before encoding).
- `read_ndjson_projected(path, options, projection : Array[String])` — the
  NDJSON twin of `read_csv_projected`, likewise `#internal`: it builds only
  the named columns behind `lazy`'s `scan_ndjson` projection pushdown (a parse
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
  constructor `ChartSpec::bar(x, y, color? , color_type? , title?)` /
  `line` / `point` / `area` (`x` / `y` are column names); `color` names a
  grouping / colour column, `color_type` overrides that channel's Vega-Lite
  field `type`, and `title` carries the chart title.
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
  column) → `"nominal"` — unless the spec's `color_type` overrides the
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

A deferred query plan over an in-memory frame. `lazy_frame(df)` starts a
plan; builder methods mirroring the eager
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

- `lazy_frame(df : DataFrame) -> LazyFrame` — the entry point (a `Scan` leaf
  over the captured frame), for the `read_csv(path)` hand-feel. A free
  function rather than a `DataFrame::lazy` method (that would force a
  `frame ↔ lazy` import cycle) and rather than `lazy(df)` (`lazy` is a
  MoonBit reserved word).
- `scan_csv(path : String, options? : CsvReadOptions = CsvReadOptions()) ->
  LazyFrame` — a **lazy CSV source**: the plan's leaf is a deferred read of
  `path` (a `ScanCsv` node), the streaming-friendly counterpart of eager
  `read_csv`. Nothing is read until `collect`, and projection pushdown
  (below) narrows the parse to the columns the pipeline consumes — so
  `scan_csv("sales.csv").select([col("region"), col("revenue")]).collect()`
  never builds the columns it drops. `scan_csv(p).….collect()` equals
  `read_csv(p).…` on well-formed input; because a dropped column is never
  parsed, a parse error confined to one does not surface.
- `scan_ndjson(path : String, options? : JsonReadOptions = JsonReadOptions())
  -> LazyFrame` — the line-oriented sibling of `scan_csv` (a `ScanNdjson` node),
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
  `rename_with(f : (String) -> String)` · `reverse()` ·
  `with_row_index(name?, offset?)` ·
  `unique(subset? : Array[Expr], keep? : KeepStrategy)` ·
  `drop_nulls(subset? : Array[Expr])` ·
  `fill_null(value : Scalar)` — defer the column / row transforms (`rename_with`
  renders as a bare `RENAME_WITH` — its closure is opaque). The
  optimizer treats each as a barrier (filters do not sink past them and scans
  below keep their full output), so they are correct but not yet pushed
  through; a deeper `select` / `aggregate` still narrows its own scan.
- `sum()` · `mean()` · `min()` · `max()` · `count()` · `null_count()` — defer
  the whole-frame reductions to a single `Reduce` node, each collecting
  bitwise-equal to its eager `DataFrame` twin (a 1-row result; numeric columns
  reduced, non-numeric ones a `Null` cell — `count` / `null_count` count every
  dtype). Barriers, like the transforms above (a reduction reads every column,
  so a filter above it stays above and the input keeps its full output). The
  materialising `describe` stays eager-only.
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
  expressions in their `Expr::to_string` form, compact `SCAN [rows×cols]`
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
(`scan_csv` / `scan_ndjson`), which now absorbs **both** push-downs: a column
no consumer reads is never parsed, and — since v0.6 — a filter sitting on the
leaf is absorbed into the scan, which builds the predicate's columns, prunes
the rows, and parses the remaining columns for the survivors alone. So a parse
error confined to a dropped column *or* to a row the predicate drops goes
unraised; dtype inference still walks the whole file, so dtypes are unchanged.
The plan shows it as `SCAN_CSV "f.csv" [cols] WHERE (pred)`. Only the first
predicate is absorbed (combining two would reorder which operand's error
surfaces first). Deferred (out of scope): dead-expression elimination,
narrowing / predicate-splitting through joins, sinking filters below sorts, and
streaming a file source — the reader still tokenises the whole file.

---

## `moonframe` — Facade package

`moonframe.mbt` re-exports every symbol above via `pub using`, so a
single `import "ihb2032/MoonFrame" @moonframe` reaches the whole surface.
Because the operator verbs and `to_markdown` are **methods on
`DataFrame`**, re-exporting `type DataFrame` makes them automatically
reachable; likewise the `Expr` operators / methods ride along with
`type Expr`, and the `LazyFrame` / `LazyGroupBy` methods with their types —
so only the value types
and the free functions are listed explicitly. The inert `BinOp` / `UnOp`
/ `AggOp` / `StrOp` tag enums are deliberately **not** re-exported (no public
API names them).

- From `@types`: `DataError` · `CellParseLocation` · `ParseErrorDetail` ·
  `DataType` · `Scalar` · `Field` · `Schema` · `SortOrder` · `NullOrder`
- From `@expr`: `Expr` · `WhenThen` · `WhenThenElse` · `col` · `cols` ·
  `lit` · `lit_int` · `lit_float` · `lit_str` · `lit_bool` · `lit_series` ·
  `when` · `map_many`
- From `@series`: `Series`
- From `@frame`: `DataFrame` · `SortOrder` ·
  `NullOrder` · `KeepStrategy` · `GroupedDataFrame` · `JoinType` ·
  `JoinOptions` · `HtmlOptions` · `numeric_cols` · `cols_of_dtype` ·
  `cols_matching`
- From `@io`: `CsvReadOptions` · `CsvWriteOptions` · `JsonReadOptions` ·
  `OnParseError` · `ChartKind` · `ChartSpec` ·
  `VegaType` · `format_csv` ·
  `format_json_records` · `format_ndjson` · `format_vega_lite` ·
  `parse_csv_str` · `parse_json_records_str` · `parse_ndjson_str` ·
  `read_csv` · `read_json` · `read_ndjson` ·
  `write_csv` · `write_json_records` ·
  `write_ndjson` · `write_vega_lite`
- From `@lazy`: `LazyFrame` · `LazyGroupBy` · `lazy_frame` · `scan_csv` ·
  `scan_ndjson`

`using @pkg { type T }` also creates constructor aliases, so
`@moonframe.Scalar::Int(42)`, `@moonframe.SortOrder::Desc`,
`@moonframe.DataError::ColumnNotFound("y")` all resolve through the
facade.

---

## Out of scope for v0.5 (so far)

The whole v0.5 surface above is **shipped**, and it is the last breaking
release: from v0.6 on the API only grows (additive — no renames, removals,
or signature changes). These are the tracked deferrals, all v0.6+:

- **More expression families** — the list-returning `str.split` (blocked on a
  list dtype; the scalar `str_split_get` is done) and — further out — window
  and datetime expressions (the repo has no datetime type yet). The v0.5
  operator / method set is frozen; these extend it. (The arithmetic / numeric
  operator family — `floor_div`, `mod`, `pow`, `abs` / `floor` / `ceil` /
  `sign` / `round` — and the string family — `str_reverse` / `str_pad_*` /
  `str_zfill` / `str_slice` / `str_len_bytes` / `str_split_get`, the
  custom-charset `str_strip_chars`, and the regex ops `str_*_regex` /
  `str_extract` / `str_count_matches` — are now done.)
- **Lazy scan depth** — predicate pushdown into the file parser and
  streaming execution (v0.5's scan does projection pushdown only), plus
  columnar sources (Parquet / IPC) once eager readers exist.
- **`unique` subset** — dedup on a `subset` of key columns (the `keep`
  strategy is now supported; `subset` stays deferred because resolving column
  names would turn the currently-total `unique` fallible).
- **Optimizer extensions** — dead-expression elimination, narrowing /
  predicate-splitting through joins, and sinking filters below sorts (v0.5
  pushes predicates and projections only).
