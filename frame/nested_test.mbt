// Blackbox tests for nested columns through the public frame and
// expression surface — what a user can do with a `List` / `Struct`
// column, and what refuses loudly rather than answering something
// else. The support: the row verbs, the comparison operators, a nested
// literal, sorting and grouping by a nested column, joining on one, and
// stacking. The refusals: every arithmetic, statistical, logical,
// string, and casting operator.

///|
fn lv(cells : Array[@types.Scalar]) -> @types.Scalar {
  @types.Scalar::List(@types.ListValue::ListValue(cells))
}

///|
fn fv(name : String, value : @types.Scalar) -> @types.FieldValue {
  @types.FieldValue::FieldValue(name, value)
}

///|
fn sv(a : @types.Scalar, b : @types.Scalar) -> @types.Scalar {
  @types.Scalar::Struct(
    @types.StructValue::StructValue([fv("a", a), fv("b", b)]),
  )
}

///|
fn ints(cells : Array[Int64]) -> @types.Scalar {
  lv(cells.map(i => @types.Scalar::Int(i)))
}

///|
fn list_column(name : String) -> Series raise @types.DataError {
  Series::from_scalars(
    name,
    [ints([1, 2]), @types.Scalar::Null, ints([1]), lv([]), ints([3])],
    dtype=@types.DataType::List(@types.DataType::Int),
  )
}

///|
fn struct_dtype() -> @types.DataType raise @types.DataError {
  @types.DataType::Struct(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
      @types.Field::Field("b", @types.DataType::String),
    ]),
  )
}

///|
fn struct_column(name : String) -> Series raise @types.DataError {
  Series::from_scalars(
    name,
    [
      sv(@types.Scalar::Int(2), @types.Scalar::String("x")),
      @types.Scalar::Null,
      sv(@types.Scalar::Int(1), @types.Scalar::String("y")),
    ],
    dtype=struct_dtype(),
  )
}

///|
fn lists_frame() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("k", ["p", "p", "q", "q", "r"]),
    list_column("l"),
  ])
}

///|
/// Run an operator that must refuse a nested column, and answer `""` when
/// it raised a `TypeMismatch` naming `verb` — as the operation's own name
/// or inside its message — any other outcome answers the reason it fell
/// short. A helper rather than the assertion itself because `fail` raises
/// a different error type than this package's verbs do.
fn refusal_message(
  verb : String,
  run : () -> DataFrame raise @types.DataError,
) -> String {
  let got : Result[DataFrame, @types.DataError] = Ok(run()) catch {
    e => Err(e)
  }
  match got {
    Err(@types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(m))) =>
      if m.contains(verb) {
        ""
      } else {
        "expected a TypeMismatch naming \{verb}, got: \{m}"
      }
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Operation(op, _, _),
      ),
    ) =>
      if op == verb {
        ""
      } else {
        "expected a TypeMismatch for \{verb}, got the operation \{op}"
      }
    Err(e) => "expected a TypeMismatch for \{verb}, got: \{e}"
    Ok(_) => "\{verb} was expected to refuse a nested column"
  }
}

///|
test "the row verbs carry a nested column through" {
  let df = lists_frame()
  assert_eq(df.columns(), ["k", "l"])
  assert_eq(df.get_column("l").dtype(), list_column("l").dtype())
  // Select, rename, drop, and a window keep the nested cells whole.
  let picked = df.select([@expr.col("l")])
  assert_eq(picked.columns(), ["l"])
  assert_eq(picked.get_column("l"), list_column("l"))
  let renamed = df.rename([("l", "tags")])
  assert_eq(renamed.columns(), ["k", "tags"])
  assert_eq(renamed.get_column("tags"), list_column("tags"))
  assert_eq(df.drop([@expr.col("k")]).columns(), ["l"])
  assert_eq(df.head(2).get_column("l").to_scalars().copy(), [
    ints([1, 2]),
    @types.Scalar::Null,
  ])
  assert_eq(df.reverse().get_column("l").to_scalars().copy(), [
    ints([3]),
    lv([]),
    ints([1]),
    @types.Scalar::Null,
    ints([1, 2]),
  ])
  // A filter on another column moves the nested cells with their rows.
  let filtered = df.filter(
    @expr.col("k").eq(@expr.lit(@types.Scalar::String("q"))),
  )
  assert_eq(filtered.get_column("l").to_scalars().copy(), [ints([1]), lv([])])
  // A null nested cell drops under drop_nulls, with its row.
  let dropped = df.drop_nulls()
  assert_eq(dropped.shape(), (4, 2))
  assert_eq(dropped.get_column("l").null_count(), 0)
  // Stacking two frames stacks the nested columns.
  let stacked = df.vstack(df)
  assert_eq(stacked.shape(), (10, 2))
  assert_eq(stacked.get_column("l").to_scalars().copy(), [
    ints([1, 2]),
    @types.Scalar::Null,
    ints([1]),
    lv([]),
    ints([3]),
    ints([1, 2]),
    @types.Scalar::Null,
    ints([1]),
    lv([]),
    ints([3]),
  ])
  // A nested column replaces through with_columns and sits beside a
  // computed one.
  let added = df.with_columns([
    @expr.col("k").with_alias("k2"),
    @expr.col("l").with_alias("l2"),
  ])
  assert_eq(added.columns(), ["k", "l", "k2", "l2"])
  assert_eq(added.get_column("l2"), list_column("l2"))
}

