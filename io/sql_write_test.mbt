// Blackbox tests for the SQL write and the table read, over a driver that
// writes nothing down but what it was asked: every statement with the
// values bound to it, in order, and the transaction calls around them.
// The contract's own MockDriver keeps a statement's values but not its
// text, and the text — the placeholders, the quoting, the type names —
// is half of what these entries promise. The driver can be told to
// refuse a statement, or a transaction call, which is how a write is
// seen rolling back.

///|
/// A driver that records: each statement with the values bound to it, in
/// order, and the transaction calls around them. It speaks the dialect it
/// is given, reports transactions when asked to, refuses the statements
/// whose text begins with `refuse`, and refuses the transaction call
/// `refuse_call` names, when it names one.
struct LedgerDriver {
  dialect : @moondb.Dialect
  mut transactions : Bool
  statements : Array[(String, Array[@moondb.Value])]
  bracket : Array[String]
  mut refuse : String
  mut refuse_call : String
}

///|
/// A ledger for `dialect`, reporting the transactions its dialect's
/// preset reports, and refusing nothing.
fn ledger(dialect : @moondb.Dialect) -> LedgerDriver {
  LedgerDriver::{
    dialect,
    transactions: @moondb.Capabilities::for_dialect(dialect).transactions,
    statements: [],
    bracket: [],
    refuse: "",
    refuse_call: "",
  }
}

///|
/// The statement texts alone, in order.
fn ledger_statements(db : LedgerDriver) -> Array[String] {
  let out : Array[String] = []
  for call in db.statements {
    out.push(call.0)
  }
  out
}

///|
/// Whether a ledger refuses the statement `sql` asks of it.
fn LedgerDriver::refuses(self : LedgerDriver, sql : String) -> Bool {
  self.refuse != "" && sql.has_prefix(self.refuse)
}

///|
impl @moondb.Driver for LedgerDriver with fn execute(
  self : LedgerDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.statements.push((sql, params.copy()))
  if self.refuses(sql) {
    raise @moondb.DbError::QueryError("the database refuses: \{sql}")
  }
  { rows_affected: 1, last_insert_id: 0, }
}

///|
impl @moondb.Driver for LedgerDriver with fn query(
  self : LedgerDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.statements.push((sql, params.copy()))
  []
}

///|
impl @moondb.Driver for LedgerDriver with fn begin(self : LedgerDriver) -> Unit raise @moondb.DbError {
  self.bracket.push("begin")
  if self.refuse_call == "begin" {
    raise @moondb.DbError::QueryError("the database refuses to begin")
  }
}

///|
impl @moondb.Driver for LedgerDriver with fn commit(self : LedgerDriver) -> Unit raise @moondb.DbError {
  self.bracket.push("commit")
  if self.refuse_call == "commit" {
    raise @moondb.DbError::QueryError("the database refuses to commit")
  }
}

///|
impl @moondb.Driver for LedgerDriver with fn rollback(self : LedgerDriver) -> Unit raise @moondb.DbError {
  self.bracket.push("rollback")
  if self.refuse_call == "rollback" {
    raise @moondb.DbError::QueryError("the database refuses to roll back")
  }
}

///|
impl @moondb.Driver for LedgerDriver with fn close(self : LedgerDriver) -> Unit {
  self.bracket.push("close")
}

///|
impl @moondb.Driver for LedgerDriver with fn dialect(self : LedgerDriver) -> @moondb.Dialect {
  self.dialect
}

///|
impl @moondb.Driver for LedgerDriver with fn capabilities(self : LedgerDriver) -> @moondb.Capabilities {
  let preset = @moondb.Capabilities::for_dialect(self.dialect)
  { ..preset, transactions: self.transactions, }
}

///|
extend LedgerDriver with @moondb.Driver::{
  execute,
  query,
  begin,
  commit,
  rollback,
  close,
  dialect,
  capabilities,
}

///|
/// The error a write that was expected to refuse raised; a write that
/// goes through fails the test.
fn sql_refusal(
  run : () -> Unit raise @types.DataError,
) -> @types.DataError raise {
  let outcome : Result[Unit, @types.DataError] = Ok(run()) catch { e => Err(e) }
  match outcome {
    Ok(_) => fail("the write was expected to refuse")
    Err(e) => e
  }
}

