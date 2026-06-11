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
/// `a & b` — logical AND over `Bool` expressions, with Kleene three-valued
/// null semantics (`false & null = false`, `true & null = null`). `&` is
/// MoonBit's only overloadable conjunction (`&&` is built-in short-circuit
/// syntax), mirroring the Polars choice of `&` for expression logic.
pub impl BitAnd for Expr with fn land(self, other) {
  Binary(BinOp::And, self, other)
}
