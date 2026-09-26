///|
/// Numeric-operand kernels for the expression evaluator — every `Expr` node
/// whose operands must be numbers: the binary arithmetic and its always-`Float`
/// siblings, the `Int`-preserving `//` / `%`, the unary shaping ops, and the
/// `NaN` probes. (Deliberately not enumerated one by one: the list grows with
/// the operator set.) Each kernel carries a `Numeric`×`Numeric` all-valid
/// fast arm that stays on the `Numeric` backend and a nullable general arm that
/// re-converges through `try_column_to_numeric`. The shared cell gates
/// (`zip_present` / `map_present`) and the `binary_type_mismatch_error` builder
/// are shared across the kernels in this package.

///|
/// The single home of the numeric-pairing contract every binary kernel
/// follows: how an `Int` and a `Float` operand pair up (any `Float` operand
/// promotes the cell pair to `Float`), the dtype gate that keeps an
/// I64-buffered rider (`Date`) out of the numeric arms, the all-valid
/// `Numeric`×`Numeric` fast arm, and the shared `TypeMismatch` for a
/// non-numeric pairing. The binary kernels differ only in their
/// `Int, Int` behaviour, which each supplies as its `int_int` callback; the
/// three `Float`-involving pairings are built here once from `float_op`.
/// A new `NumericData` variant fails every exhaustive match here
/// until it is classified, the same discipline the kernels' own arms follow.
fn numeric_fast_pair(
  left : Series,
  right : Series,
  int_int : (ArrayView[Int64], ArrayView[Int64]) -> Series,
  float_op : (Double, Double) -> Double,
) -> Series? {
  // Both operands are all-valid by construction, so the result is too —
  // compute it in one pass over the raw arrays and land straight back on
  // the `Numeric` backend, skipping the two validity materialisations, the
  // `Option` boxing, and the popcount re-convergence the general arm pays.
  // `NumericData` has exactly the two numeric arms, so the inner dispatch is
  // exhaustive with no dead arm; `Bool` / `String` columns are never
  // `Numeric`-backed and raise in `numeric_general_pair` as before.
  match (left.storage(), right.storage()) {
    (@column.ColumnStorage::Numeric(x), @column.ColumnStorage::Numeric(y)) =>
      Some(
        match (x.numeric_data(), y.numeric_data()) {
          (@column.NumericData::Int(a), @column.NumericData::Int(b)) =>
            int_int(a, b)
          (@column.NumericData::Int(a), @column.NumericData::Float(b)) =>
            Series::from_floats(
              left.name(),
              Array::makei(a.length(), i => float_op(a[i].to_double(), b[i])),
            )
          (@column.NumericData::Float(a), @column.NumericData::Int(b)) =>
            Series::from_floats(
              left.name(),
              Array::makei(a.length(), i => float_op(a[i], b[i].to_double())),
            )
          (@column.NumericData::Float(a), @column.NumericData::Float(b)) =>
            Series::from_floats(
              left.name(),
              Array::makei(a.length(), i => float_op(a[i], b[i])),
            )
        },
      )
    (@column.ColumnStorage::Builtin(_), _)
    | (_, @column.ColumnStorage::Builtin(_)) => None
  }
}

///|
/// The nullable general half of the shared binary skeleton: materialise the
/// two validity masks, gate the I64-buffered arms on both dtypes being
/// numeric (an I64 buffer may carry the `Date` rider), run the three
/// `Float`-involving pairings through `zip_present` + `float_op`, delegate
/// `Int, Int` to the kernel's `int_int` callback, and raise the shared
/// `TypeMismatch` for every non-numeric pairing. The caller converges an
/// all-valid result back onto the `Numeric` backend.
fn numeric_general_pair(
  left : Series,
  right : Series,
  verb : String,
  int_int : (ArrayView[Int64], ArrayView[Int64], Array[Bool], Array[Bool]) -> Series,
  float_op : (Double, Double) -> Double,
) -> Series raise @types.DataError {
  let lv = validity_bools(left)
  let rv = validity_bools(right)
  match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::I64(a), @column.ColumnData::I64(b)) if left
      .dtype()
      .is_numeric() &&
      right.dtype().is_numeric() => int_int(a, b, lv, rv)
    (@column.ColumnData::I64(a), @column.ColumnData::F64(b)) if left
      .dtype()
      .is_numeric() &&
      right.dtype().is_numeric() =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => float_op(a[i].to_double(), b[i])),
      )
    (@column.ColumnData::F64(a), @column.ColumnData::I64(b)) if left
      .dtype()
      .is_numeric() &&
      right.dtype().is_numeric() =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => float_op(a[i], b[i].to_double())),
      )
    (@column.ColumnData::F64(a), @column.ColumnData::F64(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => float_op(a[i], b[i])),
      )
    (@column.ColumnData::I64(_), @column.ColumnData::I64(_))
    | (@column.ColumnData::I64(_), @column.ColumnData::F64(_))
    | (@column.ColumnData::F64(_), @column.ColumnData::I64(_))
    | (@column.ColumnData::Bool(_) | @column.ColumnData::Utf8(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::Utf8(_)) =>
      raise binary_type_mismatch_error(verb, left, right)
  }
}

