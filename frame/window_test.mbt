///|
/// Blackbox behavior tests for `DataFrame::filter`: boolean row selection,
/// the null→drop rule, broadcast (literal / aggregation) predicates,
/// schema and backend preservation, and the evaluation-time error paths.
/// The predicate *evaluation* semantics (comparison dtype matrix, Kleene
/// tables, NaN) are pinned by the evaluator's own suite; the `map_many`
/// escape hatch that reifies a row-wise host predicate has dedicated
/// coverage of its own.

///|
fn where_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("qty", [5, 120, 80, 200]),
    Series::from_strings("region", ["west", "east", "west", "west"]),
  ])
}

///|
test "keeps exactly the rows where the predicate is true" {
  let out = where_df().filter(@expr.col("qty").gt(@expr.lit_int(50)))
  assert_eq(out.get_column("qty").to_scalars(), [
    @types.Scalar::Int(120),
    @types.Scalar::Int(80),
    @types.Scalar::Int(200),
  ])
  assert_eq(out.columns(), ["qty", "region"])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a compound `&` predicate keeps the rows where every clause holds" {
  // Comparison methods bind tighter than `&`, so the two clauses compose
  // into one Bool mask with no parentheses.
  let df = where_df()
  let out = df.filter(
    @expr.col("qty").gt(@expr.lit_int(50)) &
    @expr.col("region").eq(@expr.lit_str("west")),
  )
  assert_eq(out.get_column("qty").to_scalars(), [
    @types.Scalar::Int(80),
    @types.Scalar::Int(200),
  ])
  assert_eq(out.get_column("region").to_scalars(), [
    @types.Scalar::String("west"),
    @types.Scalar::String("west"),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "null predicate cells drop their rows, like false" {
  // Directly null mask cells: a nullable Bool column as the predicate.
  let df = DataFrame::DataFrame([
    Series::from_ints("id", [1, 2, 3]),
    Series::from_bool_options("flag", [Some(true), None, Some(false)]),
  ])
  let out = df.filter(@expr.col("flag"))
  assert_eq(out.get_column("id").to_scalars(), [@types.Scalar::Int(1)])
  // Null comparison cells (null-propagating `ge` over a nullable column)
  // drop their row the same way.
  let df2 = DataFrame::DataFrame([
    Series::from_int_options("x", [Some(10), None, Some(1)]),
  ])
  let out2 = df2.filter(@expr.col("x").ge(@expr.lit_int(5)))
  assert_eq(out2.get_column("x").to_scalars(), [@types.Scalar::Int(10)])
}

///|
test "Kleene predicates: a dominant true keeps, an unknown drops" {
  let df = DataFrame::DataFrame([
    Series::from_ints("id", [1, 2]),
    Series::from_bool_options("a", [Some(true), None]),
    Series::from_bool_options("b", [None, Some(true)]),
  ])
  // true|null and null|true are both true → every row kept.
  assert_eq(df.filter(@expr.col("a") | @expr.col("b")).nrows(), 2)
  // true&null and null&true are both null → every row dropped.
  assert_eq(df.filter(@expr.col("a") & @expr.col("b")).nrows(), 0)
}

///|
test "rejects-everything predicate keeps the schema at zero rows" {
  let df = where_df()
  let out = df.filter(@expr.col("qty").gt(@expr.lit_int(1000)))
  assert_eq(out.shape(), (0, 2))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "length-1 predicates broadcast: literals keep every row or none" {
  let df = where_df()
  assert_eq(df.filter(@expr.lit_bool(true)), df)
  assert_eq(df.filter(@expr.lit_bool(false)).nrows(), 0)
}

///|
test "length-1 predicates broadcast: aggregation comparisons gate the frame" {
  // qty sums to 405: the whole frame passes one threshold, none the other.
  let df = where_df()
  assert_eq(df.filter(@expr.col("qty").sum().gt(@expr.lit_int(100))), df)
  assert_eq(
    df.filter(@expr.col("qty").sum().gt(@expr.lit_int(1000))).nrows(),
    0,
  )
}

///|
test "zero-row frame: column and broadcast predicates both stay empty" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [])])
  assert_eq(df.filter(@expr.col("a").gt(@expr.lit_int(0))).nrows(), 0)
  let out = df.filter(@expr.lit_bool(true))
  assert_eq(out.shape(), (0, 1))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "column backends survive the row filter" {
  let df = DataFrame::DataFrame([
    Series::from_ints("n", [1, 2, 3]),
    Series::from_int_options("m", [Some(1), None, Some(3)]),
  ])
  let out = df.filter(@expr.col("n").gt(@expr.lit_int(1)))
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Numeric)
  assert_eq(out.get_column("m").storage_kind(), @column.StorageKind::Builtin)
}

