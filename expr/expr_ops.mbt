///|
/// Reference a column by name, for the Polars-style call shape
/// `col("a") + col("b")`. The name resolves at *evaluation* time —
/// `ColumnNotFound` then if the frame has no such column; building the
/// reference itself is total. Exposed both as the `Expr::col` static method
/// and, via `#as_free_fn`, the bare `col` free function the facade re-exports.
#as_free_fn(col)
pub fn Expr::col(name : String) -> Expr {
  Col(name)
}

///|
/// Build a column-reference list from names: `cols(["a", "b"])` is exactly
/// `[col("a"), col("b")]`. The ergonomic shorthand for the common case of
/// projecting (or dropping) several existing columns by name through the
/// expression verbs — `df.select(cols(["a", "b"]))` reads almost like the
/// names-only projection it replaces. Each name resolves at evaluation
/// time, exactly like `col`; building the list is total.
pub fn cols(names : Array[String]) -> Array[Expr] {
  names.map(name => Expr::col(name))
}

///|
/// Embed a literal `Scalar`. At evaluation it becomes a length-1 column
/// broadcast against its siblings. Prefer the typed shorthands
/// (`lit_int` / `lit_float` / `lit_str` / `lit_bool`), which avoid
/// spelling the `Scalar` variant at call sites. Exposed both as the
/// `Expr::lit` static method and, via `#as_free_fn`, the bare `lit` free
/// function.
#as_free_fn(lit)
pub fn Expr::lit(value : @types.Scalar) -> Expr {
  Lit(value)
}

///|
/// `Int` literal (64-bit, like every MoonFrame integer cell).
pub fn lit_int(value : Int64) -> Expr {
  Expr::lit(@types.Scalar::Int(value))
}

///|
/// `Float` literal.
pub fn lit_float(value : Double) -> Expr {
  Expr::lit(@types.Scalar::Float(value))
}

///|
/// `String` literal.
pub fn lit_str(value : String) -> Expr {
  Expr::lit(@types.Scalar::String(value))
}

///|
/// `Bool` literal.
pub fn lit_bool(value : Bool) -> Expr {
  Expr::lit(@types.Scalar::Bool(value))
}

///|
/// Embed a pre-materialised `Series` as a literal column, so a ready-made
/// column joins a pipeline beside the declarative `col(...) ...` expressions
/// (`df.with_columns([lit_series(s), (col("a") + col("b")).with_alias("c")])`).
/// At evaluation the series is used as-is: a length-1 series broadcasts over
/// the evaluation height (like a scalar `lit`), a series whose length matches
/// the frame supplies one cell per row, and any other length raises
/// `LengthMismatch`. The result column keeps the series' own name unless
/// `with_alias` overrides it — so `with_columns([lit_series(s)])` adds, or
/// in-place replaces, a column named `s.name()`. A free function (the argument
/// is a `Series`, not an `Expr`), like the `lit_*` family and `map_many`.
/// Building the node is total; the length check happens at evaluation, in
/// `frame`.
pub fn lit_series(series : @series.Series) -> Expr {
  LitSeries(series)
}

///|
/// `a + b` — numeric addition. Evaluation rules (`frame/expr_eval.mbt`):
/// `Int + Int → Int`, any `Float` operand promotes to `Float`, a null on
/// either side nulls the output cell, non-numeric operands are
/// `TypeMismatch`.
pub impl Add for Expr with fn add(self, other) {
  Binary(BinOp::Add, self, other)
}

///|
/// `a - b` — numeric subtraction, same promotion / null rules as `+`.
pub impl Sub for Expr with fn sub(self, other) {
  Binary(BinOp::Sub, self, other)
}

///|
/// `a * b` — numeric multiplication, same promotion / null rules as `+`.
pub impl Mul for Expr with fn mul(self, other) {
  Binary(BinOp::Mul, self, other)
}

///|
/// `a / b` — division, always `Float` (Polars `/` semantics): `Int`
/// operands promote, and division by zero follows IEEE 754 (`±inf` /
/// `nan`) on every backend rather than trapping — `Int` division-by-zero
/// behaviour differs across backends, so it is never emitted. A null on
/// either side nulls the output cell.
pub impl Div for Expr with fn div(self, other) {
  Binary(BinOp::Div, self, other)
}

