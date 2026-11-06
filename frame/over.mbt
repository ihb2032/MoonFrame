// The window-function evaluator behind `Expr::over` — the one place a
// frame-tall expression reads its own grouping. The keys evaluate against
// the whole frame (identity scope), rows partition through the same
// `KeyCell` map `group_by` builds (first-appearance order, a null key its
// own group — invisible here, since the output stitches back in row
// order), and the inner expression evaluates once per group through the
// ordinary evaluator under the group's row scope. The stitch rule is the
// length contract's window half: a group-length result lands cell-for-cell,
// a length-1 result (an aggregation) broadcasts over the group, anything
// else is the caller's shape error.

///|
/// Evaluate one window: partition `df`'s rows by `keys`, evaluate `inner`
/// once per group, and stitch the per-group results back into one
/// frame-tall column. The output keeps the inner expression's own name
/// (the naming verb renames through `output_name`). A window nesting a
/// window — in its inner or in a key — refuses, as does a group result
/// whose length is neither the group's own nor one.
fn eval_over(
  df : DataFrame,
  inner : @ir.ExprNode,
  keys : Array[@ir.ExprNode],
) -> Series raise @types.DataError {
  if contains_window(inner) {
    raise @types.DataError::InvalidOperation(
      "an over window cannot nest inside another",
    )
  }
  for key in keys {
    if contains_window(key) {
      raise @types.DataError::InvalidOperation(
        "an over window cannot appear in another window's keys",
      )
    }
  }
  let n = df.nrows()
  // The keys evaluate against the whole frame, broadcast to frame height
  // the way `group_by`'s own key expressions do — and they evaluate even
  // when the frame has no rows, so a bad key column name raises
  // `ColumnNotFound` on a 0-row frame exactly as it does on any other
  // (`group_by`'s reading; the groups an empty frame lacks would otherwise
  // swallow the error).
  let identity = Array::makei(n, i => i)
  let key_columns : Array[Series] = []
  for key in keys {
    let evaluated = eval_expr(@expr.Expr::of_node(key), df, identity)
    key_columns.push(@kernel.broadcast_series(evaluated, n))
  }
  // A frame with no rows has no groups to evaluate; the inner still runs
  // once over the empty frame so the output column carries the dtype the
  // windowed expression produces.
  if n == 0 {
    return eval_expr(@expr.Expr::of_node(inner), df, identity)
  }
  // The partition: one pass over the rows building each group's row list,
  // keyed by the row's key cells — the same map `group_by` builds, so the
  // null-key and NaN-folding rules cannot drift between the two.
  let by_key : Map[Array[KeyCell], Array[Int32]] = Map([])
  let per_column = key_columns.map(c => c.key_cells())
  for i in 0..<n {
    let row_key : Array[KeyCell] = Array::makei(per_column.length(), k => {
      per_column[k][i]
    })
    match by_key.get(row_key) {
      Some(rows) => rows.push(i)
      None => by_key[row_key] = [i]
    }
  }
  // Stitch: each group's result lands back at the group's own rows, a
  // length-1 result broadcast within the group. Every group evaluates the
  // same expression, so the dtypes agree and the first group's fixes the
  // output column's.
  let mut dtype = @types.DataType::Null
  let mut first = true
  let cells : Array[@types.Scalar] = Array::makei(n, _ => @types.Scalar::Null)
  for _, rows in by_key {
    let part = eval_expr(@expr.Expr::of_node(inner), df, rows)
    let g = rows.length()
    if part.len() != g && part.len() != 1 {
      raise @types.DataError::InvalidOperation(
        "an over expression returned \{part.len()} cells for a group of \{g} rows (a group-length or single-cell result is required)",
      )
    }
    if first {
      dtype = part.dtype()
      first = false
    }
    let part_cells = part.to_scalars()
    for r = 0; r < g; r = r + 1 {
      cells[rows[r]] = part_cells[if part.len() == 1 { 0 } else { r }]
    }
  }
  Series::from_scalars(@expr.Expr::of_node(inner).output_name(), cells, dtype~).try_column_to_numeric()
}

///|
/// Whether a tree carries a window anywhere — the nesting fence. Walks
/// the same shape encoding every engine walk rides; total and iterative.
fn contains_window(root : @ir.ExprNode) -> Bool {
  let stack : Array[@ir.ExprNode] = [root]
  for ;; {
    match stack.pop() {
      None => return false
      Some(node) =>
        if node is @ir.ExprNode::Over(_, _) {
          return true
        } else {
          node.each_child(k => stack.push(k))
        }
    }
  }
}
