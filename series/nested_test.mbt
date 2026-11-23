// Blackbox tests for nested columns through the `Series` verbs — the
// support a nested column has on its own, before any frame or
// expression asks for it: building from cells, reading cells back, the
// row verbs, the order (sort and the extrema), the key (distinct), and
// the null fill. The shape rule `DataType::fits_value` is the gate each
// build reads.

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
fn lists_of_ints() -> @types.DataType {
  @types.DataType::List(@types.DataType::Int)
}

///|
fn two_fields() -> @types.DataType raise @types.DataError {
  @types.DataType::Struct(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Int),
      @types.Field::Field("b", @types.DataType::String),
    ]),
  )
}

///|
test "a list series builds from cells and reads them back" {
  let s = Series::from_scalars(
    "tags",
    [ints([1, 2]), @types.Scalar::Null, lv([]), ints([3])],
    dtype=lists_of_ints(),
  )
  assert_eq(s.dtype(), lists_of_ints())
  assert_eq(s.len(), 4)
  assert_eq(s.null_count(), 1)
  assert_eq(s.to_scalars().copy(), [
    ints([1, 2]),
    @types.Scalar::Null,
    lv([]),
    ints([3]),
  ])
  assert_eq(s.get(0), ints([1, 2]))
  assert_true(s.is_null(1))
  assert_false(s.is_null(2))
  // The iter walks the same cells.
  let walked : Array[@types.Scalar] = []
  for cell in s.iter() {
    walked.push(cell)
  }
  assert_eq(walked, s.to_scalars().copy())
}

///|
test "a struct series builds from cells and reads them back" {
  let dtype = two_fields()
  let s = Series::from_scalars(
    "point",
    [sv(@types.Scalar::Int(1), @types.Scalar::String("x")), @types.Scalar::Null],
    dtype~,
  )
  assert_eq(s.dtype(), dtype)
  assert_eq(s.len(), 2)
  assert_eq(s.get(0), sv(@types.Scalar::Int(1), @types.Scalar::String("x")))
  assert_eq(s.get(1), @types.Scalar::Null)
}

///|
test "the column dtype is read off the first cell that names one" {
  // An empty list, a null, and a list of nulls name no element dtype:
  // the first list that does decides, and the others fit it.
  let s = Series::from_scalars("l", [
    @types.Scalar::Null,
    lv([]),
    lv([@types.Scalar::Null]),
    ints([5]),
    ints([6]),
  ])
  assert_eq(s.dtype(), lists_of_ints())
  assert_eq(s.get(1), lv([]))
  assert_eq(s.get(2), lv([@types.Scalar::Null]))
  // A struct's dtype is its first named cell's.
  let t = Series::from_scalars("s", [
    sv(@types.Scalar::Null, @types.Scalar::Null),
    sv(@types.Scalar::Int(1), @types.Scalar::String("y")),
  ])
  assert_eq(t.dtype(), two_fields())
  assert_eq(t.get(0), sv(@types.Scalar::Null, @types.Scalar::Null))
}

