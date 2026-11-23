// The order of nested values — one total order shared by the sort key
// and the extremum reducers, so a nested column's `sort`, its `min` /
// `max`, and its `arg_min` / `arg_max` never disagree about which value
// comes first. A list orders lexicographically (element by element; a
// prefix sorts before its extension), a struct field by field in the
// struct's own field order, and a nested value at any depth recurses
// through the same rule. Inside a nested value a null element sorts
// before every present one — fixed there, because the `nulls_last` a
// caller passes places the *cells* of the column, not the elements of a
// cell.

///|
/// Compare two scalars of one column's dtype — the total order the sort
/// key and the extremum reducers read. `Int` and the `I64` riders compare
/// their counts (a `Date` by its day, a `Timestamp` its instant, a
/// `Duration` its span), `Float` by the IEEE total order (every `NaN` one
/// bucket past every other value), `Bool` as `false < true`, `String`
/// lexicographically, `Decimal` by its own total order. A `Null` sorts
/// before a present value; two nulls are equal. A list compares element
/// by element through this same rule and a shorter prefix sorts first;
/// a struct compares field by field, in the fields' own order.
///
/// An engine seam, not a public comparison API: the kernel layer's
/// comparison and positional-order sites read it so that `lt` on a nested
/// column, its `sort`, and its `min` / `max` share one order. A caller
/// hands this two cells of *one* column, so the two sides carry the same
/// dtype at every position.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn cmp_scalar_total(a : @types.Scalar, b : @types.Scalar) -> Int32 {
  match (a, b) {
    (@types.Scalar::Null, @types.Scalar::Null) => 0
    (@types.Scalar::Null, _) => -1
    (_, @types.Scalar::Null) => 1
    (@types.Scalar::Int(x), @types.Scalar::Int(y)) => cmp_int64(x, y)
    (@types.Scalar::Float(x), @types.Scalar::Float(y)) =>
      @numeric.cmp_double_total(x, y)
    (@types.Scalar::Bool(x), @types.Scalar::Bool(y)) =>
      if x == y {
        0
      } else if !x {
        -1
      } else {
        1
      }
    (@types.Scalar::String(x), @types.Scalar::String(y)) =>
      @text.compare_string_lex(x, y)
    (@types.Scalar::Decimal(x), @types.Scalar::Decimal(y)) => x.cmp_total(y)
    (@types.Scalar::Date(x), @types.Scalar::Date(y))
    | (@types.Scalar::Timestamp(x), @types.Scalar::Timestamp(y))
    | (@types.Scalar::Duration(x), @types.Scalar::Duration(y)) =>
      cmp_int64(x, y)
    (@types.Scalar::List(x), @types.Scalar::List(y)) =>
      cmp_lists(x.cells(), y.cells())
    (@types.Scalar::Struct(x), @types.Scalar::Struct(y)) =>
      cmp_fields(x.fields(), y.fields())
    (other_a, other_b) =>
      other_a.dtype().to_string().compare(other_b.dtype().to_string())
  }
}

///|
/// The lexicographic order of two element lists: the first pair of
/// unequal elements decides, and a list that runs out first sorts before
/// the longer one.
fn cmp_lists(x : Array[@types.Scalar], y : Array[@types.Scalar]) -> Int32 {
  let shared = if x.length() < y.length() { x.length() } else { y.length() }
  for i in 0..<shared {
    let c = cmp_scalar_total(x[i], y[i])
    if c != 0 {
      return c
    }
  }
  cmp_int(x.length(), y.length())
}

///|
/// The field-by-field order of two struct values, in field position; the
/// names are the dtype's and agree by position, so only the values
/// decide.
fn cmp_fields(
  x : Array[@types.FieldValue],
  y : Array[@types.FieldValue],
) -> Int32 {
  let shared = if x.length() < y.length() { x.length() } else { y.length() }
  for i in 0..<shared {
    let c = cmp_scalar_total(x[i].value(), y[i].value())
    if c != 0 {
      return c
    }
  }
  cmp_int(x.length(), y.length())
}

///|
/// Three-way comparison of two `Int64`s.
fn cmp_int64(x : Int64, y : Int64) -> Int32 {
  if x < y {
    -1
  } else if x > y {
    1
  } else {
    0
  }
}

///|
/// Three-way comparison of two `Int32`s.
fn cmp_int(x : Int32, y : Int32) -> Int32 {
  if x < y {
    -1
  } else if x > y {
    1
  } else {
    0
  }
}
