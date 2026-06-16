///|
/// Vectorized evaluation of `@expr.Expr` against a `DataFrame` — the
/// engine behind `DataFrame::with_columns` (and every other expression
/// consumer: `select` / `filter` / `agg`).
///
/// This lives in `frame`, not `expr`: evaluation reads `Series` internals
/// (raw `data()` buffers plus validity bitmaps), and that capability —
/// like every DataFrame / Series method — is pinned to this package by
/// method coherence. `expr` stays a pure AST leaf over `types`; this file
/// is the one place that `match`es the tree cross-package (a `pub`
/// read-only enum is matchable here but constructible only in `expr`).
///
/// `scope` is the ordered row-index set an expression is evaluated under:
/// `[0, nrows)` for whole-frame contexts, a group's row indices under
/// `agg`. Every result is either `|scope|` tall or a
/// length-1 broadcastable (literals and aggregations).
///
/// Semantics, in one place (the v0.4 §0 matrix — every rule inherited
/// from the existing `Series` / `Scalar` surface, no new invention):
/// - **Arithmetic** (`+ - *`): `Int op Int → Int`, any `Float` operand
///   promotes to `Float`; a null on either side nulls the output cell;
///   non-numeric operands are `TypeMismatch`. `Int` arithmetic wraps
///   (MoonBit `Int64` — total, never aborts); `Float` follows IEEE 754,
///   so NaN propagates as a value.
/// - **Division** (`/`): always `Float` (Polars `/`), `Int` operands
///   promote; division by zero follows IEEE 754 (`±inf` / `nan`) on every
///   backend — `Int` division by zero is backend-divergent, so it is
///   never emitted.
/// - **Comparisons** (`eq/ne/lt/le/gt/ge`): produce `Bool`; `Int ↔ Float`
///   compare after promotion, `String` compares by `compare_string_lex`
///   (dictionary order, not MoonBit's shortlex), `Bool` orders
///   `false < true`; mixed non-numeric pairs are `TypeMismatch`. A null
///   on either side nulls the cell; NaN is a *value* under IEEE 754
///   (`NaN == NaN` is `false`, every other comparison with NaN is
///   `false`, `ne` is `true`) — exactly `Scalar::eq` / `Scalar::lt`.
/// - **Logic** (`&` / `|` / `not`): `Bool` operands only, Kleene
///   three-valued (`false & null = false`, `true | null = true`,
///   `not(null) = null`).
/// - **Null probes** (`is_null` / `is_not_null`): read validity only —
///   total, the output is never null.
/// - **Aggregations** (`sum/mean/min/max/count`): reduce the operand over
///   the scope to a length-1 column, inheriting the `Series` reduction
///   semantics — `sum` / `mean` propagate NaN and reject non-numeric
///   dtypes, `min` / `max` skip NaN and are total over every dtype,
///   `count` counts non-null cells. One deliberate divergence: an
///   empty / all-null `mean` is a **null cell**, not
///   `InvalidOperation` — per-group reductions (E4) must be able to
///   produce a null for an all-null group, mirroring Polars.
/// - **Map** (`map_elements` / `map_many`, the closure escape hatch): apply
///   an opaque host closure row by row across the input columns (each cell a
///   `Scalar`, a null as `Scalar::Null`, the closure called for every row
///   and free to `raise`). The output dtype is the first non-null result's;
///   an all-null / empty result raises `Unsupported`, having no
///   representable dtype (no Null-dtype backend, as for the `Null` literal).
/// - **Literal series** (`lit_series`): the embedded `Series` is returned
///   verbatim, the data analogue of a scalar literal's length-1 column. Its
///   length is the series' own; the consumers broadcast it like any other
///   result — a length-1 series fills the scope, a frame-tall one passes
///   through, anything else is `LengthMismatch`. It reads no frame column, so
///   evaluation never raises on the frame's contents.
/// - **Backend convention** (the v0.3 review Q2 decision): a *computed*
///   result converges onto the `Numeric` fast path whenever it is an
///   all-valid numeric column (`try_column_to_numeric`), and lands on
///   `Builtin` otherwise (nullable, `Bool`, `String`). `col(...)`
///   references preserve their source backend (`gather_series`), and
///   `cast` follows `Series::cast`.