///|
/// `a.floor_div(b)` — floor (integer) division, rounding the quotient toward
/// negative infinity (Polars `//`). Named, not an operator: MoonBit's `//` is
/// a line comment. Same-dtype `Int / Int → Int` (`-7 // 2 = -4`, not the `-3`
/// truncation gives); any `Float` operand promotes the result to `Float`
/// (`floor(a / b)`). `Int` division by zero yields a **null** cell (integers
/// have no infinity, and a backend integer divide would trap); `Float`
/// division by zero follows IEEE 754 (`±inf` / `nan`) like `/`. A null on
/// either side nulls the output cell; a non-numeric operand raises
/// `TypeMismatch`.
pub fn Expr::floor_div(self : Expr, other : Expr) -> Expr {
  Binary(BinOp::FloorDiv, self, other)
}

///|
/// `a.modulo(b)` — remainder (Polars `%`; a named method, `%` maps to no
/// `Expr` operator). Same-dtype `Int / Int → Int` carrying the dividend's sign
/// (`-7 % 2 = -1`); any `Float` operand promotes to `Float` (IEEE remainder).
/// `Int` modulo by zero yields a **null** cell (as for `floor_div`); `Float`
/// modulo by zero is `NaN`. A null on either side nulls the output cell; a
/// non-numeric operand raises `TypeMismatch`.
pub fn Expr::modulo(self : Expr, other : Expr) -> Expr {
  Binary(BinOp::Mod, self, other)
}

///|
/// `a.pow(b)` — exponentiation, **always `Float`** (`Int` operands promote to
/// `Double`, like `/`): total for every base / exponent — a negative exponent,
/// a negative or fractional base, and overflow all resolve under IEEE 754
/// (`0.0 ** 0.0 = 1.0`, an out-of-range result is `±inf`, an invalid one
/// `NaN`). A null on either side nulls the output cell; a non-numeric operand
/// raises `TypeMismatch`.
pub fn Expr::pow(self : Expr, other : Expr) -> Expr {
  Binary(BinOp::Pow, self, other)
}

///|
/// `a & b` — logical AND over `Bool` expressions, with Kleene three-valued
/// null semantics (`false & null = false`, `true & null = null`). `&` is
/// MoonBit's only overloadable conjunction (`&&` is built-in short-circuit
/// syntax), mirroring the Polars choice of `&` for expression logic. For
/// chains that read better without operators, the impl method itself is
/// the alias: `a.land(b)` — `and` is a MoonBit reserved word (mutual
/// recursion), so the core trait's own spelling serves instead.
pub impl BitAnd for Expr with fn land(self, other) {
  Binary(BinOp::And, self, other)
}

///|
/// `a | b` — logical OR over `Bool` expressions, with Kleene three-valued
/// null semantics (`true | null = true`, `false | null = null`). Same
/// operator-choice rationale as `&`; the method alias is likewise the impl
/// spelling, `a.lor(b)` (paired with `land` rather than a lone `or`).
pub impl BitOr for Expr with fn lor(self, other) {
  Binary(BinOp::Or, self, other)
}

///|
/// `-e` — numeric negation. `Int` negation wraps on `Int64` minimum
/// (MoonBit semantics — total, never aborts); `Float` follows IEEE 754.
pub impl Neg for Expr with fn neg(self) {
  Unary(UnOp::Neg, self)
}

///|
/// `a.abs()` — absolute value. `Int → Int` (`Int64::MIN` wraps, like `Neg`);
/// `Float → Float` (`|NaN| = NaN`, `|-0.0| = 0.0`). A null stays null; a
/// non-numeric operand raises `TypeMismatch`.
pub fn Expr::abs(self : Expr) -> Expr {
  Unary(UnOp::Abs, self)
}

///|
/// `a.floor()` — round toward −∞ to an integer value. `Float → Float`; `Int →
/// Int` unchanged (an integer is its own floor). `±inf` / `NaN` pass through.
/// A null stays null; a non-numeric operand raises `TypeMismatch`.
pub fn Expr::floor(self : Expr) -> Expr {
  Unary(UnOp::Floor, self)
}

///|
/// `a.ceil()` — round toward +∞ to an integer value. `Float → Float`; `Int →
/// Int` unchanged. `±inf` / `NaN` pass through. A null stays null; a
/// non-numeric operand raises `TypeMismatch`.
pub fn Expr::ceil(self : Expr) -> Expr {
  Unary(UnOp::Ceil, self)
}

