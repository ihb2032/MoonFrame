// The compound file that holds the workbook stream: its header, its file
// allocation table, its directory, and the mini stream that holds the
// streams shorter than the header's cutoff, with a table of its own. Every
// sector number, chain, stream size and directory entry the file carries
// is checked against the file before it indexes, slices or allocates
// anything: a chain may loop, a stream may claim more than the file holds,
// a table may name a sector the file does not have, and each refuses,
// naming the byte.

///|
/// The bytes a compound file opens with, when `bytes` is long enough to
/// hold them.
fn opens_compound(bytes : Bytes) -> Bool {
  if bytes.length() < 8 {
    return false
  }
  bytes[0].to_int() == 0xD0 &&
  bytes[1].to_int() == 0xCF &&
  bytes[2].to_int() == 0x11 &&
  bytes[3].to_int() == 0xE0 &&
  bytes[4].to_int() == 0xA1 &&
  bytes[5].to_int() == 0xB1 &&
  bytes[6].to_int() == 0x1A &&
  bytes[7].to_int() == 0xE1
}

///|
/// An unsigned two-byte integer at `at`, which the caller has shown the
/// bytes hold.
fn u16_at(bytes : Bytes, at : Int32) -> Int32 {
  bytes[at].to_int() | (bytes[at + 1].to_int() << 8)
}

///|
/// An unsigned four-byte integer at `at`, which the caller has shown the
/// bytes hold.
fn u32_at(bytes : Bytes, at : Int32) -> Int64 {
  u16_at(bytes, at).to_int64() | (u16_at(bytes, at + 2).to_int64() << 16)
}

///|
/// The bits of a four-byte integer at `at`, as the file's little-endian
/// order spells them, which the caller has shown the bytes hold.
fn i32_at(bytes : Bytes, at : Int32) -> Int32 {
  u16_at(bytes, at) | (u16_at(bytes, at + 2) << 16)
}

///|
/// The bits of the eight-byte floating-point number at `at`, which the
/// caller has shown the bytes hold.
fn bits_at(bytes : Bytes, at : Int32) -> UInt64 {
  let mut value = 0UL
  for j in 0..<8 {
    value = (value << 8) | bytes[at + 7 - j].to_uint64()
  }
  value
}

///|
/// The file's sectors under the reading point: its bytes, how wide a
/// sector is, and how many whole ones lie past the 512-byte header — the
/// bound every sector number is checked against.
priv struct Sectors {
  bytes : Bytes
  /// Bytes a sector holds: 512, or 4096 in a version 4 file.
  sector : Int32
  /// The whole sectors past the header; a sector number must be under it.
  count : Int32
}

///|
/// Where sector `sid` of the file begins.
fn Sectors::start(self : Sectors, sid : Int32) -> Int32 {
  512 + sid * self.sector
}

///|
/// The byte of the file where `table`'s entry for sector `sid` lies;
/// `sid` is under the table's length.
fn Sectors::entry_byte(self : Sectors, table : Table, sid : Int32) -> Int32 {
  let per = self.sector / 4
  self.start(table.at[sid / per]) + sid % per * 4
}

///|
/// An allocation table read out of the file: its entries, the file's
/// sectors the entries lie in, and the sectors it indexes — the file's
/// own for the file allocation table, the mini stream's for its own table,
/// which says how a refusal names them.
priv struct Table {
  entries : Array[Int32]
  /// The file's sectors holding the table, in order.
  at : Array[Int32]
  /// How many sectors the table indexes.
  count : Int32
  /// What one of them is called, and where it lies.
  kind : String
  home : String
}

///|
/// The end-of-chain marker an allocation table's entry carries: the four
/// bytes FE FF FF FF, which read as a signed 32-bit number is -2. A free
/// sector's marker, FF FF FF FF, ends a chain as well, as writers in the
/// wild spell it.
const END_OF_CHAIN : Int32 = -2

///|
/// The free-sector marker: the four bytes FF FF FF FF, which read as a
/// signed 32-bit number is -1.
const FREE_SECTOR : Int32 = -1

///|
/// Whether an allocation table's entry ends a chain rather than naming
/// the sector after it.
fn ends_chain(entry : Int32) -> Bool {
  entry == END_OF_CHAIN || entry == FREE_SECTOR
}

