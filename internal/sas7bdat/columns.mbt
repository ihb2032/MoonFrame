// Resolving what the walk found into a plan: the columns — each named,
// placed in the row, typed, and given its display format — the runs of
// rows with their counts, and the expansion a compressed row goes
// through. Every reference a subheader holds is checked against the text
// block it names before it is followed.

///|
/// A reference into one text block: the block's number, the offset and
/// the length within it, and the byte the reference is spelled at.
priv struct TextRef {
  at : Int64
  index : UInt64
  offset : UInt64
  width : UInt64
}

///|
/// One column's place in the row and type, as the column-attributes
/// subheader spells them, and the byte the entry is spelled at.
priv struct AttrRef {
  at : Int64
  offset : UInt64
  width : UInt64
  kind : Int64
}

///|
/// One column: its name as the file spells it, where its cell lies in
/// the row and how wide the cell is, whether the cell is a number, and
/// its display format (the empty string when it has none).
priv struct Column {
  name : String
  offset : Int64
  width : Int64
  numeric : Bool
  format : String
}

///|
/// The expansion of one compressed row: the file's bytes, the offset of
/// the row as it is stored and its stored length, and the buffer of one
/// row's length it expands into. The count of bytes written comes back.
type Expansion = (Bytes, Int64, Int64, Array[Byte]) -> Int64 raise @types.DataError

///|
/// What the file's metadata resolves to: the columns, the runs of rows
/// with every count fixed, the number of rows the file declares, the row
/// length, and the expansion a compressed row goes through.
priv struct Plan {
  columns : Array[Column]
  runs : Array[Run]
  row_count : Int64
  row_length : Int64
  expand : Expansion
}

///|
/// The 8-byte names of the two row compressions, inside the 7 bytes both
/// share.
const COMPRESSION_PREFIX : String = "SASYZCR"

///|
/// Whether the bytes at `at` spell `text`, which is ASCII.
fn spells(
  bytes : Bytes,
  at : Int64,
  text : String,
) -> Bool raise @types.DataError {
  let units = text.code_units()
  let mut same = true
  for i in 0..<units.length() {
    if byte_at(bytes, at + i.to_int64()) != units[i].to_int() {
      same = false
    }
  }
  same
}

///|
/// The column-attribute code of a numeric column, and of a character one.
const NUMERIC : Int64 = 1L

///|
const CHARACTER : Int64 = 2L

///|
/// The number of bytes a number is stored in at most.
const NUMBER_BYTES : Int64 = 8L

///|
/// The references one column-name subheader holds: as many 8-byte
/// entries as its length allows, each a block number, an offset and a
/// length of 16 bits.
fn collect_names(
  bytes : Bytes,
  header : Header,
  sub : Subheader,
  refs : Array[TextRef],
) -> Unit raise @types.DataError {
  let word = header.word()
  let room = sub.length - 2L * word - 12L
  if room < 0L || room % 8L != 0L {
    raise bad(sub.at, "a column-name subheader of \{sub.length} bytes")
  }
  let base = sub.at + word + 8L
  for i in 0..<(room / 8L).to_int() {
    let at = base + 8L * i.to_int64()
    refs.push(TextRef::{
      at,
      index: uint_at(bytes, at, 2L, header.little),
      offset: uint_at(bytes, at + 2L, 2L, header.little),
      width: uint_at(bytes, at + 4L, 2L, header.little),
    })
  }
}

///|
/// The references one column-attributes subheader holds: as many entries
/// as its length allows, each an offset of a word, a 32-bit width, two
/// unused bytes, the type byte and an unused one.
fn collect_attributes(
  bytes : Bytes,
  header : Header,
  sub : Subheader,
  refs : Array[AttrRef],
) -> Unit raise @types.DataError {
  let word = header.word()
  let room = sub.length - 2L * word - 12L
  if room < 0L || room % (word + 8L) != 0L {
    raise bad(sub.at, "a column-attribute subheader of \{sub.length} bytes")
  }
  let base = sub.at + word + 8L
  for i in 0..<(room / (word + 8L)).to_int() {
    let at = base + (word + 8L) * i.to_int64()
    refs.push(AttrRef::{
      at,
      offset: uint_at(bytes, at, word, header.little),
      width: uint_at(bytes, at + word, 4L, header.little),
      kind: uint_at(bytes, at + word + 6L, 1L, header.little).reinterpret_as_int64(),
    })
  }
}

