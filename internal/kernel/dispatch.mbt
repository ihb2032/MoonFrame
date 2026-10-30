///|
/// The tag-level entries: a whole operator tag travels from the evaluator to
/// here — the `StrOp` / `PositionalOp` pattern — and the routing to each
/// operator's implementation happens beside the tag's semantics rather than
/// as a per-member translation in the caller. The matches are exhaustive
/// with no wildcard, so a member added to either enum fails compilation
/// here until it is routed, the same compile-forcing the shape match
/// over `ExprNode` keeps for variants.

///|
/// Evaluate one binary operator tag over two operands. The length contract
/// comes first — equal lengths pass, a length-1 side broadcasts to the other
/// (including to zero rows), anything else raises `LengthMismatch` — then the
/// routed kernel runs; arithmetic keeps the operand dtypes' promotion rules,
/// comparisons produce a nullable `Bool` column, logic is Kleene over `Bool`
/// operands only. The comparison and logic members re-tag onto the verbs the
/// shared cell loops match. A new `BinOp` member fails compilation here until
/// it is routed.
pub fn eval_binary(
  op : @ir.BinOp,
  lhs : Series,
  rhs : Series,
) -> Series raise @types.DataError {
  let (left, right) = broadcast_pair(lhs, rhs)
  match op {
    @ir.BinOp::Add => eval_add(left, right)
    @ir.BinOp::Sub => eval_sub(left, right)
    @ir.BinOp::Mul => eval_mul(left, right)
    @ir.BinOp::Div => eval_div(left, right)
    @ir.BinOp::FloorDiv => eval_floor_div(left, right)
    @ir.BinOp::Mod => eval_mod(left, right)
    @ir.BinOp::Pow => eval_pow(left, right)
    @ir.BinOp::Atan2 => eval_atan2(left, right)
    @ir.BinOp::Hypot => eval_hypot(left, right)
    @ir.BinOp::Eq => eval_compare(left, right, CmpVerb::Eq)
    @ir.BinOp::Ne => eval_compare(left, right, CmpVerb::Ne)
    @ir.BinOp::Lt => eval_compare(left, right, CmpVerb::Lt)
    @ir.BinOp::Le => eval_compare(left, right, CmpVerb::Le)
    @ir.BinOp::Gt => eval_compare(left, right, CmpVerb::Gt)
    @ir.BinOp::Ge => eval_compare(left, right, CmpVerb::Ge)
    @ir.BinOp::And => eval_logic(left, right, LogicOp::And)
    @ir.BinOp::Or => eval_logic(left, right, LogicOp::Or)
  }
}

///|
/// Evaluate one unary operator tag over its operand. The null probes are
/// plain validity reads — total, the output never null, `IsNull` keeping the
/// cells a null occupies and `IsNotNull` the rest; the numeric transforms
/// follow the operand dtype's own rules; `Round` carries its decimal-place
/// count in the tag. A new `UnOp` member fails compilation here until it is
/// routed.
pub fn eval_unary(
  op : @ir.UnOp,
  operand : Series,
) -> Series raise @types.DataError {
  match op {
    @ir.UnOp::Neg => eval_neg(operand)
    @ir.UnOp::Not => eval_not(operand)
    @ir.UnOp::IsNull =>
      Series::from_bools(operand.name(), operand.validity_bools().map(v => !v))
    @ir.UnOp::IsNotNull =>
      Series::from_bools(operand.name(), operand.validity_bools())
    @ir.UnOp::IsNan => eval_is_nan(operand)
    @ir.UnOp::IsNotNan => eval_is_not_nan(operand)
    @ir.UnOp::IsFinite => eval_is_finite(operand)
    @ir.UnOp::IsInfinite => eval_is_infinite(operand)
    @ir.UnOp::DtYear => eval_dt_year(operand)
    @ir.UnOp::DtMonth => eval_dt_month(operand)
    @ir.UnOp::DtDay => eval_dt_day(operand)
    @ir.UnOp::DtWeekday => eval_dt_weekday(operand)
    @ir.UnOp::Abs => eval_abs(operand)
    @ir.UnOp::Floor => eval_floor(operand)
    @ir.UnOp::Ceil => eval_ceil(operand)
    @ir.UnOp::Sign => eval_sign(operand)
    @ir.UnOp::Round(decimals) => eval_round(operand, decimals)
    @ir.UnOp::Sin => eval_sin(operand)
    @ir.UnOp::Cos => eval_cos(operand)
    @ir.UnOp::Tan => eval_tan(operand)
    @ir.UnOp::Asin => eval_asin(operand)
    @ir.UnOp::Acos => eval_acos(operand)
    @ir.UnOp::Atan => eval_atan(operand)
    @ir.UnOp::Sinh => eval_sinh(operand)
    @ir.UnOp::Cosh => eval_cosh(operand)
    @ir.UnOp::Tanh => eval_tanh(operand)
    @ir.UnOp::Asinh => eval_asinh(operand)
    @ir.UnOp::Acosh => eval_acosh(operand)
    @ir.UnOp::Atanh => eval_atanh(operand)
    @ir.UnOp::Ln => eval_ln(operand)
    @ir.UnOp::Log2 => eval_log2(operand)
    @ir.UnOp::Log10 => eval_log10(operand)
    @ir.UnOp::Exp => eval_exp(operand)
    @ir.UnOp::Cbrt => eval_cbrt(operand)
    @ir.UnOp::Sqrt => eval_sqrt(operand)
  }
}
