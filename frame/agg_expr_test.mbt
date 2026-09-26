///|
/// Blackbox behavior tests for `GroupedDataFrame::agg`: single-column and
/// compound / derived reductions, the reduction-shape gate and its
/// structural (data-independent) rejection, naming and collision rules,
/// all-null / NaN group semantics, zero-group frames, and the backend
/// convention for computed columns. The group-partitioning behaviour and
/// the historical `"<col>_<kind>"`-named reductions have their own suite,
/// as do the evaluator's own dtype / null / NaN rules.

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

///|
test "a deeply aliased aggregation takes the bare-column fast path without overflow" {
  // `bare_col_agg` peels top-level aliases to recognise `col(n).<agg>()` — the
  // fast path a plain aggregation takes — and `with_alias` stacks without bound.
  // Peeling on the call stack overflowed and aborted at this depth; the cursor
  // reaches the aggregation, so the result is the same as the unaliased form
  // under the alias's own name.
  let df = DataFrame::DataFrame([
    Series::from_ints("k", [1, 1, 2]),
    Series::from_ints("a", [10, 20, 30]),
  ])
  let mut e = @expr.col("a").sum()
  for _ in 0..<100000 {
    e = e.with_alias("total")
  }
  let out = df.group_by([@expr.col("k")]).agg([e])
  assert_eq(out.columns(), ["k", "total"])
  assert_eq(
    out.get_column("total"),
    df
    .group_by([@expr.col("k")])
    .agg([@expr.col("a").sum().with_alias("total")])
    .get_column("total"),
  )
  assert_eq(out.check_invariants(), Ok(()))
}

///|
/// Blackbox tests for the expression aggregation family added on the shared
/// reduction kernel — `std` / `variance` / `median` / `n_unique` / `first` /
/// `last` — driven through both reduction surfaces: a whole-frame `select`
/// (the per-scope evaluator) and a grouped `agg` (the single-pass fast path).
/// Covers each op's value, output dtype, and null / NaN rule: `std` / `var`
/// propagate NaN and reduce a `< 2`-cell scope to null, `median` skips NaN,
/// `n_unique` buckets NaN as one and excludes nulls, and `first` / `last` are
/// positional (a null leading / trailing cell, or an empty scope, is null).
/// Non-numeric `std` / `var` / `median` raise `TypeMismatch`. Construction and
/// rendering have their own coverage; this pins evaluation.

///|
/// The single cell of the whole-frame reduction `e` over `df`, via `select`:
/// `select([agg])` collapses to one row, so cell `(0, "r")` is the reduction.
fn whole(
  df : DataFrame,
  e : @expr.Expr,
) -> @types.Scalar raise @types.DataError {
  df.select([e.with_alias("r")]).item(0, "r")
}

// ── std / variance: value, dtype, NaN propagation, < 2 cells ───────────

///|
test "std and variance reduce a whole frame to the sample statistics" {
  // [2, 4, 6]: mean 4, squared deviations 4 + 0 + 4 = 8, sample variance
  // (ddof = 1) 8 / 2 = 4.0, standard deviation its root, 2.0. Both are Float
  // even though the source is Int.
  let df = DataFrame::DataFrame([Series::from_ints("x", [2, 4, 6])])
  assert_eq(whole(df, @expr.col("x").std()), @types.Scalar::Float(2.0))
  assert_eq(whole(df, @expr.col("x").variance()), @types.Scalar::Float(4.0))
}

///|
test "std over a Float column keeps Float and propagates NaN" {
  let df = DataFrame::DataFrame([Series::from_floats("x", [1.0, 2.0, 3.0])])
  // [1, 2, 3]: variance 1.0, std 1.0.
  assert_eq(whole(df, @expr.col("x").std()), @types.Scalar::Float(1.0))
  // A non-null NaN is a value: it flows through the mean, so std / var
  // propagate it (matching sum / mean), unlike min / max / median.
  let nan = @double.not_a_number
  let dfn = DataFrame::DataFrame([Series::from_floats("x", [1.0, 2.0, nan])])
  assert_true(whole(dfn, @expr.col("x").std()).as_float().is_nan())
  assert_true(whole(dfn, @expr.col("x").variance()).as_float().is_nan())
}