///|
/// Shared kernel for `+` / `-` / `*` over two equal-length operands
/// (post-`broadcast_pair`); each operator supplies its `Int64` and
/// `Double` cell ops plus the verb its `TypeMismatch(Operation(...))` field uses.
/// Dtype rules: `Int op Int → Int`, any `Float` operand promotes the
/// result to `Float`, anything non-numeric raises. A null on either side
/// nulls the output cell (Arrow / Polars arithmetic propagation). `Int`
/// arithmetic wraps on overflow (MoonBit `Int64` semantics — total, never
/// aborts); `Float` follows IEEE 754, so NaN propagates as a value. An
/// all-valid numeric result converges onto the `Numeric` backend
/// (`try_column_to_numeric`); a nullable one stays `Builtin`.
fn eval_arith(
  left : Series,
  right : Series,
  verb : String,
  int_op : (Int64, Int64) -> Int64,
  float_op : (Double, Double) -> Double,
) -> Series raise @types.DataError {
  match
    numeric_fast_pair(
      left,
      right,
      (a, b) => {
        Series::from_ints(
          left.name(),
          Array::makei(a.length(), i => int_op(a[i], b[i])),
        )
      },
      float_op,
    ) {
    Some(fast) => fast
    None =>
      try_column_to_numeric(
        numeric_general_pair(
          left,
          right,
          verb,
          (a, b, lv, rv) => {
            Series::from_int_options(
              left.name(),
              zip_present(a.length(), lv, rv, i => int_op(a[i], b[i])),
            )
          },
          float_op,
        ),
      )
  }
}

///|
/// `+` — the `eval_arith` instance behind `Expr` addition.
pub fn eval_add(left : Series, right : Series) -> Series raise @types.DataError {
  eval_arith(left, right, "add", (a, b) => a + b, (a, b) => a + b)
}

///|
/// `-` — the `eval_arith` instance behind `Expr` subtraction.
pub fn eval_sub(left : Series, right : Series) -> Series raise @types.DataError {
  eval_arith(left, right, "subtract", (a, b) => a - b, (a, b) => a - b)
}

///|
/// `*` — the `eval_arith` instance behind `Expr` multiplication.
pub fn eval_mul(left : Series, right : Series) -> Series raise @types.DataError {
  eval_arith(left, right, "multiply", (a, b) => a * b, (a, b) => a * b)
}

///|
/// Shared kernel for the **always-`Float`** binary operators (`/` and `**`):
/// every numeric pairing — including `Int, Int` — computes in `Double`, so all
/// four arms land on `from_floats` / `from_float_options`. The operator supplies
/// its `Double` cell op and the verb its `TypeMismatch(Operation(...))` field uses. Null
/// propagation and the `Numeric` fast arm / re-convergence match `eval_arith`.
fn eval_binary_float(
  left : Series,
  right : Series,
  verb : String,
  float_op : (Double, Double) -> Double,
) -> Series raise @types.DataError {
  match
    numeric_fast_pair(
      left,
      right,
      (a, b) => {
        Series::from_floats(
          left.name(),
          Array::makei(a.length(), i => {
            float_op(a[i].to_double(), b[i].to_double())
          }),
        )
      },
      float_op,
    ) {
    Some(fast) => fast
    None =>
      try_column_to_numeric(
        numeric_general_pair(
          left,
          right,
          verb,
          (a, b, lv, rv) => {
            Series::from_float_options(
              left.name(),
              zip_present(a.length(), lv, rv, i => {
                float_op(a[i].to_double(), b[i].to_double())
              }),
            )
          },
          float_op,
        ),
      )
  }
}

