// The helpers the reference sidecars are read with: a cell's spelling and
// the JSON accessors, shared by the blackbox tests of the readers that are
// anchored to a reference implementation — the XML and HTML tests.

///|
/// Sixteen lowercase hexadecimal digits.
fn hex64(bits : UInt64) -> String {
  let mut digits = bits.to_string(radix=16)
  while digits.length() < 16 {
    digits = "0\{digits}"
  }
  digits
}

///|
/// A scalar as a sidecar spells one.
fn spelled(value : @types.Scalar) -> String raise {
  match value {
    Null => "Null"
    Bool(b) => "Bool \{if b { "true" } else { "false" }}"
    Int(v) => "Int \{v}"
    Float(v) => "Float \{hex64(v.reinterpret_as_uint64())}"
    String(s) => "String \{s}"
    Date(_) | Duration(_) | Timestamp(_) | Decimal(_) | List(_) | Struct(_) =>
      fail("an XML column holds \{value.to_string()}")
  }
}

///|
/// A JSON value's field, which must be there.
fn field(value : Json, name : String) -> Json raise {
  if value is Object(fields) {
    match fields.get(name) {
      Some(found) => found
      None => fail("the JSON carries no field \"\{name}\"")
    }
  } else {
    fail("the JSON value is not an object")
  }
}

///|
/// A JSON value that must be an array.
fn jarray(value : Json) -> Array[Json] raise {
  if value is Array(items) {
    items
  } else {
    fail("the JSON value is not an array")
  }
}

///|
/// A JSON value that must be a string.
fn jstring(value : Json) -> String raise {
  if value is String(text) {
    text
  } else {
    fail("the JSON value is not a string")
  }
}