///|
/// The sectors of one stream, walked through its allocation table from
/// the sector it starts at: `needed` sectors when `needed` is not
/// negative, and to the chain's end otherwise. `origin` is the byte of
/// the file where the stream's first sector number is declared, and
/// `what` names the stream, for the refusals. Each sector the chain
/// enters is one the file holds and one this chain has not entered
/// before, so a chain that loops or leaves the file refuses instead of
/// cycling or reading past the end.
fn chain(
  file : Sectors,
  table : Table,
  start : Int32,
  needed : Int32,
  what : String,
  origin : Int32,
) -> Array[Int32] raise @types.DataError {
  let out : Array[Int32] = []
  let seen = Array::make(table.count, false)
  let mut sid = start
  // The byte where the current sector number was read: the stream's own
  // declaration first, then the table's entry for the sector before it.
  let mut declared_at = origin
  while needed < 0 || out.length() < needed {
    if sid < 0 || sid >= table.count {
      raise bad(
        "byte \{declared_at}: the \{what} names \{table.kind} \{unsigned(sid)}, and \{table.home} holds \{table.count}",
      )
    }
    if sid >= table.entries.length() {
      raise bad(
        "byte \{declared_at}: the \{what} names \{table.kind} \{sid}, and its allocation table holds \{table.entries.length()} entries",
      )
    }
    if seen[sid] {
      raise bad(
        "byte \{declared_at}: the \{what} enters \{table.kind} \{sid} a second time, so its chain loops",
      )
    }
    seen[sid] = true
    out.push(sid)
    if needed >= 0 && out.length() == needed {
      break
    }
    declared_at = file.entry_byte(table, sid)
    sid = table.entries[sid]
    if ends_chain(sid) {
      if needed < 0 {
        break
      }
      raise bad(
        "byte \{declared_at}: the \{what} needs \{needed} \{table.kind}s and its chain ends after \{out.length()}",
      )
    }
  }
  out
}

///|
/// The bytes of a stream whose sectors are `sectors`: `size` bytes of
/// them, or all they hold when `size` is negative. A sector `width`
/// bytes wide begins at `base` plus its number times the width. Every
/// sector is one its chain showed to lie inside `source`, so each read
/// stays inside it.
fn gather(
  source : Bytes,
  base : Int32,
  sectors : Array[Int32],
  size : Int32,
  width : Int32,
) -> Bytes {
  let shift = if width == 64 { 6 } else if width == 512 { 9 } else { 12 }
  let mask = width - 1
  let total = if size < 0 { sectors.length() * width } else { size }
  Bytes::makei(total, i => {
    source[base + sectors[i >> shift] * width + (i & mask)]
  })
}

///|
/// The sectors the file allocation table lies in, in table order: the
/// header's 109 entries, then the DIFAT sectors chained after them — each
/// holding one entry fewer, its last naming the next. An entry that is
/// unused or ends a chain is skipped; one that names a sector the file
/// does not hold refuses, as does a DIFAT chain that loops or leaves the
/// file, and a sector named for the table a second time.
fn allocation_sectors(file : Sectors) -> Array[Int32] raise @types.DataError {
  let out : Array[Int32] = []
  let seen = Array::make(file.count, false)
  // The entries under the reading point: where they begin in the file,
  // how many there are, and whether the last of them links onward.
  let mut from = 76
  let mut count = 109
  let mut linked = false
  let mut next = i32_at(file.bytes, 68)
  let mut next_at = 68
  while true {
    for i in 0..<count {
      if linked && i == count - 1 {
        next = i32_at(file.bytes, from + 4 * i)
        next_at = from + 4 * i
        continue
      }
      let sid = i32_at(file.bytes, from + 4 * i)
      if ends_chain(sid) {
        continue
      }
      if sid < 0 || sid >= file.count {
        raise bad(
          "byte \{from + 4 * i}: the header names sector \{unsigned(sid)} as one of the file allocation table's, and the file holds \{file.count}",
        )
      }
      if seen[sid] {
        raise bad(
          "byte \{from + 4 * i}: the header names sector \{sid} as one of the file allocation table's a second time",
        )
      }
      seen[sid] = true
      out.push(sid)
    }
    if ends_chain(next) {
      break
    }
    if next < 0 || next >= file.count {
      raise bad(
        "byte \{next_at}: the file allocation table's chain names sector \{unsigned(next)}, and the file holds \{file.count}",
      )
    }
    if seen[next] {
      raise bad(
        "byte \{next_at}: the file allocation table's chain enters sector \{next} a second time, so it loops",
      )
    }
    seen[next] = true
    from = file.start(next)
    count = file.sector / 4
    linked = true
  }
  out
}

