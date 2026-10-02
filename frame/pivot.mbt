// The reshape pair — Polars' `pivot` (long → wide: one output column per
// value of the `on` keys, one output row per distinct `index` combination)
// and `unpivot` (wide → long, pandas' `melt`: the `on` columns fold into a
// `variable` / `value` pair repeated under the `index` columns).
//
// Both reshape whole frames, and both key on **columns** rather than
// computed expressions, but they differ in how a caller names those
// columns and the split follows the verbs' own shapes: `pivot`'s keys and
// values are evaluated expressions (the `group_by` / `sort` convention —
// a derived key is real here), while `unpivot`'s on / index lists are
// consulted by output name only (the `drop` / `drop_nulls` convention — a
// reshape selects columns, it does not compute them).
//
// Order is deterministic everywhere Polars leaves it unspecified:
// `pivot`'s rows are the `index` combinations in first-appearance order
// and its columns the `on` values in first-appearance order (Polars'
// `maintain_order=True` / `sort_columns=False` defaults, made the only
// behaviour), and `unpivot`'s rows walk the source rows outermost, then
// the `on` columns in declaration order.

///|
/// How `pivot` collapses the cells that land in one output column — Polars'
/// `aggregate_function`, its `None` case (the default) spelled by omitting
/// the parameter: more than one cell in a slot then `raise`s
/// `InvalidOperation` rather than picking silently.
///
/// - `First` / `Last` — the first / last cell in row order, any dtype;
/// - `Sum` / `Min` / `Max` — the reduction family's rules (an all-null
///   slot sums to the additive identity; `min` / `max` skip `NaN`), the
///   value column's dtype kept;
/// - `Mean` / `Median` — always `Float`, an all-null slot a `Null` cell;
/// - `Len` — the **row count** that landed in the slot (nulls included),
///   as `Int`.
///
/// A slot no row landed in is a `Null` cell under every aggregation.
pub(all) enum PivotAgg {
  First
  Last
  Sum
  Min
  Max
  Mean
  Median
  Len
} derive(Eq, Debug)

///|
pub extend PivotAgg with Eq::{equal, not_equal}

///|
pub extend PivotAgg with Debug::{to_repr}

///|
/// Reshape long → wide (Polars' `df.pivot(on=…)`): one output row per
/// distinct `index~` combination, one output column per distinct `on~`
/// value, each slot holding the `values~` cells of the rows that share
/// both — collapsed by `aggregate_function?` when more than one lands
/// there (`PivotAgg`'s rules; omitted, a multi-cell slot `raise`s
/// `InvalidOperation`).
///
/// `on~` / `index~` / `values~` are evaluated expressions (the `group_by`
/// convention): a bare `col(name)` keys by the column, a derived key by
/// the computed value, each named by its output name. The defaults follow
/// Polars, and one of `index?` / `values?` must be given: `index?`
/// omitted takes every column neither `on~` nor `values~` names;
/// `values?` omitted takes every column neither `on~` nor `index~` names.
///
/// Output order is first-appearance on both axes (Polars'
/// `maintain_order=True`, `sort_columns=False` — the deterministic
/// reading). The `index` columns keep their dtypes and head the frame;
/// each reshaped column is named by its `on` value alone when `values~`
/// holds one column, and `{value column}_{on value}` otherwise (a
/// multiple-`on` value joins its cells the same way). A name colliding
/// with another, or with an `index` column's, `raise`s `DuplicateColumn`.
pub fn DataFrame::pivot(
  self : DataFrame,
  on~ : Array[@expr.Expr],
  index? : Array[@expr.Expr],
  values? : Array[@expr.Expr],
  aggregate_function? : PivotAgg,
) -> DataFrame raise @types.DataError {
  if on.is_empty() {
    raise @types.DataError::InvalidOperation("pivot needs at least one on key")
  }
  if index is None && values is None {
    raise @types.DataError::InvalidOperation(
      "pivot needs an index or a values list",
    )
  }
  // Materialise the `on` key columns (the `group_by` route: evaluate over
  // the whole frame, broadcast a length-1 key, name by output name, and
  // reject a duplicate name before any reshape work).
  let n = self.nrows()
  let scope = Array::makei(n, i => i)
  let on_cols = materialize_pivot_keys(on, self, n, scope)
  // An omitted side takes the columns the other two lists do not name —
  // resolved against the original expr lists, each into its own set.
  let skip_names = (extra : Array[@expr.Expr]) => {
    let m = names_of_exprs(on)
    for e in extra {
      m[e.output_name()] = ()
    }
    m
  }
  let index_cols = match index {
    Some(keys) => materialize_pivot_keys(keys, self, n, scope)
    None => columns_except(self, skip_names(values.unwrap()))
  }
  let values_cols = match values {
    Some(vs) => materialize_pivot_keys(vs, self, n, scope)
    None => columns_except(self, skip_names(index.unwrap()))
  }
  reshape_pivot(on_cols, index_cols, values_cols, aggregate_function)
}

