// One sheet's cells: the records of its substream, from its BOF record to
// its EOF record, each cell record read into its value — a text, a
// boolean, a number with its style's number format, an error, or a
// formula's cached value — and the blank cells, which hold a style and
// nothing else, read for their place alone. A cell written twice keeps
// its last record, and the cells answer in row-then-column order.

///|
/// The number an RK value spells. Its low two bits are flags: the second
/// says whether the other thirty bits are a signed integer or the high
/// bits of a double; the first, whether the number is divided by 100.
fn rk_number(rk : Int32) -> Double {
  let value = if (rk & 2) != 0 {
    (rk >> 2).to_double()
  } else {
    ((rk.reinterpret_as_uint().to_uint64() & 0xFFFFFFFCUL) << 32).reinterpret_as_double()
  }
  if (rk & 1) != 0 {
    value / 100.0
  } else {
    value
  }
}

///|
/// The text a sheet shows for the error code a cell carries: the eight the
/// format names, `#GETTING_DATA` among them. Raises `ParseError`, naming
/// the byte, for any other code; `what` names the record, for that
/// refusal.
fn error_text(
  code : Int32,
  at : Int32,
  what : String,
) -> String raise @types.DataError {
  match code {
    0x00 => "#NULL!"
    0x07 => "#DIV/0!"
    0x0F => "#VALUE!"
    0x17 => "#REF!"
    0x1D => "#NAME?"
    0x24 => "#NUM!"
    0x2A => "#N/A"
    0x2B => "#GETTING_DATA"
    _ =>
      raise bad(
        "byte \{at} of the workbook stream: the \{what} carries error code 0x\{hex4(code)}, which the format does not name",
      )
  }
}

///|
/// The key the cell at `row` and `col` is kept under, once its column is
/// shown to lie inside the sheet: row times 256 plus column. Raises
/// `ParseError`, naming the byte, for a column outside the 256 a sheet
/// holds.
fn cell_key(
  rec : Record,
  row : Int32,
  col : Int32,
) -> Int32 raise @types.DataError {
  if col > 255 {
    raise bad(
      "byte \{rec.body() + 2} of the workbook stream: the \{record_name(rec.id)} record at byte \{rec.at} places a cell in column \{col}, and a sheet holds 256",
    )
  }
  row * 256 + col
}

///|
/// Check that the style a cell record names is one of the workbook's XF
/// records; `xf_at` is the byte of the record's style field. Raises
/// `ParseError`, naming the byte, when it is not.
fn cell_style(
  globals : Globals,
  rec : Record,
  xf : Int32,
  xf_at : Int32,
) -> Unit raise @types.DataError {
  if xf >= globals.formats.length() {
    raise bad(
      "byte \{xf_at} of the workbook stream: the \{record_name(rec.id)} record at byte \{rec.at} names XF \{xf}, and the workbook holds \{globals.formats.length()}",
    )
  }
}

///|
/// The number format of the style `xf` — which `cell_style` has shown the
/// workbook holds — for a numeric cell. An index under 164 is a built-in
/// format, by its id; from 164 on it is the code of the FORMAT record
/// defining that index. Raises `ParseError`, naming the byte, for an
/// index no FORMAT record defines.
fn cell_format(
  globals : Globals,
  rec : Record,
  xf : Int32,
  xf_at : Int32,
) -> XlsFormat raise @types.DataError {
  let index = globals.formats[xf]
  if index < 164 {
    return Builtin(index)
  }
  match globals.codes.get(index) {
    Some(code) => Custom(code)
    None =>
      raise bad(
        "byte \{xf_at} of the workbook stream: the \{record_name(rec.id)} record at byte \{rec.at} names number format \{index}, which no FORMAT record defines",
      )
  }
}

///|
/// Keep a number cell: its place, its style and its style's number format
/// are each shown to hold before the cell is kept, replacing whatever the
/// same place held.
fn put_number(
  globals : Globals,
  cells : Map[Int32, XlsCell],
  rec : Record,
  row : Int32,
  col : Int32,
  xf : Int32,
  xf_at : Int32,
  value : Double,
) -> Unit raise @types.DataError {
  let key = cell_key(rec, row, col)
  cell_style(globals, rec, xf, xf_at)
  let format = cell_format(globals, rec, xf, xf_at)
  cells[key] = XlsCell::{ rowx: row, colx: col, held: Number(value, format), }
}

///|
/// Keep a cell of a value that needs no format — a text, a boolean or an
/// error — once its place and its style are shown to hold.
fn put_value(
  globals : Globals,
  stream : Bytes,
  cells : Map[Int32, XlsCell],
  rec : Record,
  row : Int32,
  col : Int32,
  held : XlsValue,
) -> Unit raise @types.DataError {
  let key = cell_key(rec, row, col)
  cell_style(globals, rec, rec.u16(stream, 4), rec.body() + 4)
  cells[key] = XlsCell::{ rowx: row, colx: col, held, }
}

