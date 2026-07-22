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
///   all-null result has no non-null cell to fix the dtype, so it falls back
///   to the leftmost input's column backend and yields an all-null column of
///   that dtype (Polars' tolerance of a null-returning map); only a
///   *column-less* map (no input to borrow a backend from, e.g.
///   `map_many([], _ => Null)`) has no dtype witness and raises
///   `Unsupported`, as for the `Null` literal.
///   The map's height follows its inputs, like every other expression: a
///   *column* input makes it frame-tall, so over an empty scope the closure
///   runs zero times and the result is an empty column (dtype mirrored from
///   the leftmost input); an *all-literal* map (every input length-1, no
///   column read) is length-1 like a bare `lit`, so the closure runs once and
///   the one result broadcasts even over a 0-row frame — the same all-constant
///   projection rule that makes `select([lit])` a single row at any height.
/// - **Literal series** (`lit_series`): the embedded `Series` is returned
///   verbatim, the data analogue of a scalar literal's length-1 column. Its
///   length is the series' own; the consumers broadcast it like any other
///   result — a length-1 series fills the scope, a frame-tall one passes
///   through, anything else is `LengthMismatch`. It reads no frame column, so
///   evaluation never raises on the frame's contents.
/// - **Backend convention** (the v0.3 review Q2 decision): a *computed*
///   result converges onto the `Numeric` fast path whenever it is an
///   all-valid numeric column (`try_column_to_numeric`), and lands on
///   `Builtin` otherwise (nullable, `Bool`, `String`). A `col(...)` reference
///   is canonicalised the same way — to the backend its *content* implies, not
///   the source's: an all-valid numeric column converges to `Numeric`
///   (`gather_series` / `try_column_to_numeric`), and this content-determined
///   backend is the invariant predicate pushdown relies on. `cast` follows
///   `Series::cast`.

///|
/// One step of the explicit-stack evaluator: descend into a subtree (`Eval`)
/// or, once a node's operands sit on the value stack, apply its operator
/// (`Apply*`). Lifting `eval_expr`'s post-order walk off the call stack lets an
/// arbitrarily deep `Expr` evaluate without overflowing — the never-abort
/// contract the introspection walks in `expr/explain.mbt` also keep. `ApplyMap`
/// carries the opaque closure and its input count so the combiner can pop that
/// many already-evaluated operands.
priv enum EvalStep {
  Eval(@expr.Expr)
  ApplyBinary(@expr.BinOp)
  ApplyUnary(@expr.UnOp)
  ApplyAgg(@expr.AggOp)
  ApplyStr(@expr.StrOp)
  ApplyCast(@types.DataType)
  ApplyAlias(String)
  ApplyTernary
  ApplyFill(Bool) // true = fill nulls, false = fill NaNs
  ApplyIsIn(Array[@types.Scalar])
  ApplyIsBetween(@expr.ClosedInterval)
  ApplyMap((Array[@types.Scalar]) -> @types.Scalar raise @types.DataError, Int)
  ApplyMapBatches((Array[Series]) -> Series raise @types.DataError, Int)
}

