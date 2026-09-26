// The `Date` dtype acceptance suite: the structural claim behind the dtype
// registry is that a logical dtype riding an existing physical buffer touches
// only `DataType` / `Scalar` / the registry / rendering — no kernel arm, no
// `ColumnData` change, no storage change. These tests drive a `Date` column
// through the surfaces a user meets (build, compare, sort, group, reduce,
// render, interchange) and pin the fences (no date arithmetic, no cross-dtype
// compare, no cast, no inference).

///|
/// A small frame with a `Date` column: 19723 = 2024-01-01, 19753 =
/// 2024-01-31, 19754 = 2024-02-01 (leap year), one null.
fn date_frame() -> DataFrame raise @types.DataError {
  DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Date),
      @types.Field::Field("v", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Date(19723L), @types.Scalar::Int(1)],
      [@types.Scalar::Date(19753L), @types.Scalar::Int(2)],
      [@types.Scalar::Null, @types.Scalar::Int(3)],
      [@types.Scalar::Date(19754L), @types.Scalar::Int(4)],
    ],
  )
}

///|
/// The column's date cells as ISO strings (nulls as `"null"`), the readable
/// form every assertion below compares through.
fn iso_cells(
  df : DataFrame,
  name : String,
) -> Array[String] raise @types.DataError {
  df
  .get_column(name)
  .to_scalars()
  .map(s => if s is @types.Scalar::Null { "null" } else { s.to_string() })
}

///|
test "a Date column keeps its identity through build and read" {
  let df = date_frame()
  assert_eq(df.get_column("d").dtype(), @types.DataType::Date)
  assert_true(df.item(0, "d") is @types.Scalar::Date(19723L))
  assert_true(df.item(2, "d") is @types.Scalar::Null)
  // Row values render ISO, not day counts.
  assert_eq(df.item(0, "d").to_string(), "2024-01-01")
  assert_eq(df.item(1, "d").to_string(), "2024-01-31")
  assert_eq(df.item(3, "d").to_string(), "2024-02-01")
  assert_eq(iso_cells(df, "d"), [
    "2024-01-01", "2024-01-31", "null", "2024-02-01",
  ])
}

