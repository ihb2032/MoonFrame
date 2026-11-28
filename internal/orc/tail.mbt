// The file tail: the PostScript, the directory of the tail; the Footer
// with its type tree and its stripes' information; and the checks that
// hold them to the file. All of it is read before any stripe or cell, so
// a count the file cannot hold refuses before an allocation names it.

///|
/// The PostScript, the tail's directory: what the file is compressed
/// with, how much a block inflates to, where the Footer and the metadata
/// start, the format's version, and whether the decimals of a low
/// precision are spelled as integers.
priv struct PostScript {
  src : Source
  footer_at : Int32
  footer_len : Int32
  metadata_at : Int32
  version : Array[UInt64]
  decimal_as_long : Bool
}

///|
/// The PostScript of the file in `bytes`, read from its last byte, which
/// names the PostScript's length. The PostScript ends with the magic in
/// every file but the format's first, which carry it at the head only:
/// a file with neither is not an ORC file. Raises `ParseError`, naming
/// the byte, for a length byte or a field the file cuts short and for a
/// tail the file cannot hold; `Unsupported` for a compression kind this
/// reader does not inflate.
fn read_postscript(bytes : Bytes) -> PostScript raise @types.DataError {
  let n = bytes.length()
  if n < 4 {
    raise bad(0, "a file of \{n} bytes, too short for a PostScript")
  }
  let ps_len = bytes[n - 1].to_int()
  if ps_len < 3 {
    raise bad(n - 1, "the PostScript length byte names \{ps_len} bytes")
  }
  let at = n - 1 - ps_len
  let ends_in_magic = bytes[n - 4] == b'O' &&
    bytes[n - 3] == b'R' &&
    bytes[n - 2] == b'C'
  let opens_with_magic = bytes[0] == b'O' &&
    bytes[1] == b'R' &&
    bytes[2] == b'C'
  if !(ends_in_magic || opens_with_magic) {
    let error = bad(
      0, "not an ORC file: neither the end of the PostScript nor the head spells the magic",
    )
    raise error
  }
  // The PostScript lies after the file's three bytes of magic: a length
  // that would start it before them names bytes the file cannot hold.
  if at < 3 {
    let error = bad(
      n - 1,
      "the PostScript length byte names \{ps_len} bytes, past the head of the file",
    )
    raise error
  }
  let what = "the PostScript"
  let ps = message(bytes.exact_view(start=at, end=n - 1).to_owned(), at, what)
  let footer_len = match int_field(ps, 1, what) {
    Some(u) => count64(u, at, what, "footer length")
    None => 0L
  }
  let kind = match int_field(ps, 2, what) {
    Some(u) => u
    None => raise bad(at, "\{what} names no compression kind")
  }
  if kind == 3UL {
    raise refuse("the LZO compression kind, which this reader does not decode")
  }
  if kind > 5UL {
    raise refuse("compression kind \{kind}, which this reader does not decode")
  }
  let compression = match kind.to_int() {
    0 => None
    1 => Zlib
    2 => Snappy
    4 => Lz4
    _ => Zstd
  }
  // A PostScript that names no block size is read under the first
  // writers' default.
  let block_size = match int_field(ps, 3, what) {
    Some(u) => count64(u, at, what, "compression block size")
    None => 262144L
  }
  // The format's version, two numbers. A decimal of precision up to 18 is
  // an integer run length stream instead of unbounded varints under
  // UNSTABLE-PRE-2.0, [1, 9999]. Which versions this reader reads is
  // decided with the Footer, where the other refusals of a file's shape
  // are.
  let version = packed_ints(ps, 4, what)
  let decimal_as_long = version == [1UL, 9999UL]
  let metadata_len = match int_field(ps, 5, what) {
    Some(u) => count64(u, at, what, "metadata length")
    None => 0L
  }
  let tail = 1L + ps_len.to_int64() + footer_len
  if tail >= n.to_int64() {
    let error = bad(
      at,
      "\{what}: with a footer of \{footer_len} bytes a tail of \{tail} bytes, in a file of \{n}",
    )
    raise error
  }
  let footer_at = n - 1 - ps_len - footer_len.to_int()
  if metadata_len > footer_at.to_int64() - 3L {
    let error = bad(
      at,
      "\{what}: a metadata length of \{metadata_len} bytes, past the head of the file",
    )
    raise error
  }
  let src = source(bytes, compression, block_size)
  {
    src,
    footer_at,
    footer_len: footer_len.to_int(),
    metadata_at: footer_at - metadata_len.to_int(),
    version,
    decimal_as_long,
  }
}

///|
/// One node of the Footer's type tree, in its pre-order numbering: its
/// kind, the type ids of its children, the names of a struct's fields,
/// and the length, precision and scale of the varchar, char and decimal.
priv struct TypeNode {
  kind : Int32
  subtypes : Array[Int32]
  names : Array[String]
  precision : Int64
  scale : Int64
}

