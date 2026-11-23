// Whitebox pins for the nested columns at the column layer: the Arrow
// layout the two bodies carry (offsets over a flattened child; one child
// per field), the cell reads through it, the row verbs' sub-views, and
// the refusals a direct caller can still reach. Everything here goes
// through the production surface — the builders, the readers, and the
// sub-view helpers the row verbs call.

///|
fn list_dtype(element : @types.DataType) -> @types.DataType {
  @types.DataType::List(element)
}

///|
fn struct_schema() -> @types.Schema raise @types.DataError {
  @types.Schema::Schema([
    @types.Field::Field("a", @types.DataType::Int),
    @types.Field::Field("b", @types.DataType::String),
  ])
}

///|
fn struct_dtype() -> @types.DataType raise @types.DataError {
  @types.DataType::Struct(struct_schema())
}

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
fn int_list(cells : Array[Int64]) -> @types.Scalar {
  lv(cells.map(i => @types.Scalar::Int(i)))
}

///|
fn int_child(cells : Array[Int64]) -> ColumnStorage {
  ColumnStorage::Builtin(BuiltinColumn::from_ints(cells))
}

///|
/// The cell bounds of a list body, read through the offset reader: the
/// start of every cell, then the end of the last one.
fn bounds_of(body : ListArray) -> Array[Int32] {
  let out : Array[Int32] = []
  for i in 0..<=body.len() {
    out.push(body.offset(i))
  }
  out
}

///|
/// The list body of a column known to carry one, or `None` for any other
/// shape (which fails the assertion that follows rather than the test).
fn list_body_of(column : BuiltinColumn) -> ListArray? {
  match column.data() {
    List(body) => Some(body)
    _ => None
  }
}

///|
test "a list column lays its cells out as offsets over one child" {
  let column = BuiltinColumn::from_scalars(
    list_dtype(@types.DataType::Int),
    [
      int_list([1, 2]),
      @types.Scalar::Null,
      lv([]),
      lv([@types.Scalar::Null, @types.Scalar::Int(5)]),
      @types.Scalar::Int(9),
    ],
    name="l",
  )
  assert_eq(column.dtype(), list_dtype(@types.DataType::Int))
  assert_eq(column.len(), 5)
  let body = list_body_of(column).unwrap()
  // Five cells over four flattened elements: a null cell and an
  // off-type cell own empty runs.
  assert_eq(bounds_of(body), [0, 2, 2, 2, 4, 4])
  assert_eq(body.child().len(), 4)
  assert_eq(body.child().dtype(), @types.DataType::Int)
  // An element that does not fit the element dtype reads as a null
  // element — the child's validity says so.
  assert_eq(body.child().null_count(), 1)
  // The outer validity: a `Null` cell and an off-type cell are null cells.
  assert_eq(column.null_count(), 2)
  assert_eq(column.get(0), int_list([1, 2]))
  assert_eq(column.get(1), @types.Scalar::Null)
  assert_eq(column.get(2), lv([]))
  assert_eq(column.get(3), lv([@types.Scalar::Null, @types.Scalar::Int(5)]))
  assert_eq(column.get(4), @types.Scalar::Null)
}

///|
test "a struct column carries one child per field" {
  let column = BuiltinColumn::from_scalars(
    struct_dtype(),
    [
      sv(@types.Scalar::Int(1), @types.Scalar::String("x")),
      @types.Scalar::Null,
      // The field names come from the dtype: a value under another name
      // contributes a null to that field.
      @types.Scalar::Struct(
        @types.StructValue::StructValue([
          fv("a", @types.Scalar::Int(3)),
          fv("z", @types.Scalar::String("w")),
        ]),
      ),
      // An off-type field value is a null on that field alone.
      @types.Scalar::Struct(
        @types.StructValue::StructValue([
          fv("a", @types.Scalar::String("no")),
          fv("b", @types.Scalar::String("y")),
        ]),
      ),
    ],
    name="s",
  )
  assert_eq(column.dtype(), struct_dtype())
  assert_eq(column.len(), 4)
  match column.data() {
    Struct(body) => {
      assert_eq(body.children().length(), 2)
      assert_eq(body.len(), 4)
      let a = body.children()[0]
      let b = body.children()[1]
      assert_eq(a.dtype(), @types.DataType::Int)
      assert_eq(b.dtype(), @types.DataType::String)
      assert_eq(storage_get_total(a, 0), @types.Scalar::Int(1))
      assert_eq(storage_get_total(a, 1), @types.Scalar::Null)
      assert_eq(storage_get_total(a, 2), @types.Scalar::Int(3))
      assert_eq(storage_get_total(a, 3), @types.Scalar::Null)
      assert_eq(storage_get_total(b, 0), @types.Scalar::String("x"))
      assert_eq(storage_get_total(b, 1), @types.Scalar::Null)
      assert_eq(storage_get_total(b, 2), @types.Scalar::Null)
      assert_eq(storage_get_total(b, 3), @types.Scalar::String("y"))
    }
    _ => fail("a struct column carries the Struct body")
  }
  assert_eq(
    column.get(0),
    sv(@types.Scalar::Int(1), @types.Scalar::String("x")),
  )
  assert_eq(column.get(1), @types.Scalar::Null)
  assert_eq(column.get(2), sv(@types.Scalar::Int(3), @types.Scalar::Null))
  assert_eq(column.get(3), sv(@types.Scalar::Null, @types.Scalar::String("y")))
}

