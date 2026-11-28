// Checked reads of the JSON the metadata and the headers are written in:
// a value must be of the shape its field needs, an integer is read from its
// own digits so that a 64-bit identifier loses nothing, and every refusal
// names the field it was reading.

///|
/// How deep a JSON document may nest before it is refused.
const JSON_MAX_DEPTH : Int32 = 128

///|
/// The code unit at `at`, or -1 when `at` lies past the text.
fn unit_at(text : String, at : Int32) -> Int32 {
  if at >= 0 && at < text.length() {
    text[at].to_int()
  } else {
    -1
  }
}

///|
/// Whether the code is that of an ASCII digit.
fn is_digit(code : Int32) -> Bool {
  code >= 48 && code <= 57
}

///|
/// Whether the code is that of an ASCII letter.
fn is_letter(code : Int32) -> Bool {
  (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
}

///|
/// The whole number the digits from `from` spell, and where they end.
/// `None` when there is no digit or when the number passes the greatest
/// 64-bit whole number.
fn unsigned_at(text : String, from : Int32) -> (Int64?, Int32) {
  let mut at = from
  let mut value = 0UL
  while is_digit(unit_at(text, at)) {
    let digit = (unit_at(text, at) - 48).to_uint64()
    // The next digit may not carry the number past 2^63 - 1.
    if value > 922337203685477580UL ||
      (value == 922337203685477580UL && digit > 7UL) {
      return (None, at)
    }
    value = value * 10UL + digit
    at += 1
  }
  if at == from {
    (None, at)
  } else {
    (Some(value.reinterpret_as_int64()), at)
  }
}

///|
/// The 64-bit whole number a text spells, or `None`: a minus sign and
/// digits, and nothing else. The least 64-bit whole number is the one
/// negative number whose digits pass the greatest positive one.
fn int64_of_text(text : String) -> Int64? {
  if text == "-9223372036854775808" {
    return Some(-9223372036854775808L)
  }
  let negative = unit_at(text, 0) == 45
  let (magnitude, end) = unsigned_at(text, if negative { 1 } else { 0 })
  if end != text.length() {
    return None
  }
  match magnitude {
    Some(number) => Some(if negative { -number } else { number })
    None => None
  }
}

///|
/// The 64-bit whole number a JSON number spells, read from its own digits.
/// Raises `ParseError` for any other value — a string, a null, a fraction
/// or a number past 64 bits.
fn json_int(value : Json, what : String) -> Int64 raise @types.DataError {
  match value {
    Number(_, repr=Some(text)) =>
      match int64_of_text(text) {
        Some(number) => number
        None => raise malformed("\{what} is \{text}, not a 64-bit whole number")
      }
    _ => raise malformed("\{what} is not a 64-bit whole number")
  }
}

///|
/// A JSON string. Raises `ParseError` for any other value.
fn json_string(value : Json, what : String) -> String raise @types.DataError {
  if value is String(text) {
    text
  } else {
    raise malformed("\{what} is not a string")
  }
}

///|
/// The members of a JSON object. Raises `ParseError` for any other value.
fn json_object(
  value : Json,
  what : String,
) -> Map[String, Json] raise @types.DataError {
  if value is Object(members) {
    members
  } else {
    raise malformed("\{what} is not an object")
  }
}

///|
/// The items of a JSON array. Raises `ParseError` for any other value.
fn json_array(
  value : Json,
  what : String,
) -> Array[Json] raise @types.DataError {
  if value is Array(items) {
    items
  } else {
    raise malformed("\{what} is not an array")
  }
}

///|
/// The member `key` of an object, which must carry it.
fn json_member(
  members : Map[String, Json],
  key : String,
  what : String,
) -> Json raise @types.DataError {
  match members.get(key) {
    Some(found) => found
    None => raise malformed("\{what} names no \"\{key}\"")
  }
}

///|
/// The member `key` of an object: `None` when the object lacks the member
/// or holds null for it.
fn json_optional(members : Map[String, Json], key : String) -> Json? {
  match members.get(key) {
    Some(Null) => None
    other => other
  }
}

///|
/// The bytes parsed as one JSON document. Raises `ParseError` when the
/// bytes are not UTF-8 text or not one JSON document, naming the line and
/// column where it went wrong.
fn json_document(bytes : Bytes, what : String) -> Json raise @types.DataError {
  let text = @utf8.decode(bytes) catch {
    _ => raise malformed("\{what} is not UTF-8 text")
  }
  json_text(text, what)
}

///|
/// The text parsed as one JSON document, as `json_document` reads bytes.
/// The parser's own account of what it could not read — the character, the
/// key, the end of the text, the line and column — is given as it is.
fn json_text(text : String, what : String) -> Json raise @types.DataError {
  @json.parse(
    text,
    max_nesting_depth=JSON_MAX_DEPTH,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => raise malformed("\{what} is not JSON: \{error.to_string()}")
  }
}