///|
test "a nested column that names no dtype cannot be inferred" {
  // Every cell null.
  let nulls = Ok(
    ignore(
      Series::from_scalars("l", [@types.Scalar::Null, @types.Scalar::Null]),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    nulls is Err(@types.DataError::InvalidOperation(m)) &&
    m.contains("cannot infer a dtype"),
  )
  // Present cells that name nothing: empty lists, lists of nulls, a
  // struct whose every field is null.
  for
    cells in [
      [lv([]), lv([])],
      [lv([@types.Scalar::Null]), lv([])],
      [sv(@types.Scalar::Null, @types.Scalar::Null), @types.Scalar::Null],
    ] {
    let unnamed = Ok(ignore(Series::from_scalars("l", cells))) catch {
      e => Err(e)
    }
    assert_true(
      unnamed is Err(@types.DataError::InvalidOperation(m)) &&
      m.contains("names no dtype"),
    )
  }
  // A dtype pinned by hand makes the same cells a column — the empty
  // lists are lists of the pinned element dtype.
  let pinned = Series::from_scalars(
    "l",
    [lv([]), @types.Scalar::Null],
    dtype=lists_of_ints(),
  )
  assert_eq(pinned.dtype(), lists_of_ints())
  assert_eq(pinned.get(0), lv([]))
  assert_eq(pinned.get(1), @types.Scalar::Null)
  // Pinning `Null` as the element dtype names no column to build the
  // child from — the refusal a top-level `Null` column gets.
  let null_element = Ok(
    ignore(
      Series::from_scalars(
        "l",
        [lv([])],
        dtype=@types.DataType::List(@types.DataType::Null),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    null_element is Err(@types.DataError::Unsupported(m)) &&
    m.contains("dtype Null"),
  )
  // A struct of two null fields under a pinned schema.
  let struct_pinned = Series::from_scalars(
    "s",
    [sv(@types.Scalar::Null, @types.Scalar::Null)],
    dtype=two_fields(),
  )
  assert_eq(struct_pinned.get(0), sv(@types.Scalar::Null, @types.Scalar::Null))
}

///|
test "a cell that does not fit the dtype refuses the build" {
  // An element of another dtype.
  let element = Ok(
    ignore(
      Series::from_scalars(
        "l",
        [ints([1]), lv([@types.Scalar::String("x")])],
        dtype=lists_of_ints(),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    element
    is Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Expected(want, got, name),
      ),
    ) &&
    want == lists_of_ints() &&
    got == @types.DataType::List(@types.DataType::String) &&
    name == "l",
  )
  // A struct with a value under another name.
  let dtype = two_fields()
  let renamed = Ok(
    ignore(
      Series::from_scalars(
        "s",
        [
          @types.Scalar::Struct(
            @types.StructValue::StructValue([
              fv("a", @types.Scalar::Int(1)),
              fv("z", @types.Scalar::String("x")),
            ]),
          ),
        ],
        dtype~,
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(renamed is Err(@types.DataError::TypeMismatch(_)))
  // The shape rule is the gate, one function for every nested build.
  assert_true(lists_of_ints().fits_value(lv([])))
  assert_false(dtype.fits_value(ints([1])))
}

///|
test "the row verbs move nested cells whole" {
  let s = Series::from_scalars(
    "l",
    [ints([1, 2]), @types.Scalar::Null, ints([3]), lv([])],
    dtype=lists_of_ints(),
  )
  assert_eq(s.head(2).to_scalars().copy(), [ints([1, 2]), @types.Scalar::Null])
  assert_eq(s.tail(2).to_scalars().copy(), [ints([3]), lv([])])
  assert_eq(s.slice(1, length=2).to_scalars().copy(), [
    @types.Scalar::Null,
    ints([3]),
  ])
  assert_eq(s.reverse().to_scalars().copy(), [
    lv([]),
    ints([3]),
    @types.Scalar::Null,
    ints([1, 2]),
  ])
  let gathered = s.gather([2, 0, 2])
  assert_eq(gathered.to_scalars().copy(), [ints([3]), ints([1, 2]), ints([3])])
  // Dropping the nulls keeps the nested cells as they were.
  let dropped = s.drop_nulls()
  assert_eq(dropped.len(), 3)
  assert_eq(dropped.to_scalars().copy(), [ints([1, 2]), ints([3]), lv([])])
  // A slice of one cell still carries only that cell's elements.
  assert_eq(s.slice(2).get(0), ints([3]))
}

///|
test "a nested column sorts by its total order" {
  let s = Series::from_scalars(
    "l",
    [
      ints([1, 2]),
      @types.Scalar::Null,
      ints([1]),
      lv([]),
      ints([1, 2, 0]),
      ints([2]),
      lv([@types.Scalar::Null, @types.Scalar::Int(1)]),
    ],
    dtype=lists_of_ints(),
  )
  // Lexicographic: a prefix sorts before its extension; a null element
  // before a present one — so a list that opens with a null sorts before
  // the list that opens with a value; a null cell first under the
  // default placement.
  let ascending = s.sort()
  assert_eq(ascending.to_scalars().copy(), [
    @types.Scalar::Null,
    lv([]),
    lv([@types.Scalar::Null, @types.Scalar::Int(1)]),
    ints([1]),
    ints([1, 2]),
    ints([1, 2, 0]),
    ints([2]),
  ])
  // Descending flips the values and keeps the null placement rule.
  let descending = s.sort(descending=true)
  assert_eq(descending.to_scalars().copy(), [
    @types.Scalar::Null,
    ints([2]),
    ints([1, 2, 0]),
    ints([1, 2]),
    ints([1]),
    lv([@types.Scalar::Null, @types.Scalar::Int(1)]),
    lv([]),
  ])
  // Nulls last.
  let nulls_last = s.sort(nulls_last=true)
  assert_eq(nulls_last.last(), @types.Scalar::Null)
  assert_eq(nulls_last.len(), s.len())
}

///|
test "a nested column's extrema are its sorted ends" {
  let s = Series::from_scalars(
    "l",
    [ints([3]), ints([1, 9]), @types.Scalar::Null, lv([]), ints([1, 2])],
    dtype=lists_of_ints(),
  )
  assert_eq(s.min(), lv([]))
  assert_eq(s.max(), ints([3]))
  // The whole-frame extrema read the same order: the registry row says
  // the dtype is orderable, so `DataFrame::min` / `max` agree with these
  // and with what `describe` reports.
  assert_true(s.dtype().orderable())
  // A struct orders field by field.
  let dtype = two_fields()
  let t = Series::from_scalars(
    "s",
    [
      sv(@types.Scalar::Int(2), @types.Scalar::String("a")),
      sv(@types.Scalar::Int(1), @types.Scalar::String("z")),
      sv(@types.Scalar::Int(1), @types.Scalar::String("b")),
    ],
    dtype~,
  )
  assert_eq(t.min(), sv(@types.Scalar::Int(1), @types.Scalar::String("b")))
  assert_eq(t.max(), sv(@types.Scalar::Int(2), @types.Scalar::String("a")))
  assert_eq(t.sort().to_scalars().copy(), [
    sv(@types.Scalar::Int(1), @types.Scalar::String("b")),
    sv(@types.Scalar::Int(1), @types.Scalar::String("z")),
    sv(@types.Scalar::Int(2), @types.Scalar::String("a")),
  ])
}

///|
test "nested cells key by their shape" {
  let s = Series::from_scalars(
    "l",
    [
      ints([1, 2]),
      ints([1, 2]),
      @types.Scalar::Null,
      lv([]),
      ints([2, 1]),
      ints([1]),
    ],
    dtype=lists_of_ints(),
  )
  // `[1, 2]` twice is one value; order inside a list is part of it; the
  // null cell is one distinct value.
  assert_eq(s.n_unique(), 5)
  let floats = Series::from_scalars(
    "f",
    [
      lv([@types.Scalar::Float(1.0)]),
      lv([@types.Scalar::Float(1.0)]),
      lv([@types.Scalar::Float(0.0)]),
      lv([@types.Scalar::Float(-0.0)]),
    ],
    dtype=@types.DataType::List(@types.DataType::Float),
  )
  // `-0.0` folds onto `0.0`, as it does for a bare float key.
  assert_eq(floats.n_unique(), 2)
  let struct_s = Series::from_scalars(
    "s",
    [
      sv(@types.Scalar::Int(1), @types.Scalar::String("x")),
      sv(@types.Scalar::Int(1), @types.Scalar::String("x")),
      sv(@types.Scalar::Int(1), @types.Scalar::String("y")),
    ],
    dtype=two_fields(),
  )
  assert_eq(struct_s.n_unique(), 2)
}

///|
test "a nested value fills the nulls of a nested column" {
  let fill = ints([0])
  let s = Series::from_scalars(
    "l",
    [ints([1, 2]), @types.Scalar::Null, ints([3]), @types.Scalar::Null],
    dtype=lists_of_ints(),
  )
  let filled = s.fill_null(fill)
  assert_eq(filled.dtype(), lists_of_ints())
  assert_eq(filled.null_count(), 0)
  assert_eq(filled.to_scalars().copy(), [
    ints([1, 2]),
    ints([0]),
    ints([3]),
    ints([0]),
  ])
  // An empty list fills a list of any element dtype.
  let emptied = s.fill_null(lv([]))
  assert_eq(emptied.get(1), lv([]))
  // A value that does not fit the column's dtype refuses.
  let refused = Ok(ignore(s.fill_null(lv([@types.Scalar::String("x")])))) catch {
    e => Err(e)
  }
  assert_true(
    refused
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(m)),
    ) &&
    m.contains("fill_null type"),
  )
  // A scalar fill value refuses on a nested column.
  let scalar_fill = Ok(ignore(s.fill_null(@types.Scalar::Int(0)))) catch {
    e => Err(e)
  }
  assert_true(scalar_fill is Err(@types.DataError::TypeMismatch(_)))
  // A nested fill value refuses on a scalar column.
  let on_scalar = Ok(ignore(Series::from_ints("v", [1]).fill_null(fill))) catch {
    e => Err(e)
  }
  assert_true(on_scalar is Err(@types.DataError::TypeMismatch(_)))
  // A struct fill: a null field of the value stays a null field.
  let dtype = two_fields()
  let t = Series::from_scalars(
    "s",
    [sv(@types.Scalar::Int(1), @types.Scalar::String("x")), @types.Scalar::Null],
    dtype~,
  )
  let t_filled = t.fill_null(sv(@types.Scalar::Int(0), @types.Scalar::Null))
  assert_eq(t_filled.get(1), sv(@types.Scalar::Int(0), @types.Scalar::Null))
}

///|
test "nested columns are equal by content and compare unequal by shape" {
  let a = Series::from_scalars(
    "l",
    [ints([1, 2]), @types.Scalar::Null],
    dtype=lists_of_ints(),
  )
  let b = Series::from_scalars(
    "l",
    [ints([1, 2]), @types.Scalar::Null],
    dtype=lists_of_ints(),
  )
  assert_eq(a, b)
  let c = Series::from_scalars(
    "l",
    [ints([2, 1]), @types.Scalar::Null],
    dtype=lists_of_ints(),
  )
  assert_not_eq(a, c)
  // A null list and a list holding a null are different columns.
  let null_cell = Series::from_scalars(
    "l",
    [@types.Scalar::Null],
    dtype=lists_of_ints(),
  )
  let null_inside = Series::from_scalars(
    "l",
    [lv([@types.Scalar::Null])],
    dtype=lists_of_ints(),
  )
  assert_not_eq(null_cell, null_inside)
  // Another element dtype is another column.
  let strings = Series::from_scalars(
    "l",
    [lv([@types.Scalar::String("1")])],
    dtype=@types.DataType::List(@types.DataType::String),
  )
  assert_not_eq(
    strings,
    Series::from_scalars("l", [ints([1])], dtype=lists_of_ints()),
  )
  // A struct against a list.
  assert_not_eq(
    Series::from_scalars(
      "s",
      [sv(@types.Scalar::Int(1), Null)],
      dtype=two_fields(),
    ),
    Series::from_scalars("s", [ints([1])], dtype=lists_of_ints()),
  )
}

///|
test "a nested column renders its cells as text" {
  let s = Series::from_scalars(
    "l",
    [ints([1, 2]), @types.Scalar::Null],
    dtype=lists_of_ints(),
  )
  assert_eq(s.get(0).to_string(), "[1, 2]")
  assert_eq(s.dtype().to_string(), "List(Int)")
  let t = Series::from_scalars(
    "s",
    [sv(@types.Scalar::Int(1), @types.Scalar::String("x"))],
    dtype=two_fields(),
  )
  assert_eq(t.dtype().to_string(), "Struct(a: Int, b: String)")
}