///|
/// `a.sign()` — `-1` / `0` / `+1` by sign, in the operand's own dtype (`Int →
/// Int`, `Float → Float`). `Float` `NaN` stays `NaN` and `±0.0` gives `0.0`. A
/// null stays null; a non-numeric operand raises `TypeMismatch`.
pub fn Expr::sign(self : Expr) -> Expr {
  Unary(UnOp::Sign, self)
}

///|
/// `a.round()` — round to the nearest integer value, ties to even (banker's
/// rounding: `2.5` and `3.5` both round to `2` and `4`, `0.5 → 0`), matching
/// Polars' default. `Float → Float`; `Int → Int` unchanged (an integer is its
/// own rounding). `±inf` / `NaN` pass through and `±0.0` keeps its sign. A null
/// stays null; a non-numeric operand raises `TypeMismatch`. (Rounding to a
/// number of decimal places, and the other rounding modes, are deferred
/// additive refinements — this is the whole-number, ties-to-even form.)
pub fn Expr::round(self : Expr) -> Expr {
  Unary(UnOp::Round, self)
}

///|
/// `a.eq(b)` — elementwise equality, producing a `Bool` column. The whole
/// comparison family is methods, not operators: MoonBit pins the `Eq` /
/// `Compare` traits to `Bool` / `Int` returns, so they cannot build an
/// `Expr` — and the postfix method binds tighter than `&` / `|` anyway, so
/// `a.gt(x) & b.lt(y)` needs none of the parentheses Polars' operator
/// comparisons force. A null on either side nulls the output cell.
pub fn Expr::eq(self : Expr, other : Expr) -> Expr {
  Binary(BinOp::Eq, self, other)
}

///|
/// `a.ne(b)` — elementwise inequality (`Bool` column, null-propagating).
pub fn Expr::ne(self : Expr, other : Expr) -> Expr {
  Binary(BinOp::Ne, self, other)
}

///|
/// `a.lt(b)` — elementwise `<` (`Bool` column, null-propagating).
pub fn Expr::lt(self : Expr, other : Expr) -> Expr {
  Binary(BinOp::Lt, self, other)
}

///|
/// `a.le(b)` — elementwise `<=` (`Bool` column, null-propagating).
pub fn Expr::le(self : Expr, other : Expr) -> Expr {
  Binary(BinOp::Le, self, other)
}

///|
/// `a.gt(b)` — elementwise `>` (`Bool` column, null-propagating).
pub fn Expr::gt(self : Expr, other : Expr) -> Expr {
  Binary(BinOp::Gt, self, other)
}

///|
/// `a.ge(b)` — elementwise `>=` (`Bool` column, null-propagating).
pub fn Expr::ge(self : Expr, other : Expr) -> Expr {
  Binary(BinOp::Ge, self, other)
}

///|
/// `a.is_in(members)` — a `Bool` column, `true` where the cell equals one of
/// the literal `members`. Evaluated as an OR of `eq` over the set, so each
/// member is compared exactly as `a.eq(lit(member))` would: `Int` / `Float`
/// members compare across types exactly (no `2^53` collision), and a member
/// whose dtype cannot compare with the column raises `TypeMismatch`. A `Null`
/// member matches nothing (it has no value to equal), an empty set is `false`
/// for every present cell, and a null cell yields null.
pub fn Expr::is_in(self : Expr, members : Array[@types.Scalar]) -> Expr {
  IsIn(self, members)
}

///|
/// `a.is_between(lo, hi)` — a `Bool` column, `true` where `lo <= a <= hi`
/// (both endpoints closed). Equivalent to `a.ge(lo).land(a.le(hi))` — it
/// inherits their exact `Int`/`Float` ordering, `String` / `Bool` ordering,
/// Kleene null propagation, and `TypeMismatch` on an unorderable pair — but as
/// a dedicated node the operand `a` is evaluated once. (A `closed` endpoint
/// option is a deferred additive refinement; this is the both-closed form.)
pub fn Expr::is_between(self : Expr, lo : Expr, hi : Expr) -> Expr {
  IsBetween(self, lo, hi)
}

