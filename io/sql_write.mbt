// The SQL sink and the table read: a frame written into a database
// table, and a table read whole, through any `@moondb` driver — the
// counterparts of `read_sql`, over the same contract. The statements are
// the ones every dialect of the contract has — `CREATE TABLE`,
// `DROP TABLE`, `INSERT`, `SELECT` — spelled for the driver's dialect:
// its parameter placeholders, its identifier quoting, and the type names
// its `CREATE TABLE` takes. The values cross the seam bound, never
// spliced into the text.

///|
/// The most bound values one statement carries: SQLite's historical
/// per-statement bound, the narrowest among the dialects of the contract.
const SQL_BOUND_VALUES : Int32 = 999

///|
/// The most digits a `DECIMAL` names on every dialect of the contract.
const SQL_DECIMAL_DIGITS : Int32 = 38

///|
/// What `write_sql` does when the table it names is already there.
#derive(Eq, Debug)
pub(all) enum SqlIfExists {
  /// Create the table; a table already there is the database's own error.
  Fail
  /// Drop the table, then create it.
  Replace
  /// Leave the table as it is and insert into it.
  Append
}

///|
pub extend SqlIfExists with Eq::{equal, not_equal}

///|
pub extend SqlIfExists with Debug::{to_repr}

///|
/// One column of the table being written: its quoted name, its type as
/// the dialect spells it, and the scale its decimal cells are written
/// at — zero for every other dtype.
priv struct SqlColumn {
  name : String
  sql_type : String
  scale : Int32
}

///|
/// The driver's own failure, as the I/O error every SQL entry raises.
fn sql_io_error(e : @moondb.DbError) -> @types.DataError {
  @types.DataError::IoError("sql: \{e}")
}

///|
/// An identifier quoted for a dialect — a column's name, or one part of
/// a table's — whatever it holds: the quote's own character doubled
/// inside it, so a name cannot end its quoting early.
fn sql_quote(name : String, dialect : @moondb.Dialect) -> String {
  let quoted : Char = match dialect {
    Mysql | Clickhouse => '`'
    Sqlserver => ']'
    Sqlite | Postgres | Duckdb => '"'
  }
  let out = StringBuilder()
  if dialect is Sqlserver {
    out.write_char('[')
  } else {
    out.write_char(quoted)
  }
  for c in name {
    if c == quoted {
      out.write_char(quoted)
    }
    out.write_char(c)
  }
  if dialect is Sqlserver {
    out.write_char(']')
  } else {
    out.write_char(quoted)
  }
  out.to_string()
}

///|
/// The table an entry names, each dot-separated part quoted for the
/// dialect — `schema.table` is two quoted names around the dot.
fn sql_table_name(
  table : String,
  dialect : @moondb.Dialect,
) -> String raise @types.DataError {
  let parts : Array[String] = []
  for part in table.split(".") {
    if part.is_empty() {
      raise @types.DataError::InvalidOperation(
        "sql: the table name \"\{table}\" names no table at one of its parts",
      )
    }
    parts.push(sql_quote(part.to_owned(), dialect))
  }
  parts.join(".")
}

///|
/// A column's SQL type for a dialect: its dtype's widest spelling there.
/// A dtype no SQL type of the contract holds refuses, naming the column.
fn sql_type(
  dtype : @types.DataType,
  precision : Int32,
  scale : Int32,
  dialect : @moondb.Dialect,
  column : String,
) -> String raise @types.DataError {
  let integer = if dialect is Sqlite {
    "INTEGER"
  } else if dialect is Clickhouse {
    "Int64"
  } else {
    "BIGINT"
  }
  match dtype {
    Int | Duration => integer
    Float =>
      match dialect {
        Postgres => "DOUBLE PRECISION"
        Sqlite => "REAL"
        Clickhouse => "Float64"
        Sqlserver => "FLOAT(53)"
        Mysql | Duckdb => "DOUBLE"
      }
    Bool =>
      match dialect {
        Postgres | Duckdb => "BOOLEAN"
        Sqlite => "INTEGER"
        Mysql => "TINYINT(1)"
        Clickhouse => "Bool"
        Sqlserver => "BIT"
      }
    String =>
      match dialect {
        Postgres | Mysql | Sqlite => "TEXT"
        Clickhouse => "String"
        Duckdb => "VARCHAR"
        Sqlserver => "NVARCHAR(MAX)"
      }
    // SQLite has no calendar type of its own: a day and an instant land
    // as their ISO text, and read back as text. ClickHouse's type names
    // are its own case.
    Date =>
      match dialect {
        Sqlite => "TEXT"
        Clickhouse => "Date"
        Postgres | Mysql | Duckdb | Sqlserver => "DATE"
      }
    Timestamp =>
      match dialect {
        Sqlite => "TEXT"
        Postgres => "TIMESTAMP"
        Mysql => "DATETIME(6)"
        Clickhouse => "DateTime64(6)"
        Duckdb => "TIMESTAMP"
        Sqlserver => "DATETIME2(6)"
      }
    // The same on SQLite for a decimal: its digits as text, where a
    // numeric affinity would keep a double's digits and no more.
    Decimal(_) =>
      match dialect {
        Sqlite => "TEXT"
        Postgres => "NUMERIC(\{precision},\{scale})"
        Mysql | Duckdb | Sqlserver => "DECIMAL(\{precision},\{scale})"
        Clickhouse => "Decimal(\{precision},\{scale})"
      }
    Null | List(_) | Struct(_) =>
      raise @types.DataError::Unsupported(
        "sql: column \"\{column}\" is of dtype \{dtype}, which no SQL type of the contract holds; cast it before the write",
      )
  }
}

