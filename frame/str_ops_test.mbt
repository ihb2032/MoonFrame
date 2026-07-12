///|
/// Blackbox tests for the string namespace (`Expr::str_*`) driven through the
/// expression verbs: each operation's per-cell semantics over a String
/// column, null propagation, the non-String `TypeMismatch`, the `Numeric`
/// convergence of the Int-valued `str_len_chars`, and integration with
/// `select` / `filter` / grouped `agg` and the literal broadcast. The
/// rendering / equality / introspection of the nodes themselves live in
/// `expr`'s `expr_str_test.mbt`.

///|
/// A String column mixing cases, surrounding whitespace, and a null cell, so
/// one fixture exercises case, trim, length, the predicates, and substitution.
fn str_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_string_options("s", [
      Some("Hello"),
      Some(" hi "),
      None,
      Some("WORLD"),
    ]),
  ])
}

///|
test "str_to_uppercase / str_to_lowercase: case maps per cell, nulls pass through" {
  let df = str_df()
  let up = df.with_columns([@expr.col("s").str_to_uppercase().with_alias("u")])
  assert_eq(up.get_column("u").to_scalars(), [
    @types.Scalar::String("HELLO"),
    @types.Scalar::String(" HI "),
    @types.Scalar::Null,
    @types.Scalar::String("WORLD"),
  ])
  let lo = df.with_columns([@expr.col("s").str_to_lowercase().with_alias("l")])
  assert_eq(lo.get_column("l").to_scalars(), [
    @types.Scalar::String("hello"),
    @types.Scalar::String(" hi "),
    @types.Scalar::Null,
    @types.Scalar::String("world"),
  ])
}

///|
test "str_strip_chars: trims surrounding whitespace, selected standalone" {
  // Also covers `select`: a `str_*` op stands alone as its own column.
  let out = str_df().select([@expr.col("s").str_strip_chars()])
  assert_eq(out.ncols(), 1)
  assert_eq(out.get_column("s").to_scalars(), [
    @types.Scalar::String("Hello"),
    @types.Scalar::String("hi"),
    @types.Scalar::Null,
    @types.Scalar::String("WORLD"),
  ])
}

///|
test "str_len_chars: counts Unicode characters, all-valid converging onto Numeric" {
  // A supplementary-plane character (`😀`, two UTF-16 code units) counts once.
  let df = DataFrame::new([Series::from_strings("s", ["a", "héllo", "😀"])])
  let out = df.with_columns([@expr.col("s").str_len_chars().with_alias("n")])
  assert_eq(out.get_column("n").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(5),
    @types.Scalar::Int(1),
  ])
  // A computed, all-valid numeric column rides the `Numeric` fast path.
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Numeric)
}

///|
test "str_len_chars: a null cell stays null and keeps the column Builtin" {
  let out = str_df().with_columns([
    @expr.col("s").str_len_chars().with_alias("n"),
  ])
  assert_eq(out.get_column("n").to_scalars(), [
    @types.Scalar::Int(5),
    @types.Scalar::Int(4),
    @types.Scalar::Null,
    @types.Scalar::Int(5),
  ])
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Builtin)
}

///|
test "str_contains: a Bool column, the null cell stays null" {
  let out = str_df().with_columns([
    @expr.col("s").str_contains("i").with_alias("c"),
  ])
  assert_eq(out.get_column("c").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
    @types.Scalar::Bool(false),
  ])
}

///|
test "str_starts_with / str_ends_with: prefix and suffix predicates" {
  let df = str_df()
  let sw = df.with_columns([
    @expr.col("s").str_starts_with("W").with_alias("sw"),
  ])
  assert_eq(sw.get_column("sw").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
    @types.Scalar::Bool(true),
  ])
  let ew = df.with_columns([@expr.col("s").str_ends_with("o").with_alias("ew")])
  assert_eq(ew.get_column("ew").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
    @types.Scalar::Bool(false),
  ])
}

///|
test "str_replace / str_replace_all: literal substitution, first vs every, nulls pass through" {
  let df = DataFrame::new([
    Series::from_string_options("s", [Some("a-a-a"), None, Some("a")]),
  ])
  let first = df.with_columns([
    @expr.col("s").str_replace("a", "X").with_alias("f"),
  ])
  assert_eq(first.get_column("f").to_scalars(), [
    @types.Scalar::String("X-a-a"),
    @types.Scalar::Null,
    @types.Scalar::String("X"),
  ])
  let all = df.with_columns([
    @expr.col("s").str_replace_all("a", "X").with_alias("g"),
  ])
  assert_eq(all.get_column("g").to_scalars(), [
    @types.Scalar::String("X-X-X"),
    @types.Scalar::Null,
    @types.Scalar::String("X"),
  ])
}

