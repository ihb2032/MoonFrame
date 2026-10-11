// The Parquet interchange: eager reads, eager writes, and the scan driver
// the lazy `scan_parquet` rides. The wire format is `mizchi/parquet`'s
// (reader vetted against the apache-parquet-testing fixtures); what sits
// over it is the type mapping both directions — a Parquet `ColumnType` to
// a MoonFrame `DataType`, a column chunk to a `Series`, a frame back to
// column-major `Value` rows — plus the fences where the two vocabularies
// disagree (a MoonFrame `Date` / `Decimal` column has no Parquet
// `ColumnType` here yet, and the upstream writer takes only Int / String).
//
// The read keeps Parquet's own column order (a projection narrows the
// column list, never re-orders it — the driver contract); `TIMESTAMP
// (MICROS)` maps to MoonFrame's `Timestamp`, the dtype that was sized to
// it. Strings decode strictly: a column that is not valid UTF-8 refuses
// the read rather than corrupting cells silently, the `read_text` rule.
//
// The write side emits every column as optional `Value` cells — one row
// per cell, `Null` for a null — which covers every writable dtype
// uniformly; the columnar fast variants are a later, size-aware
// optimisation on top.

///|
/// Translate a Parquet error into the library's error type: the format's
/// own `Io` / `InvalidData` / `Unsupported` detail rides the message, so
/// the caller sees one error vocabulary with the origin spelled out.
fn parquet_io_error(e : @parquet.ParquetError) -> @types.DataError {
  @types.DataError::IoError("parquet: \{e.to_string()}")
}

///|
/// The MoonFrame dtype a Parquet column type maps onto — the read side of
/// the type mapping, one row per Parquet type. A `Binary` column (an
/// unannotated byte array, the ecosystem's common spelling for text a
/// writer declined to label UTF8) maps to `String`: the cell decode is
/// strict, so a non-UTF8 payload refuses the read rather than corrupting
/// the column silently.
fn parquet_column_type(t : @parquet.ColumnType) -> @types.DataType {
  match t {
    @parquet.ColumnType::Boolean => @types.DataType::Bool
    @parquet.ColumnType::Int32 => @types.DataType::Int
    @parquet.ColumnType::Int64 => @types.DataType::Int
    @parquet.ColumnType::TimestampMicros => @types.DataType::Timestamp
    @parquet.ColumnType::Float => @types.DataType::Float
    @parquet.ColumnType::Double => @types.DataType::Float
    @parquet.ColumnType::String => @types.DataType::String
    @parquet.ColumnType::Binary => @types.DataType::String
  }
}

///|
/// One Parquet column chunk as a `Series` — the columnar variants map
/// straight onto the nullable constructors (`Int32` / `Float` cells widen
/// to the 64-bit buffers), the row-form `Values` chunk decodes per cell
/// and locks the dtype from the column's declared type. Strings decode
/// strictly under the `read_text` rule.
fn parquet_column_series(
  name : String,
  declared : @types.DataType,
  data : @parquet.ParquetColumnData,
) -> @series.Series raise @types.DataError {
  match data {
    @parquet.ParquetColumnData::BooleanValues(cells) =>
      @series.Series::from_bools(name, cells)
    @parquet.ParquetColumnData::Int32Values(cells) =>
      @series.Series::from_int_options(name, cells.map(c => Some(c.to_int64())))
    @parquet.ParquetColumnData::NullableInt32Values(cells) =>
      @series.Series::from_int_options(
        name,
        cells.map(c => c.map(v => v.to_int64())),
      )
    @parquet.ParquetColumnData::Int64Values(cells) =>
      @series.Series::from_int_options(name, cells.map(c => Some(c)))
    @parquet.ParquetColumnData::NullableInt64Values(cells) =>
      @series.Series::from_int_options(name, cells)
    @parquet.ParquetColumnData::TimestampMicrosValues(cells) =>
      @series.Series::from_timestamp_options(name, cells.map(c => Some(c)))
    @parquet.ParquetColumnData::NullableTimestampMicrosValues(cells) =>
      @series.Series::from_timestamp_options(name, cells)
    @parquet.ParquetColumnData::FloatValues(cells) =>
      @series.Series::from_float_options(
        name,
        cells.map(c => Some(c.to_double())),
      )
    @parquet.ParquetColumnData::DoubleValues(cells) =>
      @series.Series::from_floats(name, cells)
    @parquet.ParquetColumnData::Utf8Values(cells) =>
      @series.Series::from_strings(
        name,
        cells.map(b => decode_parquet_text(b, name)),
      )
    @parquet.ParquetColumnData::NullableUtf8Values(cells) =>
      @series.Series::from_string_options(
        name,
        cells.map(c => c.map(b => decode_parquet_text(b, name))),
      )
    // A Binary chunk is an unannotated byte array — the Parquet ecosystem's
    // common spelling for text a writer declined to label UTF8. It reads as
    // a String under the same strict decode as a labelled one, so a
    // non-UTF8 payload refuses the read instead of corrupting cells.
    @parquet.ParquetColumnData::BinaryValues(cells) =>
      @series.Series::from_strings(
        name,
        cells.map(b => decode_parquet_text(b, name)),
      )
    @parquet.ParquetColumnData::NullableBinaryValues(cells) =>
      @series.Series::from_string_options(
        name,
        cells.map(c => c.map(b => decode_parquet_text(b, name))),
      )
    @parquet.ParquetColumnData::Values(cells) =>
      @series.Series::from_scalars(
        name,
        cells.map(v => parquet_value(v, name)),
        dtype=declared,
      )
  }
}