///|
/// An allocation table read out of the file's sectors `at`: each holds as
/// many four-byte entries as it has room for.
fn read_table(
  file : Sectors,
  at : Array[Int32],
  count : Int32,
  kind : String,
  home : String,
) -> Table {
  let entries : Array[Int32] = []
  let per = file.sector / 4
  for sid in at {
    let start = file.start(sid)
    for i in 0..<per {
      entries.push(i32_at(file.bytes, start + 4 * i))
    }
  }
  Table::{ entries, at, count, kind, home, }
}

///|
/// A compound file opened from its bytes, its workbook stream left in
/// place.
priv struct Compound {
  file : Sectors
  /// The file allocation table.
  table : Table
  /// The directory, as one stream of 128-byte entries, and its sectors.
  directory : Bytes
  directory_at : Array[Int32]
  /// The header's major version: a version 3 file spells a stream's size
  /// in its low four bytes alone.
  version : Int32
  /// The size a stream must reach to live in the file's own sectors.
  cutoff : Int64
}

///|
/// Open the compound file in `bytes` and read what finding a stream
/// needs: the header, the file allocation table and the directory. Raises
/// `Unsupported` for bytes that do not open with a compound file's
/// signature, and for a byte order, a version, a sector size or a mini
/// sector size this reader does not read; raises `ParseError`, naming the
/// byte, for a header the file cuts short, for a table that names a
/// sector the file does not hold, and for a chain that loops or leaves the
/// file.
fn open_compound(bytes : Bytes) -> Compound raise @types.DataError {
  if !opens_compound(bytes) {
    raise nope(
      "not an .xls workbook: the bytes do not open with a compound file's signature",
    )
  }
  if bytes.length() < 512 {
    raise bad(
      "byte \{bytes.length()}: the file ends inside the compound file's 512-byte header",
    )
  }
  let order = u16_at(bytes, 28)
  if order != 0xFFFE {
    raise nope(
      "byte 28: the compound file declares byte order 0x\{hex4(order)}, and this reader reads the little-endian one, 0xFFFE",
    )
  }
  let version = u16_at(bytes, 26)
  let shift = u16_at(bytes, 30)
  let sector = if version == 3 && shift == 9 {
    512
  } else if version == 4 && shift == 12 {
    4096
  } else {
    raise nope(
      "byte 26: the compound file declares version \{version} with 2^\{shift}-byte sectors, and this reader reads version 3 with 512-byte sectors and version 4 with 4096-byte ones",
    )
  }
  let mini_shift = u16_at(bytes, 32)
  if mini_shift != 6 {
    raise nope(
      "byte 32: the compound file declares 2^\{mini_shift}-byte mini sectors, and this reader reads 64-byte ones",
    )
  }
  let file = Sectors::{ bytes, sector, count: (bytes.length() - 512) / sector, }
  let table = read_table(
    file,
    allocation_sectors(file),
    file.count,
    "sector",
    "the file",
  )
  // The directory has no declared size: it runs to its chain's end, which
  // cannot be longer than the file's sectors.
  let first = i32_at(bytes, 48)
  if first < 0 || first >= file.count {
    raise bad(
      "byte 48: the header places the directory at sector \{unsigned(first)}, and the file holds \{file.count}",
    )
  }
  let directory_at = chain(file, table, first, -1, "directory", 48)
  let directory = gather(bytes, 512, directory_at, -1, sector)
  Compound::{
    file,
    table,
    directory,
    directory_at,
    version,
    cutoff: u32_at(bytes, 56),
  }
}

