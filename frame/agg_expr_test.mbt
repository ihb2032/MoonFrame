///|
/// Blackbox behavior tests for `GroupedDataFrame::agg`: single-column and
/// compound / derived reductions, the reduction-shape gate and its
/// structural (data-independent) rejection, naming and collision rules,
/// all-null / NaN group semantics, zero-group frames, and the backend
/// convention for computed columns. The group-partitioning behaviour and
/// the historical `"<col>_<kind>"`-named reductions live in
/// group_by_test.mbt; the evaluator's own dtype / null / NaN rules live in
/// expr_eval_test.mbt.

///|
fn agg_expr_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("region", ["west", "east", "west", "east", "west"]),
    Series::from_ints("revenue", [10, 20, 30, 40, 50]),
    Series::from_ints("cost", [5, 25, 10, 20, 30]),
  ])
}

///|
test "single-column reductions reduce each group, cells and backend" {
  let out = agg_expr_df()
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("revenue").sum().with_alias("revenue_sum"),
      @expr.col("revenue").mean().with_alias("revenue_mean"),
      @expr.col("revenue").min().with_alias("revenue_min"),
      @expr.col("revenue").max().with_alias("revenue_max"),
      @expr.col("revenue").count().with_alias("revenue_count"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), [
    "region", "revenue_sum", "revenue_mean", "revenue_min", "revenue_max", "revenue_count",
  ])
  // Groups in first-appearance order: west = rows [0,2,4] (revenue
  // 10/30/50), east = rows [1,3] (20/40).
  assert_eq(out.get_column("revenue_sum").to_scalars(), [
    @types.Scalar::Int(90),
    @types.Scalar::Int(60),
  ])
  assert_eq(out.get_column("revenue_mean").to_scalars(), [
    @types.Scalar::Float(30.0),
    @types.Scalar::Float(30.0),
  ])
  assert_eq(out.get_column("revenue_min").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
  ])
  assert_eq(out.get_column("revenue_max").to_scalars(), [
    @types.Scalar::Int(50),
    @types.Scalar::Int(40),
  ])
  assert_eq(out.get_column("revenue_count").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(2),
  ])
  // This fixture has no null cell, so every reduction is all-valid and
  // converges onto the `Numeric` fast path.
  for
    name in [
      "revenue_sum", "revenue_mean", "revenue_min", "revenue_max", "revenue_count",
    ] {
    assert_eq(out.get_column(name).storage_kind(), @column.StorageKind::Numeric)
  }
}

///|
test "the single-pass fast path matches the general evaluator, values and backend" {
  // `col("v").<agg>()` takes the bare-column single-pass fast path; the same
  // reduction over the identity-derived operand `col("v") + lit_int(0)` is no
  // longer a bare column, so it falls to the general per-group evaluator —
  // yet `+ 0` changes no cell (`Int` identity, and a null stays null). The
  // optimization is sound only if the two paths agree on every value *and* on
  // the backend, so pin both. The "c" group is all-null, forcing
  // `mean` / `min` / `max` onto a null cell (the `Builtin` result) while
  // `sum` / `count` stay all-valid (the `Numeric` result), so both backends
  // are exercised on both paths.
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "b", "a", "c", "b", "a"]),
    Series::from_int_options("v", [
      Some(1),
      Some(4),
      None,
      None,
      Some(2),
      Some(3),
    ]),
  ])
  let builders : Array[(@expr.Expr) -> @expr.Expr] = [
    e => e.sum(),
    e => e.mean(),
    e => e.min(),
    e => e.max(),
    e => e.count(),
  ]
  for agg in builders {
    let fast = df
      .group_by([@expr.col("k")])
      .agg([agg(@expr.col("v")).with_alias("r")])
      .get_column("r")
    let slow = df
      .group_by([@expr.col("k")])
      .agg([agg(@expr.col("v") + @expr.lit_int(0)).with_alias("r")])
      .get_column("r")
    assert_eq(fast.to_scalars(), slow.to_scalars())
    assert_eq(fast.storage_kind(), slow.storage_kind())
  }
}