///|
/// Kleene logical negation of a `Bool` expression (`not(null) = null`).
/// A method because MoonBit has no overloadable unary `~` / `!`.
pub fn Expr::not(self : Expr) -> Expr {
  Unary(UnOp::Not, self)
}

///|
/// `Bool` column that is `true` where the operand is null. Reads validity
/// only, so the result is itself never null (total).
pub fn Expr::is_null(self : Expr) -> Expr {
  Unary(UnOp::IsNull, self)
}

///|
/// `Bool` column that is `true` where the operand is non-null — the
/// complement of `is_null`, equally total.
pub fn Expr::is_not_null(self : Expr) -> Expr {
  Unary(UnOp::IsNotNull, self)
}

///|
/// `Bool` column that is `true` where the operand holds the IEEE `NaN` value
/// (Polars' `is_nan`). The operand must be numeric: an `Int` cell is never
/// `NaN` (`false`), a `Float` cell is tested by `Double::is_nan`, and a
/// non-numeric operand is a `TypeMismatch` at evaluation. Unlike `is_null`,
/// this *propagates* nulls — a missing cell is neither NaN nor not, so the
/// result cell is null — since `NaN` is a real value distinct from a missing
/// one. Building the node is total.
pub fn Expr::is_nan(self : Expr) -> Expr {
  Unary(UnOp::IsNan, self)
}

///|
/// `Bool` column that is `true` where the operand is a non-`NaN` numeric value
/// — the complement of `is_nan` on non-null cells, propagating nulls the same
/// way (a missing cell stays null). Same numeric-operand requirement.
pub fn Expr::is_not_nan(self : Expr) -> Expr {
  Unary(UnOp::IsNotNan, self)
}

///|
/// Replace every `NaN` cell of `self` with `value`, keeping the non-`NaN`
/// cells (including true nulls) verbatim — Polars' `fill_nan`. The dual of
/// `fill_null`: where `fill_null` replaces missing cells and leaves `NaN`
/// (a value) alone, `fill_nan` replaces `NaN` and leaves nulls alone.
///
/// It evaluates exactly like
/// `when(self.is_not_nan()).then(self).otherwise(value)` — **named after
/// `self`** (the operand), and a null cell — for which `is_not_nan` is null
/// — falls through the Kleene ternary to a null result, never to `value`.
/// The branches unify their dtype like any ternary (`Int` meets `Float` by
/// promoting to `Float`, any other mismatch is a `TypeMismatch`). Unlike
/// that ternary spelling, the dedicated `FillNan` node holds (and
/// evaluates) `self` once, so a chain of fills stays linear in tree size
/// and work. Building the node is total.
pub fn Expr::fill_nan(self : Expr, value : Expr) -> Expr {
  FillNan(self, value)
}

///|
/// Replace every null cell of `self` with `value`, keeping the non-null
/// cells verbatim — Polars' `fill_null` (the value form), and a coalesce of
/// `self` over `value` when `value` is itself a column. `value` is any
/// expression: a literal (`lit_int(0)`), another column
/// (`col("fallback")`), or a computed tree.
///
/// It evaluates exactly like
/// `when(self.is_not_null()).then(self).otherwise(value)` — the result is
/// **named after `self`** (the filled column), never after `value`, so
/// `with_columns([col("x").fill_null(...)])` replaces `"x"` in place. The
/// branches must unify their dtype the way a ternary's do — `Int` meets
/// `Float` by promoting to `Float`, any other mismatch is a `TypeMismatch`
/// at evaluation. A non-null `NaN` is a *value* (validity 1), so it is
/// kept, not filled; only true nulls are replaced. Unlike that ternary
/// spelling, the dedicated `FillNull` node holds (and evaluates) `self`
/// once, so the chained-coalesce idiom
/// (`col("a").fill_null(col("b")).fill_null(lit_int(0))`) stays linear in
/// tree size and work — the lowering embedded `self` twice and grew
/// exponentially with chain length. Building the node is total; errors
/// surface when a consuming verb evaluates it.
pub fn Expr::fill_null(self : Expr, value : Expr) -> Expr {
  FillNull(self, value)
}

///|
/// Sum of the operand over the evaluation scope (whole frame, or one group
/// under `agg`). Inherits `Series::sum` semantics: NaN propagates,
/// nulls are skipped, non-numeric operands are `TypeMismatch`.
pub fn Expr::sum(self : Expr) -> Expr {
  Agg(AggOp::Sum, self)
}