///|
test "str_reverse: reverses characters per cell, nulls pass through" {
  let out = str_df().select([@expr.col("s").str_reverse()])
  assert_eq(out.get_column("s").to_scalars(), [
    @types.Scalar::String("olleH"),
    @types.Scalar::String(" ih "),
    @types.Scalar::Null,
    @types.Scalar::String("DLROW"),
  ])
}

///|
test "str_reverse: respects surrogate pairs, reversing by codepoint" {
  // The emoji is one codepoint (two UTF-16 units), so it reverses as a unit.
  let df = DataFrame::new([Series::from_strings("s", ["a😀b"])])
  let out = df.select([@expr.col("s").str_reverse()])
  assert_eq(out.get_column("s").to_scalars(), [@types.Scalar::String("b😀a")])
}

///|
test "str_pad_start / str_pad_end: pad to a character width; default fill is space; never truncates" {
  let df = DataFrame::new([
    Series::from_string_options("s", [
      Some("7"),
      Some("hi"),
      Some("hello"),
      None,
    ]),
  ])
  let out = df.select([
    @expr.col("s").str_pad_start(4, fill='0').with_alias("ps"),
    @expr.col("s").str_pad_end(4).with_alias("pe"),
  ])
  // Left-pad to 4 with '0'; "hello" (5 ≥ 4) is unchanged, a null stays null.
  assert_eq(out.get_column("ps").to_scalars(), [
    @types.Scalar::String("0007"),
    @types.Scalar::String("00hi"),
    @types.Scalar::String("hello"),
    @types.Scalar::Null,
  ])
  // Right-pad to 4 with the default space.
  assert_eq(out.get_column("pe").to_scalars(), [
    @types.Scalar::String("7   "),
    @types.Scalar::String("hi  "),
    @types.Scalar::String("hello"),
    @types.Scalar::Null,
  ])
}

///|
test "str_pad_start: the width counts characters, not UTF-16 units" {
  // "😀" is one character but two UTF-16 units; padding to width 3 adds two fill
  // characters (codepoint-based), for a three-character result.
  let df = DataFrame::new([Series::from_strings("s", ["😀"])])
  let out = df.select([@expr.col("s").str_pad_start(3, fill='.')])
  assert_eq(out.get_column("s").to_scalars(), [@types.Scalar::String("..😀")])
}

