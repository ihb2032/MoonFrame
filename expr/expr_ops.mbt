///|
/// Reference a column by name, for the Polars-style call shape
/// `col("a") + col("b")`. The name resolves at *evaluation* time —
/// `ColumnNotFound` then if the frame has no such column; building the
/// reference itself is total. A free function, like the `lit*` family — the
/// facade re-exports it.
pub fn col(name : String) -> Expr {
  Expr::of(@ir.ExprNode::Col(name))
}

///|
/// Build a column-reference list from names: `cols(["a", "b"])` is exactly
/// `[col("a"), col("b")]`. The ergonomic shorthand for the common case of
/// projecting (or dropping) several existing columns by name through the
/// expression verbs — `df.select(cols(["a", "b"]))` reads almost like the
/// names-only projection it replaces. Each name resolves at evaluation
/// time, exactly like `col`; building the list is total.
pub fn cols(names : Array[String]) -> Array[Expr] {
  names.map(name => col(name))
}

///|
/// Embed a literal `Scalar`. At evaluation it becomes a length-1 column
/// broadcast against its siblings. Prefer the typed shorthands
/// (`lit_int` / `lit_float` / `lit_str` / `lit_bool`), which avoid
/// spelling the `Scalar` variant at call sites.
pub fn lit(value : @types.Scalar) -> Expr {
  Expr::of(@ir.ExprNode::Lit(value))
}

///|
/// `Int` literal (64-bit, like every MoonFrame integer cell).
pub fn lit_int(value : Int64) -> Expr {
  lit(@types.Scalar::Int(value))
}

///|
/// `Float` literal.
pub fn lit_float(value : Double) -> Expr {
  lit(@types.Scalar::Float(value))
}

///|
/// `String` literal.
pub fn lit_str(value : String) -> Expr {
  lit(@types.Scalar::String(value))
}

///|
/// `Bool` literal.
pub fn lit_bool(value : Bool) -> Expr {
  lit(@types.Scalar::Bool(value))
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
  Expr::of(@ir.ExprNode::LitSeries(series))
}

///|
/// `a + b` — numeric addition. Evaluation rules (`frame/expr_eval.mbt`):
/// `Int + Int → Int`, any `Float` operand promotes to `Float`, a null on
/// either side nulls the output cell, non-numeric operands are
/// `TypeMismatch`.
pub impl Add for Expr with fn add(self, other) {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Add, self.node, other.node))
}

///|
pub extend Expr with Add::{add}

///|
/// `a - b` — numeric subtraction, same promotion / null rules as `+`.
pub impl Sub for Expr with fn sub(self, other) {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Sub, self.node, other.node))
}

///|
pub extend Expr with Sub::{sub}

///|
/// `a * b` — numeric multiplication, same promotion / null rules as `+`.
pub impl Mul for Expr with fn mul(self, other) {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Mul, self.node, other.node))
}

///|
pub extend Expr with Mul::{mul}

///|
/// `a / b` — division, always `Float` (Polars `/` semantics): `Int`
/// operands promote, and division by zero follows IEEE 754 (`±inf` /
/// `nan`) on every backend rather than trapping — `Int` division-by-zero
/// behaviour differs across backends, so it is never emitted. A null on
/// either side nulls the output cell.
pub impl Div for Expr with fn div(self, other) {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Div, self.node, other.node))
}

///|
pub extend Expr with Div::{div}

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
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::FloorDiv, self.node, other.node))
}

///|
/// `a.modulo(b)` — remainder (Polars `%`; a named method, `%` maps to no
/// `Expr` operator). Same-dtype `Int / Int → Int` carrying the dividend's sign
/// (`-7 % 2 = -1`); any `Float` operand promotes to `Float` (IEEE remainder).
/// `Int` modulo by zero yields a **null** cell (as for `floor_div`); `Float`
/// modulo by zero is `NaN`. A null on either side nulls the output cell; a
/// non-numeric operand raises `TypeMismatch`.
pub fn Expr::modulo(self : Expr, other : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Mod, self.node, other.node))
}