///|
test "variance and std of equal large-magnitude values are 0, not +inf" {
  // Two equal cells near Double-max: the true variance is 0. A two-pass mean
  // would sum them to +inf and report +inf; Welford never forms the raw sum, so
  // the finite variance survives.
  let df = DataFrame::DataFrame([Series::from_floats("x", [1.0e308, 1.0e308])])
  assert_eq(whole(df, @expr.col("x").variance()), @types.Scalar::Float(0.0))
  assert_eq(whole(df, @expr.col("x").std()), @types.Scalar::Float(0.0))
}

///|
test "variance and std of opposite-sign extremes saturate to +inf, never negative" {
  // Finite cells more than Double-max apart: Welford's running `delta`
  // overflows and used to poison `m2` to -inf — a mathematically impossible
  // NEGATIVE variance, and sqrt(-inf) = NaN for std. The true variance
  // (~2e616) exceeds Double's range, so the statistic saturates to +inf,
  // as numpy (ddof=1) and Polars report.
  let two = DataFrame::DataFrame([Series::from_floats("x", [-1.0e308, 1.0e308])])
  assert_eq(
    whole(two, @expr.col("x").variance()),
    @types.Scalar::Float(@double.infinity),
  )
  assert_eq(
    whole(two, @expr.col("x").std()),
    @types.Scalar::Float(@double.infinity),
  )
  // A longer alternating window drives the artefact to NaN instead of -inf;
  // the finite-input rescue covers it the same way.
  let three = DataFrame::DataFrame([
    Series::from_floats("x", [1.0e308, -1.0e308, 1.0e308]),
  ])
  assert_eq(
    whole(three, @expr.col("x").variance()),
    @types.Scalar::Float(@double.infinity),
  )
  // A genuine ±inf INPUT is not rescued: it propagates through the mean
  // like sum / mean, so the statistic is NaN (inf - inf), not +inf.
  let inf_in = DataFrame::DataFrame([
    Series::from_floats("x", [@double.infinity, 1.0]),
  ])
  assert_true(whole(inf_in, @expr.col("x").variance()).as_float().is_nan())
  assert_true(whole(inf_in, @expr.col("x").std()).as_float().is_nan())
}

///|
test "std and variance are null for fewer than two non-null cells" {
  // Sample statistics need ddof = 1 < cnt: one value, or none, has no
  // sample variance, so the cell is null rather than 0.0.
  let one = DataFrame::DataFrame([Series::from_ints("x", [5])])
  assert_eq(whole(one, @expr.col("x").std()), @types.Scalar::Null)
  assert_eq(whole(one, @expr.col("x").variance()), @types.Scalar::Null)
  let empty = DataFrame::DataFrame([Series::from_ints("x", [])])
  assert_eq(whole(empty, @expr.col("x").std()), @types.Scalar::Null)
  // Nulls are skipped, so a lone non-null cell beside nulls is still < 2.
  let sparse = DataFrame::DataFrame([
    Series::from_int_options("x", [Some(5), None, None]),
  ])
  assert_eq(whole(sparse, @expr.col("x").variance()), @types.Scalar::Null)
}

// ── median: value, even/odd, dtype, NaN skipped ───────────────────────

///|
test "median is the middle of the sorted non-null cells, always Float" {
  // Odd count: the middle. Int widens, so the result is Float.
  let odd = DataFrame::DataFrame([Series::from_ints("x", [3, 1, 2])])
  assert_eq(whole(odd, @expr.col("x").median()), @types.Scalar::Float(2.0))
  // Even count: the mean of the two middles.
  let even = DataFrame::DataFrame([Series::from_ints("x", [1, 2, 3, 4])])
  assert_eq(whole(even, @expr.col("x").median()), @types.Scalar::Float(2.5))
}