///|
test "non-Bool predicates raise TypeMismatch" {
  // A frame-tall non-Bool result raises…
  assert_eq(
    Ok(where_df().filter(@expr.col("qty"))) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "filter predicate must be Bool, got Int",
        ),
      ),
    ),
  )
  // …and so does a length-1 non-Bool literal (the broadcast path).
  assert_eq(
    Ok(where_df().filter(@expr.lit_str("west"))) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "filter predicate must be Bool, got String",
        ),
      ),
    ),
  )
}

///|
test "evaluation errors surface: unknown column in the predicate" {
  assert_eq(
    Ok(where_df().filter(@expr.col("zzz").gt(@expr.lit_int(0)))) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("zzz")),
  )
}

///|
test "pipeline: derive with with_columns, then filter on the derived column" {
  // The expression target feel: declare a derived column, then gate rows
  // on it and a second condition with the `&` operator.
  let df = DataFrame::DataFrame([
    Series::from_ints("revenue", [100, 200, 300]),
    Series::from_ints("cost", [150, 120, 100]),
    Series::from_strings("region", ["west", "east", "west"]),
  ])
  let out = df
    .with_columns([
      (@expr.col("revenue") - @expr.col("cost")).with_alias("profit"),
    ])
    .filter(
      @expr.col("profit").gt(@expr.lit_int(0)) &
      @expr.col("region").eq(@expr.lit_str("west")),
    )
  assert_eq(out.get_column("profit").to_scalars(), [@types.Scalar::Int(200)])
  assert_eq(out.get_column("region").to_scalars(), [
    @types.Scalar::String("west"),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

// Blackbox tests for `DataFrame::reverse` / `with_row_index`.

///|
fn order_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("n", [1, 2, 3]),
    Series::from_strings("s", ["a", "b", "c"]),
  ])
}

///|
test "reverse flips the row order and leaves the schema alone" {
  let df = order_df()
  let out = df.reverse()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.item(0, "n"), @types.Scalar::Int(3))
  assert_eq(out.item(2, "n"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "s"), @types.Scalar::String("c"))
  // Reversing twice is the identity.
  assert_eq(out.reverse(), df)
  // Degenerate shapes are returned unchanged rather than re-gathered.
  let single = DataFrame::DataFrame([Series::from_ints("n", [7])])
  assert_eq(single.reverse(), single)
  let empty = DataFrame::DataFrame([Series::from_ints("n", [])])
  assert_eq(empty.reverse(), empty)
}

///|
test "with_row_index prepends a dense counter" {
  let df = order_df()
  let out = df.with_row_index()
  assert_eq(out.check_invariants(), Ok(()))
  // The counter lands first, ahead of the frame's own columns.
  assert_eq(out.columns(), ["index", "n", "s"])
  assert_eq(out.get_column("index").dtype(), @types.DataType::Int)
  assert_eq(out.item(0, "index"), @types.Scalar::Int(0))
  assert_eq(out.item(2, "index"), @types.Scalar::Int(2))
  // Custom name and offset.
  let renamed = df.with_row_index(name="row", offset=10)
  assert_eq(renamed.columns(), ["row", "n", "s"])
  assert_eq(renamed.item(0, "row"), @types.Scalar::Int(10))
  assert_eq(renamed.item(2, "row"), @types.Scalar::Int(12))
  // A 0-row frame gets an empty counter, not a missing column.
  let empty = DataFrame::DataFrame([Series::from_ints("n", [])])
  assert_eq(empty.with_row_index().columns(), ["index", "n"])
  assert_eq(empty.with_row_index().nrows(), 0)
}

