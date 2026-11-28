// The partitioned sinks: what a lazy sink writes when its target is a
// directory rather than one file. `PartitionBy` says how the rows split —
// a directory a distinct value of the key columns, and a file per so many
// rows — and the routing here is what every format's encoder rides: each
// batch's rows go to the file they belong to, a file is written once it is
// full and more rows come, and the rest when the plan has answered.

///|
/// How a lazy sink (`sink_parquet`, `sink_csv`, `sink_ipc`, `sink_ndjson`)
/// splits its output into files under a directory, `path` naming that
/// directory. Fields are read-only outside the package — build them
/// through `PartitionBy::PartitionBy(...)`, naming only what differs from
/// the defaults:
///
///   * `key` — the columns a directory is made per distinct value of, one
///     level a column: `path/region=Americas/year=2020/…`. A value is
///     spelled as its cell renders, with the characters a path component
///     cannot hold written `%XX` — a space, the hive separator `=`, the
///     escape `%`, a separator, a control character, and every byte outside
///     ASCII — and a null as `__HIVE_DEFAULT_PARTITION__`. `None` (the
///     default) makes one directory of `path` itself.
///   * `include_key` — when `true` (the default) the key columns stay in
///     the files; when `false` a file holds the other columns alone.
///   * `max_rows_per_file` — the most rows a file holds; a batch's rows
///     are cut at that count, so a file may hold fewer. `None` (the
///     default) puts a directory's rows in one file.
///
/// A file is named by its index in its directory, eight digits and the
/// format's extension (`00000000.parquet`, `00000000.csv`, `00000000.ipc`,
/// `00000000.jsonl`), in the order the rows arrived. The text formats
/// write every file plain, whatever the single-file sinks do with a `.gz`
/// path.
#derive(Eq, Debug)
pub struct PartitionBy {
  priv key : Array[String]?
  include_key : Bool
  max_rows_per_file : Int32?
}

///|
pub extend PartitionBy with Eq::{equal, not_equal}

///|
pub extend PartitionBy with Debug::{to_repr}

///|
/// The key columns the partition names, `None` for the one directory `path`
/// names. A copy, so mutating it cannot alter the options.
pub fn PartitionBy::key(self : PartitionBy) -> Array[String]? {
  self.key.map(names => names.copy())
}

///|
/// Whether the key columns stay in the files.
pub fn PartitionBy::include_key(self : PartitionBy) -> Bool {
  self.include_key
}

///|
/// The most rows a file holds, `None` for a directory's rows in one file.
pub fn PartitionBy::max_rows_per_file(self : PartitionBy) -> Int32? {
  self.max_rows_per_file
}

///|
/// Build partitioning options. Omitting a parameter keeps its default: no
/// key, the key columns kept in the files, and a directory's rows in one
/// file — `PartitionBy::PartitionBy(max_rows_per_file=1000)` cuts the
/// output into files of a thousand rows; `PartitionBy::PartitionBy(
/// key=["region", "year"])` makes a directory a region and year. `key` is
/// copied, so mutating it afterwards cannot alter the options.
pub fn PartitionBy::PartitionBy(
  key? : Array[String],
  include_key? : Bool,
  max_rows_per_file? : Int32,
) -> PartitionBy {
  let kept = key.map(names => names.copy())
  { key: kept, include_key: include_key.unwrap_or(true), max_rows_per_file, }
}

///|
/// A null's directory: the spelling hive partitioning gives a missing
/// value, so a null is told from the string naming it.
const HIVE_DEFAULT_PARTITION : String = "__HIVE_DEFAULT_PARTITION__"

///|
/// The options as a sink can act on them: a row limit that is not positive
/// and a key naming no column are refused, before anything is read.
fn partition_checked(parts : PartitionBy) -> PartitionBy raise @types.DataError {
  if parts.max_rows_per_file is Some(limit) && limit <= 0 {
    raise @types.DataError::InvalidOperation(
      "sink: max_rows_per_file is \{limit}, where a file holds at least one row",
    )
  }
  if parts.key is Some(names) && names.is_empty() {
    raise @types.DataError::InvalidOperation(
      "sink: the partition key names no column",
    )
  }
  parts
}

///|
/// What the files of one format hold: its encoder, made afresh for every
/// file, with the single-file sink's own options.
priv enum PartFormat {
  Parquet(@parquet.Codec, Int64)
  Ipc(@ipc.BodyCodec?, Bool)
  Csv(CsvWriteOptions)
  Ndjson
}