///|
test "Date compares date-wise; a Date never compares against an Int" {
  let df = date_frame()
  assert_eq(
    iso_cells(
      df.filter(@expr.col("d").lt(@expr.lit(@types.Scalar::Date(19754L)))),
      "d",
    ),
    ["2024-01-01", "2024-01-31"],
  )
  // A null date fails the predicate (Kleene: the comparison is null), so the
  // null-key row drops, like any other row the filter rejects. The day-count `Int` literal must not reach the Date cells through the
  // shared I64 buffer: cross-dtype compare is a TypeMismatch.
  assert_true(
    (Ok(df.filter(@expr.col("d").lt(@expr.lit_int(19754L))).nrows()) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "Date sorts chronologically and reduces positionally" {
  let df = date_frame()
  let sorted = df.sort([(@expr.col("d"), false, true)])
  assert_eq(iso_cells(sorted, "d"), [
    "2024-01-01", "2024-01-31", "2024-02-01", "null",
  ])
  // min / max are order statistics — allowed; their cells stay Dates and
  // skip the null.
  assert_eq(df.get_column("d").min().to_string(), "2024-01-01")
  assert_eq(df.get_column("d").max().to_string(), "2024-02-01")
}

///|
test "Date groups by cell value; arithmetic reductions are TypeMismatch" {
  let df = date_frame().drop_nulls(subset=[@expr.col("d")])
  let grouped = df
    .group_by([@expr.col("d")])
    .agg([@expr.col("v").sum().with_alias("total")])
  assert_true(grouped.nrows() == 3)
  // sum / mean / std / var / median read days, not dates: fenced off.
  assert_true(
    (Ok(ignore(df.get_column("d").sum())) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  assert_true(
    (Ok(ignore(df.get_column("d").mean())) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "Date renders as ISO and interchanges as text" {
  let df = date_frame().drop_nulls(subset=[@expr.col("d")])
  let csv = @io.format_csv(df)
  assert_true(csv.contains("2024-01-01"))
  let json = @io.format_json(df)
  assert_true(json.contains("2024-02-01"))
  // The describe table shows the registered dtype name.
  assert_true(df.describe().to_markdown().contains("Date"))
}

///|
test "Date is never inferred, never cast, never filled across dtypes" {
  // Inference lands ISO-shaped text on String (the documented candidate set).
  let from_csv = @io.parse_csv_str("d\n2024-01-01\n2024-02-01")
  assert_eq(from_csv.get_column("d").dtype(), @types.DataType::String)
  // Cast in either direction is Unsupported, pending real date semantics.
  let df = date_frame().drop_nulls(subset=[@expr.col("d")])
  assert_true(
    (Ok(ignore(df.get_column("d").cast(@types.DataType::Int))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
  assert_true(
    (Ok(ignore(from_csv.get_column("d").cast(@types.DataType::Date))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
  // A Date fill value fills a Date column; a String column refuses it (the
  // frame-wide verb skips non-matching dtypes, the Series verb raises).
  let filled = df.fill_null(@types.Scalar::Date(19723L))
  assert_true(filled.item(0, "d") is @types.Scalar::Date(_))
  assert_true(
    (Ok(ignore(from_csv.get_column("d").fill_null(@types.Scalar::Date(19723L)))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "a Date literal evaluates through the expression engine" {
  let df = date_frame()
  let lit_col = df.select([
    @expr.lit(@types.Scalar::Date(19723L)).with_alias("epoch"),
  ])
  assert_eq(lit_col.get_column("epoch").dtype(), @types.DataType::Date)
  assert_eq(lit_col.item(0, "epoch").to_string(), "2024-01-01")
}

///|
test "Date rides the registry through the remaining engine paths" {
  // An empty frame builds a Date column without a dedicated constructor.
  let empty = DataFrame::empty(
    @types.Schema::Schema([@types.Field::Field("d", @types.DataType::Date)]),
  )
  assert_eq(empty.get_column("d").dtype(), @types.DataType::Date)
  // A foreign cell under a Date field is the usual TypeMismatch.
  assert_true(
    (Ok(
      ignore(
        DataFrame::from_rows(
          @types.Schema::Schema([
            @types.Field::Field("d", @types.DataType::Date),
          ]),
          [[@types.Scalar::String("2024-01-01")]],
        ),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // map_elements over Date cells infers Date.
  let df = date_frame().drop_nulls(subset=[@expr.col("d")])
  let mapped = df.select([
    @expr.col("d").map_elements(label="identity", s => {
      match s {
        @types.Scalar::Date(v) => @types.Scalar::Date(v)
        other => other
      }
    }),
  ])
  assert_eq(mapped.get_column("d").dtype(), @types.DataType::Date)
  // A positional reduction on a Date key column rebuilds Dates (the grouped
  // scalars_to_series path).
  let grouped = df
    .group_by([@expr.col("v")])
    .agg([@expr.col("d").first().with_alias("first_d")])
  assert_true(grouped.item(0, "first_d") is @types.Scalar::Date(_))
  // The variance family fences Date exactly like sum / mean.
  assert_true(
    (Ok(ignore(df.get_column("d").std())) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  assert_true(
    (Ok(ignore(df.get_column("d").median())) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // fill_null on a Date column that still HAS a null: the filled cell is a
  // Date, and the column keeps its dtype.
  let filled = date_frame().fill_null(@types.Scalar::Date(19723L))
  assert_eq(filled.get_column("d").dtype(), @types.DataType::Date)
  assert_eq(filled.item(2, "d").to_string(), "2024-01-01")
}

///|
test "a null date key groups on its own and stays null in reductions" {
  let df = date_frame()
  let grouped = df
    .group_by([@expr.col("d")])
    .agg([@expr.col("d").first().with_alias("first_d")])
  // The null key forms its own group; its first() cell is null.
  let null_group = grouped.filter(@expr.col("d").is_null())
  assert_true(null_group.item(0, "first_d") is @types.Scalar::Null)
}

///|
/// The Date-rider fence for the rebuild paths that retype by buffer variant:
/// a kernel arm rebuilding an I64 column must carry the dtype, not assume
/// `Int`. Three paths, one shape of bug — a `Date` column silently becoming
/// an `Int` column of day counts.
test "a Date branch through when/then/otherwise keeps its dtype" {
  let out = date_frame().select([
    @expr.when(@expr.col("v").gt(@expr.lit(@types.Scalar::Int(2))))
    .then(@expr.col("d"))
    .otherwise(@expr.lit(@types.Scalar::Date(19000L)))
    .with_alias("dd"),
  ])
  assert_eq(out.get_column("dd").dtype(), @types.DataType::Date)
  // v = 1, 2 take the literal (19000 = 2022-01-08); v = 3 reads the null
  // date cell (the then-branch nulls it); v = 4 keeps 2024-02-01.
  assert_eq(iso_cells(out, "dd"), [
    "2022-01-08", "2022-01-08", "null", "2024-02-01",
  ])
  // Both branches columns, no literal: same arm, same identity.
  let both = date_frame().select([
    @expr.when(@expr.col("v").gt(@expr.lit(@types.Scalar::Int(3))))
    .then(@expr.col("d"))
    .otherwise(@expr.col("d"))
    .with_alias("dd"),
  ])
  assert_eq(both.get_column("dd").dtype(), @types.DataType::Date)
  assert_eq(iso_cells(both, "dd"), [
    "2024-01-01", "2024-01-31", "null", "2024-02-01",
  ])
}

///|
test "an expression fill_null keeps a Date column a Date" {
  let out = date_frame().with_columns([
    @expr.col("d").fill_null(@expr.lit(@types.Scalar::Date(19723L))),
  ])
  assert_eq(out.get_column("d").dtype(), @types.DataType::Date)
  assert_eq(iso_cells(out, "d"), [
    "2024-01-01", "2024-01-31", "2024-01-01", "2024-02-01",
  ])
}

///|
test "fill_null with an Int scalar refuses a Date column" {
  // The Int fill is gated on the column's dtype, not its I64 buffer: a
  // Date column filled with a day count would silently retype.
  let d = date_frame().get_column("d")
  assert_true(
    (Ok(ignore(d.fill_null(@types.Scalar::Int(0)))) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "an outer join coalesces a Date key to the present side's date" {
  // Right-only rows take the right key's date, not a null: the fill reads
  // the Date spelling of the I64 rider.
  let left = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Date),
      @types.Field::Field("lv", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Date(19723L), @types.Scalar::Int(1)],
      [@types.Scalar::Date(19753L), @types.Scalar::Int(2)],
    ],
  )
  let right = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Date),
      @types.Field::Field("rv", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Date(19723L), @types.Scalar::Int(1)],
      [@types.Scalar::Date(19774L), @types.Scalar::Int(2)],
    ],
  )
  let out = left.join(
    right,
    JoinOptions::on([@expr.col("d")], how=JoinType::Outer, coalesce=true),
  )
  assert_eq(out.get_column("d").dtype(), @types.DataType::Date)
  assert_eq(iso_cells(out, "d"), ["2024-01-01", "2024-01-31", "2024-02-21"])
}

///|
/// The verb matrix for a Date column: every row-selection and shape verb
/// keeps the column a `Date` (the rider's identity rides the I64 buffer, and
/// any rebuild that dropped it would show here as an `Int` column of day
/// counts), and the one-row summaries keep it a `Date` cell or a null. The
/// fence verbs — arithmetic, cross-dtype compare, cast, mixed fills — are
/// pinned by the tests above; this one sweeps the rest.
test "every shape verb keeps a Date column a Date" {
  let df = date_frame()
  // Row windows: head / tail / slice, the saturating and negative-count
  // shapes included.
  let verbs : Array[(String, @frame.DataFrame)] = [
    ("head", df.head(2)),
    ("tail", df.tail(2)),
    ("negative tail", df.tail(-1)),
    ("slice", df.slice(1, length=2)),
    ("reverse", df.reverse()),
    ("gather", df.gather([3, 0])),
    ("bracket slice", df[1:3]),
  ]
  for i, entry in verbs {
    let (name, out) = entry
    if out.get_column("d").dtype() != @types.DataType::Date {
      println("\{name} lost the Date dtype")
    }
    assert_eq(out.get_column("d").dtype(), @types.DataType::Date)
    ignore(i)
  }
  // Null-aware row selections.
  assert_eq(
    df.drop_nulls(subset=[@expr.col("d")]).get_column("d").dtype(),
    @types.DataType::Date,
  )
  // Column management: rename keeps it, select re-roots it, with_columns
  // carries it untouched beside a new column, and the bracket sugar reads
  // the column itself.
  assert_eq(
    df.rename([("d", "day")]).get_column("day").dtype(),
    @types.DataType::Date,
  )
  assert_eq(
    df.select([@expr.col("d")]).get_column("d").dtype(),
    @types.DataType::Date,
  )
  let widened = df.with_columns([
    (@expr.col("v") + @expr.lit_int(1)).with_alias("v2"),
  ])
  assert_eq(widened.get_column("d").dtype(), @types.DataType::Date)
  assert_eq(df["d"].dtype(), @types.DataType::Date)
  // A sorted copy keeps it (ordering is by day count, the natural order;
  // ascending with nulls leading, the #412 default).
  let sorted = df.sort([(@expr.col("d"), false, false)])
  assert_eq(sorted.get_column("d").dtype(), @types.DataType::Date)
  assert_eq(
    sorted
    .get_column("d")
    .to_scalars()
    .map(s => if s is @types.Scalar::Date(v) { v } else { -1L }),
    [-1L, 19723L, 19753L, 19754L],
  )
}
