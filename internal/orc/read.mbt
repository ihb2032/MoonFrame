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
  let kept = kept_columns(layout, wanted)
  // Each kept column's cells, gathered stripe by stripe: one series a
  // column is built over them once every stripe has been read.
  let cells : Array[Array[@types.Scalar]] = kept.map(_ => [])
  for k in 0..<layout.stripes.length() {
    let stripe = open_stripe(layout, k)
    for c, (id, name, _) in kept {
      for value in column_values(stripe, id, name) {
        cells[c].push(value)
      }
    }
  }
  let out = kept.mapi((c, column) => {
    let (_, name, dtype) = column
    (name, @series.Series::from_scalars(name, cells[c], dtype~))
  })
  (out, layout.rows)
}

///|
/// The names and dtypes of the fields `projection` names among the file's
/// top-level ones, in file order — every field when `projection` is `None`
/// — as a batch-wise reader answers a frame that holds no row. Raises the
/// errors `read_orc_frame` states for a file it cannot open or a type it
/// does not carry.
pub fn orc_fields(
  bytes : Bytes,
  projection? : Array[String],
) -> Array[@types.Field] raise @types.DataError {
  // The caller's array is copied at the boundary: the reader keeps the
  // names itself, so a later mutation of theirs cannot change which
  // columns are read.
  let wanted : Array[String]? = match projection {
    Some(names) => Some(names.copy())
    None => None
  }
  let layout = read_layout(bytes)
  kept_columns(layout, wanted).map(column => {
    let (_, name, dtype) = column
    @types.Field::Field(name, dtype)
  })
}

///|
/// The rows of every stripe of the file in `bytes`, in file order — what a
/// batch-wise reader walks, and what places a window. Raises the errors
/// `read_orc_frame` states for a file it cannot open.
pub fn orc_stripe_rows(bytes : Bytes) -> Array[Int32] raise @types.DataError {
  let layout = read_layout(bytes)
  layout.stripes.map(info => info.rows.to_int())
}

///|
/// The kept columns of one stripe: stripe `k` of the file in `bytes`, the
/// fields `projection` names (every field when it is `None`), decoded from
/// that stripe alone — so a batch-wise reader holds one stripe's cells at a
/// time, never a file's. Each column is a series of the stripe's rows under
/// its dtype; the count answered is the stripe's own. Raises
/// `InvalidOperation` for a stripe the file does not hold, and the errors
/// `read_orc_frame` states otherwise.
pub fn read_orc_stripe(
  bytes : Bytes,
  stripe : Int32,
  projection? : Array[String],
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  let layout = read_layout(bytes)
  if stripe < 0 || stripe >= layout.stripes.length() {
    raise @types.DataError::InvalidOperation(
      "orc: stripe \{stripe}, where the file holds \{layout.stripes.length()}",
    )
  }
  // The caller's array is copied at the boundary: the reader keeps the
  // names itself, so a later mutation of theirs cannot change which
  // columns are read.
  let wanted : Array[String]? = match projection {
    Some(names) => Some(names.copy())
    None => None
  }
  let kept = kept_columns(layout, wanted)
  let opened = open_stripe(layout, stripe)
  let out = kept.map(column => {
    let (id, name, dtype) = column
    let cells : Array[@types.Scalar] = []
    for value in column_values(opened, id, name) {
      cells.push(value)
    }
    (name, @series.Series::from_scalars(name, cells, dtype~))
  })
  (out, layout.stripes[stripe].rows.to_int())
}

///|
/// The top-level fields `projection` names, in file order — every field
/// when it is `None` — each with its type id and the dtype its column is
/// built with. A type this reader does not carry refuses here, before any
/// stripe opens.
fn kept_columns(
  layout : Layout,
  projection : Array[String]?,
) -> Array[(Int32, String, @types.DataType)] raise @types.DataError {
  let root = layout.types[0]
  let kept : Array[(Int32, String, @types.DataType)] = []
  for i, id in root.subtypes {
    let name = root.names[i]
    let keep = match projection {
      Some(names) => names.contains(name)
      None => true
    }
    if keep {
      let (_, dtype) = plan(layout, id, name)
      kept.push((id, name, dtype))
    }
  }
  kept
}