///|
test "the row verbs' sub-views re-lay the nested bodies" {
  let column = BuiltinColumn::from_scalars(
    list_dtype(@types.DataType::Int),
    [
      int_list([1, 2, 3]),
      @types.Scalar::Null,
      int_list([4]),
      lv([@types.Scalar::Int(5), @types.Scalar::Null]),
    ],
    name="l",
  )
  // A slice holds only the elements its cells own.
  let window = list_body_of(column.slice_unchecked(2, 4)).unwrap()
  assert_eq(bounds_of(window), [0, 1, 3])
  assert_eq(window.child().len(), 3)
  // A gather re-lays the child the gathered cells need.
  let gathered = list_body_of(column.take([3, 0, 3])).unwrap()
  assert_eq(bounds_of(gathered), [0, 2, 5, 7])
  assert_eq(gathered.child().len(), 7)
  // The struct twin: every child sliced / gathered the same way.
  let structs = BuiltinColumn::from_scalars(
    struct_dtype(),
    [
      sv(@types.Scalar::Int(1), @types.Scalar::String("x")),
      @types.Scalar::Null,
      sv(@types.Scalar::Int(3), @types.Scalar::String("z")),
    ],
    name="s",
  )
  match structs.slice_unchecked(1, 3).data() {
    Struct(body) => {
      assert_eq(body.len(), 2)
      assert_eq(body.children().length(), 2)
    }
    _ => fail("still a struct")
  }
  match structs.take([2, 2]).data() {
    Struct(body) => assert_eq(body.len(), 2)
    _ => fail("still a struct")
  }
}

///|
test "a nested element nests: a list of lists, a struct of a list" {
  let inner = list_dtype(@types.DataType::Int)
  let outer = BuiltinColumn::from_scalars(
    list_dtype(inner),
    [lv([int_list([1]), lv([])]), @types.Scalar::Null, lv([int_list([2, 3])])],
    name="ll",
  )
  assert_eq(outer.dtype(), list_dtype(inner))
  assert_eq(outer.get(0), lv([int_list([1]), lv([])]))
  assert_eq(outer.get(1), @types.Scalar::Null)
  assert_eq(outer.get(2), lv([int_list([2, 3])]))
  // The gather and the slice still answer through both levels.
  let taken = outer.take([2, 0])
  assert_eq(taken.get(0), outer.get(2))
  assert_eq(taken.get(1), outer.get(0))
  assert_eq(outer.slice_unchecked(2, 3).get(0), outer.get(2))
  let of_list = @types.DataType::Struct(
    @types.Schema::Schema([
      @types.Field::Field("a", inner),
      @types.Field::Field("b", @types.DataType::String),
    ]),
  )
  let structs = BuiltinColumn::from_scalars(
    of_list,
    [sv(int_list([7]), @types.Scalar::String("x")), @types.Scalar::Null],
    name="sl",
  )
  assert_eq(structs.get(0), sv(int_list([7]), @types.Scalar::String("x")))
  let picked = structs.take([1, 0])
  assert_eq(picked.get(0), @types.Scalar::Null)
  assert_eq(picked.get(1), sv(int_list([7]), @types.Scalar::String("x")))
}

