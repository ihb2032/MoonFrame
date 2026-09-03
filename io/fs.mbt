// File-system access for the IO readers and writers: the single place that
// translates `@fs`'s `IOError` into the library's `DataError::IoError`, so the
// `read_*` / `write_*` entry points don't each repeat the catch.
//
// One-file-one-test exemption: this shared plumbing has no dedicated
// `fs_test.mbt`. (doc-guard: unresolved) It is covered through the
// file-backed `read_csv` / `write_csv` / `write_json` / `write_ndjson`
// tests in the per-format test files and the surrogate-refusal corpus in
// `roundtrip_corpus_test.mbt`.

///|
/// Read a whole file as a string, mapping a file-system `IOError` to
/// `DataError::IoError`. Shared by every `read_*` entry point.
fn read_text(path : String) -> String raise @types.DataError {
  @fs.read_file_to_string(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// Return the code-unit index of the first unpaired UTF-16 surrogate in
/// `content`, or `None` when the string is well-formed. A high surrogate
/// (`0xD800`–`0xDBFF`) must be immediately followed by a low surrogate
/// (`0xDC00`–`0xDFFF`); a low surrogate anywhere else is unpaired.
fn find_unpaired_surrogate(content : String) -> Int? {
  let units = content.code_units()
  let n = units.length()
  let mut i = 0
  while i < n {
    let cu = units[i]
    if cu.is_leading_surrogate() {
      if i + 1 < n && units[i + 1].is_trailing_surrogate() {
        i += 2
        continue
      }
      return Some(i)
    }
    if cu.is_trailing_surrogate() {
      return Some(i)
    }
    i += 1
  }
  None
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
  match find_unpaired_surrogate(content) {
    Some(i) =>
      raise @types.DataError::InvalidOperation(
        "cannot write a string containing an unpaired UTF-16 surrogate " +
        "(0x\{content.code_units()[i].to_int().to_string(radix=16)} at code unit \{i}): " +
        "the UTF-8 encoding would corrupt the file",
      )
    None => ()
  }
  @fs.write_string_to_file(path, content) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}
