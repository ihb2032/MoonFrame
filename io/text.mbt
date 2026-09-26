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

// ── duplicate-key scan (JSON family, `reject_duplicate_keys`) ───────────
//
// `@json.parse` folds an object's keys into a `Map`, so a repeated key
// survives only as its last value — the serde / pandas behaviour, and the
// default here. `reject_duplicate_keys` offers the strict reading, and the
// only place a repeat is still visible is the raw text, so the check is a
// small lexer over the payload that runs *before* the parse and only when
// the option is on: the default read pays nothing. It is a lexer, not a
// parser — well-formedness stays `@json.parse`'s business, so every
// out-of-shape input is tolerated here and answered by the parser's own
// diagnostic; the scan only tracks enough state to know which string
// literals are object keys (a string directly after `{` or after `,`
// inside an object) and compares them decoded, so `"a"` and `"\u0061"`
// count as the same key exactly as they do after parsing.

///|
/// One nesting level of the duplicate-key scan: an object's seen keys plus
/// whether the next string literal is a key, or an array's item level.
priv enum JsonScanFrame {
  ObjectKeys(Map[String, Unit], Bool)
  ArrayItems
}

///|
/// The first repeated key in a JSON payload, as `(1-based object number,
/// key)`, or `None` when no object repeats a key. Objects are counted in
/// textual order across the whole payload, nested objects included, so the
/// number names the object the repeat was found in. String literals are
/// decoded (`\uXXXX` included) before comparison, matching what the keys
/// become after `@json.parse`; escape-level differences that decode to the
/// same key are therefore caught, never the reverse. Malformed input is
/// tolerated — the parser behind it reports it, and nothing here should
/// pre-empt a different diagnostic.
fn first_duplicate_json_key(content : StringView) -> (Int, String)? {
  // Collect once: the `\uXXXX` look-ahead needs index arithmetic an
  // iterator will not give. Code units, exactly as `write_char` re-emits
  // them, so a literal surrogate pair and its `\uD83D\uDE00` spelling
  // normalise to the same sequence without pairing work.
  let chars : Array[Char] = []
  for ch in content.iter() {
    chars.push(ch)
  }
  let stack : Array[JsonScanFrame] = []
  let mut objects = 0
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '"' {
      let (token, next) = read_json_string_token(chars, i)
      // Only a string in key position is recorded; elsewhere it is a value.
      if stack.length() > 0 {
        match stack[stack.length() - 1] {
          ObjectKeys(seen, true) => {
            if seen.contains(token) {
              return Some((objects, token))
            }
            seen[token] = ()
            stack[stack.length() - 1] = ObjectKeys(seen, false)
          }
          _ => ()
        }
      }
      i = next
      continue
    }
    match c {
      '{' => {
        objects = objects + 1
        stack.push(ObjectKeys(Map([]), true))
      }
      '[' => stack.push(ArrayItems)
      '}' | ']' =>
        // A stray closer pops nothing; the parser reports the shape.
        if stack.length() > 0 {
          let _ = stack.pop()
        }
      ',' =>
        if stack.length() > 0 {
          match stack[stack.length() - 1] {
            // The string after a comma inside an object is the next key.
            ObjectKeys(seen, _) =>
              stack[stack.length() - 1] = ObjectKeys(seen, true)
            ArrayItems => ()
          }
        }
      _ => () // whitespace, literals, digits, and ':' carry no key state
    }
    i = i + 1
  }
  None
}

///|
/// Read one JSON string literal starting at the opening quote `chars[start]`,
/// returning its decoded content and the index just past the closing quote.
/// Escapes decode to the code-unit sequence `write_char` would re-emit
/// (`\uXXXX` to its code unit — a surrogate pair spelled out stays two code
/// units, matching how a literal one reads back), so two spellings of the
/// same key compare equal. An unterminated literal or malformed escape
/// yields what was read so far and stops the scan: `@json.parse` owns that
/// diagnostic.
fn read_json_string_token(chars : Array[Char], start : Int) -> (String, Int) {
  let buf = StringBuilder()
  let n = chars.length()
  let mut i = start + 1
  while i < n {
    let c = chars[i]
    if c == '"' {
      return (buf.to_string(), i + 1)
    }
    if c != '\\' {
      buf.write_char(c)
      i = i + 1
      continue
    }
    // An escape with nothing behind it cannot be finished; stop the token.
    if i + 1 >= n {
      break
    }
    match chars[i + 1] {
      '"' => {
        buf.write_char('"')
        i = i + 2
      }
      '\\' => {
        buf.write_char('\\')
        i = i + 2
      }
      '/' => {
        buf.write_char('/')
        i = i + 2
      }
      'b' => {
        buf.write_char('\b')
        i = i + 2
      }
      'f' => {
        buf.write_char('\u{000C}')
        i = i + 2
      }
      'n' => {
        buf.write_char('\n')
        i = i + 2
      }
      'r' => {
        buf.write_char('\r')
        i = i + 2
      }
      't' => {
        buf.write_char('\t')
        i = i + 2
      }
      'u' =>
        match hex4(chars, i + 2) {
          // A short or non-hex escape is the parser's to report; stop here.
          None => {
            i = n
            break
          }
          Some(unit) => {
            buf.write_char(unit.unsafe_to_char())
            i = i + 6
          }
        }
      // An unknown escape is not JSON; hand the payload to the parser.
      _ => {
        i = n
        break
      }
    }
  }
  (buf.to_string(), n)
}

///|
/// The 4-hex-digit value at `chars[at..at+4]`, or `None` when fewer than four
/// characters remain or any of them is not a hex digit.
fn hex4(chars : Array[Char], at : Int) -> Int? {
  if at + 4 > chars.length() {
    return None
  }
  let mut value = 0
  for k in 0..<4 {
    let d = match chars[at + k] {
      c if c >= '0' && c <= '9' => c.to_int() - '0'.to_int()
      c if c >= 'a' && c <= 'f' => c.to_int() - 'a'.to_int() + 10
      c if c >= 'A' && c <= 'F' => c.to_int() - 'A'.to_int() + 10
      _ => return None
    }
    value = value * 16 + d
  }
  Some(value)
}
