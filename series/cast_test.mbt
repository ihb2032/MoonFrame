///|
test "a nested dtype refuses the cast in both directions" {
  // A nested column casts nowhere — neither out of a scalar dtype nor
  // back into one — and the identity cast (the same dtype on both
  // sides) still answers the column itself.
  let list = @types.DataType::List(@types.DataType::Int)
  let into = Ok(ignore(Series::from_ints("v", [1]).cast(list))) catch {
    e => Err(e)
  }
  assert_true(
    into is Err(@types.DataError::Unsupported(m)) && m.contains("cast to List"),
  )
  let nested = Series::from_scalars(
    "l",
    [
      @types.Scalar::List(@types.ListValue::ListValue([@types.Scalar::Int(1)])),
      @types.Scalar::Null,
    ],
    dtype=list,
  )
  assert_eq(nested.dtype(), list)
  let out = Ok(ignore(nested.cast(@types.DataType::Int))) catch { e => Err(e) }
  assert_true(
    out is Err(@types.DataError::Unsupported(m2)) &&
    m2.contains("cast from List"),
  )
  // The identity cast keeps the cells.
  let same = nested.cast(list)
  assert_eq(same, nested)
}

///|
test "the struct twin of the nested cast refusals" {
  let fields = @types.DataType::Struct(
    @types.Schema::Schema([@types.Field::Field("a", @types.DataType::Int)]),
  )
  let into = Ok(ignore(Series::from_ints("v", [1]).cast(fields))) catch {
    e => Err(e)
  }
  assert_true(
    into is Err(@types.DataError::Unsupported(m)) &&
    m.contains("cast to Struct"),
  )
  let nested = Series::from_scalars(
    "s",
    [
      @types.Scalar::Struct(
        @types.StructValue::StructValue([
          @types.FieldValue::FieldValue("a", @types.Scalar::Int(4)),
        ]),
      ),
    ],
    dtype=fields,
  )
  let out = Ok(ignore(nested.cast(@types.DataType::String))) catch {
    e => Err(e)
  }
  assert_true(
    out is Err(@types.DataError::Unsupported(m2)) &&
    m2.contains("cast from Struct"),
  )
}

///|
test "a nested column refuses the float and decimal targets" {
  let nested = Series::from_scalars(
    "l",
    [ints([1])],
    dtype=@types.DataType::List(@types.DataType::Int),
  )
  // The two targets whose conversion the dispatcher enters name the
  // source it refused.
  for target in [@types.DataType::Float, @types.DataType::Decimal] {
    let cast = Ok(ignore(nested.cast(target))) catch { e => Err(e) }
    match cast {
      Err(@types.DataError::Unsupported(m)) =>
        assert_true(m.contains("cast from List"))
      _ => fail("cast to \{target} was expected to refuse a nested column")
    }
  }
  // The targets the dispatcher itself refuses name the target instead.
  for
    target in [
      @types.DataType::Bool,
      @types.DataType::Date,
      @types.DataType::Timestamp,
      @types.DataType::Duration,
      @types.DataType::Null,
    ] {
    let cast = Ok(ignore(nested.cast(target))) catch { e => Err(e) }
    match cast {
      Err(@types.DataError::Unsupported(m)) =>
        assert_true(m.contains("cast to \{target}"))
      _ => fail("cast to \{target} was expected to refuse a nested column")
    }
  }
  // Every scalar source refuses the struct target. The ones the
  // dispatcher routes by target name the target; the `I64` riders are
  // stopped one gate earlier, by their own dtype.
  let fields = @types.DataType::Struct(
    @types.Schema::Schema([@types.Field::Field("a", @types.DataType::Int)]),
  )
  for
    source in [
      Series::from_floats("v", [1.0]),
      Series::from_bools("v", [true]),
      Series::from_strings("v", ["x"]),
      Series::from_decimals("v", [
        Some(@types.Dec128::of_int64_scale(1, scale=0)),
      ]),
    ] {
    let cast = Ok(ignore(source.cast(fields))) catch { e => Err(e) }
    match cast {
      Err(@types.DataError::Unsupported(m)) =>
        assert_true(m.contains("cast to Struct"))
      _ => fail("cast to Struct was expected to refuse")
    }
  }
  let riders : Array[(Series, String)] = [
    (Series::from_date_options("v", [Some(0)]), "Date"),
    (Series::from_timestamp_options("v", [Some(0)]), "Timestamp"),
    (Series::from_duration_options("v", [Some(0)]), "Duration"),
  ]
  for entry in riders {
    let (column, rider) = entry
    let cast = Ok(ignore(column.cast(fields))) catch { e => Err(e) }
    match cast {
      Err(@types.DataError::Unsupported(m)) =>
        assert_true(m.contains("cast from \{rider}"))
      _ => fail("cast to Struct was expected to refuse")
    }
  }
}