///|
/// The reference one format subheader holds: the display format's block
/// number, offset and length. One subheader belongs to one column, in
/// the order the columns are named.
fn collect_formats(
  bytes : Bytes,
  header : Header,
  sub : Subheader,
  refs : Array[TextRef],
) -> Unit raise @types.DataError {
  if sub.length < 3L * header.word() + 34L {
    raise bad(sub.at, "a format subheader of \{sub.length} bytes")
  }
  let at = sub.at + 3L * header.word() + 22L
  refs.push(TextRef::{
    at,
    index: uint_at(bytes, at, 2L, header.little),
    offset: uint_at(bytes, at + 2L, 2L, header.little),
    width: uint_at(bytes, at + 4L, 2L, header.little),
  })
}

///|
/// Where in the file the bytes a text reference names lie: the offset of
/// the first and the length. A reference to a block the file does not
/// hold, or to bytes past a block's end, raises `ParseError` at the byte
/// the reference is spelled at; `what` names the text in the message.
fn text_span(
  meta : Meta,
  reference : TextRef,
  what : String,
) -> (Int64, Int64) raise @types.DataError {
  if reference.index >= meta.texts.length().to_uint64() {
    raise bad(
      reference.at,
      "\{what} names text block \{reference.index}, and the file holds \{meta.texts.length()}",
    )
  }
  let block = meta.texts[reference.index.to_int()]
  if reference.offset > block.1.reinterpret_as_uint64() ||
    reference.width > block.1.reinterpret_as_uint64() - reference.offset {
    raise bad(
      reference.at,
      "\{what} names bytes \{reference.offset} to \{reference.offset + reference.width} of a text block of \{block.1} bytes",
    )
  }
  (
    block.0 + reference.offset.reinterpret_as_int64(),
    reference.width.reinterpret_as_int64(),
  )
}

///|
/// The expansion a compressed row goes through, from the compression the
/// text blocks name: the first block holding a compression's 8-byte name
/// decides. A file whose rows are marked compressed while its text names
/// no compression contradicts itself.
///
/// Raises `Unsupported`, naming the compression, when the name is one
/// this reader does not decode.
fn compression_of(
  bytes : Bytes,
  meta : Meta,
) -> Expansion raise @types.DataError {
  // A block holds at least the name's eight bytes: its size field is
  // checked against its subheader's length, which leaves at least eight.
  for block in meta.texts {
    let mut k = 0L
    while k <= block.1 - 7L {
      if spells(bytes, block.0 + k, COMPRESSION_PREFIX) {
        if spells(bytes, block.0 + k, "SASYZCRL") {
          return rle_decompress
        }
        if spells(bytes, block.0 + k, "SASYZCR2") {
          return rdc_decompress
        }
        let shown = if k + 8L <= block.1 { 8L } else { 7L }
        raise refused(
          block.0 + k,
          "the file names its row compression \{latin1_text(bytes, block.0 + k, shown)}, which this reader does not decode (it decodes SASYZCRL and SASYZCR2)",
        )
      }
      k += 1
    }
  }
  for run in meta.runs {
    if run.compressed {
      raise bad(
        run.at,
        "a row is marked compressed, and the file's text names no row compression",
      )
    }
  }
  rle_decompress
}