///|
/// The extension a format's files carry.
fn PartFormat::extension(self : PartFormat) -> String {
  match self {
    Parquet(_, _) => ".parquet"
    Ipc(_, _) => ".ipc"
    Csv(_) => ".csv"
    Ndjson => ".jsonl"
  }
}

///|
/// One file under way: its format's encoder with the rows it holds so far,
/// and whether a batch has landed in it — a text file's header rides the
/// first alone, and an empty file takes the batch's columns all the same.
priv struct PartFile {
  format : PartFormat
  parquet : @parquet.ParquetSink?
  ipc : @ipc.IpcSink?
  text : StringBuilder
  mut started : Bool
  mut rows : Int32
}

///|
/// A file's encoder opened, nothing in it.
fn PartFile::open(format : PartFormat) -> PartFile {
  let (parquet, ipc) = match format {
    Parquet(codec, group_rows) =>
      (Some(@parquet.ParquetSink::sink(codec, group_rows~)), None)
    Ipc(codec, file) => (None, Some(@ipc.IpcSink::sink(codec, file~)))
    Csv(_) | Ndjson => (None, None)
  }
  { format, parquet, ipc, text: StringBuilder(), started: false, rows: 0, }
}

///|
/// A batch's rows into the file: a batch of no column goes in by its
/// height alone where the format has that spelling (the parquet writer's
/// frameless push), and a text file's first batch brings the header.
fn PartFile::push(
  self : PartFile,
  frame : @frame.DataFrame,
) -> Unit raise @types.DataError {
  let columns = frame.column_series()
  match self.format {
    Parquet(_, _) => {
      let sink = self.parquet.unwrap()
      if columns.is_empty() {
        sink.push_frameless(frame.nrows())
      } else {
        sink.push(columns)
      }
    }
    Ipc(_, _) => self.ipc.unwrap().push(columns, height=frame.nrows())
    Csv(options) =>
      if !self.started {
        self.text.write_string(format_csv(frame, options~))
      } else {
        let later = CsvWriteOptions::CsvWriteOptions(
          header=false,
          delimiter=options.delimiter,
          null_value=options.null_value,
          sanitize_formulas=options.sanitize_formulas,
          line_terminator=options.line_terminator,
        )
        self.text.write_string(format_csv(frame, options=later))
      }
    Ndjson => self.text.write_string(format_ndjson(frame))
  }
  self.started = true
  self.rows = self.rows + frame.nrows()
}

///|
/// The files under way and where each goes: the directories in the order
/// the rows first reached them, how many files each has had, and the one
/// file each still holds open. The key columns are read at the first
/// batch, where the plan's columns are first known.
priv struct PartRouter {
  base : String
  parts : PartitionBy
  format : PartFormat
  dirs : Array[String]
  written : Array[Int32]
  open : Array[PartFile]
  mut resolved : Bool
  mut key : Array[@series.Series]
  mut out : Array[Int32]?
}

///|
/// A plan's batches written as files under `base`, split as `parts` says,
/// each file encoded as `format` spells. Raises the plan's own `DataError`
/// — the same error, on the same first offending batch, `collect` would
/// raise — `ColumnNotFound` for a key column the plan does not carry, the
/// writers' own refusals, and `IoError` for a directory or file that cannot
/// be written. Nothing is read until the first batch is pulled.
fn sink_partitioned(
  lf : @frame.LazyFrame,
  base : String,
  parts : PartitionBy,
  format : PartFormat,
  optimizations : @frame.Optimizations,
) -> Unit raise @types.DataError {
  let router = PartRouter::{
    base: base.trim_end(chars="/").to_owned(),
    parts,
    format,
    dirs: [],
    written: [],
    open: [],
    resolved: false,
    key: [],
    out: None,
  }
  // A plan always answers at least one batch — an empty one carries its
  // columns — so the empty plan's file is the first batch's work, not a
  // case of its own.
  let stream = lf.collect_batches(optimizations~)
  while true {
    match stream.next() {
      Some(batch) => router.feed(batch)
      None => break
    }
  }
  router.flush()
}

