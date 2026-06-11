///|
/// Vectorized evaluation of `@expr.Expr` against a `DataFrame` — the
/// engine behind `DataFrame::with_columns` (and, as v0.4 grows, every
/// expression consumer: `select_exprs` / `filter_where` / `agg_exprs`).
///
/// This lives in `frame`, not `expr`: evaluation reads `Series` internals
/// (raw `data()` buffers plus validity bitmaps), and that capability —
/// like every DataFrame / Series method — is pinned to this package by
/// method coherence. `expr` stays a pure AST leaf over `types`; this file
/// is the one place that `match`es the tree cross-package (a `pub`
/// read-only enum is matchable here but constructible only in `expr`).
///
/// `scope` is the ordered row-index set an expression is evaluated under:
/// `[0, nrows)` for whole-frame contexts today, a group's row indices once
/// `agg_exprs` lands (E4). Every result is either `|scope|` tall or a
/// length-1 broadcastable (literals now; aggregations in E2+).

///|
/// Evaluate `expr` to a `Series` under `scope`. Callers guarantee every
/// scope index is in `[0, nrows)` (the public consumers build it from
/// `nrows` themselves). Errors — unknown column, dtype mismatch, the
/// unrepresentable `Null` literal — surface here; building the tree was
/// total.
fn eval_expr(
  expr : @expr.Expr,
  df : DataFrame,
  scope : Array[Int],
) -> Series raise @types.DataError {
  match expr {
    @expr.Expr::Col(name) => gather_series(df.get_column(name), scope)
    @expr.Expr::Lit(value) => lit_series(value)
    @expr.Expr::Binary(op, l, r) => {
      let lhs = eval_expr(l, df, scope)
      let rhs = eval_expr(r, df, scope)
      let (left, right) = broadcast_pair(lhs, rhs)
      match op {
        @expr.BinOp::Add => eval_add(left, right)
        @expr.BinOp::And => eval_and(left, right)
      }
    }
  }
}

///|
/// Materialise a literal as a length-1 series. It carries the name
/// `"literal"` (the output-name fallback for column-less expressions);
/// consumers rename the final result via `expr_output_name`, so the name
/// here only shows through for pure-literal expressions. A concrete scalar
/// lands on whatever backend its `Series::from_*` constructor picks.
/// `Scalar::Null` has no column representation — the storage layer has no
/// Null-dtype backend (same gap `DataFrame::empty` reports for Null
/// fields) — so it raises `Unsupported` at evaluation; typed null literals
/// are an E2 question.
fn lit_series(value : @types.Scalar) -> Series raise @types.DataError {
  match value {
    @types.Scalar::Int(v) => Series::from_ints("literal", [v])
    @types.Scalar::Float(v) => Series::from_floats("literal", [v])
    @types.Scalar::Bool(v) => Series::from_bools("literal", [v])
    @types.Scalar::String(v) => Series::from_strings("literal", [v])
    @types.Scalar::Null =>
      raise @types.DataError::Unsupported(
        "cannot evaluate a Null literal: no Null-dtype column backend",
      )
  }
}

///|
/// Align two evaluation results for an elementwise kernel: equal lengths
/// pass through, a length-1 side is broadcast (gathered at index 0) to the
/// other side's length — including to zero rows, where the gather of an
/// empty index set never touches the value. Evaluation invariants make any
/// other shape impossible (both operands of a `Binary` evaluate under the
/// *same* scope, so lengths are drawn from `{1, |scope|}`), but the guard
/// stays: raising `LengthMismatch` keeps the helper total for any input
/// rather than indexing out of bounds. No public call chain can reach that
/// arm, so it is pinned by `expr_eval_wbtest.mbt`.
fn broadcast_pair(
  left : Series,
  right : Series,
) -> (Series, Series) raise @types.DataError {
  let m = left.len()
  let n = right.len()
  if m == n {
    (left, right)
  } else if m == 1 {
    (gather_series(left, Array::make(n, 0)), right)
  } else if n == 1 {
    (left, gather_series(right, Array::make(m, 0)))
  } else {
    raise @types.DataError::LengthMismatch
  }
}