///|
/// Evaluate the key / value expressions of a pivot: `group_by`'s
/// materialisation — evaluate over the whole frame, broadcast a length-1
/// key, rename by the output name, and reject a duplicate output name at
/// the second occurrence.
fn materialize_pivot_keys(
  keys : Array[@expr.Expr],
  df : DataFrame,
  n : Int,
  scope : Array[Int],
) -> Array[Series] raise @types.DataError {
  let seen : Map[String, Unit] = Map([])
  keys.map(key => {
    let column = @kernel.broadcast_series(eval_expr(key, df, scope), n)
    let name = key.output_name()
    if seen.contains(name) {
      raise @types.DataError::DuplicateColumn(name)
    }
    seen[name] = ()
    column.rename(name)
  })
}

///|
/// The set of output names a list of expressions produces.
fn names_of_exprs(exprs : Array[@expr.Expr]) -> Map[String, Unit] {
  let m : Map[String, Unit] = Map([])
  for e in exprs {
    m[e.output_name()] = ()
  }
  m
}

///|
/// Every column of `df` whose name is not in `skip`.
fn columns_except(df : DataFrame, skip : Map[String, Unit]) -> Array[Series] {
  df.columns.filter(c => !skip.contains(c.name()))
}

///|
/// The reshape itself: bucket every row by its (index combination, on
/// value) pair, then emit one row per index combination and one column per
/// (on value × value column), each slot reduced per the aggregation. Both
/// axes keep first-appearance order; an empty `index` list is the grand
/// total (every row one combination, `group_by([])`'s reading).
fn reshape_pivot(
  on_cols : Array[Series],
  index_cols : Array[Series],
  values_cols : Array[Series],
  agg : PivotAgg?,
) -> DataFrame raise @types.DataError {
  let n = on_cols[0].len()
  let on_scalars = on_cols.map(c => c.to_scalars())
  let index_scalars = index_cols.map(c => c.to_scalars())
  // Row → (group id, on-value id), both ids first-appearance; the group's
  // representative row and the card's rendered name record alongside.
  let gid_of : Map[Array[KeyCell], Int] = Map([])
  let cid_of : Map[Array[KeyCell], Int] = Map([])
  let gids : Array[Int] = Array::makei(n, _ => 0)
  let cids : Array[Int] = Array::makei(n, _ => 0)
  let rep_rows : Array[Int] = []
  let on_names : Array[String] = []
  for i in 0..<n {
    let gkey = row_group_key(index_scalars, i)
    if !gid_of.contains(gkey) {
      gid_of[gkey] = rep_rows.length()
      rep_rows.push(i)
    }
    gids[i] = gid_of[gkey]
    let ckey = row_group_key(on_scalars, i)
    if !cid_of.contains(ckey) {
      cid_of[ckey] = on_names.length()
      // The card's name renders this row's on cells — unquoted for
      // strings, the dtype's own display, multiple keys joined by `_`.
      on_names.push(
        on_scalars
        .map(col => {
          match col[i] {
            @types.Scalar::Null => "null"
            cell => cell.to_string()
          }
        })
        .join("_"),
      )
    }
    cids[i] = cid_of[ckey]
  }
  let groups = rep_rows.length()
  let cards = on_names.length()
  // Buckets: cells[group][card][value column], filled in row order.
  let buckets : Array[Array[Array[Array[@types.Scalar]]]] = Array::makei(
    groups,
    _ => Array::makei(cards, _ => Array::makei(values_cols.length(), _ => [])),
  )
  let value_scalars = values_cols.map(c => c.to_scalars())
  for i in 0..<n {
    let bucket = buckets[gids[i]][cids[i]]
    for v in 0..<values_cols.length() {
      bucket[v].push(value_scalars[v][i])
    }
  }
  // Index columns head the output: one representative cell per group (the
  // group's first row, `agg`'s key-column rule).
  let out_cols = index_cols.map(c => c.gather_series(rep_rows))
  // One column per (card × value column), named per the naming rule.
  let multi_values = values_cols.length() > 1
  // Value-major: each value column's cards together (Polars' order).
  for v in 0..<values_cols.length() {
    for card in 0..<cards {
      let name = if multi_values {
        "\{values_cols[v].name()}_\{on_names[card]}"
      } else {
        on_names[card]
      }
      let probe = match agg {
        Some(Mean) | Some(Median) => @types.DataType::Float
        Some(Len) => @types.DataType::Int
        _ => values_cols[v].dtype()
      }
      let cells : Array[@types.Scalar] = []
      for g in 0..<groups {
        cells.push(reduce_pivot_slot(buckets[g][card][v], agg, probe))
      }
      out_cols.push(@series.scalars_to_series(probe, name, cells))
    }
  }
  DataFrame::from_parts(out_cols, groups)
}

