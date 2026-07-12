///|
/// Numeric-operand kernels for the expression evaluator: the elementwise
/// arithmetic (`+` / `-` / `*`), division (`/`), unary negation, and the
/// `is_nan` / `is_not_nan` probes. Each carries a `Numeric`×`Numeric` all-valid
/// fast arm that stays on the `Numeric` backend and a nullable general arm that
/// re-converges through `try_column_to_numeric`. The shared cell gates
/// (`zip_present` / `map_present`) and the `binary_type_mismatch_msg` wording
/// live with the evaluator shell in `expr_eval.mbt`.

///|
/// Shared kernel for `+` / `-` / `*` over two equal-length operands
/// (post-`broadcast_pair`); each operator supplies its `Int64` and
/// `Double` cell ops plus the verb its `TypeMismatch` message uses.
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
  // `Numeric`×`Numeric` fast arm: both operands are all-valid by
  // construction, so the result is too — compute it in one pass over the
  // raw arrays and land straight back on the `Numeric` backend, skipping
  // the two validity materialisations, the `Option` boxing, and the
  // popcount re-convergence the general arm below pays. `NumericData` has
  // exactly the two numeric arms, so the inner dispatch is exhaustive with
  // no dead arm; `Bool` / `String` columns are never `Numeric`-backed and
  // raise in the general arm as before.
  match (left.storage(), right.storage()) {
    (@column.ColumnStorage::Numeric(x), @column.ColumnStorage::Numeric(y)) =>
      return match (x.data, y.data) {
        (@column.NumericData::Int(a), @column.NumericData::Int(b)) =>
          Series::from_ints(
            left.name(),
            Array::makei(a.length(), i => int_op(a[i], b[i])),
          )
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
      }
    (@column.ColumnStorage::Builtin(_), _)
    | (_, @column.ColumnStorage::Builtin(_)) => ()
  }
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  let out = match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      Series::from_int_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => int_op(a[i], b[i])),
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => float_op(a[i].to_double(), b[i])),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => float_op(a[i], b[i].to_double())),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => float_op(a[i], b[i])),
      )
    (@column.ColumnData::Bool(_) | @column.ColumnData::String(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::String(_)) =>
      raise @types.DataError::TypeMismatch(
        binary_type_mismatch_msg(verb, left, right),
      )
  }
  try_column_to_numeric(out)
}

///|
/// `Div` kernel over two equal-length operands (post-`broadcast_pair`).
/// Not an `eval_arith` instance because it is the one operator whose
/// `Int, Int` arm produces `Float`: division is **always** `Float`
/// (Polars `/`), so every numeric pair divides in `Double` and division
/// by zero follows IEEE 754 — `x/0 → ±inf`, `0/0 → NaN` — on every
/// backend rather than trapping (`Int` division by zero is
/// backend-divergent, so it is never emitted). Null propagation, the
/// non-numeric `TypeMismatch`, and the `Numeric` re-convergence match
/// `eval_arith`.
fn eval_div(left : Series, right : Series) -> Series raise @types.DataError {
  // `Numeric`×`Numeric` fast arm (see `eval_arith`): every pairing divides
  // in `Double`, so all four arms land on `from_floats`.
  match (left.storage(), right.storage()) {
    (@column.ColumnStorage::Numeric(x), @column.ColumnStorage::Numeric(y)) =>
      return match (x.data, y.data) {
        (@column.NumericData::Int(a), @column.NumericData::Int(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => a[i].to_double() / b[i].to_double()),
          )
        (@column.NumericData::Int(a), @column.NumericData::Float(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => a[i].to_double() / b[i]),
          )
        (@column.NumericData::Float(a), @column.NumericData::Int(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => a[i] / b[i].to_double()),
          )
        (@column.NumericData::Float(a), @column.NumericData::Float(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => a[i] / b[i]),
          )
      }
    (@column.ColumnStorage::Builtin(_), _)
    | (_, @column.ColumnStorage::Builtin(_)) => ()
  }
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  let out = match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => a[i].to_double() / b[i].to_double()),
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => a[i].to_double() / b[i]),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => a[i] / b[i].to_double()),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => a[i] / b[i]),
      )
    (@column.ColumnData::Bool(_) | @column.ColumnData::String(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::String(_)) =>
      raise @types.DataError::TypeMismatch(
        binary_type_mismatch_msg("divide", left, right),
      )
  }
  try_column_to_numeric(out)
}

