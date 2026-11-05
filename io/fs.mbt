// File-system access for the IO readers and writers: the single place that
// translates `@fs`'s `IOError` into the library's `DataError::IoError`, so the
// `read_*` / `write_*` entry points don't each repeat the catch. It is also
// the one place compressed files change shape: a read whose bytes carry the
// gzip magic is decompressed before the UTF-8 decode (under the output cap
// below), and a write to a `.gz`-suffixed path compresses the encoded
// bytes — every reader, writer, and lazy scan inherits both through the two
// choke points below.
//
// The per-format suites and the surrogate-refusal corpus cover this shared
// plumbing end to end (file-backed `read_csv` / `write_csv` / `write_json` /
// `write_ndjson`); the output cap's own refusal needs the private
// parameterised entry, so it lives in `fs_wbtest.mbt`.

///|
/// Read a whole file as a string, mapping a file-system `IOError` to
/// `DataError::IoError` and a byte sequence that is not UTF-8 to
/// `DataError::ParseError`. Shared by every `read_*` entry point. A file
/// whose first two bytes are the gzip magic (`1f 8b`) is decompressed
/// first, so a compressed source reads exactly like its plain twin. The
/// decode is strict on purpose: a lenient decoder merges a stray byte with
/// the ones after it — swallowing a delimiter or a quote and shifting
/// every cell boundary that follows — or silently drops the rest of the
/// file, so a non-UTF-8 file would read as confidently wrong data.
/// Refusing up front matches `validate_csv_delimiter`'s philosophy: reject
/// a read that cannot round-trip rather than corrupt the data silently.
fn read_text(path : String) -> String raise @types.DataError {
  let bytes = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  let text_bytes = gunzip_bytes(path, bytes)
  @utf8.decode(text_bytes) catch {
    // The error carries the bytes from the first malformed one, so that
    // byte's offset is the difference in length.
    @utf8.Malformed(tail) =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "file \{path} is not valid UTF-8: first malformed byte at offset \{text_bytes.length() - tail.length()}",
        ),
      )
  }
}

///|
/// The most decompressed bytes one gzip read may produce — the
/// decompression-bomb guard, aligned with the parquet SNAPPY codec's own
/// 1 GiB declared-length cap (`snappy_decompress`'s `0x4000_0000`). A
/// compressed file of a few megabytes can name gigabytes of payload; past
/// this cap the read refuses instead of letting the expansion run the
/// process out of memory.
const GUNZIP_MAX_OUTPUT : Int32 = 0x4000_0000

///|
/// Decompress `bytes` when they open with the gzip magic (`1f 8b`), pass
/// them through otherwise. A stream that claims the magic but does not
/// decompress — truncated, corrupt header, failed checksum — raises
/// `ParseError` naming the file: the content cannot be read as written, so
/// refusing beats handing the decompressor's bytes to a parser that would
/// read them as confidently wrong cells. The sniff is on the content, not
/// the file name, so a misnamed source still reads and a plain file that
/// happens to sit under a `.gz` name is not mistaken for one.
///
/// The output rides a cap, enforced by the inflater itself
/// (`@gzip.decompress`'s `max_output`), never by the trailer's declared
/// ISIZE: that 4-byte little-endian length is best-effort by format —
/// stored modulo 2^32, so an expansion can wrap it to any value, and a
/// multi-member stream declares only its *last* member's length — so a
/// bomb can name a small size as freely as an honest file names its real
/// one. Only the count of bytes actually produced cannot lie; past
/// `GUNZIP_MAX_OUTPUT` of them the read refuses with `ParseError` naming
/// the cap (the stream may be perfectly valid — its expansion is simply
/// past what one read accepts).
fn gunzip_bytes(path : String, bytes : Bytes) -> Bytes raise @types.DataError {
  gunzip_bytes_capped(path, bytes, GUNZIP_MAX_OUTPUT)
}

///|
/// `gunzip_bytes` with the output cap as a parameter — production reads
/// pass `GUNZIP_MAX_OUTPUT`; the whitebox tests pass a small one, because
/// inflating a real gigabyte past the production cap is exactly the cost
/// the guard exists to spare.
fn gunzip_bytes_capped(
  path : String,
  bytes : Bytes,
  cap : Int32,
) -> Bytes raise @types.DataError {
  if bytes.length() < 2 || bytes[0] != b'\x1f' || bytes[1] != b'\x8b' {
    return bytes
  }
  @gzip.decompress(bytes, max_output=cap) catch {
    // The cap's refusal, kept apart from the malformed-stream arm: the
    // message names the cap rather than claiming the stream is invalid.
    @gzip.GzipError(OutputLimitExceeded(limit~, observed~), _detail) =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "file \{path} inflates past the \{limit}-byte decompression cap (already \{observed} bytes produced); refusing the read",
        ),
      )
    @gzip.GzipError(_kind, detail) =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "file \{path} is not a valid gzip stream: \{detail}",
        ),
      )
  }
}

///|
/// Write a string to a file, mapping a file-system `IOError` to
/// `DataError::IoError`. Shared by every `write_*` entry point — io's own
/// and the chart package's `write_vega_lite`, whose cross-package reach is
/// why this is an `#internal(engine)` seam (hidden from the interface,
/// flagged for downstream callers) rather than package-private: the
/// unpaired-surrogate refusal below is a guard, and a guard that exists in
/// one serialiser but not another is a hole, so every file writer routes
/// through this one copy of it.
///
/// A path ending in `.gz` (case-sensitive, matching the read side's
/// content sniff round-trip: what this writes, `read_text` reads back)
/// receives the gzip-compressed UTF-8 encoding instead of the plain bytes.
///
/// Rejects content holding an unpaired UTF-16 surrogate (`raise
/// InvalidOperation`) before encoding: MoonBit strings can legally hold one
/// (e.g. assembled from a raw code unit with `Int::unsafe_to_char` — since
/// moonc 0.10.9 neither string literals nor the JSON parser accept one), but
/// the UTF-8 file encoder
/// merges a lone high surrogate with the *following* code unit — swallowing
/// a CSV delimiter or a JSON closing quote and silently shifting every cell
/// boundary after it. Refusing up front matches `validate_csv_delimiter`'s
/// philosophy: reject a write that cannot round-trip rather than corrupt
/// the file silently.
#doc(hidden)
#internal(engine, "MoonFrame chart export shares the guarded file writer")
pub fn write_text(
  path : String,
  content : String,
) -> Unit raise @types.DataError {
  match @text.find_unpaired_surrogate(content) {
    Some(i) =>
      raise @types.DataError::InvalidOperation(
        "cannot write a string containing an unpaired UTF-16 surrogate " +
        "(0x\{content.code_units()[i].to_int().to_string(radix=16)} at code unit \{i}): " +
        "the UTF-8 encoding would corrupt the file",
      )
    None => ()
  }
  if path.has_suffix(".gz") {
    @fs.write_bytes_to_file(path, @gzip.compress(@utf8.encode(content))) catch {
      @fs.IOError(msg) => raise @types.DataError::IoError(msg)
    }
    return
  }
  @fs.write_string_to_file(path, content) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}
