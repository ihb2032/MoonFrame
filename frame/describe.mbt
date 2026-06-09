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
/// uniform value type. The per-column reductions (`min`, `max`) keep the
/// original dtype if a caller needs it typed.
///
/// Raises only because the summary frame is built through the fallible
/// `DataFrame::new`; the output columns are hardcoded-unique and equal
/// length, so the raise is forwarded, never actually taken. The 0-column
/// case collapses to a `0×8` frame: zero source columns ⇒ zero output
/// rows, but the eight schema columns are still present so downstream
/// code can rely on the result's column layout.
pub fn DataFrame::describe(
  self : DataFrame,
) -> DataFrame raise @types.DataError {
  let names : Array[String] = []
  let dtypes : Array[String] = []
  let counts : Array[Int64] = []
  let null_counts : Array[Int64] = []
  let unique_counts : Array[Int64] = []
  let means : Array[Double?] = []
  let mins : Array[String?] = []
  let maxs : Array[String?] = []
  for s in self.column_series() {
    names.push(s.name())
    dtypes.push(s.dtype().to_string())
    counts.push(s.count().to_int64())
    null_counts.push(s.null_count().to_int64())
    unique_counts.push(s.unique_count().to_int64())
    // Both `Series::mean` failure modes — `TypeMismatch` (non-numeric) and
    // `InvalidOperation` (empty / all-null numeric) — collapse to a null
    // cell here; the per-column API keeps the distinction, which would be
    // noise in the aggregate view. Those are the only two errors mean
    // raises, so the wildcard catches exactly them: spelling them out and
    // re-raising the rest would leave an unreachable arm that breaks the
    // 100% line-coverage gate.
    let mean_cell = try s.mean() catch {
      _ => None
    } noraise {
      v => Some(v)
    }
    means.push(mean_cell)
    // `min_value` / `max_value` are total; they return `Scalar::Null` to
    // signal "no value", which `render_extremum` maps to a null cell and
    // otherwise renders via `Scalar::to_string`.
    mins.push(render_extremum(s.min_value()))
    maxs.push(render_extremum(s.max_value()))
  }
  // The output columns share a length (`self.ncols()`) and the names are
  // hardcoded-unique, so `DataFrame::new` always succeeds; the raise is
  // forwarded rather than caught.
  DataFrame::new([
    Series::from_strings("column", names),
    Series::from_strings("dtype", dtypes),
    Series::from_ints("count", counts),
    Series::from_ints("null_count", null_counts),
    Series::from_ints("unique_count", unique_counts),
    Series::from_float_options("mean", means),
    Series::from_string_options("min", mins),
    Series::from_string_options("max", maxs),
  ])
}

///|
/// Map a `Series::min_value` / `Series::max_value` result into a nullable
/// `String` cell. `Scalar::Null` becomes a null cell; every concrete
/// variant renders via `Scalar::to_string`.
fn render_extremum(scalar : @types.Scalar) -> String? {
  if scalar.is_null() {
    None
  } else {
    Some(scalar.to_string())
  }
}
