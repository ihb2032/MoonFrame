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
test "Scalar::eq same type" {
  assert_eq(Scalar::Int(1).eq(Scalar::Int(1)), true)
  assert_eq(Scalar::Int(1).eq(Scalar::Int(2)), false)
  assert_eq(Scalar::String("a").eq(Scalar::String("a")), true)
  assert_eq(Scalar::Bool(true).eq(Scalar::Bool(false)), false)
}

///|
test "Scalar::eq Int and Float compare numerically" {
  assert_eq(Scalar::Int(3).eq(Scalar::Float(3.0)), true)
  assert_eq(Scalar::Float(3.0).eq(Scalar::Int(3)), true)
  assert_eq(Scalar::Int(3).eq(Scalar::Float(3.1)), false)
}

///|
test "Scalar::eq/lt Int-vs-Float compares exactly (no 2^53 promotion)" {
  // The `Int64` is NOT promoted to `Double`, so distinct values never collide
  // above 2^53 — the deliberate departure from Polars' Float64 supertype rule.
  let two_pow_53 = 9007199254740992.0
  // 2^53 + 1 is a distinct integer; the 2^53 `Double` is smaller, not equal.
  assert_eq(Scalar::Int(9007199254740993L).eq(Scalar::Float(two_pow_53)), false)
  assert_eq(Scalar::Int(9007199254740993L).gt(Scalar::Float(two_pow_53)), true)
  assert_eq(Scalar::Int(9007199254740993L).lt(Scalar::Float(two_pow_53)), false)
  // The exact value still compares equal.
  assert_eq(Scalar::Int(9007199254740992L).eq(Scalar::Float(two_pow_53)), true)
  // `Int64::MAX` (2^63-1) is strictly below 2^63, never equal to the `2^63`
  // `Double` a promotion would round it to.
  let two_pow_63 = 9223372036854775808.0
  assert_eq(
    Scalar::Int(9223372036854775807L).eq(Scalar::Float(two_pow_63)),
    false,
  )
  assert_eq(
    Scalar::Int(9223372036854775807L).lt(Scalar::Float(two_pow_63)),
    true,
  )
  // `Int64::MIN` (-2^63) is exactly representable and compares equal.
  let neg_two_pow_63 = -9223372036854775808.0
  assert_eq(
    Scalar::Int(-9223372036854775808L).eq(Scalar::Float(neg_two_pow_63)),
    true,
  )
  // Reverse operand order (Float vs Int) agrees.
  assert_eq(Scalar::Float(two_pow_53).eq(Scalar::Int(9007199254740993L)), false)
  assert_eq(Scalar::Float(two_pow_53).lt(Scalar::Int(9007199254740993L)), true)
  assert_eq(
    Scalar::Float(two_pow_63).gt(Scalar::Int(9223372036854775807L)),
    true,
  )
}

///|
test "Scalar::eq/lt Int-vs-Float: infinities and NaN" {
  let inf = @double.infinity
  let ninf = @double.neg_infinity
  let nan = @double.not_a_number
  // Infinities order past every `Int`.
  assert_eq(Scalar::Int(0).lt(Scalar::Float(inf)), true)
  assert_eq(Scalar::Int(0).gt(Scalar::Float(ninf)), true)
  assert_eq(Scalar::Float(inf).gt(Scalar::Int(9223372036854775807L)), true)
  assert_eq(Scalar::Float(ninf).lt(Scalar::Int(-9223372036854775808L)), true)
  // `NaN` is unordered: every comparison is `false`.
  assert_eq(Scalar::Int(0).eq(Scalar::Float(nan)), false)
  assert_eq(Scalar::Int(0).lt(Scalar::Float(nan)), false)
  assert_eq(Scalar::Int(0).gt(Scalar::Float(nan)), false)
  assert_eq(Scalar::Float(nan).lt(Scalar::Int(0)), false)
}

///|
test "Scalar::eq Null short-circuits to a raise" {
  assert_true(
    (Ok(Scalar::Null.eq(Scalar::Null)) catch { e => Err(e) }) is Err(_),
  )
  assert_true(
    (Ok(Scalar::Null.eq(Scalar::Int(0))) catch { e => Err(e) }) is Err(_),
  )
  assert_true(
    (Ok(Scalar::Int(0).eq(Scalar::Null)) catch { e => Err(e) }) is Err(_),
  )
}

///|
test "Scalar::eq cross-type raises" {
  assert_true(
    (Ok(Scalar::Int(0).eq(Scalar::String("0"))) catch { e => Err(e) }) is Err(_),
  )
  assert_true(
    (Ok(Scalar::Bool(true).eq(Scalar::Int(1))) catch { e => Err(e) }) is Err(_),
  )
}