///|
test "compound aggregations: derived operands and combined reductions" {
  let out = agg_expr_df()
    .group_by([@expr.col("region")])
    .agg([
      (@expr.col("revenue") - @expr.col("cost")).sum().with_alias("profit"),
      (@expr.col("revenue").max() - @expr.col("revenue").min()).with_alias(
        "range",
      ),
    ])
  assert_eq(out.columns(), ["region", "profit", "range"])
  // west rows: profit 5+20+20, range 50-10; east rows: profit -5+20, range
  // 40-20. Group order is first appearance: west, then east.
  assert_eq(out.get_column("profit").to_scalars(), [
    @types.Scalar::Int(45),
    @types.Scalar::Int(15),
  ])
  assert_eq(out.get_column("range").to_scalars(), [
    @types.Scalar::Int(40),
    @types.Scalar::Int(20),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "multiple expressions over multiple keys" {
  let df = DataFrame::DataFrame([
    Series::from_strings("region", ["w", "w", "e", "e"]),
    Series::from_strings("product", ["a", "b", "a", "a"]),
    Series::from_ints("qty", [1, 2, 3, 4]),
  ])
  let out = df
    .group_by([@expr.col("region"), @expr.col("product")])
    .agg([
      @expr.col("qty").sum().with_alias("total"),
      @expr.col("qty").count().with_alias("n"),
    ])
  // Groups in first-appearance order: (w,a)=[0], (w,b)=[1], (e,a)=[2,3].
  assert_eq(out.columns(), ["region", "product", "total", "n"])
  assert_eq(out.shape(), (3, 4))
  assert_eq(out.get_column("total").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(7),
  ])
  assert_eq(out.get_column("n").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "all-null group: sum is the additive identity, mean and extrema are null" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    Series::from_int_options("v", [Some(1), Some(3), None]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("v").sum().with_alias("s"),
      @expr.col("v").mean().with_alias("m"),
      @expr.col("v").min().with_alias("lo"),
      @expr.col("v").count().with_alias("n"),
    ])
  assert_eq(out.get_column("s").to_scalars(), [
    @types.Scalar::Int(4),
    @types.Scalar::Int(0),
  ])
  assert_eq(out.get_column("m").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
  assert_eq(out.get_column("lo").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Null,
  ])
  assert_eq(out.get_column("n").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(0),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "NaN propagates through sum/mean and is skipped by max" {
  let nan : Double = @double.not_a_number
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    Series::from_floats("v", [1.0, nan, 2.0]),
    Series::from_floats("w", [nan, nan, 1.0]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("v").sum().with_alias("s"),
      @expr.col("v").mean().with_alias("m"),
      @expr.col("v").max().with_alias("hi"),
      @expr.col("w").max().with_alias("w_hi"),
      @expr.col("w").count().with_alias("w_n"),
    ])
  // Group a holds {1.0, NaN}: NaN is a value, so sum and mean are NaN,
  // while max skips it and returns 1.0.
  assert_true(out.get_column("s").get(0).as_float().is_nan())
  assert_true(out.get_column("m").get(0).as_float().is_nan())
  assert_eq(out.get_column("hi").get(0), @types.Scalar::Float(1.0))
  assert_eq(out.get_column("s").get(1), @types.Scalar::Float(2.0))
  // Group a is all-NaN in `w`: an extremum that skips every cell is a null
  // cell, yet count still sees two values — NaN is not missing.
  assert_eq(out.get_column("w_hi").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Float(1.0),
  ])
  assert_eq(out.get_column("w_n").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(1),
  ])
}

///|
test "scalar combinators: literal, neg, null probe, cast, when/then/otherwise" {
  let out = agg_expr_df()
    .group_by([@expr.col("region")])
    .agg([
      @expr.lit_int(1).with_alias("one"),
      (-@expr.col("revenue").sum()).with_alias("neg_total"),
      @expr.col("revenue").mean().is_null().with_alias("empty"),
      @expr.col("revenue")
      .sum()
      .cast(@types.DataType::Float)
      .with_alias("total_f"),
      @expr.when(@expr.col("cost").min().gt(@expr.lit_int(10)))
      .then(@expr.lit_str("pricey"))
      .otherwise(@expr.lit_str("cheap"))
      .with_alias("band"),
    ])
  assert_eq(out.get_column("one").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
  ])
  assert_eq(out.get_column("neg_total").to_scalars(), [
    @types.Scalar::Int(-90),
    @types.Scalar::Int(-60),
  ])
  assert_eq(out.get_column("empty").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(false),
  ])
  assert_eq(out.get_column("total_f").to_scalars(), [
    @types.Scalar::Float(90.0),
    @types.Scalar::Float(60.0),
  ])
  // west's cheapest cost is 5, east's is 20 — only east clears the bar.
  assert_eq(out.get_column("band").to_scalars(), [
    @types.Scalar::String("cheap"),
    @types.Scalar::String("pricey"),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "extrema cover Bool and String operands, all-null groups as null cells" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    Series::from_bool_options("flag", [Some(true), Some(false), None]),
    Series::from_string_options("tag", [Some("x"), Some("y"), None]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("flag").min().with_alias("flag_min"),
      @expr.col("tag").max().with_alias("tag_max"),
    ])
  assert_eq(out.get_column("flag_min").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
  assert_eq(out.get_column("tag_max").to_scalars(), [
    @types.Scalar::String("y"),
    @types.Scalar::Null,
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "expression naming: leftmost column reference, literal fallback" {
  let out = agg_expr_df()
    .group_by([@expr.col("region")])
    .agg([@expr.col("revenue").sum(), @expr.lit_int(7)])
  // The expression naming rule: a reduction over a bare column is named for
  // that column (no `"_sum"` suffix), a column-less literal is `"literal"`.
  assert_eq(out.columns(), ["region", "revenue", "literal"])
  assert_eq(out.get_column("literal").to_scalars(), [
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
  ])
}

///|
test "computed columns converge onto Numeric when all-valid, Builtin when not" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    Series::from_int_options("v", [Some(1), Some(3), None]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("v").sum().with_alias("s"), // all-valid Int
      @expr.col("v").mean().with_alias("m"), // null cell for group b
    ])
  assert_eq(out.get_column("s").storage_kind(), @column.StorageKind::Numeric)
  assert_eq(out.get_column("m").storage_kind(), @column.StorageKind::Builtin)
  // An all-valid mean (no null cell, no empty group) converges onto
  // `Numeric` rather than staying on the `Builtin` mean default.
  let all_valid = agg_expr_df()
    .group_by([@expr.col("region")])
    .agg([@expr.col("revenue").mean().with_alias("revenue_mean")])
  assert_eq(
    all_valid.get_column("revenue_mean").storage_kind(),
    @column.StorageKind::Numeric,
  )
}

///|
test "agg([]) degenerates to a distinct over the keys" {
  let df = agg_expr_df()
  let out = df.group_by([@expr.col("region")]).agg([])
  // No aggregation expressions ⇒ just the distinct key tuples, in
  // first-appearance order.
  assert_eq(out.columns(), ["region"])
  assert_eq(out.shape(), (2, 1))
  assert_eq(out.get_column("region").to_scalars(), [
    @types.Scalar::String("west"),
    @types.Scalar::String("east"),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "an empty key list reduces the whole frame as one grand-total group" {
  let df = agg_expr_df()
  let total = @expr.col("revenue").sum().with_alias("total")
  let out = df.group_by([]).agg([total])
  assert_eq(out.shape(), (1, 1))
  assert_eq(out.get_column("total").get(0), @types.Scalar::Int(150))
  // The grand-total group is the whole-frame scope: identical to the
  // one-row summary select produces, backend included.
  assert_eq(out, df.select([total]))
}

///|
test "a zero-row frame aggregates to zero groups with correctly typed columns" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", []),
    Series::from_ints("v", []),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("v").sum().with_alias("s"),
      @expr.col("v").mean().with_alias("m"),
    ])
  // Zero groups: the empty-scope fallback probe types each output column.
  assert_eq(out.shape(), (0, 3))
  assert_eq(out.get_column("k").dtype(), @types.DataType::String)
  assert_eq(out.get_column("s").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("m").dtype(), @types.DataType::Float)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a non-reducing expression is rejected with InvalidOperation" {
  // A bare column reference is the group's whole height, not a scalar.
  assert_eq(
    Ok(
      agg_expr_df().group_by([@expr.col("region")]).agg([@expr.col("revenue")]),
    ) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::InvalidOperation(
        "aggregate expression must reduce each group to a single value: col(revenue)",
      ),
    ),
  )
  // Mixing a reduction with a frame-tall operand does not reduce either.
  assert_eq(
    Ok(
      agg_expr_df()
      .group_by([@expr.col("region")])
      .agg([@expr.col("revenue").sum() + @expr.col("cost")]),
    ) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::InvalidOperation(
        "aggregate expression must reduce each group to a single value: (col(revenue).sum() + col(cost))",
      ),
    ),
  )
  // The shape gate precedes evaluation: an unknown column inside a
  // non-reducing tree reports the shape, not ColumnNotFound.
  assert_eq(
    Ok(agg_expr_df().group_by([@expr.col("region")]).agg([@expr.col("zzz")])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::InvalidOperation(
        "aggregate expression must reduce each group to a single value: col(zzz)",
      ),
    ),
  )
}