///|
/// The mini stream and its table, read only when a stream turns out to
/// need them: the root entry's stream through the file allocation table,
/// and the table from the sectors the header gives it. The mini stream is
/// addressed in whole 64-byte mini sectors, so it is held whole. Raises
/// `ParseError`, naming the byte, for a root entry whose stream the file
/// cannot hold, for a table placed at a sector the file does not have, and
/// for a chain that loops or ends early.
fn read_mini(compound : Compound) -> (Bytes, Table) raise @types.DataError {
  let file = compound.file
  let root_size = entry_size(compound, 0)
  let mini_stream = if root_size == 0L {
    b""
  } else {
    check_size(
      compound,
      root_size,
      directory_byte(compound, 120),
      "the root entry's stream",
    )
    let sectors = chain(
      file,
      compound.table,
      i32_at(compound.directory, 116),
      sectors_needed(root_size, file.sector),
      "root entry's stream",
      directory_byte(compound, 116),
    )
    // The root entry's size is the mini stream's; what the sector holding
    // its end leaves after it is not.
    gather(file.bytes, 512, sectors, root_size.to_int(), file.sector)
  }
  // The mini stream is addressed in whole 64-byte mini sectors: what its
  // size leaves short of the last one is nothing, and the table indexes
  // the whole ones.
  let whole = (mini_stream.length() + 63) / 64
  let table_count = u32_at(file.bytes, 64)
  let mini_table = if table_count == 0L {
    Table::{
      entries: [],
      at: [],
      count: whole,
      kind: "mini sector",
      home: "the mini stream",
    }
  } else {
    let first = i32_at(file.bytes, 60)
    if first < 0 || first >= file.count {
      raise bad(
        "byte 60: the header places the mini stream's table at sector \{unsigned(first)}, and the file holds \{file.count}",
      )
    }
    let at = chain(
      file,
      compound.table,
      first,
      table_count.to_int(),
      "mini stream's table",
      60,
    )
    read_table(file, at, whole, "mini sector", "the mini stream")
  }
  (held_whole(mini_stream, 64), mini_table)
}

///|
/// `source` held in whole sectors `width` bytes wide, the last completed
/// with nothing.
fn held_whole(source : Bytes, width : Int32) -> Bytes {
  let whole = (source.length() + width - 1) / width * width
  Bytes::makei(whole, i => if i < source.length() { source[i] } else { b'\x00' })
}

///|
/// A directory entry's stream size: all eight bytes in a version 4 file,
/// and the low four alone in a version 3 one, whose streams are shorter
/// than eight bytes could spell.
fn entry_size(compound : Compound, index : Int32) -> Int64 {
  let at = index * 128 + 120
  let low = u32_at(compound.directory, at)
  if compound.version == 3 {
    low
  } else {
    low | (u32_at(compound.directory, at + 4) << 32)
  }
}

///|
/// The byte of the file where byte `inside` of the directory stream lies.
fn directory_byte(compound : Compound, inside : Int32) -> Int32 {
  let sector = compound.file.sector
  compound.file.start(compound.directory_at[inside / sector]) + inside % sector
}

///|
/// How many sectors of `sector` bytes a stream of `size` bytes needs.
fn sectors_needed(size : Int64, sector : Int32) -> Int32 {
  ((size + sector.to_int64() - 1L) / sector.to_int64()).to_int()
}

///|
/// Refuse unless the stream declared at byte `at` of the file, `size`
/// bytes long, fits inside the file's sectors: nothing is allocated for a
/// stream before this holds.
fn check_size(
  compound : Compound,
  size : Int64,
  at : Int32,
  what : String,
) -> Unit raise @types.DataError {
  let held = compound.file.bytes.length() - 512
  if size < 0L || size > held.to_int64() {
    raise bad(
      "byte \{at}: \{what} declares \{size.reinterpret_as_uint64()} bytes, and the file holds \{held} past its header",
    )
  }
}

///|
/// Check that every entry of the directory spells its name as the format
/// says: no name at all, or an even count of bytes from 2 to 64 counting
/// the final U+0000 of a UTF-16 name. The whole directory is checked
/// before any entry is read, as a reader decoding every name reads them
/// all before it looks for the workbook's. Raises `ParseError`, naming
/// the byte, for a length no name has.
fn check_directory(compound : Compound) -> Unit raise @types.DataError {
  let entries = compound.directory.length() / 128
  for index in 0..<entries {
    let inside = index * 128 + 64
    let length = u16_at(compound.directory, inside)
    if length != 0 && (length < 2 || length > 64 || (length & 1) != 0) {
      raise bad(
        "byte \{directory_byte(compound, inside)}: directory entry \{index} spells its name in \{length} bytes, neither an even count from 2 to 64 nor none",
      )
    }
  }
}

