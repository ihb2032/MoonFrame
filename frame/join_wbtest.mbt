// Whitebox guard for the one `JoinOptions` state the public constructors make
// unspellable. `on` and `left_on` / `right_on` are mutually exclusive, and
// since `JoinOptions::on` / `left_on` / `cross` each fill exactly one key
// shape — the fields being private outside `frame` — no caller can hand the
// join both. The defensive check in `join_key_exprs` stays anyway, because a
// future in-package builder could reintroduce the state; it is reachable only
// from here, through a record literal.

///|
test "join rejects options carrying both `on` and `left_on` / `right_on`" {
  let left = DataFrame::new([Series::from_ints("k", [1])])
  let right = DataFrame::new([Series::from_ints("k", [1])])
  let both : JoinOptions = {
    on: [@expr.col("k")],
    left_on: [@expr.col("k")],
    right_on: [@expr.col("k")],
    how: Inner,
    suffix: "_right",
    coalesce: None,
  }
  assert_true(
    (Ok(left.join(right, both)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}
