// Blackbox tests for the lazy SQL source, over a driver whose cursor
// counts the rows it is asked for — which is how a sunk window is seen
// stopping the read — and whose rows are set per test. Each opened read
// gets a cursor of its own, and the driver records every run: its text,
// its bound values, how many rows were pulled, and whether the cursor
// was closed. A driver can be told to refuse the query, or to have its
// cursor fail at a row.

///|
/// A cursor over set rows, counting its pulls and its closing into the
/// driver's record of the run it was opened for.
struct TallyCursor {
  rows : Array[@moondb.Row]
  mut at : Int32
  fail_at : Int32
  pulled : Array[Int32]
  closed : Array[Bool]
  run : Int32
}

///|
impl @moondb.Cursor for TallyCursor with fn next(self : TallyCursor) -> @moondb.Row? raise @moondb.DbError {
  if self.fail_at >= 0 && self.at == self.fail_at {
    raise @moondb.DbError::QueryError("the cursor fails at its row")
  }
  if self.at >= self.rows.length() {
    None
  } else {
    let row = self.rows[self.at]
    self.at += 1
    self.pulled[self.run] += 1
    Some(row)
  }
}

///|
impl @moondb.Cursor for TallyCursor with fn close(self : TallyCursor) -> Unit {
  self.closed[self.run] = true
}

///|
extend TallyCursor with @moondb.Cursor::{next, close}

///|
/// A driver whose every query streams `rows`: one cursor per run, each
/// counted, and every run's text and values recorded. Told to `fail`, it
/// refuses the query; told a `fail_at` row, its cursor fails there.
struct TallyDriver {
  rows : Array[@moondb.Row]
  runs : Array[(String, Array[@moondb.Value])]
  pulled : Array[Int32]
  closed : Array[Bool]
  mut fail : Bool
  mut fail_at : Int32
}

///|
/// A tally driver answering `rows` to every query.
fn tally(rows : Array[@moondb.Row]) -> TallyDriver {
  TallyDriver::{
    rows,
    runs: [],
    pulled: [],
    closed: [],
    fail: false,
    fail_at: -1,
  }
}

///|
/// A tally driver answering one `i` column: the integers from `0` up to
/// `count`, each through `cell`.
fn tally_ints(count : Int32, cell : (Int32) -> @moondb.Value) -> TallyDriver {
  let rows : Array[@moondb.Row] = []
  for k in 0..<count {
    rows.push({ columns: ["i"], values: [cell(k)], })
  }
  tally(rows)
}

///|
/// A tally of ten integers, `0` to `9`.
fn tally_ten() -> TallyDriver {
  tally_ints(10, k => Int64(k.to_int64()))
}

///|
impl @moondb.Driver for TallyDriver with fn execute(
  _self : TallyDriver,
  _sql : String,
  _params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  { rows_affected: 0, last_insert_id: 0, }
}

///|
impl @moondb.Driver for TallyDriver with fn query(
  self : TallyDriver,
  _sql : String,
  _params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.rows.copy()
}

///|
impl @moondb.Driver for TallyDriver with fn query_stream(
  self : TallyDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> &@moondb.Cursor raise @moondb.DbError {
  if self.fail {
    raise @moondb.DbError::QueryError("the database refuses the query")
  }
  let run = self.runs.length()
  self.runs.push((sql, params.copy()))
  self.pulled.push(0)
  self.closed.push(false)
  TallyCursor::{
    rows: self.rows,
    at: 0,
    fail_at: self.fail_at,
    pulled: self.pulled,
    closed: self.closed,
    run,
  }
}

///|
impl @moondb.Driver for TallyDriver with fn begin(self : TallyDriver) -> Unit raise @moondb.DbError {
  ignore(self)
}

///|
impl @moondb.Driver for TallyDriver with fn commit(self : TallyDriver) -> Unit raise @moondb.DbError {
  ignore(self)
}

///|
impl @moondb.Driver for TallyDriver with fn rollback(self : TallyDriver) -> Unit raise @moondb.DbError {
  ignore(self)
}

///|
impl @moondb.Driver for TallyDriver with fn close(self : TallyDriver) -> Unit {
  ignore(self)
}

///|
extend TallyDriver with @moondb.Driver::{
  execute,
  query,
  query_stream,
  begin,
  commit,
  rollback,
  close,
}

///|
/// The error a collect that was expected to refuse raised; one that goes
/// through fails the test.
fn scan_refusal(plan : @frame.LazyFrame) -> @types.DataError raise {
  let outcome : Result[@frame.DataFrame, @types.DataError] = Ok(plan.collect()) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the collect was expected to refuse")
    Err(e) => e
  }
}

