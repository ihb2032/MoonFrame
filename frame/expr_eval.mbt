///|
/// Vectorized evaluation of `@expr.Expr` against a `DataFrame` — the
/// engine behind `DataFrame::with_columns` (and every other expression
/// consumer: `select` / `filter` / `agg`).
///
/// This lives in `frame`, not `expr`, because evaluation is a DataFrame
/// question: what a column name resolves to, what shape a result must have,
/// which error surfaces first, and how a scope narrows the rows. The reading
/// and the arithmetic sit below it — `series` owns a column's cells and
/// `internal/kernel` the vectorized pass over them, and this package reaches
/// both through helpers that hand back a `Series`, a scalar, or a fresh
/// array. It holds no column buffer of its own; the layering guard refuses
/// the import that would let it.
///
/// The public `@expr.Expr` is an opaque handle; the AST it wraps is
/// `@ir.ExprNode`, in the module-internal `internal/ir` package. This file
/// enters through the `Expr::node()` seam and matches `@ir.ExprNode`
/// directly — the tree walk is over the AST node, not the handle, and a
/// downstream module can reach neither.
///
/// `scope` is the ordered row-index set an expression is evaluated under:
/// `[0, nrows)` for whole-frame contexts, a group's row indices under
/// `agg`.
///
/// **The length contract**, which every consuming verb enforces through
/// `@kernel.broadcast_series` and none of them restates: a result of `|scope|`
/// cells passes through, a length-1 result (a literal, an aggregation)
/// broadcasts over the scope — down to zero rows on an empty one — and **any
/// other length raises `LengthMismatch`**. The built-in algebra only ever
/// produces the first two, which is why the third is easy to forget; the two
/// nodes carrying a caller's own data do not. A `lit_series(s)` keeps `s`'s own
/// length and a `map_batches` closure returns whatever length it likes, so a
/// three-row frame and a two-cell series is the `LengthMismatch` case, not a
/// silently reshaped frame. Under `agg` the contract narrows to one cell per
/// group, since a group's reduction is a single value.
///
/// Semantics, in one place (every rule inherited
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
///   compare **exactly** — the `Int64` is never promoted to `Double`, so two
///   distinct values cannot collide above `2^53` (`cmp_int_double` in
///   `internal/kernel/compare.mbt`, over the `@numeric` primitives `int64_eq_double` /
///   `int64_lt_double` / `double_lt_int64`; a deliberate departure from
///   Polars' Float64-supertype rule), `String` compares by `compare_string_lex`
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
///   `to_lowercase`), `strip_chars` (ASCII whitespace by default, or a given
///   charset), the length probes `len_chars` / `len_bytes` (Int), the shape
///   transforms `reverse` / `pad_start` / `pad_end` / `zfill` / `slice` /
///   `split_get`, the literal predicates `contains` /
///   `starts_with` / `ends_with` (Bool), and the literal substitutions
///   `replace` (first) / `replace_all` (all), plus the regex operations
///   (`str_contains` / `str_replace` / `str_replace_all` with `literal=false`,
///   and `str_extract` / `str_count_matches`), implemented in
///   `internal/kernel/str.mbt`. Null cells stay null and a non-String operand is a
///   `TypeMismatch`; a literal operation is total per value, but a regex
///   operation compiles its pattern once per evaluation and may raise
///   `InvalidOperation` for an invalid pattern — the one non-total path.
/// - **Aggregations** (`sum/mean/min/max/count/std/var/median/n_unique/
///   first/last`): reduce the operand over
///   the scope to a length-1 column through the shared `series/reduce.mbt` kernel —
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
///   all-null result has no non-null cell to fix the dtype, so it borrows the
///   leftmost input's *logical dtype* and yields an all-null column of
///   that dtype (Polars' tolerance of a null-returning map) — the dtype only,
///   never that input's storage backend, which the result decides from its own
///   content like any computed column. Any input can be that witness, a literal
///   included; only a *zero-input* map (nothing to borrow a dtype from, e.g.
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
/// - **Backend convention**: a *computed*
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
  Eval(@ir.ExprNode)
  ApplyBinary(@ir.BinOp)
  ApplyUnary(@ir.UnOp)
  ApplyAgg(@ir.AggOp)
  ApplyStr(@ir.StrOp)
  ApplyCast(@types.DataType)
  ApplyAlias(String)
  ApplyTernary
  ApplyFill(FillKind)
  ApplyIsIn(ArrayView[@types.Scalar])
  ApplyIsBetween(@types.ClosedInterval)
  ApplyMap((Array[@types.Scalar]) -> @types.Scalar raise @types.DataError, Int)
  ApplyMapBatches((Array[Series]) -> Series raise @types.DataError, Int)
}

///|
/// Which emptiness a fill step patches: `Nulls` fills null cells (guarding on
/// the validity mask), `Nans` fills `Float` NaN cells. Names the boolean the
/// `ApplyFill` step used to carry so both call sites and the combiner read the
/// same word instead of re-deriving "true = nulls".
priv enum FillKind {
  Nulls
  Nans
}

