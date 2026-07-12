///|
/// Reduce each group of a grouped frame to one row, evaluating one
/// expression per output column. Each expression is a **reduction** over
/// its group: `col("revenue").sum()`, `col("revenue").max() -
/// col("revenue").min()` (a per-group range), `(col("revenue") -
/// col("cost")).sum()` (a reduction over a *derived* column) — the group
/// collapses to a single cell per expression.
///
/// Output shape: the key columns head the frame (in key order, each named
/// by its key expression's output name and keeping its evaluated dtype and
/// backend, one representative row per group), followed by one column per
/// expression (in expression order), named by the expression's
/// output name (alias, else leftmost column reference, else `"literal"`);
/// one row per group, in the first-appearance group order fixed by
/// `group_by`. The result routes through `DataFrame::new`, so name
/// collisions — two expressions sharing an output name, or an expression
/// shadowing a key column — surface as `DuplicateColumn`, and every output
/// satisfies `check_invariants()`. `agg([])` degenerates to a distinct over
/// the key tuples (zero expressions ⇒ zero aggregated columns).
///
/// Each expression must be **reduction-shaped** (`reduces_per_group`):
/// aggregations and literals are per-group scalars, and every combinator —
/// arithmetic / comparison / Kleene operators, `not` and the null probes,
/// `cast`, `with_alias`, `when/then/otherwise` — preserves scalarness; a
/// bare column reference pins the result to the group height, so it is
/// not a reduction. The check is structural, hence deterministic:
/// `agg([col("a")])` raises `InvalidOperation` even when every group
/// happens to hold a single row, where a dynamic length test would
/// data-dependently pass. (Polars would implicitly collect the group into
/// a list value; MoonFrame has no list dtype, so implicit list-aggregation
/// stays out of scope.)
///
/// Evaluation reuses the `expr_eval.mbt` engine with `scope =` each
/// group's row indices, inheriting the documented dtype / null / NaN
/// rules verbatim: `sum` / `mean` propagate NaN and reject non-numeric
/// dtypes, `min` / `max` skip NaN and are total over every dtype, an
/// all-null group sums to the additive identity and means to a null
/// cell, `count` counts non-null cells. Dtype errors (`ColumnNotFound`,
/// `TypeMismatch`) surface from the per-group evaluation itself (the
/// bare-column fast path still reports them up front, resolving its
/// reducer before any group work); the output dtype is taken from the
/// reduced cells themselves, since a `map(...)` closure's result dtype is
/// scope-dependent. A probe evaluation under the empty scope is consulted
/// only as a fallback that types — and gates — a zero-group or all-null
/// result: consulted eagerly it would spuriously reject a dtype-changing
/// `map(...)` under a numeric reduction, because the closure never runs
/// under the empty scope and the probe would type the `Map` by its
/// leftmost input column instead. Computed columns follow the
/// expression-engine backend convention: an all-valid numeric column
/// converges onto `Numeric`, anything nullable (or `Bool` / `String`) stays
/// `Builtin`.
///
/// An aggregation directly over a bare column — `col(name).<agg>()` for any
/// aggregation op, the common case once aliases are peeled — takes a
/// single-pass fast path (`bare_col_agg`): the shared reduction kernel
/// resolves its reducer and validity mask once and folds each group's row
/// indices straight off the source column, instead of gathering a fresh
/// sub-column per group through the general evaluator. It is purely an
/// optimization — the result is cell-for-cell and backend identical to the
/// general path, with the same dtype / null / NaN rules and the same up-front
/// error surfacing — so an aggregation over a *derived* operand
/// (`(col("a") - col("b")).sum()`) transparently falls back to it.
///
/// Raises:
/// - `InvalidOperation(...)` — an expression is not reduction-shaped, or
///   the handle's `groups` no longer satisfy the `group_by` invariants (an
///   empty group, or a row index outside the source) — the pub fields
///   expose live arrays, so external mutation is re-checked here rather
///   than allowed to drive the folds into an abort.
/// - `ColumnNotFound(name)` — an expression references an absent column.
/// - `TypeMismatch(...)` — an expression's dtypes don't unify (e.g. `sum`
///   over a `String` column), from the first group's evaluation — or from
///   the fallback probe when zero groups / an all-null result leave no
///   dtype witness.
/// - `DuplicateColumn(name)` — two output column names collide.
pub fn GroupedDataFrame::agg(
  self : GroupedDataFrame,
  exprs : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  // Re-validate the `group_by` invariants before any fold: the pub fields
  // are read-only (no reassignment) but the Array values read from them are
  // live objects, so a cross-package caller can empty a group or plant a
  // stray row index after construction. The folds below index the source
  // unguarded on the strength of these invariants (`g[0]`, the bare-column
  // reducer's `read(i)`), so a corrupted handle must raise here — one
  // O(total indices) pass, the same order as `agg` itself — instead of
  // aborting downstream (the never-abort gate).
  let nrows = self.source.nrows()
  for g in self.groups {
    if g.is_empty() {
      raise @types.DataError::InvalidOperation(
        "corrupted GroupedDataFrame: a group is empty (groups were mutated after group_by)",
      )
    }
    for i in g {
      if i < 0 || i >= nrows {
        raise @types.DataError::InvalidOperation(
          "corrupted GroupedDataFrame: group row index \{i} outside [0, \{nrows}) (groups were mutated after group_by)",
        )
      }
    }
  }
  let out_cols : Array[Series] = []
  // Key columns: gather one representative cell per group from the
  // materialised key columns `group_by` already built (each named by its
  // expression's output name and carrying its evaluated dtype / backend) —
  // `g[0]` is in-bounds since the validation above rejected empty groups,
  // and `gather_series` keeps the key column's name, dtype, and backend.
  let reps = self.groups.map(g => g[0])
  for key_column in self.key_columns {
    out_cols.push(gather_series(key_column, reps))
  }
  for expr in exprs {
    let out_name = expr_output_name(expr)
    // `(probe, cells)`: a *deferred* fallback `ColumnData` that types (and
    // gates) the column only when the cells carry no dtype of their own
    // (zero groups, or an all-null result), plus one reduced `Scalar` per
    // group in group order. Both branches feed `agg_cells_to_series`, which
    // types the column from the cells themselves and converges an all-valid
    // numeric result onto `Numeric`, so the fast path is cell-for-cell *and
    // backend* identical to the general one — it only changes how the cells
    // are computed.
    let (probe, cells) : (
      () -> @column.ColumnData raise @types.DataError,
      Array[@types.Scalar],
    ) = match bare_col_agg(expr) {
      // Fast path: an aggregation over a bare column, `col(name).<agg>()`.
      // Resolve the reducer and validity mask once through the shared kernel
      // (which raises `ColumnNotFound` on the absent column and `TypeMismatch`
      // for a non-numeric `sum` / `mean`, both up front before any group
      // work), then fold each group's row indices straight off the source
      // column — no per-group sub-column is gathered.
      Some((name, rop)) => {
        let (reducer, probe) = reducer_for(
          self.source.get_column(name).storage(),
          rop,
        )
        (() => probe, self.groups.map(g => reducer(g.length(), k => g[k])))
      }
      // General path: a derived or compound reduction such as
      // `(col("a") - col("b")).sum()` or `col("x").max() - col("x").min()`.
      // The shape gate rejects non-reductions first; each group is then
      // evaluated through the general engine and its length-1 result read
      // off the total `to_scalars` by plain index. The empty-scope probe is
      // deferred: it is only evaluated — surfacing its `ColumnNotFound` /
      // `TypeMismatch` — when the reduced cells leave the dtype undecided
      // (zero groups, or an all-null result). Running it eagerly would
      // spuriously reject a dtype-changing `map(...)` closure under a
      // numeric reduction: under the empty scope the closure never runs, so
      // the probe types the `Map` by its leftmost *input* column (e.g.
      // `String`) and `sum` / `mean` raise `TypeMismatch` even though every
      // real group evaluates to a numeric cell.
      None => {
        if !reduces_per_group(expr) {
          raise @types.DataError::InvalidOperation(
            "aggregate expression must reduce each group to a single value: \{expr.explain()}",
          )
        }
        (
          () => eval_expr(expr, self.source, []).storage().data(),
          self.groups.map(g => eval_expr(expr, self.source, g).to_scalars()[0]),
        )
      }
    }
    out_cols.push(agg_cells_to_series(cells, probe, out_name))
  }
  DataFrame::new(out_cols)
}