///|
test "with_row_index rejects a name the frame already carries" {
  let df = order_df()
  assert_true(
    (Ok(df.with_row_index(name="n")) catch { e => Err(e) })
    is Err(@types.DataError::DuplicateColumn("n")),
  )
}

///|
test "with_row_index rejects an offset the counter would overflow" {
  // The 3-row counter needs `offset ..= offset + 2`. One short of the top,
  // MoonBit's wrapping `+` would hand back MAX-1, MAX, MIN — a column that
  // runs backwards at the last row instead of counting.
  let df = order_df()
  let max = 9223372036854775807L
  assert_true(
    (Ok(df.with_row_index(offset=max - 1)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // The last offset that still fits is accepted, and reaches exactly the top.
  let fits = df.with_row_index(offset=max - 2)
  assert_eq(fits.item(2, "index"), @types.Scalar::Int(max))
  // A 0-row frame has no counter to overflow, so any offset is fine.
  let empty = DataFrame::DataFrame([Series::from_ints("n", [])])
  assert_eq(empty.with_row_index(offset=max).nrows(), 0)
  // The bound is one-sided: counting only ever goes up, so the far negative
  // end is reachable.
  let low = df.with_row_index(offset=-9223372036854775808L)
  assert_eq(low.item(0, "index"), @types.Scalar::Int(-9223372036854775808L))
}

// Blackbox tests for the row-window verbs — `head` / `tail` / `slice` /
// `gather` — one family to a file, matching the verbs' own home. The verbs
// keep a frame's schema verbatim and move or trim rows; that name lookup
// keeps working after a transform is pinned in the type-core suite, whose
// "name lookup survives transforms" section is about the schema index
// rather than about this family.

// ── head / tail ──────────────────────────────────────────────────────

///|
test "head returns the first n rows with the same schema" {
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  let two = df.head(2)
  assert_eq(two.shape(), (2, 2))
  assert_eq(two.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(two.item(1, "b"), @types.Scalar::String("x"))
  // Schema is preserved verbatim.
  assert_eq(two.schema(), df.schema())
}

///|
test "head clamps n > nrows to nrows" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2, 3])])
  let all = df.head(99)
  assert_eq(all.shape(), (3, 1))
}

///|
test "head with a negative n keeps every row but the last |n|, as Polars" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2, 3])])
  // head(-1) drops the final row.
  let but_last = df.head(-1)
  assert_eq(but_last.shape(), (2, 1))
  assert_eq(but_last.item(1, "a"), @types.Scalar::Int(2))
  // |n| reaching past the frame leaves nothing.
  assert_eq(df.head(-5).shape(), (0, 1))
}

///|
test "tail returns the last n rows with the same schema" {
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  let two = df.tail(2)
  assert_eq(two.shape(), (2, 2))
  assert_eq(two.item(0, "a"), @types.Scalar::Int(3))
  assert_eq(two.item(1, "b"), @types.Scalar::String("z"))
}

///|
test "tail clamps n > nrows; a negative n keeps every row but the first |n|" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2, 3])])
  let all = df.tail(99)
  assert_eq(all.shape(), (3, 1))
  // tail(-1) drops the leading row.
  let but_first = df.tail(-1)
  assert_eq(but_first.shape(), (2, 1))
  assert_eq(but_first.item(0, "a"), @types.Scalar::Int(2))
  assert_eq(df.tail(-5).shape(), (0, 1))
}

// ── slice ────────────────────────────────────────────────────────────

///|
test "slice mid-range produces a sub-frame preserving names + nulls" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(10), None, Some(30), Some(40)]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  let part = df.slice(1, length=2)
  assert_eq(part.shape(), (2, 2))
  assert_eq(part.item(0, "a"), @types.Scalar::Null)
  assert_eq(part.item(1, "a"), @types.Scalar::Int(30))
  assert_eq(part.item(0, "b"), @types.Scalar::String("x"))
}