///|
fn sql_dec(text : String) -> @types.Scalar {
  @types.Scalar::Decimal(@types.Dec128::parse_opt(text).unwrap())
}

///|
/// A frame of every column shape the write carries, three rows with a
/// null in each; its decimal column counts two fraction digits.
fn sql_frame() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_ints("id", [1, 2, 3]),
    @series.Series::from_scalars(
      "ratio",
      [
        @types.Scalar::Float(1.5),
        @types.Scalar::Null,
        @types.Scalar::Float(-0.25),
      ],
      dtype=@types.DataType::Float,
    ),
    @series.Series::from_scalars(
      "ok",
      [
        @types.Scalar::Bool(true),
        @types.Scalar::Bool(false),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::Bool,
    ),
    @series.Series::from_scalars(
      "name",
      [
        @types.Scalar::String("a"),
        @types.Scalar::Null,
        @types.Scalar::String("c"),
      ],
      dtype=@types.DataType::String,
    ),
    @series.Series::from_scalars(
      "day",
      [@types.Scalar::Date(0), @types.Scalar::Date(19723), @types.Scalar::Null],
      dtype=@types.DataType::Date,
    ),
    @series.Series::from_scalars(
      "at",
      [
        @types.Scalar::Timestamp(0),
        @types.Scalar::Timestamp(-1),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::Timestamp,
    ),
    @series.Series::from_scalars(
      "amount",
      [sql_dec("1.50"), @types.Scalar::Null, sql_dec("-2.25")],
      dtype=@types.DataType::Decimal,
    ),
    @series.Series::from_scalars(
      "span",
      [
        @types.Scalar::Duration(1500000),
        @types.Scalar::Null,
        @types.Scalar::Duration(-1),
      ],
      dtype=@types.DataType::Duration,
    ),
  ])
}

///|
/// The test frame's column list, as a dialect's quoting spells it.
fn quoted_names(open : String, close : String) -> String {
  let out : Array[String] = []
  for name in ["id", "ratio", "ok", "name", "day", "at", "amount", "span"] {
    out.push("\{open}\{name}\{close}")
  }
  out.join(", ")
}

///|
/// The test frame's `CREATE TABLE` on SQLite.
const SQLITE_CREATE : String = "CREATE TABLE \"items\" (\"id\" INTEGER, \"ratio\" REAL, \"ok\" INTEGER, \"name\" TEXT, \"day\" TEXT, \"at\" TEXT, \"amount\" TEXT, \"span\" INTEGER)"

///|
test "write_sql creates the table and inserts the rows by bound statement" {
  let db = ledger(Sqlite)
  @io.write_sql(sql_frame(), db, "items")
  // The write is one transaction.
  assert_eq(db.bracket, ["begin", "commit"])
  assert_eq(ledger_statements(db), [
    SQLITE_CREATE,
    "INSERT INTO \"items\" (\{quoted_names("\"", "\"")}) VALUES (?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?)",
  ])
  // Row by row, each cell as the value its shape binds. On SQLite, which
  // has no boolean, calendar, or decimal type, the calendar values and
  // the decimal are their text — the boolean stays a boolean, for the
  // driver to map.
  assert_eq(db.statements[1].1, [
    @moondb.Value::Int64(1),
    @moondb.Value::Double(1.5),
    @moondb.Value::Bool(true),
    @moondb.Value::Text("a"),
    @moondb.Value::Time("1970-01-01"),
    @moondb.Value::Time("1970-01-01T00:00:00.000000"),
    @moondb.Value::Text("1.50"),
    @moondb.Value::Int64(1500000),
    @moondb.Value::Int64(2),
    @moondb.Value::Null,
    @moondb.Value::Bool(false),
    @moondb.Value::Null,
    @moondb.Value::Time("2024-01-01"),
    @moondb.Value::Time("1969-12-31T23:59:59.999999"),
    @moondb.Value::Null,
    @moondb.Value::Null,
    @moondb.Value::Int64(3),
    @moondb.Value::Double(-0.25),
    @moondb.Value::Null,
    @moondb.Value::Text("c"),
    @moondb.Value::Null,
    @moondb.Value::Null,
    @moondb.Value::Text("-2.25"),
    @moondb.Value::Int64(-1),
  ])
}