///|
/// `a.pow(b)` — exponentiation, **always `Float`** (`Int` operands promote to
/// `Double`, like `/`): total for every base / exponent — a negative exponent,
/// a negative or fractional base, and overflow all resolve under IEEE 754
/// (`0.0 ** 0.0 = 1.0`, an out-of-range result is `±inf`, an invalid one
/// `NaN`). A null on either side nulls the output cell; a non-numeric operand
/// raises `TypeMismatch`.
pub fn Expr::pow(self : Expr, other : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Pow, self.node, other.node))
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
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::And, self.node, other.node))
}

///|
pub extend Expr with BitAnd::{land}

///|
/// `a | b` — logical OR over `Bool` expressions, with Kleene three-valued
/// null semantics (`true | null = true`, `false | null = null`). Same
/// operator-choice rationale as `&`; the method alias is likewise the impl
/// spelling, `a.lor(b)` (paired with `land` rather than a lone `or`).
pub impl BitOr for Expr with fn lor(self, other) {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Or, self.node, other.node))
}

///|
pub extend Expr with BitOr::{lor}

///|
/// `-e` — numeric negation. `Int` negation wraps on `Int64` minimum
/// (MoonBit semantics — total, never aborts); `Float` follows IEEE 754.
pub impl Neg for Expr with fn neg(self) {
  Expr::of(@ir.ExprNode::Unary(@ir.UnOp::Neg, self.node))
}

///|
pub extend Expr with Neg::{neg}

///|
/// `a.abs()` — absolute value. `Int → Int` (`Int64::MIN` wraps, like `Neg`);
/// `Float → Float` (`|NaN| = NaN`, `|-0.0| = 0.0`). A null stays null; a
/// non-numeric operand raises `TypeMismatch`.
pub fn Expr::abs(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Unary(@ir.UnOp::Abs, self.node))
}

///|
/// `a.floor()` — round toward −∞ to an integer value. `Float → Float`; `Int →
/// Int` unchanged (an integer is its own floor). `±inf` / `NaN` pass through.
/// A null stays null; a non-numeric operand raises `TypeMismatch`.
pub fn Expr::floor(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Unary(@ir.UnOp::Floor, self.node))
}

///|
/// `a.ceil()` — round toward +∞ to an integer value. `Float → Float`; `Int →
/// Int` unchanged. `±inf` / `NaN` pass through. A null stays null; a
/// non-numeric operand raises `TypeMismatch`.
pub fn Expr::ceil(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Unary(@ir.UnOp::Ceil, self.node))
}

///|
/// `a.sign()` — `-1` / `0` / `+1` by sign, in the operand's own dtype (`Int →
/// Int`, `Float → Float`). `Float` `NaN` stays `NaN` and `±0.0` gives `0.0`. A
/// null stays null; a non-numeric operand raises `TypeMismatch`.
pub fn Expr::sign(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Unary(@ir.UnOp::Sign, self.node))
}

///|
/// `a.round()` — round to the nearest integer value, ties to even (banker's
/// rounding: `2.5` and `3.5` both round to `2` and `4`, `0.5 → 0`), matching
/// Polars' default. `Float → Float`; `Int → Int` unchanged (an integer is its
/// own rounding). `±inf` / `NaN` pass through and `±0.0` keeps its sign. A null
/// stays null; a non-numeric operand raises `TypeMismatch`. `decimals` (default
/// `0`) rounds to that many decimal places — `decimals=2` sends `1.005` to
/// `1.0` or `1.01` as binary floating point dictates, the same caveat Polars
/// carries. A negative `decimals` clamps to `0`, and an `Int` column is the
/// identity at any setting. So is a place finer than the value's own
/// resolution: `round(decimals=20)` returns `123456.789` unchanged rather than
/// perturbing it by an ulp. (The other rounding modes remain a deferred
/// additive refinement; this is the ties-to-even form.)
pub fn Expr::round(self : Expr, decimals? : Int = 0) -> Expr {
  Expr::of(
    @ir.ExprNode::Unary(
      @ir.UnOp::Round(if decimals < 0 { 0 } else { decimals }),
      self.node,
    ),
  )
}

