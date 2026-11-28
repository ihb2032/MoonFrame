// Where a file lies. A path in the metadata is a URI (`file:///wh/t/data`,
// `s3://bucket/t`), a POSIX absolute path, or a Windows drive path, where
// the letter before the colon is a drive and not a scheme. A reader that
// opens a table from a directory of its own wants each path relative to the
// table's location, and refuses a file that lies elsewhere: it cannot be
// found from that directory.

///|
/// The URI scheme `path` begins with, or `None` when it begins with none.
/// A scheme is a letter and then letters, digits, `+`, `-` or `.`, closed
/// by a colon, and at least two characters long: a single letter before a
/// colon is a drive, not a scheme.
fn scheme_of(path : String) -> String? {
  let units = path.code_units()
  if !is_letter(unit_at(path, 0)) {
    return None
  }
  let mut at = 1
  while at < units.length() {
    let code = units[at].to_int()
    if code == 58 {
      return if at >= 2 { Some(path[:at].to_owned()) } else { None }
    }
    let allowed = is_letter(code) ||
      is_digit(code) ||
      code == 43 ||
      code == 45 ||
      code == 46
    if !allowed {
      return None
    }
    at += 1
  }
  None
}

///|
/// The path spelled by the scheme it lies under: `the scheme s3`, or
/// `no scheme` for a plain path.
fn under_scheme(path : String) -> String {
  match scheme_of(path) {
    Some(scheme) => "the scheme \{scheme}"
    None => "no scheme"
  }
}

///|
/// `path` relative to the table's `location`: what follows the location
/// and the separator after it. Raises `ParseError` for an empty path or an
/// empty location, and `Unsupported` when the path does not lie under the
/// location — naming the scheme it lies under when that differs from the
/// location's own — since a file outside the table cannot be found from
/// the table's directory.
fn relative_to(
  path : String,
  location : String,
  what : String,
) -> String raise @types.DataError {
  if path.is_empty() {
    raise malformed("\{what} is an empty path")
  }
  let mut end = location.length()
  while end > 0 && location[end - 1].to_int() == 47 {
    end -= 1
  }
  if end == 0 {
    raise malformed("the table's location is empty")
  }
  let prefix = location[:end].to_owned() + "/"
  if path.has_prefix(prefix) {
    return path[prefix.length():].to_owned()
  }
  if scheme_of(path) != scheme_of(location) {
    raise refuse(
      "\{what} \{path} lies under \{under_scheme(path)}, not under the table location \{location}, which lies under \{under_scheme(location)}",
    )
  }
  raise refuse("\{what} \{path} lies outside the table location \{location}")
}

///|
/// The path a caller reads, relative to the table's location when the
/// reading was told the location, and otherwise as the bytes spell it.
fn table_path(
  path : String,
  location : String?,
  what : String,
) -> String raise @types.DataError {
  match location {
    Some(base) => relative_to(path, base, what)
    None =>
      if path.is_empty() {
        raise malformed("\{what} is an empty path")
      } else {
        path
      }
  }
}