///|
/// Shared kernel for the binary operators whose **`Int, Int` arm stays `Int`
/// but nulls on a zero divisor** (`//` and `%`): same-dtype `Int / Int → Int`
/// via `int_op` (a `0` divisor → null cell), any `Float` operand promotes to
/// `Float` via `float_op`. Because a zero divisor can null an otherwise-all-valid
/// `Int` pair, the `Int, Int` arms re-converge through `try_column_to_numeric`.
/// The operator supplies both cell ops and its verb.
fn eval_binary_nullzero(
  left : Series,
  right : Series,
  verb : String,
  int_op : (Int64, Int64) -> Int64,
  float_op : (Double, Double) -> Double,
) -> Series raise @types.DataError {
  match
    numeric_fast_pair(
      left,
      right,
      (a, b) => {
        // A zero divisor nulls its cell, so an all-valid pair can still leave
        // the `Numeric` fast path — re-converge afterwards.
        try_column_to_numeric(
          Series::from_int_options(
            left.name(),
            Array::makei(a.length(), i => {
              if b[i] == 0L {
                None
              } else {
                Some(int_op(a[i], b[i]))
              }
            }),
          ),
        )
      },
      float_op,
    ) {
    Some(fast) => fast
    None =>
      try_column_to_numeric(
        numeric_general_pair(
          left,
          right,
          verb,
          (a, b, lv, rv) => {
            Series::from_int_options(
              left.name(),
              Array::makei(a.length(), i => {
                if lv[i] && rv[i] && b[i] != 0L {
                  Some(int_op(a[i], b[i]))
                } else {
                  None
                }
              }),
            )
          },
          float_op,
        ),
      )
  }
}

///|
/// `Div` — division is **always** `Float` (Polars `/`), so every numeric pair
/// divides in `Double` and division by zero follows IEEE 754 — `x/0 → ±inf`,
/// `0/0 → NaN` — on every backend rather than trapping (`Int` division by zero
/// is backend-divergent, so it is never emitted).
pub fn eval_div(left : Series, right : Series) -> Series raise @types.DataError {
  eval_binary_float(left, right, "divide", (a, b) => a / b)
}

///|
/// `Mod` — remainder, the kernel behind `Expr::modulo`. Same-dtype
/// `Int / Int → Int`
/// carrying the dividend's sign; any `Float` operand promotes to `Float` (IEEE
/// remainder). `Int` modulo by zero produces a **null** cell (as for
/// `floor_div`), so an all-valid `Int / Int` pair can still yield nulls;
/// `Float` modulo by zero is `NaN`.
pub fn eval_mod(left : Series, right : Series) -> Series raise @types.DataError {
  eval_binary_nullzero(
    left,
    right,
    "take the remainder of",
    (a, b) => rem_i64(a, b),
    (a, b) => a % b,
  )
}

///|
/// `a % b` for two `Int64`s. The caller has already excluded a zero divisor.
///
/// `-1` is special-cased for the same reason `floor_div_i64` special-cases it:
/// the pair `Int64::MIN % -1` is evaluated as part of a division whose quotient
/// (`2^63`) does not fit, and the backends disagree about what that means.
/// Wasm's `i64.rem_s` defines the result as `0`, but a native build lowers `%`
/// to a hardware divide, where `INT64_MIN % -1` raises the same fault as a
/// divide by zero — aborting the whole evaluation. The remainder of a division
/// by `-1` (or by `1`) is `0` for every dividend, so returning it directly is
/// the value every backend that defines the operation already produces, and it
/// never reaches the instruction that faults.
fn rem_i64(a : Int64, b : Int64) -> Int64 {
  if b == -1L {
    return 0L
  }
  a % b
}

///|
/// `Pow` — exponentiation, **always `Float`**, the kernel behind `Expr::pow`.
/// Every numeric pair raises in `Double` (the `pow` primitive), total under
/// IEEE 754.
pub fn eval_pow(left : Series, right : Series) -> Series raise @types.DataError {
  eval_binary_float(left, right, "exponentiate", (a, b) => @math.pow(a, b))
}