///|
test "the statements follow the driver's dialect" {
  let cases : Array[(@moondb.Dialect, String, String)] = [
    (
      Postgres,
      "CREATE TABLE \"items\" (\"id\" BIGINT, \"ratio\" DOUBLE PRECISION, \"ok\" BOOLEAN, \"name\" TEXT, \"day\" DATE, \"at\" TIMESTAMP, \"amount\" NUMERIC(3,2), \"span\" BIGINT)",
      "INSERT INTO \"items\" (\{quoted_names("\"", "\"")}) VALUES ($1,$2,$3,$4,$5,$6,$7,$8),($9,$10,$11,$12,$13,$14,$15,$16),($17,$18,$19,$20,$21,$22,$23,$24)",
    ),
    (
      Mysql,
      "CREATE TABLE `items` (`id` BIGINT, `ratio` DOUBLE, `ok` TINYINT(1), `name` TEXT, `day` DATE, `at` DATETIME(6), `amount` DECIMAL(3,2), `span` BIGINT)",
      "INSERT INTO `items` (\{quoted_names("`", "`")}) VALUES (?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?)",
    ),
    (
      Clickhouse,
      "CREATE TABLE `items` (`id` Int64, `ratio` Float64, `ok` Bool, `name` String, `day` Date, `at` DateTime64(6), `amount` Decimal(3,2), `span` Int64) ENGINE = MergeTree",
      "INSERT INTO `items` (\{quoted_names("`", "`")}) VALUES (?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?)",
    ),
    (
      Duckdb,
      "CREATE TABLE \"items\" (\"id\" BIGINT, \"ratio\" DOUBLE, \"ok\" BOOLEAN, \"name\" VARCHAR, \"day\" DATE, \"at\" TIMESTAMP, \"amount\" DECIMAL(3,2), \"span\" BIGINT)",
      "INSERT INTO \"items\" (\{quoted_names("\"", "\"")}) VALUES (?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?)",
    ),
    (
      Sqlserver,
      "CREATE TABLE [items] ([id] BIGINT, [ratio] FLOAT(53), [ok] BIT, [name] NVARCHAR(MAX), [day] DATE, [at] DATETIME2(6), [amount] DECIMAL(3,2), [span] BIGINT)",
      "INSERT INTO [items] (\{quoted_names("[", "]")}) VALUES (@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8),(@p9,@p10,@p11,@p12,@p13,@p14,@p15,@p16),(@p17,@p18,@p19,@p20,@p21,@p22,@p23,@p24)",
    ),
  ]
  for case in cases {
    let db = ledger(case.0)
    @io.write_sql(sql_frame(), db, "items")
    assert_eq(ledger_statements(db), [case.1, case.2])
    // A decimal binds as its digit text everywhere but SQLite. ClickHouse
    // has no transaction to bracket the write.
    let first = db.statements[1].1
    assert_eq(first[6], @moondb.Value::Numeric("1.50"))
    assert_eq(first[22], @moondb.Value::Numeric("-2.25"))
    let bracket : Array[String] = if case.0 is Clickhouse {
      []
    } else {
      ["begin", "commit"]
    }
    assert_eq(db.bracket, bracket)
  }
}

///|
test "if_exists drops the table first, or leaves it, or lets the database refuse" {
  let insert = "INSERT INTO \"items\" (\{quoted_names("\"", "\"")}) VALUES (?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?)"
  // Replace: the drop, the create, the insert, in one transaction.
  let replace = ledger(Sqlite)
  @io.write_sql(sql_frame(), replace, "items", if_exists=Replace)
  assert_eq(ledger_statements(replace), [
    "DROP TABLE IF EXISTS \"items\"",
    SQLITE_CREATE,
    insert,
  ])
  assert_eq(replace.bracket, ["begin", "commit"])
  // Append: the insert alone.
  let append = ledger(Sqlite)
  @io.write_sql(sql_frame(), append, "items", if_exists=Append)
  assert_eq(ledger_statements(append), [insert])
  // Fail, the default: the create is sent, and a table already there is
  // the database's own refusal.
  let exists = ledger(Sqlite)
  exists.refuse = "CREATE"
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(sql_frame(), exists, "items")
    })
    is @types.DataError::IoError(m) &&
    m.contains("the database refuses: CREATE"),
  )
  assert_eq(exists.bracket, ["begin", "rollback"])
}