///|
test "str_contains_regex: POSIX-regex partial match, nulls pass through" {
  let df = DataFrame::new([
    Series::from_string_options("s", [
      Some("abc"),
      Some("a1c"),
      Some("xyz"),
      None,
    ]),
  ])
  let out = df.select([
    @expr.col("s").str_contains_regex("a.c").with_alias("dot"),
    @expr.col("s").str_contains_regex("[[:digit:]]").with_alias("dig"),
  ])
  // "a.c" (`.` matches any char): abc ✓, a1c ✓, xyz ✗, null → null.
  assert_eq(out.get_column("dot").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
  // POSIX digit class: only "a1c" has a digit.
  assert_eq(out.get_column("dig").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
}

///|
test "str_replace_regex / str_replace_all_regex: first vs every match" {
  let df = DataFrame::new([
    Series::from_string_options("s", [Some("a12b345"), None]),
  ])
  let out = df.select([
    @expr.col("s").str_replace_regex("[0-9]+", "#").with_alias("first"),
    @expr.col("s").str_replace_all_regex("[0-9]+", "#").with_alias("all"),
  ])
  assert_eq(out.get_column("first").to_scalars(), [
    @types.Scalar::String("a#b345"),
    @types.Scalar::Null,
  ])
  assert_eq(out.get_column("all").to_scalars(), [
    @types.Scalar::String("a#b#"),
    @types.Scalar::Null,
  ])
}

///|
test "str regex: an invalid or PCRE-only pattern raises InvalidOperation" {
  let df = DataFrame::new([Series::from_strings("s", ["x"])])
  // An unclosed bracket is a genuine syntax error.
  assert_true(
    (Ok(df.select([@expr.col("s").str_contains_regex("[")])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // The core engine is POSIX: the PCRE `\d` is rejected (use `[[:digit:]]`).
  assert_true(
    (Ok(df.select([@expr.col("s").str_replace_regex("\\d", "x")])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "str regex: a non-String operand is a TypeMismatch" {
  let df = DataFrame::new([Series::from_ints("n", [1])])
  assert_true(
    (Ok(df.select([@expr.col("n").str_contains_regex("a")])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "str_extract: whole match by default, capture groups by index, null on no match" {
  let df = DataFrame::new([
    Series::from_string_options("s", [Some("abc123"), Some("xyz"), None]),
  ])
  let out = df.select([
    @expr.col("s").str_extract("[0-9]+").with_alias("whole"),
    @expr.col("s").str_extract("([a-z]+)([0-9]+)", group=1).with_alias("g1"),
    @expr.col("s").str_extract("([a-z]+)([0-9]+)", group=2).with_alias("g2"),
  ])
  // Group 0 (default) is the whole match: "123"; "xyz" has no digit → null.
  assert_eq(out.get_column("whole").to_scalars(), [
    @types.Scalar::String("123"),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  // Groups 1 / 2 on "abc123"; "xyz" doesn't match the whole pattern → null.
  assert_eq(out.get_column("g1").to_scalars(), [
    @types.Scalar::String("abc"),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  assert_eq(out.get_column("g2").to_scalars(), [
    @types.Scalar::String("123"),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
}

///|
test "str_extract: a group that did not participate is null even on a match" {
  // The pattern has no capture group, so group 1 is absent — null despite the
  // whole pattern matching.
  let df = DataFrame::new([Series::from_strings("s", ["abc123"])])
  let out = df.select([@expr.col("s").str_extract("[0-9]+", group=1)])
  assert_eq(out.get_column("s").to_scalars(), [@types.Scalar::Null])
}

///|
test "str_count_matches: non-overlapping match count, all-valid rides Numeric" {
  let df = DataFrame::new([Series::from_strings("s", ["a1b22c333", "abc", ""])])
  let out = df.with_columns([
    @expr.col("s").str_count_matches("[0-9]+").with_alias("n"),
  ])
  // Three digit runs, then none, then none.
  assert_eq(out.get_column("n").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(0),
    @types.Scalar::Int(0),
  ])
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Numeric)
}

///|
test "str_count_matches: a null cell stays null (Builtin)" {
  let df = DataFrame::new([
    Series::from_string_options("s", [Some("x1x2"), None]),
  ])
  let out = df.with_columns([
    @expr.col("s").str_count_matches("[0-9]").with_alias("n"),
  ])
  assert_eq(out.get_column("n").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Null,
  ])
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Builtin)
}

///|
test "str: a predicate filters rows by a (case-sensitive) string test" {
  let df = str_df()
  // `contains` is literal and case-sensitive: only "Hello" has a lowercase
  // "o" ("WORLD" carries an uppercase "O"); " hi " lacks it, and the null row
  // drops.
  let kept = df.filter(@expr.col("s").str_contains("o"))
  assert_eq(kept.get_column("s").to_scalars(), [@types.Scalar::String("Hello")])
}

///|
test "str: a namespace op wraps an aggregation inside grouped agg" {
  let df = DataFrame::new([
    Series::from_strings("region", ["west", "east", "west"]),
    Series::from_strings("name", ["alice", "bob", "carol"]),
  ])
  // `first(name).str_to_uppercase()` is reduction-shaped (the wrapper sees
  // through to the aggregation), so it is one value per group.
  let out = df
    .group_by([@expr.col("region")])
    .agg([@expr.col("name").first().str_to_uppercase().with_alias("lead")])
  assert_eq(out.get_column("region").to_scalars(), [
    @types.Scalar::String("west"),
    @types.Scalar::String("east"),
  ])
  assert_eq(out.get_column("lead").to_scalars(), [
    @types.Scalar::String("ALICE"),
    @types.Scalar::String("BOB"),
  ])
}

///|
test "str: an op on a literal broadcasts over the frame" {
  // A `str_*` op over a length-1 literal column broadcasts like any other
  // literal — every row receives the same transformed constant.
  let out = str_df().with_columns([
    @expr.lit_str("Raw").str_to_uppercase().with_alias("k"),
  ])
  assert_eq(out.get_column("k").to_scalars(), [
    @types.Scalar::String("RAW"),
    @types.Scalar::String("RAW"),
    @types.Scalar::String("RAW"),
    @types.Scalar::String("RAW"),
  ])
}

///|
test "str: a non-String operand is a TypeMismatch" {
  let df = DataFrame::new([Series::from_ints("n", [1, 2, 3])])
  let result = Ok(df.with_columns([@expr.col("n").str_to_uppercase()])) catch {
    e => Err(e)
  }
  assert_eq(
    result,
    Err(
      @types.DataError::TypeMismatch(
        "string operation requires a String operand, got Int",
      ),
    ),
  )
}