///|
test "nested columns compare by value for equality and by order" {
  let df = DataFrame::DataFrame([
    list_column("l"),
    Series::from_scalars(
      "m",
      [ints([1, 2]), ints([9]), ints([1]), ints([1]), @types.Scalar::Null],
      dtype=@types.DataType::List(@types.DataType::Int),
    ),
  ])
  // Equality is structural; a null on either side is an unknown.
  let eq = df.select([@expr.col("l").eq(@expr.col("m")).with_alias("e")])
  assert_eq(eq.get_column("e").to_scalars().copy(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
  let ne = df.select([@expr.col("l").ne(@expr.col("m")).with_alias("n")])
  assert_eq(ne.get_column("n").to_scalars().copy(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
  ])
  // The order is the sort order: lexicographic.
  let lt = df.select([@expr.col("l").lt(@expr.col("m")).with_alias("t")])
  assert_eq(lt.get_column("t").to_scalars().copy(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
  ])
  let gt = df.select([@expr.col("m").gt(@expr.col("l")).with_alias("g")])
  assert_eq(gt.get_column("g").to_scalars().copy(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
  ])
  let le = df.select([@expr.col("l").le(@expr.col("m")).with_alias("e")])
  assert_eq(le.get_column("e").to_scalars().copy(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
  ])
  let ge = df.select([@expr.col("m").ge(@expr.col("l")).with_alias("e")])
  assert_eq(ge.get_column("e").to_scalars().copy(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Null,
  ])
  // The null probes read the cells' validity.
  let nulls = df.select([@expr.col("l").is_null().with_alias("n")])
  assert_eq(nulls.get_column("n").to_scalars().copy(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
  ])
}

///|
test "a nested literal compares against a nested column" {
  let df = lists_frame()
  let matched = df.filter(@expr.col("l").eq(@expr.lit(ints([1]))))
  assert_eq(matched.get_column("k").to_scalars().copy(), [
    @types.Scalar::String("q"),
  ])
  // A literal with a null beside a present element names its dtype and
  // compares; the frame holds no such cell.
  let with_null = df.filter(
    @expr.col("l").eq(
      @expr.lit(lv([@types.Scalar::Null, @types.Scalar::Int(1)])),
    ),
  )
  assert_eq(with_null.shape(), (0, 2))
  // A struct literal against a struct column.
  let s = DataFrame::DataFrame([struct_column("s")])
  let one = s.filter(
    @expr.col("s").eq(
      @expr.lit(sv(@types.Scalar::Int(1), @types.Scalar::String("y"))),
    ),
  )
  assert_eq(one.shape(), (1, 1))
  // A nested literal of another dtype than the column's is a type
  // mismatch — the columns do not unify.
  let other = DataFrame::DataFrame([struct_column("s")])
  let cross = Ok(
    ignore(
      other.select([@expr.col("s").eq(@expr.lit(ints([1]))).with_alias("x")]),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(cross is Err(@types.DataError::TypeMismatch(_)))
  // A nested literal that names no dtype cannot become a column.
  let unnamed = DataFrame::DataFrame([Series::from_ints("v", [1])])
  for bad in [lv([]), lv([@types.Scalar::Null])] {
    let refused = Ok(ignore(unnamed.select([@expr.lit(bad).with_alias("x")]))) catch {
      e => Err(e)
    }
    assert_true(
      refused is Err(@types.DataError::Unsupported(m)) &&
      m.contains("nested literal"),
    )
  }
}

///|
test "is_in tests a nested cell against nested members" {
  let df = lists_frame()
  let membership = df.select([
    @expr.col("l").is_in([ints([1]), ints([3])]).with_alias("m"),
  ])
  assert_eq(membership.get_column("m").to_scalars().copy(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
  ])
}

///|
test "a frame sorts, groups, and deduplicates by a nested column" {
  let df = lists_frame()
  let sorted = df.sort([(@expr.col("l"), false, false)])
  assert_eq(sorted.get_column("k").to_scalars().copy(), [
    @types.Scalar::String("p"),
    @types.Scalar::String("q"),
    @types.Scalar::String("q"),
    @types.Scalar::String("p"),
    @types.Scalar::String("r"),
  ])
  assert_eq(sorted.get_column("l").to_scalars().copy(), [
    @types.Scalar::Null,
    lv([]),
    ints([1]),
    ints([1, 2]),
    ints([3]),
  ])
  // A group per distinct list; the null cell is its own group.
  let grouped = df.group_by([@expr.col("l")]).len()
  assert_eq(grouped.shape(), (5, 2))
  // Two frames join on a nested key.
  let left = DataFrame::DataFrame([
    list_column("l"),
    Series::from_strings("side", ["a", "a", "a", "a", "a"]),
  ])
  let right = DataFrame::DataFrame([
    Series::from_scalars(
      "l",
      [ints([1]), ints([3]), ints([1, 2])],
      dtype=@types.DataType::List(@types.DataType::Int),
    ),
    Series::from_strings("r", ["one", "three", "two"]),
  ])
  let joined = left.join(right, JoinOptions::on([@expr.col("l")]))
  assert_eq(joined.shape(), (3, 3))
  assert_eq(joined.get_column("r").to_scalars().copy(), [
    @types.Scalar::String("two"),
    @types.Scalar::String("one"),
    @types.Scalar::String("three"),
  ])
  // A left join keeps the unmatched rows, null-extended.
  let left_join = left.join(
    right,
    JoinOptions::on([@expr.col("l")], how=JoinType::Left),
  )
  assert_eq(left_join.shape(), (5, 3))
  assert_eq(left_join.get_column("l").to_scalars().copy(), [
    ints([1, 2]),
    @types.Scalar::Null,
    ints([1]),
    lv([]),
    ints([3]),
  ])
  assert_eq(left_join.get_column("r").null_count(), 2)
  // Unique over every column keeps one of each distinct row.
  let unique = df.unique()
  assert_eq(unique.shape(), (5, 2))
}

///|
test "a grouped extremum and count read nested cells" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    Series::from_scalars(
      "l",
      [ints([3]), ints([1, 9]), ints([2])],
      dtype=@types.DataType::List(@types.DataType::Int),
    ),
  ])
  let grouped = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("l").min().with_alias("lo"),
      @expr.col("l").max().with_alias("hi"),
      @expr.col("l").first().with_alias("first"),
      @expr.col("l").last().with_alias("last"),
    ])
  assert_eq(grouped.shape(), (2, 5))
  assert_eq(grouped.get_column("lo").to_scalars().copy(), [
    ints([1, 9]),
    ints([2]),
  ])
  assert_eq(grouped.get_column("hi").to_scalars().copy(), [ints([3]), ints([2])])
  assert_eq(grouped.get_column("first").to_scalars().copy(), [
    ints([3]),
    ints([2]),
  ])
  assert_eq(grouped.get_column("last").to_scalars().copy(), [
    ints([1, 9]),
    ints([2]),
  ])
  // n_unique and count work on the nested column.
  let counted = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("l").n_unique().with_alias("n"),
      @expr.col("l").count().with_alias("c"),
    ])
  assert_eq(counted.get_column("n").to_scalars().copy(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(1),
  ])
  assert_eq(counted.get_column("c").to_scalars().copy(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(1),
  ])
}

