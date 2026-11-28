// The Stata dataset writer: release 118, little-endian — the first
// release whose text is UTF-8 — laid out as its tagged header, the map
// that places its sections, and the sections themselves.

///|
/// The days between the format's epoch, 1960-01-01, and the library's,
/// 1970-01-01.
const EPOCH_DAYS : Int64 = 3653L

///|
/// The milliseconds between the two epochs.
const EPOCH_MILLIS : Int64 = 315_619_200_000L

///|
/// The smallest value a `long` cell holds. The 27 missing codes occupy
/// what lies above the largest, and the minimum of the machine type lies
/// below the smallest.
const LONG_LEAST : Int64 = -2147483647L

///|
/// The largest value a `long` cell holds.
const LONG_MOST : Int64 = 2147483620L

///|
/// The `long` storage's code for `.`.
const LONG_MISSING : Int64 = 2147483621L

///|
/// The `byte` storage's code for `.`.
const BYTE_MISSING : Int64 = 101L

///|
/// The width in bytes of a variable's name slot.
const NAME_SLOT : Int32 = 129

///|
/// The width in bytes of a display format's slot.
const FORMAT_SLOT : Int32 = 57

///|
/// The words the Stata language reserves, none of which a variable name
/// may spell.
let reserved_words : ReadOnlyArray[String] = [
  "aggregate", "array", "boolean", "break", "byte", "case", "catch", "class", "colvector",
  "complex", "const", "continue", "default", "delegate", "delete", "do", "double",
  "else", "eltypedef", "end", "enum", "explicit", "export", "external", "float",
  "for", "friend", "function", "global", "goto", "if", "inline", "int", "local",
  "long", "NULL", "pragma", "protected", "quad", "rowvector", "short", "typedef",
  "typename", "virtual", "_all", "_N", "_skip", "_b", "_pi", "str#", "in", "_pred",
  "strL", "_coef", "_rc", "using", "_cons", "_se", "with", "_n",
]

///|
/// One column's cells, encoded as the bytes the data block spells them
/// in: `Integers` a `byte` or `long` cell's value, missing code included;
/// `Doubles` a `double` cell's value, a missing one already the code for
/// `.`; `Texts` a fixed-width string's UTF-8 bytes; `Keys` a long
/// string's table key per cell, with the records the keys name.
priv enum Cells {
  Integers(Array[Int64])
  Doubles(Array[Double])
  Texts(Array[Bytes])
  Keys(Array[UInt64], Bytes)
}

///|
/// How one column is written: the type code its descriptor carries, the
/// width of one of its cells, the display format written beside its
/// name, and its encoded cells.
priv struct ColumnPlan {
  code : Int32
  width : Int32
  format : String
  cells : Cells
}

///|
/// The `double` storage's code for `.`: 2^1023, the first value past the
/// storage's valid range, and no NaN — the 27 codes count up from it in
/// steps of 2^40.
fn double_missing() -> Double {
  0x7FE0000000000000UL.reinterpret_as_double()
}

///|
/// Whether the format's `double` storage holds `value` exactly — every
/// integer of at most 53 significant bits, which is every one whose
/// magnitude loses nothing when its factors of two are divided out below
/// 2^53. The division runs at most ten times: halving stops at an odd
/// magnitude, and no 64-bit magnitude needs more than ten to reach 2^53.
/// The magnitude is taken in the unsigned domain, where the minimum's
/// own fits.
fn double_holds(value : Int64) -> Bool {
  let bits = value.reinterpret_as_uint64()
  let mut magnitude = if value < 0L { 0UL - bits } else { bits }
  while magnitude >= 9007199254740992UL && magnitude % 2UL == 0UL {
    magnitude = magnitude / 2UL
  }
  magnitude < 9007199254740992UL
}

///|
/// Append `text`'s bytes.
fn push_bytes(out : Array[Byte], text : Bytes) -> Unit {
  for b in text {
    out.push(b)
  }
}

///|
/// Append a string's UTF-8 bytes.
fn push_text(out : Array[Byte], text : String) -> Unit {
  push_bytes(out, @utf8.encode(text))
}

