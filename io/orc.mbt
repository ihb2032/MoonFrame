// The ORC file interchange — a native reader over the codec in `internal/orc`
// (the file tail with its PostScript and Footer and the type tree, each
// stripe's footer and streams, the compression blocks, and the run length
// encodings of both format versions). The format is read only: nothing is
// written.

///|
/// Read an ORC file into a frame — the file's top-level fields as the
/// columns, in the file's order. `projection` keeps only the fields it names.
/// Raises the errors `parse_orc` states; a path that cannot be read raises
/// `IoError`.
pub fn read_orc(
  path : String,
  projection? : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  parse_orc(bytes, projection?)
}

///|
/// Parse an ORC file's bytes into a frame — the string-level entry's binary
/// counterpart (what `read_orc` hands the codec, exposed for in-memory
/// bytes). The file's top-level struct is the table: its fields are the
/// columns, in the file's order, each named as the file spells it.
///
/// `projection` keeps only the top-level fields it names, in the file's
/// order: a name the file does not carry builds no column, and the rows
/// stay. A field the projection leaves out is never decoded, so a refusal
/// confined to it does not surface — a file carrying a BINARY column reads
/// under a projection that does not name it.
///
/// The columns a file's fields read as:
///
/// - BOOLEAN → `Bool`; BYTE, SHORT, INT and LONG → `Int`; FLOAT and DOUBLE →
///   `Float` (a 32-bit float widened to exactly what it holds); STRING,
///   VARCHAR and CHAR → `String`, the bytes as stored; DATE → `Date`, days
///   since 1970-01-01.
/// - TIMESTAMP and TIMESTAMP_INSTANT → `Timestamp`, microseconds since
///   1970-01-01 — the wall clock the writer stored, taken for UTC: the
///   writer's time zone is not applied.
/// - DECIMAL → `Decimal`, its unscaled integer at its scale.
/// - LIST → `List` of what its elements read as; STRUCT → `Struct` of its
///   fields. A null at any level is null.
/// - Two top-level fields of one name come back as spelled, both of them;
///   the frame's own refusal of a repeated name is the frame's.
///
/// A file reads under each compression kind but LZO — NONE, ZLIB, SNAPPY,
/// LZ4 and ZSTD — in the format versions 0.11 and 0.12, in the first
/// writers' files that name no version, and in UNSTABLE-PRE-2.0. Row
/// indexes, statistics and bloom filters are stepped over. A file of no
/// field, or a projection naming none, reads as a frame of no column with
/// the file's row count.
///
/// Raises `Unsupported`, naming what it is, for a compression kind, a
/// format version or a column encoding this reader does not read; for
/// encrypted columns; for a top-level type that is not a struct; for a
/// BINARY, MAP or UNION column and for a struct whose two fields share a
/// name, each by the column's way from its top-level field; for a timestamp
/// with a nanosecond remainder or past what a 64-bit microsecond count
/// holds; and for a decimal the library's cannot hold exactly. Raises
/// `ParseError` (`Message`), naming the byte, for bytes that contradict the
/// layout: a file that spells the magic neither at its end nor at its head,
/// a PostScript, Footer or stripe footer the file cuts short, a count,
/// length or offset outside the file or its stripe, a stripe declaring more
/// rows than its streams can spell, a block that does not decompress, and a
/// stream that ends inside a value.
pub fn parse_orc(
  bytes : Bytes,
  projection? : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let (columns, nrows) = match projection {
    Some(names) => @orc.read_orc_frame(bytes, projection=names)
    None => @orc.read_orc_frame(bytes)
  }
  // A lenient projection that matches no column still reports the file's
  // rows — the `N×0` shape the text readers' projections yield, not a
  // collapse to zero.
  if columns.length() == 0 {
    @frame.DataFrame::from_parts([], nrows)
  } else {
    @frame.DataFrame::DataFrame(columns.map(pair => pair.1))
  }
}
