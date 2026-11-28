// The pages: each page's header, its subheader pointers, and the one
// walk over the file that gathers every subheader that describes the
// columns and every place a row lies. The metadata may sit anywhere —
// names on one page, the column attributes on the next, the formats on
// the pages after, a second text block on a page of its own — so the
// walk covers the whole file before anything is resolved.

///|
/// The page-type nibble of a page's type field: bits 8 to 11.
const TYPE_NIBBLE : Int32 = 0x0F00

///|
/// The type bits that mark a page holding neither rows nor subheaders
/// this layout reads: a page carrying any of them is passed over.
const TYPE_SKIPPED : Int32 = 0x9000

///|
/// A page holding subheaders and, when compressed rows are stored as
/// subheaders, rows.
const KIND_META : Int32 = 0x0000

///|
/// A page holding nothing but rows, as many as its block count says.
const KIND_DATA : Int32 = 0x0100

///|
/// A page holding subheaders first and rows behind them.
const KIND_MIX : Int32 = 0x0200

///|
/// A page holding subheaders, appended to the file after it was first
/// written.
const KIND_AMD : Int32 = 0x0400

///|
/// The byte that marks a subheader pointer whose subheader is stored
/// compressed.
const STORED_COMPRESSED : Int32 = 4

///|
/// The byte that marks a subheader pointer whose subheader continues
/// on a page of its own; the part here is not read.
const STORED_TRUNCATED : Int32 = 1

///|
/// The type byte of a subheader pointer that marks a row: the bytes the
/// pointer names are one observation, compressed or not.
const TYPE_ROW : Int32 = 1

///|
/// What a subheader's signature names.
priv enum Signature {
  RowSize
  ColumnSize
  Counts
  ColumnText
  ColumnName
  ColumnAttributes
  ColumnFormat
  ColumnList
  Ignored
  Unknown
}

///|
/// Which subheader a signature names. `signature` is the signature's
/// bytes read least significant byte first into one unsigned integer,
/// whatever the file's byte order — a key over the bytes as they lie in
/// the file: four bytes in a 32-bit file, eight in a 64-bit one. The
/// row-size and column-count signatures stand in either half of the
/// eight, or come followed by `FF FF FB FE`; the others carry their one
/// telling byte last in a little-endian file and first in a big-endian
/// one. A signature whose telling byte is `F8`, `F9` or `FA` is one the
/// layout has no name for; it holds nothing this reader reads.
fn signature_kind(signature : UInt64, wide : Bool) -> Signature {
  if wide {
    match signature {
      0xF7F7F7F700000000UL | 0x00000000F7F7F7F7UL | 0xFEFBFFFFF7F7F7F7UL =>
        Signature::RowSize
      0xF6F6F6F600000000UL | 0x00000000F6F6F6F6UL | 0xFEFBFFFFF6F6F6F6UL =>
        Signature::ColumnSize
      0xFFFFFFFFFFFFFC00UL | 0x00FCFFFFFFFFFFFFUL => Signature::Counts
      0xFFFFFFFFFFFFFFFDUL | 0xFDFFFFFFFFFFFFFFUL => Signature::ColumnText
      0xFFFFFFFFFFFFFFFFUL => Signature::ColumnName
      0xFFFFFFFFFFFFFFFCUL | 0xFCFFFFFFFFFFFFFFUL => Signature::ColumnAttributes
      0xFFFFFFFFFFFFFBFEUL | 0xFEFBFFFFFFFFFFFFUL => Signature::ColumnFormat
      0xFFFFFFFFFFFFFFFEUL | 0xFEFFFFFFFFFFFFFFUL => Signature::ColumnList
      v if v >= 0xFFFFFFFFFFFFFFF8UL && v <= 0xFFFFFFFFFFFFFFFAUL =>
        Signature::Ignored
      v if v >= 0xF8FFFFFFFFFFFFFFUL && v <= 0xFAFFFFFFFFFFFFFFUL =>
        Signature::Ignored
      _ => Signature::Unknown
    }
  } else {
    match signature {
      0xF7F7F7F7UL => Signature::RowSize
      0xF6F6F6F6UL => Signature::ColumnSize
      0xFFFFFC00UL | 0x00FCFFFFUL => Signature::Counts
      0xFFFFFFFDUL | 0xFDFFFFFFUL => Signature::ColumnText
      0xFFFFFFFFUL => Signature::ColumnName
      0xFFFFFFFCUL | 0xFCFFFFFFUL => Signature::ColumnAttributes
      0xFFFFFBFEUL | 0xFEFBFFFFUL => Signature::ColumnFormat
      0xFFFFFFFEUL | 0xFEFFFFFFUL => Signature::ColumnList
      v if v >= 0xFFFFFFF8UL && v <= 0xFFFFFFFAUL => Signature::Ignored
      v if v >= 0xF8FFFFFFUL && v <= 0xFAFFFFFFUL => Signature::Ignored
      _ => Signature::Unknown
    }
  }
}