///|
test "median propagates NaN, skips nulls, all-missing is null" {
  let nan = @double.not_a_number
  // NaN propagates — the sum / mean rule, not the min / max skip: a window
  // that contains one has that value's order statistic.
  let df = DataFrame::DataFrame([Series::from_floats("x", [1.0, 2.0, nan])])
  let got = whole(df, @expr.col("x").median())
  assert_true(
    match got {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  // Nulls drop out; [10, null, 20, null, 30] medians to 20.0.
  let sparse = DataFrame::DataFrame([
    Series::from_float_options("x", [
      Some(10.0),
      None,
      Some(20.0),
      None,
      Some(30.0),
    ]),
  ])
  assert_eq(whole(sparse, @expr.col("x").median()), @types.Scalar::Float(20.0))
  // Every cell missing → null.
  let allnull = DataFrame::DataFrame([
    Series::from_float_options("x", [None, None]),
  ])
  assert_eq(whole(allnull, @expr.col("x").median()), @types.Scalar::Null)
}

///|
test "median of two near-Double-max middles stays finite (no overflow to Inf)" {
  // The sum of the two middle cells overflows Double before the halving, yet the
  // median lies between them and is finite. Regression guard: the naive
  // `(lo + hi) / 2` returned +Inf here.
  let big = DataFrame::DataFrame([Series::from_floats("x", [1.6e308, 1.7e308])])
  assert_eq(
    whole(big, @expr.col("x").median()),
    @types.Scalar::Float(1.6e308 / 2.0 + 1.7e308 / 2.0),
  )
}

// ── n_unique: distinct non-null across every dtype ─────────────────────

///|
test "n_unique counts distinct non-null values, an Int over any dtype" {
  let ints = DataFrame::DataFrame([Series::from_ints("x", [1, 1, 2, 3, 3, 3])])
  assert_eq(whole(ints, @expr.col("x").n_unique()), @types.Scalar::Int(3))
  let bools = DataFrame::DataFrame([
    Series::from_bools("x", [true, true, false]),
  ])
  assert_eq(whole(bools, @expr.col("x").n_unique()), @types.Scalar::Int(2))
  let strs = DataFrame::DataFrame([Series::from_strings("x", ["a", "a", "b"])])
  assert_eq(whole(strs, @expr.col("x").n_unique()), @types.Scalar::Int(2))
  // Empty scope → zero distinct values (never null).
  let empty = DataFrame::DataFrame([Series::from_ints("x", [])])
  assert_eq(whole(empty, @expr.col("x").n_unique()), @types.Scalar::Int(0))
}

///|
test "n_unique buckets every NaN as one value and excludes nulls" {
  let nan = @double.not_a_number
  // Two distinct values — the finite 1.0 and the single NaN bucket — even
  // though two NaN cells appear (NaN is one value, the n_unique / group rule).
  let floats = DataFrame::DataFrame([
    Series::from_floats("x", [1.0, nan, 1.0, nan]),
  ])
  assert_eq(whole(floats, @expr.col("x").n_unique()), @types.Scalar::Int(2))
  // Nulls are not a value here: [1, null, 1, 2] has two distinct values.
  let sparse = DataFrame::DataFrame([
    Series::from_int_options("x", [Some(1), None, Some(1), Some(2)]),
  ])
  assert_eq(whole(sparse, @expr.col("x").n_unique()), @types.Scalar::Int(2))
}

///|
test "n_unique agrees with the whole-column Series statistic" {
  // The kernel reducer and `Series::n_unique` are separate implementations of
  // the same count; pin that they agree so neither drifts.
  let x = Series::from_int_options("x", [
    Some(1),
    None,
    Some(1),
    Some(2),
    Some(2),
  ])
  let df = DataFrame::DataFrame([x])
  assert_eq(
    whole(df, @expr.col("x").n_unique()),
    @types.Scalar::Int(x.n_unique().to_int64()),
  )
}

// ── first / last: positional, every dtype, null / empty ───────────────

///|
test "first and last take the positional cell, keeping the source dtype" {
  let ints = DataFrame::DataFrame([Series::from_ints("x", [10, 20, 30])])
  assert_eq(whole(ints, @expr.col("x").first()), @types.Scalar::Int(10))
  assert_eq(whole(ints, @expr.col("x").last()), @types.Scalar::Int(30))
  let floats = DataFrame::DataFrame([Series::from_floats("x", [1.5, 2.5, 3.5])])
  assert_eq(whole(floats, @expr.col("x").last()), @types.Scalar::Float(3.5))
  let bools = DataFrame::DataFrame([
    Series::from_bools("x", [true, false, true]),
  ])
  assert_eq(whole(bools, @expr.col("x").first()), @types.Scalar::Bool(true))
  let strs = DataFrame::DataFrame([Series::from_strings("x", ["a", "b", "c"])])
  assert_eq(whole(strs, @expr.col("x").first()), @types.Scalar::String("a"))
}

///|
test "first and last are null on a null leading or trailing cell, or empty" {
  // Positional: a null first / last cell is null, not the first / last
  // *present* value.
  let headnull = DataFrame::DataFrame([
    Series::from_int_options("x", [None, Some(2), Some(3)]),
  ])
  assert_eq(whole(headnull, @expr.col("x").first()), @types.Scalar::Null)
  let tailnull = DataFrame::DataFrame([
    Series::from_int_options("x", [Some(1), Some(2), None]),
  ])
  assert_eq(whole(tailnull, @expr.col("x").last()), @types.Scalar::Null)
  // An empty scope has no first / last cell → null.
  let empty = DataFrame::DataFrame([Series::from_ints("x", [])])
  assert_eq(whole(empty, @expr.col("x").first()), @types.Scalar::Null)
  assert_eq(whole(empty, @expr.col("x").last()), @types.Scalar::Null)
}

// ── Non-numeric std / variance / median raise ─────────────────────────

///|
test "std, variance, and median reject non-numeric columns" {
  let strs = DataFrame::DataFrame([Series::from_strings("x", ["a", "b"])])
  assert_true(
    (Ok(whole(strs, @expr.col("x").std())) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
  assert_true(
    (Ok(whole(strs, @expr.col("x").variance())) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
  let bools = DataFrame::DataFrame([Series::from_bools("x", [true, false])])
  assert_true(
    (Ok(whole(bools, @expr.col("x").median())) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
}

// ── Grouped agg: per-group reductions over the fast path ───────────────

///|
/// Five-row sales fixture grouped by `region`: `east` = rows 0, 2, 3
/// (quantity 10, 2, 6), `west` = rows 1, 4 (quantity 5, 4); `east` first.
fn grouped_sales() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("region", ["east", "west", "east", "east", "west"]),
    Series::from_ints("quantity", [10, 5, 2, 6, 4]),
  ])
}

///|
test "grouped agg reduces each group with the new family" {
  let out = grouped_sales()
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("quantity").std().with_alias("q_std"),
      @expr.col("quantity").variance().with_alias("q_var"),
      @expr.col("quantity").median().with_alias("q_med"),
      @expr.col("quantity").n_unique().with_alias("q_nu"),
      @expr.col("quantity").first().with_alias("q_first"),
      @expr.col("quantity").last().with_alias("q_last"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), [
    "region", "q_std", "q_var", "q_med", "q_nu", "q_first", "q_last",
  ])
  // east quantity = [10, 2, 6]: mean 6, var (16 + 16 + 0) / 2 = 16.0,
  // std 4.0, median (sorted 2, 6, 10) 6.0, 3 distinct, first 10, last 6.
  assert_eq(out.item(0, "q_std"), @types.Scalar::Float(4.0))
  assert_eq(out.item(0, "q_var"), @types.Scalar::Float(16.0))
  assert_eq(out.item(0, "q_med"), @types.Scalar::Float(6.0))
  assert_eq(out.item(0, "q_nu"), @types.Scalar::Int(3))
  assert_eq(out.item(0, "q_first"), @types.Scalar::Int(10))
  assert_eq(out.item(0, "q_last"), @types.Scalar::Int(6))
  // west quantity = [5, 4]: mean 4.5, var (0.25 + 0.25) / 1 = 0.5, std its
  // root, median (sorted 4, 5) 4.5, 2 distinct, first 5, last 4.
  assert_eq(out.item(1, "q_std"), @types.Scalar::Float(0.5.sqrt()))
  assert_eq(out.item(1, "q_var"), @types.Scalar::Float(0.5))
  assert_eq(out.item(1, "q_med"), @types.Scalar::Float(4.5))
  assert_eq(out.item(1, "q_nu"), @types.Scalar::Int(2))
  assert_eq(out.item(1, "q_first"), @types.Scalar::Int(5))
  assert_eq(out.item(1, "q_last"), @types.Scalar::Int(4))
}

///|
test "grouped agg reduces a derived operand through the general path" {
  // A non-bare operand bypasses the single-pass fast path and reduces through
  // the general per-group evaluator — the same kernel, reached the other way.
  let out = grouped_sales()
    .group_by([@expr.col("region")])
    .agg([(@expr.col("quantity") + @expr.lit_int(0)).median().with_alias("m")])
  assert_eq(out.check_invariants(), Ok(()))
  // east [10, 2, 6] → 6.0, west [5, 4] → 4.5, unchanged by the `+ 0`.
  assert_eq(out.item(0, "m"), @types.Scalar::Float(6.0))
  assert_eq(out.item(1, "m"), @types.Scalar::Float(4.5))
}
