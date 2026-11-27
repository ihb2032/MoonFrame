// Blackbox round trips in code: a table is written and read back, cell by
// cell. The table has every dtype the codec carries, a non-ASCII string, a
// missing cell of each kind, and the extreme values of each numeric type.

///|
/// The round-trip table: six observations of every dtype the codec
/// carries, with the extreme values of each.
fn roundtrip_columns() -> Array[@series.Series] raise @types.DataError {
  [
    @series.Series::from_scalars(
      "flag",
      [
        @types.Scalar::Bool(true),
        @types.Scalar::Bool(false),
        @types.Scalar::Null,
        @types.Scalar::Bool(true),
        @types.Scalar::Bool(false),
        @types.Scalar::Bool(true),
      ],
      dtype=@types.DataType::Bool,
    ),
    @series.Series::from_ints("num", [
      1L, -1L, 9007199254740992L, -9007199254740992L, 0L, 7L,
    ]),
    @series.Series::from_floats("ratio", [
      0.1, -0.25, 5.397605346934028e-79, -5.397605346934028e-79, 1.0e75, -1.0e75,
    ]),
    @series.Series::from_date_options("day", [
      Some(0L),
      Some(-3653L),
      Some(2932896L),
      Some(-719162L),
      None,
      Some(15625L),
    ]),
    @series.Series::from_timestamp_options("stamp", [
      Some(0L),
      Some(-315619200000000L),
      Some(1709201696781250L),
      Some(-62135596800000000L),
      Some(253370764800000000L),
      None,
    ]),
    @series.Series::from_string_options("label", [
      Some("a"),
      Some(""),
      Some("héllo wörld"),
      Some("日本語😀"),
      None,
      Some(repeated("z", 200)),
    ]),
  ]
}

///|
/// The cell a written cell comes back as: a `Bool` as 1.0 or 0.0, an
/// `Int` as its double, and every other cell as itself — except a
/// missing cell of a text column (`text`), which the file spells as
/// blanks and which read as the empty string.
fn as_read(written : @types.Scalar, text : Bool) -> @types.Scalar {
  if text && written is @types.Scalar::Null {
    @types.Scalar::String("")
  } else if written is @types.Scalar::Bool(b) {
    @types.Scalar::Float(if b { 1.0 } else { 0.0 })
  } else if written is @types.Scalar::Int(v) {
    @types.Scalar::Float(v.to_double())
  } else {
    written
  }
}

///|
/// The dtype a written column comes back as: `Bool` and `Int` columns
/// are numbers in the file, and read as `Float`.
fn dtype_as_read(column : @series.Series) -> @types.DataType {
  let dtype = column.dtype()
  if dtype is @types.DataType::Bool || dtype is @types.DataType::Int {
    @types.DataType::Float
  } else {
    dtype
  }
}

///|
test "a table of every carried dtype reads back as it was written, cell by cell" {
  let columns = roundtrip_columns()
  let bytes = write_xport_bytes(columns)
  let (read, height) = read_xport_frame(bytes)
  assert_eq(height, 6)
  assert_eq(read.length(), columns.length())
  let mut compared = 0
  for i, column in columns {
    let (name, series) = read[i]
    assert_eq(name, column.name())
    assert_eq(series.dtype(), dtype_as_read(column))
    assert_eq(series.len(), column.len())
    let written = column.to_scalars()
    let back = series.to_scalars()
    let text = column.dtype() is @types.DataType::String
    for row in 0..<written.length() {
      let want = as_read(written[row], text)
      if !cell_equal(back[row], want) {
        fail(
          "\{name}, row \{row + 1}: wrote \{spelled(written[row])}, read back \{spelled(back[row])}",
        )
      }
    }
    compared += written.length()
  }
  assert_eq(compared, 36)
  println(
    "round trip: \{columns.length()} columns, \{compared} cells, all equal; DONE",
  )
}

///|
test "the same columns write the same bytes, whatever the height argument" {
  let columns = roundtrip_columns()
  let first = write_xport_bytes(columns)
  let again = write_xport_bytes(columns)
  let pinned = write_xport_bytes(columns, height=6)
  assert_eq(first.length(), again.length())
  assert_eq(first.length(), pinned.length())
  for i in 0..<first.length() {
    if first[i] != again[i] || first[i] != pinned[i] {
      fail("byte \{i} differs between two writes of the same columns")
    }
  }
  // A file is whole 80-byte records, and the NAMESTRs and the observation
  // header record end where the layout puts them.
  assert_eq(first.length() % 80, 0)
}

///|
test "a NaN and a negative zero write missing and plain zero" {
  let columns = [
    @series.Series::from_floats("ratio", [@double.not_a_number, -0.0, 0.0, 1.5]),
  ]
  let bytes = write_xport_bytes(columns)
  let (read, _) = read_xport_frame(bytes)
  let back = read[0].1.to_scalars()
  assert_eq(back[0], @types.Scalar::Null)
  assert_eq(spelled(back[1]), "Float 0000000000000000")
  assert_eq(spelled(back[2]), "Float 0000000000000000")
  assert_eq(spelled(back[3]), "Float 3ff8000000000000")
}
