// The Arrow IPC columnar interchange — a native reader and writer over
// the codec in `internal/ipc`: hand-written FlatBuffers metadata, the
// stream framing and the file framing, dictionary batches decoded to
// plain columns, and LZ4 / Zstandard buffer compression. A read takes
// both framings, every metadata version through V5, and either
// endianness; a write takes the file framing unless the stream framing is
// asked for.
//
// Round-trip caveats — the interchange by value, under Arrow's types:
// - An integer column is written `int64` and a float `double`, whatever
//   width a read met; a `String` column written over a binary column
//   comes back `utf8`.
// - A `Date` is a `date32`; a `Timestamp` is a `timestamp[us]` with no
//   time zone (a zoned column reads as the instants it holds and writes
//   back zone-less); a `Duration` is a `duration[us]`.
// - A decimal column is one `decimal128` at one scale — the most fraction
//   digits its cells count. A cell that counts fewer is lifted to that
//   scale and reads back there: the value is its own, the trailing zero
//   is not.
// - A large list and a fixed-size list are written plain lists.
// - Every field is nullable, and no column is dictionary-encoded.

///|
/// The compression a written payload's buffers carry. A reader inflates
/// every codec it can, whichever this names.
#derive(Eq, Debug)
pub(all) enum IpcCompression {
  Uncompressed
  Lz4
  Zstd
}

///|
pub extend IpcCompression with Eq::{equal, not_equal}

///|
pub extend IpcCompression with Debug::{to_repr}

///|
/// The framing a written payload takes.
#derive(Eq, Debug)
pub(all) enum IpcFormat {
  /// The file format: the messages between an `ARROW1` marker at each
  /// end, closed by a footer that repeats the schema and indexes every
  /// batch.
  File
  /// The stream format: the messages alone, closed by an end marker —
  /// written and read in one pass.
  Stream
}

///|
pub extend IpcFormat with Eq::{equal, not_equal}

///|
pub extend IpcFormat with Debug::{to_repr}

///|
/// Whether a format is the file format.
fn ipc_file(format : IpcFormat) -> Bool {
  match format {
    File => true
    Stream => false
  }
}

///|
fn ipc_codec(compression : IpcCompression) -> @ipc.BodyCodec? {
  match compression {
    Uncompressed => None
    Lz4 => Some(Lz4Frame)
    Zstd => Some(Zstd)
  }
}