///|
/// The `DECIMAL` window a decimal column is written in: the scale — the
/// most fraction digits its cells count — and the precision, the digits
/// the widest cell lifts to under that scale, and at least one more than
/// the scale. The cells of other dtypes pass through as `(0, 0)`. A NaN
/// or infinite cell has no digits to count, and a column past
/// `SQL_DECIMAL_DIGITS` no type to name, and each refuses.
fn sql_decimal_window(
  cells : Array[@types.Scalar],
  column : String,
) -> (Int32, Int32) raise @types.DataError {
  let mut scale = 0
  let mut lifted = 0
  for cell in cells {
    if cell is @types.Scalar::Decimal(value) {
      match (value.coefficient_digits(), value.exponent()) {
        (Some(digits), Some(exponent)) => {
          let fraction = -exponent
          if fraction > scale {
            scale = fraction
          }
          let reach = digits.length() + exponent
          if reach > lifted {
            lifted = reach
          }
        }
        (_, _) =>
          raise @types.DataError::InvalidOperation(
            "sql: column \"\{column}\" carries a NaN or infinite decimal cell, which has no digit text to bind",
          )
      }
    }
  }
  let precision = if lifted + scale > scale + 1 {
    lifted + scale
  } else {
    scale + 1
  }
  if precision > SQL_DECIMAL_DIGITS {
    raise @types.DataError::InvalidOperation(
      "sql: column \"\{column}\": its cells need a \{precision}-digit decimal, past the \{SQL_DECIMAL_DIGITS} a DECIMAL names on every dialect",
    )
  }
  (precision, scale)
}

///|
/// A decimal cell as the digit text of its column's scale: its
/// coefficient, lifted to the scale, with the point `scale` digits from
/// the end — no exponent, so a driver reads digits and nothing else.
fn sql_decimal_text(
  value : @types.Dec128,
  scale : Int32,
  column : String,
) -> String raise @types.DataError {
  match (value.coefficient_digits(), value.exponent()) {
    (Some(digits), Some(exponent)) => {
      let coefficient = StringBuilder()
      for digit in digits {
        coefficient.write_string(digit.to_string())
      }
      // The window has held the cell, so the lift to the scale is a whole
      // number of zeros; a cell smaller than the unit takes zeros ahead
      // of the point.
      let lifted = coefficient.to_string() + String::make(exponent + scale, '0')
      let places = if lifted.length() <= scale {
        String::make(scale + 1 - lifted.length(), '0') + lifted
      } else {
        lifted
      }
      let out = StringBuilder()
      if value.is_negative() && !value.is_zero() {
        out.write_char('-')
      }
      let point = places.length() - scale
      out.write_substring(places, 0, point)
      if scale > 0 {
        out.write_char('.')
        out.write_substring(places, point, places.length())
      }
      out.to_string()
    }
    (_, _) =>
      raise @types.DataError::InvalidOperation(
        "sql: column \"\{column}\" carries a NaN or infinite decimal cell, which has no digit text to bind",
      )
  }
}

