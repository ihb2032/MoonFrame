// The nested values: the two payloads a `Scalar::List` / `Scalar::Struct`
// carries. Each is an immutable wrapper that owns its cells — the enum
// payload rule ("a payload owns its data, or reading the variant hands the
// caller the container"): a constructor copies what it is handed, an
// accessor answers a copy, and nothing outside can reach the backing
// array. Equality is structural in both (cell by cell; `Double` keeps
// `NaN != NaN`), so two nested values built separately compare equal.

///|
/// The elements of one list value, in order. An element may be
/// `Scalar::Null`. The element dtype is the list *dtype's* business
/// (`DataType::List`), not the value's: a value carries only cells.
#derive(Eq, Debug)
pub struct ListValue {
  priv cells : Array[Scalar]
}

///|
pub extend ListValue with Eq::{equal, not_equal}

///|
pub extend ListValue with Debug::{to_repr}

///|
/// Build a list value from its elements, in order. `cells` is copied, so
/// the value owns its cells and a later mutation of the array cannot
/// change it. An empty array is the empty list.
pub fn ListValue::ListValue(cells : Array[Scalar]) -> ListValue {
  { cells: cells.copy(), }
}

///|
/// The elements, in order — a copy, so the value's own cells stay
/// immutable.
pub fn ListValue::cells(self : ListValue) -> Array[Scalar] {
  self.cells.copy()
}

///|
/// How many elements the list holds.
pub fn ListValue::len(self : ListValue) -> Int32 {
  self.cells.length()
}

///|
/// `true` when the list holds no elements.
pub fn ListValue::is_empty(self : ListValue) -> Bool {
  self.cells.is_empty()
}

///|
/// The element at `index` — a null element reads as `Scalar::Null`.
/// `index` outside `[0, len)` raises `IndexOutOfBounds`.
pub fn ListValue::get(
  self : ListValue,
  index : Int32,
) -> Scalar raise DataError {
  match self.cells.get(index) {
    Some(cell) => cell
    None => raise IndexOutOfBounds(index)
  }
}

///|
/// One field value of a struct: the field's name and the value held
/// there. A null value is `Scalar::Null`.
#derive(Eq, Debug)
pub struct FieldValue {
  priv name : String
  priv value : Scalar
}

///|
pub extend FieldValue with Eq::{equal, not_equal}

///|
pub extend FieldValue with Debug::{to_repr}

///|
/// Build one field value. `name` is the field's name as the struct
/// dtype spells it; `value` is the cell held there.
pub fn FieldValue::FieldValue(name : String, value : Scalar) -> FieldValue {
  { name, value, }
}

///|
/// The field's name.
pub fn FieldValue::name(self : FieldValue) -> String {
  self.name
}

///|
/// The value held at the field — `Scalar::Null` for a null.
pub fn FieldValue::value(self : FieldValue) -> Scalar {
  self.value
}

///|
/// The field values of one struct value, in the struct dtype's field
/// order — the order a `Schema`'s fields spell. The struct's dtype is
/// the *dtype's* business (`DataType::Struct`), not the value's: a value
/// carries names and cells, so it is self-describing on its own.
#derive(Eq, Debug)
pub struct StructValue {
  priv fields : Array[FieldValue]
}

///|
pub extend StructValue with Eq::{equal, not_equal}

///|
pub extend StructValue with Debug::{to_repr}

///|
/// Build a struct value from its field values, in the struct dtype's
/// field order. `fields` is copied, so the value owns its cells.
pub fn StructValue::StructValue(fields : Array[FieldValue]) -> StructValue {
  { fields: fields.copy(), }
}

///|
/// The field values, in order — a copy.
pub fn StructValue::fields(self : StructValue) -> Array[FieldValue] {
  self.fields.copy()
}

///|
/// How many fields the struct holds.
pub fn StructValue::len(self : StructValue) -> Int32 {
  self.fields.length()
}

///|
/// The field value at position `index`. `index` outside `[0, len)`
/// raises `IndexOutOfBounds`.
pub fn StructValue::get(
  self : StructValue,
  index : Int32,
) -> FieldValue raise DataError {
  match self.fields.get(index) {
    Some(field) => field
    None => raise IndexOutOfBounds(index)
  }
}

///|
/// The value held at the field named `name`, or `None` when the struct
/// carries no field of that name. The first match answers when names
/// repeat (a struct value built by hand may repeat them; a column's
/// dtype never does).
pub fn StructValue::get_named(self : StructValue, name : String) -> Scalar? {
  for field in self.fields {
    if field.name == name {
      return Some(field.value)
    }
  }
  None
}

