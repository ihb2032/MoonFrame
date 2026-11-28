// The Iceberg table interchange: a table's current snapshot read into a
// frame, and nothing written. The metadata, the snapshot's manifest list
// and its manifests are walked by the codec in `internal/iceberg`, which
// answers the files the snapshot holds; every data file is a Parquet file,
// read by the Parquet codec, a column taken by the field id it carried
// when the file was written — whatever its name is now — so that a column
// renamed, widened, added or dropped since reads in its place. A path the
// metadata names is opened under the directory the caller names, so a
// table reads wherever it has been moved to.

///|
/// The field ids the format gives a position-delete file's two columns:
/// the data file a deleted position lies in, and the position.
const DELETE_PATH_ID : Int64 = 2147483546L

///|
const DELETE_POSITION_ID : Int64 = 2147483545L

///|
/// One position-delete file, read: the positions it deletes from each
/// data file, by the data file's path as the delete file spells it — the
/// table's location joined to the file's relative path. Kept with the
/// delete file's own partition and sequence number, which decide the data
/// files it applies to.
priv struct IcebergDeletes {
  partition : Array[@iceberg.IcebergPartitionValue]
  sequence : Int64
  positions : Map[String, Array[Int64]]
}

///|
/// Read an Iceberg table's current snapshot into a frame: every live data
/// file of the snapshot, in the plan's order — the manifest list's order,
/// then each manifest's entries — with the table's current columns. The
/// table is the directory `path` names: its current metadata file is the
/// one `metadata/version-hint.text` names when the file is there, and
/// otherwise the one of `metadata/*.metadata.json` whose leading version
/// number is the greatest.
///
/// Each column takes the data files' column of the same field id, under
/// the column's current name; a column a file does not hold — one added
/// after the file was written, or one an identity partition dropped from
/// the data — reads as the file's partition value for an identity
/// partition, and as null otherwise. A table with no snapshot reads as the
/// empty frame of its columns.
///
/// A position-delete file removes the positions it names from the data
/// files of its partition whose sequence number is not above its own. An
/// equality-delete file, a nested column, a column of a type the library
/// does not carry, a file that names no field id, and a format version
/// past 3 refuse by name; nothing is approximated.
///
/// Raises `IoError` for a file that cannot be read, `ParseError` for a
/// malformed metadata file, manifest list, manifest or data file,
/// `Unsupported` for what the format allows and this reader does not
/// carry, and `InvalidOperation` where a data file answers another row
/// count than its manifest entry names.
pub fn read_iceberg(path : String) -> @frame.DataFrame raise @types.DataError {
  let root = iceberg_root(path)
  let metadata = iceberg_metadata_file(root)
  let table = @iceberg.iceberg_metadata(iceberg_bytes(metadata))
  let schema = table.schema()
  let ids = table.field_ids()
  let list = match table.manifest_list() {
    None => return @frame.DataFrame::empty(schema)
    Some(list) => list
  }
  let location = table.location()
  let manifests = @iceberg.iceberg_manifests(
    iceberg_bytes(iceberg_joined(root, list)),
    location~,
  )
  // The plan in one pass: the data files in order, and each position-delete
  // file read as it is met.
  let data : Array[@iceberg.IcebergFile] = []
  let deletes : Array[IcebergDeletes] = []
  for manifest in manifests {
    let files = @iceberg.iceberg_files(
      iceberg_bytes(iceberg_joined(root, manifest.path())),
      manifest~,
    )
    for file in files {
      match file.kind() {
        Data => data.push(file)
        PositionDeletes => deletes.push(iceberg_position_deletes(root, file))
        EqualityDeletes =>
          raise @types.DataError::Unsupported(
            "iceberg: the equality-delete file \{file.path()}, on the columns \{file.equality_ids().map(id => id.to_string()).join(", ")}, which this reader does not apply",
          )
      }
    }
  }
  let frames : Array[@frame.DataFrame] = []
  for file in data {
    let frame = iceberg_file_frame(
      iceberg_bytes(iceberg_joined(root, file.path())),
      file,
      schema,
      ids,
    )
    frames.push(iceberg_without_positions(frame, file, location, deletes))
  }
  // A snapshot that holds no data file reads as the empty frame of the
  // columns, as a table with no snapshot does.
  if frames.is_empty() {
    return @frame.DataFrame::empty(schema)
  }
  let mut out = frames[0]
  for frame in frames[1:] {
    out = out.vstack(frame)
  }
  out
}

///|
/// The table's directory as the caller named it, without a separator at
/// its end.
fn iceberg_root(path : String) -> String {
  let trimmed = path.trim_end(chars="/\\")
  if trimmed.is_empty() {
    path
  } else {
    trimmed.to_owned()
  }
}