///|
test "scan_sql answers what read_sql answers" {
  let db = tally([
    {
      columns: ["id", "ratio", "ok", "name", "at", "amount", "none"],
      values: [
        @moondb.Value::Int(1),
        @moondb.Value::Double(1.5),
        @moondb.Value::Bool(true),
        @moondb.Value::Text("a"),
        @moondb.Value::Time("2024-01-01T00:00:00Z"),
        @moondb.Value::Numeric("150.25"),
        @moondb.Value::Null,
      ],
    },
    {
      columns: ["id", "ratio", "ok", "name", "at", "amount", "none"],
      values: [
        @moondb.Value::Int64(2),
        @moondb.Value::Double(2.5),
        @moondb.Value::Bool(false),
        @moondb.Value::Null,
        @moondb.Value::Time("2024-06-01T12:30:00.250000Z"),
        @moondb.Value::Numeric("-0.75"),
        @moondb.Value::Null,
      ],
    },
  ])
  let plan = @io.scan_sql(db, "select")
  // Nothing ran to build the plan.
  assert_eq(db.runs.length(), 0)
  let got = plan.collect()
  assert_eq(got, @io.read_sql(db, "select"))
  assert_eq(got.columns(), ["id", "ratio", "ok", "name", "at", "amount", "none"])
  assert_eq(got.get_column("ratio").dtype(), @types.DataType::Float)
  assert_eq(got.get_column("at").dtype(), @types.DataType::Timestamp)
  assert_eq(got.get_column("amount").dtype(), @types.DataType::Decimal)
  assert_eq(got.get_column("none").dtype(), @types.DataType::String)
  // One run, its cursor read to the end and closed.
  assert_eq(db.runs.length(), 1)
  assert_eq(db.runs[0].0, "select")
  assert_eq(db.pulled, [2])
  assert_eq(db.closed, [true])
}

///|
/// Collect a plan over a fresh tally of ten integers and check the cells
/// it answers and how many rows the one read pulled.
fn check_window(
  build : (TallyDriver) -> @frame.LazyFrame,
  want : Array[Int64],
  pulls : Int32,
) -> Unit raise {
  let db = tally_ten()
  let got = build(db).collect()
  assert_eq(
    got.get_column("i").to_scalars().copy(),
    want.map(v => @types.Scalar::Int(v)),
  )
  assert_eq(got.columns(), ["i"])
  assert_eq(db.runs.length(), 1)
  assert_eq(db.pulled, [pulls])
  assert_eq(db.closed, [true])
}

///|
test "a sunk head or slice stops the read at the window's end" {
  check_window(db => @io.scan_sql(db, "select"), all_ten(), 10)
  check_window(db => @io.scan_sql(db, "select").head(3), [0, 1, 2], 3)
  // A head past the answer is the whole answer.
  check_window(db => @io.scan_sql(db, "select").head(100), all_ten(), 10)
  check_window(db => @io.scan_sql(db, "select").slice(1, length=2), [1, 2], 3)
  check_window(db => @io.scan_sql(db, "select").slice(7), [7, 8, 9], 10)
  // The rows the eager read's window answers are the same.
  let db = tally_ten()
  assert_eq(
    @io.scan_sql(db, "select").slice(1, length=2).collect(),
    @io.read_sql(db, "select").slice(1, length=2),
  )
}

///|
test "a sunk tail reads the answer whole, for its row count" {
  check_window(db => @io.scan_sql(db, "select").tail(2), [8, 9], 10)
  check_window(db => @io.scan_sql(db, "select").tail(100), all_ten(), 10)
  let db = tally_ten()
  assert_eq(
    @io.scan_sql(db, "select").tail(2).collect(),
    @io.read_sql(db, "select").tail(2),
  )
}

///|
fn all_ten() -> Array[Int64] {
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
}

///|
test "a window that keeps no row still answers the columns" {
  // One row is pulled to learn the columns, and nothing after the
  // window's end — a slice of no length stops at its offset, without
  // pulling the row the offset names.
  check_window(db => @io.scan_sql(db, "select").head(0), [], 1)
  check_window(db => @io.scan_sql(db, "select").slice(4, length=0), [], 4)
  // A window past the answer's end reads the answer to be sure.
  check_window(db => @io.scan_sql(db, "select").slice(20, length=2), [], 10)
  check_window(db => @io.scan_sql(db, "select").tail(0), [], 10)
  let db = tally_ten()
  let got = @io.scan_sql(db, "select").head(0).collect()
  assert_eq(got.shape(), (0, 1))
  // The columns are typed by the answer's first row, the row an eager
  // read would have typed its first batch by.
  assert_eq(got.get_column("i").dtype(), @types.DataType::Int)
  assert_eq(got, @io.read_sql(db, "select").head(0))
  let counted = tally_ten()
  assert_eq(
    @io.scan_sql(counted, "select").tail(0).collect(),
    @io.read_sql(counted, "select").tail(0),
  )
}

