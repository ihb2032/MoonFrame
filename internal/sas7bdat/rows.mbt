// The rows: each run's rows in order, up to the count the file declares,
// and each row's cells by column. A row stored plain is copied out of its
// page; one stored compressed is expanded first and must come out one row
// long.

///|
/// One column's cells as they are read: a number per row — a missing
/// value, whatever of the 28 spellings it takes, is `None` — or a text
/// per row, `None` for no row.
priv enum Cells {
  Numbers(Array[Double?])
  Texts(Array[String?])
}

///|
/// Read every cell of the rows the file declares. The rows come from the
/// runs in file order, and stop at the declared count; a run may hold
/// more rows than are taken from it. A numeric cell of fewer than eight
/// bytes holds the leading bytes of the number, most significant first,
/// and zero elsewhere.
///
/// Raises `ParseError` when a compressed row does not expand to exactly
/// one row, and when a text cell cannot be decoded as the header's
/// character set says: UTF-8 that is not well-formed, or a byte the code
/// page leaves undefined.
fn read_cells(
  bytes : Bytes,
  header : Header,
  plan : Plan,
) -> Array[Cells] raise @types.DataError {
  let row_length = plan.row_length
  let row : Array[Byte] = Array::make(row_length.to_int(), b'\x00')
  let stores : Array[Cells] = []
  let rows = plan.row_count.to_int()
  for column in plan.columns {
    if column.numeric {
      stores.push(Cells::Numbers(Array::make(rows, None)))
    } else {
      stores.push(Cells::Texts(Array::make(rows, Some(""))))
    }
  }
  let expand = plan.expand
  let mut taken = 0L
  let mut run_index = 0
  while run_index < plan.runs.length() && taken < plan.row_count {
    let run = plan.runs[run_index]
    run_index += 1
    for k in 0..<run.count.to_int() {
      if taken >= plan.row_count {
        break
      }
      let row_at = if run.compressed {
        run.at
      } else {
        run.at + k.to_int64() * row_length
      }
      if run.compressed {
        let expanded = expand(bytes, run.at, run.stored, row)
        if expanded != row_length {
          raise bad(
            run.at,
            "a compressed row expands to \{expanded} bytes, and rows are \{row_length} bytes",
          )
        }
      } else {
        need(bytes, row_at, row_length, "a row")
        let base = row_at.to_int()
        for j in 0..<row_length.to_int() {
          row[j] = bytes[base + j]
        }
      }
      let cell_row = taken.to_int()
      for i, column in plan.columns {
        let at = column.offset.to_int()
        let width = column.width.to_int()
        match stores[i] {
          Cells::Numbers(cells) => {
            let value = numeric_bits(row, at, width, header.little).reinterpret_as_double()
            cells[cell_row] = if value.is_nan() { None } else { Some(value) }
          }
          Cells::Texts(cells) =>
            cells[cell_row] = Some(
              cell_text(row, at, width, row_at + column.offset, header),
            )
        }
      }
      taken += 1
    }
  }
  stores
}

///|
/// The 64 bits of the number a numeric cell spells. A cell narrower than
/// eight bytes holds the number's leading bytes — the most significant
/// ones — and the bytes it lacks are zero. A big-endian file stores them
/// most significant first; a little-endian one stores them, like all its
/// numbers, least significant first. `at` and `width` lie inside `row`,
/// as the plan's column does.
fn numeric_bits(
  row : Array[Byte],
  at : Int32,
  width : Int32,
  little : Bool,
) -> UInt64 {
  let mut bits : UInt64 = 0UL
  if little {
    for j in 0..<width {
      bits = bits | (row[at + j].to_uint64() << (8 * (8 - width + j)))
    }
  } else {
    for j in 0..<width {
      bits = bits | (row[at + j].to_uint64() << (8 * (7 - j)))
    }
  }
  bits
}