///|
/// Append the `width` low bytes of an integer, least significant first.
fn push_le(out : Array[Byte], value : UInt64, width : Int32) -> Unit {
  let mut rest = value
  for _ in 0..<width {
    out.push((rest & 0xFFUL).to_byte())
    rest = rest >> 8
  }
}

///|
/// Append `count` zero bytes.
fn push_zeros(out : Array[Byte], count : Int32) -> Unit {
  for _ in 0..<count {
    out.push((0).to_byte())
  }
}

///|
/// Write a little-endian eight-byte integer into bytes already appended
/// — a map entry, once the position it names is known.
fn patch_le64(out : Array[Byte], at : Int32, value : Int32) -> Unit {
  let mut rest = value.to_uint64()
  for i in 0..<8 {
    out[at + i] = (rest & 0xFFUL).to_byte()
    rest = rest >> 8
  }
}

///|
/// The UTF-8 bytes of one string cell. A cell holding an unpaired UTF-16
/// surrogate refuses, naming the column and row: the encoder aborts
/// on one, and it has no UTF-8 spelling to round-trip.
fn encode_cell(
  name : String,
  row : Int32,
  text : String,
) -> Bytes raise @types.DataError {
  match @text.find_unpaired_surrogate(text) {
    None => @utf8.encode(text)
    Some(_) =>
      raise @types.DataError::InvalidOperation(
        "cannot write column \"\{name}\": the String cell at row \{row + 1} holds an unpaired UTF-16 surrogate, which has no UTF-8 spelling",
      )
  }
}

///|
/// `code` as the four hexadecimal digits the `U+` spelling of a code
/// unit uses.
fn hex4(code : Int32) -> String {
  let mut digits = code.reinterpret_as_uint().to_string(radix=16).to_upper()
  while digits.length() < 4 {
    digits = "0" + digits
  }
  digits
}

///|
/// Check one column name against the format's rules — one to 32 of the
/// ASCII letters, the digits and the underscore; not opening with a
/// digit; not a word the language reserves; not an earlier column's name
/// — and refuse with `InvalidOperation` on the first it breaks, naming
/// the column. The name is read as code units, so a name holding an
/// unpaired surrogate is refused as any other character outside the
/// alphabet, and nothing decodes it.
fn check_name(
  name : String,
  index : Int32,
  earlier : Map[String, Int32],
) -> Unit raise @types.DataError {
  let units = name.code_units()
  let length = units.length()
  if length == 0 {
    raise @types.DataError::InvalidOperation(
      "the column name \"\" is empty; a Stata variable name has one to 32 characters",
    )
  }
  let mut i = 0
  while i < length {
    let cu = units[i].to_int()
    let allowed = (cu >= 65 && cu <= 90) ||
      (cu >= 97 && cu <= 122) ||
      (cu >= 48 && cu <= 57) ||
      cu == 95
    if !allowed {
      raise @types.DataError::InvalidOperation(
        "the column name \"\{name}\" holds U+\{hex4(cu)}, outside the letters, digits and underscore a Stata variable name allows",
      )
    }
    i += 1
  }
  if length > 32 {
    raise @types.DataError::InvalidOperation(
      "the column name \"\{name}\" is \{length} characters long; a Stata variable name has at most 32",
    )
  }
  let first = units[0].to_int()
  if first >= 48 && first <= 57 {
    raise @types.DataError::InvalidOperation(
      "the column name \"\{name}\" opens with the digit \{first - 48}; a Stata variable name opens with a letter or the underscore",
    )
  }
  if reserved_words.contains(name) {
    raise @types.DataError::InvalidOperation(
      "the column name \"\{name}\" is a word the Stata language reserves, which no variable name spells",
    )
  }
  match earlier.get(name) {
    None => ()
    Some(at) =>
      raise @types.DataError::InvalidOperation(
        "the column name \"\{name}\" is already column \{at + 1}'s; a dataset's variable names are distinct",
      )
  }
  earlier[name] = index
}

