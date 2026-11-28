// Blackbox tests of the projection: which columns a projection keeps,
// in what order, and what it answers for a file it names nothing of.

///|
test "a projection naming a subset gives exactly those columns, in file order, and the file's row count" {
  let bytes = fixture(".github/fixtures/orc/reference/pyorc_scalars.orc")
  let (columns, rows) = read_orc_frame(bytes, projection=["str", "tiny", "b"])
  assert_eq(rows, 12)
  assert_eq(columns.length(), 3)
  let names = columns.map(pair => pair.0)
  assert_eq(names, ["b", "tiny", "str"])
  assert_eq(columns[0].1.dtype(), @types.DataType::Bool)
  assert_eq(columns[1].1.dtype(), @types.DataType::Int)
  assert_eq(columns[2].1.dtype(), @types.DataType::String)
  assert_eq(columns[0].1.get(0), @types.Scalar::Bool(true))
  assert_eq(columns[1].1.get(9), @types.Scalar::Int(100))
  assert_eq(columns[2].1.get(2), @types.Scalar::String(""))
}

///|
test "a projection naming nothing the file carries gives no column and the file's row count" {
  let bytes = fixture(".github/fixtures/orc/reference/pyorc_scalars.orc")
  let (columns, rows) = read_orc_frame(bytes, projection=["nope", "nada"])
  assert_eq(columns.length(), 0)
  assert_eq(rows, 12)
}

///|
test "an empty projection gives no column and the file's row count" {
  let bytes = fixture(".github/fixtures/orc/reference/pyorc_scalars.orc")
  let (columns, rows) = read_orc_frame(bytes, projection=[])
  assert_eq(columns.length(), 0)
  assert_eq(rows, 12)
}

///|
test "two fields of one name: a projection naming it keeps both, as the file spells them" {
  let bytes = fixture(".github/fixtures/orc/reference/pyorc_dupnames.orc")
  let (columns, rows) = read_orc_frame(bytes, projection=["a"])
  assert_eq(rows, 2)
  assert_eq(columns.length(), 2)
  assert_eq(columns[0].1.get(0), @types.Scalar::Int(1))
  assert_eq(columns[1].1.get(0), @types.Scalar::Int(3))
}

///|
test "a projection names top-level fields: a nested field's name builds no column" {
  let bytes = fixture(".github/fixtures/orc/reference/pyorc_nested.orc")
  let (columns, rows) = read_orc_frame(bytes, projection=["a", "x", "l"])
  assert_eq(columns.length(), 0)
  assert_eq(rows, 8)
  let (structs, _) = read_orc_frame(bytes, projection=["st"])
  assert_eq(structs.length(), 1)
  assert_eq(
    structs[0].1.dtype().to_string(),
    "Struct(a: Int, b: String, c: Struct(d: Float, e: Bool))",
  )
}

///|
test "a projection may name a field twice: the column comes back once" {
  let bytes = fixture(
    ".github/fixtures/orc/reference/pyorc_small_uncompressed.orc",
  )
  let (columns, rows) = read_orc_frame(bytes, projection=["a", "a", "s"])
  assert_eq(rows, 5)
  assert_eq(columns.map(pair => pair.0), ["a", "s"])
}

///|
test "a projection leaves a field out entirely: a column the reader cannot carry is not refused when it is not named" {
  // The file carries a BINARY column; named, it is refused; left out,
  // the int column beside it reads.
  let bytes = fixture(".github/fixtures/orc/reference/pyorc_binary.orc")
  let (columns, rows) = read_orc_frame(bytes, projection=["n"])
  assert_eq(rows, 3)
  assert_eq(columns.length(), 1)
  assert_eq(columns[0].1.get(1), @types.Scalar::Null)
}
