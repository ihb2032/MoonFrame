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
/// Transpose a comparison verb so `a verb b` becomes `b transpose(verb) a`
/// (`Lt`↔`Gt`, `Le`↔`Ge`; `Eq` / `Ne` are symmetric). Lets the
/// `Float`-vs-`Int` arm reuse the `Int`-vs-`Float` verdict with the operands
/// swapped.
fn transpose_verb(verb : CmpVerb) -> CmpVerb {
  match verb {
    CmpVerb::Eq => CmpVerb::Eq
    CmpVerb::Ne => CmpVerb::Ne
    CmpVerb::Lt => CmpVerb::Gt
    CmpVerb::Le => CmpVerb::Ge
    CmpVerb::Gt => CmpVerb::Lt
    CmpVerb::Ge => CmpVerb::Le
  }
}

///|
/// One comparison verdict between an `Int64` cell and a `Double` cell,
/// **exact** — no `Int`→`Double` promotion, so it mirrors `Scalar`'s
/// mixed-numeric arms and avoids the `2^53` collisions the Float64-supertype
/// widening would produce. NaN falls out right through the `@types`
/// primitives (every comparison with it is `false`).
fn cmp_int_double(verb : CmpVerb, a : Int64, b : Double) -> Bool {
  match verb {
    CmpVerb::Eq => @types.int64_eq_double(a, b)
    CmpVerb::Ne => !@types.int64_eq_double(a, b)
    CmpVerb::Lt => @types.int64_lt_double(a, b)
    CmpVerb::Le => @types.int64_lt_double(a, b) || @types.int64_eq_double(a, b)
    CmpVerb::Gt => @types.double_lt_int64(b, a)
    CmpVerb::Ge => @types.double_lt_int64(b, a) || @types.int64_eq_double(a, b)
  }
}

///|
/// The `Float`-vs-`Int` verdict, as the transposed `Int`-vs-`Float` one.
fn cmp_double_int(verb : CmpVerb, a : Double, b : Int64) -> Bool {
  cmp_int_double(transpose_verb(verb), b, a)
}

///|
/// `compare_cells` for a mixed `Int64` / `Double` pair, whose two sides have
/// different cell types so a single-`T` reader / predicate does not fit. Takes
/// the per-row verdict directly; the null layer is identical.
fn compare_cells_mixed(
  n : Int,
  lv : Array[Bool],
  rv : Array[Bool],
  verdict : (Int) -> Bool,
) -> Array[Bool?] {
  Array::makei(n, i => if lv[i] && rv[i] { Some(verdict(i)) } else { None })
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
  left_valid~ : Array[Bool],
  right_valid~ : Array[Bool],
  get_left~ : (Int) -> T,
  get_right~ : (Int) -> T,
  less_than~ : (T, T) -> Bool,
  equal~ : (T, T) -> Bool,
  verb~ : CmpVerb,
) -> Array[Bool?] {
  Array::makei(n, i => {
    if left_valid[i] && right_valid[i] {
      Some(apply_cmp(verb, less_than, equal, get_left(i), get_right(i)))
    } else {
      None
    }
  })
}

///|
/// Comparison kernel over two equal-length operands
/// (post-`broadcast_pair`), producing a nullable `Bool` column. The dtype
/// matrix mirrors `Scalar::eq` / `Scalar::lt` (the `Scalar` comparison
/// precedent): `Int ↔ Float` compare **exactly** (no `Int`→`Double`
/// promotion — see `cmp_int_double`), `String` compares by
/// `compare_string_lex` (dictionary order — MoonBit's
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
            Array::makei(a.length(), i => cmp_int_double(verb, a[i], b[i])),
          )
        (@column.NumericData::Float(a), @column.NumericData::Int(b)) =>
          Series::from_bools(
            left.name(),
            Array::makei(a.length(), i => cmp_double_int(verb, a[i], b[i])),
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
        left_valid=lv,
        right_valid=rv,
        get_left=i => a[i],
        get_right=i => b[i],
        less_than=(x, y) => x < y,
        equal=(x, y) => x == y,
        verb~,
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      compare_cells_mixed(a.length(), lv, rv, i => {
        cmp_int_double(verb, a[i], b[i])
      })
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      compare_cells_mixed(a.length(), lv, rv, i => {
        cmp_double_int(verb, a[i], b[i])
      })
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
      compare_cells(
        a.length(),
        left_valid=lv,
        right_valid=rv,
        get_left=i => a[i],
        get_right=i => b[i],
        less_than=(x, y) => x < y,
        equal=(x, y) => x == y,
        verb~,
      )
    (@column.ColumnData::Bool(a), @column.ColumnData::Bool(b)) =>
      compare_cells(
        a.length(),
        left_valid=lv,
        right_valid=rv,
        get_left=i => a[i],
        get_right=i => b[i],
        less_than=(x, y) => !x && y,
        equal=(x, y) => x == y,
        verb~,
      )
    (@column.ColumnData::String(a), @column.ColumnData::String(b)) =>
      compare_cells(
        a.length(),
        left_valid=lv,
        right_valid=rv,
        get_left=i => a[i],
        get_right=i => b[i],
        less_than=(x, y) => @types.compare_string_lex(x, y) < 0,
        equal=(x, y) => x == y,
        verb~,
      )
    (@column.ColumnData::Bool(_) | @column.ColumnData::String(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::String(_)) =>
      raise @types.DataError::TypeMismatch(
        binary_type_mismatch_msg("compare", left, right),
      )
  }
  Series::from_bool_options(left.name(), cells)
}
