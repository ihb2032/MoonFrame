// The ORC file reader's entry: the tail read once, each stripe opened in
// turn, and the columns a projection keeps decoded stripe by stripe into
// one series each.

///|
/// Read an ORC file from `bytes` and answer its columns in file order —
/// each named as the file's top-level struct spells its field — and the
/// file's row count.
///
/// `projection` keeps only the top-level fields it names, in the file's
/// order: a name the file does not carry builds no column, and a field it
/// leaves out is never decoded. With no projection every field is read.
/// The row count is the file's own, whatever the projection keeps.
///
/// Each field reads as:
///
/// - BOOLEAN: `Bool`; BYTE, SHORT, INT and LONG: `Int`; FLOAT and DOUBLE:
///   `Float`, a 32-bit one widened to what it holds exactly; STRING,
///   VARCHAR and CHAR: `String`, the bytes as stored; DATE: `Date`, days
///   since 1970-01-01;
/// - TIMESTAMP and TIMESTAMP_INSTANT: `Timestamp`, microseconds since
///   1970-01-01, as the wall clock the writer stored taken for UTC: the
///   writer's time zone is not applied;
/// - DECIMAL: `Decimal`, its unscaled integer at its scale, when the 34
///   significant digits of the library's decimal hold it exactly;
/// - LIST: `List` of what its elements read as; STRUCT: `Struct` of its
///   fields. A null at any level is null.
///
/// Two fields of one name come back as spelled, both of them: the
/// columns are the file's; a frame's own refusal of a repeated name is
/// the frame's.
///
/// Raises `Unsupported`, naming what it is, for a compression kind this
/// reader does not decode, for a BINARY, MAP or UNION column or a struct
/// whose two fields share a name, for a timestamp with a nanosecond
/// remainder or past the ends of a microsecond count, for a decimal the
/// library cannot hold exactly, for an encoding the format does not
/// name, for encrypted columns and for a top-level type that is not a
/// struct. Raises `ParseError`, naming the byte, for bytes that
/// contradict the layout: a file that is not an ORC file, a PostScript,
/// Footer or stripe footer cut short, a count, length or offset outside
/// the file or its stripe, a block that does not decompress, and a stream
/// that ends inside a value.
pub fn read_orc_frame(
  bytes : Bytes,
  projection? : Array[String],
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  // The caller's array is copied at the boundary: the reader keeps the
  // names itself, so a later mutation of theirs cannot change which
  // columns are read.
  let wanted : Array[String]? = match projection {
    Some(names) => Some(names.copy())
    None => None
  }
  let layout = read_layout(bytes)
  let root = layout.types[0]
  // The columns kept, each mapped to its dtype before any stripe opens,
  // so a type this reader does not carry refuses the whole read first.
  let kept : Array[(Int32, String, @types.DataType, Array[@types.Scalar])] = []
  for i, id in root.subtypes {
    let name = root.names[i]
    let keep = match wanted {
      Some(names) => names.contains(name)
      None => true
    }
    if keep {
      let (_, dtype) = plan(layout, id, name)
      kept.push((id, name, dtype, []))
    }
  }
  for k in 0..<layout.stripes.length() {
    let stripe = open_stripe(layout, k)
    for column in kept {
      let (id, name, _, cells) = column
      for value in column_values(stripe, id, name) {
        cells.push(value)
      }
    }
  }
  let out : Array[(String, @series.Series)] = []
  for column in kept {
    let (_, name, dtype, cells) = column
    out.push((name, @series.Series::from_scalars(name, cells, dtype~)))
  }
  (out, layout.rows)
}