///|
/// Whether `expr` reduces *any* evaluation scope to a single value — the
/// structural gate `agg` applies before evaluating. Aggregations
/// and literals are scalars; the combinators preserve scalarness over
/// their operands; a bare column reference pins the result to the scope
/// height, so it is not a reduction — and a `Map` is row-wise the same way
/// (one cell per row), so a bare `map(...)` is not a reduction either,
/// though `map(...).sum()` is, by the enclosing `Agg`. A `lit_series(s)` is
/// likewise row-wise — its own cells, not a single value — so a bare
/// `lit_series(s)` is not a reduction, though `lit_series(s).sum()` is.
/// Structural (data-independent) on purpose: group sizes never change the
/// verdict.
fn reduces_per_group(expr : @expr.Expr) -> Bool {
  // Iterative tree walk (explicit stack, not the call stack): a deeply nested
  // aggregation expression formerly overflowed and aborted in this pre-pass,
  // which the doc calls structural and total. `Lit` / `Agg` are terminal (an
  // aggregation reduces regardless of its operand), `Col` / `Map` / `LitSeries`
  // fail, and the combinators require every child to reduce.
  let stack : Array[@expr.Expr] = [expr]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) =>
        match e {
          @expr.Expr::Col(_)
          | @expr.Expr::Map(_, _, _)
          | @expr.Expr::LitSeries(_) => return false
          @expr.Expr::Lit(_) | @expr.Expr::Agg(_, _) => ()
          @expr.Expr::Binary(_, l, r)
          | @expr.Expr::FillNull(l, r)
          | @expr.Expr::FillNan(l, r) => {
            stack.push(l)
            stack.push(r)
          }
          @expr.Expr::Unary(_, e2)
          | @expr.Expr::Str(_, e2)
          | @expr.Expr::Cast(e2, _)
          | @expr.Expr::Alias(e2, _)
          | @expr.Expr::IsIn(e2, _) => stack.push(e2)
          @expr.Expr::Ternary(c, t, f) => {
            stack.push(c)
            stack.push(t)
            stack.push(f)
          }
          @expr.Expr::IsBetween(x, lo, hi) => {
            stack.push(x)
            stack.push(lo)
            stack.push(hi)
          }
        }
    }
  }
  true
}