///|
test "the plan renders the sunk window on the scan line" {
  let db = tally_ten()
  assert_eq(
    @io.scan_sql(db, "select").head(2).explain(optimized=true),
    "SCAN_SQL \"select\" WINDOW HEAD 2",
  )
  assert_eq(
    @io.scan_sql(db, "select").tail(2).explain(optimized=true),
    "SCAN_SQL \"select\" WINDOW TAIL 2",
  )
  assert_eq(
    @io.scan_sql(db, "select").explain(optimized=true),
    "SCAN_SQL \"select\"",
  )
  // Explaining runs nothing.
  assert_eq(db.runs.length(), 0)
}

///|
test "the projection names the columns built, and the predicate's ride along" {
  let rows : Array[@moondb.Row] = []
  for k in 1..<=3 {
    rows.push({
      columns: ["a", "b", "z"],
      values: [
        @moondb.Value::Int64(k.to_int64()),
        @moondb.Value::Text(if k == 2 { "x" } else { "y" }),
        @moondb.Value::Blob(b"\x00"),
      ],
    })
  }
  let db = tally(rows)
  // A projection that leaves z out never reads z's cells.
  let projected = @io.scan_sql(db, "select").select([@expr.col("a")]).collect()
  assert_eq(projected.columns(), ["a"])
  assert_eq(projected.get_column("a").to_scalars().copy(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
  // The whole read meets z's cells and refuses, as `read_sql` does.
  assert_true(
    scan_refusal(@io.scan_sql(db, "select")) is @types.DataError::Unsupported(m) &&
    m.contains("column \"z\" carries a Blob cell"),
  )
  // The predicate's own column rides the build though the projection
  // omits it.
  let filtered = @io.scan_sql(db, "select")
    .filter(@expr.col("b").eq(@expr.lit_str("x")))
    .select([@expr.col("a")])
    .collect()
  assert_eq(filtered.columns(), ["a"])
  assert_eq(filtered.get_column("a").to_scalars().copy(), [
    @types.Scalar::Int(2),
  ])
  // The batch keeps the answer's column order; the plan's own selection
  // reorders above it.
  let reordered = @io.scan_sql(db, "select")
    .select([@expr.col("b"), @expr.col("a")])
    .collect()
  assert_eq(reordered.columns(), ["b", "a"])
}

///|
test "the answer streams in batches" {
  let db = tally_ints(10000, k => Int64(k.to_int64()))
  let stream = @io.scan_sql(db, "select").collect_batches()
  let heights : Array[Int32] = []
  let mut done = false
  while !done {
    match stream.next() {
      Some(batch) => heights.push(batch.nrows())
      None => done = true
    }
  }
  assert_eq(heights, [4096, 4096, 1808])
  assert_eq(db.runs.length(), 1)
  assert_eq(db.pulled, [10000])
}

///|
test "a later batch is held to the first batch's dtypes" {
  // Integers, then a double: the first batch answered an `Int` column,
  // and the later cell refuses rather than widening what was answered.
  let late_double = tally_ints(5000, k => {
    if k < 4096 {
      Int64(k.to_int64())
    } else {
      Double(k.to_double())
    }
  })
  assert_true(
    scan_refusal(@io.scan_sql(late_double, "select"))
    is @types.DataError::InvalidOperation(m) &&
    m.contains(
      "column \"i\" holds a Float cell where its first batch held Int ones, and a stream cannot widen a column it has answered; cast the column in the query",
    ),
  )
  // The refusal comes once the second batch is pulled, whole.
  assert_eq(late_double.pulled, [5000])
  // Doubles, then integers: the integers lift into the `Float` column.
  let late_int = tally_ints(5000, k => {
    if k < 4096 {
      Double(k.to_double())
    } else {
      Int64(k.to_int64())
    }
  })
  let lifted = @io.scan_sql(late_int, "select").collect()
  assert_eq(lifted.nrows(), 5000)
  assert_eq(lifted.get_column("i").dtype(), @types.DataType::Float)
  assert_eq(
    lifted.get_column("i").to_scalars()[4999],
    @types.Scalar::Float(4999.0),
  )
  // A column of nothing but nulls in its first batch is `String`, and a
  // typed cell later refuses.
  let late_typed = tally_ints(5000, k => {
    if k < 4096 {
      Null
    } else {
      Int64(k.to_int64())
    }
  })
  assert_true(
    scan_refusal(@io.scan_sql(late_typed, "select"))
    is @types.DataError::InvalidOperation(m) &&
    m.contains("holds a Int cell where its first batch held String ones"),
  )
  // A null cell in any batch lands as a null.
  let sparse = tally_ints(5000, k => {
    if k % 7 == 0 {
      Null
    } else {
      Int64(k.to_int64())
    }
  })
  let sparse_got = @io.scan_sql(sparse, "select").collect()
  assert_eq(
    sparse_got.get_column("i").to_scalars()[4999],
    @types.Scalar::Int(4999),
  )
  assert_eq(sparse_got.get_column("i").to_scalars()[4998], @types.Scalar::Null)
}

///|
test "an empty answer is the empty frame" {
  let db = tally([])
  assert_eq(@io.scan_sql(db, "select").collect().shape(), (0, 0))
  assert_eq(db.pulled, [0])
  assert_eq(db.closed, [true])
  // A window over nothing answers nothing: there are no columns to name.
  assert_eq(@io.scan_sql(db, "select").head(3).collect().shape(), (0, 0))
  assert_eq(@io.scan_sql(db, "select").tail(3).collect().shape(), (0, 0))
}

///|
test "the builder is total, and the query's failure surfaces at collect" {
  let db = tally_ten()
  db.fail = true
  let plan = @io.scan_sql(db, "select")
  assert_eq(db.runs.length(), 0)
  assert_true(
    scan_refusal(plan) is @types.DataError::IoError(m) &&
    m.contains("the database refuses the query"),
  )
  // A cursor that fails partway, in a streaming read and in a counted one.
  let mid = tally_ten()
  mid.fail_at = 4
  assert_true(
    scan_refusal(@io.scan_sql(mid, "select")) is @types.DataError::IoError(m) &&
    m.contains("the cursor fails at its row"),
  )
  let counted = tally_ten()
  counted.fail_at = 4
  assert_true(
    scan_refusal(@io.scan_sql(counted, "select").tail(2))
    is @types.DataError::IoError(m) &&
    m.contains("the cursor fails at its row"),
  )
  assert_eq(counted.closed, [true])
}

///|
test "a row narrower than the first refuses" {
  let db = tally([
    {
      columns: ["a", "b"],
      values: [@moondb.Value::Int(1), @moondb.Value::Int(2)],
    },
    { columns: ["a"], values: [@moondb.Value::Int(3)], },
  ])
  assert_true(
    scan_refusal(@io.scan_sql(db, "select"))
    is @types.DataError::ParseError(@types.ParseErrorDetail::Message(m)) &&
    m.contains("a row carries 1 columns but the first carried 2"),
  )
}

///|
test "the bound values are the builder's, not the caller's array" {
  let db = tally_ten()
  let params : Array[@moondb.Value] = [@moondb.Value::Int64(7)]
  let plan = @io.scan_sql(db, "select * from t where id = ?", params~)
  // Mutating the array after the plan is built changes nothing the read
  // binds.
  params[0] = @moondb.Value::Int64(9)
  ignore(plan.collect())
  assert_eq(db.runs[0].0, "select * from t where id = ?")
  assert_eq(db.runs[0].1, [@moondb.Value::Int64(7)])
  // A second collect is a second run, over the same values.
  ignore(plan.collect())
  assert_eq(db.runs.length(), 2)
  assert_eq(db.runs[1].1, [@moondb.Value::Int64(7)])
}

///|
test "the tally driver satisfies the whole contract" {
  // Each arm called on the driver itself, as the contract spells it.
  let db = tally_ten()
  ignore(db.execute("insert", []))
  assert_eq(db.query("select", []).length(), 10)
  ignore(db.query_stream("select", []))
  db.begin()
  db.commit()
  db.rollback()
  db.close()
  // The cursor's own two arms, on a cursor of its own.
  let pulled : Array[Int32] = [0]
  let closed : Array[Bool] = [false]
  let cursor = TallyCursor::{
    rows: [],
    at: 0,
    fail_at: -1,
    pulled,
    closed,
    run: 0,
  }
  assert_true(cursor.next() is None)
  cursor.close()
  assert_eq(closed, [true])
}