///|
/// The plan for a `Bool` column: a `byte` holding 1, 0 or the code for
/// `.`.
fn plan_flag(column : @series.Series) -> ColumnPlan raise @types.DataError {
  let values : Array[Int64] = []
  for cell in column.to_scalars() {
    if cell is @types.Scalar::Null {
      values.push(BYTE_MISSING)
    } else {
      values.push(if cell.as_bool() { 1L } else { 0L })
    }
  }
  ColumnPlan::{
    code: 65530,
    width: 1,
    format: "%8.0g",
    cells: Cells::Integers(values),
  }
}

///|
/// The plan for an `Int` column: a `long` while every cell lies inside
/// that storage's valid range, and a `double` otherwise — in which a
/// cell the double cannot hold exactly refuses, naming the column and
/// the row.
fn plan_int(
  name : String,
  column : @series.Series,
) -> ColumnPlan raise @types.DataError {
  let cells = column.to_scalars()
  let mut narrow = true
  for cell in cells {
    if cell is @types.Scalar::Int(v) {
      if v < LONG_LEAST || v > LONG_MOST {
        narrow = false
      }
    }
  }
  if narrow {
    let values = cells.map(cell => {
      if cell is @types.Scalar::Null {
        LONG_MISSING
      } else {
        cell.as_int()
      }
    })
    return ColumnPlan::{
      code: 65528,
      width: 4,
      format: "%12.0g",
      cells: Cells::Integers(values),
    }
  }
  let values : Array[Double] = []
  for row, cell in cells {
    if cell is @types.Scalar::Null {
      values.push(double_missing())
      continue
    }
    let v = cell.as_int()
    if !double_holds(v) {
      raise @types.DataError::InvalidOperation(
        "cannot write column \"\{name}\": the Int cell at row \{row + 1} (\{v}) is too large for the format's double storage to hold exactly",
      )
    }
    values.push(v.to_double())
  }
  ColumnPlan::{
    code: 65526,
    width: 8,
    format: "%10.0g",
    cells: Cells::Doubles(values),
  }
}

///|
/// The plan for a `Float` column: a `double`. A NaN writes the code for
/// `.`. An infinite cell refuses — the format has no infinity — and so
/// does a finite one outside the storage's valid range, whose top the
/// missing codes occupy; each names the column and the row.
fn plan_float(
  name : String,
  column : @series.Series,
) -> ColumnPlan raise @types.DataError {
  let values : Array[Double] = []
  for row, cell in column.to_scalars() {
    if cell is @types.Scalar::Null {
      values.push(double_missing())
      continue
    }
    let v = cell.as_float()
    if v.is_nan() {
      values.push(double_missing())
    } else if v.is_inf() {
      raise @types.DataError::InvalidOperation(
        "cannot write column \"\{name}\": the Float cell at row \{row + 1} is infinite, and the format has no infinity",
      )
    } else if (v.reinterpret_as_uint64() & 0x7FFFFFFFFFFFFFFFUL) >=
      0x7FE0000000000000UL {
      raise @types.DataError::InvalidOperation(
        "cannot write column \"\{name}\": the Float cell at row \{row + 1} lies past the double storage's valid range, whose top the missing codes occupy",
      )
    } else {
      values.push(v)
    }
  }
  ColumnPlan::{
    code: 65526,
    width: 8,
    format: "%10.0g",
    cells: Cells::Doubles(values),
  }
}

///|
/// The plan for a `Date` column: a `long` holding the days since
/// 1960-01-01, under the `%td` format. A date whose count leaves the
/// storage's valid range refuses, naming the column and the row.
fn plan_date(
  name : String,
  column : @series.Series,
) -> ColumnPlan raise @types.DataError {
  let values : Array[Int64] = []
  for row, cell in column.to_scalars() {
    let mut stored = LONG_MISSING
    if cell is @types.Scalar::Date(days) {
      // The bounds are spelled before the shift, so no sum overflows.
      if days < LONG_LEAST - EPOCH_DAYS || days > LONG_MOST - EPOCH_DAYS {
        raise @types.DataError::InvalidOperation(
          "cannot write column \"\{name}\": the Date cell at row \{row + 1} (day \{days} since 1970-01-01) leaves the long storage's valid range",
        )
      }
      stored = days + EPOCH_DAYS
    }
    values.push(stored)
  }
  ColumnPlan::{
    code: 65528,
    width: 4,
    format: "%td",
    cells: Cells::Integers(values),
  }
}