///|
/// Evaluate `expr` to a `Series` under `scope`. Callers guarantee every
/// scope index is in `[0, nrows)` (the public consumers build it from
/// `nrows` themselves). Errors — unknown column, dtype mismatch, the
/// unrepresentable `Null` literal — surface here; building the tree was
/// total. The dispatch is a closed double `match` (Expr variant × dtype
/// arm in each kernel) with no wildcard over the expression tree, so a
/// future `Expr` variant fails compilation here rather than silently
/// falling through.
fn eval_expr(
  expr : @expr.Expr,
  df : DataFrame,
  scope : Array[Int],
) -> Series raise @types.DataError {
  match expr {
    @expr.Expr::Col(name) => gather_series(df.get_column(name), scope)
    @expr.Expr::Lit(value) => singleton_series(value)
    // A literal series is used verbatim, like a scalar `Lit` is its length-1
    // column: the result's length is the series' own, and the consumers
    // (`broadcast_series` in the verbs, `broadcast_pair` in `Binary`) align
    // it — broadcasting a length-1 series, passing a frame-tall one through,
    // and raising `LengthMismatch` on anything else.
    @expr.Expr::LitSeries(s) => s
    @expr.Expr::Binary(op, l, r) => {
      let lhs = eval_expr(l, df, scope)
      let rhs = eval_expr(r, df, scope)
      let (left, right) = broadcast_pair(lhs, rhs)
      match op {
        @expr.BinOp::Add =>
          eval_arith(left, right, "add", (x, y) => x + y, (x, y) => x + y)
        @expr.BinOp::Sub =>
          eval_arith(left, right, "subtract", (x, y) => x - y, (x, y) => x - y)
        @expr.BinOp::Mul =>
          eval_arith(left, right, "multiply", (x, y) => x * y, (x, y) => x * y)
        @expr.BinOp::Div => eval_div(left, right)
        @expr.BinOp::Eq => eval_compare(left, right, CmpVerb::Eq)
        @expr.BinOp::Ne => eval_compare(left, right, CmpVerb::Ne)
        @expr.BinOp::Lt => eval_compare(left, right, CmpVerb::Lt)
        @expr.BinOp::Le => eval_compare(left, right, CmpVerb::Le)
        @expr.BinOp::Gt => eval_compare(left, right, CmpVerb::Gt)
        @expr.BinOp::Ge => eval_compare(left, right, CmpVerb::Ge)
        @expr.BinOp::And => eval_logic(left, right, "and", kleene_and)
        @expr.BinOp::Or => eval_logic(left, right, "or", kleene_or)
      }
    }
    @expr.Expr::Unary(op, e) => {
      let operand = eval_expr(e, df, scope)
      match op {
        @expr.UnOp::Neg => eval_neg(operand)
        @expr.UnOp::Not => eval_not(operand)
        @expr.UnOp::IsNull =>
          Series::from_bools(
            operand.name(),
            validity_bools(operand.storage()).map(v => !v),
          )
        @expr.UnOp::IsNotNull =>
          Series::from_bools(operand.name(), validity_bools(operand.storage()))
      }
    }
    @expr.Expr::Agg(op, e) => eval_agg(op, eval_expr(e, df, scope))
    @expr.Expr::Cast(e, target) =>
      try_column_to_numeric(eval_expr(e, df, scope).cast(target))
    @expr.Expr::Alias(e, name) => eval_expr(e, df, scope).rename(name)
    @expr.Expr::Ternary(c, t, f) =>
      eval_ternary(
        eval_expr(c, df, scope),
        eval_expr(t, df, scope),
        eval_expr(f, df, scope),
      )
    @expr.Expr::Map(_, inputs, f) => eval_map(inputs, f, df, scope)
  }
}