///|
test "a struct column rides the same verbs" {
  let df = DataFrame::DataFrame([
    struct_column("s"),
    Series::from_ints("v", [10, 20, 30]),
  ])
  assert_eq(df.get_column("s").dtype(), struct_dtype())
  let sorted = df.sort([(@expr.col("s"), false, false)])
  assert_eq(sorted.get_column("v").to_scalars().copy(), [
    @types.Scalar::Int(20),
    @types.Scalar::Int(30),
    @types.Scalar::Int(10),
  ])
  let grouped = df.group_by([@expr.col("s")]).len()
  assert_eq(grouped.shape(), (3, 2))
  let picked = s_head(df)
  assert_eq(picked.get_column("s"), struct_column("s").head(1))
}

///|
fn s_head(df : DataFrame) -> DataFrame {
  df.head(1)
}

///|
test "arithmetic and the numeric verbs refuse a nested column" {
  let df = DataFrame::DataFrame([
    list_column("l"),
    Series::from_ints("v", [1, 1, 1, 1, 1]),
  ])
  let l = @expr.col("l")
  let v = @expr.col("v")
  assert_eq(
    refusal_message("add", fn() -> DataFrame raise @types.DataError {
      df.select([l.add(v).with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("subtract", fn() -> DataFrame raise @types.DataError {
      df.select([l.sub(v).with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("multiply", fn() -> DataFrame raise @types.DataError {
      df.select([v.mul(l).with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("negate", fn() -> DataFrame raise @types.DataError {
      df.select([l.neg().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("take the absolute value of", fn() -> DataFrame raise @types.DataError {
      df.select([l.abs().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("round", fn() -> DataFrame raise @types.DataError {
      df.select([l.round().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("ceil", fn() -> DataFrame raise @types.DataError {
      df.select([l.ceil().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("floor", fn() -> DataFrame raise @types.DataError {
      df.select([l.floor().with_alias("x")])
    }),
    "",
  )
  // The whole-frame statistics refuse the same way.
  assert_eq(
    refusal_message("sum", fn() -> DataFrame raise @types.DataError {
      df.select([l.sum().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("mean", fn() -> DataFrame raise @types.DataError {
      df.select([l.mean().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("std", fn() -> DataFrame raise @types.DataError {
      df.select([l.std().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("cumulative sum", fn() -> DataFrame raise @types.DataError {
      df.select([l.cum_sum().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("rolling sum", fn() -> DataFrame raise @types.DataError {
      df.select([l.rolling_sum(2).with_alias("x")])
    }),
    "",
  )
  // A nested column cast nowhere.
  let cast = Ok(ignore(df.get_column("l").cast(@types.DataType::Int))) catch {
    e => Err(e)
  }
  assert_true(cast is Err(@types.DataError::Unsupported(_)))
}

///|
test "logical, string, and the numeric probes refuse a nested column" {
  let df = DataFrame::DataFrame([
    list_column("l"),
    Series::from_ints("v", [1, 1, 1, 1, 1]),
  ])
  let l = @expr.col("l")
  assert_eq(
    refusal_message("logical 'and'", fn() -> DataFrame raise @types.DataError {
      df.select([l.land(l).with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("logical 'not'", fn() -> DataFrame raise @types.DataError {
      df.select([l.not().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("string operation", fn() -> DataFrame raise @types.DataError {
      df.select([l.str_to_uppercase().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("is_nan", fn() -> DataFrame raise @types.DataError {
      df.select([l.is_nan().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("is_finite", fn() -> DataFrame raise @types.DataError {
      df.select([l.is_finite().with_alias("x")])
    }),
    "",
  )
  // A struct column refuses the same operators, naming its own dtype.
  let s = DataFrame::DataFrame([struct_column("s")])
  let sc = @expr.col("s")
  assert_eq(
    refusal_message("Struct", fn() -> DataFrame raise @types.DataError {
      s.select([sc.neg().with_alias("x")])
    }),
    "",
  )
}

///|
fn lit_or_otherwise(
  df : DataFrame,
  cond : @expr.Expr,
  then : @expr.Expr,
  other : @expr.Expr,
) -> DataFrame raise @types.DataError {
  df.select([@expr.when(cond).then(then).otherwise(other).with_alias("x")])
}

///|
test "when/then/otherwise selects whole nested cells" {
  let df = DataFrame::DataFrame([
    list_column("l"),
    Series::from_bool_options("b", [
      Some(true),
      None,
      Some(false),
      Some(true),
      Some(false),
    ]),
  ])
  // A true condition takes the `then` cell, a false one the `otherwise`
  // cell, a null condition nulls the row, and a null branch cell stays
  // null when it is the one selected.
  let other = Series::from_scalars(
    "m",
    [ints([9]), ints([8]), @types.Scalar::Null, ints([7]), ints([6])],
    dtype=@types.DataType::List(@types.DataType::Int),
  )
  let frame = DataFrame::DataFrame([
    df.get_column("l"),
    df.get_column("b"),
    other,
  ])
  let picked = lit_or_otherwise(
    frame,
    @expr.col("b"),
    @expr.col("l"),
    @expr.col("m"),
  )
  assert_eq(picked.get_column("x").dtype(), list_column("l").dtype())
  assert_eq(picked.get_column("x").to_scalars().copy(), [
    ints([1, 2]),
    @types.Scalar::Null,
    @types.Scalar::Null,
    lv([]),
    ints([6]),
  ])
  // A struct column selects the same way.
  let structs = DataFrame::DataFrame([
    struct_column("s"),
    Series::from_bools("b", [false, true, true]),
  ])
  let struct_picked = lit_or_otherwise(
    structs,
    @expr.col("b"),
    @expr.col("s"),
    @expr.col("s"),
  )
  assert_eq(struct_picked.get_column("x").to_scalars().copy(), [
    sv(@types.Scalar::Int(2), @types.Scalar::String("x")),
    @types.Scalar::Null,
    sv(@types.Scalar::Int(1), @types.Scalar::String("y")),
  ])
}

///|
test "when/then/otherwise refuses a nested condition or mismatched branches" {
  let df = DataFrame::DataFrame([
    list_column("l"),
    Series::from_bools("b", [true, true, false, false, true]),
  ])
  let l = @expr.col("l")
  // A nested condition is not a Bool.
  assert_eq(
    refusal_message("when condition must be Bool", fn() -> DataFrame raise @types.DataError {
      lit_or_otherwise(df, l, @expr.lit_int(1), @expr.lit_int(0))
    }),
    "",
  )
  // Branches of different nested dtypes do not unify.
  let mixed = DataFrame::DataFrame([
    list_column("l"),
    Series::from_scalars(
      "s",
      [
        sv(@types.Scalar::Int(1), @types.Scalar::String("x")),
        @types.Scalar::Null,
        sv(@types.Scalar::Int(2), @types.Scalar::String("y")),
        sv(@types.Scalar::Int(3), @types.Scalar::String("z")),
        @types.Scalar::Null,
      ],
      dtype=struct_dtype(),
    ),
  ])
  assert_eq(
    refusal_message("do not unify", fn() -> DataFrame raise @types.DataError {
      lit_or_otherwise(
        mixed,
        @expr.col("l").is_not_null(),
        @expr.col("l"),
        @expr.col("s"),
      )
    }),
    "",
  )
  // A nested branch beside a scalar one does not unify either.
  let scalars = DataFrame::DataFrame([
    list_column("l"),
    Series::from_bools("b", [true, true, false, false, true]),
    Series::from_ints("v", [1, 2, 3, 4, 5]),
  ])
  assert_eq(
    refusal_message("do not unify", fn() -> DataFrame raise @types.DataError {
      lit_or_otherwise(scalars, @expr.col("b"), @expr.col("l"), @expr.col("v"))
    }),
    "",
  )
}

///|
test "clip reads a nested column through its comparisons" {
  // `clip` is a pair of `when/then/otherwise` selections over `lt` /
  // `gt`; on a nested column those compare by the total order, so the
  // verb clamps lists lexicographically.
  let df = DataFrame::DataFrame([
    Series::from_scalars(
      "l",
      [ints([5]), ints([1]), lv([]), @types.Scalar::Null, ints([2, 9])],
      dtype=@types.DataType::List(@types.DataType::Int),
    ),
  ])
  let clamped = df.select([
    @expr.col("l")
    .clip(lower=@expr.lit(ints([1])), upper=@expr.lit(ints([2])))
    .with_alias("c"),
  ])
  assert_eq(clamped.get_column("c").to_scalars().copy(), [
    ints([2]),
    ints([1]),
    ints([1]),
    @types.Scalar::Null,
    ints([2]),
  ])
}

///|
test "a nested column renders in the table and the text formats" {
  let df = lists_frame().head(3)
  // The Markdown table shows each nested cell in its JSON shape.
  let table = df.to_markdown()
  assert_true(table.contains("[1, 2]"))
  // CSV: one quoted field per nested cell.
  let csv = @io.format_csv(df)
  assert_true(csv.contains("\"[1, 2]\""))
}

///|
test "the positional verbs read nested cells" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "b", "c", "d", "e"]),
    list_column("l"),
  ])
  let l = @expr.col("l")
  // shift moves whole cells down and leaves the gap null.
  let shifted = df.select([l.shift(1).with_alias("x")])
  assert_eq(shifted.get_column("x").to_scalars().copy(), [
    @types.Scalar::Null,
    ints([1, 2]),
    @types.Scalar::Null,
    ints([1]),
    lv([]),
  ])
  // A fill value takes the gap when it fits the dtype — and only the
  // gap: a cell that was already null stays null.
  let filled = df.select([l.shift(1, fill_value=lv([])).with_alias("x")])
  assert_eq(filled.get_column("x").to_scalars().copy(), [
    lv([]),
    ints([1, 2]),
    @types.Scalar::Null,
    ints([1]),
    lv([]),
  ])
  let bad_fill = Ok(
    ignore(
      df.select([l.shift(1, fill_value=@types.Scalar::Int(9)).with_alias("x")]),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    bad_fill
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(m)),
    ) &&
    m.contains("shift fill"),
  )
  // rank orders by the total order and ranks a null cell null — the
  // default method averages, so the column is `Float`.
  let ranked = df.select([l.rank().with_alias("x")])
  assert_eq(ranked.get_column("x").dtype(), @types.DataType::Float)
  assert_eq(ranked.get_column("x").to_scalars().copy(), [
    @types.Scalar::Float(3.0),
    @types.Scalar::Null,
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(4.0),
  ])
  let mins = df.select([l.rank(how=@types.RankMethod::Min).with_alias("x")])
  assert_eq(mins.get_column("x").dtype(), @types.DataType::Int)
  assert_eq(mins.get_column("x").to_scalars().copy(), [
    @types.Scalar::Int(3),
    @types.Scalar::Null,
    @types.Scalar::Int(2),
    @types.Scalar::Int(1),
    @types.Scalar::Int(4),
  ])
  // cum_count is dtype-blind: the running count of present cells, a
  // null slot repeating the count before it.
  let counted = df.select([l.cum_count().with_alias("x")])
  assert_eq(counted.get_column("x").to_scalars().copy(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
    @types.Scalar::Int(4),
  ])
  // forward_fill carries the last present cell into the null.
  let carried = df.select([l.forward_fill().with_alias("x")])
  assert_eq(carried.get_column("x").to_scalars().copy(), [
    ints([1, 2]),
    ints([1, 2]),
    ints([1]),
    lv([]),
    ints([3]),
  ])
  // Distinctness is structural: each list here occurs once.
  let firsts = df.select([l.is_first_distinct().with_alias("x")])
  assert_eq(firsts.get_column("x").to_scalars().copy(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
  ])
  let tallies = df.select([l.unique_counts().with_alias("x")])
  assert_eq(tallies.get_column("x").to_scalars().copy(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
  ])
  // arg_sort places the null first by default, and last when asked.
  let args = df.select([l.arg_sort().with_alias("x")])
  assert_eq(args.get_column("x").to_scalars().copy(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(3),
    @types.Scalar::Int(2),
    @types.Scalar::Int(0),
    @types.Scalar::Int(4),
  ])
  let args_last = df.select([l.arg_sort(nulls_last=true).with_alias("x")])
  assert_eq(args_last.get_column("x").to_scalars().copy(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(2),
    @types.Scalar::Int(0),
    @types.Scalar::Int(4),
    @types.Scalar::Int(1),
  ])
  // A repeated list ties in the rank and loses its later firsts.
  let repeated = DataFrame::DataFrame([
    Series::from_scalars(
      "l",
      [ints([2]), @types.Scalar::Null, ints([1]), ints([2])],
      dtype=@types.DataType::List(@types.DataType::Int),
    ),
  ])
  let r = @expr.col("l")
  let tied = repeated.select([r.rank().with_alias("x")])
  assert_eq(tied.get_column("x").to_scalars().copy(), [
    @types.Scalar::Float(2.5),
    @types.Scalar::Null,
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.5),
  ])
  let once = repeated.select([r.is_first_distinct().with_alias("x")])
  assert_eq(once.get_column("x").to_scalars().copy(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
  ])
  let twice = repeated.select([r.unique_counts().with_alias("x")])
  assert_eq(twice.get_column("x").to_scalars().copy(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
}

///|
test "the arithmetic positional verbs refuse a nested column" {
  let df = DataFrame::DataFrame([list_column("l")])
  let l = @expr.col("l")
  // The running extremum takes a numeric operand only — a nested column
  // refuses exactly as `Bool` / `String` do.
  assert_eq(
    refusal_message("cumulative min", fn() -> DataFrame raise @types.DataError {
      df.select([l.cum_min().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("cumulative max", fn() -> DataFrame raise @types.DataError {
      df.select([l.cum_max().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("cumulative product", fn() -> DataFrame raise @types.DataError {
      df.select([l.cum_prod().with_alias("x")])
    }),
    "",
  )
  // diff is a shift then a subtraction: the shift reads the nested cells,
  // the subtraction refuses.
  assert_eq(
    refusal_message("subtract", fn() -> DataFrame raise @types.DataError {
      df.select([l.diff().with_alias("x")])
    }),
    "",
  )
  // The transcendental verbs refuse through their own message.
  assert_eq(
    refusal_message("take the square root of", fn() -> DataFrame raise @types.DataError {
      df.select([l.sqrt().with_alias("x")])
    }),
    "",
  )
  assert_eq(
    refusal_message("exponentiate", fn() -> DataFrame raise @types.DataError {
      df.select([l.exp().with_alias("x")])
    }),
    "",
  )
}

///|
test "a nested bound on a numeric clip does not clamp silently" {
  // The clip fast pass declines a nested bound, and the comparisons the
  // composed kernel then runs refuse a numeric column against a `List` —
  // so a nested bound is never read as a number. Each numeric buffer has
  // its own bound pass; both decline.
  let df = DataFrame::DataFrame([
    Series::from_ints("i", [1, 2, 3]),
    Series::from_floats("f", [1.5, 2.5, 3.5]),
    list_column("l").head(3),
  ])
  let l = @expr.col("l")
  let attempts : Array[() -> DataFrame raise @types.DataError] = [
    fn() -> DataFrame raise @types.DataError {
      df.select([@expr.col("i").clip(lower=l).with_alias("x")])
    },
    fn() -> DataFrame raise @types.DataError {
      df.select([@expr.col("i").clip(upper=l).with_alias("x")])
    },
    fn() -> DataFrame raise @types.DataError {
      df.select([@expr.col("f").clip(lower=l).with_alias("x")])
    },
    fn() -> DataFrame raise @types.DataError {
      df.select([@expr.col("f").clip(upper=l).with_alias("x")])
    },
  ]
  for attempt in attempts {
    let got = Ok(ignore(attempt())) catch { e => Err(e) }
    match got {
      Err(
        @types.DataError::TypeMismatch(
          @types.TypeMismatchDetail::Operation(op, _, _),
        ),
      ) => assert_eq(op, "compare")
      _ => fail("a nested clip bound was expected to refuse")
    }
  }
}

///|
test "the whole-frame extrema read a nested column's order" {
  // `min` / `max` over the whole frame answer for a nested column by the
  // order its sort reads — agreeing with the expression, the `Series`,
  // and what `describe` reports — while `sum` / `mean` leave a `Null`
  // cell, as they do for every column that does not sum.
  let df = lists_frame()
  let low = df.min()
  assert_eq(low.get_column("l").to_scalars().copy(), [lv([])])
  assert_eq(df.max().get_column("l").to_scalars().copy(), [ints([3])])
  assert_eq(df.sum().get_column("l").to_scalars().copy(), [@types.Scalar::Null])
  assert_eq(df.mean().get_column("l").to_scalars().copy(), [@types.Scalar::Null])
  let s = DataFrame::DataFrame([struct_column("s")])
  assert_eq(s.min().get_column("s").to_scalars().copy(), [
    sv(@types.Scalar::Int(1), @types.Scalar::String("y")),
  ])
  assert_eq(s.max().get_column("s").to_scalars().copy(), [
    sv(@types.Scalar::Int(2), @types.Scalar::String("x")),
  ])
}