///|
test "the body constructor refuses layouts that break the rules" {
  let child = int_child([1, 2, 3])
  // The refusal the constructor raises for `offsets`, or `None` when it
  // built a body instead.
  let refusal = fn(offsets : Array[Int32], name : String) -> @types.DataError? {
    let built = Ok(ignore(ListArray::from_parts(offsets, child, name~))) catch {
      e => Err(e)
    }
    match built {
      Err(e) => Some(e)
      Ok(_) => None
    }
  }
  // No entry at all.
  assert_true(
    refusal([], "l") is Some(InvalidOperation(m)) &&
    m.contains("carry no entry"),
  )
  // Not starting at zero.
  assert_true(
    refusal([1, 3], "l") is Some(InvalidOperation(m)) &&
    m.contains("start at 1 rather than 0"),
  )
  // Decreasing.
  assert_true(
    refusal([0, 2, 1, 3], "l") is Some(InvalidOperation(m)) &&
    m.contains("decrease at 2 (1 after 2)"),
  )
  // Ending past or short of the child.
  assert_true(
    refusal([0, 2], "l") is Some(InvalidOperation(m)) &&
    m.contains("end at 2 but the child holds 3"),
  )
  // The column's own name rides into every message.
  assert_true(
    refusal([0, 2], "tags") is Some(InvalidOperation(m)) &&
    m.contains("column \"tags\""),
  )
  // A struct whose children disagree in length.
  let ragged = Ok(ignore(StructArray::from_parts([child, int_child([1])]))) catch {
    e => Err(e)
  }
  assert_true(ragged is Err(LengthMismatch(3, 1)))
}

///|
test "the empty shapes: no cells over an empty child" {
  // A list body with no cells sits over an empty child, and its offset
  // reader answers the one bound it has for any index.
  let empty_child = int_child([])
  let body = ListArray::from_parts([0], empty_child, name="l")
  assert_eq(body.len(), 0)
  assert_eq(body.offset(0), 0)
  assert_eq(body.offset(7), 0)
  // An empty body cannot sit over a child that holds elements.
  let over_elements = Ok(
    ignore(ListArray::from_parts([0], int_child([1, 2, 3]), name="l")),
  ) catch {
    e => Err(e)
  }
  assert_true(
    over_elements is Err(InvalidOperation(m)) &&
    m.contains("end at 0 but the child holds 3"),
  )
  // A struct body with no children has no cells and no fields; one with
  // children but no rows has its fields and no cells.
  let bare = StructArray::from_parts([])
  assert_eq(bare.len(), 0)
  assert_eq(bare.children().length(), 0)
  let no_rows = StructArray::from_parts([empty_child, empty_child])
  assert_eq(no_rows.len(), 0)
  assert_eq(no_rows.children().length(), 2)
  // The same shapes built the way a reader builds them: from no cells.
  let list = BuiltinColumn::from_scalars(
    list_dtype(@types.DataType::Int),
    [],
    name="l",
  )
  assert_eq(list.len(), 0)
  assert_eq(bounds_of(list_body_of(list).unwrap()), [0])
  let struct_col = BuiltinColumn::from_scalars(struct_dtype(), [], name="s")
  assert_eq(struct_col.len(), 0)
}

///|
test "the offset reader clamps a stray index to the nearest bound" {
  let body = ListArray::from_parts([0, 1, 3], int_child([1, 2, 3]), name="l")
  assert_eq(body.offset(-4), 0)
  assert_eq(body.offset(0), 0)
  assert_eq(body.offset(1), 1)
  assert_eq(body.offset(2), 3)
  assert_eq(body.offset(9), 3)
}