///|
/// Materialise a scalar literal as a length-1 series — the `Lit` node's
/// column form (named `singleton_series` to keep it distinct from the public
/// `lit_series`, which embeds a whole `Series` as a `LitSeries` node). It
/// carries the name `"literal"` (the output-name fallback for column-less
/// expressions); consumers rename the final result via `expr_output_name`, so
/// the name here only shows through for pure-literal expressions. A concrete
/// scalar lands on whatever backend its `Series::from_*` constructor picks —
/// `Numeric` for `Int` / `Float`, `Builtin` for `Bool` / `String` (the
/// same convention as computed results). `Scalar::Null` has no column
/// representation — the storage layer has no Null-dtype backend (same gap
/// `DataFrame::empty` reports for Null fields) — so it raises
/// `Unsupported` at evaluation; typed null literals stay out of v0.4.
fn singleton_series(value : @types.Scalar) -> Series raise @types.DataError {
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
/// Stretch one evaluation result onto a frame-tall column slot of `target`
/// rows: an already-matching length passes through, a length-1 result (a
/// literal or aggregation) is gathered at index 0 over every row —
/// including to zero rows, where the empty gather never touches the value.
/// As with `broadcast_pair`, evaluation invariants make any other length
/// impossible (a result's length is drawn from `{1, |scope|}` and `target`
/// is `|scope|`), but the guard stays: raising `LengthMismatch` keeps the
/// helper total for any input rather than indexing out of bounds. No public
/// call chain reaches that arm, so it is pinned by `expr_eval_wbtest.mbt`.
fn broadcast_series(s : Series, target : Int) -> Series raise @types.DataError {
  if s.len() == target {
    s
  } else if s.len() == 1 {
    gather_series(s, Array::make(target, 0))
  } else {
    raise @types.DataError::LengthMismatch
  }
}

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
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  let out = match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      Series::from_int_options(
        left.name(),
        Array::makei(a.length(), i => {
          if lv[i] && rv[i] {
            Some(int_op(a[i], b[i]))
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
            Some(float_op(a[i].to_double(), b[i]))
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
            Some(float_op(a[i], b[i].to_double()))
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
            Some(float_op(a[i], b[i]))
          } else {
            None
          }
        }),
      )
    (_, _) =>
      raise @types.DataError::TypeMismatch(
        "cannot " +
        verb +
        " " +
        left.dtype().to_string() +
        " and " +
        right.dtype().to_string(),
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
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  let out = match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        left.name(),
        Array::makei(a.length(), i => {
          if lv[i] && rv[i] {
            Some(a[i].to_double() / b[i].to_double())
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
            Some(a[i].to_double() / b[i])
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
            Some(a[i] / b[i].to_double())
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
            Some(a[i] / b[i])
          } else {
            None
          }
        }),
      )
    (_, _) =>
      raise @types.DataError::TypeMismatch(
        "cannot divide " +
        left.dtype().to_string() +
        " and " +
        right.dtype().to_string(),
      )
  }
  try_column_to_numeric(out)
}

///|
/// Which comparison a `Binary` comparison tag asked for, carried into the
/// shared cell loop. A package-local re-tag of the six `@expr.BinOp`
/// comparison constructors so `compare_cells` can match exhaustively
/// without dead arms for the non-comparison tags (`Add` / `And` / … never
/// reach it).
priv enum CmpVerb {
  Eq
  Ne
  Lt
  Le
  Gt
  Ge
}

///|
/// Build the `Bool?` cells of one comparison over two equal-length
/// operands, given a cell reader per side and the dtype's two primitive
/// predicates. Everything derives from `lt` / `eq` with arguments in both
/// orders — `Gt` is `lt(y, x)`, not `!(lt ∨ eq)` — so IEEE NaN falls out
/// right: NaN is a *value* (the cell stays non-null), `eq` / `lt` against
/// it are `false`, hence `Ne` is `true` and every ordering comparison is
/// `false`. A null on either side nulls the cell before the predicates
/// run.
fn[T] compare_cells(
  n : Int,
  lv : Array[Bool],
  rv : Array[Bool],
  get_left : (Int) -> T,
  get_right : (Int) -> T,
  lt : (T, T) -> Bool,
  eq : (T, T) -> Bool,
  verb : CmpVerb,
) -> Array[Bool?] {
  Array::makei(n, i => {
    if lv[i] && rv[i] {
      let x = get_left(i)
      let y = get_right(i)
      Some(
        match verb {
          CmpVerb::Eq => eq(x, y)
          CmpVerb::Ne => !eq(x, y)
          CmpVerb::Lt => lt(x, y)
          CmpVerb::Le => lt(x, y) || eq(x, y)
          CmpVerb::Gt => lt(y, x)
          CmpVerb::Ge => lt(y, x) || eq(x, y)
        },
      )
    } else {
      None
    }
  })
}