///|
/// `a // b` for two `Int64`s, rounding toward −∞ rather than the truncation
/// `Int64::/` gives. The caller has already excluded a zero divisor.
///
/// `-1` is special-cased because it is the one divisor whose quotient can
/// leave `Int64`: `Int64::MIN // -1` is `2^63`. `Int64::/` does not wrap there
/// the way `+` / `-` / `*` / `neg` do — **every backend faults**: wasm's
/// `i64.div_s` traps on that pair by specification, and a native build lowers
/// `/` to a hardware divide that raises the same fault as a divide by zero. So
/// the general path below would abort rather than return. Division by `-1` is
/// exact for every dividend (the remainder is always `0`, so the floor
/// adjustment never fires) and equals negation, which *does* wrap. Routing it
/// through `-a` therefore returns the same value as the general path wherever
/// that path is defined, and the wrapped `Int64::MIN` where it is not —
/// matching `neg` / `abs` / `*` on the same overflow, and numpy's `//`.
fn floor_div_i64(a : Int64, b : Int64) -> Int64 {
  if b == -1L {
    return -a
  }
  let q = a / b
  // `/` truncates toward zero and `%` carries the dividend's sign, so a
  // negative, non-integral true quotient truncates one above its floor.
  if a % b != 0L && (a < 0L) != (b < 0L) {
    q - 1L
  } else {
    q
  }
}

///|
/// `FloorDiv` — same-dtype `Int / Int → Int` (floor toward −∞); any `Float`
/// operand promotes to `Float` (`(a / b).floor()`). `Int` division by zero
/// produces a **null** cell (no integer infinity, and a backend integer divide
/// by zero traps), so even an all-valid `Int / Int` pair can yield nulls;
/// `Float` division by zero follows IEEE 754 (`±inf` / `nan`) and stays a value.
pub fn eval_floor_div(
  left : Series,
  right : Series,
) -> Series raise @types.DataError {
  eval_binary_nullzero(
    left,
    right,
    "floor-divide",
    (a, b) => floor_div_i64(a, b),
    (a, b) => (a / b).floor(),
  )
}

///|
/// Numeric negation kernel. `Int` negation wraps on `Int64` minimum
/// (MoonBit semantics — total, never aborts); `Float` follows IEEE 754,
/// so `-NaN` is still NaN and `-0.0` is the negative zero. A null cell
/// stays null; non-numeric operands raise. An all-valid result converges
/// onto the `Numeric` backend, as for binary arithmetic.
pub fn eval_neg(operand : Series) -> Series raise @types.DataError {
  eval_unary_num(operand, "negate", a => -a, a => -a)
}

///|
/// `abs` — the `eval_unary_num` instance behind `Expr::abs`.
pub fn eval_abs(operand : Series) -> Series raise @types.DataError {
  eval_unary_num(operand, "take the absolute value of", a => a.abs(), a => {
    a.abs()
  })
}

///|
/// `floor` — the `eval_unary_num` instance behind `Expr::floor`.
pub fn eval_floor(operand : Series) -> Series raise @types.DataError {
  eval_unary_num(operand, "take the floor of", a => a, a => a.floor())
}

///|
/// `ceil` — the `eval_unary_num` instance behind `Expr::ceil`.
pub fn eval_ceil(operand : Series) -> Series raise @types.DataError {
  eval_unary_num(operand, "take the ceiling of", a => a, a => a.ceil())
}

///|
/// `sign` — the `eval_unary_num` instance behind `Expr::sign`.
pub fn eval_sign(operand : Series) -> Series raise @types.DataError {
  eval_unary_num(operand, "take the sign of", sign_i64, sign_f64)
}

///|
/// `round` — the `eval_unary_num` instance behind `Expr::round`, rounding
/// each `Float` cell to `decimals` places (`round_places`); `Int` cells pass
/// through.
pub fn eval_round(
  operand : Series,
  decimals : Int,
) -> Series raise @types.DataError {
  eval_unary_num(operand, "round", a => a, v => round_places(v, decimals))
}