///|
/// `a.eq(b)` — elementwise equality, producing a `Bool` column. The whole
/// comparison family is methods, not operators: MoonBit pins the `Eq` /
/// `Compare` traits to `Bool` / `Int` returns, so they cannot build an
/// `Expr` — and the postfix method binds tighter than `&` / `|` anyway, so
/// `a.gt(x) & b.lt(y)` needs none of the parentheses Polars' operator
/// comparisons force. A null on either side nulls the output cell.
pub fn Expr::eq(self : Expr, other : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Eq, self.node, other.node))
}

///|
/// `a.ne(b)` — elementwise inequality (`Bool` column, null-propagating).
pub fn Expr::ne(self : Expr, other : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Ne, self.node, other.node))
}

///|
/// `a.lt(b)` — elementwise `<` (`Bool` column, null-propagating).
pub fn Expr::lt(self : Expr, other : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Lt, self.node, other.node))
}

///|
/// `a.le(b)` — elementwise `<=` (`Bool` column, null-propagating).
pub fn Expr::le(self : Expr, other : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Le, self.node, other.node))
}

///|
/// `a.gt(b)` — elementwise `>` (`Bool` column, null-propagating).
pub fn Expr::gt(self : Expr, other : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Gt, self.node, other.node))
}

///|
/// `a.ge(b)` — elementwise `>=` (`Bool` column, null-propagating).
pub fn Expr::ge(self : Expr, other : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Binary(@ir.BinOp::Ge, self.node, other.node))
}

///|
/// `a.is_in(members)` — a `Bool` column, `true` where the cell equals one of
/// the literal `members`. Each member is compared exactly as `a.eq(lit(member))`
/// would — the general path is an OR of `eq` over the set, and a
/// `String` / `Bool` / `Int` column whose members share its dtype takes an
/// equivalent single-pass membership test instead: `Int` / `Float`
/// members compare across types exactly (no `2^53` collision), and a member
/// whose dtype cannot compare with the column raises `TypeMismatch`. A `Null`
/// member matches nothing (it has no value to equal), an empty set is `false`
/// for every present cell, and a null cell yields null.
pub fn Expr::is_in(self : Expr, members : Array[@types.Scalar]) -> Expr {
  Expr::of(@ir.ExprNode::IsIn(self.node, members.copy()))
}

///|
/// `a.is_between(lo, hi)` — a `Bool` column, `true` where `a` falls in the
/// range. `closed` picks which endpoints count (Polars' `closed`): `Both` (the
/// default) is `lo <= a <= hi`, `Left` / `Right` open the other end, and `None`
/// excludes both. Equivalent to the matching `ge` / `gt` and `le` / `lt` pair
/// joined by `land` — it inherits their exact `Int`/`Float` ordering, `String`
/// / `Bool` ordering, Kleene null propagation, and `TypeMismatch` on an
/// unorderable pair — but as a dedicated node the operand `a` is evaluated
/// once.
pub fn Expr::is_between(
  self : Expr,
  lo : Expr,
  hi : Expr,
  closed? : @types.ClosedInterval = Both,
) -> Expr {
  Expr::of(@ir.ExprNode::IsBetween(self.node, lo.node, hi.node, closed))
}

///|
/// Kleene logical negation of a `Bool` expression (`not(null) = null`).
/// A method because MoonBit has no overloadable unary `~` / `!`.
pub fn Expr::not(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Unary(@ir.UnOp::Not, self.node))
}

///|
/// `Bool` column that is `true` where the operand is null. Reads validity
/// only, so the result is itself never null (total).
pub fn Expr::is_null(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Unary(@ir.UnOp::IsNull, self.node))
}

///|
/// `Bool` column that is `true` where the operand is non-null — the
/// complement of `is_null`, equally total.
pub fn Expr::is_not_null(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Unary(@ir.UnOp::IsNotNull, self.node))
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
  Expr::of(@ir.ExprNode::Unary(@ir.UnOp::IsNan, self.node))
}