///|
/// Comparison kernel over two equal-length operands
/// (post-`broadcast_pair`), producing a nullable `Bool` column. The dtype
/// matrix mirrors `Scalar::eq` / `Scalar::lt` (the `Scalar` comparison
/// precedent): `Int ↔ Float` compare after promoting `Int` to `Double`,
/// `String` compares by `compare_string_lex` (dictionary order — MoonBit's
/// built-in `String` order is shortlex), `Bool` orders `false < true`,
/// and any other pairing — including `Bool` / `String` against numbers —
/// raises `TypeMismatch`. Null and NaN behavior live in `compare_cells`.
fn eval_compare(
  left : Series,
  right : Series,
  verb : CmpVerb,
) -> Series raise @types.DataError {
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  let cells = match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i],
        i => b[i],
        (x, y) => x < y,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i].to_double(),
        i => b[i],
        (x, y) => x < y,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i],
        i => b[i].to_double(),
        (x, y) => x < y,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i],
        i => b[i],
        (x, y) => x < y,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::Bool(a), @column.ColumnData::Bool(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i],
        i => b[i],
        (x, y) => !x && y,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::String(a), @column.ColumnData::String(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i],
        i => b[i],
        (x, y) => @types.compare_string_lex(x, y) < 0,
        (x, y) => x == y,
        verb,
      )
    (_, _) =>
      raise @types.DataError::TypeMismatch(
        "cannot compare " +
        left.dtype().to_string() +
        " and " +
        right.dtype().to_string(),
      )
  }
  Series::from_bool_options(left.name(), cells)
}