///|
test "gt reports an incomparable pair in call order" {
  // `gt` delegates to `other.lt(self)`, which transposes the operands — the
  // diagnostic must still name them in the caller's order, like eq/lt.
  assert_eq(
    Ok(Scalar::Int(1).gt(Scalar::String("x"))) catch {
      e => Err(e)
    },
    Err(
      DataError::TypeMismatch(
        TypeMismatchDetail::Operation(
          "compare",
          DataType::Int,
          DataType::String,
        ),
      ),
    ),
  )
  // Comparable pairs still delegate (Bool orders false < true; String
  // orders lexicographically).
  assert_true(Scalar::Bool(true).gt(Scalar::Bool(false)))
  assert_true(Scalar::String("fig").gt(Scalar::String("apple")))
}

///|
test "Scalar::lt / gt" {
  assert_eq(Scalar::Int(1).lt(Scalar::Int(2)), true)
  assert_eq(Scalar::Int(2).lt(Scalar::Int(2)), false)
  assert_eq(Scalar::Int(2).gt(Scalar::Int(1)), true)
  assert_eq(Scalar::String("a").lt(Scalar::String("b")), true)
  // Lexicographic, not shortlex: "apple" < "fig" even though "fig" is
  // shorter (the built-in `<` would rank the shorter "fig" first).
  assert_eq(Scalar::String("fig").lt(Scalar::String("apple")), false)
  assert_eq(Scalar::String("apple").lt(Scalar::String("fig")), true)
  assert_eq(Scalar::Bool(false).lt(Scalar::Bool(true)), true)
  // Mixed numeric works.
  assert_eq(Scalar::Int(1).lt(Scalar::Float(1.5)), true)
  // Null always raises.
  assert_true(
    (Ok(Scalar::Null.lt(Scalar::Int(0))) catch { e => Err(e) }) is Err(_),
  )
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
test "Scalar::eq Float-Float and IEEE 754 NaN semantics" {
  assert_eq(Scalar::Float(1.5).eq(Scalar::Float(1.5)), true)
  assert_eq(Scalar::Float(1.5).eq(Scalar::Float(2.0)), false)
  // NaN never equals anything, including itself.
  let nan : Double = @double.not_a_number
  assert_eq(Scalar::Float(nan).eq(Scalar::Float(nan)), false)
  assert_eq(Scalar::Float(nan).eq(Scalar::Float(1.0)), false)
}

///|
test "Scalar::lt Float-Float and Float-Int both directions" {
  assert_eq(Scalar::Float(1.0).lt(Scalar::Float(2.0)), true)
  assert_eq(Scalar::Float(2.0).lt(Scalar::Float(2.0)), false)
  assert_eq(Scalar::Float(2.0).lt(Scalar::Int(3)), true)
  assert_eq(Scalar::Int(3).lt(Scalar::Float(2.5)), false)
  // NaN comparisons are always false per IEEE 754.
  let nan : Double = @double.not_a_number
  assert_eq(Scalar::Float(nan).lt(Scalar::Float(1.0)), false)
  assert_eq(Scalar::Float(1.0).lt(Scalar::Float(nan)), false)
}

///|
test "Scalar::lt cross-type raises" {
  assert_true(
    (Ok(Scalar::Int(0).lt(Scalar::String("0"))) catch { e => Err(e) }) is Err(_),
  )
  assert_true(
    (Ok(Scalar::Bool(true).lt(Scalar::String("x"))) catch { e => Err(e) })
    is Err(_),
  )
  assert_true(
    (Ok(Scalar::Float(1.0).lt(Scalar::Bool(true))) catch { e => Err(e) })
    is Err(_),
  )
}

///|
test "Scalar::gt guards Null" {
  assert_true(
    (Ok(Scalar::Null.gt(Scalar::Int(0))) catch { e => Err(e) }) is Err(_),
  )
  assert_true(
    (Ok(Scalar::Int(0).gt(Scalar::Null)) catch { e => Err(e) }) is Err(_),
  )
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
test "Scalar::Date compares date-wise and refuses every other dtype" {
  assert_true(Scalar::Date(5L).eq(Scalar::Date(5L)))
  assert_true(Scalar::Date(4L).lt(Scalar::Date(5L)))
  assert_true(Scalar::Date(5L).gt(Scalar::Date(4L)))
  // Cross-dtype: the day count never equals the Int, and comparing raises
  // the same Operation mismatch any other incomparable pair does.
  assert_true(
    (Ok(Scalar::Date(5L).eq(Scalar::Int(5L))) catch { e => Err(e) }) is Err(_),
  )
  assert_true(
    (Ok(Scalar::Date(5L).lt(Scalar::Int(6L))) catch { e => Err(e) }) is Err(_),
  )
  // Typed accessors refuse it like any other foreign variant.
  assert_true((Ok(Scalar::Date(0L).as_int()) catch { e => Err(e) }) is Err(_))
}