///|
/// `Mod` kernel — remainder (see `Expr::modulo`). Same-dtype `Int / Int → Int`
/// carrying the dividend's sign; any `Float` operand promotes to `Float` (IEEE
/// remainder). `Int` modulo by zero produces a **null** cell (as for
/// `floor_div`), so an all-valid `Int / Int` pair can still yield nulls;
/// `Float` modulo by zero is `NaN`. Structure matches `eval_floor_div`.
fn eval_mod(left : Series, right : Series) -> Series raise @types.DataError {
  match (left.storage(), right.storage()) {
    (@column.ColumnStorage::Numeric(x), @column.ColumnStorage::Numeric(y)) =>
      return match (x.data, y.data) {
        (@column.NumericData::Int(a), @column.NumericData::Int(b)) =>
          try_column_to_numeric(
            Series::from_int_options(
              left.name(),
              Array::makei(a.length(), i => {
                if b[i] == 0L {
                  None
                } else {
                  Some(a[i] % b[i])
                }
              }),
            ),
          )
        (@column.NumericData::Int(a), @column.NumericData::Float(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => a[i].to_double() % b[i]),
          )
        (@column.NumericData::Float(a), @column.NumericData::Int(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => a[i] % b[i].to_double()),
          )
        (@column.NumericData::Float(a), @column.NumericData::Float(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => a[i] % b[i]),
          )
      }
    (@column.ColumnStorage::Builtin(_), _)
    | (_, @column.ColumnStorage::Builtin(_)) => ()
  }
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  let out = match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      Series::from_int_options(
        left.name(),
        Array::makei(a.length(), i => {
          if lv[i] && rv[i] && b[i] != 0L {
            Some(a[i] % b[i])
          } else {
            None
          }
        }),
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => a[i].to_double() % b[i]),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => a[i] % b[i].to_double()),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => a[i] % b[i]),
      )
    (@column.ColumnData::Bool(_) | @column.ColumnData::String(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::String(_)) =>
      raise @types.DataError::TypeMismatch(
        binary_type_mismatch_msg("take the remainder of", left, right),
      )
  }
  try_column_to_numeric(out)
}

///|
/// `Pow` kernel — exponentiation, **always `Float`** (see `Expr::pow`). Every
/// numeric pair raises in `Double` (`a.pow(b)`), total under IEEE 754. Null
/// propagation, the non-numeric `TypeMismatch`, and the `Numeric`
/// re-convergence match `eval_div`.
fn eval_pow(left : Series, right : Series) -> Series raise @types.DataError {
  match (left.storage(), right.storage()) {
    (@column.ColumnStorage::Numeric(x), @column.ColumnStorage::Numeric(y)) =>
      return match (x.data, y.data) {
        (@column.NumericData::Int(a), @column.NumericData::Int(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => {
              @math.pow(a[i].to_double(), b[i].to_double())
            }),
          )
        (@column.NumericData::Int(a), @column.NumericData::Float(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => @math.pow(a[i].to_double(), b[i])),
          )
        (@column.NumericData::Float(a), @column.NumericData::Int(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => @math.pow(a[i], b[i].to_double())),
          )
        (@column.NumericData::Float(a), @column.NumericData::Float(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => @math.pow(a[i], b[i])),
          )
      }
    (@column.ColumnStorage::Builtin(_), _)
    | (_, @column.ColumnStorage::Builtin(_)) => ()
  }
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  let out = match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => {
          @math.pow(a[i].to_double(), b[i].to_double())
        }),
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => @math.pow(a[i].to_double(), b[i])),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => @math.pow(a[i], b[i].to_double())),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => @math.pow(a[i], b[i])),
      )
    (@column.ColumnData::Bool(_) | @column.ColumnData::String(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::String(_)) =>
      raise @types.DataError::TypeMismatch(
        binary_type_mismatch_msg("exponentiate", left, right),
      )
  }
  try_column_to_numeric(out)
}

