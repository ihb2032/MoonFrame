// Blackbox tests for the batch-wise entries: the stripes' rows, the fields
// without a cell, and one stripe's columns — what the lazy source walks.

///|
/// The error a call raises, for a test to compare; a value answered instead
/// fails the test.
fn stripe_error(
  call : () -> Unit raise @types.DataError,
) -> @types.DataError raise {
  let outcome : Result[Unit, @types.DataError] = Ok(call()) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the call answered a value")
    Err(e) => e
  }
}

///|
test "the stripes' rows are the file's, in file order" {
  let bytes = fixture(".github/fixtures/orc/reference/pyorc_stripes.orc")
  assert_eq(orc_stripe_rows(bytes), [10, 10, 10, 10, 10, 10])
  // A file of no row holds no stripe.
  assert_eq(
    orc_stripe_rows(fixture(".github/fixtures/orc/reference/pyorc_norows.orc")),
    [],
  )
}

///|
test "the fields are the kept columns' names and dtypes, with no cell" {
  let bytes = fixture(".github/fixtures/orc/reference/pyorc_stripes.orc")
  let every = orc_fields(bytes)
  assert_eq(every.map(field => (field.name(), field.dtype())), [
    ("i", @types.DataType::Int),
    ("s", @types.DataType::String),
    ("f", @types.DataType::Float),
    ("b", @types.DataType::Bool),
  ])
  // A projection keeps its fields in file order, whatever order it names
  // them in, and one naming nothing the file carries keeps none.
  let kept = orc_fields(bytes, projection=["b", "i", "nope"])
  assert_eq(kept.map(field => field.name()), ["i", "b"])
  assert_eq(orc_fields(bytes, projection=["nope"]), [])
  // The caller's array is not kept: a later mutation of it changes nothing.
  let names = ["i"]
  let one = orc_fields(bytes, projection=names)
  names[0] = "b"
  names.push("s")
  assert_eq(one.map(field => field.name()), ["i"])
}

///|
test "a stripe's columns are the whole read's rows over that stripe" {
  let bytes = fixture(".github/fixtures/orc/reference/pyorc_stripes.orc")
  let (whole, rows) = read_orc_frame(bytes)
  assert_eq(rows, 60)
  let mut before = 0
  for k in 0..<6 {
    let (stripe, srows) = read_orc_stripe(bytes, k)
    assert_eq(srows, 10)
    assert_eq(stripe.length(), whole.length())
    for c, pair in stripe {
      let (name, column) = pair
      assert_eq(name, whole[c].0)
      assert_eq(column.dtype(), whole[c].1.dtype())
      assert_eq(
        column.to_scalars(),
        whole[c].1.slice_series(before, 10).to_scalars(),
      )
    }
    before = before + 10
  }
  // A projection reaches a stripe as it reaches the file.
  let (kept, srows) = read_orc_stripe(bytes, 2, projection=["s"])
  assert_eq(srows, 10)
  assert_eq(kept.map(pair => pair.0), ["s"])
  assert_eq(
    kept[0].1.to_scalars(),
    whole[1].1.slice_series(20, 10).to_scalars(),
  )
}

///|
test "a stripe the file does not hold is refused, and a file it cannot open refuses as the read does" {
  let bytes = fixture(".github/fixtures/orc/reference/pyorc_stripes.orc")
  for stripe in [-1, 6, 100] {
    assert_eq(
      stripe_error(() => ignore(read_orc_stripe(bytes, stripe))),
      @types.DataError::InvalidOperation(
        "orc: stripe \{stripe}, where the file holds 6",
      ),
    )
  }
  // The refusals of the whole read are the stripe's: a file of another
  // version, and a column the reader cannot carry when it is named.
  let old = fixture(".github/fixtures/orc/reference/orc_version1999.orc")
  assert_eq(
    stripe_error(() => ignore(read_orc_stripe(old, 0))),
    @types.DataError::Unsupported(
      "orc: a file of format version 19.99, which this reader does not read",
    ),
  )
  assert_eq(
    stripe_error(() => ignore(orc_stripe_rows(old))),
    @types.DataError::Unsupported(
      "orc: a file of format version 19.99, which this reader does not read",
    ),
  )
  assert_eq(
    stripe_error(() => ignore(orc_fields(old))),
    @types.DataError::Unsupported(
      "orc: a file of format version 19.99, which this reader does not read",
    ),
  )
  let every = fixture(
    ".github/fixtures/orc/reference/orc_TestOrcFile.test1.orc",
  )
  let refused = @types.DataError::Unsupported(
    "orc: column \"bytes1\" is BINARY, which has no dtype here",
  )
  assert_eq(stripe_error(() => ignore(read_orc_stripe(every, 0))), refused)
  assert_eq(stripe_error(() => ignore(orc_fields(every))), refused)
  // Its rows answer still: the stripes are the file's, whatever a column
  // the projection would name.
  assert_eq(orc_stripe_rows(every), [2])
}
