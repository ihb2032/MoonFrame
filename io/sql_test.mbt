// Blackbox tests for the SQL source: read_sql over moondb's own
// MockDriver (the reference in-memory driver the contract ships with —
// it answers every query with the rows its INSERTs recorded, the
// columns named c0, c1, …, and no WHERE honoured), plus a hand-rolled
// driver for the contract corners MockDriver cannot answer: a failing
// query, and a row whose width disagrees with the first's.

///|
test "read_sql answers every scalar dtype" {
  let db = @moondb.MockDriver::new()
  db.execute("insert", [
    @moondb.Value::Int64(1),
    @moondb.Value::Double(72.5),
    @moondb.Value::Bool(true),
    @moondb.Value::Text("Nova"),
    @moondb.Value::Time("2024-01-01T00:00:00Z"),
    @moondb.Value::Numeric("150.25"),
  ])
  |> ignore
  db.execute("insert", [
    @moondb.Value::Null,
    @moondb.Value::Null,
    @moondb.Value::Null,
    @moondb.Value::Null,
    @moondb.Value::Null,
    @moondb.Value::Null,
  ])
  |> ignore
  let df = @io.read_sql(db, "select")
  assert_eq(df.nrows(), 2)
  assert_eq(df.columns(), ["c0", "c1", "c2", "c3", "c4", "c5"])
  assert_eq(df.get_column("c0").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("c0").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Null,
  ])
  assert_eq(df.get_column("c1").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("c2").dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("c3").dtype(), @types.DataType::String)
  assert_eq(df.get_column("c4").dtype(), @types.DataType::Timestamp)
  assert_eq(df.get_column("c4").to_scalars(), [
    @types.Scalar::Timestamp(1_704_067_200_000_000),
    @types.Scalar::Null,
  ])
  assert_eq(df.get_column("c5").dtype(), @types.DataType::Decimal)
}

///|
test "read_sql's numeric lattice widens integer and double mixes" {
  let db = @moondb.MockDriver::new()
  db.execute("insert", [@moondb.Value::Int(1), @moondb.Value::Double(2.5)])
  |> ignore
  db.execute("insert", [@moondb.Value::Double(9.5), @moondb.Value::Int(4)])
  |> ignore
  let df = @io.read_sql(db, "select")
  // Both directions of the meeting lift the column to Float.
  assert_eq(df.get_column("c0").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("c0").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(9.5),
  ])
  assert_eq(df.get_column("c1").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("c1").to_scalars(), [
    @types.Scalar::Float(2.5),
    @types.Scalar::Float(4.0),
  ])
  // Int and Int64 alone stay Int.
  let db2 = @moondb.MockDriver::new()
  db2.execute("insert", [@moondb.Value::Int(3), @moondb.Value::Int64(4)])
  |> ignore
  let ints = @io.read_sql(db2, "select")
  assert_eq(ints.get_column("c0").dtype(), @types.DataType::Int)
  assert_eq(ints.get_column("c1").dtype(), @types.DataType::Int)
}

///|
test "read_sql refuses what a frame column cannot carry" {
  // A container-shaped cell.
  let db = @moondb.MockDriver::new()
  db.execute("insert", [@moondb.Value::Blob(b"\x00")]) |> ignore
  let refused = Ok(ignore(@io.read_sql(db, "select"))) catch { e => Err(e) }
  assert_true(
    refused is Err(@types.DataError::Unsupported(m)) &&
    m.contains("Blob cell MoonFrame does not read"),
  )
  // A dtype mix the lattice does not reconcile.
  let db2 = @moondb.MockDriver::new()
  db2.execute("insert", [@moondb.Value::Int(1)]) |> ignore
  db2.execute("insert", [@moondb.Value::Text("x")]) |> ignore
  let mixed = Ok(ignore(@io.read_sql(db2, "select"))) catch { e => Err(e) }
  assert_true(
    mixed is Err(@types.DataError::InvalidOperation(m2)) &&
    m2.contains("mixes Int and String cells"),
  )
  // A Time text that does not parse.
  let db3 = @moondb.MockDriver::new()
  db3.execute("insert", [@moondb.Value::Time("not-a-time")]) |> ignore
  let bad_time = Ok(ignore(@io.read_sql(db3, "select"))) catch { e => Err(e) }
  assert_true(
    bad_time
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(t))) &&
    t.contains("does not parse as a timestamp"),
  )
  // A Numeric text that does not parse.
  let db4 = @moondb.MockDriver::new()
  db4.execute("insert", [@moondb.Value::Numeric("not-a-number")]) |> ignore
  let bad_numeric = Ok(ignore(@io.read_sql(db4, "select"))) catch {
    e => Err(e)
  }
  assert_true(
    bad_numeric
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(n))) &&
    n.contains("does not parse as a decimal"),
  )
}

