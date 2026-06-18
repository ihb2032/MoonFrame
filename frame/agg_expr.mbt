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
/// `TypeMismatch`) surface from a probe evaluation under the empty scope
/// *before* any per-group work — dtype rules are scope-independent — and
/// the probe also fixes the output dtype when a 0-row source produced
/// zero groups. Computed columns follow the expression-engine backend
/// convention: an all-valid numeric column converges onto `Numeric`,
/// anything nullable (or `Bool` / `String`) stays `Builtin`.
///
/// An aggregation directly over a bare column — `col(name).sum()` and the
/// four other reductions, the common case once aliases are peeled — takes a
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
/// - `InvalidOperation(...)` — an expression is not reduction-shaped.
/// - `ColumnNotFound(name)` — an expression references an absent column.
/// - `TypeMismatch(...)` — an expression's dtypes don't unify (e.g. `sum`
///   over a `String` column), reported before any group work.
/// - `DuplicateColumn(name)` — two output column names collide.
pub fn GroupedDataFrame::agg(
  self : GroupedDataFrame,
  exprs : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  let out_cols : Array[Series] = []
  // Key columns: gather one representative cell per group from the
  // materialised key columns `group_by` already built (each named by its
  // expression's output name and carrying its evaluated dtype / backend) —
  // `g[0]` is in-bounds since `group_by` never stores an empty group, and
  // `gather_series` keeps the key column's name, dtype, and backend.
  let reps = self.groups.map(g => g[0])
  for key_column in self.key_columns {
    out_cols.push(gather_series(key_column, reps))
  }
  for expr in exprs {
    let out_name = expr_output_name(expr)
    // `(probe, cells)`: the `ColumnData` fixing the output dtype (so a
    // zero-group result still types) plus one reduced `Scalar` per group, in
    // group order. Both branches feed the same `scalars_to_series`, which
    // converges an all-valid numeric result onto `Numeric`, so the fast path
    // is cell-for-cell *and backend* identical to the general one — it only
    // changes how the cells are computed.
    let (probe, cells) = match bare_col_agg(expr) {
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
        (probe, self.groups.map(g => reducer(g.length(), k => g[k])))
      }
      // General path: a derived or compound reduction such as
      // `(col("a") - col("b")).sum()` or `col("x").max() - col("x").min()`.
      // The shape gate rejects non-reductions first; the empty-scope probe
      // then surfaces `ColumnNotFound` / `TypeMismatch` once and pins the
      // output dtype even when a 0-row source produced zero groups; each group
      // is evaluated through the general engine and its length-1 result read
      // off the total `to_scalars` by plain index.
      None => {
        if !reduces_per_group(expr) {
          raise @types.DataError::InvalidOperation(
            "aggregate expression must reduce each group to a single value: \{expr.explain()}",
          )
        }
        let probe = eval_expr(expr, self.source, [])
        (
          probe.storage().data(),
          self.groups.map(g => eval_expr(expr, self.source, g).to_scalars()[0]),
        )
      }
    }
    out_cols.push(scalars_to_series(probe, out_name, cells))
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
  match expr {
    @expr.Expr::Col(_) | @expr.Expr::Map(_, _, _) | @expr.Expr::LitSeries(_) =>
      false
    @expr.Expr::Lit(_) | @expr.Expr::Agg(_, _) => true
    @expr.Expr::Binary(_, l, r) => reduces_per_group(l) && reduces_per_group(r)
    @expr.Expr::Unary(_, e)
    | @expr.Expr::Str(_, e)
    | @expr.Expr::Cast(e, _)
    | @expr.Expr::Alias(e, _) => reduces_per_group(e)
    @expr.Expr::Ternary(c, t, f) =>
      reduces_per_group(c) && reduces_per_group(t) && reduces_per_group(f)
  }
}

///|
/// Recognise the single-pass fast-path shape — an aggregation directly over
/// a bare column reference, `col(name).sum()` / `.mean()` / `.min()` /
/// `.max()` / `.count()` — returning the source column name and reduction op,
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