///|
/// Evaluate `expr` to a `Series` under `scope`. Callers guarantee every
/// scope index is in `[0, nrows)` (the public consumers build it from
/// `nrows` themselves). Errors — unknown column, dtype mismatch, the
/// unrepresentable `Null` literal — surface here; building the tree was
/// total. The dispatch is a closed `match` over the `Expr` variants (each
/// kernel a closed dtype `match` in turn) with no wildcard, so a future
/// `Expr` variant fails compilation here rather than silently falling
/// through. The walk is iterative — an explicit work + value stack, not the
/// call stack — so an arbitrarily deep tree evaluates without overflowing and
/// aborting. `df` / `scope` are constant across the walk (a sub-scope is fixed
/// by the caller), so only the `Col` leaves consult them; every combinator
/// reads its already-evaluated operands off the value stack.
fn eval_expr(
  root : @expr.Expr,
  df : DataFrame,
  scope : Array[Int],
) -> Series raise @types.DataError {
  let work : Array[EvalStep] = [Eval(root)]
  let values : Array[Series] = []
  for ;; {
    match work.pop() {
      None => break
      Some(step) =>
        match step {
          Eval(expr) =>
            match expr {
              @expr.Expr::Col(name) =>
                // The whole-frame verbs evaluate over the identity scope
                // `[0, nrows)`; gathering a column onto itself there is a full
                // per-row copy + re-box. Short-circuit to
                // `try_column_to_numeric`, which lands on the same canonical
                // backend `gather_series` would (the invariant the optimizer
                // relies on — *not* a bare `self`, which could leave a
                // `Builtin` all-valid numeric column un-canonicalised) without
                // the copy. A genuine sub-scope (a group's rows in the
                // aggregation engine) still gathers.
                values.push(
                  if is_identity_perm(scope, df.nrows()) {
                    try_column_to_numeric(df.get_column(name))
                  } else {
                    gather_series(df.get_column(name), scope)
                  },
                )
              @expr.Expr::Lit(value) => values.push(singleton_series(value))
              // A literal series is used verbatim, like a scalar `Lit` is its
              // length-1 column: the result's length is the series' own, and
              // the consumers (`broadcast_series` in the verbs, `broadcast_pair`
              // in `Binary`) align it — broadcasting a length-1 series, passing
              // a frame-tall one through, raising `LengthMismatch` otherwise.
              @expr.Expr::LitSeries(s) => values.push(s)
              @expr.Expr::Binary(op, l, r) => {
                work.push(ApplyBinary(op))
                work.push(Eval(r))
                work.push(Eval(l))
              }
              @expr.Expr::Unary(op, e) => {
                work.push(ApplyUnary(op))
                work.push(Eval(e))
              }
              @expr.Expr::Agg(op, e) => {
                work.push(ApplyAgg(op))
                work.push(Eval(e))
              }
              @expr.Expr::Str(op, e) => {
                work.push(ApplyStr(op))
                work.push(Eval(e))
              }
              @expr.Expr::Cast(e, target) => {
                work.push(ApplyCast(target))
                work.push(Eval(e))
              }
              @expr.Expr::Alias(e, name) => {
                work.push(ApplyAlias(name))
                work.push(Eval(e))
              }
              @expr.Expr::Ternary(c, t, f) => {
                work.push(ApplyTernary)
                work.push(Eval(f))
                work.push(Eval(t))
                work.push(Eval(c))
              }
              // The whole point of the dedicated fill nodes: the operand is
              // evaluated ONCE here, where the ternary lowering evaluated it
              // twice (as condition input and as `then` branch) — a chained
              // coalesce is linear work instead of exponential.
              @expr.Expr::FillNull(o, v) => {
                work.push(ApplyFill(true))
                work.push(Eval(v))
                work.push(Eval(o))
              }
              @expr.Expr::FillNan(o, v) => {
                work.push(ApplyFill(false))
                work.push(Eval(v))
                work.push(Eval(o))
              }
              // The set rides along on the `ApplyIsIn` step; only the operand
              // is evaluated.
              @expr.Expr::IsIn(e, members) => {
                work.push(ApplyIsIn(members))
                work.push(Eval(e))
              }
              // Operand first (popped last), then both bounds — evaluated once
              // each; the dedicated node is what lets the operand be shared.
              @expr.Expr::IsBetween(x, lo, hi, closed) => {
                work.push(ApplyIsBetween(closed))
                work.push(Eval(hi))
                work.push(Eval(lo))
                work.push(Eval(x))
              }
              @expr.Expr::Map(_, inputs, f) => {
                work.push(ApplyMap(f, inputs.length()))
                for i = inputs.length() - 1; i >= 0; i = i - 1 {
                  work.push(Eval(inputs[i]))
                }
              }
              // `returns_scalar` is a planning hint (it gates whether the node
              // is accepted as a per-group reduction); evaluation is identical
              // either way — the closure runs over the operands' evaluated
              // series and its result rides the length contract below.
              @expr.Expr::MapBatches(_, inputs, _, f) => {
                work.push(ApplyMapBatches(f, inputs.length()))
                for i = inputs.length() - 1; i >= 0; i = i - 1 {
                  work.push(Eval(inputs[i]))
                }
              }
            }
          ApplyBinary(op) => {
            let rhs = pop_value(values)
            let lhs = pop_value(values)
            let (left, right) = broadcast_pair(lhs, rhs)
            values.push(
              match op {
                @expr.BinOp::Add =>
                  eval_arith(left, right, "add", (x, y) => x + y, (x, y) => {
                    x + y
                  })
                @expr.BinOp::Sub =>
                  eval_arith(left, right, "subtract", (x, y) => x - y, (x, y) => {
                    x - y
                  })
                @expr.BinOp::Mul =>
                  eval_arith(left, right, "multiply", (x, y) => x * y, (x, y) => {
                    x * y
                  })
                @expr.BinOp::Div => eval_div(left, right)
                @expr.BinOp::FloorDiv => eval_floor_div(left, right)
                @expr.BinOp::Mod => eval_mod(left, right)
                @expr.BinOp::Pow => eval_pow(left, right)
                @expr.BinOp::Eq => eval_compare(left, right, CmpVerb::Eq)
                @expr.BinOp::Ne => eval_compare(left, right, CmpVerb::Ne)
                @expr.BinOp::Lt => eval_compare(left, right, CmpVerb::Lt)
                @expr.BinOp::Le => eval_compare(left, right, CmpVerb::Le)
                @expr.BinOp::Gt => eval_compare(left, right, CmpVerb::Gt)
                @expr.BinOp::Ge => eval_compare(left, right, CmpVerb::Ge)
                @expr.BinOp::And => eval_logic(left, right, "and", kleene_and)
                @expr.BinOp::Or => eval_logic(left, right, "or", kleene_or)
              },
            )
          }
          ApplyUnary(op) => {
            let operand = pop_value(values)
            values.push(
              match op {
                @expr.UnOp::Neg => eval_neg(operand)
                @expr.UnOp::Not => eval_not(operand)
                @expr.UnOp::IsNull =>
                  Series::from_bools(
                    operand.name(),
                    validity_bools(operand.storage()).map(v => !v),
                  )
                @expr.UnOp::IsNotNull =>
                  Series::from_bools(
                    operand.name(),
                    validity_bools(operand.storage()),
                  )
                @expr.UnOp::IsNan => eval_is_nan(operand, true)
                @expr.UnOp::IsNotNan => eval_is_nan(operand, false)
                @expr.UnOp::Abs =>
                  eval_unary_num(
                    operand,
                    "take the absolute value of",
                    a => a.abs(),
                    a => a.abs(),
                  )
                @expr.UnOp::Floor =>
                  eval_unary_num(operand, "take the floor of", a => a, a => {
                    a.floor()
                  })
                @expr.UnOp::Ceil =>
                  eval_unary_num(operand, "take the ceiling of", a => a, a => {
                    a.ceil()
                  })
                @expr.UnOp::Sign =>
                  eval_unary_num(
                    operand, "take the sign of", sign_i64, sign_f64,
                  )
                @expr.UnOp::Round(decimals) =>
                  eval_unary_num(operand, "round", a => a, v => {
                    round_places(v, decimals)
                  })
              },
            )
          }
          ApplyAgg(op) => {
            let operand = pop_value(values)
            values.push(eval_agg(op, operand))
          }
          ApplyStr(op) => {
            let operand = pop_value(values)
            values.push(eval_str(op, operand))
          }
          ApplyCast(target) => {
            let operand = pop_value(values)
            values.push(try_column_to_numeric(operand.cast(target)))
          }
          ApplyAlias(name) => {
            let operand = pop_value(values)
            values.push(operand.rename(name))
          }
          ApplyTernary => {
            let else_v = pop_value(values)
            let then_v = pop_value(values)
            let cond = pop_value(values)
            values.push(eval_ternary(cond, then_v, else_v))
          }
          ApplyFill(fill_nulls) => {
            let value_v = pop_value(values)
            let operand = pop_value(values)
            // Synthesize the guard the old lowering spelled out —
            // `is_not_null(operand)` (resp. `is_not_nan`) — from the
            // already-evaluated operand, then combine through the same
            // ternary kernel, so dtype unification, Kleene null-condition
            // handling (a null cell is neither NaN nor not-NaN, so
            // `fill_nan` passes it through as null), naming, and backend
            // convergence stay byte-for-byte identical.
            let cond = if fill_nulls {
              Series::from_bools(
                operand.name(),
                validity_bools(operand.storage()),
              )
            } else {
              eval_is_nan(operand, false)
            }
            values.push(eval_ternary(cond, operand, value_v))
          }
          ApplyIsIn(members) => {
            let operand = pop_value(values)
            values.push(eval_is_in(operand, members))
          }
          ApplyIsBetween(closed) => {
            let hi_v = pop_value(values)
            let lo_v = pop_value(values)
            let x_v = pop_value(values)
            values.push(eval_is_between(x_v, lo_v, hi_v, closed))
          }
          ApplyMap(f, arity) =>
            values.push(eval_map_apply(pop_inputs(values, arity), f))
          // Hand the whole evaluated series to the closure and canonicalise the
          // backend of its result — an all-valid numeric column returned on
          // `Builtin` lands on `Numeric`, keeping `collect ≡ execute`.
          ApplyMapBatches(f, arity) =>
            values.push(try_column_to_numeric(f(pop_inputs(values, arity))))
        }
    }
  }
  pop_value(values)
}