///|
/// The plan for a `Timestamp` column: a `double` holding the
/// milliseconds since 1960-01-01, under the `%tc` format. An instant
/// that is not a whole number of milliseconds refuses — the format
/// holds nothing finer — and so does one too far from the epoch for the
/// double to hold its count exactly; each names the column and the row.
fn plan_timestamp(
  name : String,
  column : @series.Series,
) -> ColumnPlan raise @types.DataError {
  let values : Array[Double] = []
  for row, cell in column.to_scalars() {
    let mut stored = double_missing()
    if cell is @types.Scalar::Timestamp(micros) {
      if micros % 1000L != 0L {
        raise @types.DataError::InvalidOperation(
          "cannot write column \"\{name}\": the Timestamp cell at row \{row + 1} (\{micros} microseconds since 1970-01-01) is not a whole number of milliseconds",
        )
      }
      // A microsecond count is at most 2^63, so its milliseconds, and
      // their shift, both fit.
      let shifted = micros / 1000L + EPOCH_MILLIS
      if shifted.to_double().to_int64() != shifted {
        raise @types.DataError::InvalidOperation(
          "cannot write column \"\{name}\": the Timestamp cell at row \{row + 1} (\{micros} microseconds since 1970-01-01) is too far from the epoch for the double storage to hold its milliseconds exactly",
        )
      }
      stored = shifted.to_double()
    }
    values.push(stored)
  }
  ColumnPlan::{
    code: 65526,
    width: 8,
    format: "%tc",
    cells: Cells::Doubles(values),
  }
}

///|
/// The plan for a `String` column: a fixed-width string as wide as its
/// longest cell in bytes, or — when one cell is longer than 2045 bytes —
/// the whole column as long strings. A missing cell writes the empty
/// string: the format has no missing string. A long string's record is
/// keyed by the column and the row it first appears in, one record per
/// distinct text, and an empty text names key zero, which keeps none.
fn plan_string(
  name : String,
  index : Int32,
  column : @series.Series,
) -> ColumnPlan raise @types.DataError {
  let cells = column.to_scalars()
  let texts : Array[Bytes] = []
  let mut longest = 0
  for row, cell in cells {
    if cell is @types.Scalar::Null {
      texts.push(b"")
      continue
    }
    let encoded = encode_cell(name, row, cell.as_string())
    texts.push(encoded)
    if encoded.length() > longest {
      longest = encoded.length()
    }
  }
  if longest <= 2045 {
    let width = if longest > 1 { longest } else { 1 }
    return ColumnPlan::{
      code: width,
      width,
      format: "%\{width}s",
      cells: Cells::Texts(texts),
    }
  }
  let keys : Array[UInt64] = []
  let blob : Array[Byte] = []
  let seen : Map[String, UInt64] = Map([])
  for row, cell in cells {
    if cell is @types.Scalar::Null {
      keys.push(0UL)
      continue
    }
    let text = cell.as_string()
    if text == "" {
      keys.push(0UL)
      continue
    }
    let key = match seen.get(text) {
      Some(key) => key
      None => {
        // The pair is the column's and the row's own numbers, one
        // based, in the widths release 118 gives them: two bytes of
        // column and six of row.
        let fresh = (index + 1).to_uint64() | ((row + 1).to_uint64() << 16)
        seen[text] = fresh
        push_bytes(blob, b"GSO")
        push_le(blob, (index + 1).to_uint64(), 4)
        push_le(blob, (row + 1).to_uint64(), 8)
        push_le(blob, 130UL, 1)
        push_le(blob, (texts[row].length() + 1).to_uint64(), 4)
        push_bytes(blob, texts[row])
        push_le(blob, 0UL, 1)
        fresh
      }
    }
    keys.push(key)
  }
  ColumnPlan::{
    code: 32768,
    width: 8,
    format: "%9s",
    cells: Cells::Keys(keys, Bytes::from_array(blob)),
  }
}

///|
/// The plan for a column of dtype `Null`: a `double` with every cell
/// missing. Its cells are not read — the column has none to carry.
fn plan_vacant(column : @series.Series) -> ColumnPlan {
  ColumnPlan::{
    code: 65526,
    width: 8,
    format: "%10.0g",
    cells: Cells::Doubles(Array::make(column.len(), double_missing())),
  }
}

