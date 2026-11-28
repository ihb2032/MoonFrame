// The workbook globals: the records between the stream's BOF and its EOF
// that name the sheets, hold the shared strings, and bind each style to
// its number format. Everything a sheet's cells need is read here once,
// and the other records of the globals — fonts, window and calculation
// settings, protection, names — are stepped over unread.

///|
/// One sheet as the workbook globals name it: where its substream begins
/// in the workbook stream, and its name.
priv struct SheetInfo {
  position : Int32
  name : String
}

///|
/// What reading a sheet's cells needs from the workbook globals.
priv struct Globals {
  /// The sheets in workbook order: the worksheets alone, a chart's, a
  /// macro sheet's or a module's substream holding no cells.
  sheets : Array[SheetInfo]
  /// The shared string table.
  strings : Array[String]
  /// Each XF record's number format index.
  formats : Array[Int32]
  /// The code of each FORMAT record, by its index.
  codes : Map[Int32, String]
  /// Whether the workbook counts dates from 1904-01-01 rather than from
  /// 1899-12-30.
  date_1904 : Bool
}

///|
/// The workbook globals of the workbook stream: from its BOF record to the
/// EOF record that ends them. Raises `Unsupported` for a BOF record of
/// another BIFF version, and for a FILEPASS record — the workbook is
/// encrypted; raises `ParseError`, naming the byte, for a stream that
/// does not open with a BOF record of the workbook globals, for a
/// record cut short, for a sheet placed outside the stream, for a shared
/// string table whose count its strings contradict, for a string the
/// records do not hold, for a DATEMODE record outside 0 and 1, for a BOF
/// record standing where the globals' EOF record should, and for globals
/// that end before their EOF record.
fn parse_globals(stream : Bytes) -> Globals raise @types.DataError {
  let bof = record_at(stream, 0)
  // 0x0005: the workbook globals substream.
  check_bof(stream, bof, "the workbook globals' 0x0005", 0x0005)
  let sheets : Array[SheetInfo] = []
  let strings : Array[String] = []
  let formats : Array[Int32] = []
  let codes : Map[Int32, String] = Map([])
  let mut date_1904 = false
  let mut at = bof.after()
  let mut ended = false
  while !ended {
    if at >= stream.length() {
      raise bad(
        "byte \{at} of the workbook stream: the workbook globals end before their EOF record",
      )
    }
    let rec = record_at(stream, at)
    at = rec.after()
    match rec.id {
      // EOF.
      0x000A => ended = true
      // FILEPASS.
      0x002F =>
        raise nope(
          "byte \{rec.at} of the workbook stream: the workbook is encrypted (a FILEPASS record), and this reader decrypts nothing",
        )
      // DATEMODE.
      0x0022 => {
        rec.need(2)
        let mode = rec.u16(stream, 0)
        if mode > 1 {
          raise bad(
            "byte \{rec.body()} of the workbook stream: the DATEMODE record at byte \{rec.at} holds \{mode}, neither 0 nor 1",
          )
        }
        date_1904 = mode == 1
      }
      // XF.
      0x00E0 => {
        rec.need(20)
        formats.push(rec.u16(stream, 2))
      }
      // BOUNDSHEET.
      0x0085 => read_boundsheet(stream, rec, sheets)
      // SST.
      0x00FC => read_sst(stream, rec, strings)
      // FORMAT.
      0x041E => read_format(stream, rec, codes)
      _ =>
        if is_bof(rec.id) {
          raise bad(
            "byte \{rec.at} of the workbook stream: a BOF record stands where the workbook globals' EOF record should end them",
          )
        }
    }
  }
  Globals::{ sheets, strings, formats, codes, date_1904, }
}

///|
/// The BIFF version whose BOF record carries the id `id`: BIFF4, 3 and 2
/// spell one each; BIFF5 to BIFF8 share 0x0809 and tell themselves apart
/// by the version field.
fn biff_of(id : Int32) -> String {
  match id {
    0x0409 => "BIFF4"
    0x0209 => "BIFF3"
    _ => "BIFF2"
  }
}

