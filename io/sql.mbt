// The SQL source: a query run through any `@moondb` driver, answered as
// a frame. MoonFrame depends on the moondb *contract* only — the pure
// interface package behind moonsqlite / moonpostgres / moonmysql — so
// the caller brings their own driver and this reader never learns a
// wire protocol. Values cross the seam as moondb's own `Value` sum; the
// mapping into MoonFrame's dtypes is total over the scalar shapes and
// refuses the container shapes a frame column cannot carry.

///|
/// Run one query and read the answer into a frame. `driver` is any
/// moondb driver — the in-memory `MockDriver` ships with moondb itself,
/// and moonsqlite / moonpostgres / moonmysql plug in the same way; MoonFrame
/// takes no database dependency of its own. `params` are bound values
/// (`?` placeholders or the driver's own style), handed to the driver
/// out-of-band, never spliced into `sql`.
///
/// Each column's dtype follows its cells: `Bool` → `Bool`, `Int` /
/// `Int64` → `Int`, `Double` → `Float`, `Text` → `String`, `Time` →
/// `Timestamp` (its ISO-8601 text parsed by the readers' own parser),
/// `Numeric` → `Decimal` (exact-decimal text into the decimal128
/// dtype). A column mixing the integer shapes with `Double` answers
/// `Float` — the numeric lattice the CSV reader already uses — while
/// any other mix refuses naming both shapes; cast one side in the
/// query. A column of nothing but `Null` answers `String`: no cell
/// names a dtype, every dtype's null set is the same shape, and a
/// string keeps the widest round-trip. A cell a frame column cannot
/// carry — `Blob` / `Uuid` / `Json` / `Array` — refuses the read naming
/// the column (cast it to text in the query instead); so does a `Time`
/// / `Numeric` text that does not parse. An empty answer is the `0×0`
/// frame — moondb carries the column names on the rows, so a query
/// answering nothing names nothing.
///
/// Raises `IoError` carrying the driver's own `DbError` text when the
/// query itself fails.
pub fn read_sql(
  driver : &@moondb.Driver,
  sql : String,
  params~ : Array[@moondb.Value] = [],
) -> @frame.DataFrame raise @types.DataError {
  // The caller's array is copied at the boundary — the read hands the
  // values to the driver and keeps none of them, but the copy keeps
  // that a fact of this body rather than of the callee.
  let params = params.copy()
  let rows = driver.query(sql, params) catch {
    e => raise @types.DataError::IoError("sql: \{e}")
  }
  // No rows, no column names — the 0×0 answer.
  if rows.length() == 0 {
    return @frame.DataFrame::from_parts([], 0)
  }
  let ncols = rows[0].columns.length()
  for row in rows {
    if row.columns.length() != ncols {
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "sql: a row carries \{row.columns.length()} columns but the first carried \{ncols}",
        ),
      )
    }
  }
  let columns : Array[@series.Series] = []
  for c in 0..<ncols {
    columns.push(sql_column(rows[0].columns[c], rows, c))
  }
  @frame.DataFrame::from_parts(columns, rows.length())
}

///|
/// One query column as a series, in one scan: each cell converts as it
/// arrives (a container shape or an unparseable rider text refuses
/// right there), the dtype verdict rides the first non-null cell, and
/// the numeric lattice's one widening — an integer cell meeting a
/// `Double` — rewrites the cells already stacked rather than refusing.
/// The scan reads the local row array the query answered, so what the
/// verdict saw is exactly what converts: no second pass, no drift.
fn sql_column(
  name : String,
  rows : Array[@moondb.Row],
  c : Int32,
) -> @series.Series raise @types.DataError {
  let cells : Array[@types.Scalar] = []
  let mut verdict : @types.DataType? = None
  let mut widen = false
  for row in rows {
    let cell = sql_cell(name, row.values[c])
    if cell is @types.Scalar::Null {
      cells.push(cell)
    } else {
      let dtype = cell.dtype()
      match verdict {
        None => verdict = Some(dtype)
        Some(d) =>
          if dtype != d {
            // The numeric lattice's one widening — an `Int` cell
            // meeting a `Float` cell, either order — defers to a
            // single rewrite after the scan; every other mix refuses
            // naming both shapes.
            if (d is @types.DataType::Int && dtype is @types.DataType::Float) ||
              (d is @types.DataType::Float && dtype is @types.DataType::Int) {
              verdict = Some(@types.DataType::Float)
              widen = true
            } else {
              raise @types.DataError::InvalidOperation(
                "sql: column \"\{name}\" mixes \{d} and \{dtype} cells; cast one side in the query",
              )
            }
          }
      }
      cells.push(cell)
    }
  }
  // The deferred widening: the integer cells already stacked lift to
  // `Float` in one rewrite (the `Float` and null cells pass through).
  if widen {
    lift_column(cells)
  }
  // An all-null column answers `String`.
  let dtype = match verdict {
    Some(d) => d
    None => @types.DataType::String
  }
  @series.Series::from_scalars(name, cells, dtype~)
}

///|
/// One cell as a scalar: the six shapes a frame column carries convert,
/// the rider texts parse by the readers' own parsers, and the container
/// shapes refuse naming the shape.
fn sql_cell(
  name : String,
  v : @moondb.Value,
) -> @types.Scalar raise @types.DataError {
  match v {
    Null => @types.Scalar::Null
    Bool(b) => @types.Scalar::Bool(b)
    Int(i) => @types.Scalar::Int(i.to_int64())
    Int64(i) => @types.Scalar::Int(i)
    Double(d) => @types.Scalar::Float(d)
    Text(s) => @types.Scalar::String(s)
    Time(text) =>
      match @types.parse_timestamp_micros_opt(text) {
        Some(micros) => @types.Scalar::Timestamp(micros)
        None =>
          raise @types.DataError::ParseError(
            @types.ParseErrorDetail::Message(
              "sql: column \"\{name}\" carries a Time cell whose text does not parse as a timestamp: \"\{text}\"",
            ),
          )
      }
    Numeric(text) =>
      match @types.Dec128::parse_opt(text) {
        Some(d) => @types.Scalar::Decimal(d)
        None =>
          raise @types.DataError::ParseError(
            @types.ParseErrorDetail::Message(
              "sql: column \"\{name}\" carries a Numeric cell whose text does not parse as a decimal: \"\{text}\"",
            ),
          )
      }
    Blob(_) | Uuid(_) | Json(_) | Array(_) =>
      raise @types.DataError::Unsupported(
        "sql: column \"\{name}\" carries a \{shape_name(v)} cell MoonFrame does not read; cast it to text in the query",
      )
  }
}

///|
/// The numeric lattice's lifts: a whole column of `Int` cells rewritten
/// to `Float` (the one widening), and an integer cell lifted on the
/// spot.
fn lift_column(cells : Array[@types.Scalar]) -> Unit {
  for i in 0..<cells.length() {
    let cell = cells[i]
    if cell is @types.Scalar::Int(v) {
      cells[i] = @types.Scalar::Float(v.to_double())
    }
  }
}

///|
/// The shape name a refusal message names a cell by.
fn shape_name(v : @moondb.Value) -> String {
  // Only the four container shapes reach here (the caller refused the
  // cell already), so the catch-all answers Array — the fourth one.
  match v {
    Blob(_) => "Blob"
    Uuid(_) => "Uuid"
    Json(_) => "Json"
    _ => "Array"
  }
}
