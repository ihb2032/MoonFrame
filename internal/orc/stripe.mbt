// One stripe opened for reading. Its footer lists every stream with its
// kind, its column and its length on disk, and the streams lie end to end
// from the stripe's first byte in the order of that list; the footer also
// names each column's encoding. Row indexes, bloom filters and statistics
// are in the list too and are passed over: a stream is opened when a
// column asks for its own.

///|
/// The stream kinds a column's values ride, as the format numbers them:
/// whether a value is present (0), the data itself (1), the length of a
/// string or a list (2), a string dictionary's bytes (3), and a
/// timestamp's nanoseconds or a decimal's scale (5). Every other kind —
/// row indexes, bloom filters, statistics — is passed over.
#derive(Eq)
priv enum StreamKind {
  Present
  Data
  Length
  Dictionary
  Secondary
}

///|
/// The name of a stream kind as the format spells it.
fn StreamKind::name(self : StreamKind) -> String {
  match self {
    Present => "PRESENT"
    Data => "DATA"
    Length => "LENGTH"
    Dictionary => "DICTIONARY_DATA"
    Secondary => "SECONDARY"
  }
}

///|
/// The stream kind a stream's number names, or `None` for one this reader
/// never opens.
fn stream_kind(raw : Int32) -> StreamKind? {
  match raw {
    0 => Some(Present)
    1 => Some(Data)
    2 => Some(Length)
    3 => Some(Dictionary)
    5 => Some(Secondary)
    _ => None
  }
}

///|
/// A stream of a stripe, located: its kind, its column, how many bytes it
/// takes on disk — compression block headers included — and where its
/// first byte lies.
priv struct StreamAt {
  kind : StreamKind
  column : Int32
  length : Int32
  at : Int32
}

///|
/// A column's encoding in a stripe: its kind and, for a dictionary, how
/// many entries the dictionary holds.
priv struct Encoding {
  kind : Int32
  dictionary_size : Int64
}

///|
/// One stripe opened for reading: the layout it belongs to, its index and
/// first byte for the refusals, its streams and encodings, and the cells
/// its streams may still spell.
priv struct Stripe {
  layout : Layout
  index : Int32
  at : Int32
  rows : Int32
  streams : Array[StreamAt]
  encodings : Array[Encoding]
  mut budget : Int64
}

///|
/// A stripe's streams spell at most this many cells a byte: a present
/// stream or a boolean column's data packs eight values to a byte, and
/// its byte run length encoding repeats up to 130 bytes from a two-byte
/// header — 1,040 values over two bytes. A stripe that declares more
/// rows, or more list items, than its streams can spell is refused before
/// a cell is built for them.
const DENSEST : Int64 = 520L

///|
/// The stripe `index` of the file, its footer read and every stream
/// located. Raises `ParseError`, naming the byte, for a footer the file
/// cuts short, for a stream that runs past the stripe and for a stripe
/// whose rows its streams cannot spell; `Unsupported` for a stripe that
/// carries the streams or the variants of encrypted columns.
fn open_stripe(layout : Layout, index : Int32) -> Stripe raise @types.DataError {
  let info = layout.stripes[index]
  let what = "stripe \{index}'s footer"
  let footer_at = info.offset + info.index_length + info.data_length
  let fields = message(
    layout.src.range(footer_at.to_int(), info.footer_length.to_int(), what),
    footer_at.to_int(),
    what,
  )
  if blob_field(fields, 4, what) is Some(_) {
    let error = refuse(
      "stripe \{index}'s footer carries encrypted columns, which this reader does not read",
    )
    raise error
  }
  let streams : Array[StreamAt] = []
  let body_end = layout.body_end.to_int64()
  let mut cursor = info.offset
  for j, field in blobs(fields, 1, what) {
    let f = message(field.bytes, field.at, what)
    let raw_kind = match int_field(f, 1, what) {
      Some(u) => count32(u, field.at, what, "stream kind")
      None => -1
    }
    let column = match int_field(f, 2, what) {
      Some(u) => count32(u, field.at, what, "stream column")
      None => 0
    }
    let length = match int_field(f, 3, what) {
      Some(u) => count64(u, field.at, what, "stream length")
      None => 0L
    }
    if raw_kind == 9 || raw_kind == 10 {
      let named = if raw_kind == 9 {
        "an ENCRYPTED_INDEX"
      } else {
        "an ENCRYPTED_DATA"
      }
      let error = refuse(
        "stripe \{index} carries \{named} stream: the spelling of encrypted columns, which this reader does not read",
      )
      raise error
    }
    if length > body_end - cursor {
      let error = bad(
        layout.footer_at,
        "stripe \{index}: stream \{j} of column \{column} runs past the stripe's end at byte \{layout.body_end}",
      )
      raise error
    }
    match stream_kind(raw_kind) {
      Some(kind) =>
        streams.push({
          kind,
          column,
          length: length.to_int(),
          at: cursor.to_int(),
        })
      None => ()
    }
    cursor = cursor + length
  }
  let encodings : Array[Encoding] = []
  for field in blobs(fields, 2, what) {
    let f = message(field.bytes, field.at, what)
    let kind = match int_field(f, 1, what) {
      Some(u) => count32(u, field.at, what, "encoding kind")
      None => 0
    }
    let dictionary_size = match int_field(f, 2, what) {
      Some(u) => count64(u, field.at, what, "dictionary size")
      None => 0L
    }
    encodings.push({ kind, dictionary_size, })
  }
  if encodings.length() != layout.types.length() {
    let error = bad(
      layout.footer_at,
      "\{what} names \{encodings.length()} encodings for \{layout.types.length()} types",
    )
    raise error
  }
  let bytes = info.index_length + info.data_length
  let budget = DENSEST * bytes - info.rows
  if budget < 0L {
    let error = bad(
      layout.footer_at,
      "stripe \{index} declares \{info.rows} rows over \{bytes} bytes of streams, more than the densest encoding spells",
    )
    raise error
  }
  {
    layout,
    index,
    at: info.offset.to_int(),
    rows: info.rows.to_int(),
    streams,
    encodings,
    budget,
  }
}

