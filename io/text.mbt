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
