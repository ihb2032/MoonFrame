///|
/// The comparison kernel (`eq` / `ne` / `lt` / `le` / `gt` / `ge`). `CmpVerb`
/// re-tags the six comparison `BinOp`s so the cell loop matches
/// exhaustively; `apply_cmp` derives every verdict from the dtype's `lt` / `eq`
/// primitives (so IEEE NaN falls out right — a comparison against NaN is
/// `false`, `ne` `true`), and `compare_cells` adds the null layer. Produces a
/// `Bool` column on the `Builtin` backend.

///|
/// Which comparison a `Binary` comparison tag asked for, carried into the
/// shared cell loop. A re-tag of the six `BinOp` comparison constructors
/// so `compare_cells` can match exhaustively without dead arms for the
/// non-comparison tags (`Add` / `And` / … never reach it); `frame`'s evaluator
/// picks the verb when it dispatches a comparison node.
pub(all) enum CmpVerb {
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
fn[T] CmpVerb::apply_cmp(
  self : CmpVerb,
  lt : (T, T) -> Bool,
  eq : (T, T) -> Bool,
  x : T,
  y : T,
) -> Bool {
  match self {
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
fn CmpVerb::transpose_verb(self : CmpVerb) -> CmpVerb {
  match self {
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
/// widening would produce. NaN falls out right through the `@numeric`
/// primitives (every comparison with it is `false`).
fn CmpVerb::cmp_int_double(self : CmpVerb, a : Int64, b : Double) -> Bool {
  match self {
    CmpVerb::Eq => @numeric.int64_eq_double(a, b)
    CmpVerb::Ne => !@numeric.int64_eq_double(a, b)
    CmpVerb::Lt => @numeric.int64_lt_double(a, b)
    CmpVerb::Le =>
      @numeric.int64_lt_double(a, b) || @numeric.int64_eq_double(a, b)
    CmpVerb::Gt => @numeric.double_lt_int64(b, a)
    CmpVerb::Ge =>
      @numeric.double_lt_int64(b, a) || @numeric.int64_eq_double(a, b)
  }
}

///|
/// Build the `Bool?` cells of one comparison over two equal-length
/// operands, given a cell reader per side and the dtype's two primitive
/// predicates. The verdict itself is `apply_cmp` (NaN semantics live
/// there); the null layer is the shared `zip_present` gate every binary
/// kernel uses — NaN is a *value* (the cell stays non-null), while a null
/// on either side nulls the cell before the predicates run.
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
  zip_present(n, left_valid, right_valid, i => {
    verb.apply_cmp(less_than, equal, get_left(i), get_right(i))
  })
}

///|
/// Comparison kernel over two equal-length operands
/// (post-`broadcast_pair`), producing a nullable `Bool` column. This kernel
/// is the one home of the cell comparison matrix: `Int ↔ Float` compare
/// **exactly** (no `Int`→`Double`
/// promotion — `cmp_int_double` compares them exactly), `String` compares by
/// `compare_string_lex` (dictionary order — MoonBit's
/// built-in `String` order is shortlex), `Bool` orders `false < true`,
/// and any other pairing — including `Bool` / `String` against numbers —
/// raises `TypeMismatch`. Null and NaN behavior live in `compare_cells`.
pub fn eval_compare(
  left : Series,
  right : Series,
  verb : CmpVerb,
) -> Series raise @types.DataError {
  // `Numeric`×`Numeric` fast arm, as in `eval_arith`: both sides all-valid,
  // so every cell compares — build the `Bool` cells directly through
  // `apply_cmp`, with no validity arrays and no `Bool?` boxing. The result
  // is nullable-free but `Bool`, so it lands on `Builtin` (`from_bools`),
  // same as the general arm's all-valid output.
  match (left.storage(), right.storage()) {
    (@column.ColumnStorage::Numeric(x), @column.ColumnStorage::Numeric(y)) =>
      return match (x.numeric_data(), y.numeric_data()) {
        (@column.NumericData::Int(a), @column.NumericData::Int(b)) =>
          Series::from_bools(
            left.name(),
            Array::makei(a.length(), i => {
              verb.apply_cmp((x, y) => x < y, (x, y) => x == y, a[i], b[i])
            }),
          )
        (@column.NumericData::Int(a), @column.NumericData::Float(b)) =>
          Series::from_bools(
            left.name(),
            Array::makei(a.length(), i => verb.cmp_int_double(a[i], b[i])),
          )
        (@column.NumericData::Float(a), @column.NumericData::Int(b)) =>
          Series::from_bools(
            left.name(),
            Array::makei(a.length(), i => {
              verb.transpose_verb().cmp_int_double(b[i], a[i])
            }),
          )
        (@column.NumericData::Float(a), @column.NumericData::Float(b)) =>
          Series::from_bools(
            left.name(),
            Array::makei(a.length(), i => {
              verb.apply_cmp((x, y) => x < y, (x, y) => x == y, a[i], b[i])
            }),
          )
      }
    (@column.ColumnStorage::Builtin(_), _)
    | (_, @column.ColumnStorage::Builtin(_)) => ()
  }
  let lv = left.validity_bools()
  let rv = right.validity_bools()
  let cells = match (left.storage().data(), right.storage().data()) {
    // The dtype gates read `DataType::comparable_with`: the same dtype
    // compares, two numerics compare, and an I64 rider (Date) never compares
    // against a plain Int through the shared buffer.
    (@column.ColumnData::I64(a), @column.ColumnData::I64(b)) if left
      .dtype()
      .comparable_with(right.dtype()) =>
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
    (@column.ColumnData::I64(a), @column.ColumnData::F64(b)) if left
      .dtype()
      .comparable_with(right.dtype()) =>
      // The mixed pair's two sides have different cell types, so a
      // single-`T` reader / predicate does not fit; the per-row verdict is
      // taken directly over the same shared null gate.
      zip_present(a.length(), lv, rv, i => verb.cmp_int_double(a[i], b[i]))
    (@column.ColumnData::F64(a), @column.ColumnData::I64(b)) if left
      .dtype()
      .comparable_with(right.dtype()) =>
      zip_present(a.length(), lv, rv, i => {
        verb.transpose_verb().cmp_int_double(b[i], a[i])
      })
    (@column.ColumnData::F64(a), @column.ColumnData::F64(b)) =>
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
    (@column.ColumnData::Utf8(a), @column.ColumnData::Utf8(b)) => {
      // Decoded once per side: the comparison reads materialised strings
      // rather than decoding each cell per comparison.
      let sa = a.to_strings()
      let sb = b.to_strings()
      compare_cells(
        sa.length(),
        left_valid=lv,
        right_valid=rv,
        get_left=i => sa[i],
        get_right=i => sb[i],
        less_than=(x, y) => @text.compare_string_lex(x, y) < 0,
        equal=(x, y) => x == y,
        verb~,
      )
    }
    (@column.ColumnData::I64(_), @column.ColumnData::I64(_))
    | (@column.ColumnData::I64(_), @column.ColumnData::F64(_))
    | (@column.ColumnData::F64(_), @column.ColumnData::I64(_))
    | (@column.ColumnData::Bool(_) | @column.ColumnData::Utf8(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::Utf8(_)) =>
      raise binary_type_mismatch_error("compare", left, right)
  }
  Series::from_bool_options(left.name(), cells)
}