///|
/// `Bool` column that is `true` where the operand is a non-`NaN` numeric value
/// — the complement of `is_nan` on non-null cells, propagating nulls the same
/// way (a missing cell stays null). Same numeric-operand requirement.
pub fn Expr::is_not_nan(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Unary(@ir.UnOp::IsNotNan, self.node))
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
  Expr::of(@ir.ExprNode::FillNan(self.node, value.node))
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
  Expr::of(@ir.ExprNode::FillNull(self.node, value.node))
}

///|
/// Sum of the operand over the evaluation scope (whole frame, or one group
/// under `agg`). Inherits `Series::sum` semantics: NaN propagates,
/// nulls are skipped, non-numeric operands are `TypeMismatch`.
pub fn Expr::sum(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::Sum, self.node))
}

///|
/// Mean of the operand over the evaluation scope (`Series::mean`
/// semantics: NaN propagates, nulls are skipped).
pub fn Expr::mean(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::Mean, self.node))
}

///|
/// Minimum of the operand over the evaluation scope (`Series::min`
/// semantics: NaN and nulls are skipped).
pub fn Expr::min(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::Min, self.node))
}

///|
/// Maximum of the operand over the evaluation scope (`Series::max`
/// semantics: NaN and nulls are skipped).
pub fn Expr::max(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::Max, self.node))
}

///|
/// Count of non-null cells of the operand over the evaluation scope
/// (`Series::count` semantics).
pub fn Expr::count(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::Count, self.node))
}

///|
/// Sample standard deviation of the operand over the evaluation scope
/// (`ddof = 1`, Polars' default): NaN propagates through the mean, nulls are
/// skipped, fewer than two non-null cells reduce to null, and a non-numeric
/// operand is `TypeMismatch`. Always a `Float`.
pub fn Expr::std(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::Std, self.node))
}

///|
/// Sample variance of the operand over the evaluation scope (`ddof = 1`); the
/// square of `std`, with the identical null / NaN / dtype rules. Always a
/// `Float`. Spelled `variance` because `var` is a reserved MoonBit word (the
/// `with_alias` / `.land()` situation), so Polars' `var` becomes `variance`.
pub fn Expr::variance(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::Var, self.node))
}

///|
/// Median of the operand over the evaluation scope. NaN and nulls are skipped
/// (the order-statistic counterpart of `min` / `max`), an all-missing scope
/// reduces to null, and a non-numeric operand is `TypeMismatch`. Always a
/// `Float` (`Int` widens), so an even count averages its two middles.
pub fn Expr::median(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::Median, self.node))
}

///|
/// Number of distinct non-null values of the operand over the evaluation scope
/// (`Series::n_unique` semantics: every NaN is one bucket, `-0.0` folds into
/// `+0.0`). Total over every dtype, never null — an `Int`.
pub fn Expr::n_unique(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::NUnique, self.node))
}

///|
/// First cell of the operand over the evaluation scope, in row order, keeping
/// the operand's dtype. Positional — a null first cell is null, an empty scope
/// is null, and a present `NaN` passes through verbatim.
pub fn Expr::first(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::First, self.node))
}

///|
/// Last cell of the operand over the evaluation scope, in row order, keeping
/// the operand's dtype. The positional mirror of `first`.
pub fn Expr::last(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Agg(@ir.AggOp::Last, self.node))
}

///|
/// Cast the operand to `target` at evaluation time, delegating to
/// `Series::cast` (so the supported dtype pairs — and the `Unsupported`
/// cases — are exactly the eager ones).
pub fn Expr::cast(self : Expr, target : @types.DataType) -> Expr {
  Expr::of(@ir.ExprNode::Cast(self.node, target))
}

///|
/// Name the result column (`(col("revenue") - col("cost"))
/// .with_alias("profit")`). Without an alias, an expression is named after
/// its leftmost column reference, or `"literal"` for a column-less tree.
/// Called `with_alias` — `alias` itself is a MoonBit reserved word.
pub fn Expr::with_alias(self : Expr, name : String) -> Expr {
  Expr::of(@ir.ExprNode::Alias(self.node, name))
}