///|
/// One subheader: where it lies and how long it is.
priv struct Subheader {
  at : Int64
  length : Int64
}

///|
/// One run of rows: a compressed row stored as a subheader (one row, of
/// `stored` bytes), an uncompressed row stored as a subheader (one row,
/// flagged `raw`), or rows lying one behind another from `at` — on a
/// DATA page, or behind the subheader pointers of a MIX page. A MIX
/// page's run counts its rows as -1 until the row-size subheader has
/// said how many that is. `page_end` is where the run's page ends.
priv struct Run {
  at : Int64
  stored : Int64
  mut count : Int64
  compressed : Bool
  raw : Bool
  page_end : Int64
}

///|
/// What the walk finds: the row-size and column-count subheaders' facts,
/// the text blocks, and the subheaders whose references are resolved
/// once every one of them has been seen.
priv struct Meta {
  mut row_size_at : Int64
  mut row_length : UInt64
  mut row_count : UInt64
  mut mix_rows : UInt64
  mut column_count_at : Int64
  mut column_count : UInt64
  texts : Array[(Int64, Int64)]
  names : Array[Subheader]
  attributes : Array[Subheader]
  formats : Array[Subheader]
  runs : Array[Run]
}

///|
/// Walk the pages. Each page's type says what it holds: a DATA page's
/// rows run from behind its header, as many as its block count names; a
/// META, MIX or AMD page carries subheader pointers, each to an offset
/// and length inside the page; the other page types are passed over. A
/// pointer marked compressed names a row whatever its bytes start with.
/// A pointer to a subheader of unknown signature whose type byte marks a
/// row names a row stored uncompressed.
///
/// Raises `ParseError` when the pointers do not fit in their page, when a
/// subheader does not lie behind the pointers and inside the page, when a
/// subheader is shorter than its signature, when a text block's size
/// contradicts its subheader's length, and when a subheader of unknown
/// signature is not a row. Raises `Unsupported` when a pointer's
/// compression byte names a storage this reader does not read.
fn walk(bytes : Bytes, header : Header) -> Meta raise @types.DataError {
  let meta = Meta::{
    row_size_at: -1L,
    row_length: 0UL,
    row_count: 0UL,
    mix_rows: 0UL,
    column_count_at: -1L,
    column_count: 0UL,
    texts: [],
    names: [],
    attributes: [],
    formats: [],
    runs: [],
  }
  let lead = header.lead()
  let word = header.word()
  let pointer_length = header.pointer()
  let little = header.little
  let page_length = header.page_length
  let page_span = page_length.reinterpret_as_uint64()
  for page_index in 0..<header.pages.to_int() {
    let page_at = header.header_length + page_index.to_int64() * page_length
    let page_end = page_at + page_length
    let raw = uint_at(bytes, page_at + lead, 2L, little).to_int()
    let blocks = uint_at(bytes, page_at + lead + 2L, 2L, little)
    let count = uint_at(bytes, page_at + lead + 4L, 2L, little)
    let kind = raw & TYPE_NIBBLE
    if (raw & TYPE_SKIPPED) != 0 {
      continue
    }
    if kind == KIND_DATA {
      meta.runs.push(Run::{
        at: page_at + lead + 8L,
        stored: 0L,
        count: blocks.reinterpret_as_int64(),
        compressed: false,
        raw: false,
        page_end,
      })
      continue
    }
    if kind != KIND_META && kind != KIND_MIX && kind != KIND_AMD {
      continue
    }
    let pointers_at = page_at + lead + 8L
    let array_length = count.reinterpret_as_int64() * pointer_length
    if array_length > page_length - lead - 8L {
      raise bad(
        page_at + lead + 4L,
        "\{count} subheader pointers of \{pointer_length} bytes do not fit in a \{page_length}-byte page",
      )
    }
    let first_free = lead + 8L + array_length
    for i in 0..<count.to_int() {
      let p = pointers_at + i.to_int64() * pointer_length
      let offset = uint_at(bytes, p, word, little)
      let length = uint_at(bytes, p + word, word, little)
      let compression = byte_at(bytes, p + 2L * word)
      let flagged = byte_at(bytes, p + 2L * word + 1L)
      if length == 0UL || compression == STORED_TRUNCATED {
        continue
      }
      if offset > page_span || length > page_span - offset {
        raise bad(
          p,
          "a subheader at byte \{offset} of \{length} bytes does not fit in a \{page_length}-byte page",
        )
      }
      if offset < first_free.reinterpret_as_uint64() {
        raise bad(
          p,
          "a subheader at byte \{offset} lies inside the page's \{count} subheader pointers",
        )
      }
      let sub_at = page_at + offset.reinterpret_as_int64()
      let sub_length = length.reinterpret_as_int64()
      if compression == STORED_COMPRESSED {
        meta.runs.push(Run::{
          at: sub_at,
          stored: sub_length,
          count: 1L,
          compressed: true,
          raw: false,
          page_end,
        })
      } else if compression != 0 {
        raise refused(
          p + 2L * word,
          "a subheader's compression byte is \{compression}, which names a storage this reader does not read",
        )
      } else {
        read_subheader(
          bytes, header, meta, sub_at, sub_length, p, flagged, page_end,
        )
      }
    }
    if kind == KIND_MIX {
      // The rows start behind the pointers, on a multiple of eight bytes.
      let start = first_free + first_free % 8L
      meta.runs.push(Run::{
        at: page_at + start,
        stored: 0L,
        count: -1L,
        compressed: false,
        raw: false,
        page_end,
      })
    }
  }
  meta
}