///|
/// `a // b` for two `Int64`s, rounding toward −∞ rather than the truncation
/// `Int64::/` gives. The caller has already excluded a zero divisor.
/// `Int64::MIN // -1` wraps like every other `Int64` overflow (total, never
/// aborts).
fn floor_div_i64(a : Int64, b : Int64) -> Int64 {
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
/// `FloorDiv` kernel over two equal-length operands (post-`broadcast_pair`).
/// Same-dtype `Int / Int → Int` (floor toward −∞); any `Float` operand
/// promotes to `Float` (`(a / b).floor()`). `Int` division by zero produces a
/// **null** cell (no integer infinity, and a backend integer divide by zero
/// traps), so even an all-valid `Int / Int` pair can yield nulls; `Float`
/// division by zero follows IEEE 754 (`±inf` / `nan`) and stays a value. Null
/// propagation, the non-numeric `TypeMismatch`, and the `Numeric`
/// re-convergence match `eval_arith`.
fn eval_floor_div(
  left : Series,
  right : Series,
) -> Series raise @types.DataError {
  match (left.storage(), right.storage()) {
    (@column.ColumnStorage::Numeric(x), @column.ColumnStorage::Numeric(y)) =>
      return match (x.data, y.data) {
        // A zero divisor nulls its cell, so an all-valid pair can still leave
        // the `Numeric` fast path — re-converge afterwards.
        (@column.NumericData::Int(a), @column.NumericData::Int(b)) =>
          try_column_to_numeric(
            Series::from_int_options(
              left.name(),
              Array::makei(a.length(), i => {
                if b[i] == 0L {
                  None
                } else {
                  Some(floor_div_i64(a[i], b[i]))
                }
              }),
            ),
          )
        (@column.NumericData::Int(a), @column.NumericData::Float(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => (a[i].to_double() / b[i]).floor()),
          )
        (@column.NumericData::Float(a), @column.NumericData::Int(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => (a[i] / b[i].to_double()).floor()),
          )
        (@column.NumericData::Float(a), @column.NumericData::Float(b)) =>
          Series::from_floats(
            left.name(),
            Array::makei(a.length(), i => (a[i] / b[i]).floor()),
          )
      }
    (@column.ColumnStorage::Builtin(_), _)
    | (_, @column.ColumnStorage::Builtin(_)) => ()
  }
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  let out = match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      Series::from_int_options(
        left.name(),
        Array::makei(a.length(), i => {
          if lv[i] && rv[i] && b[i] != 0L {
            Some(floor_div_i64(a[i], b[i]))
          } else {
            None
          }
        }),
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => (a[i].to_double() / b[i]).floor()),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => (a[i] / b[i].to_double()).floor()),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        zip_present(a.length(), lv, rv, i => (a[i] / b[i]).floor()),
      )
    (@column.ColumnData::Bool(_) | @column.ColumnData::String(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::String(_)) =>
      raise @types.DataError::TypeMismatch(
        binary_type_mismatch_msg("floor-divide", left, right),
      )
  }
  try_column_to_numeric(out)
}

///|
/// Numeric negation kernel. `Int` negation wraps on `Int64` minimum
/// (MoonBit semantics — total, never aborts); `Float` follows IEEE 754,
/// so `-NaN` is still NaN and `-0.0` is the negative zero. A null cell
/// stays null; non-numeric operands raise. An all-valid result converges
/// onto the `Numeric` backend, as for binary arithmetic.
fn eval_neg(operand : Series) -> Series raise @types.DataError {
  eval_unary_num(operand, "negate", a => -a, a => -a)
}

///|
/// Shared kernel for a numeric unary op (`neg` / `abs` / `floor` / `ceil` /
/// `sign`): each supplies its `Int64` and `Double` cell op plus the verb its
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
      return match x.data {
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
  let valid = validity_bools(operand.storage())
  let out = match operand.storage().data() {
    @column.ColumnData::Int(a) =>
      Series::from_int_options(
        operand.name(),
        map_present(a.length(), valid, i => int_op(a[i])),
      )
    @column.ColumnData::Float(a) =>
      Series::from_float_options(
        operand.name(),
        map_present(a.length(), valid, i => float_op(a[i])),
      )
    @column.ColumnData::Bool(_) | @column.ColumnData::String(_) =>
      raise @types.DataError::TypeMismatch("cannot \{verb} \{operand.dtype()}")
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
/// Build the nullable `Bool` cells of `is_nan` (`want_nan = true`) or
/// `is_not_nan` (`want_nan = false`) over a numeric operand. `NaN` is a
/// *value*, so a null cell stays null — the probe propagates nulls, unlike
/// `is_null`. A present `Float` cell is tested by IEEE `is_nan`; a present
/// `Int` cell is never `NaN` (so the constant `!want_nan`); a non-numeric
/// operand raises `TypeMismatch`. Lands on the nullable `Builtin` backend.
fn eval_is_nan(
  operand : Series,
  want_nan : Bool,
) -> Series raise @types.DataError {
  // `Numeric` fast arm (see `eval_arith`): all cells present, so the probe
  // is a raw-array pass — an `Int` cell is never NaN, so its arm is the
  // constant `!want_nan` per cell.
  match operand.storage() {
    @column.ColumnStorage::Numeric(x) =>
      return match x.data {
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
  let valid = validity_bools(operand.storage())
  match operand.storage().data() {
    @column.ColumnData::Float(a) =>
      Series::from_bool_options(
        operand.name(),
        map_present(a.length(), valid, i => a[i].is_nan() == want_nan),
      )
    @column.ColumnData::Int(a) =>
      Series::from_bool_options(
        operand.name(),
        map_present(a.length(), valid, _ => !want_nan),
      )
    @column.ColumnData::Bool(_) | @column.ColumnData::String(_) => {
      let probe = if want_nan { "is_nan" } else { "is_not_nan" }
      raise @types.DataError::TypeMismatch(
        "\{probe} requires a numeric operand, got \{operand.dtype()}",
      )
    }
  }
}