///|
/// The plan's key columns and the columns its files hold, resolved the
/// first time a batch arrives — the first place the plan's columns are
/// known. Without a key every column is written and no row's directory is
/// read.
fn PartRouter::resolve(
  self : PartRouter,
  frame : @frame.DataFrame,
) -> Unit raise @types.DataError {
  let names = match self.parts.key {
    Some(names) => names
    None => return
  }
  // A name the plan does not carry is the frame's own refusal.
  self.key = names.map(name => frame.get_column(name))
  if !self.parts.include_key {
    let out : Array[Int32] = []
    for i, name in frame.columns() {
      if !names.contains(name) {
        out.push(i)
      }
    }
    self.out = Some(out)
  }
}

///|
/// The batch as its files hold it: every column, or the ones the key does
/// not name when the key stays out.
fn PartRouter::content(
  self : PartRouter,
  frame : @frame.DataFrame,
) -> @frame.DataFrame raise @types.DataError {
  match self.out {
    None => frame
    Some(positions) => {
      let every = frame.column_series()
      @frame.DataFrame::from_parts(positions.map(i => every[i]), frame.nrows())
    }
  }
}

///|
/// A row's directory, as the key's cells at it spell it: one level a key
/// column, `column=value`.
fn PartRouter::directory(
  self : PartRouter,
  row : Int32,
) -> String raise @types.DataError {
  let names = self.parts.key.unwrap()
  let levels : Array[String] = []
  for c, column in self.key {
    let cell = column.get(row)
    let value = if cell is @types.Scalar::Null {
      HIVE_DEFAULT_PARTITION
    } else {
      path_component(cell.to_string())
    }
    levels.push("\{names[c]}=\{value}")
  }
  levels.join("/")
}

///|
/// The batch's rows to the files they belong to: with no key every row goes
/// to the one directory; with one, a run of rows spelling the same
/// directory goes together, in the order they arrived.
fn PartRouter::feed(
  self : PartRouter,
  frame : @frame.DataFrame,
) -> Unit raise @types.DataError {
  if !self.resolved {
    self.resolve(frame)
    self.resolved = true
  }
  let content = self.content(frame)
  match self.parts.key {
    None => self.send(content, 0, content.nrows(), "")
    Some(_) => {
      let nrows = frame.nrows()
      if nrows == 0 {
        // No row names a value: no directory is made.
        return
      }
      let mut from = 0
      let mut dir = self.directory(0)
      for row in 1..<=nrows {
        if row == nrows {
          self.send(content, from, row, dir)
        } else {
          let next = self.directory(row)
          if next != dir {
            self.send(content, from, row, dir)
            from = row
            dir = next
          }
        }
      }
    }
  }
}

///|
/// Rows `[from, to)` of `content` into `dir`'s file, a new file opened —
/// the full one before it written — each time the row limit is reached.
fn PartRouter::send(
  self : PartRouter,
  content : @frame.DataFrame,
  from : Int32,
  to : Int32,
  dir : String,
) -> Unit raise @types.DataError {
  let d = self.directory_index(dir)
  let limit = self.parts.max_rows_per_file.unwrap_or(2147483647)
  // A file handed no row takes the batch's columns all the same, so an
  // empty file reads back with the schema, as the single-file sink's does.
  if from == to && !self.open[d].started {
    self.open[d].push(content.slice(from, length=0))
  }
  let mut at = from
  while at < to {
    let current = self.open[d]
    if current.rows == limit {
      self.write(d)
      self.open[d] = PartFile::open(self.format)
    }
    let file = self.open[d]
    let take = if to - at < limit - file.rows {
      to - at
    } else {
      limit - file.rows
    }
    file.push(content.slice(at, length=take))
    at = at + take
  }
}

///|
/// The index of the directory `dir` among the router's, appended when the
/// rows first reach it.
fn PartRouter::directory_index(self : PartRouter, dir : String) -> Int32 {
  for i, known in self.dirs {
    if known == dir {
      return i
    }
  }
  self.dirs.push(dir)
  self.written.push(0)
  self.open.push(PartFile::open(self.format))
  self.dirs.length() - 1
}