///|
/// One column's plan by its dtype. `Duration`, `Decimal`, `List` and
/// `Struct` columns refuse with `Unsupported`, naming the column and
/// the dtype; every other column refuses only on a cell the format
/// cannot carry, with `InvalidOperation`.
fn plan_column(
  name : String,
  index : Int32,
  column : @series.Series,
) -> ColumnPlan raise @types.DataError {
  let dtype = column.dtype()
  match dtype {
    Bool => plan_flag(column)
    Int => plan_int(name, column)
    Float => plan_float(name, column)
    String => plan_string(name, index, column)
    Date => plan_date(name, column)
    Timestamp => plan_timestamp(name, column)
    Duration | Decimal | List(_) | Struct(_) =>
      raise @types.DataError::Unsupported(
        "stata cannot carry column \"\{name}\" of dtype \{dtype}",
      )
    Null => plan_vacant(column)
  }
}

///|
/// One row of the data block: each column's cell, in column order, in
/// the bytes its plan spells.
fn push_row(out : Array[Byte], plans : Array[ColumnPlan], row : Int32) -> Unit {
  for plan in plans {
    match plan.cells {
      Integers(values) =>
        push_le(out, values[row].reinterpret_as_uint64(), plan.width)
      Doubles(values) => push_le(out, values[row].reinterpret_as_uint64(), 8)
      Texts(values) => {
        push_bytes(out, values[row])
        push_zeros(out, plan.width - values[row].length())
      }
      Keys(values, _) => push_le(out, values[row], 8)
    }
  }
}

