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

///|
/// The lazy source over an ORC file: the file's stripes are its batches,
/// one a `next`. A pushed-down projection names the columns decoded, a
/// pushed-down window the stripes read — the others are skipped without
/// being decoded — and a pushed-down predicate filters each stripe's rows
/// once it is read. The frame a collected plan answers is the frame
/// `read_orc` answers under the same projection and predicate, and the
/// read's errors are `parse_orc`'s, raised where the read happens.
pub fn scan_orc(path : String) -> @frame.LazyFrame {
  @frame.LazyFrame::file_scan(orc_scan_driver(path), may_carry_temporal=true)
}

///|
/// The ORC scan driver: the bytes read once, then the file's stripes
/// walked as its batches — one stripe per `next`, the decode carrying the
/// projected columns plus the predicate's own, never anything else. An
/// absorbed window resolves against the footer's row count and skips the
/// stripes outside it outright; a stripe the window only partly covers
/// decodes and cuts to the overlap. The predicate filters each stripe's
/// rows after the decode, the column pruning happening inside it — where a
/// columnar source can prune. The predicate's columns ride the decode even
/// when the projection omits them, the key-column contract every scan
/// driver honours: the optimizer's projection pass narrows a scan to what
/// its consumers reference, so a pushed predicate reading a pruned column
/// would otherwise filter a frame that no longer carries it. Served to
/// `scan_orc`.
fn orc_scan_driver(path : String) -> @scan.ScanDriver {
  @scan.ScanDriver::driver(
    () => "ORC \"\{@text.escape_debug(path)}\"",
    (projection, predicate, window) => {
      let bytes = @fs.read_file_to_bytes(path) catch {
        @fs.IOError(msg) => raise @types.DataError::IoError(msg)
      }
      let stripe_rows = @orc.orc_stripe_rows(bytes)
      // The file's row count is the sum of its stripes'. Every count, the
      // sum included, is one a frame's height holds — the file's own
      // refusal otherwise — so the arithmetic below cannot wrap.
      let mut total = 0
      for rows in stripe_rows {
        total = total + rows
      }
      // The window as an absolute [start, start + len) row range against
      // the footer's rows — `resolve` saturates exactly as the eager
      // window verbs do.
      let (w0, wlen) = match window {
        Some(w) => w.resolve(total)
        None => (0, total)
      }
      // The columns decoded: the projection's, with the predicate's own
      // beside them.
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
      // One stripe's frame to the batch the engine reads: the absorbed
      // predicate filters the stripe's rows, then the projection keeps its
      // columns in the file's own order (a name the file does not carry
      // builds no column, and the batch's separately carried height keeps
      // the rows — the `N×0` shape).
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
      // The cursor's place: the next stripe, the rows before that stripe,
      // and whether any batch has left yet — array cells, so the step
      // closure sees its own earlier answers on every later call.
      let place : Array[Int32] = [0, 0]
      let emitted : Array[Bool] = [false]
      @scan.BatchCursor::cursor(() => {
        let stripes = stripe_rows.length()
        let mut i = place[0]
        let mut rows_before = place[1]
        // Skip the stripes that end at or before the window's start —
        // their streams are never decoded.
        while i < stripes {
          let srows = stripe_rows[i]
          if rows_before + srows <= w0 {
            i = i + 1
            rows_before = rows_before + srows
          } else {
            break
          }
        }
        // Past the last stripe, or the window entirely behind us: done —
        // unless nothing has left yet, in which case the read still
        // answers its columns: one zero-row batch over the fields, the
        // `0×N` shape an eager read-then-window yields.
        if i >= stripes || rows_before >= w0 + wlen {
          if emitted[0] {
            return None
          }
          emitted[0] = true
          let fields = match decoded {
            Some(names) => @orc.orc_fields(bytes, projection=names)
            None => @orc.orc_fields(bytes)
          }
          let empty = fields.map(field => {
            @series.Series::from_scalars(field.name(), [], dtype=field.dtype())
          })
          return Some(to_batch(@frame.DataFrame::from_parts(empty, 0)))
        }
        emitted[0] = true
        let (pairs, srows) = match decoded {
          Some(names) => @orc.read_orc_stripe(bytes, i, projection=names)
          None => @orc.read_orc_stripe(bytes, i)
        }
        place[0] = i + 1
        place[1] = rows_before + srows
        // The window's overlap with this stripe — a stripe the window cuts
        // through keeps only the overlapping rows of every column.
        let lo = if w0 > rows_before { w0 - rows_before } else { 0 }
        let hi = if w0 + wlen - rows_before < srows {
          w0 + wlen - rows_before
        } else {
          srows
        }
        let columns : Array[@series.Series] = []
        let rows = if lo > 0 || hi < srows {
          for pair in pairs {
            columns.push(pair.1.slice_series(lo, hi - lo))
          }
          hi - lo
        } else {
          for pair in pairs {
            columns.push(pair.1)
          }
          srows
        }
        Some(to_batch(@frame.DataFrame::from_parts(columns, rows)))
      })
    },
    absorbs_window=true,
  )
}