///|
/// The name directory entry `index` spells, compared with `want` without
/// regard to the case of its letters. The entry's name is UTF-16 and
/// `want` is ASCII, so the comparison runs on code units and no name the
/// file carries is ever decoded. `check_directory` has shown every length
/// to be one a name has; an entry naming nothing spells no `want`.
fn entry_named(directory : Bytes, index : Int32, want : String) -> Bool {
  let base = index * 128
  // The name's length counts its final U+0000, which is not spelled.
  let length = u16_at(directory, base + 64)
  let units = want.code_units()
  if length < 2 || (length - 2) / 2 != units.length() {
    return false
  }
  for k in 0..<units.length() {
    let unit = u16_at(directory, base + 2 * k)
    // The letter of `want`, and the entry's unit, both lower case.
    let letter = lower_letter(units[k].to_int())
    if lower_letter(unit) != letter {
      return false
    }
  }
  true
}

///|
/// An ASCII letter as its lower case; any other code as it is.
fn lower_letter(code : Int32) -> Int32 {
  if code >= 65 && code <= 90 {
    code + 32
  } else {
    code
  }
}

///|
/// The stream `name` names, of the streams the directory holds: an entry
/// of the stream kind with that name. `None` when the directory holds no
/// such entry.
fn find_stream(compound : Compound, name : String) -> Int32? {
  let entries = compound.directory.length() / 128
  for index in 0..<entries {
    // The object type, 2 for a stream.
    if compound.directory[index * 128 + 66].to_int() == 2 &&
      entry_named(compound.directory, index, name) {
      return Some(index)
    }
  }
  None
}

///|
/// The workbook's directory entry, and the spelling of its name: the
/// stream named Workbook, or the one named Book where a writer spelled it
/// so. Raises `Unsupported` when the compound file holds neither — it is
/// not an .xls workbook.
fn workbook_entry(
  compound : Compound,
) -> (String, Int32) raise @types.DataError {
  let found = find_stream(compound, "Workbook")
  if found is Some(index) {
    return ("Workbook", index)
  }
  let older = find_stream(compound, "Book")
  if older is Some(index) {
    return ("Book", index)
  }
  raise nope(
    "not an .xls workbook: the compound file holds no stream named Workbook or Book",
  )
}

///|
/// The workbook stream of the compound file in `bytes`: the stream named
/// Workbook, or the one named Book where a writer spelled it so, in whole
/// whatever sectors it lies in. Raises `Unsupported` when the compound
/// file holds neither — it is not an .xls workbook; raises `ParseError`,
/// naming the byte, for a directory entry whose name length no name has,
/// for a stream whose size the file cannot hold, whose chain ends before
/// the sectors it needs, and for a short stream whose mini sectors lie
/// outside the mini stream or outside its table.
fn workbook_stream(bytes : Bytes) -> Bytes raise @types.DataError {
  let compound = open_compound(bytes)
  check_directory(compound)
  let (name, index) = workbook_entry(compound)
  let file = compound.file
  let base = index * 128
  let what = "\{name} stream"
  let size = entry_size(compound, index)
  check_size(
    compound,
    size,
    directory_byte(compound, base + 120),
    "the \{what}",
  )
  if size == 0L {
    // Spelled through a binding: the coverage reporter's own parser
    // cannot read a byte-string literal returned directly.
    let nothing : Bytes = b""
    return nothing
  }
  let start = i32_at(compound.directory, base + 116)
  let origin = directory_byte(compound, base + 116)
  let needed = sectors_needed(size, file.sector)
  if size >= compound.cutoff {
    let sectors = chain(file, compound.table, start, needed, what, origin)
    return gather(bytes, 512, sectors, size.to_int(), file.sector)
  }
  // A short stream lives in the mini stream, in 64-byte mini sectors its
  // own table chains: a file with no mini stream holds none, and every
  // mini sector such a stream names is outside it.
  let (mini_stream, mini_table) = read_mini(compound)
  let mini_needed = sectors_needed(size, 64)
  let sectors = chain(file, mini_table, start, mini_needed, what, origin)
  gather(mini_stream, 0, sectors, size.to_int(), 64)
}