///|
/// Read a MULRK record into `cells`: a run of number cells along one row,
/// each its style and its RK value, the run's last column spelled at the
/// record's end. Raises `ParseError`, naming the byte, for a record whose
/// length is not 6 bytes and 6 more for every cell, for a last column
/// that is not the one after the run's last cell, and for what any of its
/// cells refuses.
fn read_mulrk(
  globals : Globals,
  stream : Bytes,
  rec : Record,
  cells : Map[Int32, XlsCell],
) -> Unit raise @types.DataError {
  rec.need(12)
  let row = rec.u16(stream, 0)
  let first = rec.u16(stream, 2)
  let last = rec.u16(stream, rec.len - 2)
  if (rec.len - 6) % 6 != 0 {
    raise bad(
      "byte \{rec.at} of the workbook stream: the MULRK record is \{rec.len} bytes long, and its kind needs 6 bytes and 6 more for every cell",
    )
  }
  let count = (rec.len - 6) / 6
  if last != first + count - 1 {
    raise bad(
      "byte \{rec.body() + rec.len - 2} of the workbook stream: the MULRK record at byte \{rec.at} holds \{count} cells from column \{first}, and names column \{last} as its last",
    )
  }
  for k in 0..<count {
    put_number(
      globals,
      cells,
      rec,
      row,
      first + k,
      rec.u16(stream, 4 + 6 * k),
      rec.body() + 4 + 6 * k,
      rk_number(rec.i32(stream, 6 + 6 * k)),
    )
  }
}

///|
/// Read a MULBLANK record for its place alone: a run of styled empty
/// cells along one row, each its style, the run's last column spelled at
/// the record's end. The cells are empty and none is kept. Raises
/// `ParseError`, naming the byte, for a record whose length is not 6
/// bytes and 2 more for every cell, for a last column that is not the one
/// after the run's last cell, and for a column outside the sheet.
fn read_mulblank(stream : Bytes, rec : Record) -> Unit raise @types.DataError {
  rec.need(8)
  let row = rec.u16(stream, 0)
  let first = rec.u16(stream, 2)
  let last = rec.u16(stream, rec.len - 2)
  if (rec.len - 6) % 2 != 0 {
    raise bad(
      "byte \{rec.at} of the workbook stream: the MULBLANK record is \{rec.len} bytes long, and its kind needs 6 bytes and 2 more for every cell",
    )
  }
  let count = (rec.len - 6) / 2
  if last != first + count - 1 {
    raise bad(
      "byte \{rec.body() + rec.len - 2} of the workbook stream: the MULBLANK record at byte \{rec.at} holds \{count} cells from column \{first}, and names column \{last} as its last",
    )
  }
  ignore(cell_key(rec, row, first))
  ignore(cell_key(rec, row, last))
}

///|
/// Read a LABELSST record into `cells`: a cell holding one of the shared
/// strings. Raises `ParseError`, naming the byte, for a shared string the
/// table does not hold, and for what the cell's place and style refuse.
fn read_labelsst(
  globals : Globals,
  stream : Bytes,
  rec : Record,
  cells : Map[Int32, XlsCell],
) -> Unit raise @types.DataError {
  rec.need(10)
  let key = cell_key(rec, rec.u16(stream, 0), rec.u16(stream, 2))
  cell_style(globals, rec, rec.u16(stream, 4), rec.body() + 4)
  let index = rec.i32(stream, 6)
  if index < 0 || index >= globals.strings.length() {
    raise bad(
      "byte \{rec.body() + 6} of the workbook stream: the LABELSST record at byte \{rec.at} names shared string \{index}, and the table holds \{globals.strings.length()}",
    )
  }
  cells[key] = XlsCell::{
    rowx: rec.u16(stream, 0),
    colx: rec.u16(stream, 2),
    held: Text(globals.strings[index]),
  }
}

///|
/// Read a LABEL record into `cells`: a cell holding a string of its own,
/// its character count in the record and its characters in the record and
/// the CONTINUE records after it. Answers the byte of the stream past the
/// last of those records. Raises `ParseError`, naming the byte, for a
/// string the records do not hold and for what the cell's place and style
/// refuse.
fn read_label(
  globals : Globals,
  stream : Bytes,
  rec : Record,
  cells : Map[Int32, XlsCell],
) -> Int32 raise @types.DataError {
  rec.need(8)
  let key = cell_key(rec, rec.u16(stream, 0), rec.u16(stream, 2))
  cell_style(globals, rec, rec.u16(stream, 4), rec.body() + 4)
  let (parts, after) = segments(stream, rec)
  // Past the row, the column, the style and the character count.
  parts.pos = 8
  let text = read_string(
    parts,
    0,
    rec.u16(stream, 6),
    "LABEL record at byte \{rec.at}",
  )
  cells[key] = XlsCell::{
    rowx: rec.u16(stream, 0),
    colx: rec.u16(stream, 2),
    held: Text(text),
  }
  after
}

