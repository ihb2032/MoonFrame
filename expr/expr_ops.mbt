///|
/// Reference a column by name. The name resolves at *evaluation* time —
/// `ColumnNotFound` then if the frame has no such column; building the
/// reference itself is total.
pub fn Expr::col(name : String) -> Expr {
  Col(name)
}

///|
/// Free-function alias of `Expr::col`, for the Polars-style call shape
/// `col("a") + col("b")` (the same static-method + free-alias double
/// export the facade uses for `read_csv`).
pub fn col(name : String) -> Expr {
  Expr::col(name)
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
/// spelling the `Scalar` variant at call sites.
pub fn Expr::lit(value : @types.Scalar) -> Expr {
  Lit(value)
}

///|
/// Free-function alias of `Expr::lit`.
pub fn lit(value : @types.Scalar) -> Expr {
  Expr::lit(value)
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
/// `then` supplies the matching branch. Read-only and constructible only
/// through `when` (a `pub` fn cannot return a `priv` type, so the builder
/// is `pub` like the `Expr` variants it carries — still opaque outside).
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
/// returns — an all-null (or empty) result has no representable dtype and
/// raises `Unsupported`, exactly as the `Null` literal does. The result is
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
/// `RowView` row predicate: `f` is handed one `@types.Scalar` per input in
/// `inputs` order (null cells as `Scalar::Null`) and is called for every
/// row, so a row predicate is `map_many(..., f).` returning a `Bool`. A
/// free function rather than a method (there is no single `self`); `inputs`
/// may mix columns, literals, and aggregations, the length-1 results
/// broadcasting over the row count. Same opacity, totality, dtype
/// inference, naming (after the leftmost input), and value-barrier rules as
/// `map_elements`.
pub fn map_many(
  label~ : String,
  inputs : Array[Expr],
  f : (Array[@types.Scalar]) -> @types.Scalar raise @types.DataError,
) -> Expr {
  Map(label, inputs, f)
}