///|
test "a frame of no row creates the table, and appends nothing" {
  let empty = sql_frame().slice(0, length=0)
  let db = ledger(Sqlite)
  @io.write_sql(empty, db, "items")
  assert_eq(ledger_statements(db), [SQLITE_CREATE])
  assert_eq(db.bracket, ["begin", "commit"])
  // With no cell to count, the decimal column takes the narrowest window.
  let postgres = ledger(Postgres)
  @io.write_sql(empty, postgres, "items")
  assert_true(
    ledger_statements(postgres)[0].contains("\"amount\" NUMERIC(1,0)"),
  )
  // Appending nothing sends no statement at all.
  let append = ledger(Sqlite)
  @io.write_sql(empty, append, "items", if_exists=Append)
  assert_eq(ledger_statements(append), [])
  assert_eq(append.bracket, ["begin", "commit"])
}

///|
test "the rows go in by runs that fit the per-statement bound" {
  let wide = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("a", Array::makei(1000, i => i.to_int64())),
    @series.Series::from_ints("b", Array::makei(1000, i => (2 * i).to_int64())),
  ])
  let db = ledger(Postgres)
  @io.write_sql(wide, db, "t")
  let inserts = db.statements.filter(s => s.0.has_prefix("INSERT"))
  // Two columns leave room for 499 rows a statement: two full runs and
  // the two remaining rows.
  assert_eq(inserts.map(s => s.1.length()), [998, 998, 4])
  // The placeholders are numbered across the run and start over with the
  // next statement.
  assert_true(
    inserts[0].0.has_prefix("INSERT INTO \"t\" (\"a\", \"b\") VALUES ($1,$2)"),
  )
  assert_true(inserts[0].0.contains(",($997,$998)"))
  assert_eq(
    inserts[2].0,
    "INSERT INTO \"t\" (\"a\", \"b\") VALUES ($1,$2),($3,$4)",
  )
  assert_eq(inserts[0].1[996], @moondb.Value::Int64(498))
  assert_eq(inserts[0].1[997], @moondb.Value::Int64(996))
  assert_eq(inserts[2].1, [
    @moondb.Value::Int64(998),
    @moondb.Value::Int64(1996),
    @moondb.Value::Int64(999),
    @moondb.Value::Int64(1998),
  ])
  // The bracket holds the create and every run.
  assert_eq(db.bracket, ["begin", "commit"])
  assert_eq(db.statements.length(), 4)
}

///|
test "a statement the database refuses rolls the transaction back" {
  let insert = ledger(Sqlite)
  insert.refuse = "INSERT"
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(sql_frame(), insert, "items")
    })
    is @types.DataError::IoError(m) &&
    m.contains("the database refuses: INSERT"),
  )
  assert_eq(insert.bracket, ["begin", "rollback"])
  // A refusal under Replace rolls back past the drop.
  let create = ledger(Sqlite)
  create.refuse = "CREATE"
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(sql_frame(), create, "items", if_exists=Replace)
    })
    is @types.DataError::IoError(m) &&
    m.contains("the database refuses: CREATE"),
  )
  assert_eq(create.statements.length(), 2)
  assert_eq(create.bracket, ["begin", "rollback"])
  // A rollback the database refuses displaces nothing: the write's own
  // error is still the one raised, naming its statement.
  let stuck = ledger(Sqlite)
  stuck.refuse = "INSERT"
  stuck.refuse_call = "rollback"
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(sql_frame(), stuck, "items")
    })
    is @types.DataError::IoError(m) &&
    m.contains("the database refuses: INSERT"),
  )
  assert_eq(stuck.bracket, ["begin", "rollback"])
}

