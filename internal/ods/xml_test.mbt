// XML spelled by the blackbox tests, piece by piece: the table, row and
// cell elements, a paragraph, a content.xml in UTF-16, and the two ways a
// test states a refusal.

///|
/// A table:table element, named unless `name` is empty.
fn xtable(name : String, rows : String) -> String {
  if name == "" {
    "<table:table>\{rows}</table:table>"
  } else {
    "<table:table table:name=\"\{name}\">\{rows}</table:table>"
  }
}

///|
/// A table:table-row element.
fn xrow(cells : String) -> String {
  "<table:table-row>\{cells}</table:table-row>"
}

///|
/// A table:table-cell element: `attrs` each spelled with its leading
/// space, `inner` what it holds.
fn xcell(attrs : String, inner : String) -> String {
  "<table:table-cell\{attrs}>\{inner}</table:table-cell>"
}

///|
/// A table:covered-table-cell element.
fn xcovered(attrs : String, inner : String) -> String {
  "<table:covered-table-cell\{attrs}>\{inner}</table:covered-table-cell>"
}

///|
/// A paragraph.
fn xp(text : String) -> String {
  "<text:p>\{text}</text:p>"
}

///|
/// A float cell holding `value`, its text the same.
fn xnumber(value : String) -> String {
  xcell(" office:value-type=\"float\" office:value=\"\{value}\"", xp(value))
}

///|
/// A string cell holding `inner`.
fn xstring(inner : String) -> String {
  xcell(" office:value-type=\"string\"", inner)
}

///|
/// A string cell holding one paragraph of `text`.
fn xtext(text : String) -> String {
  xstring(xp(text))
}

///|
/// Text as XML spells it: the ampersand, the two angle brackets and the
/// two quotes escaped.
fn xescaped(text : String) -> String {
  text
  .replace(old="&", new="&amp;")
  .replace(old="<", new="&lt;")
  .replace(old=">", new="&gt;")
  .replace(old="\"", new="&quot;")
}

///|
/// `text` with every `was` spelled `now`.
fn swapped(text : String, was : String, now : String) -> String {
  text.replace(old=was, new=now)
}

///|
/// A text in UTF-16, with or without its byte-order mark.
fn utf16(text : String, big : Bool, mark : Bool) -> Bytes {
  let units = text.code_units()
  let body = Bytes::makei(units.length() * 2, i => {
    let unit = units[i / 2].to_int()
    let high = (unit >> 8).to_byte()
    let low = (unit & 0xFF).to_byte()
    let first = i % 2 == 0
    if big {
      if first {
        high
      } else {
        low
      }
    } else if first {
      low
    } else {
      high
    }
  })
  if mark {
    (if big { b"\xfe\xff" } else { b"\xff\xfe" }) + body
  } else {
    body
  }
}

///|
/// A spreadsheet package with only a content.xml entry.
fn only_content(content : Bytes) -> Bytes {
  zip([("content.xml", content)], @utf8.encode(MIMETYPE))
}

///|
/// A package of entries with a mimetype entry of `mimetype`.
fn with_mimetype(entries : Array[(String, Bytes)], mimetype : Bytes) -> Bytes {
  zip(entries, mimetype)
}

///|
/// The refusal reading `bytes` raises, which must be `wanted` in variant
/// and `message` in text — from `OdsBook::grid` and from `OdsBook::sheets` alike.
fn refusal_is(
  bytes : Bytes,
  wanted : String,
  message : String,
) -> Unit raise Failure {
  let by_grid = refused(bytes)
  if variant(by_grid) != wanted ||
    by_grid.message() != rendered(wanted, message) {
    fail(
      "OdsBook::grid refuses with \{variant(by_grid)} \{by_grid.message()}; expected \{wanted} \{rendered(wanted, message)}",
    )
  }
  let by_sheets = refused_sheets(bytes)
  if variant(by_sheets) != wanted ||
    by_sheets.message() != rendered(wanted, message) {
    fail(
      "OdsBook::sheets refuses with \{variant(by_sheets)} \{by_sheets.message()}; expected \{wanted} \{rendered(wanted, message)}",
    )
  }
}

///|
/// A budget as the reader grants one a package of `size` bytes.
fn budget_of(size : Int32) -> Int64 {
  let linear = 65536L + size.to_int64() * 8L
  if linear < 33554432L {
    linear
  } else {
    33554432L
  }
}

///|
/// The first sheet's cells, which must be `wanted` — each spelled as the
/// sidecars spell one.
fn cells_are(bytes : Bytes, wanted : Array[String]) -> Unit raise Failure {
  let got = read(bytes)
  if got != wanted {
    fail("the codec read \{got.join(" | ")}; expected \{wanted.join(" | ")}")
  }
}
