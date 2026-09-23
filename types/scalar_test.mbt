///|
test "Scalar::dtype" {
  assert_eq(Scalar::Int(1).dtype(), DataType::Int)
  assert_eq(Scalar::Float(1.5).dtype(), DataType::Float)
  assert_eq(Scalar::Bool(true).dtype(), DataType::Bool)
  assert_eq(Scalar::String("x").dtype(), DataType::String)
  assert_eq(Scalar::Null.dtype(), DataType::Null)
}

///|
test "Scalar::is_null" {
  assert_true(Scalar::Null.is_null())
  assert_false(Scalar::Int(0).is_null())
  assert_false(Scalar::String("").is_null())
}

///|
test "Scalar::to_string value-style" {
  inspect(Scalar::Int(42).to_string(), content="42")
  inspect(Scalar::Float(1.5).to_string(), content="1.5")
  inspect(Scalar::Bool(true).to_string(), content="true")
  inspect(Scalar::String("ab").to_string(), content="ab")
  inspect(Scalar::Null.to_string(), content="")
}

///|
test "Scalar::as_int" {
  assert_eq(Scalar::Int(7).as_int(), 7)
  assert_true((Ok(Scalar::Float(7.0).as_int()) catch { e => Err(e) }) is Err(_))
  assert_true((Ok(Scalar::Null.as_int()) catch { e => Err(e) }) is Err(_))
  assert_true(
    (Ok(Scalar::String("7").as_int()) catch { e => Err(e) }) is Err(_),
  )
}

///|
test "Scalar::as_float promotes Int" {
  assert_eq(Scalar::Float(1.5).as_float(), 1.5)
  assert_eq(Scalar::Int(3).as_float(), 3.0)
  assert_true((Ok(Scalar::Null.as_float()) catch { e => Err(e) }) is Err(_))
  assert_true(
    (Ok(Scalar::Bool(true).as_float()) catch { e => Err(e) }) is Err(_),
  )
}

///|
test "Scalar::as_bool / as_string" {
  assert_eq(Scalar::Bool(false).as_bool(), false)
  assert_true((Ok(Scalar::Int(0).as_bool()) catch { e => Err(e) }) is Err(_))
  assert_eq(Scalar::String("ok").as_string(), "ok")
  assert_true((Ok(Scalar::Null.as_string()) catch { e => Err(e) }) is Err(_))
}

///|
test "Scalar Show variant-style" {
  inspect(Scalar::Int(42), content="Int(42)")
  inspect(Scalar::Float(1.5), content="Float(1.5)")
  inspect(Scalar::Bool(true), content="Bool(true)")
  inspect(Scalar::String("ab"), content="String(\"ab\")")
  inspect(Scalar::Null, content="Null")
}

///|
test "Scalar Show escapes embedded quotes and backslashes" {
  // The variant form quotes the payload, so a `"` or `\` inside it is
  // escaped (`\"` / `\\`) to keep the rendering unambiguous — debug-string
  // style, distinct from the unquoted value form `to_string` produces.
  inspect(Scalar::String("a\"b\\c"), content="String(\"a\\\"b\\\\c\")")
  inspect(Scalar::String("a\"b\\c").to_string(), content="a\"b\\c")
}

///|
test "Scalar Show escapes control characters" {
  // Newline / carriage-return / tab become `\n` / `\r` / `\t` so the quoted
  // debug form stays on one line and round-trippable.
  inspect(Scalar::String("a\nb\tc\rd"), content="String(\"a\\nb\\tc\\rd\")")
  // Every other control character — the rest of C0, DEL, and the Unicode
  // line/paragraph separators (NEL / LS / PS) — becomes a `\uXXXX` escape, so a
  // hostile payload cannot inject a terminal control sequence or an extra line.
  inspect(
    Scalar::String("a\u{1b}\u{7f}\u{85}\u{2028}\u{2029}b"),
    content="String(\"a\\u001b\\u007f\\u0085\\u2028\\u2029b\")",
  )
}

///|
test "Scalar equality" {
  assert_eq(Scalar::Int(1), Scalar::Int(1))
  assert_not_eq(Scalar::Int(1), Scalar::Int(2))
  assert_not_eq(Scalar::Int(1), Scalar::Float(1.0))
  assert_eq(Scalar::Null, Scalar::Null)
}

///|
test "Scalar::as_bool / as_string remaining error paths" {
  // as_bool: Null branch.
  assert_true((Ok(Scalar::Null.as_bool()) catch { e => Err(e) }) is Err(_))
  // as_string: non-String non-Null branch.
  assert_true(
    (Ok(Scalar::Float(1.5).as_string()) catch { e => Err(e) }) is Err(_),
  )
  assert_true((Ok(Scalar::Int(0).as_string()) catch { e => Err(e) }) is Err(_))
}

///|
test "Scalar::Date renders ISO across the epoch and leap years" {
  // The epoch itself, pre-epoch dates (negative day counts), and a leap-day.
  assert_eq(Scalar::Date(0L).to_string(), "1970-01-01")
  assert_eq(Scalar::Date(-1L).to_string(), "1969-12-31")
  assert_eq(Scalar::Date(19723L).to_string(), "2024-01-01")
  assert_eq(Scalar::Date(19754L).to_string(), "2024-02-01")
  // 2024-12-31 = 19723 + 365 (2024 is a leap year; Feb 29 included), so
  // day 20089 is already 2025-01-01.
  assert_eq(Scalar::Date(20088L).to_string(), "2024-12-31")
  assert_eq(Scalar::Date(20089L).to_string(), "2025-01-01")
  // The Show form keeps the variant spelling with the ISO inside.
  // The Show form keeps the variant spelling with the ISO inside.
  inspect(Scalar::Date(0L), content="Date(1970-01-01)")
  // The dtype reports Date.
  assert_eq(Scalar::Date(0L).dtype(), DataType::Date)
}

///|
test "Scalar::Date refuses the typed accessors of foreign variants" {
  // The typed accessors refuse it like any other foreign variant.
  assert_true((Ok(Scalar::Date(0L).as_int()) catch { e => Err(e) }) is Err(_))
}

///|
test "Scalar::Date renders ISO years zero-padded to four digits" {
  // ISO 8601's `YYYY` basic range is 0000-9999: the epoch's own era renders
  // padded, a negative year carries its sign over a padded magnitude, and a
  // year beyond 9999 keeps its full expanded spelling.
  assert_eq(Scalar::Date(-719528L).to_string(), "0000-01-01")
  assert_eq(Scalar::Date(-720000L).to_string(), "-0002-09-16")
  assert_eq(Scalar::Date(2932896L).to_string(), "9999-12-31")
  assert_eq(Scalar::Date(-71584342L).to_string(), "-194022-09-24")
  // The Show form shares the rendering.
  inspect(Scalar::Date(-719528L), content="Date(0000-01-01)")
}

///|
test "Scalar::Date pads every sub-thousand year width" {
  // Years 1-99 and 100-999 exercise the two remaining pad arms: day counts
  // chosen so the civil algorithm lands mid-range of each.
  assert_eq(Scalar::Date(-701200L).to_string(), "0050-03-07")
  assert_eq(Scalar::Date(-536700L).to_string(), "0500-07-26")
}