///|
/// Check that `rec` is a BOF record of BIFF8, and that it opens a
/// substream of type `kind`, which `expected` names, when `expected` is
/// not empty. Raises `Unsupported` for a BOF record of another BIFF
/// version — the id of BIFF2, 3 and 4, or a version field other than
/// BIFF8's; raises `ParseError`, naming the byte, for a record that is
/// no BOF, for a BOF too short to say, and for a substream of another
/// type.
fn check_bof(
  stream : Bytes,
  rec : Record,
  expected : String,
  kind : Int32,
) -> Unit raise @types.DataError {
  // 0x0809: the BOF record of BIFF5 to BIFF8; BIFF4, 3 and 2 spell
  // 0x0409, 0x0209 and 0x0009.
  if rec.id != 0x0809 {
    if is_bof(rec.id) {
      raise nope(
        "byte \{rec.at} of the workbook stream: the BOF record's id 0x\{hex4(rec.id)} is \{biff_of(rec.id)}'s, and this reader reads BIFF8's 0x0809",
      )
    }
    raise bad(
      "byte \{rec.at} of the workbook stream: record \{record_name(rec.id)} stands where a BOF record should",
    )
  }
  rec.need(4)
  let version = rec.u16(stream, 0)
  if version != 0x0600 {
    raise nope(
      "byte \{rec.body()} of the workbook stream: the BOF record at byte \{rec.at} declares BIFF version 0x\{hex4(version)}, and this reader reads BIFF8's 0x0600",
    )
  }
  let dt = rec.u16(stream, 2)
  if expected != "" && dt != kind {
    raise bad(
      "byte \{rec.body() + 2} of the workbook stream: the BOF record at byte \{rec.at} declares substream type 0x\{hex4(dt)}, not \{expected}",
    )
  }
}

///|
/// Read one BOUNDSHEET record into `sheets`: a worksheet's place and
/// name. The other kinds the record names — a macro sheet, a chart, a
/// module — hold no cells and are passed over. Raises `ParseError`,
/// naming the byte, for a record too short, for a name the record does
/// not hold, and for a sheet placed outside the workbook stream.
fn read_boundsheet(
  stream : Bytes,
  rec : Record,
  sheets : Array[SheetInfo],
) -> Unit raise @types.DataError {
  rec.need(8)
  let position = u32_at(stream, rec.body())
  // The sheet's kind: 0 a worksheet, 1 a macro sheet, 2 a chart, 6 a
  // module.
  if rec.byte(stream, 5) != 0 {
    return
  }
  let (parts, _) = segments(stream, rec)
  // Past the position, the kind and the visibility.
  parts.pos = 6
  let name = read_string(parts, 1, -1, "BOUNDSHEET record at byte \{rec.at}")
  if position + 4 > stream.length().to_int64() {
    raise bad(
      "byte \{rec.body()} of the workbook stream: the BOUNDSHEET record at byte \{rec.at} places the sheet \"\{name}\" at byte \{position}, and the stream holds \{stream.length()} bytes",
    )
  }
  sheets.push(SheetInfo::{ position: position.to_int(), name, })
}

///|
/// Read the shared string table into `strings`: the record's two counts,
/// then as many strings as the second names. The first count, of every
/// reference to the table, is the writer's own bookkeeping and is not
/// read. Raises `ParseError`, naming the byte, for a record too short,
/// for a negative count, for a string the records do not hold, and for a
/// table whose records hold other bytes than its strings.
fn read_sst(
  stream : Bytes,
  rec : Record,
  strings : Array[String],
) -> Unit raise @types.DataError {
  let (parts, _) = segments(stream, rec)
  let what = "shared string table"
  parts.need(8, what, "counts")
  ignore(parts.take(4))
  let unique_at = parts.take(4)
  let unique = i32_at(parts.stream, unique_at)
  if unique < 0 {
    raise bad(
      "byte \{unique_at} of the workbook stream: the shared string table declares a string count of \{unique}",
    )
  }
  strings.clear()
  for k in 0..<unique {
    strings.push(
      read_string(
        parts,
        2,
        -1,
        "\{ordinal(k + 1)} string of the shared string table",
      ),
    )
  }
  parts.settle()
  if !parts.exhausted() {
    raise bad(
      "byte \{parts.here()} of the workbook stream: the shared string table declares a string count of \{unique} and holds more",
    )
  }
}

///|
/// Read one FORMAT record into `codes`: the index of the number format it
/// defines, and its code — a whole string, with its own character count.
/// A later record with the same index replaces an earlier one. Raises
/// `ParseError`, naming the byte, for a record too short and for a code
/// the record does not hold.
fn read_format(
  stream : Bytes,
  rec : Record,
  codes : Map[Int32, String],
) -> Unit raise @types.DataError {
  let (parts, _) = segments(stream, rec)
  let what = "FORMAT record at byte \{rec.at}"
  parts.need(2, what, "index")
  let index = u16_at(parts.stream, parts.take(2))
  codes[index] = read_string(parts, 2, -1, what)
}