///|
test "the nested builders refuse the shapes that name no column" {
  // A struct with no fields.
  let bare = Ok(
    ignore(
      BuiltinColumn::from_struct_cells(@types.Schema::Schema([]), [], name="s"),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    bare is Err(Unsupported(m)) && m.contains("struct column with no fields"),
  )
  // A list whose element dtype is `Null` names no child column.
  let null_element = Ok(
    ignore(
      BuiltinColumn::from_scalars(
        list_dtype(@types.DataType::Null),
        [lv([])],
        name="l",
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(null_element is Err(Unsupported(m)) && m.contains("dtype Null"))
}

///|
test "an empty inner list stays an empty list under a nested element dtype" {
  // The shape test that catches the dtype-equality trap: an empty list's
  // own dtype names `Null`, so comparing dtypes would read it as
  // off-type and null it — it is still a list of the element dtype, and
  // an all-null list likewise.
  let inner = list_dtype(@types.DataType::Int)
  let column = BuiltinColumn::from_scalars(
    list_dtype(inner),
    [
      lv([]),
      lv([lv([]), lv([@types.Scalar::Null])]),
      lv([int_list([7])]),
      @types.Scalar::Null,
    ],
    name="ll",
  )
  assert_eq(column.len(), 4)
  assert_eq(column.null_count(), 1)
  assert_eq(column.get(0), lv([]))
  assert_eq(column.get(1), lv([lv([]), lv([@types.Scalar::Null])]))
  assert_eq(column.get(2), lv([int_list([7])]))
}

///|
test "the column-layer builders null what does not fit" {
  // The series layer refuses a misfit cell before reaching here; the
  // column layer's own projection still answers for a direct caller —
  // a misfit element is a null element, a missing field a null field.
  let list = BuiltinColumn::from_list_cells(
    @types.DataType::Int,
    [
      lv([
        @types.Scalar::String("x"),
        @types.Scalar::Int(3),
        @types.Scalar::Null,
      ]),
    ],
    name="l",
  )
  let body = list_body_of(list).unwrap()
  assert_eq(body.child().null_count(), 2)
  assert_eq(storage_get_total(body.child(), 0), @types.Scalar::Null)
  assert_eq(storage_get_total(body.child(), 1), @types.Scalar::Int(3))
  assert_eq(storage_get_total(body.child(), 2), @types.Scalar::Null)
  // A struct cell that names fewer fields than the dtype: the rest are
  // null on that cell.
  let struct_col = BuiltinColumn::from_struct_cells(
    struct_schema(),
    [
      @types.Scalar::Struct(
        @types.StructValue::StructValue([fv("a", @types.Scalar::Int(1))]),
      ),
      @types.Scalar::Struct(
        @types.StructValue::StructValue([
          fv("a", @types.Scalar::Int(2)),
          fv("b", @types.Scalar::String("y")),
        ]),
      ),
    ],
    name="s",
  )
  assert_eq(struct_col.get(0), sv(@types.Scalar::Int(1), @types.Scalar::Null))
  assert_eq(
    struct_col.get(1),
    sv(@types.Scalar::Int(2), @types.Scalar::String("y")),
  )
}

///|
test "the total reader answers for a numeric child and a stray index" {
  // A nested body's children are built `Builtin`; the total reader still
  // answers for a `Numeric` column handed to it, and for an index past
  // the end of any column.
  let numeric = ColumnStorage::Numeric(NumericColumn::from_ints([5, 7]))
  assert_eq(storage_get_total(numeric, 0), @types.Scalar::Int(5))
  assert_eq(storage_get_total(numeric, 1), @types.Scalar::Int(7))
  assert_eq(storage_get_total(numeric, 2), @types.Scalar::Null)
  assert_eq(storage_get_total(numeric, -1), @types.Scalar::Null)
  let floats = ColumnStorage::Numeric(NumericColumn::from_floats([1.5]))
  assert_eq(storage_get_total(floats, 0), @types.Scalar::Float(1.5))
  assert_eq(storage_get_total(floats, 9), @types.Scalar::Null)
}

///|
test "a body under the wrong dtype reads without inventing names" {
  // The constructors pair a `Struct` body with a `Struct` dtype. The one
  // shape that reaches the reader with the two disagreeing is a column
  // built against its own dtype — built here directly — and the cell
  // then reads as a struct whose fields carry no name, rather than
  // crashing or borrowing a name from somewhere.
  let mislabeled = BuiltinColumn::{
    dtype: @types.DataType::Int,
    data: Struct(
      StructArray::from_parts([
        int_child([1]),
        ColumnStorage::Builtin(BuiltinColumn::from_strings(["x"])),
      ]),
    ),
    validity: @buffer.Bitmap::all_valid(1),
  }
  assert_eq(
    scalar_of(mislabeled.dtype(), mislabeled.data(), 0),
    @types.Scalar::Struct(
      @types.StructValue::StructValue([
        fv("", @types.Scalar::Int(1)),
        fv("", @types.Scalar::String("x")),
      ]),
    ),
  )
}

///|
test "the temporal casts refuse a nested body under a temporal dtype" {
  // Each temporal cast reaches its buffer arms only for a column of its
  // own dtype; a nested body under that dtype — the disagreeing shape,
  // built directly — takes the arm's refusal rather than reading a list
  // of offsets as day-counts or microseconds.
  let list_body = ListArray::from_parts([0, 1], int_child([1]), name="l")
  let as_date = BuiltinColumn::{
    dtype: @types.DataType::Date,
    data: List(list_body),
    validity: @buffer.Bitmap::all_valid(1),
  }
  let to_timestamp = Ok(ignore(as_date.cast(@types.DataType::Timestamp))) catch {
    e => Err(e)
  }
  assert_true(
    to_timestamp is Err(Unsupported(m)) && m.contains("cast from Date"),
  )
  let as_timestamp = BuiltinColumn::{
    dtype: @types.DataType::Timestamp,
    data: List(list_body),
    validity: @buffer.Bitmap::all_valid(1),
  }
  let to_date = Ok(ignore(as_timestamp.cast(@types.DataType::Date))) catch {
    e => Err(e)
  }
  assert_true(
    to_date is Err(Unsupported(m)) && m.contains("cast from Timestamp"),
  )
}