///|
/// The stream of `kind` that column `column` rides, if its footer lists
/// one: `None` otherwise, whatever the column needs.
fn Stripe::find(self : Stripe, kind : StreamKind, column : Int32) -> StreamAt? {
  for stream in self.streams {
    if stream.kind == kind && stream.column == column {
      return Some(stream)
    }
  }
  None
}

///|
/// A located stream, inflated whole. Its refusals name the byte: the
/// file's own when the stream lies in it as it is, else the stream's byte
/// among the bytes it inflated to, said to be so.
fn Stripe::open(
  self : Stripe,
  stream : StreamAt,
) -> Cursor raise @types.DataError {
  let what = "stripe \{self.index}'s \{stream.kind.name()} stream of column \{stream.column}, which starts at byte \{stream.at}"
  let bytes = self.layout.src.range(stream.at, stream.length, what)
  match self.layout.src.compression {
    None => cursor(bytes, stream.at, what)
    _ => cursor(bytes, 0, what, inflated=true)
  }
}

///|
/// The stream of `kind` that column `column` rides, inflated. A column
/// with values to read and no stream for them raises: a footer that lists
/// no stream for a column that needs one does not hold together.
fn Stripe::required(
  self : Stripe,
  kind : StreamKind,
  column : Int32,
  needed : Int32,
) -> Cursor raise @types.DataError {
  self.required_for(kind, column, needed, "present value")
}

///|
/// As `required`, naming what the stream spells — a noun for one and
/// for many: a column's present values, or the entries of its dictionary.
fn Stripe::required_for(
  self : Stripe,
  kind : StreamKind,
  column : Int32,
  needed : Int32,
  one : String,
  many~ : String = "",
) -> Cursor raise @types.DataError {
  match self.find(kind, column) {
    Some(stream) => self.open(stream)
    None => {
      let count = counted(needed.to_int64(), one, many~)
      let error = bad(
        self.at,
        "stripe \{self.index} lists no \{kind.name()} stream for the \{count} of column \{column}",
      )
      raise error
    }
  }
}

///|
/// The encoding of column `column`, at `path` from its top-level field:
/// its kind, the integer run length encoding the kind names, and for a
/// dictionary its number of entries. A kind the format does not name is
/// refused by name.
fn Stripe::encoding(
  self : Stripe,
  column : Int32,
  path : String,
) -> (Int32, Rle, Int64) raise @types.DataError {
  let encoding = self.encodings[column]
  let rle = match encoding.kind {
    0 | 1 => V1
    2 | 3 => V2
    kind =>
      raise refuse(
        "column \"\{path}\" carries encoding \{kind}, which this reader does not read",
      )
  }
  (encoding.kind, rle, encoding.dictionary_size)
}