///|
/// Read a BOOLERR record into `cells`: a boolean cell or an error cell,
/// as the record's last byte says. Raises `ParseError`, naming the byte,
/// for a last byte that is neither a boolean's 0 nor an error's 1, for a
/// boolean that is neither 0 nor 1, for an error code the format does not
/// name, and for what the cell's place and style refuse.
fn read_boolerr(
  globals : Globals,
  stream : Bytes,
  rec : Record,
  cells : Map[Int32, XlsCell],
) -> Unit raise @types.DataError {
  rec.need(8)
  let what = "BOOLERR record at byte \{rec.at}"
  let value_at = rec.body() + 6
  let value = rec.byte(stream, 6)
  let held : XlsValue = match rec.byte(stream, 7) {
    0 =>
      if value == 0 {
        Boolean(false)
      } else if value == 1 {
        Boolean(true)
      } else {
        raise bad(
          "byte \{value_at} of the workbook stream: the \{what} holds \{value} as a boolean, neither 0 nor 1",
        )
      }
    1 => Error(error_text(value, value_at, what))
    other =>
      raise bad(
        "byte \{rec.body() + 7} of the workbook stream: the \{what} holds \{other}, neither a boolean's 0 nor an error's 1",
      )
  }
  put_value(
    globals,
    stream,
    cells,
    rec,
    rec.u16(stream, 0),
    rec.u16(stream, 2),
    held,
  )
}

///|
/// Read a FORMULA record into `cells`, by its cached value alone —
/// nothing is evaluated. A number is in the record; a boolean, an error
/// and a blank string are in its last two bytes' marker and a kind byte,
/// the blank string leaving nothing to keep; a string is in the STRING
/// record after it, past the records that belong to the formula — ARRAY,
/// SHRFMLA, TABLEOP and TABLEOP2 — should any stand between. Answers the
/// byte of the stream past the last
/// record read. Raises `ParseError`, naming the byte, for a cached value
/// of a kind the format does not name, for a boolean that is neither 0
/// nor 1, for an error code the format does not name, for another record
/// where the STRING record should be, for a string the records do not
/// hold, and for what the cell's place and style refuse.
fn read_formula(
  globals : Globals,
  stream : Bytes,
  rec : Record,
  at : Int32,
  cells : Map[Int32, XlsCell],
) -> Int32 raise @types.DataError {
  rec.need(14)
  let row = rec.u16(stream, 0)
  let col = rec.u16(stream, 2)
  let xf = rec.u16(stream, 4)
  let what = "FORMULA record at byte \{rec.at}"
  // The cached value's eight bytes: a number, unless their last two are
  // the marker FF FF, which leaves the kind to their first byte.
  let value_at = rec.body() + 6
  let marked = stream[value_at + 6].to_int() == 0xFF &&
    stream[value_at + 7].to_int() == 0xFF
  if !marked {
    put_number(
      globals,
      cells,
      rec,
      row,
      col,
      xf,
      rec.body() + 4,
      rec.f64(stream, 6),
    )
    return at
  }
  match stream[value_at].to_int() {
    0 => {
      let mut next = record_at(stream, at)
      let mut after = next.after()
      // The records that belong to a formula may stand between it and its
      // string: 0x0221 ARRAY, 0x04BC SHRFMLA, 0x0236 TABLEOP and 0x0037
      // TABLEOP2.
      while next.id == 0x0221 ||
            next.id == 0x04BC ||
            next.id == 0x0236 ||
            next.id == 0x0037 {
        next = record_at(stream, after)
        after = next.after()
      }
      // 0x0207: STRING.
      if next.id != 0x0207 {
        raise bad(
          "byte \{next.at} of the workbook stream: record \{record_name(next.id)} follows the \{what}, whose cached value is a string, where a STRING record should",
        )
      }
      let (parts, end) = segments(stream, next)
      let text = read_string(parts, 2, -1, "STRING record at byte \{next.at}")
      put_value(globals, stream, cells, rec, row, col, Text(text))
      end
    }
    1 =>
      if stream[value_at + 2].to_int() == 0 {
        put_value(globals, stream, cells, rec, row, col, Boolean(false))
        at
      } else if stream[value_at + 2].to_int() == 1 {
        put_value(globals, stream, cells, rec, row, col, Boolean(true))
        at
      } else {
        raise bad(
          "byte \{value_at + 2} of the workbook stream: the \{what} caches a boolean of \{stream[value_at + 2].to_int()}, neither 0 nor 1",
        )
      }
    2 => {
      let text = error_text(stream[value_at + 2].to_int(), value_at + 2, what)
      put_value(globals, stream, cells, rec, row, col, Error(text))
      at
    }
    // A blank string: nothing is kept, the cell is absent from the sheet.
    3 => at
    kind =>
      raise bad(
        "byte \{value_at} of the workbook stream: the \{what} caches a value of kind \{kind}, which the format does not name",
      )
  }
}

