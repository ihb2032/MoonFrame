///|
/// Per-column statistical summary, returned as a `DataFrame` with one
/// row per source column. The result schema is fixed and dtype-pure —
/// every cell has the dtype declared below, regardless of the source
/// frame's shape or column dtypes:
///
/// - `column` (`String`): source column name, in declaration order
/// - `dtype` (`String`): source column dtype rendered via `Show`
/// - `count` (`Int`): non-null cell count
/// - `null_count` (`Int`): null cell count
/// - `unique_count` (`Int`): distinct non-null value count
/// - `mean` (`Float`, nullable): arithmetic mean for numeric columns;
///   `Null` for non-numeric or empty / all-null numeric columns
/// - `min` (`String`, nullable): minimum cell rendered via
///   `Scalar::to_string`; `Null` for empty / all-null columns
/// - `max` (`String`, nullable): maximum cell rendered via
///   `Scalar::to_string`; `Null` for empty / all-null columns
///
/// `min` / `max` are rendered as `String` so the summary can carry
/// extrema for every dtype in a single column without forcing a
/// uniform value type. The per-column reductions (`@ops.min`,
/// `@ops.max`) keep the original dtype if a caller needs it typed.
///
/// `describe` is total — every well-formed `df` produces a well-formed
/// result. The 0-column case collapses to a `0×8` frame: zero source
/// columns ⇒ zero output rows, but the eight schema columns are still
/// present so downstream code can rely on the result's column layout.
pub fn describe(df : @frame.DataFrame) -> @frame.DataFrame {
  let names : Array[String] = []
  let dtypes : Array[String] = []
  let counts : Array[Int64] = []
  let null_counts : Array[Int64] = []
  let unique_counts : Array[Int64] = []
  let means : Array[Double?] = []
  let mins : Array[String?] = []
  let maxs : Array[String?] = []
  for name in df.columns() {
    // `get_column` cannot fail: name came from `df.columns()`.
    let s = df.get_column(name).unwrap()
    names.push(name)
    dtypes.push(s.dtype().to_string())
    counts.push(s.count().to_int64())
    null_counts.push(s.null_count().to_int64())
    unique_counts.push(s.unique_count().to_int64())
    // Both `Series::mean` failure modes (TypeMismatch for non-numeric,
    // InvalidOperation for empty / all-null numeric) collapse to a
    // null cell here — the diagnostic distinction is preserved at the
    // per-column API and would be noise in the aggregate view.
    let mean_cell = match s.mean() {
      Ok(v) => Some(v)
      Err(_) => None
    }
    means.push(mean_cell)
    // `Series::min` / `Series::max` are total for v0.1 columns (every
    // dtype is concrete), so unwrapping is safe. They return
    // `Scalar::Null` to signal "no value" — `render_extremum` maps that
    // to a null cell and otherwise renders via `Scalar::to_string`.
    mins.push(render_extremum(s.min().unwrap()))
    maxs.push(render_extremum(s.max().unwrap()))
  }
  // All output columns share the same length (`df.ncols()`) and the
  // names are hardcoded and unique, so `DataFrame::new` cannot fail
  // here. `unwrap` is a structural assertion, not a real error path.
  @frame.DataFrame::new([
    @frame.Series::from_strings("column", names),
    @frame.Series::from_strings("dtype", dtypes),
    @frame.Series::from_ints("count", counts),
    @frame.Series::from_ints("null_count", null_counts),
    @frame.Series::from_ints("unique_count", unique_counts),
    @frame.Series::from_float_options("mean", means),
    @frame.Series::from_string_options("min", mins),
    @frame.Series::from_string_options("max", maxs),
  ]).unwrap()
}

///|
/// Map a `Series::min` / `Series::max` result into a nullable `String`
/// cell. `Scalar::Null` becomes a null cell; every concrete variant
/// renders via `Scalar::to_string`.
fn render_extremum(scalar : @types.Scalar) -> String? {
  if scalar.is_null() {
    None
  } else {
    Some(scalar.to_string())
  }
}
