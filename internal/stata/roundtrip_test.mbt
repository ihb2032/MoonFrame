// Blackbox round trips in code: each table written by the codec and read
// back by it, cell for cell — every carried dtype, a non-ASCII string, a
// missing value, and the extreme values of each numeric type.

///|
test "every table round-trips through the codec, cell for cell" {
  let mut compared = 0
  for table in tables() {
    let bytes = write_table(table)
    let (back, height) = read_stata_frame(bytes)
    if height != table.height {
      fail("\{table.name}: \{height} rows came back, \{table.height} went in")
    }
    if back.length() != table.columns.length() {
      fail(
        "\{table.name}: \{back.length()} columns came back, \{table.columns.length()} went in",
      )
    }
    for i, (name, series) in back {
      let column = table.columns[i]
      if name != column.name() {
        fail(
          "\{table.name}: column \{i + 1} came back as \"\{name}\", not \"\{column.name()}\"",
        )
      }
      let dtype = dtype_as_read(column)
      if series.dtype() != dtype {
        fail(
          "\{table.name}, column \"\{name}\": came back \{series.dtype()}, not \{dtype}",
        )
      }
      let sent = column.to_scalars()
      let got = series.to_scalars()
      if sent.length() != got.length() {
        fail(
          "\{table.name}, column \"\{name}\": \{got.length()} cells came back, \{sent.length()} went in",
        )
      }
      for row in 0..<sent.length() {
        let want = as_read(column, sent[row])
        if !cell_equal(got[row], want) {
          fail(
            "\{table.name}, column \"\{name}\", row \{row + 1}: read back \{spelled(got[row])}, not \{spelled(want)}",
          )
        }
      }
      compared += sent.length()
    }
  }
  if compared < 100 {
    fail("only \{compared} cells round-tripped")
  }
  println("round trip in code: \{compared} cells")
}

///|
test "the same table writes the same bytes every time" {
  for table in tables() {
    let first = write_table(table)
    let again = write_table(table)
    if first != again {
      fail("\{table.name}: two writes of one table differ")
    }
  }
}

///|
test "a table written and read again keeps its shape at the edges" {
  // No column, a height: the count is the file's own.
  let (none, five) = read_stata_frame(write_stata_bytes([], height=5))
  assert_eq(none.length(), 0)
  assert_eq(five, 5)
  // No column, no height.
  let (none0, zero) = read_stata_frame(write_stata_bytes([]))
  assert_eq(none0.length(), 0)
  assert_eq(zero, 0)
  // Columns, no row: every column is there, empty, and of its dtype.
  let columns : Array[@series.Series] = [
    @series.Series::from_ints("num", []),
    @series.Series::from_strings("label", []),
  ]
  let (empty, rows) = read_stata_frame(write_stata_bytes(columns))
  assert_eq(rows, 0)
  assert_eq(empty.length(), 2)
  assert_eq(empty[0].0, "num")
  assert_eq(empty[1].0, "label")
  assert_eq(empty[0].1.dtype(), @types.DataType::Int)
  assert_eq(empty[1].1.dtype(), @types.DataType::String)
  assert_eq(empty[0].1.len(), 0)
  // A table of nothing but missing values.
  let missing : Array[@series.Series] = [
    @series.Series::from_scalars(
      "num",
      [@types.Scalar::Null, @types.Scalar::Null],
      dtype=@types.DataType::Int,
    ),
    @series.Series::from_scalars(
      "ratio",
      [@types.Scalar::Null, @types.Scalar::Null],
      dtype=@types.DataType::Float,
    ),
  ]
  let (back, _) = read_stata_frame(write_stata_bytes(missing))
  for i, (_, series) in back {
    assert_eq(series.dtype(), missing[i].dtype())
    assert_eq(series.to_scalars(), missing[i].to_scalars())
  }
}