///|
/// A file under the table: a path the metadata names relative to the
/// table's location, joined to the table's directory.
fn iceberg_joined(root : String, relative : String) -> String {
  "\{root}/\{relative}"
}

///|
/// A file's bytes, an unreadable file being the I/O error it is.
fn iceberg_bytes(path : String) -> Bytes raise @types.DataError {
  @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// The metadata file the table's current snapshot is read from: the one
/// `metadata/version-hint.text` names when it is there — a content ending
/// in `.metadata.json` names the file as it is spelled, a bare number
/// names `v<number>.metadata.json`, anything else names
/// `<content>.metadata.json` — and otherwise, among the metadata files
/// present, the one whose leading version number is the greatest.
fn iceberg_metadata_file(root : String) -> String raise @types.DataError {
  let dir = iceberg_joined(root, "metadata")
  let hint = iceberg_joined(dir, "version-hint.text")
  if @fs.path_exists(hint) {
    let named = iceberg_text(hint).trim().to_owned()
    let bare_number = named.length() > 0 &&
      named.iter().all(fn(c) { c >= '0' && c <= '9' })
    let file = if named.has_suffix(".metadata.json") {
      named
    } else if bare_number {
      "v\{named}.metadata.json"
    } else {
      "\{named}.metadata.json"
    }
    return iceberg_joined(dir, file)
  }
  let names = @fs.read_dir(dir) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  let mut best = ""
  let mut best_version = -1L
  for name in names {
    if name.has_suffix(".metadata.json") {
      let version = iceberg_version_number(name)
      if version >= best_version {
        best_version = version
        best = name
      }
    }
  }
  if best.is_empty() {
    raise @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "iceberg: the table's metadata directory names no metadata file",
      ),
    )
  }
  iceberg_joined(dir, best)
}

///|
/// The number a metadata file's name leads with, before its first hyphen
/// or dot — `9` of `00009-<uuid>.metadata.json`; `-1` where it leads with
/// none.
fn iceberg_version_number(name : String) -> Int64 {
  let digits = StringBuilder()
  for c in name.iter() {
    if c == '-' || c == '.' {
      break
    }
    if !(c >= '0' && c <= '9') {
      return -1L
    }
    digits.write_char(c)
  }
  let text = digits.to_string()
  if text.is_empty() {
    -1L
  } else {
    @text.parse_decimal_int_opt(text).unwrap_or(-1L)
  }
}

///|
/// A small text file's content, an unreadable file being the I/O error it
/// is.
fn iceberg_text(path : String) -> String raise @types.DataError {
  @fs.read_file_to_string(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// A Parquet file's named columns as a frame, over `rows` rows.
fn iceberg_read(
  bytes : Bytes,
  names : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let (columns, rows) = @parquet.read_parquet_frame(bytes, Some(names))
  let series : Array[@series.Series] = []
  for (_, column) in columns {
    series.push(column)
  }
  @frame.DataFrame::from_parts(series, rows)
}

///|
/// One position-delete file as it applies to the data files: its two
/// columns read by their field ids, and every row a position struck from
/// the data file its path names. The path is kept as the delete file
/// spells it, the table's location joined to the data file's relative
/// path.
fn iceberg_position_deletes(
  root : String,
  file : @iceberg.IcebergFile,
) -> IcebergDeletes raise @types.DataError {
  let path = iceberg_joined(root, file.path())
  let bytes = iceberg_bytes(path)
  let ids = @parquet.parquet_field_ids(bytes)
  let mut path_column = ""
  let mut position_column = ""
  for (name, id) in ids {
    if id == DELETE_PATH_ID {
      path_column = name
    } else if id == DELETE_POSITION_ID {
      position_column = name
    }
  }
  if path_column.is_empty() || position_column.is_empty() {
    raise @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "iceberg: the position-delete file \{file.path()} names no column of the data file's path or of the position",
      ),
    )
  }
  let read = iceberg_read(bytes, [path_column, position_column])
  let paths = read.get_column(path_column).to_scalars()
  let positions = read.get_column(position_column).to_scalars()
  let struck : Map[String, Array[Int64]] = Map([])
  for i, spelled in paths {
    let path = match spelled {
      @types.Scalar::String(path) => path
      _ =>
        raise @types.DataError::ParseError(
          @types.ParseErrorDetail::Message(
            "iceberg: the position-delete file \{file.path()} holds a data file's path that is not a string",
          ),
        )
    }
    let position = match positions[i] {
      @types.Scalar::Int(position) => position
      _ =>
        raise @types.DataError::ParseError(
          @types.ParseErrorDetail::Message(
            "iceberg: the position-delete file \{file.path()} holds a position that is not a whole number",
          ),
        )
    }
    let at = match struck.get(path) {
      Some(at) => at
      None => []
    }
    at.push(position)
    struck[path] = at
  }
  {
    partition: file.partition(),
    sequence: file.sequence_number(),
    positions: struck,
  }
}