///|
/// The dtype a nested value names — `None` when a position of its shape
/// is left unnamed. The one rule every "can this value name a column"
/// question reads: a nested literal becomes a column under the dtype it
/// names, a list value's element dtype is the first element that names
/// one, and a column's dtype is read off its first cell that names one.
///
/// A list names `List(d)` where `d` is the dtype its first *naming*
/// element names — an empty list, a list of nulls, or a list of nested
/// values that name nothing names nothing, while any one naming element
/// settles the list (the others must then fit that dtype, which the
/// column build checks). A struct names its dtype only when **every**
/// field names one: a struct's dtype spells each field's dtype, and a
/// null field or an empty list in a field leaves that field's dtype
/// unnamed. A null names nothing; every other scalar names its own
/// dtype.
pub fn Scalar::named_dtype(self : Scalar) -> DataType? {
  if self is Null {
    return None
  }
  if self is List(v) {
    for cell in v.cells() {
      match cell.named_dtype() {
        Some(d) => return Some(DataType::List(d))
        None => ()
      }
    }
    return None
  }
  if self is Struct(v) {
    // Each field's dtype, in order; the field names must also spell a
    // schema, so a repeated name leaves the value unnamed.
    let fields : Array[Field] = []
    let index : Map[String, Int32] = Map([])
    for entry in v.fields() {
      match entry.value().named_dtype() {
        Some(d) => {
          if index.contains(entry.name()) {
            return None
          }
          index[entry.name()] = fields.length()
          fields.push(Field::Field(entry.name(), d))
        }
        None => return None
      }
    }
    return Some(DataType::Struct({ fields, index, }))
  }
  Some(self.dtype())
}

///|
/// The element dtype a list value's cells name: the dtype of its first
/// element that names one (`Scalar::named_dtype`) — an element that
/// names nothing (a null, an empty list) is passed over, since it fits
/// any element dtype and so has no say in which one the list has. A
/// value with no naming element names `Null`, the dtype of a missing
/// value, which is what an empty or all-null list has to say about its
/// elements. A later element that does not fit the named dtype is not
/// reconciled here; the column build refuses it (a value alone has no
/// column to be consistent with).
pub fn ListValue::element_dtype(self : ListValue) -> DataType {
  for cell in self.cells {
    if cell.named_dtype() is Some(_) {
      return cell.dtype()
    }
  }
  DataType::Null
}

///|
/// The schema a struct value's cells spell: one field per field value,
/// in order, each typed by its value the way `ListValue::element_dtype`
/// reads an element (a null value names `Null`). Total: a value whose
/// field names repeat spells no schema (two fields of one name), which
/// answers `None` — the shape `StructValue::schema` refuses by name.
pub fn StructValue::schema_opt(self : StructValue) -> Schema? {
  let fields : Array[Field] = []
  let index : Map[String, Int32] = Map([])
  for field in self.fields {
    if index.contains(field.name) {
      return None
    }
    index[field.name] = fields.length()
    fields.push(Field::Field(field.name, field.value.dtype()))
  }
  // The uniqueness walk above is the schema constructor's own check,
  // run here so the answer is an option rather than a raise; the map is
  // the same name→position index the constructor builds, in lock-step
  // with the fields.
  Some({ fields, index, })
}

///|
/// The schema a struct value's cells spell (see `schema_opt`), raising
/// `DuplicateColumn(name)` on the first repeated field name.
pub fn StructValue::schema(self : StructValue) -> Schema raise DataError {
  match self.schema_opt() {
    Some(schema) => schema
    None => {
      let mut repeated = ""
      let seen : Array[String] = []
      for field in self.fields {
        if seen.contains(field.name) {
          repeated = field.name
          break
        }
        seen.push(field.name)
      }
      raise DuplicateColumn(repeated)
    }
  }
}

///|
/// Whether `value` may sit in a column of this dtype — the one shape
/// rule every nested build reads (a column from cells, a literal, a
/// fill value). A scalar dtype takes its own scalar; a `List` takes a
/// list whose every present element fits the element dtype (an empty
/// list fits any element dtype); a `Struct` takes a struct carrying
/// exactly this dtype's fields, in order by name, each present value
/// fitting its field's dtype. A `Null` fits every dtype: it is the
/// missing value, and which dtype's column it is missing from is the
/// column's business.
pub fn DataType::fits_value(self : DataType, value : Scalar) -> Bool {
  if value is Null {
    return true
  }
  if self is List(element) && value is List(v) {
    return v.cells().all(cell => cell is Null || element.fits_value(cell))
  }
  if self is Struct(fields) && value is Struct(v) {
    let declared = fields.fields()
    let given = v.fields()
    if given.length() != declared.length() {
      return false
    }
    for i in 0..<given.length() {
      let entry = given[i]
      if entry.name() != declared[i].name() {
        return false
      }
      if !(entry.value() is Null) &&
        !declared[i].dtype().fits_value(entry.value()) {
        return false
      }
    }
    return true
  }
  value.dtype() == self
}

///|
/// Whether a nested dtype names a real dtype somewhere inside it. A
/// value's dtype is read off its first present cell, so a value with no
/// present cell anywhere — an empty list, a list of nulls, a struct
/// whose every field is null — names `Null` where its element or field
/// dtype should be. Such a dtype is a placeholder, not a verdict: a
/// column's dtype is read off its first cell whose dtype names types,
/// and a placeholder beside a named dtype of the same shape fits the
/// column (an empty list is a list of anything). Every scalar dtype
/// but `Null` names types.
pub fn DataType::names_types(self : DataType) -> Bool {
  match self {
    Null => false
    List(element) => element.names_types()
    Struct(fields) => {
      let declared = fields.fields()
      let mut named = false
      for field in declared {
        if field.dtype().names_types() {
          named = true
        }
      }
      named
    }
    Int | Float | Bool | String | Date | Timestamp | Decimal | Duration => true
  }
}