///|
/// Mean of the operand over the evaluation scope (`Series::mean`
/// semantics: NaN propagates, nulls are skipped).
pub fn Expr::mean(self : Expr) -> Expr {
  Agg(AggOp::Mean, self)
}

///|
/// Minimum of the operand over the evaluation scope (`Series::min`
/// semantics: NaN and nulls are skipped).
pub fn Expr::min(self : Expr) -> Expr {
  Agg(AggOp::Min, self)
}

///|
/// Maximum of the operand over the evaluation scope (`Series::max`
/// semantics: NaN and nulls are skipped).
pub fn Expr::max(self : Expr) -> Expr {
  Agg(AggOp::Max, self)
}

///|
/// Count of non-null cells of the operand over the evaluation scope
/// (`Series::count` semantics).
pub fn Expr::count(self : Expr) -> Expr {
  Agg(AggOp::Count, self)
}

///|
/// Sample standard deviation of the operand over the evaluation scope
/// (`ddof = 1`, Polars' default): NaN propagates through the mean, nulls are
/// skipped, fewer than two non-null cells reduce to null, and a non-numeric
/// operand is `TypeMismatch`. Always a `Float`.
pub fn Expr::std(self : Expr) -> Expr {
  Agg(AggOp::Std, self)
}

///|
/// Sample variance of the operand over the evaluation scope (`ddof = 1`); the
/// square of `std`, with the identical null / NaN / dtype rules. Always a
/// `Float`. Spelled `variance` because `var` is a reserved MoonBit word (the
/// `with_alias` / `.land()` situation), so Polars' `var` becomes `variance`.
pub fn Expr::variance(self : Expr) -> Expr {
  Agg(AggOp::Var, self)
}

///|
/// Median of the operand over the evaluation scope. NaN and nulls are skipped
/// (the order-statistic counterpart of `min` / `max`), an all-missing scope
/// reduces to null, and a non-numeric operand is `TypeMismatch`. Always a
/// `Float` (`Int` widens), so an even count averages its two middles.
pub fn Expr::median(self : Expr) -> Expr {
  Agg(AggOp::Median, self)
}

///|
/// Number of distinct non-null values of the operand over the evaluation scope
/// (`Series::n_unique` semantics: every NaN is one bucket, `-0.0` folds into
/// `+0.0`). Total over every dtype, never null — an `Int`.
pub fn Expr::n_unique(self : Expr) -> Expr {
  Agg(AggOp::NUnique, self)
}

///|
/// First cell of the operand over the evaluation scope, in row order, keeping
/// the operand's dtype. Positional — a null first cell is null, an empty scope
/// is null, and a present `NaN` passes through verbatim.
pub fn Expr::first(self : Expr) -> Expr {
  Agg(AggOp::First, self)
}

///|
/// Last cell of the operand over the evaluation scope, in row order, keeping
/// the operand's dtype. The positional mirror of `first`.
pub fn Expr::last(self : Expr) -> Expr {
  Agg(AggOp::Last, self)
}

///|
/// Uppercase the **ASCII** letters of a String column — the shape of
/// Polars' `str.to_uppercase`, but case mapping is currently ASCII-only
/// (like `str_strip_chars`' ASCII whitespace set): a non-ASCII letter
/// (`é`, `ß`, Cyrillic, …) passes through unchanged rather than mapping.
/// Null cells stay null, the result keeps the operand's column name, and a
/// non-String operand is a `TypeMismatch` at evaluation. The leading method
/// of the string namespace: every `str_*` method builds a `Str` node over a
/// `StrOp` tag, evaluated cell by cell in `frame`.
pub fn Expr::str_to_uppercase(self : Expr) -> Expr {
  Str(StrOp::ToUppercase, self)
}

///|
/// Lowercase the **ASCII** letters of a String column (the shape of Polars'
/// `str.to_lowercase`, with `str_to_uppercase`'s ASCII-only case-mapping
/// caveat), the case mirror of `str_to_uppercase`.
pub fn Expr::str_to_lowercase(self : Expr) -> Expr {
  Str(StrOp::ToLowercase, self)
}

