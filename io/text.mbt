// Text-content normalization shared by the string-level readers (CSV / JSON /
// NDJSON). Keeping BOM handling in one place stops the formats from drifting
// apart — historically CSV stripped the BOM while JSON / NDJSON did not, so a
// file saved by Excel read cleanly through one format and failed through the
// others.

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
/// Defuse a projection that matches **no** header, shared by the CSV and
/// JSON/NDJSON projected readers. Building zero columns would collapse the
/// read to a 0×0 frame — silently losing the file's row count, so a
/// downstream `slice` / `head` bounds-checks against 0 and the surfaced
/// error flips from the as-built plan's `ColumnNotFound` to
/// `IndexOutOfBounds`, breaking the optimizer's error-parity contract.
/// Falling back to every column keeps the row count, and the consumer that
/// provably reads the missing name then raises its own as-built error.
/// Per-name leniency stays for a partially matching projection (the
/// surviving sub-frame keeps the full row count either way), and an
/// explicitly empty projection (`Some([])`) is the optimizer's deliberate
/// zero-column read, honoured as-is.
fn effective_projection(
  projection : Array[String]?,
  headers : Array[String],
) -> Array[String]? {
  match projection {
    Some(names) =>
      if !names.is_empty() && !headers.iter().any(h => names.contains(h)) {
        None
      } else {
        Some(names)
      }
    None => None
  }
}