///|
/// Recognise the single-pass fast-path shape — an aggregation directly over
/// a bare column reference, `col(name).<agg>()` for any aggregation op —
/// returning the source column name and reduction op,
/// else `None`. Top-level aliases are peeled first: `col(name).sum()
/// .with_alias("total")` is the common idiom and an alias only renames the
/// result (the output name comes from `expr_output_name` either way). The
/// aggregation's operand must be a *bare* `Col`; an aggregation over a
/// derived operand (`(col("a") - col("b")).sum()`, `col("x").cast(...).sum()`)
/// or any non-aggregation returns `None` and takes the general per-group
/// evaluator — which the fast path reproduces cell for cell.
fn bare_col_agg(expr : @expr.Expr) -> (String, ReduceOp)? {
  match expr {
    @expr.Expr::Alias(inner, _) => bare_col_agg(inner)
    @expr.Expr::Agg(op, @expr.Expr::Col(name)) =>
      Some((name, reduce_op_of_agg(op)))
    _ => None
  }
}

///|
/// Build one aggregated output column from the reduced cells — one `Scalar`
/// per group, in group order. The dtype comes from the cells themselves: a
/// mixed `Int`/`Float` result promotes to `Float` (the arithmetic engine's
/// rule), the first non-null cell then fixes the variant, and an all-valid
/// numeric result converges onto `Numeric`. So a `map(...)`-wrapped reduction
/// whose closure returns a dtype other than its input column's is typed by
/// what it actually produced — not by the empty-scope `fallback` probe, which
/// never ran the closure. The `fallback` types only the cases the cells
/// cannot: zero groups, or an all-null result (e.g. `mean` over all-null
/// groups), where the reduction's own declared dtype is the right witness.
/// It is a deferred computation, first forced here — its own
/// `ColumnNotFound` / `TypeMismatch` only surfaces when it is actually
/// consumed as the witness.
/// One narrow corner: when the reduction wraps a `map(...)` whose closure
/// output dtype differs from its leftmost input's, an all-null result is typed
/// by that input's dtype — a `Map`'s empty-scope probe takes the leftmost
/// input column and never runs the closure — so the empty column's declared
/// dtype / backend can differ from the closure's intended output. Every cell is
/// `Null`, so no value is wrong; only the dtype witness of an all-null column
/// differs (reachable via `first` / `last` / `min` / `max`).
fn agg_cells_to_series(
  cells : Array[@types.Scalar],
  fallback : () -> @column.ColumnData raise @types.DataError,
  name : String,
) -> Series raise @types.DataError {
  let cells = promote_mixed_int_float(cells)
  let probe = match infer_cells_dtype(cells) {
    Some(p) => p
    None => fallback()
  }
  scalars_to_series(probe, name, cells)
}
