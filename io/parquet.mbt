// The parquet columnar interchange — a native reader and writer over
// the codec in `internal/parquet` (thrift compact metadata, RLE
// definition levels, PLAIN values, UNCOMPRESSED / SNAPPY / GZIP
// compression; the RLE_DICTIONARY encoding reads, the writer emits
// PLAIN). One row group per write, projection pushed into the read.
//
// Round-trip caveat: the riders interchange by value (DATE, TIMESTAMP as
// TIMESTAMP_MICROS, DECIMAL over INT64 precision 18 or, past that
// window, FIXED_LEN_BYTE_ARRAY(16) precision 38, with its scale) — the
// one deliberate narrowing is a written `Duration`, which rides a bare
// INT64 (no standard converted type names a microsecond span) and reads
// back `Int`, exactly like its text round trip. The reader also takes
// the foreign DECIMAL shapes the writer never emits: `INT32` (precision
// up to 9) and the legacy variable-width `BYTE_ARRAY`.

///|
/// The compression a written parquet file carries (the reader takes
/// every codec it can decode; this names the writer's).
#derive(Eq, Debug)
pub(all) enum ParquetCodec {
  Uncompressed
  Snappy
  Gzip
}

///|
pub extend ParquetCodec with Eq::{equal, not_equal}

///|
pub extend ParquetCodec with Debug::{to_repr}

