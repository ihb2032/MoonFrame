// The lazy sinks: a plan's streaming face turned to a file —
// `collect_batches` with the consumer being an encoder. The execution
// rides the pipeline batch by batch (a frame is held only as long as
// its batch); the encoded bytes accumulate and land on disk in one
// write, the closest a platform with whole-file writes only comes to
// Polars' incrementally flushed sinks. The results are exactly
// `collect` then `write_*` — the same rows, the same order, the same
// first error — with the whole result never sitting in memory as a
// frame.

///|
/// Run a lazy plan and write its result as one parquet file, batch by
/// batch: each batch lands as its own row group (split further inside
/// the batch at `row_group_rows`, the `write_parquet` bound — a group
/// never spans batches, so the file's layout follows the pipeline's own
/// batch boundaries). The columns are the first batch's — every batch
/// agrees with them, name and dtype, the way `vstack` demands; a
/// decimal column's interchange window is the first batch's too, and a
/// later batch needing a wider one refuses rather than silently
/// narrowing. Raises the read's own `DataError` — the same error, on
/// the same first offending batch, `collect` would raise — plus the
/// writer's own refusals (a dtype the mapping does not carry, a decimal
/// cell past the interchange window) and the file write's `IoError`.
/// Nothing is read until the first batch is pulled.
///
/// `optimizations` defaults to the same every-stage-on pipeline
/// `collect` runs.
pub fn sink_parquet(
  lf : @frame.LazyFrame,
  path : String,
  codec? : ParquetCodec,
  row_group_rows~ : Int32 = 0,
  optimizations~ : @frame.Optimizations = @frame.Optimizations::Optimizations(),
) -> Unit raise @types.DataError {
  let chosen = match codec {
    Some(Uncompressed) => @parquet.Codec::Uncompressed
    Some(Snappy) => @parquet.Codec::Snappy
    Some(Gzip) => @parquet.Codec::Gzip
    None => @parquet.Codec::Uncompressed
  }
  let sink = @parquet.ParquetSink::sink(
    chosen,
    group_rows=row_group_rows.to_int64(),
  )
  let stream = lf.collect_batches(optimizations~)
  while true {
    match stream.next() {
      Some(batch) => sink.push(batch.column_series())
      None => break
    }
  }
  @fs.write_bytes_to_file(path, sink.finish()) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// Run a lazy plan and write its result as one CSV file, batch by
/// batch: the header (when `options.header`) rides the first batch and
/// never repeats, and each batch's rows render through the same
/// quoting / null / formula-sanitising rules `format_csv` spells — the
/// file is byte-for-byte `format_csv(collect())` for the same options.
/// A plan whose result is no batch at all (an empty read) writes the
/// empty file. Raises the read's own `DataError` and the writer's own
/// (the delimiter refusal, the rows-but-no-columns shape), plus the
/// file write's `IoError`. Nothing is read until the first batch is
/// pulled.
///
/// `optimizations` defaults to the same every-stage-on pipeline
/// `collect` runs.
pub fn sink_csv(
  lf : @frame.LazyFrame,
  path : String,
  options~ : CsvWriteOptions = CsvWriteOptions::CsvWriteOptions(),
  optimizations~ : @frame.Optimizations = @frame.Optimizations::Optimizations(),
) -> Unit raise @types.DataError {
  validate_csv_delimiter(options.delimiter)
  let rows = StringBuilder()
  let later = CsvWriteOptions::CsvWriteOptions(
    header=false,
    delimiter=options.delimiter,
    null_value=options.null_value,
    sanitize_formulas=options.sanitize_formulas,
    line_terminator=options.line_terminator,
  )
  let stream = lf.collect_batches(optimizations~)
  let mut first = true
  while true {
    match stream.next() {
      Some(batch) => {
        let text = if first {
          first = false
          format_csv(batch, options~)
        } else {
          format_csv(batch, options=later)
        }
        rows.write_string(text)
      }
      None => break
    }
  }
  @fs.write_string_to_file(path, rows.to_string()) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// Run a lazy plan and write its result as one Arrow IPC payload, batch
/// by batch: each batch lands as its own record batch, so the payload's
/// layout follows the pipeline's own batch boundaries. The columns are the
/// first batch's — every batch agrees with them, name and dtype, the way
/// `vstack` demands — and every decimal column's precision and scale are
/// the first batch's too: a later batch whose decimal cells need a wider
/// window refuses rather than narrowing. `format` picks the framing (the
/// file format by default) and `compression` the codec every buffer is
/// compressed with. A plan whose result is no batch at all writes a
/// payload of an empty schema. Raises the read's own `DataError` — the
/// same error, on the same first offending batch, `collect` would raise —
/// plus the writer's own refusals and the file write's `IoError`. Nothing
/// is read until the first batch is pulled.
///
/// `optimizations` defaults to the same every-stage-on pipeline
/// `collect` runs.
pub fn sink_ipc(
  lf : @frame.LazyFrame,
  path : String,
  compression~ : IpcCompression = IpcCompression::Uncompressed,
  format~ : IpcFormat = IpcFormat::File,
  optimizations~ : @frame.Optimizations = @frame.Optimizations::Optimizations(),
) -> Unit raise @types.DataError {
  let sink = @ipc.IpcSink::sink(ipc_codec(compression), file=ipc_file(format))
  let stream = lf.collect_batches(optimizations~)
  while true {
    match stream.next() {
      Some(batch) => sink.push(batch.column_series(), height=batch.nrows())
      None => break
    }
  }
  // The payload is finished before the write is in sight: its own refusal
  // is the writer's, and the catch below is for the write's alone.
  let bytes = sink.finish()
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// Run a lazy plan and write its result as one JSON records file, batch
/// by batch: each batch's rows render as the record objects `format_json`
/// spells — the same cells under the same cell conventions, keys in
/// column order — and the batches' records share one top-level array, so
/// the file is byte-for-byte `format_json(collect())`. A plan that answers
/// no row writes `[]`. The text goes through the file writer `write_json`
/// uses: a path ending in `.gz` receives the gzip-compressed encoding, and
/// a string cell or column name holding an unpaired UTF-16 surrogate is
/// refused with `InvalidOperation` rather than written as a file the UTF-8
/// encoding would corrupt. Raises the read's own `DataError` — the same
/// error, on the same first offending batch, `collect` would raise — and,
/// the text being written only once the plan has answered in full, a read
/// error always comes before that refusal; the file write's own failure
/// is `IoError`. Nothing is read until the first batch is pulled.
///
/// `optimizations` defaults to the same every-stage-on pipeline
/// `collect` runs.
pub fn sink_json(
  lf : @frame.LazyFrame,
  path : String,
  optimizations~ : @frame.Optimizations = @frame.Optimizations::Optimizations(),
) -> Unit raise @types.DataError {
  let stream = lf.collect_batches(optimizations~)
  let text = StringBuilder()
  // One array over every batch: a record is separated from the one before
  // it by a single comma, whichever batch either came from — the framing
  // `format_json` gets from stringifying the whole records array at once.
  let mut first = true
  text.write_char('[')
  while true {
    match stream.next() {
      Some(batch) =>
        for record in df_to_json_records(batch) {
          if !first {
            text.write_char(',')
          }
          first = false
          text.write_string(record.stringify())
        }
      None => break
    }
  }
  text.write_char(']')
  write_text(path, text.to_string())
}

///|
/// Run a lazy plan and write its result as one NDJSON file, batch by
/// batch: each batch's rows render as the lines `format_ndjson` spells —
/// one JSON object per row, keys in column order, each line terminated by
/// a newline — and a line ends with its own newline whatever batch it came
/// from, so the file is byte-for-byte `format_ndjson(collect())`. A plan
/// that answers no row writes the empty file. The text goes through the
/// file writer `write_ndjson` uses: a path ending in `.gz` receives the
/// gzip-compressed encoding, and a string cell or column name holding an
/// unpaired UTF-16 surrogate is refused with `InvalidOperation` rather
/// than written as a file the UTF-8 encoding would corrupt. Raises the
/// read's own `DataError` — the same error, on the same first offending
/// batch, `collect` would raise — and, the text being written only once
/// the plan has answered in full, a read error always comes before that
/// refusal; the file write's own failure is `IoError`. Nothing is read
/// until the first batch is pulled.
///
/// `optimizations` defaults to the same every-stage-on pipeline
/// `collect` runs.
pub fn sink_ndjson(
  lf : @frame.LazyFrame,
  path : String,
  optimizations~ : @frame.Optimizations = @frame.Optimizations::Optimizations(),
) -> Unit raise @types.DataError {
  let stream = lf.collect_batches(optimizations~)
  let text = StringBuilder()
  while true {
    match stream.next() {
      Some(batch) => text.write_string(format_ndjson(batch))
      None => break
    }
  }
  write_text(path, text.to_string())
}