///|
test "deep non-reduction aggregation expressions are rejected without overflow" {
  // The structural `reduces_per_group` gate formerly recursed on the call
  // stack: a deeply nested expression whose leaf is a bare column overflowed
  // and aborted before `agg` could reject it. The explicit-stack walk reaches
  // the column at any depth and raises a clean error instead of aborting.
  let df = DataFrame::DataFrame([
    Series::from_ints("k", [1, 1, 2]),
    Series::from_ints("a", [10, 20, 30]),
  ])
  let depth = 100000
  let mut e = @expr.col("a")
  for _ in 0..<depth {
    e = e + @expr.lit_int(1)
  }
  // `e` ends in a bare `col("a")`, so it is not reduction-shaped; the gate walks
  // the whole tree and `agg` raises rather than aborting.
  let result = Ok(df.group_by([@expr.col("k")]).agg([e.with_alias("r")])) catch {
    err => Err(err)
  }
  assert_true(result is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "rejection is structural: singleton groups reject a bare column too" {
  // Every group holds exactly one row, so a bare col("v") would happen to
  // evaluate to length 1 per group — a dynamic length test would pass on
  // this data and fail on tomorrow's. The structural gate rejects it
  // regardless of group sizes.
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "b"]),
    Series::from_ints("v", [1, 2]),
  ])
  assert_eq(
    Ok(df.group_by([@expr.col("k")]).agg([@expr.col("v")])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::InvalidOperation(
        "aggregate expression must reduce each group to a single value: col(v)",
      ),
    ),
  )
}