///|
/// Write a frame as one parquet file. Raises `Unsupported` for a column
/// whose dtype the mapping does not carry (a `Null` column) and
/// `InvalidOperation` for a `Date` day count outside the INT32 the
/// parquet `DATE` annotation rides, for a `Decimal` cell whose NaN / ±∞
/// shape has no fixed-point spelling, and for a decimal column past the
/// 38-digit payload window.
///
/// `row_group_rows` spells the row-group layout: the default `0` writes
/// the whole frame as one row group, a positive bound writes consecutive
/// groups of that many rows with the last one the remainder — the layout
/// a foreign columnar reader pages through, and the batch boundaries a
/// lazy `scan_parquet` reads group by group. A bound at or past the
/// height is the single group again.
pub fn write_parquet(
  df : @frame.DataFrame,
  path : String,
  codec? : ParquetCodec,
  row_group_rows~ : Int32 = 0,
) -> Unit raise @types.DataError {
  let chosen = match codec {
    Some(Uncompressed) => @parquet.Codec::Uncompressed
    Some(Snappy) => @parquet.Codec::Snappy
    Some(Gzip) => @parquet.Codec::Gzip
    None => @parquet.Codec::Uncompressed
  }
  let columns = df.column_series()
  let names = columns.map(c => c.name())
  let bytes = @parquet.write_parquet_bytes(
    columns,
    names,
    chosen,
    group_rows=row_group_rows.to_int64(),
  )
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// Read a parquet file into a frame: the footer's schema names the
/// dtypes, each column chunk decodes its pages, and the projection
/// (every column when `projection?` is omitted) rides into the chunk
/// walk — unprojected columns are never parsed. The projection is
/// lenient like the text readers': a name the file does not carry
/// builds no column (a projection matching no column yields the file's
/// rows over zero columns), and whichever expression references the
/// missing name raises `ColumnNotFound`, the same error a full read
/// plus a select would. Also raises `Unsupported` for a dtype or
/// encoding the mapping does not carry (a `FLOAT` column would narrow;
/// a nested or dictionary-only page shape decodes or names itself) and
/// `ParseError` for a malformed file.
pub fn read_parquet(
  path : String,
  projection? : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  parse_parquet(bytes, projection?)
}

///|
/// Parse parquet bytes into a frame — the string-level entry's binary
/// counterpart (what `read_parquet` hands the codec, exposed for
/// in-memory bytes). The same contract as `read_parquet`'s.
pub fn parse_parquet(
  bytes : Bytes,
  projection? : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  // The footer is parsed once — the picked columns and the declared row
  // count both come off the same walk.
  let (picked, nrows) = @parquet.read_parquet_frame(bytes, projection)
  let columns : Array[@series.Series] = []
  for pair in picked {
    columns.push(pair.1)
  }
  // A lenient projection that matches no column still reports the
  // file's rows — the `N×0` shape the text readers' projections yield,
  // not a collapse to zero.
  if columns.length() == 0 {
    @frame.DataFrame::from_parts(columns, nrows)
  } else {
    @frame.DataFrame::DataFrame(columns)
  }
}

///|
/// The parquet scan driver: read the bytes once, then walk the file's
/// row groups as its batches — one group per `next`, the decode
/// carrying the projected columns plus the predicate's own (never
/// anything else). An absorbed window resolves against the footer's own
/// row count and skips the groups outside it outright (the one row
/// pruning a columnar file without row-group statistics offers past the
/// projection); a group the window only partly covers decodes and cuts
/// to the overlap. The row pruning happens after the decode, the column
/// pruning inside it, which is exactly where a columnar source can
/// prune. The predicate's columns ride the decode even when the
/// projection omits them, the same key-column contract the text
/// drivers' pruner honours: the optimizer's projection pass narrows a
/// scan to what its consumers reference, so a pushed predicate reading
/// a pruned column would otherwise filter a frame that no longer
/// carries it. Served to the io layer's `scan_parquet` source, which
/// hands the engine the driver record.
fn parquet_scan_driver(path : String) -> @scan.ScanDriver {
  @scan.ScanDriver::driver(() => "PARQUET \"\{@text.escape_debug(path)}\"", (
    projection,
    predicate,
    window,
  ) => {
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
    let reader = match decoded {
      Some(names) =>
        @parquet.ParquetGroupReader::group_reader(bytes, Some(names))
      None => @parquet.ParquetGroupReader::group_reader(bytes, None)
    }
    // The window as an absolute [start, start + len) row range against
    // the file's declared rows — `resolve` saturates exactly as the
    // eager window verbs do, and start + len stays inside the row count,
    // so the Int32 arithmetic below cannot wrap.
    let total = reader.total_rows()
    let (w0, wlen) = match window {
      Some(w) => w.resolve(total)
      None => (0, total)
    }
    // The cursor's place: the next group index, and the rows before that
    // group — array cells, so the step closure sees its own earlier
    // answers on every later call.
    let place : Array[Int32] = [0, 0]
    @scan.BatchCursor::cursor(() => {
      let groups = reader.group_count()
      let mut i = place[0]
      let mut rows_before = place[1]
      // Skip the groups that end at or before the window's start — their
      // chunks are never asked for.
      while i < groups {
        let grows = reader.group_rows(i)
        if rows_before + grows <= w0 {
          i = i + 1
          rows_before = rows_before + grows
        } else {
          break
        }
      }
      // Past the last group, or the window entirely behind us: done.
      if i >= groups || rows_before >= w0 + wlen {
        return None
      }
      let (pairs, grows) = reader.decode_group(i)
      place[0] = i + 1
      place[1] = rows_before + grows
      // The window's overlap with this group — a group the window cuts
      // through keeps only the overlapping rows of every column.
      let lo = if w0 > rows_before { w0 - rows_before } else { 0 }
      let hi = if w0 + wlen - rows_before < grows {
        w0 + wlen - rows_before
      } else {
        grows
      }
      let columns : Array[@series.Series] = []
      let rows = if lo > 0 || hi < grows {
        for pair in pairs {
          columns.push(pair.1.slice_series(lo, hi - lo))
        }
        hi - lo
      } else {
        for pair in pairs {
          columns.push(pair.1)
        }
        grows
      }
      let frame = @frame.DataFrame::from_parts(columns, rows)
      let kept = match predicate {
        Some(pred) => frame.filter(pred)
        None => frame
      }
      // The projected columns in the file's own schema order (a name the
      // file does not carry builds no column, and the batch's separately
      // carried height keeps the rows — the `N×0` shape).
      let out : Array[@series.Series] = match projection {
        Some(cols) => kept.column_series().filter(s => cols.contains(s.name()))
        None => kept.column_series()
      }
      Some(@scan.ScanBatch::batch(out, kept.nrows()))
    })
  })
}