///|
/// The name of a type kind as the format spells them, by number.
fn kind_names() -> ReadOnlyArray[String] {
  [
    "BOOLEAN", "BYTE", "SHORT", "INT", "LONG", "FLOAT", "DOUBLE", "STRING", "BINARY",
    "TIMESTAMP", "LIST", "MAP", "STRUCT", "UNION", "DECIMAL", "DATE", "VARCHAR",
    "CHAR", "TIMESTAMP_INSTANT",
  ]
}

///|
/// The name of a type kind as the format spells it; a kind the format
/// does not name, by its number.
fn kind_name(kind : Int32) -> String {
  let names = kind_names()
  if kind >= 0 && kind < names.length().to_int() {
    names[kind]
  } else {
    "type kind \{kind}"
  }
}

///|
/// Type `index` of the tree, from its message in the Footer.
fn type_node(field : Field, index : Int32) -> TypeNode raise @types.DataError {
  let what = "the Footer's type \{index}"
  let f = message(field.bytes, field.at, what)
  let kind = match int_field(f, 1, what) {
    Some(u) => count32(u, field.at, what, "kind")
    None => 0
  }
  let subtypes : Array[Int32] = []
  for u in packed_ints(f, 2, what) {
    subtypes.push(count32(u, field.at, what, "subtype"))
  }
  let names : Array[String] = []
  for name in blobs(f, 3, what) {
    let text = @utf8.decode(name.bytes) catch {
      _ => raise bad(name.at, "\{what}: a field name not well-formed as UTF-8")
    }
    names.push(text)
  }
  let precision = match int_field(f, 5, what) {
    Some(u) => count64(u, field.at, what, "precision")
    None => 0L
  }
  let scale = match int_field(f, 6, what) {
    Some(u) => count64(u, field.at, what, "scale")
    None => 0L
  }
  { kind, subtypes, names, precision, scale, }
}

///|
/// One stripe as the Footer describes it: where it starts, how long its
/// index, its data and its footer are, and how many rows it holds.
priv struct StripeInfo {
  offset : Int64
  index_length : Int64
  data_length : Int64
  footer_length : Int64
  rows : Int64
}

///|
/// A stripe's information, from its message in the Footer.
fn stripe_info(
  field : Field,
  index : Int32,
) -> StripeInfo raise @types.DataError {
  let what = "the Footer's stripe \{index}"
  let f = message(field.bytes, field.at, what)
  let offset = match int_field(f, 1, what) {
    Some(u) => count64(u, field.at, what, "offset")
    None => 0L
  }
  let index_length = match int_field(f, 2, what) {
    Some(u) => count64(u, field.at, what, "index length")
    None => 0L
  }
  let data_length = match int_field(f, 3, what) {
    Some(u) => count64(u, field.at, what, "data length")
    None => 0L
  }
  let footer_length = match int_field(f, 4, what) {
    Some(u) => count64(u, field.at, what, "footer length")
    None => 0L
  }
  let rows = match int_field(f, 5, what) {
    Some(u) => count64(u, field.at, what, "row count")
    None => 0L
  }
  { offset, index_length, data_length, footer_length, rows, }
}

///|
/// The whole file's layout, once the tail is read: where every part lies,
/// the type tree, the stripes, and the row count.
priv struct Layout {
  src : Source
  footer_at : Int32
  body_end : Int32
  types : Array[TypeNode]
  stripes : Array[StripeInfo]
  rows : Int32
  decimal_as_long : Bool
}

///|
/// The type tree, link by link: a struct names as many field names as
/// subtypes, a list one subtype and a map two, a leaf none, and every
/// link goes down the tree to a type the Footer carries, the subtypes of
/// one node in rising order. A tree that does not hold together cannot
/// be walked.
fn check_tree(
  types : Array[TypeNode],
  at : Int32,
) -> Unit raise @types.DataError {
  let count = types.length()
  for i, t in types {
    let what = "the Footer's type \{i}"
    let n = t.subtypes.length()
    match t.kind {
      12 =>
        if n != t.names.length() {
          let error = bad(
            at,
            "\{what} is a STRUCT of \{counted(n.to_int64(), "subtype")} and \{counted(t.names.length().to_int64(), "field name")}",
          )
          raise error
        }
      10 =>
        if n != 1 {
          raise bad(
            at,
            "\{what} is a LIST of \{counted(n.to_int64(), "subtype")}",
          )
        }
      11 =>
        if n != 2 {
          raise bad(
            at,
            "\{what} is a MAP of \{counted(n.to_int64(), "subtype")}",
          )
        }
      13 => ()
      _ =>
        if n != 0 {
          let name = kind_name(t.kind)
          let error = bad(
            at,
            "\{what} names \{counted(n.to_int64(), "subtype")}, and \{a(name)} \{name} has none",
          )
          raise error
        }
    }
    for j, s in t.subtypes {
      if s <= i {
        raise bad(at, "\{what} names subtype \{s}, at or before itself")
      }
      if s >= count {
        let error = bad(
          at,
          "\{what} names subtype \{s}, which the Footer does not carry",
        )
        raise error
      }
      if j > 0 && t.subtypes[j - 1] >= s {
        raise bad(at, "\{what}'s subtypes do not rise")
      }
    }
  }
}