///|
test "evaluation errors surface before any group work" {
  assert_eq(
    Ok(
      agg_expr_df()
      .group_by([@expr.col("region")])
      .agg([@expr.col("zzz").sum()]),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("zzz")),
  )
  assert_eq(
    Ok(
      agg_expr_df()
      .group_by([@expr.col("region")])
      .agg([@expr.col("region").sum()]),
    ) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message("sum undefined for String"),
      ),
    ),
  )
}

///|
test "output name collisions raise DuplicateColumn via DataFrame::DataFrame" {
  // Two reductions over the same column share its leftmost-name output.
  assert_eq(
    Ok(
      agg_expr_df()
      .group_by([@expr.col("region")])
      .agg([@expr.col("revenue").sum(), @expr.col("revenue").mean()]),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("revenue")),
  )
  // An alias that shadows a key column collides the same way.
  assert_eq(
    Ok(
      agg_expr_df()
      .group_by([@expr.col("region")])
      .agg([@expr.col("revenue").sum().with_alias("region")]),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("region")),
  )
  // Collisions surface at DataFrame::DataFrame, after every expression has
  // evaluated — so a later evaluation error wins over an earlier name
  // collision (unlike select, whose seen-check fires per expression).
  assert_eq(
    Ok(
      agg_expr_df()
      .group_by([@expr.col("region")])
      .agg([
        @expr.col("revenue").sum(),
        @expr.col("revenue").mean(),
        @expr.col("zzz").sum(),
      ]),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("zzz")),
  )
}

///|
/// A `map(...)`-wrapped reduction is typed by the closure's result dtype, not
/// by its input column's. Regression: the general agg path used to type the
/// output column from an empty-scope probe, which never runs the closure and
/// so mirrored the `Int` input dtype — nulling every `Float` group cell.
test "grouped agg of a map-wrapped reduction types by the closure result" {
  let half = @expr.col("revenue").map_elements(label="half", s => {
    @types.Scalar::Float(s.as_int().to_double() / 2.0)
  })
  let out = agg_expr_df()
    .group_by([@expr.col("region")])
    .agg([half.sum().with_alias("half_sum"), half.min().with_alias("half_min")])
  assert_eq(out.check_invariants(), Ok(()))
  // west = revenue 10/30/50 -> halves 5/15/25; east = 20/40 -> 10/20.
  assert_eq(out.get_column("half_sum").dtype(), @types.DataType::Float)
  assert_eq(out.get_column("half_sum").to_scalars(), [
    @types.Scalar::Float(45.0),
    @types.Scalar::Float(30.0),
  ])
  assert_eq(out.get_column("half_min").to_scalars(), [
    @types.Scalar::Float(5.0),
    @types.Scalar::Float(10.0),
  ])
  // An all-valid numeric aggregated column rides the `Numeric` backend, like
  // the engine's other computed columns.
  assert_eq(
    out.get_column("half_sum").storage_kind(),
    @column.StorageKind::Numeric,
  )
}

