///|
/// The comparison kernel (`eq` / `ne` / `lt` / `le` / `gt` / `ge`). `CmpVerb`
/// re-tags the six comparison `@expr.BinOp`s so the cell loop matches
/// exhaustively; `apply_cmp` derives every verdict from the dtype's `lt` / `eq`
/// primitives (so IEEE NaN falls out right — a comparison against NaN is
/// `false`, `ne` `true`), and `compare_cells` adds the null layer. Produces a
/// `Bool` column on the `Builtin` backend.

///|
/// Which comparison a `Binary` comparison tag asked for, carried into the
/// shared cell loop. A package-local re-tag of the six `@expr.BinOp`
/// comparison constructors so `compare_cells` can match exhaustively
/// without dead arms for the non-comparison tags (`Add` / `And` / … never
/// reach it).
priv enum CmpVerb {
  Eq
  Ne
  Lt
  Le
  Gt
  Ge
}

///|
/// One comparison verdict from the dtype's `lt` / `eq` primitives, shared
/// by the nullable cell loop (`compare_cells`) and `eval_compare`'s
/// all-valid `Numeric` fast arms. Everything derives from `lt` / `eq` with
/// arguments in both orders — `Gt` is `lt(y, x)`, not `!(lt ∨ eq)` — so
/// IEEE NaN falls out right: `eq` / `lt` against NaN are `false`, hence
/// `Ne` is `true` and every ordering comparison is `false`.
fn[T] apply_cmp(
  verb : CmpVerb,
  lt : (T, T) -> Bool,
  eq : (T, T) -> Bool,
  x : T,
  y : T,
) -> Bool {
  match verb {
    CmpVerb::Eq => eq(x, y)
    CmpVerb::Ne => !eq(x, y)
    CmpVerb::Lt => lt(x, y)
    CmpVerb::Le => lt(x, y) || eq(x, y)
    CmpVerb::Gt => lt(y, x)
    CmpVerb::Ge => lt(y, x) || eq(x, y)
  }
}

///|
/// Build the `Bool?` cells of one comparison over two equal-length
/// operands, given a cell reader per side and the dtype's two primitive
/// predicates. The verdict itself is `apply_cmp` (NaN semantics live
/// there); this loop adds the null layer — NaN is a *value* (the cell
/// stays non-null), while a null on either side nulls the cell before the
/// predicates run.
fn[T] compare_cells(
  n : Int,
  lv : Array[Bool],
  rv : Array[Bool],
  get_left : (Int) -> T,
  get_right : (Int) -> T,
  lt : (T, T) -> Bool,
  eq : (T, T) -> Bool,
  verb : CmpVerb,
) -> Array[Bool?] {
  Array::makei(n, i => {
    if lv[i] && rv[i] {
      Some(apply_cmp(verb, lt, eq, get_left(i), get_right(i)))
    } else {
      None
    }
  })
}

///|
/// Comparison kernel over two equal-length operands
/// (post-`broadcast_pair`), producing a nullable `Bool` column. The dtype
/// matrix mirrors `Scalar::eq` / `Scalar::lt` (the `Scalar` comparison
/// precedent): `Int ↔ Float` compare after promoting `Int` to `Double`,
/// `String` compares by `compare_string_lex` (dictionary order — MoonBit's
/// built-in `String` order is shortlex), `Bool` orders `false < true`,
/// and any other pairing — including `Bool` / `String` against numbers —
/// raises `TypeMismatch`. Null and NaN behavior live in `compare_cells`.
fn eval_compare(
  left : Series,
  right : Series,
  verb : CmpVerb,
) -> Series raise @types.DataError {
  // `Numeric`×`Numeric` fast arm (see `eval_arith`): both sides all-valid,
  // so every cell compares — build the `Bool` cells directly through
  // `apply_cmp`, with no validity arrays and no `Bool?` boxing. The result
  // is nullable-free but `Bool`, so it lands on `Builtin` (`from_bools`),
  // same as the general arm's all-valid output.
  match (left.storage(), right.storage()) {
    (@column.ColumnStorage::Numeric(x), @column.ColumnStorage::Numeric(y)) =>
      return match (x.data, y.data) {
        (@column.NumericData::Int(a), @column.NumericData::Int(b)) =>
          Series::from_bools(
            left.name(),
            Array::makei(a.length(), i => {
              apply_cmp(verb, (x, y) => x < y, (x, y) => x == y, a[i], b[i])
            }),
          )
        (@column.NumericData::Int(a), @column.NumericData::Float(b)) =>
          Series::from_bools(
            left.name(),
            Array::makei(a.length(), i => {
              apply_cmp(
                verb,
                (x, y) => x < y,
                (x, y) => x == y,
                a[i].to_double(),
                b[i],
              )
            }),
          )
        (@column.NumericData::Float(a), @column.NumericData::Int(b)) =>
          Series::from_bools(
            left.name(),
            Array::makei(a.length(), i => {
              apply_cmp(
                verb,
                (x, y) => x < y,
                (x, y) => x == y,
                a[i],
                b[i].to_double(),
              )
            }),
          )
        (@column.NumericData::Float(a), @column.NumericData::Float(b)) =>
          Series::from_bools(
            left.name(),
            Array::makei(a.length(), i => {
              apply_cmp(verb, (x, y) => x < y, (x, y) => x == y, a[i], b[i])
            }),
          )
      }
    (@column.ColumnStorage::Builtin(_), _)
    | (_, @column.ColumnStorage::Builtin(_)) => ()
  }
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  let cells = match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i],
        i => b[i],
        (x, y) => x < y,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i].to_double(),
        i => b[i],
        (x, y) => x < y,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i],
        i => b[i].to_double(),
        (x, y) => x < y,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i],
        i => b[i],
        (x, y) => x < y,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::Bool(a), @column.ColumnData::Bool(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i],
        i => b[i],
        (x, y) => !x && y,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::String(a), @column.ColumnData::String(b)) =>
      compare_cells(
        a.length(),
        lv,
        rv,
        i => a[i],
        i => b[i],
        (x, y) => @types.compare_string_lex(x, y) < 0,
        (x, y) => x == y,
        verb,
      )
    (@column.ColumnData::Bool(_) | @column.ColumnData::String(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::String(_)) =>
      raise @types.DataError::TypeMismatch(
        binary_type_mismatch_msg("compare", left, right),
      )
  }
  Series::from_bool_options(left.name(), cells)
}