///|
/// Write a frame as one Arrow IPC payload: one schema message and one
/// record batch. `format` picks the framing (the file format by default),
/// and `compression` the codec every buffer is compressed with — a buffer
/// the frame does not make shorter is stored as it is. Raises
/// `InvalidOperation` for what the interchange does not carry: a NaN or
/// infinite decimal cell, a decimal column whose cells leave the
/// 38-digit window, or a column name, a struct field name, or a string
/// cell holding an unpaired UTF-16 surrogate, which has no UTF-8
/// spelling to write. Raises `IoError` for the file write.
pub fn write_ipc(
  df : @frame.DataFrame,
  path : String,
  compression~ : IpcCompression = IpcCompression::Uncompressed,
  format~ : IpcFormat = IpcFormat::File,
) -> Unit raise @types.DataError {
  let bytes = @ipc.write_ipc_bytes(
    df.column_series(),
    ipc_codec(compression),
    file=ipc_file(format),
    height=df.nrows(),
  )
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// Read an Arrow IPC file into a frame — the file framing or the stream
/// framing, whichever the bytes open with. The schema message names the
/// dtypes and every record batch decodes, its cells appended to the
/// columns; the projection (every column when `projection?` is omitted)
/// leaves the other columns' buffers unread. The projection is lenient
/// like the other readers': a name the payload does not carry builds no
/// column, and whichever expression references it raises
/// `ColumnNotFound`.
///
/// An Arrow type reads as the dtype that holds it: every integer width as
/// `Int`, both float widths as `Float`, `utf8` and `binary` as `String` (a
/// binary column only while its bytes are UTF-8), a day date as `Date`, a
/// millisecond date and every timestamp as `Timestamp` in microseconds, a
/// duration as `Duration`, a `decimal128` as `Decimal`, the list kinds and
/// `map` as `List`, `struct` as `Struct`, a dictionary-encoded column as
/// its values, and a null column as an all-null `String` column.
///
/// Raises:
/// - `Unsupported` for a type with no dtype to read as — a time of day,
///   an interval, a union, a run-end-encoded or view type, a `float16`, a
///   `decimal256` — and for a cell the dtype cannot hold: a `uint64` past
///   `Int64`, a nanosecond count off a whole microsecond, a decimal past
///   34 significant digits. A type is refused when its column is read,
///   so a projection that leaves it out reads the rest.
/// - `ParseError(Message(...))` for a malformed payload, a buffer that
///   does not inflate, or a cell that is not UTF-8.
/// - `InvalidOperation` for a null column, or a whole payload, past the
///   cell budget a column is read within (134,217,728 cells).
/// - `DuplicateColumn(name)` for two chosen columns of one name.
/// - `IoError` for the file read.
pub fn read_ipc(
  path : String,
  projection? : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  parse_ipc(bytes, projection?)
}

///|
/// Parse Arrow IPC bytes into a frame — the file-level entry's
/// binary counterpart (what `read_ipc` hands the codec, exposed for
/// in-memory bytes). The same contract as `read_ipc`'s.
pub fn parse_ipc(
  bytes : Bytes,
  projection? : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let (picked, rows) = @ipc.read_ipc_frame(bytes, projection)
  let columns : Array[@series.Series] = []
  for pair in picked {
    columns.push(pair.1)
  }
  // A lenient projection that matches no column still reports the
  // payload's rows — the `N×0` shape the other readers' projections
  // yield.
  if columns.is_empty() {
    @frame.DataFrame::from_parts(columns, rows.to_int())
  } else {
    @frame.DataFrame::DataFrame(columns)
  }
}

///|
/// The Arrow IPC scan driver: read the bytes once, then hand out the
/// payload's record batches as its batches — the decode carrying the
/// projected columns plus the predicate's own (never anything else), and
/// a batch outside an absorbed window skipped without being decoded. A
/// batch the window only partly covers decodes and cuts to the overlap.
/// The row pruning happens after the decode, the column pruning inside
/// it. The predicate's columns ride the decode even when the projection
/// omits them, the key-column contract every driver honours. Served to
/// the io layer's `scan_ipc` source.
fn ipc_scan_driver(path : String) -> @scan.ScanDriver {
  @scan.ScanDriver::driver(
    () => "IPC \"\{@text.escape_debug(path)}\"",
    (projection, predicate, window) => {
      let bytes = @fs.read_file_to_bytes(path) catch {
        @fs.IOError(msg) => raise @types.DataError::IoError(msg)
      }
      let decoded : Array[String]? = match (projection, predicate) {
        (Some(cols), Some(pred)) => {
          let union : Array[String] = []
          for c in cols {
            union.push(c)
          }
          for c in pred.referenced_columns() {
            if !union.contains(c) {
              union.push(c)
            }
          }
          Some(union)
        }
        (Some(cols), None) => Some(cols)
        (None, _) => None
      }
      let reader = @ipc.open_ipc(bytes, decoded)
      let total = reader.total_rows()
      let (w0, wlen) = match window {
        Some(w) => w.resolve(total.to_int())
        None => (0, total.to_int())
      }
      // One batch's frame to the batch the engine reads: the absorbed
      // predicate filters the batch's rows, then the projection keeps its
      // columns in the payload's own schema order (a name the payload does
      // not carry builds no column, and the batch's separately carried
      // height keeps the rows — the `N×0` shape).
      let to_batch : (@frame.DataFrame) -> @scan.ScanBatch raise @types.DataError = frame => {
        let kept = match predicate {
          Some(pred) => frame.filter(pred)
          None => frame
        }
        let out : Array[@series.Series] = match projection {
          Some(cols) =>
            kept.column_series().filter(s => cols.contains(s.name()))
          None => kept.column_series()
        }
        @scan.ScanBatch::batch(out, kept.nrows())
      }
      // The cursor's place: the next batch index, the rows before that
      // batch, and whether any batch has left yet — array cells, so the
      // step closure sees its own earlier answers on every later call.
      let place : Array[Int32] = [0, 0]
      let emitted : Array[Bool] = [false]
      @scan.BatchCursor::cursor(() => {
        let batches = reader.batch_count()
        let mut i = place[0]
        let mut rows_before = place[1]
        // Skip the batches that end at or before the window's start —
        // their bodies are never decoded.
        while i < batches {
          let grows = reader.batch_rows(i)
          if rows_before + grows <= w0 {
            reader.skip_batch()
            i += 1
            rows_before += grows
          } else {
            break
          }
        }
        // Past the last batch, or the window entirely behind us: done —
        // unless nothing has left yet, in which case the read still
        // answers its columns: one zero-row batch over the schema, the
        // `0×N` shape an eager read-then-window yields.
        if i >= batches || rows_before >= w0 + wlen {
          if emitted[0] {
            return None
          }
          emitted[0] = true
          let empty = @frame.DataFrame::from_parts(reader.empty_columns(), 0)
          return Some(to_batch(empty))
        }
        emitted[0] = true
        // A batch is counted before it is taken, so the reader always has
        // one to give: the batches skipped above were stepped over unread.
        let columns = reader.take_batch()
        let grows = reader.batch_rows(i)
        place[0] = i + 1
        place[1] = rows_before + grows
        // The window's overlap with this batch — a batch the window cuts
        // through keeps only the overlapping rows of every column.
        let lo = if w0 > rows_before { w0 - rows_before } else { 0 }
        let hi = if w0 + wlen - rows_before < grows {
          w0 + wlen - rows_before
        } else {
          grows
        }
        let cut : Array[@series.Series] = []
        let rows = if lo > 0 || hi < grows {
          for column in columns {
            cut.push(column.slice_series(lo, hi - lo))
          }
          hi - lo
        } else {
          for column in columns {
            cut.push(column)
          }
          grows
        }
        Some(to_batch(@frame.DataFrame::from_parts(cut, rows)))
      })
    },
    absorbs_window=true,
  )
}

///|
/// The lazy Arrow IPC source: `scan_ipc(path)` builds a `LazyFrame` whose
/// leaf is a deferred read of `path` — the push-down-aware counterpart of
/// eager `read_ipc`. Nothing is read until `collect` (the builder is
/// total). The **projection** push-down narrows the leaf to the columns
/// the pipeline consumes, and only those decode — a type the mapping
/// refuses in an unprojected column does not surface, the same dropped
/// column a text scan never parses. The **predicate** push-down moves the
/// filter into the read as a post-decode filter over the projected frame;
/// the predicate's own columns ride the decode even when the projection
/// omits them. The **window** push-down sinks a `head` / `tail` / `slice`
/// into the read itself: the window resolves against the payload's row
/// count and the record batches outside it are skipped outright — never
/// decoded — while a batch the window only partly covers decodes and cuts
/// to the overlap, so a refusal confined to a skipped batch does not
/// surface, the same skipping trade the projection push-down makes for
/// columns; the surviving rows are exactly the eager read's. The dtypes
/// come from the payload's schema, so a narrowed scan matches the eager
/// read exactly — and the schema can name temporal columns no plan-time
/// fact can rule out, so this source takes the temporal value-fence's
/// conservative arm: a predicate or stage expression carrying a
/// temporal-checked operation stays above the scan, trading that
/// push-down for a failing plan still failing.
pub fn scan_ipc(path : String) -> @frame.LazyFrame {
  @frame.LazyFrame::file_scan(ipc_scan_driver(path), may_carry_temporal=true)
}
