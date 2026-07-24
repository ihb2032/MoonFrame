// `Field.nullable` is declared, never inferred: `nullable = false` originates
// only in a caller-supplied `from_rows` schema. These tests pin where that
// declaration travels — the projections that merely move a column carry it,
// the ones that compute new cells derive a fresh field.

///|
/// Two columns, one of them declared non-nullable, so a projection can be
/// observed either carrying the flag or resetting it.
fn declared_df() -> DataFrame raise @types.DataError {
  DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("id", @types.DataType::Int, nullable=false),
      @types.Field::Field("qty", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Int(1), @types.Scalar::Int(10)],
      [@types.Scalar::Int(2), @types.Scalar::Null],
    ],
  )
}

// ── Carried: the column moves, its declaration moves with it ────────

///|
test "a bare projection carries the declared flag, under an alias too" {
  let df = declared_df()
  let bare = df.select([@expr.col("id"), @expr.col("qty")])
  assert_false(bare.schema().field("id").nullable())
  assert_true(bare.schema().field("qty").nullable())
  // An alias changes the name and nothing else, so the declaration follows it.
  let aliased = df.select([@expr.col("id").with_alias("key")])
  assert_false(aliased.schema().field("key").nullable())
}

///|
test "drop keeps the declaration of every surviving column" {
  let out = declared_df().drop([@expr.col("qty")])
  assert_eq(out.schema().fields(), [
    @types.Field::Field("id", @types.DataType::Int, nullable=false),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "with_columns leaves the columns it does not touch alone" {
  // Adding a column used to re-derive every field, resetting the declaration
  // on columns the call never mentioned.
  let out = declared_df().with_columns([@expr.lit_int(0).with_alias("seq")])
  assert_false(out.schema().field("id").nullable())
  assert_true(out.schema().field("seq").nullable())
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "with_columns replacing a column by itself keeps its declaration" {
  let out = declared_df().with_columns([@expr.col("id")])
  assert_false(out.schema().field("id").nullable())
}

///|
test "a replaced column takes the declaration of the column it now holds" {
  // `qty`'s cells land under the name `id`, so the output describes `qty`:
  // the nullable `qty` declaration wins over the non-nullable `id` one.
  let out = declared_df().with_columns([@expr.col("qty").with_alias("id")])
  assert_true(out.schema().field("id").nullable())
  // And the other way round: `id`'s cells under the name `qty`.
  let back = declared_df().with_columns([@expr.col("id").with_alias("qty")])
  assert_false(back.schema().field("qty").nullable())
}

// ── Derived: new cells, new field ───────────────────────────────────

///|
test "a computed projection derives a fresh field" {
  let df = declared_df()
  // Arithmetic, an aggregation and a cast all produce cells the declaration
  // was never made about, so each resets to the constructor default.
  let arith = df.select([(@expr.col("id") * @expr.lit_int(2)).with_alias("id")])
  assert_true(arith.schema().field("id").nullable())
  let agg = df.select([@expr.col("id").sum().with_alias("id")])
  assert_true(agg.schema().field("id").nullable())
  let cast = df.select([
    @expr.col("id").cast(@types.DataType::Float).with_alias("id"),
  ])
  assert_true(cast.schema().field("id").nullable())
  assert_eq(cast.schema().field("id").dtype(), @types.DataType::Float)
}

///|
test "a fill_null over a declared column still derives a fresh field" {
  // `fill_null` as an *expression* computes new cells (that is its point), so
  // unlike `DataFrame::fill_null` — a row transform that reuses the schema
  // verbatim — it does not inherit the input's declaration.
  let out = declared_df().select([
    @expr.col("qty").fill_null(@expr.lit_int(0)).with_alias("id"),
  ])
  assert_true(out.schema().field("id").nullable())
}

// ── The declaration stays honest ────────────────────────────────────

///|
test "with_row_index prepends a counter without disturbing the schema" {
  // Its docstring's promise — the counter "never changes any other column's
  // nullability" — is only true if the existing fields are carried, not
  // re-derived from the widened column vector.
  let out = declared_df().with_row_index(name="i")
  assert_eq(out.schema().fields(), [
    @types.Field::Field("i", @types.DataType::Int),
    @types.Field::Field("id", @types.DataType::Int, nullable=false),
    @types.Field::Field("qty", @types.DataType::Int),
  ])
}

///|
test "a carried non-nullable column really holds no nulls" {
  // What makes carrying sound: `nullable = false` is validated once, by
  // `from_rows`, and every op that carries it only moves or drops cells.
  let projected = declared_df()
    .select([@expr.col("id")])
    .filter(@expr.col("id").gt(@expr.lit_int(1)))
  assert_false(projected.schema().field("id").nullable())
  assert_eq(projected.get_column("id").null_count(), 0)
}