///|
/// Strip leading and trailing characters from every cell of a String column —
/// Polars' `str.strip_chars`. With `chars` omitted, the default set is ASCII
/// whitespace (tab, newline, carriage-return, space); with `chars` given, every
/// character in that string is a strip target (order and repeats do not
/// matter). Null cells stay null.
pub fn Expr::str_strip_chars(self : Expr, chars? : String) -> Expr {
  match chars {
    None => Str(StrOp::StripChars, self)
    Some(set) => Str(StrOp::StripCharsCustom(set), self)
  }
}

///|
/// The number of Unicode characters in each cell of a String column, as an
/// `Int` (Polars `str.len_chars`): a supplementary-plane character counts
/// once, not as its two UTF-16 code units. Null cells stay null; an all-valid
/// result rides the `Numeric` fast path like every computed numeric column.
pub fn Expr::str_len_chars(self : Expr) -> Expr {
  Str(StrOp::LenChars, self)
}

///|
/// The number of **UTF-8 bytes** in each cell of a String column, as an `Int`
/// (Polars `str.len_bytes`) — the encoded byte length, so an ASCII character is
/// 1, a `é` is 2, and a supplementary-plane emoji is 4 (vs `str_len_chars`,
/// which counts every character as 1). Null cells stay null; an all-valid
/// result rides the `Numeric` fast path.
pub fn Expr::str_len_bytes(self : Expr) -> Expr {
  Str(StrOp::LenBytes, self)
}

///|
/// The `index`-th field of each cell split on the literal separator `sep`, as a
/// nullable `String` (a scalar slice of Polars' `str.split`, which returns a
/// list this repo has no dtype for). `index` is 0-based; a cell with fewer than
/// `index + 1` fields (or a negative `index`) yields **null**. `"a,b,c"` split
/// on `","` at index 1 is `"b"`. Null cells stay null.
pub fn Expr::str_split_get(self : Expr, sep : String, index : Int) -> Expr {
  Str(StrOp::SplitGet(sep, index), self)
}

///|
/// A `Bool` column that is `true` where the cell contains `pattern` as a
/// literal substring — Polars' `str.contains(..., literal=True)`. Matching is
/// always literal: there is no regex engine yet, so a regex `contains` is a
/// future addition. Null cells stay null.
pub fn Expr::str_contains(self : Expr, pattern : String) -> Expr {
  Str(StrOp::Contains(pattern), self)
}

///|
/// A `Bool` column that is `true` where the cell starts with `prefix`
/// (Polars `str.starts_with`). Null cells stay null.
pub fn Expr::str_starts_with(self : Expr, prefix : String) -> Expr {
  Str(StrOp::StartsWith(prefix), self)
}

///|
/// A `Bool` column that is `true` where the cell ends with `suffix`
/// (Polars `str.ends_with`). Null cells stay null.
pub fn Expr::str_ends_with(self : Expr, suffix : String) -> Expr {
  Str(StrOp::EndsWith(suffix), self)
}

///|
/// Replace the first literal occurrence of `pattern` with `value` in each
/// cell of a String column — Polars' `str.replace(..., literal=True)`. A cell
/// without `pattern` is unchanged; null cells stay null.
pub fn Expr::str_replace(self : Expr, pattern : String, value : String) -> Expr {
  Str(StrOp::Replace(pattern, value), self)
}

///|
/// Replace every literal occurrence of `pattern` with `value` in each cell
/// (Polars `str.replace_all(..., literal=True)`), the all-occurrences mirror
/// of `str_replace`.
pub fn Expr::str_replace_all(
  self : Expr,
  pattern : String,
  value : String,
) -> Expr {
  Str(StrOp::ReplaceAll(pattern, value), self)
}

///|
/// Reverse the Unicode characters of each cell of a String column — Polars'
/// `str.reverse()`. Surrogate pairs are respected (reversal is by codepoint,
/// not UTF-16 unit); null cells stay null.
pub fn Expr::str_reverse(self : Expr) -> Expr {
  Str(StrOp::Reverse, self)
}

///|
/// Left-pad each cell of a String column with `fill` until it is `width`
/// **characters** long — Polars' `str.pad_start`. A cell already at least
/// `width` characters is unchanged (never truncated); null cells stay null.
/// The width counts characters, consistent with `str_len_chars`.
pub fn Expr::str_pad_start(
  self : Expr,
  width : Int,
  fill? : Char = ' ',
) -> Expr {
  Str(StrOp::PadStart(width, fill), self)
}

