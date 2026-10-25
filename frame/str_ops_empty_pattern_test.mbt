///|
/// Pin MoonBit core's empty-pattern behaviour, which the string kernels ride
/// through `SplitGet` and `Replace`: an empty separator splits into the
/// string's single characters, and an empty `old` inserts the replacement at
/// the head once. Both are total today; if a core change turns either into a
/// trap, this pin is where it surfaces rather than in a user's query.
test "str verbs: the empty-pattern shapes core answers today" {
  let df = DataFrame::DataFrame([Series::from_strings("s", ["ab"])])
  let split = df.select([
    @expr.col("s").str_split_get("", 0).with_alias("a"),
    @expr.col("s").str_split_get("", 1).with_alias("b"),
    // One past the last field reads null, as for any other separator.
    @expr.col("s").str_split_get("", 2).with_alias("c"),
  ])
  assert_eq(split.get_column("a").to_scalars(), [@types.Scalar::String("a")])
  assert_eq(split.get_column("b").to_scalars(), [@types.Scalar::String("b")])
  assert_eq(split.get_column("c").to_scalars(), [@types.Scalar::Null])
  let rep = df.select([@expr.col("s").str_replace("", "X").with_alias("r")])
  assert_eq(rep.get_column("r").to_scalars(), [@types.Scalar::String("Xab")])
}
