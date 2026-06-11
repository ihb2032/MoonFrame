///|
/// Expression aggregation over a grouped frame — the expression twin of
/// `GroupedDataFrame::agg(Array[AggSpec])`, generalising the one-column /
/// one-reduction spec to full reduction-shaped expression trees:
/// `(col("revenue") - col("cost")).sum()` aggregates a *derived* column,
/// `col("revenue").max() - col("revenue").min()` combines two reductions
/// into a per-group range — neither is expressible as an `AggSpec`. The
/// single-reduction forms coincide: `col("r").sum().with_alias("x")`
/// computes cell-for-cell what `AggSpec::sum("r").with_alias("x")` does.
///
/// Output shape mirrors `agg`: the key columns head the frame (in `keys`
/// order, source dtype and backend, one representative row per group),
/// followed by one column per expression (in expression order), named by
/// the expression's output name (alias, else leftmost column reference,
/// else `"literal"`); one row per group, in the first-appearance group
/// order fixed by `group_by`. The result routes through `DataFrame::new`,
/// so name collisions — two expressions sharing an output name, or an
/// expression shadowing a key column — surface as `DuplicateColumn`, and
/// every output satisfies `check_invariants()`. `agg_exprs([])`
/// degenerates to the same distinct-over-keys frame as `agg([])`.
///
/// Each expression must be **reduction-shaped** (`reduces_per_group`):
/// aggregations and literals are per-group scalars, and every combinator —
/// arithmetic / comparison / Kleene operators, `not` and the null probes,
/// `cast`, `with_alias`, `when/then/otherwise` — preserves scalarness; a
/// bare column reference pins the result to the group height, so it is
/// not a reduction. The check is structural, hence deterministic:
/// `agg_exprs([col("a")])` raises `InvalidOperation` even when every
/// group happens to hold a single row, where a dynamic length test would
/// data-dependently pass. (Polars would implicitly collect the group into
/// a list value; v0.4 has no list dtype, so implicit list-aggregation
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
/// anything nullable (or `Bool` / `String`) stays `Builtin`. (The
/// `AggSpec` path leaves `mean` / `min` / `max` on `Builtin` even when
/// all-valid, so the two paths agree on every cell value but can differ
/// in backend.)
///
/// Raises:
/// - `InvalidOperation(...)` — an expression is not reduction-shaped.
/// - `ColumnNotFound(name)` — an expression references an absent column.
/// - `TypeMismatch(...)` — an expression's dtypes don't unify (e.g. `sum`
///   over a `String` column), reported before any group work.
/// - `DuplicateColumn(name)` — two output column names collide.
pub fn GroupedDataFrame::agg_exprs(
  self : GroupedDataFrame,
  exprs : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  let out_cols : Array[Series] = []
  // Key columns: gather one representative cell per group, exactly as
  // `agg` — `g[0]` is in-bounds since `group_by` never stores an empty
  // group, and `gather_series` keeps the key's dtype and backend. The key
  // came from `group_by`, which already validated it, so `get_column`'s
  // raise is forwarded but never taken.
  let reps = self.groups.map(g => g[0])
  for key in self.keys {
    out_cols.push(gather_series(self.source.get_column(key), reps))
  }
  for expr in exprs {
    if !reduces_per_group(expr) {
      raise @types.DataError::InvalidOperation(
        "aggregate expression must reduce each group to a single value: " +
        expr.explain(),
      )
    }
    // Probe under the empty scope: dtype rules are scope-independent, so
    // this surfaces `ColumnNotFound` / `TypeMismatch` once, before any
    // per-group evaluation (the `sum_groups` convention), and pins the
    // output dtype even when a 0-row source produced zero groups.
    let probe = eval_expr(expr, self.source, [])
    // A reduction-shaped expression evaluates to length 1 under any scope
    // (aggregations and literals are length-1, and the combinators only
    // ever broadcast 1 against 1), so the lone cell is read off the total
    // `to_scalars` by plain index.
    let cells = self.groups.map(g => {
      eval_expr(expr, self.source, g).to_scalars()[0]
    })
    out_cols.push(stitch_group_cells(probe, cells, expr_output_name(expr)))
  }
  DataFrame::new(out_cols)
}

///|
/// Whether `expr` reduces *any* evaluation scope to a single value — the
/// structural gate `agg_exprs` applies before evaluating. Aggregations
/// and literals are scalars; the combinators preserve scalarness over
/// their operands; a bare column reference pins the result to the scope
/// height, so it is not a reduction. Structural (data-independent) on
/// purpose: group sizes never change the verdict.
fn reduces_per_group(expr : @expr.Expr) -> Bool {
  match expr {
    @expr.Expr::Col(_) => false
    @expr.Expr::Lit(_) | @expr.Expr::Agg(_, _) => true
    @expr.Expr::Binary(_, l, r) => reduces_per_group(l) && reduces_per_group(r)
    @expr.Expr::Unary(_, e)
    | @expr.Expr::Cast(e, _)
    | @expr.Expr::Alias(e, _) => reduces_per_group(e)
    @expr.Expr::Ternary(c, t, f) =>
      reduces_per_group(c) && reduces_per_group(t) && reduces_per_group(f)
  }
}

///|
/// Stitch one expression's per-group scalar cells into its output column.
/// `probe` (the empty-scope evaluation of the same expression) anchors
/// the dtype dispatch, so zero groups still produce a correctly-typed
/// empty column. The cells are dtype-consistent with the probe because
/// dtype is scope-independent, so each typed arm only ever meets its own
/// variant or `Null` (an all-null group's `mean` / extremum); the
/// catch-all maps `Null` to a null cell — the `agg_extremum` trick,
/// leaving no dead arm. An all-valid numeric result converges onto the
/// `Numeric` backend, the expression-engine convention for computed
/// columns.
fn stitch_group_cells(
  probe : Series,
  cells : Array[@types.Scalar],
  name : String,
) -> Series {
  try_column_to_numeric(
    match probe.storage().data() {
      @column.ColumnData::Int(_) =>
        Series::from_int_options(
          name,
          cells.map(c => {
            match c {
              @types.Scalar::Int(v) => Some(v)
              _ => None
            }
          }),
        )
      @column.ColumnData::Float(_) =>
        Series::from_float_options(
          name,
          cells.map(c => {
            match c {
              @types.Scalar::Float(v) => Some(v)
              _ => None
            }
          }),
        )
      @column.ColumnData::Bool(_) =>
        Series::from_bool_options(
          name,
          cells.map(c => {
            match c {
              @types.Scalar::Bool(v) => Some(v)
              _ => None
            }
          }),
        )
      @column.ColumnData::String(_) =>
        Series::from_string_options(
          name,
          cells.map(c => {
            match c {
              @types.Scalar::String(v) => Some(v)
              _ => None
            }
          }),
        )
    },
  )
}