///|
/// Resolve the walk's findings into a plan. The row-size subheader gives
/// the row length, the row count and the rows a MIX page holds; the
/// column-count subheader the columns; the text blocks, the name, the
/// attribute and the format subheaders the columns themselves. The runs
/// take their counts and are checked to hold the rows the file declares.
///
/// Raises `ParseError` when a row-size or column-count subheader is
/// missing anywhere, when the row length is zero or longer than a page,
/// when columns are declared without a row length to hold them, when
/// fewer names or attributes than columns are spelled, when a subheader
/// has a length its entries cannot fill, when a reference names a text
/// block or bytes in one that the file does not hold, when a column
/// spans past the row, when a column declares no bytes, when a numeric
/// column declares more than eight, when a row stored as a subheader is
/// not one row long, when a page's rows do not fit in it, and when the
/// pages hold fewer rows than the file declares. Raises `Unsupported`
/// for a column type that is neither numeric nor character, and for a
/// row compression this reader does not decode.
fn resolve(
  bytes : Bytes,
  header : Header,
  meta : Meta,
) -> Plan raise @types.DataError {
  let word = header.word()
  if meta.row_size_at < 0L {
    raise bad(header.header_length, "the pages hold no row-size subheader")
  }
  if meta.column_count_at < 0L {
    raise bad(header.header_length, "the pages hold no column-count subheader")
  }
  if meta.row_length == 0UL {
    raise bad(meta.row_size_at + 5L * word, "the row length is 0")
  }
  if meta.row_length > header.page_length.reinterpret_as_uint64() {
    raise bad(
      meta.row_size_at + 5L * word,
      "the row length \{meta.row_length} exceeds the page length \{header.page_length}",
    )
  }
  let row_length = meta.row_length.reinterpret_as_int64()
  if meta.column_count == 0UL {
    raise bad(
      meta.column_count_at + word,
      "the file declares no column, but rows of \{row_length} bytes",
    )
  }
  let names : Array[TextRef] = []
  for sub in meta.names {
    collect_names(bytes, header, sub, names)
  }
  let attributes : Array[AttrRef] = []
  for sub in meta.attributes {
    collect_attributes(bytes, header, sub, attributes)
  }
  let formats : Array[TextRef] = []
  for sub in meta.formats {
    collect_formats(bytes, header, sub, formats)
  }
  let columns = meta.column_count
  if names.length().to_int64().reinterpret_as_uint64() < columns {
    raise bad(
      meta.column_count_at + word,
      "the file declares \{columns} columns but names \{names.length()}",
    )
  }
  if attributes.length().to_int64().reinterpret_as_uint64() < columns {
    raise bad(
      meta.column_count_at + word,
      "the file declares \{columns} columns but describes \{attributes.length()}",
    )
  }
  let resolved : Array[Column] = []
  for i in 0..<columns.to_int() {
    let entry = attributes[i]
    let ordinal = (i + 1).to_int64()
    if entry.offset > meta.row_length ||
      entry.width > meta.row_length - entry.offset {
      raise bad(
        entry.at,
        "column \{ordinal} spans bytes \{entry.offset} to \{entry.offset + entry.width} of a \{row_length}-byte row",
      )
    }
    let numeric = if entry.kind == NUMERIC {
      true
    } else if entry.kind == CHARACTER {
      false
    } else {
      raise refused(
        entry.at + word + 6L,
        "column \{ordinal} is of type \{entry.kind}, which is neither numeric (1) nor character (2)",
      )
    }
    if entry.width == 0UL {
      raise bad(entry.at + word, "column \{ordinal} declares no bytes")
    }
    if numeric && entry.width > 8UL {
      raise bad(
        entry.at + word,
        "column \{ordinal} is numeric and declares \{entry.width} bytes, more than the \{NUMBER_BYTES} a number takes",
      )
    }
    let name_span = text_span(meta, names[i], "the name of column \{ordinal}")
    let name = decode_text(bytes, name_span.0, name_span.1, name_span.0, header)
    let format = if i < formats.length() {
      let span = text_span(meta, formats[i], "the format of column \{ordinal}")
      decode_text(bytes, span.0, span.1, span.0, header)
    } else {
      ""
    }
    resolved.push(Column::{
      name,
      offset: entry.offset.reinterpret_as_int64(),
      width: entry.width.reinterpret_as_int64(),
      numeric,
      format,
    })
  }
  let runs : Array[Run] = []
  let mut held : UInt64 = 0UL
  for run in meta.runs {
    if run.compressed {
      runs.push(run)
      held += 1UL
      continue
    }
    if run.raw && run.stored != row_length {
      raise bad(
        run.at,
        "a row stored as a subheader of \{run.stored} bytes, and rows are \{row_length} bytes",
      )
    }
    let count = if run.count < 0L {
      meta.mix_rows
    } else {
      run.count.reinterpret_as_uint64()
    }
    let room = if run.at < run.page_end { run.page_end - run.at } else { 0L }
    if count > (room / row_length).reinterpret_as_uint64() {
      raise bad(
        run.at,
        "\{count} rows of \{row_length} bytes do not fit in the page, which holds \{room} bytes from here",
      )
    }
    run.count = count.reinterpret_as_int64()
    runs.push(run)
    held += count
  }
  if held < meta.row_count {
    raise bad(
      meta.row_size_at + 6L * word,
      "the file declares \{meta.row_count} rows and its pages hold \{held}",
    )
  }
  Plan::{
    columns: resolved,
    runs,
    row_count: meta.row_count.reinterpret_as_int64(),
    row_length,
    expand: compression_of(bytes, meta),
  }
}
