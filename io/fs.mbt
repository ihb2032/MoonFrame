// File-system access for the IO readers and writers: the single place that
// translates `@fs`'s `IOError` into the library's `DataError::IoError`, so the
// `read_*` / `write_*` entry points don't each repeat the catch.

///|
/// Read a whole file as a string, mapping a file-system `IOError` to
/// `DataError::IoError`. Shared by every `read_*` entry point.
fn read_text(path : String) -> String raise @types.DataError {
  @fs.read_file_to_string(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
/// Write a string to a file, mapping a file-system `IOError` to
/// `DataError::IoError`. Shared by every `write_*` entry point.
fn write_text(path : String, content : String) -> Unit raise @types.DataError {
  @fs.write_string_to_file(path, content) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}
