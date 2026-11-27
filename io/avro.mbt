// The Avro record interchange — a native reader and writer over the codec
// in `internal/avro` (the JSON schema, the zigzag binary encoding, and
// the file's blocks under the null / deflate / snappy / zstandard
// codecs). Projection is pushed into the read.
//
// The riders interchange by value: a date is an `int` under the `date`
// logical type, a timestamp a `long` under `timestamp-micros`, a decimal
// `bytes` under `decimal` with the scale its cells carry, an enum a
// string, a list an array and a struct a record — and every field is
// written as a nullable union, so a null lands wherever a column holds
// one. The mapping's refusals are stated on `parse_avro`.

///|
/// The compression a written Avro block carries (the reader takes every
/// codec it can decode; this names the writer's).
#derive(Eq, Debug)
pub(all) enum AvroCodec {
  Null
  Deflate
  Snappy
  Zstd
}

///|
pub extend AvroCodec with Eq::{equal, not_equal}

///|
pub extend AvroCodec with Debug::{to_repr}

///|
/// Write a frame as one Avro file: a record whose fields are the
/// columns, every field a nullable union, in blocks of ten thousand rows
/// compressed by `codec` (`AvroCodec::Null` by default — the blocks
/// stored as encoded). Raises `InvalidOperation` for a column whose name
/// is not a name an Avro schema allows (letters, digits and `_`,
/// starting with a letter or `_`), for a decimal column whose integer
/// digits and scale together pass the 38 an Avro decimal carries, and
/// for a date outside the `int` it rides; `Unsupported` for a `Null` or
/// `Duration` column; `IoError` for a path that cannot be written. A
/// lone UTF-16 surrogate in a string cell is refused, as every text
/// writer refuses it.
///
/// The same frame writes the same file.
pub fn write_avro(
  df : @frame.DataFrame,
  path : String,
  codec? : AvroCodec,
) -> Unit raise @types.DataError {
  let chosen = match codec {
    Some(Null) => @avro.Codec::Null
    Some(Deflate) => @avro.Codec::Deflate
    Some(Snappy) => @avro.Codec::Snappy
    Some(Zstd) => @avro.Codec::Zstd
    None => @avro.Codec::Null
  }
  let columns = df.column_series()
  let names = columns.map(column => column.name())
  let bytes = @avro.write_avro_bytes(columns, names, chosen)
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// Read an Avro file into a frame — the file's record as the columns, in
/// the file's order. Raises `ParseError` for bytes that are not a
/// container that holds together and `Unsupported` for what the mapping
/// does not carry, each as `parse_avro` states them; a path that cannot
/// be read raises `IoError`.
pub fn read_avro(
  path : String,
  projection? : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  parse_avro(bytes, projection?)
}

///|
/// Parse Avro bytes into a frame — the string-level entry's binary
/// counterpart (what `read_avro` hands the codec, exposed for in-memory
/// bytes).
///
/// `projection` keeps only the fields it names, in the file's order: a
/// name the file does not carry builds no column, and the rows stay. A
/// field the read does not keep is stepped over without being read into
/// a cell, so a refusal confined to it does not surface.
///
/// The columns a file's fields read as:
///
/// - `boolean` → `Bool`; `int` and `long` → `Int`; `float` and `double`
///   → `Float` (a 32-bit float widened to exactly what it holds);
///   `string` → `String`; an enum → `String`, the symbol.
/// - Under a logical type: `date` → `Date`; `timestamp-millis`,
///   `timestamp-micros` and their local forms → `Timestamp`; a time of
///   day (`time-millis`, `time-micros`) → `Timestamp` on the epoch day,
///   the library having no time-of-day type, so the cell still prints as
///   a clock reading; `decimal` over `bytes` or a fixed type →
///   `Decimal`; `uuid` → `String`. A logical type the format does not
///   define for its primitive is ignored, and the value reads plain.
/// - An array → `List` of what its items read as; a record → `Struct`
///   of its fields. A field typed `null` alone reads as an all-null
///   `String` column.
/// - A union of a null and one type reads as that type with the nulls;
///   the null may come first or last.
///
/// Raises `ParseError` (`Message`) for bytes that are not a container
/// that holds together: a file that does not open with the magic, a
/// truncated or malformed header, schema, block or datum, a block that
/// does not decompress or whose checksum does not match, a time of day
/// outside one day, a timestamp in milliseconds past what the library
/// holds, an index outside its union branches or enum symbols. Raises
/// `Unsupported` for what the mapping does not carry, each naming the
/// field: a block codec other than null / deflate / snappy / zstandard, a
/// top-level schema that is not a record, a `bytes` or fixed field with
/// no decimal logical type, a map field, a union of more than a null and
/// one type, a nanosecond timestamp, a duration, a decimal cell past 34
/// significant digits.
pub fn parse_avro(
  bytes : Bytes,
  projection? : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let (columns, nrows) = @avro.read_avro_frame(bytes, projection)
  // A lenient projection that matches no column still reports the file's
  // rows — the `N×0` shape the text readers' projections yield, not a
  // collapse to zero.
  if columns.length() == 0 {
    @frame.DataFrame::from_parts([], nrows)
  } else {
    @frame.DataFrame::DataFrame(columns.map(pair => pair.1))
  }
}