///|
test "slice [start, start) returns an empty frame" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2, 3])])
  let zero = df.slice(2, length=0)
  assert_eq(zero.shape(), (0, 1))
}

///|
test "slice saturates like Polars: negative offset from the end, omitted length to the end" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2, 3, 4, 5])])
  // Omitted length runs to the end.
  assert_eq(df.slice(2).shape(), (3, 1))
  assert_eq(df.slice(2).item(0, "x"), @types.Scalar::Int(3))
  assert_eq(df.slice(2).item(2, "x"), @types.Scalar::Int(5))
  // A negative offset counts from the end; -1 names the last row.
  assert_eq(df.slice(-1).shape(), (1, 1))
  assert_eq(df.slice(-1).item(0, "x"), @types.Scalar::Int(5))
  assert_eq(df.slice(-2).item(0, "x"), @types.Scalar::Int(4))
  // An offset reaching past either end saturates there.
  assert_eq(df.slice(-99).shape(), (5, 1))
  assert_eq(df.slice(99).shape(), (0, 1))
}

///|
test "slice saturates the length: past the end keeps what remains, negative is empty" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2, 3, 4, 5])])
  assert_eq(df.slice(1, length=99).shape(), (4, 1))
  assert_eq(df.slice(1, length=99).item(0, "x"), @types.Scalar::Int(2))
  assert_eq(df.slice(-3, length=2).item(0, "x"), @types.Scalar::Int(3))
  assert_eq(df.slice(-3, length=2).item(1, "x"), @types.Scalar::Int(4))
  assert_eq(df.slice(2, length=-5).shape(), (0, 1))
  // `tail(n)` is `slice(-n)` against the known height — same window either way.
  assert_eq(df.slice(-2).item(0, "x"), df.tail(2).item(0, "x"))
  assert_eq(df.slice(-2).shape(), df.tail(2).shape())
}

// ── gather ─────────────────────────────────────────────────────────────

///|
test "gather collects rows in arbitrary order across every column" {
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [10, 20, 30]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
  let out = df.gather([2, 0, 0])
  assert_eq(out.shape(), (3, 2))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(30))
  assert_eq(out.item(0, "b"), @types.Scalar::String("z"))
  assert_eq(out.item(2, "a"), @types.Scalar::Int(10))
}

///|
test "gather with empty indices produces an empty frame of the same schema" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2])])
  let out = df.gather([])
  assert_true(out.is_empty())
  assert_eq(out.schema(), df.schema())
}

///|
test "gather rejects out-of-bounds indices with the first offender" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2])])
  assert_eq(
    Ok(df.gather([0, 5])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_eq(
    Ok(df.gather([-1])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
}

// ── bracket access ──────────────────────────────────────────────────

///|
test "df[name] reads a column; df[a:b] is the bracket-slice sugar" {
  let df = DataFrame::DataFrame([
    Series::from_ints("x", [1, 2, 3, 4, 5]),
    Series::from_strings("tag", ["a", "b", "c", "d", "e"]),
  ])
  // The column bracket is get_column.
  assert_eq(df["x"].dtype(), @types.DataType::Int)
  assert_true(
    (Ok(df["missing"]) catch { e => Err(e) })
    is Err(@types.DataError::ColumnNotFound("missing")),
  )
  // The slice bracket is slice_between: half-open, omitted to the end,
  // negative from the end, crossed bounds empty.
  assert_eq(df[1:3].shape(), (2, 2))
  assert_eq(df[1:3].item(0, "x"), @types.Scalar::Int(2))
  assert_eq(df[2:].shape(), (3, 2))
  assert_eq(df[:2].shape(), (2, 2))
  assert_eq(df[:].shape(), (5, 2))
  assert_eq(df[:-1].shape(), (4, 2))
  assert_eq(df[-2:].item(0, "tag"), @types.Scalar::String("d"))
  assert_eq(df[3:1].shape(), (0, 2))
  // Same kernel, so the two spellings agree on a shared window.
  assert_eq(df[1:3], df.slice(1, length=2))
}