///|
/// `dir`'s open file written out: finished, named by its index in the
/// directory, and closed; the next file the directory receives opens
/// fresh.
fn PartRouter::write(
  self : PartRouter,
  d : Int32,
) -> Unit raise @types.DataError {
  let index = self.written[d]
  self.written[d] = index + 1
  let path = self.file_path(d, index)
  make_dirs(self.directory_path(d))
  let file = self.open[d]
  match file.format {
    Parquet(_, _) =>
      @fs.write_bytes_to_file(path, file.parquet.unwrap().finish()) catch {
        @fs.IOError(msg) => raise @types.DataError::IoError(msg)
      }
    Ipc(_, _) => {
      let bytes = file.ipc.unwrap().finish()
      @fs.write_bytes_to_file(path, bytes) catch {
        @fs.IOError(msg) => raise @types.DataError::IoError(msg)
      }
    }
    Csv(_) | Ndjson => write_text(path, file.text.to_string())
  }
}

///|
/// Every open file written: the end of the plan.
fn PartRouter::flush(self : PartRouter) -> Unit raise @types.DataError {
  for d in 0..<self.dirs.length() {
    // A directory whose file never received a row still answers it when
    // the sink has no key to split by.
    if self.open[d].rows > 0 || self.parts.key is None {
      self.write(d)
    }
  }
}

///|
/// The path of `dir`'s file `index`: the base directory, the key's levels,
/// and eight digits with the format's extension.
fn PartRouter::file_path(self : PartRouter, d : Int32, index : Int32) -> String {
  let dir = self.dirs[d]
  let name = "\{eight_digits(index)}\{self.format.extension()}"
  if dir == "" {
    "\{self.base}/\{name}"
  } else {
    "\{self.base}/\{dir}/\{name}"
  }
}

///|
/// `n` as eight digits, zero-padded.
fn eight_digits(n : Int32) -> String {
  let digits = n.to_string()
  let padding = 8 - digits.length()
  let buf = StringBuilder()
  for _ in 0..<padding {
    buf.write_char('0')
  }
  buf.write_string(digits)
  buf.to_string()
}

///|
/// The directory `dir`'s files go in: the base, under the key's levels.
fn PartRouter::directory_path(self : PartRouter, d : Int32) -> String {
  let dir = self.dirs[d]
  if dir == "" {
    self.base
  } else {
    "\{self.base}/\{dir}"
  }
}

///|
/// The directory and every directory above it that does not exist yet, one
/// component a step.
fn make_dirs(dir : String) -> Unit raise @types.DataError {
  // The root's separator starts an absolute path; a relative one starts
  // empty.
  let mut at = if dir.has_prefix("/") { "/" } else { "" }
  for component in dir.split("/") {
    if component.is_empty() {
      continue
    }
    at = joined(at, component)
    if !@fs.path_exists(at) {
      @fs.create_dir(at) catch {
        @fs.IOError(msg) => raise @types.DataError::IoError(msg)
      }
    }
  }
}

///|
/// `component` below `at`: the first of a relative path, beside the root's
/// separator of an absolute one, and under what came before otherwise. The
/// separator already in `at` is the root's own and is not doubled.
fn joined(at : String, component : StringView) -> String {
  if at == "" {
    component.to_owned()
  } else {
    "\{at.trim_end(chars="/")}/\{component}"
  }
}

///|
/// A key value as one path component: the characters a path cannot hold
/// written `%XX` in upper-case hex — a space, the separators `/` and `\`,
/// the hive separator `=`, the escape `%`, the characters Windows forbids
/// (`: * ? " < > |`), a control character — and every byte of the value's
/// UTF-8 encoding that is not ASCII, each spelled the same way.
fn path_component(text : String) -> String {
  let bytes = @utf8.encode(text)
  let buf = StringBuilder()
  for byte in bytes {
    let b = byte.to_int()
    let raw = (b >= 0x30 && b <= 0x39) ||
      (b >= 0x41 && b <= 0x5A) ||
      (b >= 0x61 && b <= 0x7A) ||
      b == 0x2D ||
      b == 0x2E ||
      b == 0x5F ||
      b == 0x7E
    if raw {
      buf.write_char(byte.to_char())
    } else {
      buf.write_char('%')
      buf.write_char(hex_digit(b >> 4))
      buf.write_char(hex_digit(b & 15))
    }
  }
  buf.to_string()
}

///|
/// One upper-case hex digit, for a value from 0 to 15: the digit's or the
/// letter's own code, which the range makes a character.
fn hex_digit(n : Int32) -> Char {
  let code = if n < 10 { n + 48 } else { n + 55 }
  code.unsafe_to_char()
}