///|
/// One row-form Parquet cell as a `Scalar`, under the column's declared
/// dtype. `Null` stays the missing value; a value that disagrees with the
/// declared dtype (a schema drift the reader should not paper over) is a
/// `TypeMismatch`, the same verdict an explicit-dtype build gives.
fn parquet_value(
  v : @parquet.Value,
  name : String,
) -> @types.Scalar raise @types.DataError {
  match v {
    @parquet.Value::Boolean(b) => @types.Scalar::Bool(b)
    @parquet.Value::Int32(i) => @types.Scalar::Int(i.to_int64())
    @parquet.Value::Int64(i) => @types.Scalar::Int(i)
    @parquet.Value::TimestampMicros(us) => @types.Scalar::Timestamp(us)
    @parquet.Value::Float(f) => @types.Scalar::Float(f.to_double())
    @parquet.Value::Double(d) => @types.Scalar::Float(d)
    @parquet.Value::String(s) => @types.Scalar::String(s)
    @parquet.Value::Null => @types.Scalar::Null
    @parquet.Value::Binary(b) =>
      @types.Scalar::String(decode_parquet_text(b, name))
  }
}

///|
/// Strictly decode a Parquet string cell — the `read_text` rule for one
/// cell: refuse the read on bytes that are not UTF-8 rather than corrupt
/// the column silently.
fn decode_parquet_text(
  b : Bytes,
  name : String,
) -> String raise @types.DataError {
  @utf8.decode(b) catch {
    _ =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "parquet: column \"\{name}\" holds bytes that are not valid UTF-8",
        ),
      )
  }
}

///|
/// Assemble a Parquet columnar file as a frame. `projection` narrows the
/// column list (never the row count: a projection matching no column keeps
/// the `N×0` shape, the driver contract); the file's own column order
/// survives.
fn parquet_columnar_to_frame(
  file : @parquet.ParquetColumnarFile,
  projection : Array[String]?,
) -> @frame.DataFrame raise @types.DataError {
  let columns : Array[@series.Series] = []
  for i in 0..<file.columns.length() {
    let col = file.columns[i]
    let keep = match projection {
      None => true
      Some(names) => names.contains(col.name)
    }
    if keep {
      let declared = parquet_column_type(col.column_type)
      columns.push(
        parquet_column_series(col.name, declared, file.column_data[i]),
      )
    }
  }
  @frame.DataFrame::from_parts(columns, file.row_count)
}

///|
/// Read a Parquet file from its bytes. The whole document parses before
/// any column builds, so a malformed file fails as a read, never as a
/// half-built frame.
pub fn parse_parquet(bytes : Bytes) -> @frame.DataFrame raise @types.DataError {
  let file = @parquet.read_bytes_columnar(bytes) catch {
    e => raise parquet_io_error(e)
  }
  parquet_columnar_to_frame(file, None)
}

///|
/// Read a Parquet file. The binary read maps a file-system failure to
/// `IoError`; the Parquet parse and the column builds raise through as
/// themselves.
pub fn read_parquet(path : String) -> @frame.DataFrame raise @types.DataError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  parse_parquet(bytes)
}