///|
/// One cell as the value the driver binds. A `Date` and a `Timestamp`
/// are their ISO text, a `Duration` its microsecond count (no type of
/// the contract names a span), and a decimal its digit text — on
/// SQLite, where the column declares text, the same digits as `Text`.
fn sql_value(
  cell : @types.Scalar,
  scale : Int32,
  text_decimals : Bool,
  column : String,
) -> @moondb.Value raise @types.DataError {
  match cell {
    Null => @moondb.Value::Null
    Int(v) => Int64(v)
    Duration(v) => Int64(v)
    Float(v) => Double(v)
    Bool(v) => @moondb.Value::Bool(v)
    String(v) => Text(v)
    Date(_) | Timestamp(_) => Time(cell.to_string())
    Decimal(value) => {
      let text = sql_decimal_text(value, scale, column)
      if text_decimals {
        Text(text)
      } else {
        Numeric(text)
      }
    }
    List(_) | Struct(_) =>
      // The columns were planned before any statement was sent, so a
      // list or a struct column has refused already.
      raise @types.DataError::Unsupported(
        "sql: column \"\{column}\" carries a nested cell, which no SQL type of the contract holds",
      )
  }
}

///|
/// Run one statement with its bound values; the driver's own failure is
/// the I/O error.
fn sql_execute(
  driver : &@moondb.Driver,
  sql : String,
  params : Array[@moondb.Value],
) -> Unit raise @types.DataError {
  ignore(driver.execute(sql, params) catch { e => raise sql_io_error(e) })
}

///|
/// Run the write inside a transaction where the dialect has one: a
/// statement that fails rolls back the ones before it — the rollback's
/// own failure displacing nothing — and a dialect without transactions
/// runs the statements as they are.
fn sql_in_transaction(
  driver : &@moondb.Driver,
  write : () -> Unit raise @types.DataError,
) -> Unit raise @types.DataError {
  if !driver.capabilities().transactions {
    return write()
  }
  driver.begin() catch {
    e => raise sql_io_error(e)
  }
  let outcome : Result[Unit, @types.DataError] = Ok(write()) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => driver.commit() catch { e => raise sql_io_error(e) }
    Err(e) => {
      let rolled : Result[Unit, @moondb.DbError] = Ok(driver.rollback()) catch {
        failure => Err(failure)
      }
      ignore(rolled)
      raise e
    }
  }
}

///|
/// The table's `CREATE TABLE`: each column's quoted name and type, and
/// on ClickHouse the engine clause its `CREATE TABLE` asks for — the
/// general-purpose one.
fn sql_create(
  target : String,
  columns : Array[SqlColumn],
  dialect : @moondb.Dialect,
) -> String {
  let out = StringBuilder()
  out.write_string("CREATE TABLE ")
  out.write_string(target)
  out.write_string(" (")
  for i, column in columns {
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string(column.name)
    out.write_char(' ')
    out.write_string(column.sql_type)
  }
  out.write_char(')')
  if dialect is Clickhouse {
    out.write_string(" ENGINE = MergeTree")
  }
  out.to_string()
}

///|
/// Insert the rows, one statement per run of rows whose values fit the
/// per-statement bound: the placeholders numbered across the run, each
/// row's values bound in the columns' order.
fn sql_insert(
  driver : &@moondb.Driver,
  dialect : @moondb.Dialect,
  target : String,
  columns : Array[SqlColumn],
  cells : Array[Array[@types.Scalar]],
  rows : Int32,
) -> Unit raise @types.DataError {
  let width = columns.length()
  let per = SQL_BOUND_VALUES / width
  let text_decimals = dialect is Sqlite
  let names : Array[String] = []
  for column in columns {
    names.push(column.name)
  }
  let head = "INSERT INTO \{target} (\{names.join(", ")}) VALUES "
  let mut start = 0
  while start < rows {
    let count = if rows - start < per { rows - start } else { per }
    let out = StringBuilder()
    out.write_string(head)
    let params : Array[@moondb.Value] = []
    let mut bound = 0
    for r in 0..<count {
      if r > 0 {
        out.write_char(',')
      }
      out.write_char('(')
      for c in 0..<width {
        if c > 0 {
          out.write_char(',')
        }
        bound += 1
        out.write_string(dialect.placeholder(bound))
        params.push(
          sql_value(
            cells[c][start + r],
            columns[c].scale,
            text_decimals,
            columns[c].name,
          ),
        )
      }
      out.write_char(')')
    }
    sql_execute(driver, out.to_string(), params)
    start += count
  }
}

