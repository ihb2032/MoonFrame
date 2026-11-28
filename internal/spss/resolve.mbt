///|
/// The four-byte unsigned integer at `at` of `data`, in the file's
/// integer byte order.
fn u32_at(data : Bytes, at : Int32, big : Bool) -> Int64 {
  let mut value = 0L
  if big {
    for i in 0..<4 {
      value = (value << 8) | data[at + i].to_int64()
    }
  } else {
    for i = 3; i >= 0; i = i - 1 {
      value = (value << 8) | data[at + i].to_int64()
    }
  }
  value
}

///|
/// The dictionary: its header, its records, and what the extension
/// records make of the variables — the text encoding every string decodes
/// in, each variable's long name, the very long strings the variable
/// records join into, the missing values declared for those, and the
/// floating-point format and system-missing value the machine records
/// name.
fn read_dictionary(c : Cursor) -> Dictionary raise @types.DataError {
  let (compression, ncases) = read_header(c)
  let slots : Array[Slot] = []
  let records = read_records(c, slots)
  let data_start = c.pos
  // The machine integer info record names the floating-point format and
  // a code page; one that is not the thirty-two bytes the format gives
  // it is passed over whole.
  let mut character_code = -1L
  if records.integer_info is Some(data) {
    if data.length() == 32 {
      let at = records.integer_info_at
      let representation = u32_at(data, 16, c.big)
      if representation != 1L {
        raise nope(
          "byte \{at}: the file declares floating-point representation \{representation}, which is not IEEE 754 and this reader does not decode",
        )
      }
      character_code = u32_at(data, 28, c.big)
    }
  }
  let encoding = encoding_declared(records.encoding_name, character_code)
  for slot in slots {
    slot.name = text_of(slot.raw_name, encoding, "byte \{slot.at + 24}")
  }
  apply_long_names(slots, records, encoding)
  apply_lengths(slots, records)
  apply_long_missing(slots, records, encoding, c.big)
  for slot in slots {
    for raw in slot.missing_raw {
      slot.missing.push(text_of(cut_blank(raw), encoding, "byte \{slot.at}"))
    }
  }
  let mut sysmis = SYSMIS
  if records.float_info is Some(data) {
    if data.length() == 24 {
      sysmis = bits_at(data, 0, c.big_float)
    }
  }
  if slots.length() == 0 {
    raise bad(
      "byte \{data_start}: the dictionary holds no variable, so a case has no size",
    )
  }
  Dictionary::{
    slots,
    compression,
    ncases,
    sysmis,
    encoding,
    big_float: c.big_float,
  }
}

///|
/// The slot whose variable record spells `key` as its name, or −1.
fn find_slot(slots : Array[Slot], key : BytesView) -> Int32 {
  for i, slot in slots {
    if same_name(slot.raw_name, key) {
      return i
    }
  }
  -1
}

///|
/// The number `text` spell, or −1 when they spell none or a number too
/// wide for the arithmetic.
fn digits(text : BytesView) -> Int64 {
  if text.length() == 0 || text.length() > 18 {
    return -1L
  }
  let mut value = 0L
  for i in 0..<text.length() {
    let d = text[i].to_int() - 48
    if d < 0 || d > 9 {
      return -1L
    }
    value = value * 10L + d.to_int64()
  }
  value
}

///|
/// Where a piece of an extension record's data sits in the file: the
/// record's sixteen-byte header, then the piece's offset in the data.
fn inside(at : Int32, start : Int32) -> Int32 {
  at + 16 + start
}

///|
/// The long variable names record: `name=long name` pairs separated by
/// tabs, each keyed by the name a variable record spells. A key naming
/// no variable is passed over: the record only renames, so an entry that
/// cannot apply leaves every cell as it was. An entry that spells no
/// pair contradicts the record.
fn apply_long_names(
  slots : Array[Slot],
  records : Records,
  encoding : Encoding,
) -> Unit raise @types.DataError {
  let data = match records.long_names {
    Some(data) => data
    None => return
  }
  let at = records.long_names_at
  let n = data.length()
  let mut i = 0
  while i <= n {
    let start = i
    while i < n && data[i].to_int() != 9 {
      i += 1
    }
    i += 1
    if i - 1 == start {
      continue
    }
    let piece = data[start:i - 1]
    let eq = locate(piece, 61)
    if eq <= 0 {
      raise bad(
        "byte \{inside(at, start)}: the long variable name record's entry \{plain_text(piece, false)} spells no variable and long name",
      )
    }
    let value = cut_blank(piece[eq + 1:])
    if value.length() == 0 {
      raise bad(
        "byte \{inside(at, start)}: the long variable name record gives the variable \{plain_text(piece[:eq], false)} no long name",
      )
    }
    let found = find_slot(slots, piece[:eq])
    if found >= 0 {
      slots[found].name = text_of(value, encoding, "byte \{inside(at, start)}")
    }
  }
}