///|
/// Pop the evaluator's value stack. `eval_expr`'s post-order walk pushes a
/// value for every operand before its combiner runs, so the stack is never
/// empty here; the top slot is read by that stack-invariant index — total, like
/// the engine's other indexed reads — and dropped, never `unwrap`.
fn pop_value(stack : Array[Series]) -> Series {
  let top = stack[stack.length() - 1]
  let _ = stack.pop()
  top
}

///|
/// Pop `arity` already-evaluated operands off the value stack and return them in
/// **input order**. The stack yields them last-first, so the result reverses the
/// pop order (`arity - 1 - i`) — cell `k` then feeds the closure its k-th input.
/// Shared by the `ApplyMap` / `ApplyMapBatches` combiners, whose reversals must
/// otherwise be kept in lockstep.
fn pop_inputs(stack : Array[Series], arity : Int) -> Array[Series] {
  let popped : Array[Series] = []
  for _ in 0..<arity {
    popped.push(pop_value(stack))
  }
  Array::makei(arity, i => popped[arity - 1 - i])
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
/// Build the structured error a binary numeric / ordering kernel raises when
/// its operands are not a supported pair. `TypeMismatch(Operation(...))` keeps the operation
/// and both dtypes programmable while its `message()` preserves the historical
/// `cannot <verb> <left> and <right>` wording. (`eval_logic` names the Bool
/// requirement instead, so it keeps its own error shape.)
fn binary_type_mismatch_error(
  verb : String,
  left : Series,
  right : Series,
) -> @types.DataError {
  @types.DataError::TypeMismatch(
    @types.TypeMismatchDetail::Operation(verb, left.dtype(), right.dtype()),
  )
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