///|
/// The formats this reader reads: 0.11 and 0.12, the released versions,
/// the first writers' files, which name no version, and UNSTABLE-PRE-2.0,
/// [1, 9999], whose decimals of a low precision are an integer stream.
/// A file of another version is refused by name, whatever its bytes look
/// like: the format may have changed under it, and a reader that took it
/// for 0.12 would be guessing.
fn check_version(version : Array[UInt64]) -> Unit raise @types.DataError {
  match version {
    [] | [0UL, 11UL] | [0UL, 12UL] | [1UL, 9999UL] => ()
    [major, minor] => {
      let error = refuse(
        "a file of format version \{major}.\{minor}, which this reader does not read",
      )
      raise error
    }
    _ => {
      let error = refuse(
        "a file whose PostScript names \{version.length()} version numbers, which this reader does not read",
      )
      raise error
    }
  }
}

///|
/// The layout of the file in `bytes`: its PostScript, its Footer, the
/// type tree checked link by link, and every stripe checked against the
/// body of the file. Raises `ParseError`, naming the byte, for a Footer
/// the file cuts short or decodes into no type or into a tree whose links
/// do not hold, for a stripe outside the body, and for a row count its
/// stripes do not add up to or a frame cannot hold; `Unsupported` for a
/// file of a format version this reader does not read, with encrypted
/// columns, or with a top-level type that is not a struct.
fn read_layout(bytes : Bytes) -> Layout raise @types.DataError {
  let ps = read_postscript(bytes)
  check_version(ps.version)
  let what = "the Footer"
  let at = ps.footer_at
  let footer = message(ps.src.range(at, ps.footer_len, what), at, what)
  if blob_field(footer, 10, what) is Some(_) {
    raise refuse(
      "the Footer carries encrypted columns, which this reader does not read",
    )
  }
  let type_fields = blobs(footer, 4, what)
  if type_fields.is_empty() {
    raise bad(at, "\{what} carries no type")
  }
  let types : Array[TypeNode] = []
  for i, field in type_fields {
    types.push(type_node(field, i))
  }
  if types[0].kind != 12 {
    let error = refuse(
      "the top-level type is \{kind_name(types[0].kind)}, where the columns are a STRUCT's fields",
    )
    raise error
  }
  check_tree(types, at)
  let stripes : Array[StripeInfo] = []
  for i, field in blobs(footer, 3, what) {
    stripes.push(stripe_info(field, i))
  }
  // The stripes lie end to end between the magic and the metadata. Each
  // bound is a subtraction, so a length near the top of the range cannot
  // wrap the sum back inside.
  let body_end = ps.metadata_at.to_int64()
  let mut summed = 0L
  for k, s in stripes {
    if s.offset < 3L {
      let error = bad(
        at,
        "stripe \{k} starts at byte \{s.offset}, inside the magic",
      )
      raise error
    }
    let outside = bad(
      at,
      "stripe \{k} runs past the body's end at byte \{ps.metadata_at}",
    )
    let cursor = s.offset
    if s.index_length > body_end - cursor {
      raise outside
    }
    let after_index = cursor + s.index_length
    if s.data_length > body_end - after_index {
      raise outside
    }
    let after_data = after_index + s.data_length
    if s.footer_length > body_end - after_data {
      raise outside
    }
    if s.rows > 2147483647L {
      let error = bad(
        at,
        "stripe \{k} declares \{s.rows} rows, past a frame's own height",
      )
      raise error
    }
    summed = summed + s.rows
  }
  let rows = match int_field(footer, 6, what) {
    Some(u) => count64(u, at, what, "row count")
    None => 0L
  }
  if summed != rows {
    raise bad(at, "\{what} declares \{rows} rows and its stripes \{summed}")
  }
  if rows > 2147483647L {
    let error = bad(
      at,
      "\{what} declares \{rows} rows, past a frame's own height",
    )
    raise error
  }
  {
    src: ps.src,
    footer_at: at,
    body_end: ps.metadata_at,
    types,
    stripes,
    rows: rows.to_int(),
    decimal_as_long: ps.decimal_as_long,
  }
}