///|
/// Right-pad each cell of a String column with `fill` until it is `width`
/// **characters** long — Polars' `str.pad_end`, the mirror of `str_pad_start`.
pub fn Expr::str_pad_end(self : Expr, width : Int, fill? : Char = ' ') -> Expr {
  Str(StrOp::PadEnd(width, fill), self)
}

///|
/// `Bool` column, `true` where the cell **matches** the regular expression
/// `pattern` (a partial match, like Polars' `str.contains`). The regex form of
/// `str_contains`, which stays literal. `pattern` is a **POSIX** regular
/// expression — the core engine's dialect, so character classes are
/// `[[:digit:]]` / `[[:alpha:]]`, **not** the PCRE `\d` / `\w` (those raise). It
/// is compiled once per evaluation, so an invalid pattern raises
/// `InvalidOperation` at evaluation; a null cell stays null and a non-String
/// operand raises `TypeMismatch`.
pub fn Expr::str_contains_regex(self : Expr, pattern : String) -> Expr {
  Str(StrOp::ContainsRegex(pattern), self)
}

///|
/// Replace the **first** regex match of `pattern` in each cell with the literal
/// `value` — the regex form of `str_replace`. `pattern` is a POSIX regular
/// expression (see `str_contains_regex` for the dialect and the invalid-pattern
/// error); `value` is inserted literally (no capture-group references yet). A
/// cell with no match is unchanged; null cells stay null.
pub fn Expr::str_replace_regex(
  self : Expr,
  pattern : String,
  value : String,
) -> Expr {
  Str(StrOp::ReplaceRegex(pattern, value), self)
}

///|
/// Replace **every** regex match of `pattern` with the literal `value` — the
/// all-occurrences mirror of `str_replace_regex`.
pub fn Expr::str_replace_all_regex(
  self : Expr,
  pattern : String,
  value : String,
) -> Expr {
  Str(StrOp::ReplaceAllRegex(pattern, value), self)
}

///|
/// Extract a substring matched by the POSIX regular expression `pattern` — a
/// nullable `String` column (Polars' `str.extract`). `group` (default `0`, the
/// **whole match** — Polars defaults to the first capture group `1` instead)
/// selects a capture group; a cell that does not match, or whose chosen group
/// did not participate, yields **null**. See `str_contains_regex` for the
/// dialect and the invalid-pattern error; a null cell stays null and a
/// non-String operand raises `TypeMismatch`.
pub fn Expr::str_extract(
  self : Expr,
  pattern : String,
  group? : Int = 0,
) -> Expr {
  Str(StrOp::Extract(pattern, group), self)
}

///|
/// Count the non-overlapping matches of the POSIX regular expression `pattern`
/// in each cell — an `Int` column (Polars' `str.count_matches`), `0` where the
/// pattern does not match. An all-valid result rides the `Numeric` fast path,
/// like `str_len_chars`. See `str_contains_regex` for the dialect and the
/// invalid-pattern error; a null cell stays null and a non-String operand
/// raises `TypeMismatch`.
pub fn Expr::str_count_matches(self : Expr, pattern : String) -> Expr {
  Str(StrOp::CountMatches(pattern), self)
}

///|
/// Substring of each cell by **character** position — Polars' `str.slice`.
/// `offset` is a 0-based character index; a negative `offset` counts from the
/// end (`-2` starts two characters before the end). `length` is the number of
/// characters (omitted → to the end); a `length` of zero or less yields the
/// empty string. Both are clamped to the cell — an `offset` past the end gives
/// `""`, and a `length` past the end stops at the end — so it never raises on a
/// value. Character-based (surrogate pairs are never split), consistent with
/// `str_len_chars`; a null cell stays null and a non-String operand raises
/// `TypeMismatch`.
pub fn Expr::str_slice(self : Expr, offset : Int, length? : Int) -> Expr {
  Str(StrOp::Slice(offset, length), self)
}

///|
/// Cast the operand to `target` at evaluation time, delegating to
/// `Series::cast` (so the supported dtype pairs — and the `Unsupported`
/// cases — are exactly the eager ones).
pub fn Expr::cast(self : Expr, target : @types.DataType) -> Expr {
  Cast(self, target)
}