///|
/// The same holds for a non-numeric closure result: a `map(...)` returning
/// `String`, reduced per group, keeps the `String` dtype rather than being
/// nulled against the `Int` input probe.
test "grouped agg of a map-wrapped reduction keeps a non-numeric result dtype" {
  let tag = @expr.col("revenue").map_elements(label="tag", s => {
    @types.Scalar::String("r\{s.as_int()}")
  })
  let out = agg_expr_df()
    .group_by([@expr.col("region")])
    .agg([tag.first().with_alias("first_tag")])
  assert_eq(out.get_column("first_tag").dtype(), @types.DataType::String)
  // First row per group: west = revenue 10, east = revenue 20.
  assert_eq(out.get_column("first_tag").to_scalars(), [
    @types.Scalar::String("r10"),
    @types.Scalar::String("r20"),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
/// Regression: every cell maps to null, so each group's map result is all-null.
/// The general agg path used to raise `Unsupported` mid-iteration on such a
/// group; now the map falls back to the input (`revenue`, `Int`) backend, so
/// the per-group sum reduces to the additive identity `Int(0)` and the
/// aggregation completes (matching Polars' tolerance of a null-returning map).
test "grouped agg of an all-null map reduction is the additive identity, not an error" {
  let nullify = @expr.col("revenue").map_elements(label="nullify", _s => {
    @types.Scalar::Null
  })
  let out = agg_expr_df()
    .group_by([@expr.col("region")])
    .agg([nullify.sum().with_alias("s")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("s").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("s").to_scalars(), [
    @types.Scalar::Int(0),
    @types.Scalar::Int(0),
  ])
}

///|
/// Under the empty scope a `Map`'s closure never runs, so an *eager* probe
/// would type it by its `String` input and `sum` would raise `TypeMismatch`
/// — even though every real group reduces to an `Int`. The probe is
/// deferred, so the grouped path agrees with the select path.
test "grouped agg accepts a dtype-changing map closure under a numeric reduction" {
  let df = DataFrame::DataFrame([
    Series::from_strings("g", ["x", "x", "y"]),
    Series::from_strings("s", ["a", "bb", "ccc"]),
  ])
  let strlen = @expr.col("s").map_elements(label="len", s => {
    match s {
      @types.Scalar::String(v) => @types.Scalar::Int(v.length().to_int64())
      _ => @types.Scalar::Null
    }
  })
  let out = df
    .group_by([@expr.col("g")])
    .agg([strlen.sum().with_alias("total")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.get_column("total").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("total").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(3),
  ])
  // The whole-frame select path reduces the same expression to one cell —
  // the two paths must agree on accepting it.
  let whole = df.select([strlen.sum().with_alias("total")])
  assert_eq(whole.get_column("total").to_scalars(), [@types.Scalar::Int(6)])
}

///|
/// With zero groups the reduced cells carry no dtype, so the deferred
/// empty-scope probe is consumed: it types a derived reduction's 0-row
/// output — and still gates a dtype-changing map it cannot type.
test "grouped agg over zero groups consumes the deferred probe" {
  let empty = DataFrame::DataFrame([
    Series::from_strings("g", []),
    Series::from_ints("q", []),
  ])
  let grouped = empty.group_by([@expr.col("g")])
  let out = grouped.agg([
    (@expr.col("q").sum() + @expr.lit_int(1)).with_alias("t"),
  ])
  assert_eq(out.nrows(), 0)
  assert_eq(out.get_column("t").dtype(), @types.DataType::Int)
  // No group ever runs the closure, so the probe is the only witness — it
  // types the Map by its String input and the reduction is refused,
  // exactly as before the deferral.
  let strlen = @expr.col("g").map_elements(label="len", s => {
    match s {
      @types.Scalar::String(v) => @types.Scalar::Int(v.length().to_int64())
      _ => @types.Scalar::Null
    }
  })
  let r = Ok(grouped.agg([strlen.sum().with_alias("n")])) catch { e => Err(e) }
  assert_true(
    r
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
}