///|
/// One Stata dataset file holding `columns`, each under its own name.
///
/// The file is release 118, little-endian: the first release whose text
/// is UTF-8. A `Bool` column writes as `byte`, an `Int` column as
/// `long` while every cell lies inside that storage's valid range and as
/// `double` otherwise, a `Float` column as `double`, a `String` column
/// as a fixed-width string as wide as its longest cell or — past 2045
/// bytes — as long strings, a `Date` column as `long` under `%td`, a
/// `Timestamp` column as `double` under `%tc`, and a column of dtype
/// `Null` as a `double` with every cell missing. A missing numeric cell
/// writes `.`, and a missing string cell the empty string. No value
/// label and no characteristic is written, the sort list is empty, the
/// dataset label is empty, and the creation timestamp is a constant.
///
/// Every column must have the same length. `height` pins the height of a
/// table with no column; without it the first column's length is the
/// height, and no column means zero.
///
/// Raises `LengthMismatch` when the columns' lengths disagree, or when
/// `height` disagrees with them. Raises `Unsupported` for a column of
/// dtype `Duration`, `Decimal`, `List` or `Struct`, naming the column
/// and the dtype. Raises `InvalidOperation` — naming the column — for a
/// name the format forbids, a duplicate name, and a cell the format
/// cannot carry; and for a negative height, or more columns than the
/// release carries.
pub fn write_stata_bytes(
  columns : Array[@series.Series],
  height? : Int32,
) -> Bytes raise @types.DataError {
  // The caller's array is copied at the boundary — the write is a
  // one-shot consumer, and the copy keeps that a fact of this body
  // rather than of the callee it hands it to.
  let columns = columns.copy()
  let ncols = columns.length()
  // Release 118 spells its variable count in two bytes, and carries
  // 32,767 variables at most.
  if ncols > 32767 {
    raise @types.DataError::InvalidOperation(
      "the stata writer was handed \{ncols} columns, and release 118 carries at most 32,767",
    )
  }
  // A caller that knows the frame's height pins it even when there are
  // no columns. Without a supplied height, derive it from the first
  // column, and an empty column list is 0.
  let derived = if ncols == 0 { 0 } else { columns[0].len() }
  for i in 1..<ncols {
    if columns[i].len() != derived {
      raise @types.DataError::LengthMismatch(derived, columns[i].len())
    }
  }
  let pinned = match height {
    Some(h) => h
    None => derived
  }
  if pinned < 0 {
    raise @types.DataError::InvalidOperation(
      "the stata writer was handed a height of \{pinned}, and a dataset declares no negative observation count",
    )
  }
  if ncols > 0 && pinned != derived {
    raise @types.DataError::LengthMismatch(derived, pinned)
  }
  // Every name is checked and every column planned before a byte is
  // written, so a refusal leaves no half-built file behind it.
  let earlier : Map[String, Int32] = Map([])
  let plans : Array[ColumnPlan] = []
  for i in 0..<ncols {
    let name = columns[i].name()
    check_name(name, i, earlier)
    plans.push(plan_column(name, i, columns[i]))
  }
  // The header: the release, the byte order, the counts, an empty label
  // and the constant timestamp, which opens with the control byte the
  // format's own files carry.
  let out : Array[Byte] = []
  push_bytes(
    out, b"<stata_dta><header><release>118</release><byteorder>LSF</byteorder><K>",
  )
  push_le(out, ncols.to_uint64(), 2)
  push_bytes(out, b"</K><N>")
  push_le(out, pinned.to_int64().reinterpret_as_uint64(), 8)
  push_bytes(out, b"</N><label>")
  push_le(out, 0UL, 2)
  push_bytes(out, b"</label><timestamp>")
  push_le(out, 18UL, 1)
  push_bytes(out, b"\x11")
  push_text(out, "01 Jan 1970 00:00")
  push_bytes(out, b"</timestamp></header>")
  // The map: fourteen positions, each where a section's opening tag
  // begins. Its bytes are written now and filled in once every section
  // is.
  let map_at = out.length()
  push_bytes(out, b"<map>")
  let entries_at = out.length()
  push_zeros(out, 112)
  push_bytes(out, b"</map>")
  let entries : Array[Int32] = Array::make(14, 0)
  entries[1] = map_at
  entries[2] = out.length()
  push_bytes(out, b"<variable_types>")
  for plan in plans {
    push_le(out, plan.code.to_uint64(), 2)
  }
  push_bytes(out, b"</variable_types>")
  entries[3] = out.length()
  push_bytes(out, b"<varnames>")
  for i in 0..<ncols {
    let name = columns[i].name()
    push_text(out, name)
    push_zeros(out, NAME_SLOT - @utf8.encode(name).length())
  }
  push_bytes(out, b"</varnames>")
  // The sort list: one two-byte slot per variable, zero for unsorted,
  // closed by a zero slot.
  entries[4] = out.length()
  push_bytes(out, b"<sortlist>")
  push_zeros(out, 2 * ncols + 2)
  push_bytes(out, b"</sortlist>")
  entries[5] = out.length()
  push_bytes(out, b"<formats>")
  for plan in plans {
    push_text(out, plan.format)
    push_zeros(out, FORMAT_SLOT - @utf8.encode(plan.format).length())
  }
  push_bytes(out, b"</formats>")
  // Every value-label name and every variable label is left blank.
  entries[6] = out.length()
  push_bytes(out, b"<value_label_names>")
  push_zeros(out, NAME_SLOT * ncols)
  push_bytes(out, b"</value_label_names>")
  entries[7] = out.length()
  push_bytes(out, b"<variable_labels>")
  push_zeros(out, 321 * ncols)
  push_bytes(out, b"</variable_labels>")
  entries[8] = out.length()
  push_bytes(out, b"<characteristics></characteristics>")
  entries[9] = out.length()
  push_bytes(out, b"<data>")
  for row in 0..<pinned {
    push_row(out, plans, row)
  }
  push_bytes(out, b"</data>")
  // The long-string records, column by column in the order the columns
  // hold them.
  entries[10] = out.length()
  push_bytes(out, b"<strls>")
  for plan in plans {
    match plan.cells {
      Keys(_, blob) => push_bytes(out, blob)
      Integers(_) | Doubles(_) | Texts(_) => ()
    }
  }
  push_bytes(out, b"</strls>")
  entries[11] = out.length()
  push_bytes(out, b"<value_labels></value_labels>")
  entries[12] = out.length()
  push_bytes(out, b"</stata_dta>")
  entries[13] = out.length()
  for i in 0..<14 {
    patch_le64(out, entries_at + 8 * i, entries[i])
  }
  Bytes::from_array(out)
}