///|
/// Collapse one pivot slot's cells under the aggregation: `None` raises on
/// a multi-cell slot (Polars' default strictness), `Len` counts rows, and
/// the reductions go through a same-dtype series so every rule the
/// reduction family documents applies verbatim. An empty slot is a `Null`
/// cell under every aggregation.
fn reduce_pivot_slot(
  cells : Array[@types.Scalar],
  agg : PivotAgg?,
  probe : @types.DataType,
) -> @types.Scalar raise @types.DataError {
  if cells.is_empty() {
    return @types.Scalar::Null
  }
  // A `Float` probe over `Int` cells (the mean / median / unified-value
  // shape) widens first — the probe projects, it does not coerce.
  let as_series = () => {
    @series.scalars_to_series(
      probe,
      "slot",
      cells.map(c => widen_unpivot_cell(c, probe)),
    )
  }
  match agg {
    None =>
      if cells.length() > 1 {
        raise @types.DataError::InvalidOperation(
          "pivot slot holds \{cells.length()} values; pass an aggregate_function",
        )
      } else {
        cells[0]
      }
    Some(Len) => @types.Scalar::Int(cells.length().to_int64())
    Some(First) => cells[0]
    Some(Last) => cells[cells.length() - 1]
    Some(Sum) => as_series().sum()
    Some(Min) => as_series().min()
    Some(Max) => as_series().max()
    Some(Mean) =>
      match as_series().mean_opt() {
        Some(m) => @types.Scalar::Float(m)
        None => @types.Scalar::Null
      }
    Some(Median) =>
      if as_series().count() == 0 {
        @types.Scalar::Null
      } else {
        @types.Scalar::Float(as_series().median())
      }
  }
}

///|
/// Reshape wide → long (Polars' `df.unpivot`, pandas' `melt`): each `on?`
/// column folds into a `variable_name?` / `value_name?` pair — one output
/// row per (source row, on column), the `index?` columns repeated beside.
/// `on?` and `index?` are consulted by output name only (the `drop`
/// convention); `on?` omitted takes every column `index?` does not name,
/// `index?` omitted keeps nothing, and an empty `on` resolution `raise`s
/// `InvalidOperation`. The output rows walk the `on` columns outermost —
/// one block per column, each holding its source rows in order — so the
/// index columns repeat within a block, deterministic where Polars leaves
/// the order unspecified.
///
/// The value column carries one dtype: the `on` columns' own dtype when
/// they agree, `Float` when they are `Int` / `Float` in any mix (`Int`
/// cells widen), and any other mix `raise`s `TypeMismatch` — MoonFrame has
/// no stringly supertype to fall back on.
pub fn DataFrame::unpivot(
  self : DataFrame,
  on? : Array[@expr.Expr],
  index? : Array[@expr.Expr],
  variable_name? : String = "variable",
  value_name? : String = "value",
) -> DataFrame raise @types.DataError {
  // Name-only resolution: the reshape selects columns, it does not compute.
  let index_cols = match index {
    Some(keys) => self.resolve_subset_columns(keys)
    None => []
  }
  let index_names : Map[String, Unit] = Map([])
  for c in index_cols {
    index_names[c.name()] = ()
  }
  let on_cols = match on {
    Some(keys) => self.resolve_subset_columns(keys)
    None => self.columns.filter(c => !index_names.contains(c.name()))
  }
  if on_cols.is_empty() {
    raise @types.DataError::InvalidOperation(
      "unpivot needs at least one on column",
    )
  }
  // The value dtype: agreement, or the Int / Float widening.
  let mut value_dtype = on_cols[0].dtype()
  for c in on_cols {
    let d = c.dtype()
    if d != value_dtype {
      if d.is_numeric() && value_dtype.is_numeric() {
        value_dtype = @types.DataType::Float
      } else {
        raise @types.DataError::TypeMismatch(
          @types.TypeMismatchDetail::Message(
            "unpivot on-columns must share a dtype, got \{value_dtype} and \{d}",
          ),
        )
      }
    }
  }
  let n = self.nrows()
  let k = on_cols.length()
  // Index columns repeat once per on-column block, in step with the value
  // blocks below: the row at output position `j * n + i` carries source
  // row `i`'s index cells, so the index and value columns stay aligned.
  let out_cols : Array[Series] = []
  for c in index_cols {
    let repeated : Array[@types.Scalar] = []
    let cells = c.to_scalars()
    for _ in 0..<k {
      for i in 0..<n {
        repeated.push(cells[i])
      }
    }
    out_cols.push(@series.scalars_to_series(c.dtype(), c.name(), repeated))
  }
  let variables : Array[String] = []
  let values : Array[@types.Scalar] = []
  for c in on_cols {
    for _ in 0..<n {
      variables.push(c.name())
    }
    for cell in c.to_scalars() {
      values.push(widen_unpivot_cell(cell, value_dtype))
    }
  }
  out_cols.push(Series::from_strings(variable_name, variables))
  out_cols.push(@series.scalars_to_series(value_dtype, value_name, values))
  DataFrame::from_parts(out_cols, n * k)
}

///|
/// Widen one cell into the unified value dtype — the `Int` → `Float` half
/// of unpivot's dtype rule; every other cell passes through (the columns
/// agreed, or the unify would have raised).
fn widen_unpivot_cell(
  cell : @types.Scalar,
  value_dtype : @types.DataType,
) -> @types.Scalar {
  match (cell, value_dtype) {
    (@types.Scalar::Int(i), @types.DataType::Float) =>
      @types.Scalar::Float(i.to_double())
    _ => cell
  }
}
