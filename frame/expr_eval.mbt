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
/// - **String namespace** (`str_to_uppercase` / `str_contains` / …): apply a
///   `StrOp` to each cell of a String operand — case (`to_uppercase` /
///   `to_lowercase`), `strip_chars` (ASCII whitespace), `len_chars` (an Int
///   Unicode-character count), the literal predicates `contains` /
///   `starts_with` / `ends_with` (Bool), and the literal substitutions
///   `replace` (first) / `replace_all` (all). Null cells stay null, a
///   non-String operand is a `TypeMismatch`, all are total (no value can
///   raise), and matching is always literal — there is no regex engine yet.
/// - **Aggregations** (`sum/mean/min/max/count/std/var/median/n_unique/
///   first/last`): reduce the operand over
///   the scope to a length-1 column through the shared `reduce.mbt` kernel —
///   `sum` / `mean` / `std` / `var` propagate NaN and reject non-numeric
///   dtypes, `min` / `max` / `median` skip NaN (`median` numeric-only),
///   `count` counts non-null cells, `n_unique` the distinct non-null values,
///   and `first` / `last` are positional. One deliberate divergence: an
///   empty / all-null `mean` is a **null cell**, not
///   `InvalidOperation` — per-group reductions (E4) must be able to
///   produce a null for an all-null group, mirroring Polars.
/// - **Map** (`map_elements` / `map_many`, the closure escape hatch): apply
///   an opaque host closure row by row across the input columns (each cell a
///   `Scalar`, a null as `Scalar::Null`, the closure called for every row
///   and free to `raise`). The output dtype is the first non-null result's,
///   except that a mix of `Int` and `Float` results promotes to `Float` (the
///   engine's `Int ↔ Float` rule) rather than nulling the minority. An
///   all-null result over a non-empty scope raises `Unsupported`, having no
///   representable dtype (no Null-dtype backend, as for the `Null` literal);
///   over an *empty* scope the closure never runs, so the dtype is mirrored
///   from the leftmost input and the result is an empty column.
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
        @expr.UnOp::IsNan => eval_is_nan(operand, true)
        @expr.UnOp::IsNotNan => eval_is_nan(operand, false)
      }
    }
    @expr.Expr::Agg(op, e) => eval_agg(op, eval_expr(e, df, scope))
    @expr.Expr::Str(op, e) => eval_str(op, eval_expr(e, df, scope))
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
/// empty index set never touches the value. For most operands both sides of
/// a `Binary` evaluate under the *same* scope, so their lengths are drawn
/// from `{1, |scope|}` and always align; a `lit_series` is the exception — it
/// evaluates at the embedded series' own length — so a public
/// `lit_series(len2) + lit_series(len3)` reaches the mismatch arm, which
/// raises `LengthMismatch` (keeping the helper total rather than indexing out
/// of bounds). Covered by `lit_series_test.mbt` (public path) and
/// `expr_eval_wbtest.mbt` (the helper directly).
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
/// Most results' lengths are drawn from `{1, |scope|}` (with `target =
/// |scope|`) and always fit; a `lit_series` is the exception — it evaluates
/// at the embedded series' own length — so a public
/// `df.with_columns([lit_series(len2)])` on an off-length frame reaches the
/// mismatch arm, which raises `LengthMismatch` (keeping the helper total
/// rather than indexing out of bounds). Covered by `lit_series_test.mbt`
/// (public path) and `expr_eval_wbtest.mbt` (the helper directly).
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
/// Build the cells of a binary elementwise op: index `i` is `Some(f(i))` when
/// both operands are present there, else `None` — the Arrow / Polars rule that
/// a null on either side nulls the output cell. The shared null-gate behind the
/// arithmetic (`eval_arith`) and division (`eval_div`) kernels, so each dtype
/// arm supplies only its per-cell op. Total — `f` only reads two present cells.
fn[T] zip_present(
  n : Int,
  lv : Array[Bool],
  rv : Array[Bool],
  f : (Int) -> T,
) -> Array[T?] {
  Array::makei(n, i => if lv[i] && rv[i] { Some(f(i)) } else { None })
}

///|
/// The `TypeMismatch` message a binary numeric / ordering kernel raises when
/// its operands are not a supported pair: `cannot <verb> <left> and <right>`.
/// Shared by `eval_arith`, `eval_div`, and `eval_compare` so the wording stays
/// identical across them. (`eval_logic`'s message names the Bool requirement
/// instead, so it keeps its own.)
fn binary_type_mismatch_msg(
  verb : String,
  left : Series,
  right : Series,
) -> String {
  "cannot " +
  verb +
  " " +
  left.dtype().to_string() +
  " and " +
  right.dtype().to_string()
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
    (_, _) =>
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
    (_, _) =>
      raise @types.DataError::TypeMismatch(
        binary_type_mismatch_msg("divide", left, right),
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
        binary_type_mismatch_msg("compare", left, right),
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
/// Build the cells of a unary elementwise op: index `i` is `Some(f(i))` when the
/// operand is present there, else `None` — a null cell maps to a null result.
/// The shared null-gate behind the negation (`eval_neg`), logical-not
/// (`eval_not`), and string-namespace (`eval_str`) kernels, so each arm supplies
/// only its per-cell map. The single-operand sibling of `zip_present`. Total —
/// `f` only reads a present cell.
fn[T] map_present(n : Int, valid : Array[Bool], f : (Int) -> T) -> Array[T?] {
  Array::makei(n, i => if valid[i] { Some(f(i)) } else { None })
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
        map_present(a.length(), valid, i => -a[i]),
      )
    @column.ColumnData::Float(a) =>
      Series::from_float_options(
        operand.name(),
        map_present(a.length(), valid, i => -a[i]),
      )
    _ =>
      raise @types.DataError::TypeMismatch(
        "cannot negate " + operand.dtype().to_string(),
      )
  }
  try_column_to_numeric(out)
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
    _ =>
      raise @types.DataError::TypeMismatch(
        (if want_nan { "is_nan" } else { "is_not_nan" }) +
        " requires a numeric operand, got " +
        operand.dtype().to_string(),
      )
  }
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
        map_present(a.length(), valid, i => !a[i]),
      )
    _ =>
      raise @types.DataError::TypeMismatch(
        "logical 'not' requires a Bool operand, got " +
        operand.dtype().to_string(),
      )
  }
}