///|
/// Write a frame into a database table through any moondb driver — the
/// counterpart of `read_sql`. `table` names the table, a schema's when
/// it is dot-qualified (`schema.table`); each part is quoted for the
/// driver's dialect, as are the frame's column names, which become the
/// table's columns in the frame's order.
///
/// A column's type is its dtype's, spelled for the dialect: an integer
/// a `BIGINT` (`INTEGER` on SQLite, `Int64` on ClickHouse), a `Float` a
/// double, a `Bool` a boolean (`BIT` on SQL Server, `TINYINT(1)` on
/// MySQL), a `String` text, a `Date` a date, a `Timestamp` a timestamp
/// to the microsecond, and a `Decimal` a `DECIMAL(precision, scale)`
/// whose window is read off the column's cells — the most fraction
/// digits they count. A `Duration` column is written as its microsecond
/// count and reads back `Int`.
///
/// `if_exists` says what to do when the table is already there: `Fail`
/// (the default) creates it and the database's own error surfaces;
/// `Replace` drops it first; `Append` leaves it and only inserts. The
/// rows go in by bound statement, each statement carrying at most 999
/// values — the narrowest per-statement bound among the dialects — so a
/// wide table sends fewer rows per statement. Where the dialect has
/// transactions the write is one: a statement that fails rolls back the
/// ones before it (a DDL statement on MySQL commits as it goes, and
/// ClickHouse has no transaction to roll back). A frame of no row
/// creates the table and inserts nothing.
///
/// SQLite has no boolean, calendar, or decimal type of its own: those
/// cells land as integers, or as their ISO text and digit text in a
/// text column, and read back through `read_sql` as `Int` or `String`.
/// A float cell that is NaN or infinite is bound as it is; whether the
/// database keeps it is the database's own.
///
/// Raises `Unsupported` for a column of a dtype no SQL type holds (a
/// list or a struct) and `InvalidOperation` for a table name with an
/// empty part, a frame with no column or past 999 columns, and a decimal
/// column with a NaN or infinite cell or past the 38-digit window —
/// each before a statement is sent. A statement the database refuses
/// raises `IoError` carrying the driver's own `DbError` text.
pub fn write_sql(
  df : @frame.DataFrame,
  driver : &@moondb.Driver,
  table : String,
  if_exists~ : SqlIfExists = SqlIfExists::Fail,
) -> Unit raise @types.DataError {
  let dialect = driver.dialect()
  let series = df.column_series()
  if series.is_empty() {
    raise @types.DataError::InvalidOperation(
      "sql: a frame with no column names no column to create the table by",
    )
  }
  if series.length() > SQL_BOUND_VALUES {
    raise @types.DataError::InvalidOperation(
      "sql: a frame of \{series.length()} columns is past the \{SQL_BOUND_VALUES} values one statement binds on every dialect",
    )
  }
  let target = sql_table_name(table, dialect)
  // The table is settled before a statement is sent: a column no SQL
  // type holds, or a decimal column past the window, refuses here.
  let cells : Array[Array[@types.Scalar]] = []
  let columns : Array[SqlColumn] = []
  for column in series {
    let values = column.to_scalars()
    cells.push(values)
    let (precision, scale) = sql_decimal_window(values, column.name())
    columns.push({
      name: sql_quote(column.name(), dialect),
      sql_type: sql_type(
        column.dtype(),
        precision,
        scale,
        dialect,
        column.name(),
      ),
      scale,
    })
  }
  sql_in_transaction(driver, fn() -> Unit raise @types.DataError {
    match if_exists {
      Replace => sql_execute(driver, "DROP TABLE IF EXISTS \{target}", [])
      Fail | Append => ()
    }
    match if_exists {
      Append => ()
      Fail | Replace =>
        sql_execute(driver, sql_create(target, columns, dialect), [])
    }
    sql_insert(driver, dialect, target, columns, cells, df.nrows())
  })
}

///|
/// Read one table whole into a frame — `read_sql` over `SELECT … FROM
/// table`, the table's parts quoted for the driver's dialect as
/// `write_sql` quotes them. `columns`, when given, keeps the columns of
/// those names in the table's own order; one the table does not carry
/// is the database's own error. The cell mapping and the errors are
/// `read_sql`'s.
pub fn read_sql_table(
  driver : &@moondb.Driver,
  table : String,
  columns~ : Array[String] = [],
) -> @frame.DataFrame raise @types.DataError {
  let dialect = driver.dialect()
  let target = sql_table_name(table, dialect)
  let picked : Array[String] = []
  for column in columns.copy() {
    picked.push(sql_quote(column, dialect))
  }
  let selection = if picked.is_empty() { "*" } else { picked.join(", ") }
  read_sql(driver, "SELECT \{selection} FROM \{target}")
}