///|
/// Kleene logic kernel over two equal-length `Bool` operands
/// (post-`broadcast_pair`); `&` and `|` differ only in the nullable cell
/// combiner (`kleene_and` / `kleene_or`) and the verb their `TypeMismatch`
/// message names. Non-`Bool` operands raise. The output is nullable by
/// nature and lands on the `Builtin` backend.
fn eval_logic(
  left : Series,
  right : Series,
  verb : String,
  combine : (Bool?, Bool?) -> Bool?,
) -> Series raise @types.DataError {
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Bool(a), @column.ColumnData::Bool(b)) =>
      Series::from_bool_options(
        left.name(),
        Array::makei(a.length(), i => {
          combine(
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
        "logical '" +
        verb +
        "' requires Bool operands, got " +
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
/// Kleene three-valued OR over nullable booleans (the `or_kleene` dual):
/// a known `true` dominates regardless of the other side, null included;
/// two known `false`s are `false`; everything else is unknown, `None`.
fn kleene_or(a : Bool?, b : Bool?) -> Bool? {
  match (a, b) {
    (Some(true), _) | (_, Some(true)) => Some(true)
    (Some(false), Some(false)) => Some(false)
    _ => None
  }
}

///|
/// Numeric negation kernel. `Int` negation wraps on `Int64` minimum
/// (MoonBit semantics — total, never aborts); `Float` follows IEEE 754,
/// so `-NaN` is still NaN and `-0.0` is the negative zero. A null cell
/// stays null; non-numeric operands raise. An all-valid result converges
/// onto the `Numeric` backend, as for binary arithmetic.
fn eval_neg(operand : Series) -> Series raise @types.DataError {
  let valid = validity_bools(operand.storage())
  let out = match operand.storage().data() {
    @column.ColumnData::Int(a) =>
      Series::from_int_options(
        operand.name(),
        Array::makei(a.length(), i => if valid[i] { Some(-a[i]) } else { None }),
      )
    @column.ColumnData::Float(a) =>
      Series::from_float_options(
        operand.name(),
        Array::makei(a.length(), i => if valid[i] { Some(-a[i]) } else { None }),
      )
    _ =>
      raise @types.DataError::TypeMismatch(
        "cannot negate " + operand.dtype().to_string(),
      )
  }
  try_column_to_numeric(out)
}

///|
/// Kleene logical negation kernel: `not(true) = false`, `not(false) =
/// true`, `not(null) = null`. Non-`Bool` operands raise.
fn eval_not(operand : Series) -> Series raise @types.DataError {
  let valid = validity_bools(operand.storage())
  match operand.storage().data() {
    @column.ColumnData::Bool(a) =>
      Series::from_bool_options(
        operand.name(),
        Array::makei(a.length(), i => if valid[i] { Some(!a[i]) } else { None }),
      )
    _ =>
      raise @types.DataError::TypeMismatch(
        "logical 'not' requires a Bool operand, got " +
        operand.dtype().to_string(),
      )
  }
}

///|
/// Reduce an evaluated operand (length `|scope|`) to a length-1 column — the
/// point where group scopes (E4) and whole-frame scopes share one path.
/// Delegates to the shared `reducer_for` kernel (the same one `Series::sum` /
/// `mean` / `min` / `max` and the grouped `agg` reduce through),
/// then projects the reduced `Scalar` into a length-1 column with
/// `scalars_to_series`. Inherits the kernel's dtype / null / `NaN` rules:
/// - `Sum`: `Int → Int`, `Float → Float`, nulls skipped, `NaN` propagates;
///   an empty / all-null operand sums to the additive identity. Non-numeric
///   raises `TypeMismatch`.
/// - `Mean`: always `Float`, nulls skipped from both numerator and
///   denominator, `NaN` propagates. An empty / all-null operand yields a
///   **null cell** — deliberately not `Series::mean`'s `InvalidOperation`,
///   because a per-group reduction must produce a value slot for an all-null
///   group (Polars `mean` semantics). Non-numeric raises `TypeMismatch`.
/// - `Min` / `Max`: total over every dtype in the operand's own dtype, `NaN`
///   skipped; empty / all-null / all-`NaN` reduces to a null cell.
/// - `Count`: the non-null cell count, never null.
/// Numeric outputs converge onto the `Numeric` backend, the expression-engine
/// convention for computed columns; consumers broadcast the length-1 result
/// back over their scope.
fn eval_agg(
  op : @expr.AggOp,
  operand : Series,
) -> Series raise @types.DataError {
  let (reducer, probe) = reducer_for(operand.storage(), reduce_op_of_agg(op))
  let cell = reducer(operand.len(), k => k)
  scalars_to_series(probe, operand.name(), [cell])
}

///|
/// Map the read-only `@expr.AggOp` (matchable here, constructible only in
/// `expr`) into the frame-local `ReduceOp` the shared reduction kernel
/// speaks. Shared by the scoped `eval_agg` and the grouped `agg`
/// single-pass fast path (`bare_col_agg`), so the two map the same op the
/// same way. Exhaustive with no wildcard: a future `AggOp` variant fails
/// compilation here rather than silently routing to a wrong reduction.
fn reduce_op_of_agg(op : @expr.AggOp) -> ReduceOp {
  match op {
    @expr.AggOp::Sum => ReduceOp::Sum
    @expr.AggOp::Mean => ReduceOp::Mean
    @expr.AggOp::Min => ReduceOp::Min
    @expr.AggOp::Max => ReduceOp::Max
    @expr.AggOp::Count => ReduceOp::Count
  }
}

///|
/// Build the cells of a conditional: where the condition is null the
/// output is null (Kleene: the branch is unknown), where it is `true` /
/// `false` the cell comes from the matching branch reader — which itself
/// yields `None` for a null branch cell.
fn[T] select_cells(
  cond : Array[Bool],
  cond_valid : Array[Bool],
  get_then : (Int) -> T?,
  get_else : (Int) -> T?,
) -> Array[T?] {
  Array::makei(cond.length(), i => {
    if !cond_valid[i] {
      None
    } else if cond[i] {
      get_then(i)
    } else {
      get_else(i)
    }
  })
}

///|
/// `when(cond).then(a).otherwise(b)` kernel. The three operands evaluate
/// under one scope, so lengths are drawn from `{1, |scope|}`; two
/// `broadcast_pair` passes plus one stretch of the `then` branch align
/// them (the stretch only fires when the condition and `then` are both
/// length-1 literals against a column-length `otherwise`). The condition
/// must be `Bool`; a null condition cell nulls the output. The branches
/// must share a dtype, except that `Int` meets `Float` by promoting to
/// `Float` — the arithmetic promotion rule applied to selection. An
/// all-valid numeric result converges onto the `Numeric` backend.
fn eval_ternary(
  cond : Series,
  then_v : Series,
  else_v : Series,
) -> Series raise @types.DataError {
  let (c1, t1) = broadcast_pair(cond, then_v)
  let (c2, e2) = broadcast_pair(c1, else_v)
  let t2 = if t1.len() == c2.len() {
    t1
  } else {
    gather_series(t1, Array::make(c2.len(), 0))
  }
  let cond_cells = match c2.storage().data() {
    @column.ColumnData::Bool(a) => a
    _ =>
      raise @types.DataError::TypeMismatch(
        "when condition must be Bool, got " + c2.dtype().to_string(),
      )
  }
  let cv = validity_bools(c2.storage())
  let tv = validity_bools(t2.storage())
  let ev = validity_bools(e2.storage())
  let out = match (t2.storage().data(), e2.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      Series::from_int_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i].to_double()) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i].to_double()) } else { None },
        ),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::Bool(a), @column.ColumnData::Bool(b)) =>
      Series::from_bool_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::String(a), @column.ColumnData::String(b)) =>
      Series::from_string_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (_, _) =>
      raise @types.DataError::TypeMismatch(
        "when/then/otherwise branches do not unify: " +
        t2.dtype().to_string() +
        " and " +
        e2.dtype().to_string(),
      )
  }
  try_column_to_numeric(out)
}

