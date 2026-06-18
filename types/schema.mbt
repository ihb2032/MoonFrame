///|
/// Ordered list of `Field`s describing a `DataFrame`'s columns.
///
/// Construction always validates uniqueness of names; once built, a
/// `Schema` is guaranteed to have no duplicate column names.
pub(all) struct Schema {
  fields : Array[Field]
} derive(Eq, Debug)

///|
/// Build a schema from a list of fields. `raise DuplicateColumn(name)` on
/// the first repeated name.
pub fn Schema::new(fields : Array[Field]) -> Schema raise DataError {
  let seen : Map[String, Unit] = {}
  for f in fields {
    if seen.contains(f.name) {
      raise DuplicateColumn(f.name)
    }
    seen[f.name] = ()
  }
  { fields, }
}

///|
/// Return a snapshot of the schema's fields.
///
/// A fresh array is returned so callers cannot mutate the schema in place
/// and break the "no duplicate names" invariant enforced by `Schema::new`.
pub fn Schema::fields(self : Schema) -> Array[Field] {
  self.fields.copy()
}

///|
/// Number of columns in the schema.
pub fn Schema::len(self : Schema) -> Int {
  self.fields.length()
}

///|
pub fn Schema::is_empty(self : Schema) -> Bool {
  self.fields.length() == 0
}

///|
/// Column names in declaration order.
pub fn Schema::field_names(self : Schema) -> Array[String] {
  self.fields.map(fn(f) { f.name })
}

///|
/// The index of the column named `name`, or `raise ColumnNotFound(name)`.
pub fn Schema::index_of(self : Schema, name : String) -> Int raise DataError {
  for i, f in self.fields {
    if f.name == name {
      return i
    }
  }
  raise ColumnNotFound(name)
}

///|
/// Return the `Field` for `name`, or `raise ColumnNotFound(name)`.
pub fn Schema::field(self : Schema, name : String) -> Field raise DataError {
  for f in self.fields {
    if f.name == name {
      return f
    }
  }
  raise ColumnNotFound(name)
}

///|
/// Return the `Field` at position `i`, or `raise IndexOutOfBounds(i)`.
pub fn Schema::field_at(self : Schema, i : Int) -> Field raise DataError {
  if i < 0 || i >= self.fields.length() {
    raise IndexOutOfBounds(i)
  }
  self.fields[i]
}

///|
/// Project a sub-schema by name, preserving the order of `names`. Missing
/// names `raise ColumnNotFound(name)`; duplicates inside `names`
/// `raise DuplicateColumn(name)`.
pub fn Schema::select(
  self : Schema,
  names : Array[String],
) -> Schema raise DataError {
  let picked : Array[Field] = []
  let seen : Map[String, Unit] = {}
  for n in names {
    if seen.contains(n) {
      raise DuplicateColumn(n)
    }
    seen[n] = ()
    // `field` raises `ColumnNotFound(n)` for an unknown name; it propagates.
    picked.push(self.field(n))
  }
  { fields: picked }
}

///|
/// Rename `old_name` to `new_name`. Raises if `old_name` is missing or
/// `new_name` collides with another existing column.
pub fn Schema::rename(
  self : Schema,
  old_name : String,
  new_name : String,
) -> Schema raise DataError {
  if old_name == new_name {
    // No-op rename: still validate that old_name exists (raises if not).
    let _ = self.index_of(old_name)
    return self
  }
  let idx = self.index_of(old_name)
  // A *present* `new_name` is the collision case — a total membership
  // check over the fields, with no raising probe.
  if self.fields.search_by(fn(f) { f.name == new_name }) is Some(_) {
    raise DuplicateColumn(new_name)
  }
  let next = self.fields.copy()
  next[idx] = self.fields[idx].rename(new_name)
  { fields: next }
}

///|
/// `Show` renders `Schema([Field { ... }, ...])` for assertion snapshots.
pub impl Show for Schema with fn output(self, logger) {
  logger.write_string("Schema([")
  logger.write_string(self.fields.map(f => f.to_string()).join(", "))
  logger.write_string("])")
}