///|
/// Elementwise string-namespace kernel: apply `op` to each cell of a String
/// operand. The operand must be `String` — any other dtype is a
/// `TypeMismatch`, decided once for the whole column (scope-independent, so
/// the optimizer treats a `Str` node as row-stable). A null cell maps to a
/// null result; a present cell maps through the underlying total `String`
/// method, so no value can raise. `ToUppercase` / `ToLowercase` /
/// `StripChars` / `Replace` / `ReplaceAll` produce a String column,
/// `LenChars` an Int (the Unicode character count — an all-valid result
/// converges onto the `Numeric` fast path like every computed numeric), and
/// the `Contains` / `StartsWith` / `EndsWith` predicates a Bool. Matching is
/// always literal (no regex engine yet).
fn eval_str(
  op : @expr.StrOp,
  operand : Series,
) -> Series raise @types.DataError {
  let data = match operand.storage().data() {
    @column.ColumnData::String(a) => a
    _ =>
      raise @types.DataError::TypeMismatch(
        "string operation requires a String operand, got " +
        operand.dtype().to_string(),
      )
  }
  let valid = validity_bools(operand.storage())
  let name = operand.name()
  let n = data.length()
  let out = match op {
    @expr.StrOp::ToUppercase =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].to_upper()),
      )
    @expr.StrOp::ToLowercase =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].to_lower()),
      )
    @expr.StrOp::StripChars =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].trim().to_owned()),
      )
    @expr.StrOp::LenChars =>
      Series::from_int_options(
        name,
        map_present(n, valid, i => data[i].char_length().to_int64()),
      )
    @expr.StrOp::Contains(pattern) =>
      Series::from_bool_options(
        name,
        map_present(n, valid, i => data[i].contains(pattern)),
      )
    @expr.StrOp::StartsWith(prefix) =>
      Series::from_bool_options(
        name,
        map_present(n, valid, i => data[i].has_prefix(prefix)),
      )
    @expr.StrOp::EndsWith(suffix) =>
      Series::from_bool_options(
        name,
        map_present(n, valid, i => data[i].has_suffix(suffix)),
      )
    @expr.StrOp::Replace(pattern, value) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].replace(old=pattern, new=value)),
      )
    @expr.StrOp::ReplaceAll(pattern, value) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].replace_all(old=pattern, new=value)),
      )
  }
  try_column_to_numeric(out)
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
    @expr.AggOp::Std => ReduceOp::Std
    @expr.AggOp::Var => ReduceOp::Var
    @expr.AggOp::Median => ReduceOp::Median
    @expr.AggOp::NUnique => ReduceOp::NUnique
    @expr.AggOp::First => ReduceOp::First
    @expr.AggOp::Last => ReduceOp::Last
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
  // The engine promotes Int <-> Float (eval_arith / eval_ternary); a closure
  // that returns a mix of Int and Float unifies to Float here too — the Int
  // cells are promoted rather than nulled as the minority type by the raw
  // first-cell-dtype projection below. Other dtype mixes keep the first
  // non-null dtype (a mismatched cell stays null), unchanged.
  let cells = if map_mixes_int_and_float(cells) {
    cells.map(c => {
      match c {
        @types.Scalar::Int(v) => @types.Scalar::Float(v.to_double())
        _ => c
      }
    })
  } else {
    cells
  }
  // An empty scope (a 0-row frame with a column input) calls the closure zero
  // times, so `infer_map_dtype` sees no cell. Rather than raise — which would
  // make `map` the one expression that cannot survive an empty frame, breaking
  // with_columns / select / filter whenever the frame happens to be empty —
  // fall back to the leftmost input's own column backend as the dtype witness
  // (its array contents are ignored: `scalars_to_series` reads the probe's
  // variant only) and return an empty column, mirroring that input's dtype as
  // `name` already mirrors its name. The all-null case (a non-empty scope
  // whose every result cell is null) still resolves to `None` and raises
  // `Unsupported` below — that genuinely has no representable dtype, like a
  // `Null` literal.
  let probe = match infer_map_dtype(cells) {
    Some(p) => Some(p)
    None =>
      if cells.is_empty() {
        evaluated.get(0).map(lead => lead.storage().data())
      } else {
        None
      }
  }
  match probe {
    Some(p) => scalars_to_series(p, name, cells)
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
/// Whether the map result cells mix `Int` and `Float` — the one heterogeneity
/// the engine resolves by promotion (`Int -> Float`, as in `eval_arith` /
/// `eval_ternary`) rather than by nulling the minority type. `Bool` / `String`
/// never promote, so a mix involving them is not flagged here.
fn map_mixes_int_and_float(cells : Array[@types.Scalar]) -> Bool {
  let mut has_int = false
  let mut has_float = false
  for c in cells {
    match c {
      @types.Scalar::Int(_) => has_int = true
      @types.Scalar::Float(_) => has_float = true
      _ => ()
    }
  }
  has_int && has_float
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