///|
/// Shared kernel for a numeric unary op (`neg` / `abs` / `floor` / `ceil` /
/// `sign` / `round`): each supplies its `Int64` and `Double` cell op plus the verb its
/// `TypeMismatch` message uses. `Int op → Int`, `Float op → Float`; a null cell
/// stays null; a non-numeric operand raises. An all-valid result converges onto
/// the `Numeric` backend, as for binary arithmetic.
fn eval_unary_num(
  operand : Series,
  verb : String,
  int_op : (Int64) -> Int64,
  float_op : (Double) -> Double,
) -> Series raise @types.DataError {
  match operand.storage() {
    @column.ColumnStorage::Numeric(x) =>
      return match x.numeric_data() {
        @column.NumericData::Int(a) =>
          Series::from_ints(
            operand.name(),
            Array::makei(a.length(), i => int_op(a[i])),
          )
        @column.NumericData::Float(a) =>
          Series::from_floats(
            operand.name(),
            Array::makei(a.length(), i => float_op(a[i])),
          )
      }
    @column.ColumnStorage::Builtin(_) => ()
  }
  let valid = validity_bools(operand)
  let out = match operand.storage().data() {
    // Dtype-gated: a Date column is I64-typed but is not a number.
    @column.ColumnData::I64(a) if operand.dtype().is_numeric() =>
      Series::from_int_options(
        operand.name(),
        map_present(a.length(), valid, i => int_op(a[i])),
      )
    @column.ColumnData::F64(a) =>
      Series::from_float_options(
        operand.name(),
        map_present(a.length(), valid, i => float_op(a[i])),
      )
    @column.ColumnData::I64(_)
    | @column.ColumnData::Bool(_)
    | @column.ColumnData::Utf8(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message("cannot \{verb} \{operand.dtype()}"),
      )
  }
  try_column_to_numeric(out)
}

///|
/// Sign of an `Int64` — `-1` / `0` / `1`.
fn sign_i64(a : Int64) -> Int64 {
  if a > 0L {
    1L
  } else if a < 0L {
    -1L
  } else {
    0L
  }
}

///|
/// Sign of a `Double` — `-1.0` / `0.0` / `1.0`; `NaN` stays `NaN` and `±0.0`
/// gives `0.0`.
fn sign_f64(a : Double) -> Double {
  if a.is_nan() {
    a
  } else if a > 0.0 {
    1.0
  } else if a < 0.0 {
    -1.0
  } else {
    0.0
  }
}

///|
/// Round to `decimals` places, ties to even — the general form behind
/// `Expr::round`. `decimals <= 0` is `round_half_even` itself; otherwise the
/// value is scaled by `10^decimals`, rounded, and unscaled, so the result
/// carries the usual binary-floating-point caveat (`1.005` at two places is
/// whatever the nearest `Double` says it is, exactly as in Polars).
///
/// Total at every input, including every `Int` a caller can pass: a non-finite
/// value passes through, and a place finer than the value's own resolution
/// leaves it untouched rather than perturbing it (`DOUBLE_INTEGRAL_FLOOR` is
/// the cutoff).
///
/// A **negative** `decimals` folds into that first arm rather than being
/// rejected or trusted away. `Expr::round` clamps one to `0` when it builds the
/// node, so the production path never sends one here — but this function is
/// reachable from anywhere in the module, and a negative place underflows
/// `10^decimals` to `0.0`, whose unscaling division would hand back `NaN`.
/// Treating `decimals <= 0` as "round to an integer" is the same answer the
/// clamp gives, established where it cannot be bypassed instead of argued from a
/// caller's behaviour. Past that arm the scale is therefore at least `10`: it can
/// still overflow upward (handled below), but it cannot underflow to `0`.
fn round_places(a : Double, decimals : Int) -> Double {
  if decimals <= 0 {
    return round_half_even(a)
  }
  if a - a != 0.0 {
    return a
  }
  let scale = @math.pow(10.0, decimals.to_double())
  if scale - scale != 0.0 {
    return a
  }
  let scaled = a * scale
  // At or past `2^52` the scaled value is already an integer, so rounding it
  // is a no-op and `a` itself is the exact answer. Returning it is not just a
  // shortcut: scaling up and dividing back rounds twice through a `10^decimals`
  // that is itself inexact above `10^22`, which moves the value by an ulp
  // (`123456.789` at 20 places came back as `123456.78900000002`). Asking for
  // more places than the value can resolve must be the identity. An overflow to
  // infinity lands here too, so it is likewise left alone rather than divided
  // back through infinity.
  if scaled >= DOUBLE_INTEGRAL_FLOOR || scaled <= -DOUBLE_INTEGRAL_FLOOR {
    return a
  }
  round_half_even(scaled) / scale
}

