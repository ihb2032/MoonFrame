// What every string-level reader (CSV / JSON / NDJSON) shares, kept in one
// place so the formats cannot drift apart: BOM handling (historically CSV
// stripped the BOM while JSON / NDJSON did not, so a file saved by Excel read
// cleanly through one format and failed through the others), and the message
// spelling of a typed source coordinate — the prefix every reader renders a
// `Row` / `Line` / `Record` location with.
//
// One-file-one-test exemption: this shared file has no dedicated test file
// of its own. (doc-guard: unresolved) It is covered through the per-format
// BOM tests and the parse-error message tests in the CSV / JSON / NDJSON
// suites.

///|
/// Strip a single leading UTF-8 BOM (`U+FEFF`) if present, returning the rest
/// of the content unchanged.
///
/// Excel and many Windows tools prepend a BOM when saving `utf-8-sig`. Left in
/// place it leaks into the first column's name (CSV) or makes `@json.parse`
/// reject the payload at column 0 (JSON / NDJSON). Matches Polars / pandas,
/// which strip it on read for every format. A BOM-only file collapses to the
/// empty string, so callers that short-circuit empty input still see "no
/// payload".
fn strip_utf8_bom(content : String) -> String {
  if content.view().get_char(0) == Some('\u{FEFF}') {
    content.view().view(start_offset=1).to_owned()
  } else {
    content
  }
}

///|
/// The message-level spelling of a typed source coordinate — the prefix
/// every reader renders a `Row` / `Line` / `Record` location with, single
/// home for the row / line / record vocabulary, so a hand-spelled prefix
/// cannot drift from the typed one.
fn locator_text(loc : @types.CellParseLocation, n : Int) -> String {
  match loc {
    Row => "row \{n}"
    Line => "line \{n}"
    Record => "record \{n}"
  }
}