///|
/// Evaluate a `Map` escape-hatch node: apply the opaque closure `f` to each
/// row across `inputs`. Every input is evaluated under the shared `scope`
/// (so a failing input — unknown column, dtype mismatch — propagates), then
/// stretched to a common height: any column-tall input fixes it (all share
/// `scope`, so a non-1 length is `|scope|`), while all-length-1 inputs (or
/// none at all) keep height 1 — the literal / aggregation broadcast rule.
/// Each row hands `f` one cell per input, in order, a null cell as
/// `Scalar::Null`; `f` runs for every row and may `raise`.
///
/// The output dtype is inferred from the first non-null `Scalar` the closure
/// returns, then `scalars_to_series` projects the cells onto it (an off-type
/// cell becomes null; an all-valid numeric result converges onto `Numeric`).
/// An all-null or empty result has no representable dtype — there is no
/// Null-dtype column backend — so it raises `Unsupported`, exactly as the
/// `Null` literal does. The column is named after the leftmost input (or
/// `"literal"` when there are none), agreeing with `Expr::output_name`; the
/// consuming verb renames it through `expr_output_name` regardless.
fn eval_map(
  inputs : Array[@expr.Expr],
  f : (Array[@types.Scalar]) -> @types.Scalar raise @types.DataError,
  df : DataFrame,
  scope : Array[Int],
) -> Series raise @types.DataError {
  let evaluated : Array[Series] = []
  for input in inputs {
    evaluated.push(eval_expr(input, df, scope))
  }
  let mut height = 1
  for s in evaluated {
    if s.len() != 1 {
      height = s.len()
    }
  }
  let columns : Array[Array[@types.Scalar]] = []
  for s in evaluated {
    columns.push(broadcast_series(s, height).to_scalars())
  }
  let width = columns.length()
  let cells : Array[@types.Scalar] = []
  for i in 0..<height {
    cells.push(f(Array::makei(width, k => columns[k][i])))
  }
  let name = if evaluated.is_empty() { "literal" } else { evaluated[0].name() }
  match infer_map_dtype(cells) {
    Some(probe) => scalars_to_series(probe, name, cells)
    None =>
      raise @types.DataError::Unsupported(
        "cannot infer the dtype of a map result with no non-null cell: no Null-dtype column backend",
      )
  }
}

///|
/// The output-column probe for a map result: the first non-null cell fixes
/// the dtype (`Int` / `Float` / `Bool` / `String`); an all-null or empty
/// cell list yields `None`, which `eval_map` turns into `Unsupported`.
fn infer_map_dtype(cells : Array[@types.Scalar]) -> @column.ColumnData? {
  for cell in cells {
    match cell {
      @types.Scalar::Int(_) => return Some(@column.ColumnData::Int([]))
      @types.Scalar::Float(_) => return Some(@column.ColumnData::Float([]))
      @types.Scalar::Bool(_) => return Some(@column.ColumnData::Bool([]))
      @types.Scalar::String(_) => return Some(@column.ColumnData::String([]))
      @types.Scalar::Null => ()
    }
  }
  None
}

///|
/// The output column name for an expression (Polars' naming rule): an
/// alias wins, otherwise the leftmost column reference's name, otherwise
/// `"literal"` for a column-less tree. Delegates to `Expr::output_name` —
/// the rule lives in `expr`, beside `referenced_columns`, so the eager
/// materialisers here and the lazy optimizer's column pruning (which must
/// know the names a deferred `with_columns` defines) can never drift
/// apart.
fn expr_output_name(expr : @expr.Expr) -> String {
  expr.output_name()
}