///|
test "a transaction call the database refuses surfaces" {
  let commit = ledger(Sqlite)
  commit.refuse_call = "commit"
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(sql_frame(), commit, "items")
    })
    is @types.DataError::IoError(m) &&
    m.contains("refuses to commit"),
  )
  assert_eq(commit.statements.length(), 2)
  let begin = ledger(Sqlite)
  begin.refuse_call = "begin"
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(sql_frame(), begin, "items")
    })
    is @types.DataError::IoError(m) &&
    m.contains("refuses to begin"),
  )
  // Nothing follows a refused begin.
  assert_eq(begin.statements, [])
  assert_eq(begin.bracket, ["begin"])
}

///|
test "a driver without transactions runs the statements as they are" {
  // ClickHouse's preset: no transaction to bracket the write.
  let clickhouse = ledger(Clickhouse)
  @io.write_sql(sql_frame(), clickhouse, "items")
  assert_eq(clickhouse.bracket, [])
  assert_eq(clickhouse.statements.length(), 2)
  // A refusal leaves the statements before it where they fell.
  let failing = ledger(Clickhouse)
  failing.refuse = "INSERT"
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(sql_frame(), failing, "items")
    })
    is @types.DataError::IoError(_),
  )
  assert_eq(failing.bracket, [])
  assert_eq(failing.statements.length(), 2)
  // A driver that reports no transaction on a dialect whose preset has
  // one is believed the same way.
  let flat = ledger(Sqlite)
  flat.transactions = false
  @io.write_sql(sql_frame(), flat, "items")
  assert_eq(flat.bracket, [])
  assert_eq(flat.statements.length(), 2)
}

///|
test "what no SQL type holds refuses before a statement is sent" {
  let db = ledger(Sqlite)
  let nested = @frame.DataFrame::DataFrame([
    @series.Series::from_scalars(
      "l",
      [
        @types.Scalar::List(
          @types.ListValue::ListValue([@types.Scalar::Int(1)]),
        ),
      ],
      dtype=@types.DataType::List(@types.DataType::Int),
    ),
  ])
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(nested, db, "items")
    })
    is @types.DataError::Unsupported(m) &&
    m.contains("column \"l\" is of dtype List(Int), which no SQL type"),
  )
  let record = @frame.DataFrame::DataFrame([
    @series.Series::from_scalars(
      "s",
      [
        @types.Scalar::Struct(
          @types.StructValue::StructValue([
            @types.FieldValue::FieldValue("a", @types.Scalar::Int(1)),
          ]),
        ),
        @types.Scalar::Null,
      ],
      dtype=@types.DataType::Struct(
        @types.Schema::Schema([@types.Field::Field("a", @types.DataType::Int)]),
      ),
    ),
  ])
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(record, db, "items")
    })
    is @types.DataError::Unsupported(m) &&
    m.contains("dtype Struct(a: Int)"),
  )
  // A NaN decimal cell, and a decimal column past the window.
  let nan = @frame.DataFrame::DataFrame([
    @series.Series::from_scalars(
      "d",
      [@types.Scalar::Decimal(@types.Dec128::nan())],
      dtype=@types.DataType::Decimal,
    ),
  ])
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(nan, db, "items")
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains("column \"d\" carries a NaN or infinite decimal cell"),
  )
  let wide = @frame.DataFrame::DataFrame([
    @series.Series::from_scalars(
      "d",
      [sql_dec("1E+38")],
      dtype=@types.DataType::Decimal,
    ),
  ])
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(wide, db, "items")
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains("39-digit decimal, past the 38"),
  )
  // A table name with an empty part, a frame with no column, and a frame
  // past the per-statement bound in columns alone.
  for table in ["", "a..b", ".items", "items."] {
    assert_true(
      sql_refusal(fn() -> Unit raise @types.DataError {
        @io.write_sql(sql_frame(), db, table)
      })
      is @types.DataError::InvalidOperation(m) &&
      m.contains("names no table at one of its parts"),
    )
  }
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(@frame.DataFrame::DataFrame([]), db, "items")
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains("a frame with no column"),
  )
  let many = @frame.DataFrame::DataFrame(
    Array::makei(1000, i => @series.Series::from_ints("c\{i}", [i.to_int64()])),
  )
  assert_true(
    sql_refusal(fn() -> Unit raise @types.DataError {
      @io.write_sql(many, db, "items")
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains("a frame of 1000 columns is past the 999"),
  )
  // None of them reached the driver.
  assert_eq(db.statements, [])
  assert_eq(db.bracket, [])
}

///|
test "an identifier is quoted whatever it holds, and a table's parts one by one" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("a\"b", [1]),
    @series.Series::from_ints("c`d", [2]),
    @series.Series::from_ints("e]f", [3]),
  ])
  let ansi = ledger(Postgres)
  @io.write_sql(df, ansi, "sch\"ema.my\"table")
  assert_eq(
    ledger_statements(ansi)[0],
    "CREATE TABLE \"sch\"\"ema\".\"my\"\"table\" (\"a\"\"b\" BIGINT, \"c`d\" BIGINT, \"e]f\" BIGINT)",
  )
  let mysql = ledger(Mysql)
  @io.write_sql(df, mysql, "sch`ema.my`table")
  assert_eq(
    ledger_statements(mysql)[0],
    "CREATE TABLE `sch``ema`.`my``table` (`a\"b` BIGINT, `c``d` BIGINT, `e]f` BIGINT)",
  )
  let tsql = ledger(Sqlserver)
  @io.write_sql(df, tsql, "sch]ema.my]table")
  assert_eq(
    ledger_statements(tsql)[0],
    "CREATE TABLE [sch]]ema].[my]]table] ([a\"b] BIGINT, [c`d] BIGINT, [e]]f] BIGINT)",
  )
  // A name with a space in it is kept as it is.
  let spaced = ledger(Sqlite)
  @io.write_sql(
    @frame.DataFrame::DataFrame([@series.Series::from_ints("the id", [1])]),
    spaced,
    "my items",
  )
  assert_eq(
    ledger_statements(spaced)[0],
    "CREATE TABLE \"my items\" (\"the id\" INTEGER)",
  )
}