///|
test "read_sql answers the empty and all-null shapes" {
  // A driver whose query answered nothing names nothing: the 0×0 frame.
  let empty = @io.read_sql(@moondb.MockDriver::new(), "select")
  assert_eq(empty.shape(), (0, 0))
  // An all-null column answers String.
  let db2 = @moondb.MockDriver::new()
  db2.execute("insert", [@moondb.Value::Null]) |> ignore
  let all_null = @io.read_sql(db2, "select")
  assert_eq(all_null.nrows(), 1)
  assert_eq(all_null.get_column("c0").dtype(), @types.DataType::String)
  assert_eq(all_null.get_column("c0").to_scalars(), [@types.Scalar::Null])
}

///|
/// A driver answering what the contract allows but MockDriver will not:
/// a failing query, and a row whose width disagrees with the first's.
struct RogueDriver {
  fail : Bool
}

///|
fn rogue_rows() -> Array[@moondb.Row] {
  [
    {
      columns: ["a", "b"],
      values: [@moondb.Value::Int(1), @moondb.Value::Text("x")],
    },
    // The second row's width disagrees with the first's.
    { columns: ["a"], values: [@moondb.Value::Int(2)], },
  ]
}

///|
impl @moondb.Driver for RogueDriver with fn execute(
  self : RogueDriver,
  _sql : String,
  _params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  ignore(self)
  { rows_affected: 0, last_insert_id: 0, }
}

///|
impl @moondb.Driver for RogueDriver with fn query(
  self : RogueDriver,
  _sql : String,
  _params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  if self.fail {
    raise @moondb.DbError::QueryError("rogue driver refuses")
  }
  rogue_rows()
}

///|
impl @moondb.Driver for RogueDriver with fn begin(self : RogueDriver) -> Unit raise @moondb.DbError {
  ignore(self)
}

///|
impl @moondb.Driver for RogueDriver with fn commit(self : RogueDriver) -> Unit raise @moondb.DbError {
  ignore(self)
}

///|
impl @moondb.Driver for RogueDriver with fn rollback(self : RogueDriver) -> Unit raise @moondb.DbError {
  ignore(self)
}

///|
impl @moondb.Driver for RogueDriver with fn close(self : RogueDriver) -> Unit {
  ignore(self)
}

///|
extend RogueDriver with @moondb.Driver::{
  execute,
  query,
  begin,
  commit,
  rollback,
  close,
  ping,
}

///|
test "read_sql carries the driver's failure and width refusal" {
  let failing : RogueDriver = RogueDriver::{ fail: true, }
  let err = Ok(ignore(@io.read_sql(failing, "select"))) catch { e => Err(e) }
  assert_true(
    err is Err(@types.DataError::IoError(m)) &&
    m.contains("rogue driver refuses"),
  )
  let ragged : RogueDriver = RogueDriver::{ fail: false, }
  let width = Ok(ignore(@io.read_sql(ragged, "select"))) catch { e => Err(e) }
  assert_true(
    width
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(w))) &&
    w.contains("1 columns but the first carried 2"),
  )
}

///|
test "the rogue driver satisfies the whole contract" {
  // Every trait arm the read itself never reaches, touched so the
  // implementation is exercised rather than merely linked.
  let rogue : RogueDriver = RogueDriver::{ fail: false, }
  rogue.execute("x", []) |> ignore
  rogue.query("x", []) |> ignore
  rogue.begin()
  rogue.commit()
  rogue.begin()
  rogue.rollback()
  rogue.close()
  rogue.ping() |> ignore
}

///|
test "read_sql names every container shape in its refusal" {
  // The refusal message names the shape it refused — one case per
  // shape, so each spelling is pinned.
  let shapes : Array[@moondb.Value] = [
    @moondb.Value::Uuid(b"\x01\x02"),
    @moondb.Value::Json("{}"),
    @moondb.Value::Array([@moondb.Value::Int(1)]),
  ]
  let names : Array[String] = ["Uuid", "Json", "Array"]
  for i in 0..<shapes.length() {
    let db = @moondb.MockDriver::new()
    db.execute("insert", [shapes[i]]) |> ignore
    let refused = Ok(ignore(@io.read_sql(db, "select"))) catch { e => Err(e) }
    assert_true(
      refused is Err(@types.DataError::Unsupported(m)) &&
      m.contains("\{names[i]} cell MoonFrame does not read"),
    )
  }
}