///|
/// Name the result column (`(col("revenue") - col("cost"))
/// .with_alias("profit")`). Without an alias, an expression is named after
/// its leftmost column reference, or `"literal"` for a column-less tree.
/// Called `with_alias` — `alias` itself is a MoonBit reserved word.
pub fn Expr::with_alias(self : Expr, name : String) -> Expr {
  Alias(self, name)
}

///|
/// First step of the conditional chain
/// `when(cond).then(a).otherwise(b)` — holds the `Bool` condition until
/// `then` supplies the matching branch. Constructible only through `when`
/// (a `pub` fn cannot return a `priv` type, so the builder is `pub` like the
/// `Expr` variants it carries); its field is read-only outside the package.
pub struct WhenThen {
  cond : Expr
}

///|
/// Second step of the conditional chain — condition plus `then` branch,
/// waiting for `otherwise` to complete the expression. Same read-only
/// rationale as `WhenThen`.
pub struct WhenThenElse {
  cond : Expr
  then_value : Expr
}

///|
/// Open a conditional expression: `when(cond).then(a).otherwise(b)`
/// evaluates to `a` where `cond` is `true`, `b` where it is `false`, and
/// null where `cond` is null. The chain is the only construction route, so
/// a conditional is complete by the time it becomes an `Expr`.
pub fn when(cond : Expr) -> WhenThen {
  { cond, }
}

///|
/// Supply the branch taken where the condition is `true`.
pub fn WhenThen::then(self : WhenThen, value : Expr) -> WhenThenElse {
  { cond: self.cond, then_value: value }
}

///|
/// Supply the branch taken where the condition is `false`, completing the
/// conditional as a `Ternary` expression node.
pub fn WhenThenElse::otherwise(self : WhenThenElse, value : Expr) -> Expr {
  Ternary(self.cond, self.then_value, value)
}

///|
/// Apply a host closure to each row of `self` — the single-input escape
/// hatch (Polars' `map_elements`). Where the operators and methods above
/// cover the documented algebra, `map_elements` reaches past it: `f`
/// receives the operand's cell as a `@types.Scalar` (a null cell as
/// `Scalar::Null`) and returns the output cell. `label` names the step in
/// `explain` / `Show` output — the function itself is opaque to
/// introspection, equality, and the optimizer.
///
/// Building the node is total; `f` runs at evaluation, once per row, and
/// may `raise` (the error propagates from the consuming verb). The output
/// column's dtype is that of the first non-null `Scalar` the closure
/// returns — an all-null (or empty) result has no such cell, so its dtype
/// falls back to `self`'s own column backend, yielding an all-null (or empty)
/// column of that dtype rather than the `Unsupported` a bare `Null` literal
/// raises (Polars' tolerance of a null-returning map). The result is
/// named after `self` (its leftmost column), so `with_alias` renames it.
/// Use it inside `with_columns` / `select` / `filter` like any other
/// expression; the optimizer treats it as a value barrier (it can raise on
/// values), so no filter sinks across it.
pub fn Expr::map_elements(
  self : Expr,
  label~ : String,
  f : (@types.Scalar) -> @types.Scalar raise @types.DataError,
) -> Expr {
  Map(label, [self], vs => f(vs[0]))
}

///|
/// Apply a host closure across several input columns, row by row — the
/// multi-input escape hatch, and the reified replacement for the v0.1
/// closure `filter` predicate: `f` is handed one `@types.Scalar` per input
/// in `inputs` order (null cells as `Scalar::Null`) and is called for every
/// row, so a row predicate is `map_many(..., f).` returning a `Bool`. A
/// free function rather than a method (there is no single `self`); `inputs`
/// may mix columns, literals, and aggregations, the length-1 results
/// broadcasting over the row count. Same opacity, totality, dtype
/// inference, naming (after the leftmost input), and value-barrier rules as
/// `map_elements`. The `inputs` array is copied, so mutating it after
/// construction cannot alter the built expression.
pub fn map_many(
  label~ : String,
  inputs : Array[Expr],
  f : (Array[@types.Scalar]) -> @types.Scalar raise @types.DataError,
) -> Expr {
  Map(label, inputs.copy(), f)
}