///|
/// One MoonFrame cell as a row-form Parquet value. The write side of the
/// type mapping: `Date` and `Decimal` are the fences (no Parquet
/// `ColumnType` here carries them yet).
fn parquet_cell(v : @types.Scalar) -> @parquet.Value raise @types.DataError {
  match v {
    @types.Scalar::Int(i) => @parquet.Value::Int64(i)
    @types.Scalar::Float(d) => @parquet.Value::Double(d)
    @types.Scalar::Bool(b) => @parquet.Value::Boolean(b)
    @types.Scalar::String(s) => @parquet.Value::String(s)
    @types.Scalar::Timestamp(us) => @parquet.Value::TimestampMicros(us)
    @types.Scalar::Null => @parquet.Value::Null
    @types.Scalar::Date(_) =>
      raise @types.DataError::Unsupported(
        "parquet write: a Date column has no Parquet type here yet",
      )
    @types.Scalar::Decimal(scale, _) =>
      raise @types.DataError::Unsupported(
        "parquet write: a Decimal(\{scale}) column has no Parquet type here yet",
      )
  }
}

///|
/// The Parquet column type a MoonFrame dtype writes as — the write side's
/// declared half, kept beside `parquet_cell` so the two cannot drift.
fn parquet_write_type(
  d : @types.DataType,
) -> @parquet.ColumnType raise @types.DataError {
  match d {
    @types.DataType::Int => @parquet.ColumnType::Int64
    @types.DataType::String => @parquet.ColumnType::String
    @types.DataType::Null =>
      raise @types.DataError::Unsupported(
        "parquet write: a Null-dtype column cannot be written",
      )
    // The upstream writer accepts Int32 / Int64 / String / Binary only
    // (its own gate), so Bool / Float / Timestamp columns refuse here with
    // the same fence rather than failing deep in the writer — the read side
    // maps all of them, so this is a write-only limit.
    @types.DataType::Bool
    | @types.DataType::Float
    | @types.DataType::Timestamp =>
      raise @types.DataError::Unsupported(
        "parquet write: the upstream writer does not take a \{d} column yet (Int and String are the writable dtypes)",
      )
    @types.DataType::Date | @types.DataType::Decimal(_) =>
      raise @types.DataError::Unsupported(
        "parquet write: a Date / Decimal column has no Parquet type here yet",
      )
  }
}

///|
/// Serialise a frame as Parquet bytes. Every column is written optional,
/// one `Value` cell per row (`Null` for a null) — the uniform encoding that
/// covers every writable dtype; column names ride the schema as declared.
pub fn format_parquet(df : @frame.DataFrame) -> Bytes raise @types.DataError {
  let names = df.columns()
  let columns : Array[@parquet.Column] = []
  for name in names {
    let t = parquet_write_type(df.get_column(name).dtype())
    columns.push(@parquet.new_column(name, t, @parquet.Repetition::Optional))
  }
  let rows : Array[Array[@parquet.Value]] = []
  for r in 0..<df.nrows() {
    rows.push(names.map(name => parquet_cell(df.item(r, name))))
  }
  let file = @parquet.new_parquet_file(columns, rows, None)
  @parquet.write_bytes(file) catch {
    e => raise parquet_io_error(e)
  }
}

///|
/// Write a frame to a Parquet file.
pub fn write_parquet(
  df : @frame.DataFrame,
  path : String,
) -> Unit raise @types.DataError {
  let bytes = format_parquet(df)
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// The Parquet scan driver — the lazy `scan_parquet`'s read face. The
/// projection narrows the columns built (Parquet's columnar layout makes
/// that the cheap half); an absorbed predicate is applied to the assembled
/// frame, which is exactly the eager `read_parquet(path).filter(..)` —
/// row-group pruning is the streaming-reader's later win, correctness
/// never depends on it.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn parquet_scan_driver(path : String) -> @scan.ScanDriver {
  @scan.ScanDriver::driver(() => "PARQUET \"\{@text.escape_debug(path)}\"", (
    projection,
    predicate,
  ) => {
    let bytes = @fs.read_file_to_bytes(path) catch {
      @fs.IOError(msg) => raise @types.DataError::IoError(msg)
    }
    let file = @parquet.read_bytes_columnar(bytes) catch {
      e => raise parquet_io_error(e)
    }
    let df = parquet_columnar_to_frame(file, projection)
    let kept = match predicate {
      Some(pred) => df.filter(pred)
      None => df
    }
    let columns = kept.columns().map(name => kept.get_column(name))
    @scan.ScanBatch::batch(columns, kept.nrows())
  })
}