///|
/// `2^52`, the magnitude past which consecutive `Double`s are at least `1.0`
/// apart — so every value at or above it is an integer, with no fractional
/// part left for a decimal place to round.
const DOUBLE_INTEGRAL_FLOOR : Double = 4503599627370496.0

///|
/// Round a `Double` to the nearest integer value, ties to even (banker's
/// rounding — Polars' default). MoonBit's `Double::round` rounds ties toward
/// +inf instead, so the even rule is spelled out here. `±inf` / `NaN` pass
/// through unchanged and `±0.0` keeps its sign; the tie is resolved only on the
/// exactly-half case — the floor when it is already even, else the ceil.
fn round_half_even(a : Double) -> Double {
  // Non-finite passes through: `a - a` is `0.0` only for a finite `a` (both
  // `NaN` and `±inf` yield `NaN`) — the finiteness probe `format_scalar`
  // also uses.
  if a - a != 0.0 {
    return a
  }
  let lo = a.floor()
  let frac = a - lo
  if frac < 0.5 {
    lo
  } else if frac > 0.5 {
    lo + 1.0
  } else if lo % 2.0 == 0.0 {
    lo
  } else {
    // The ceil, spelled as the operation itself: `lo + 1.0` is the same
    // value everywhere except the one tie that lands on zero — `-0.5`,
    // whose even neighbour is `-0.0`, and IEEE addition `-1.0 + 1.0`
    // would return `+0.0`, losing the sign a division can observe.
    a.ceil()
  }
}

///|
/// Build the nullable `Bool` cells of `is_nan` over a numeric operand. `NaN`
/// is a *value*, so a null cell stays null — the probe propagates nulls,
/// unlike `is_null`. A present `Float` cell is tested by IEEE `is_nan`; a
/// present `Int` cell is never `NaN` (so the constant `false`); a non-numeric
/// operand raises `TypeMismatch`. Lands on the nullable `Builtin` backend.
pub fn eval_is_nan(operand : Series) -> Series raise @types.DataError {
  nan_probe(operand, true)
}

///|
/// Build the nullable `Bool` cells of `is_not_nan` — the complement of
/// `eval_is_nan` cell by cell, so a null cell stays null rather than counting
/// as "not NaN". A present `Int` cell is always not-NaN; a non-numeric operand
/// raises `TypeMismatch`. Lands on the nullable `Builtin` backend.
pub fn eval_is_not_nan(operand : Series) -> Series raise @types.DataError {
  nan_probe(operand, false)
}

///|
/// The shared NaN-probe core behind `eval_is_nan` / `eval_is_not_nan`:
/// `want_nan` picks the polarity, the two public entries name it.
fn nan_probe(
  operand : Series,
  want_nan : Bool,
) -> Series raise @types.DataError {
  // `Numeric` fast arm, as in `eval_arith`: all cells present, so the probe
  // is a raw-array pass — an `Int` cell is never NaN, so its arm is the
  // constant `!want_nan` per cell.
  match operand.storage() {
    @column.ColumnStorage::Numeric(x) =>
      return match x.numeric_data() {
        @column.NumericData::Int(a) =>
          Series::from_bools(
            operand.name(),
            Array::makei(a.length(), _ => !want_nan),
          )
        @column.NumericData::Float(a) =>
          Series::from_bools(
            operand.name(),
            Array::makei(a.length(), i => a[i].is_nan() == want_nan),
          )
      }
    @column.ColumnStorage::Builtin(_) => ()
  }
  let valid = validity_bools(operand)
  match operand.storage().data() {
    @column.ColumnData::F64(a) =>
      Series::from_bool_options(
        operand.name(),
        map_present(a.length(), valid, i => a[i].is_nan() == want_nan),
      )
    @column.ColumnData::I64(a) if operand.dtype().is_numeric() =>
      Series::from_bool_options(
        operand.name(),
        map_present(a.length(), valid, _ => !want_nan),
      )
    @column.ColumnData::I64(_)
    | @column.ColumnData::Bool(_)
    | @column.ColumnData::Utf8(_) => {
      let probe = if want_nan { "is_nan" } else { "is_not_nan" }
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "\{probe} requires a numeric operand, got \{operand.dtype()}",
        ),
      )
    }
  }
}