///|
/// The very long string record: `name=width` pairs, naming the variable
/// record a string wider than 255 bytes opens with and its width. Its
/// segments are that variable and the ones after it, as many as the
/// width needs at 252 bytes each; each must be as wide as its place
/// calls for, rounded to eight bytes, since some writers round the last
/// one up. An entry naming no variable, a width one variable could hold,
/// or a segment of the wrong width contradicts the dictionary.
fn apply_lengths(
  slots : Array[Slot],
  records : Records,
) -> Unit raise @types.DataError {
  let data = match records.lengths {
    Some(data) => data
    None => return
  }
  let at = records.lengths_at
  let n = data.length()
  let mut i = 0
  while i < n {
    // Entries are delimited by NUL and tab bytes, one or several.
    while i < n && (data[i].to_int() == 0 || data[i].to_int() == 9) {
      i += 1
    }
    if i == n {
      break
    }
    let start = i
    while i < n && data[i].to_int() != 0 && data[i].to_int() != 9 {
      i += 1
    }
    let piece = data[start:i]
    let eq = locate(piece, 61)
    let width = if eq < 0 { -1L } else { digits(piece[eq + 1:]) }
    if eq <= 0 || width < 0L {
      raise bad(
        "byte \{inside(at, start)}: the very long string record's entry \{plain_text(piece, false)} spells no variable and width",
      )
    }
    let found = find_slot(slots, piece[:eq])
    if found < 0 {
      raise bad(
        "byte \{inside(at, start)}: the very long string record names the variable \{plain_text(piece[:eq], false)}, which the dictionary does not hold",
      )
    }
    let first = slots[found]
    if first.width == 0 {
      raise bad(
        "byte \{inside(at, start)}: the very long string record names the numeric variable \{first.name}",
      )
    }
    if first.length > 0L || first.owner >= 0 {
      raise bad(
        "byte \{inside(at, start)}: the very long string record names the variable \{first.name} a second time",
      )
    }
    if width < 256L {
      raise bad(
        "byte \{inside(at, start)}: the very long string record gives the variable \{first.name} a width of \{width}, which one variable holds",
      )
    }
    let count = (width + 251L) / 252L
    let held = (slots.length() - found).to_int64()
    if count > held {
      raise bad(
        "byte \{inside(at, start)}: the very long string \{first.name} of width \{width} needs \{count} segments and the dictionary holds \{held} variables from it on",
      )
    }
    for k in 0..<count.to_int() {
      let segment = slots[found + k]
      let expected = if k.to_int64() < count - 1L {
        255L
      } else {
        width - (count - 1L) * 252L
      }
      if segment.width == 0 {
        raise bad(
          "byte \{inside(at, start)}: segment \{k + 1} of the very long string \{first.name} is the numeric variable \{segment.name}",
        )
      }
      if up8(segment.width.to_int64()) != up8(expected) {
        raise bad(
          "byte \{inside(at, start)}: segment \{k + 1} of the very long string \{first.name} is \{segment.width} bytes wide, where its width \{width} calls for \{expected}",
        )
      }
    }
    first.length = width
    for k in 1..<count.to_int() {
      slots[found + k].owner = found
    }
  }
}

///|
/// The bytes of segment `k` of a very long string that carry text: the
/// string is packed 255 bytes to a segment, and the rest of each segment
/// is padding the writer left.
fn segment_used(length : Int64, k : Int32) -> Int32 {
  let left = length - 255L * k.to_int64()
  if left < 0L {
    0
  } else if left > 255L {
    255
  } else {
    left.to_int()
  }
}

///|
/// The long string missing values record: for a string wider than eight
/// bytes, its name and the values declared missing, each as long as the
/// record says. The variable is named by its long name where it has one.
fn apply_long_missing(
  slots : Array[Slot],
  records : Records,
  encoding : Encoding,
  big : Bool,
) -> Unit raise @types.DataError {
  let data = match records.long_missing {
    Some(data) => data
    None => return
  }
  let at = records.long_missing_at
  let n = data.length()
  let mut i = 0
  while i < n {
    let start = i
    if n - i < 4 {
      raise bad(
        "byte \{inside(at, start)}: the long string missing values record ends inside a name length",
      )
    }
    let name_len = u32_at(data, i, big)
    i += 4
    if name_len > (n - i).to_int64() {
      raise bad(
        "byte \{inside(at, start)}: the long string missing values record names a variable in \{name_len} bytes and ends before them",
      )
    }
    let raw = data[i:i + name_len.to_int()]
    i += name_len.to_int()
    if n - i < 5 {
      raise bad(
        "byte \{inside(at, start)}: the long string missing values record ends before the variable's missing values",
      )
    }
    let count = data[i].to_int()
    i += 1
    if count < 1 || count > 3 {
      raise bad(
        "byte \{inside(at, i - 1)}: the long string missing values record declares \{count} missing values, not 1, 2 or 3",
      )
    }
    let value_len = u32_at(data, i, big)
    i += 4
    if count.to_int64() * value_len > (n - i).to_int64() {
      raise bad(
        "byte \{inside(at, start)}: the long string missing values record declares \{count} values of \{value_len} bytes and ends before them",
      )
    }
    let name = text_of(cut_blank(raw), encoding, "byte \{inside(at, start)}")
    let mut found = -1
    for k, slot in slots {
      if slot.name == name || same_name(slot.raw_name, raw) {
        found = k
      }
    }
    if found < 0 {
      raise bad(
        "byte \{inside(at, start)}: the long string missing values record names the variable \{name}, which the dictionary does not hold",
      )
    }
    if slots[found].width == 0 {
      raise bad(
        "byte \{inside(at, start)}: the long string missing values record names the numeric variable \{slots[found].name}",
      )
    }
    for _ in 0..<count {
      slots[found].missing_raw.push(data[i:i + value_len.to_int()].to_owned())
      i += value_len.to_int()
    }
  }
}