///|
/// One data file as the table's columns, in the schema's order. Each
/// column takes the file's column of the same field id, cast to the
/// column's dtype when the file spelled it otherwise and renamed to the
/// column's name; a column the file does not hold takes its value from the
/// file's partition tuple under an identity transform, and null
/// otherwise. The file's rows must number what its manifest entry names.
fn iceberg_file_frame(
  bytes : Bytes,
  file : @iceberg.IcebergFile,
  schema : @types.Schema,
  ids : Array[Int64],
) -> @frame.DataFrame raise @types.DataError {
  let file_ids = @parquet.parquet_field_ids(bytes)
  if file_ids.all(pair => pair.1 < 0L) {
    raise @types.DataError::Unsupported(
      "iceberg: the file \{file.path()} names no field id, so its columns cannot be matched to the table's",
    )
  }
  // The file's columns the table still holds, by the names the file gave
  // them; a column dropped since is left undecoded.
  let kept : Array[String] = []
  for (name, id) in file_ids {
    if ids.contains(id) {
      kept.push(name)
    }
  }
  let read = iceberg_read(bytes, kept)
  let rows = read.nrows()
  if rows.to_int64() != file.record_count() {
    raise @types.DataError::InvalidOperation(
      "iceberg: the file \{file.path()} answers \{rows} rows, where its manifest entry names \{file.record_count()}",
    )
  }
  let fields = schema.fields()
  let out : Array[@series.Series] = []
  for i, field in fields {
    let id = ids[i]
    let mut taken : String? = None
    for (name, file_id) in file_ids {
      if file_id == id {
        taken = Some(name)
      }
    }
    let series = match taken {
      Some(name) => read.get_column(name)
      None => iceberg_absent_column(file, id, field, rows)
    }
    let dtype = field.dtype()
    let cast = if series.dtype() != dtype { series.cast(dtype) } else { series }
    out.push(cast.rename(field.name()))
  }
  @frame.DataFrame::from_parts(out, rows)
}

///|
/// A column the file does not hold, over `rows` rows: the file's partition
/// value where the column is identity-partitioned, and null otherwise. The
/// partition tuple names each value's source column; a value under another
/// transform is the transform's result, which the source value cannot be
/// recovered from.
fn iceberg_absent_column(
  file : @iceberg.IcebergFile,
  id : Int64,
  field : @types.Field,
  rows : Int32,
) -> @series.Series raise @types.DataError {
  let mut value : @types.Scalar = @types.Scalar::Null
  for partition in file.partition() {
    if partition.source_id() == id &&
      partition.transform() is @iceberg.IcebergTransform::Identity {
      value = partition.value()
    }
  }
  @series.Series::from_scalars(
    field.name(),
    Array::make(rows, value),
    dtype=field.dtype(),
  )
}

///|
/// The data file's rows without the positions the delete files strike:
/// those of its partition whose sequence number is not above the data
/// file's own.
fn iceberg_without_positions(
  frame : @frame.DataFrame,
  file : @iceberg.IcebergFile,
  location : String,
  deletes : Array[IcebergDeletes],
) -> @frame.DataFrame raise @types.DataError {
  let spelled = "\{location}/\{file.path()}"
  let struck : Array[Int64] = []
  for delete in deletes {
    if delete.sequence >= file.sequence_number() &&
      iceberg_same_partition(delete.partition, file.partition()) {
      match delete.positions.get(spelled) {
        Some(positions) => struck.append(positions)
        None => ()
      }
    }
  }
  if struck.is_empty() {
    return frame
  }
  let kept : Array[Int32] = []
  for row in 0..<frame.nrows() {
    if !struck.contains(row.to_int64()) {
      kept.push(row)
    }
  }
  frame.gather(kept)
}

///|
/// Whether two partition tuples spell the same partition: the same fields,
/// each under the same transform, each holding the same value.
fn iceberg_same_partition(
  one : Array[@iceberg.IcebergPartitionValue],
  other : Array[@iceberg.IcebergPartitionValue],
) -> Bool {
  one.length() == other.length() &&
  one
  .zip(other)
  .all(pair => {
    let (value, against) = pair
    value.source_id() == against.source_id() &&
    value.transform() == against.transform() &&
    value.value() == against.value()
  })
}
