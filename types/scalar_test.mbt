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
  assert_true((try? Scalar::Float(7.0).as_int()) is Err(_))
  assert_true((try? Scalar::Null.as_int()) is Err(_))
  assert_true((try? Scalar::String("7").as_int()) is Err(_))
}

///|
test "Scalar::as_float promotes Int" {
  assert_eq(Scalar::Float(1.5).as_float(), 1.5)
  assert_eq(Scalar::Int(3).as_float(), 3.0)
  assert_true((try? Scalar::Null.as_float()) is Err(_))
  assert_true((try? Scalar::Bool(true).as_float()) is Err(_))
}

///|
test "Scalar::as_bool / as_string" {
  assert_eq(Scalar::Bool(false).as_bool(), false)
  assert_true((try? Scalar::Int(0).as_bool()) is Err(_))
  assert_eq(Scalar::String("ok").as_string(), "ok")
  assert_true((try? Scalar::Null.as_string()) is Err(_))
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
test "Scalar::eq Null short-circuits to a raise" {
  assert_true((try? Scalar::Null.eq(Scalar::Null)) is Err(_))
  assert_true((try? Scalar::Null.eq(Scalar::Int(0))) is Err(_))
  assert_true((try? Scalar::Int(0).eq(Scalar::Null)) is Err(_))
}

///|
test "Scalar::eq cross-type raises" {
  assert_true((try? Scalar::Int(0).eq(Scalar::String("0"))) is Err(_))
  assert_true((try? Scalar::Bool(true).eq(Scalar::Int(1))) is Err(_))
}

///|
test "Scalar::lt / lte / gt / gte" {
  assert_eq(Scalar::Int(1).lt(Scalar::Int(2)), true)
  assert_eq(Scalar::Int(2).lt(Scalar::Int(2)), false)
  assert_eq(Scalar::Int(2).lte(Scalar::Int(2)), true)
  assert_eq(Scalar::Int(2).gt(Scalar::Int(1)), true)
  assert_eq(Scalar::Int(2).gte(Scalar::Int(2)), true)
  assert_eq(Scalar::String("a").lt(Scalar::String("b")), true)
  // Lexicographic, not shortlex: "apple" < "fig" even though "fig" is
  // shorter (the built-in `<` would rank the shorter "fig" first).
  assert_eq(Scalar::String("fig").lt(Scalar::String("apple")), false)
  assert_eq(Scalar::String("apple").lt(Scalar::String("fig")), true)
  assert_eq(Scalar::Bool(false).lt(Scalar::Bool(true)), true)
  // Mixed numeric works.
  assert_eq(Scalar::Int(1).lt(Scalar::Float(1.5)), true)
  // Null always raises.
  assert_true((try? Scalar::Null.lt(Scalar::Int(0))) is Err(_))
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
  assert_true((try? Scalar::Int(0).lt(Scalar::String("0"))) is Err(_))
  assert_true((try? Scalar::Bool(true).lt(Scalar::String("x"))) is Err(_))
  assert_true((try? Scalar::Float(1.0).lt(Scalar::Bool(true))) is Err(_))
}

///|
test "Scalar::lte / gt / gte all guard Null" {
  assert_true((try? Scalar::Null.lte(Scalar::Int(0))) is Err(_))
  assert_true((try? Scalar::Int(0).lte(Scalar::Null)) is Err(_))
  assert_true((try? Scalar::Null.gt(Scalar::Int(0))) is Err(_))
  assert_true((try? Scalar::Int(0).gt(Scalar::Null)) is Err(_))
  assert_true((try? Scalar::Null.gte(Scalar::Int(0))) is Err(_))
  assert_true((try? Scalar::Int(0).gte(Scalar::Null)) is Err(_))
}

///|
test "Scalar::lte short-circuits at equality" {
  // Equal values: result is true; lt never needs to fire.
  assert_eq(Scalar::Int(5).lte(Scalar::Int(5)), true)
  // Strictly less: falls through to lt.
  assert_eq(Scalar::Int(4).lte(Scalar::Int(5)), true)
  // Strictly greater: lt returns false.
  assert_eq(Scalar::Int(6).lte(Scalar::Int(5)), false)
}

///|
test "Scalar::as_bool / as_string remaining error paths" {
  // as_bool: Null branch.
  assert_true((try? Scalar::Null.as_bool()) is Err(_))
  // as_string: non-String non-Null branch.
  assert_true((try? Scalar::Float(1.5).as_string()) is Err(_))
  assert_true((try? Scalar::Int(0).as_string()) is Err(_))
}