///|
/// Step over the substream embedded in a sheet at `rec`, a BOF record —
/// a chart's, typically — to the EOF record that ends it, answering the
/// byte of the stream past that record. Raises `Unsupported` for a BOF
/// record of another BIFF version; raises `ParseError`, naming the byte,
/// for an embedded substream that ends before its EOF record.
fn skip_embedded(
  stream : Bytes,
  rec : Record,
  at : Int32,
) -> Int32 raise @types.DataError {
  check_bof(stream, rec, "", 0)
  let mut pos = at
  let mut closed = false
  while !closed {
    if pos >= stream.length() {
      raise bad(
        "byte \{pos} of the workbook stream: the substream embedded at byte \{rec.at} ends before its EOF record",
      )
    }
    let inner = record_at(stream, pos)
    pos = inner.after()
    if inner.id == 0x000A {
      closed = true
    }
  }
  pos
}

///|
/// The cells of sheet number `index` of the workbook, in row-then-column
/// order. Raises `Unsupported` for a BOF record of another BIFF version,
/// the sheet's own or one embedded in it; raises `ParseError`, naming the
/// byte, for a sheet whose BOF record is not where the workbook globals
/// placed it or opens another kind of substream, for a record cut short
/// or shorter than its kind needs, for a cell outside the sheet, for a
/// style, a shared string or a number format the workbook does not hold,
/// for a string the records do not hold, for an error code or a cached
/// formula value the format does not name, for a formula's string not
/// followed by a STRING record, for a run of cells whose length
/// contradicts its last column, and for a sheet that ends before its EOF
/// record.
fn read_sheet(
  stream : Bytes,
  globals : Globals,
  index : Int32,
) -> Array[XlsCell] raise @types.DataError {
  let info = globals.sheets[index]
  let bof = record_at(stream, info.position)
  // 0x0010: a worksheet's substream.
  check_bof(stream, bof, "a worksheet's 0x0010", 0x0010)
  // The cells by their key: a cell written twice keeps its last record.
  let cells : Map[Int32, XlsCell] = Map([])
  let mut at = bof.after()
  let mut ended = false
  while !ended {
    if at >= stream.length() {
      raise bad(
        "byte \{at} of the workbook stream: sheet \{index} ends before its EOF record",
      )
    }
    let rec = record_at(stream, at)
    at = rec.after()
    match rec.id {
      // EOF.
      0x000A => ended = true
      // BLANK: a styled empty cell, kept for nothing.
      0x0201 => {
        rec.need(6)
        ignore(cell_key(rec, rec.u16(stream, 0), rec.u16(stream, 2)))
      }
      // MULBLANK.
      0x00BE => read_mulblank(stream, rec)
      // NUMBER.
      0x0203 => {
        rec.need(14)
        put_number(
          globals,
          cells,
          rec,
          rec.u16(stream, 0),
          rec.u16(stream, 2),
          rec.u16(stream, 4),
          rec.body() + 4,
          rec.f64(stream, 6),
        )
      }
      // RK.
      0x027E => {
        rec.need(10)
        put_number(
          globals,
          cells,
          rec,
          rec.u16(stream, 0),
          rec.u16(stream, 2),
          rec.u16(stream, 4),
          rec.body() + 4,
          rk_number(rec.i32(stream, 6)),
        )
      }
      // MULRK.
      0x00BD => read_mulrk(globals, stream, rec, cells)
      // LABELSST.
      0x00FD => read_labelsst(globals, stream, rec, cells)
      // LABEL.
      0x0204 => at = read_label(globals, stream, rec, cells)
      // BOOLERR.
      0x0205 => read_boolerr(globals, stream, rec, cells)
      // FORMULA.
      0x0006 => at = read_formula(globals, stream, rec, at, cells)
      _ => if is_bof(rec.id) { at = skip_embedded(stream, rec, at) }
    }
  }
  let held : Array[XlsCell] = []
  for _, cell in cells {
    held.push(cell)
  }
  held.sort_by((a, b) => {
    if a.rowx != b.rowx {
      a.rowx - b.rowx
    } else {
      a.colx - b.colx
    }
  })
  held
}