///|
/// Read one uncompressed subheader that the pointer at `p` names, of
/// `length` bytes at `at`: the row-size and column-count facts, a text
/// block, or a subheader whose references are collected for after the
/// walk. A row-size or column-count subheader seen a second time must
/// say what the first said.
fn read_subheader(
  bytes : Bytes,
  header : Header,
  meta : Meta,
  at : Int64,
  length : Int64,
  p : Int64,
  flagged : Int32,
  page_end : Int64,
) -> Unit raise @types.DataError {
  let word = header.word()
  let little = header.little
  if length < word {
    raise bad(p, "a subheader of \{length} bytes is shorter than its signature")
  }
  let sub = Subheader::{ at, length, }
  match signature_kind(uint_at(bytes, at, word, true), header.wide) {
    Signature::RowSize => {
      if length < 16L * word {
        raise bad(p, "a row-size subheader of \{length} bytes")
      }
      let row_length = uint_at(bytes, at + 5L * word, word, little)
      let row_count = uint_at(bytes, at + 6L * word, word, little)
      let mix_rows = uint_at(bytes, at + 15L * word, word, little)
      if meta.row_size_at >= 0L {
        if row_length != meta.row_length ||
          row_count != meta.row_count ||
          mix_rows != meta.mix_rows {
          raise bad(
            at, "a second row-size subheader says something other than the first",
          )
        }
      } else {
        meta.row_size_at = at
        meta.row_length = row_length
        meta.row_count = row_count
        meta.mix_rows = mix_rows
      }
    }
    Signature::ColumnSize => {
      if length < 2L * word {
        raise bad(p, "a column-count subheader of \{length} bytes")
      }
      let columns = uint_at(bytes, at + word, word, little)
      if meta.column_count_at >= 0L {
        if columns != meta.column_count {
          raise bad(
            at, "a second column-count subheader says something other than the first",
          )
        }
      } else {
        meta.column_count_at = at
        meta.column_count = columns
      }
    }
    Signature::ColumnText => {
      let size = uint_at(bytes, at + word, 2L, little)
      if length < 2L * word + 4L ||
        size != (length - 2L * word - 4L).reinterpret_as_uint64() {
        raise bad(
          at + word,
          "a text block of \{size} bytes in a subheader of \{length} bytes",
        )
      }
      // The block runs from its size field to the subheader's end: files
      // written by the format's own producer park format names past the
      // size the field names, and the references reach them there.
      meta.texts.push((at + word, length - word))
    }
    Signature::ColumnName => meta.names.push(sub)
    Signature::ColumnAttributes => meta.attributes.push(sub)
    Signature::ColumnFormat => meta.formats.push(sub)
    Signature::Counts | Signature::ColumnList | Signature::Ignored => ()
    Signature::Unknown =>
      if flagged == TYPE_ROW {
        meta.runs.push(Run::{
          at,
          stored: length,
          count: 1L,
          compressed: false,
          raw: true,
          page_end,
        })
      } else {
        raise bad(
          at,
          "the signature \{hex_at(bytes, at)} is not a subheader's, and the pointer does not mark a row",
        )
      }
  }
}

///|
/// The four bytes at `at`, as they lie in the file, as hex digits.
fn hex_at(bytes : Bytes, at : Int64) -> String raise @types.DataError {
  let digits = "0123456789abcdef".code_units()
  let out = StringBuilder()
  for i in 0..<4 {
    let value = byte_at(bytes, at + i.to_int64())
    out.write_char(digits[value >> 4].to_int().to_byte().to_char())
    out.write_char(digits[value & 15].to_int().to_byte().to_char())
  }
  out.to_string()
}
