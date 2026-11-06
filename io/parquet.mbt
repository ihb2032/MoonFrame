// The parquet columnar interchange — a native reader and writer over
// the codec in `internal/parquet` (thrift compact metadata, RLE
// definition levels, PLAIN values, UNCOMPRESSED / SNAPPY / GZIP
// compression; the RLE_DICTIONARY encoding reads, the writer emits
// PLAIN). One row group per write, projection pushed into the read.
//
// Round-trip caveat: the riders interchange exactly (DATE, TIMESTAMP as
// TIMESTAMP_MICROS, DECIMAL over INT64 with its scale) — the one
// deliberate narrowing is a written `Duration`, which rides a bare
// INT64 (no standard converted type names a microsecond span) and reads
// back `Int`, exactly like its text round trip.

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
/// parquet `DATE` annotation rides.
pub fn write_parquet(
  df : @frame.DataFrame,
  path : String,
  codec? : ParquetCodec,
) -> Unit raise @types.DataError {
  let chosen = match codec {
    Some(Uncompressed) => @parquet.Codec::Uncompressed
    Some(Snappy) => @parquet.Codec::Snappy
    Some(Gzip) => @parquet.Codec::Gzip
    None => @parquet.Codec::Uncompressed
  }
  let columns = df.column_series()
  let names = columns.map(c => c.name())
  let bytes = @parquet.write_parquet_bytes(columns, names, chosen)
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
  let picked = @parquet.read_parquet_columns(bytes, projection)
  let columns : Array[@series.Series] = []
  for pair in picked {
    columns.push(pair.1)
  }
  // A lenient projection that matches no column still reports the
  // file's rows — the `N×0` shape the text readers' projections yield,
  // not a collapse to zero.
  if columns.length() == 0 {
    @frame.DataFrame::from_parts(columns, @parquet.parquet_num_rows(bytes))
  } else {
    @frame.DataFrame::DataFrame(columns)
  }
}

///|
/// The parquet scan driver: read the bytes, decode the projected
/// columns plus the predicate's own (never anything else), then apply
/// the absorbed predicate and hand back only the projected columns —
/// the row pruning happens after the decode, the column pruning inside
/// it, which is exactly where a columnar source can prune. The
/// predicate's columns ride the decode even when the projection omits
/// them, the same key-column contract the text drivers' pruner
/// honours: the optimizer's projection pass narrows a scan to what its
/// consumers reference, so a pushed predicate reading a pruned column
/// would otherwise filter a frame that no longer carries it. Served to
/// `scan_parquet` in `io/scan.mbt`, which hands the engine the driver
/// record.
fn parquet_scan_driver(path : String) -> @scan.ScanDriver {
  @scan.ScanDriver::driver(() => "PARQUET \"\{@text.escape_debug(path)}\"", (
    projection,
    predicate,
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
    let frame = match decoded {
      Some(names) => parse_parquet(bytes, projection=names)
      None => parse_parquet(bytes)
    }
    let kept = match predicate {
      Some(pred) => frame.filter(pred)
      None => frame
    }
    // The projected columns in the file's own schema order (a name the
    // file does not carry builds no column, and the batch's separately
    // carried height keeps the rows — the `N×0` shape).
    let columns : Array[@series.Series] = match projection {
      Some(cols) => kept.column_series().filter(s => cols.contains(s.name()))
      None => kept.column_series()
    }
    @scan.ScanBatch::batch(columns, kept.nrows())
  })
}