///|
/// Evaluate `expr` to a `Series` under `scope`. Callers guarantee every
/// scope index is in `[0, nrows)` (the public consumers build it from
/// `nrows` themselves). Errors — unknown column, dtype mismatch, the
/// unrepresentable `Null` literal — surface here; building the tree was
/// total. The dispatch is a closed `match` over the `@ir.ExprNode` variants
/// (each kernel a closed dtype `match` in turn) with no wildcard, so a future
/// node fails compilation here rather than silently falling
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
  let work : Array[EvalStep] = [Eval(root.node())]
  let values : Array[Series] = []
  // `scope` and `df.nrows()` are constant across the whole walk, so whether the
  // scope is the identity permutation `[0, nrows)` is decided once here instead
  // of re-scanned at every `Col` leaf — an expression with `k` column leaves
  // over an `n`-row frame would otherwise pay an extra O(k·n) just to keep
  // re-answering the same question.
  let identity_scope = is_identity_perm(scope, df.nrows())
  for ;; {
    match work.pop() {
      None => break
      Some(step) =>
        match step {
          Eval(node) =>
            match node {
              @ir.ExprNode::Col(name) =>
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
                  if identity_scope {
                    try_column_to_numeric(df.get_column(name))
                  } else {
                    gather_series(df.get_column(name), scope)
                  },
                )
              @ir.ExprNode::Lit(value) =>
                values.push(@kernel.singleton_series(value))
              // A literal series is used verbatim, like a scalar `Lit` is its
              // length-1 column: the result's length is the series' own, and
              // the consumers (`broadcast_series` in the verbs, `broadcast_pair`
              // in `Binary`) align it — broadcasting a length-1 series, passing
              // a frame-tall one through, raising `LengthMismatch` otherwise.
              @ir.ExprNode::LitSeries(s) => values.push(s)
              @ir.ExprNode::Binary(op, l, r) => {
                work.push(ApplyBinary(op))
                work.push(Eval(r))
                work.push(Eval(l))
              }
              @ir.ExprNode::Unary(op, e) => {
                work.push(ApplyUnary(op))
                work.push(Eval(e))
              }
              @ir.ExprNode::Agg(op, e) => {
                work.push(ApplyAgg(op))
                work.push(Eval(e))
              }
              @ir.ExprNode::Str(op, e) => {
                work.push(ApplyStr(op))
                work.push(Eval(e))
              }
              @ir.ExprNode::Cast(e, target) => {
                work.push(ApplyCast(target))
                work.push(Eval(e))
              }
              @ir.ExprNode::Alias(e, name) => {
                work.push(ApplyAlias(name))
                work.push(Eval(e))
              }
              @ir.ExprNode::Ternary(c, t, f) => {
                work.push(ApplyTernary)
                work.push(Eval(f))
                work.push(Eval(t))
                work.push(Eval(c))
              }
              // The whole point of the dedicated fill nodes: the operand is
              // evaluated ONCE here, where the ternary lowering evaluated it
              // twice (as condition input and as `then` branch) — a chained
              // coalesce is linear work instead of exponential.
              @ir.ExprNode::FillNull(o, v) => {
                work.push(ApplyFill(FillKind::Nulls))
                work.push(Eval(v))
                work.push(Eval(o))
              }
              @ir.ExprNode::FillNan(o, v) => {
                work.push(ApplyFill(FillKind::Nans))
                work.push(Eval(v))
                work.push(Eval(o))
              }
              // The set rides along on the `ApplyIsIn` step; only the operand
              // is evaluated.
              @ir.ExprNode::IsIn(e, members) => {
                work.push(ApplyIsIn(members))
                work.push(Eval(e))
              }
              // Operand first (popped last), then both bounds — evaluated once
              // each; the dedicated node is what lets the operand be shared.
              @ir.ExprNode::IsBetween(x, lo, hi, closed) => {
                work.push(ApplyIsBetween(closed))
                work.push(Eval(hi))
                work.push(Eval(lo))
                work.push(Eval(x))
              }
              @ir.ExprNode::Map(_, inputs, f) => {
                work.push(ApplyMap(f, inputs.length()))
                for i = inputs.length() - 1; i >= 0; i = i - 1 {
                  work.push(Eval(inputs[i]))
                }
              }
              // `returns_scalar` is a planning hint (it gates whether the node
              // is accepted as a per-group reduction); evaluation is identical
              // either way — the closure runs over the operands' evaluated
              // series and its result rides the length contract below.
              @ir.ExprNode::MapBatches(_, inputs, _, f) => {
                work.push(ApplyMapBatches(f, inputs.length()))
                for i = inputs.length() - 1; i >= 0; i = i - 1 {
                  work.push(Eval(inputs[i]))
                }
              }
            }
          ApplyBinary(op) => {
            let rhs = pop_value(values)
            let lhs = pop_value(values)
            let (left, right) = @kernel.broadcast_pair(lhs, rhs)
            values.push(
              match op {
                @ir.BinOp::Add =>
                  @kernel.eval_arith(left, right, "add", (x, y) => x + y, (x, y) => {
                    x + y
                  })
                @ir.BinOp::Sub =>
                  @kernel.eval_arith(left, right, "subtract", (x, y) => x - y, (
                    x,
                    y,
                  ) => x - y)
                @ir.BinOp::Mul =>
                  @kernel.eval_arith(left, right, "multiply", (x, y) => x * y, (
                    x,
                    y,
                  ) => x * y)
                @ir.BinOp::Div => @kernel.eval_div(left, right)
                @ir.BinOp::FloorDiv => @kernel.eval_floor_div(left, right)
                @ir.BinOp::Mod => @kernel.eval_mod(left, right)
                @ir.BinOp::Pow => @kernel.eval_pow(left, right)
                @ir.BinOp::Eq =>
                  @kernel.eval_compare(left, right, @kernel.CmpVerb::Eq)
                @ir.BinOp::Ne =>
                  @kernel.eval_compare(left, right, @kernel.CmpVerb::Ne)
                @ir.BinOp::Lt =>
                  @kernel.eval_compare(left, right, @kernel.CmpVerb::Lt)
                @ir.BinOp::Le =>
                  @kernel.eval_compare(left, right, @kernel.CmpVerb::Le)
                @ir.BinOp::Gt =>
                  @kernel.eval_compare(left, right, @kernel.CmpVerb::Gt)
                @ir.BinOp::Ge =>
                  @kernel.eval_compare(left, right, @kernel.CmpVerb::Ge)
                @ir.BinOp::And =>
                  @kernel.eval_logic(left, right, "and", @kernel.kleene_and)
                @ir.BinOp::Or =>
                  @kernel.eval_logic(left, right, "or", @kernel.kleene_or)
              },
            )
          }
          ApplyUnary(op) => {
            let operand = pop_value(values)
            values.push(
              match op {
                @ir.UnOp::Neg => @kernel.eval_neg(operand)
                @ir.UnOp::Not => @kernel.eval_not(operand)
                @ir.UnOp::IsNull =>
                  Series::from_bools(
                    operand.name(),
                    validity_bools(operand).map(v => !v),
                  )
                @ir.UnOp::IsNotNull =>
                  Series::from_bools(operand.name(), validity_bools(operand))
                @ir.UnOp::IsNan => @kernel.eval_is_nan(operand, true)
                @ir.UnOp::IsNotNan => @kernel.eval_is_nan(operand, false)
                @ir.UnOp::Abs =>
                  @kernel.eval_unary_num(
                    operand,
                    "take the absolute value of",
                    a => a.abs(),
                    a => a.abs(),
                  )
                @ir.UnOp::Floor =>
                  @kernel.eval_unary_num(operand, "take the floor of", a => a, a => {
                    a.floor()
                  })
                @ir.UnOp::Ceil =>
                  @kernel.eval_unary_num(
                    operand,
                    "take the ceiling of",
                    a => a,
                    a => a.ceil(),
                  )
                @ir.UnOp::Sign =>
                  @kernel.eval_unary_num(
                    operand, "take the sign of", @kernel.sign_i64, @kernel.sign_f64,
                  )
                @ir.UnOp::Round(decimals) =>
                  @kernel.eval_unary_num(operand, "round", a => a, v => {
                    @kernel.round_places(v, decimals)
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
            values.push(@kernel.eval_str(op, operand))
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
            values.push(@kernel.eval_ternary(cond, then_v, else_v))
          }
          ApplyFill(kind) => {
            let value_v = pop_value(values)
            let operand = pop_value(values)
            // Synthesize the guard the old lowering spelled out —
            // `is_not_null(operand)` (resp. `is_not_nan`) — from the
            // already-evaluated operand, then combine through the same
            // ternary kernel, so dtype unification, Kleene null-condition
            // handling (a null cell is neither NaN nor not-NaN, so
            // `fill_nan` passes it through as null), naming, and backend
            // convergence stay byte-for-byte identical.
            let cond = match kind {
              FillKind::Nulls =>
                Series::from_bools(operand.name(), validity_bools(operand))
              FillKind::Nans => @kernel.eval_is_nan(operand, false)
            }
            values.push(@kernel.eval_ternary(cond, operand, value_v))
          }
          ApplyIsIn(members) => {
            let operand = pop_value(values)
            values.push(@kernel.eval_is_in(operand, members))
          }
          ApplyIsBetween(closed) => {
            let hi_v = pop_value(values)
            let lo_v = pop_value(values)
            let x_v = pop_value(values)
            values.push(@kernel.eval_is_between(x_v, lo_v, hi_v, closed))
          }
          ApplyMap(f, arity) =>
            values.push(@kernel.eval_map_apply(pop_inputs(values, arity), f))
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