///|
test "read_sql_table selects the table's columns" {
  let db = ledger(Postgres)
  ignore(@io.read_sql_table(db, "public.users"))
  assert_eq(ledger_statements(db), ["SELECT * FROM \"public\".\"users\""])
  ignore(@io.read_sql_table(db, "users", columns=["id", "na\"me"]))
  assert_eq(
    ledger_statements(db)[1],
    "SELECT \"id\", \"na\"\"me\" FROM \"users\"",
  )
  let tsql = ledger(Sqlserver)
  ignore(@io.read_sql_table(tsql, "dbo.users", columns=["id"]))
  assert_eq(ledger_statements(tsql), ["SELECT [id] FROM [dbo].[users]"])
  // A table name with an empty part refuses before the query is sent.
  let empty : Result[@frame.DataFrame, @types.DataError] = Ok(
    @io.read_sql_table(db, "public."),
  ) catch {
    e => Err(e)
  }
  assert_true(
    empty is Err(@types.DataError::InvalidOperation(m)) &&
    m.contains("names no table"),
  )
  assert_eq(ledger_statements(db).length(), 2)
  // Over moondb's own MockDriver the rows come back as the read maps
  // them.
  let mock = @moondb.MockDriver::new()
  mock.execute("insert", [@moondb.Value::Int64(7), @moondb.Value::Text("x")])
  |> ignore
  mock.execute("insert", [@moondb.Value::Int64(8), @moondb.Value::Null])
  |> ignore
  let table = @io.read_sql_table(mock, "users")
  assert_eq(table.columns(), ["c0", "c1"])
  assert_eq(table.nrows(), 2)
  assert_eq(table.get_column("c1").to_scalars(), [
    @types.Scalar::String("x"),
    @types.Scalar::Null,
  ])
}

///|
test "the ledger driver satisfies the whole contract" {
  // Each arm called on the driver itself: the entries reach them through
  // the trait object, and this keeps the implementation exercised rather
  // than merely linked.
  let db = ledger(Sqlite)
  ignore(db.execute("insert", []))
  assert_eq(db.query("select", []), [])
  db.begin()
  db.commit()
  db.begin()
  db.rollback()
  db.close()
  assert_eq(db.dialect(), Sqlite)
  assert_true(db.capabilities().transactions)
  assert_eq(db.bracket, ["begin", "commit", "begin", "rollback", "close"])
  assert_eq(ledger_statements(db), ["insert", "select"])
}