///|
/// `Add` kernel over two equal-length operands (post-`broadcast_pair`).
/// Dtype rules (the v0.4 §0 matrix, S0 subset): `Int + Int → Int`, any
/// `Float` operand promotes the result to `Float`, anything non-numeric is
/// `TypeMismatch`. A null on either side nulls the output cell
/// (Arrow / Polars arithmetic propagation). `Int` addition wraps on
/// overflow (MoonBit `Int64` semantics — total, never aborts); `Float`
/// follows IEEE 754, so NaN propagates as a value. The result is built
/// through the option constructors (`Builtin` backend); the output-backend
/// convention is an E2 decision (v0.3 review Q2).
fn eval_add(left : Series, right : Series) -> Series raise @types.DataError {
  let lv = left.storage().validity().to_bools()
  let rv = right.storage().validity().to_bools()
  match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      Series::from_int_options(
        left.name(),
        Array::makei(a.length(), i => {
          if lv[i] && rv[i] {
            Some(a[i] + b[i])
          } else {
            None
          }
        }),
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        Array::makei(a.length(), i => {
          if lv[i] && rv[i] {
            Some(a[i].to_double() + b[i])
          } else {
            None
          }
        }),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        left.name(),
        Array::makei(a.length(), i => {
          if lv[i] && rv[i] {
            Some(a[i] + b[i].to_double())
          } else {
            None
          }
        }),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        left.name(),
        Array::makei(a.length(), i => {
          if lv[i] && rv[i] {
            Some(a[i] + b[i])
          } else {
            None
          }
        }),
      )
    (_, _) =>
      raise @types.DataError::TypeMismatch(
        "cannot add " +
        left.dtype().to_string() +
        " and " +
        right.dtype().to_string(),
      )
  }
}

///|
/// Kleene `AND` kernel over two equal-length `Bool` operands
/// (post-`broadcast_pair`). Non-`Bool` operands are `TypeMismatch`. Nulls
/// follow three-valued logic via `kleene_and`, so the output is nullable
/// by nature and lands on the `Builtin` backend.
fn eval_and(left : Series, right : Series) -> Series raise @types.DataError {
  let lv = left.storage().validity().to_bools()
  let rv = right.storage().validity().to_bools()
  match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Bool(a), @column.ColumnData::Bool(b)) =>
      Series::from_bool_options(
        left.name(),
        Array::makei(a.length(), i => {
          kleene_and(
            if lv[i] {
              Some(a[i])
            } else {
              None
            },
            if rv[i] {
              Some(b[i])
            } else {
              None
            },
          )
        }),
      )
    (_, _) =>
      raise @types.DataError::TypeMismatch(
        "logical 'and' requires Bool operands, got " +
        left.dtype().to_string() +
        " and " +
        right.dtype().to_string(),
      )
  }
}

///|
/// Kleene three-valued AND over nullable booleans (the Polars / Arrow
/// `and_kleene` table): a known `false` dominates — the result is `false`
/// no matter what the other side holds, null included; two known `true`s
/// are `true`; everything else (a null meeting `true` or another null) is
/// unknown, `None`.
fn kleene_and(a : Bool?, b : Bool?) -> Bool? {
  match (a, b) {
    (Some(false), _) | (_, Some(false)) => Some(false)
    (Some(true), Some(true)) => Some(true)
    _ => None
  }
}

///|
/// The output column name for an expression (Polars' naming rule, S0
/// subset): the leftmost `Col` reference's name, or `"literal"` for a
/// column-less (pure literal) tree. E1's `Alias` variant takes precedence
/// over both once it lands.
fn expr_output_name(expr : @expr.Expr) -> String {
  match leftmost_col_name(expr) {
    Some(name) => name
    None => "literal"
  }
}

///|
/// Depth-first, left-to-right search for the first `Col` in the tree.
fn leftmost_col_name(expr : @expr.Expr) -> String? {
  match expr {
    @expr.Expr::Col(name) => Some(name)
    @expr.Expr::Lit(_) => None
    @expr.Expr::Binary(_, l, r) =>
      match leftmost_col_name(l) {
        Some(name) => Some(name)
        None => leftmost_col_name(r)
      }
  }
}
