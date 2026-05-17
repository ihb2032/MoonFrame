///|
/// Ordered list of `Field`s describing a `DataFrame`'s columns.
///
/// Construction always validates uniqueness of names; once built, a
/// `Schema` is guaranteed to have no duplicate column names.
pub(all) struct Schema {
  fields : Array[Field]
} derive(Eq, Debug)

///|
/// Build a schema from a list of fields. Returns `Err(DuplicateColumn(name))`
/// on the first repeated name.
pub fn Schema::new(fields : Array[Field]) -> Result[Schema, DataError] {
  let seen : Map[String, Unit] = {}
  for f in fields {
    if seen.contains(f.name) {
      return Err(DuplicateColumn(f.name))
    }
    seen[f.name] = ()
  }
  Ok({ fields, })
}

///|
pub fn Schema::fields(self : Schema) -> Array[Field] {
  self.fields
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
/// `Ok(index)` of the column named `name`, or `Err(ColumnNotFound(name))`.
pub fn Schema::index_of(self : Schema, name : String) -> Result[Int, DataError] {
  for i, f in self.fields {
    if f.name == name {
      return Ok(i)
    }
  }
  Err(ColumnNotFound(name))
}

///|
/// Return the `Field` for `name`, or `Err(ColumnNotFound(name))`.
pub fn Schema::field(self : Schema, name : String) -> Result[Field, DataError] {
  for f in self.fields {
    if f.name == name {
      return Ok(f)
    }
  }
  Err(ColumnNotFound(name))
}

///|
/// Return the `Field` at position `i`, or `Err(IndexOutOfBounds(i))`.
pub fn Schema::field_at(self : Schema, i : Int) -> Result[Field, DataError] {
  if i < 0 || i >= self.fields.length() {
    return Err(IndexOutOfBounds(i))
  }
  Ok(self.fields[i])
}

///|
/// Project a sub-schema by name, preserving the order of `names`. Missing
/// names yield `Err(ColumnNotFound(name))`; duplicates inside `names`
/// yield `Err(DuplicateColumn(name))`.
pub fn Schema::select(
  self : Schema,
  names : Array[String],
) -> Result[Schema, DataError] {
  let picked : Array[Field] = []
  let seen : Map[String, Unit] = {}
  for n in names {
    if seen.contains(n) {
      return Err(DuplicateColumn(n))
    }
    seen[n] = ()
    match self.field(n) {
      Ok(f) => picked.push(f)
      Err(e) => return Err(e)
    }
  }
  Ok({ fields: picked })
}

///|
/// Rename `old_name` to `new_name`. Errors if `old_name` is missing or
/// `new_name` collides with another existing column.
pub fn Schema::rename(
  self : Schema,
  old_name : String,
  new_name : String,
) -> Result[Schema, DataError] {
  if old_name == new_name {
    // No-op rename: still validate that old_name exists.
    return match self.index_of(old_name) {
      Ok(_) => Ok(self)
      Err(e) => Err(e)
    }
  }
  let idx = match self.index_of(old_name) {
    Ok(i) => i
    Err(e) => return Err(e)
  }
  match self.index_of(new_name) {
    Ok(_) => return Err(DuplicateColumn(new_name))
    Err(_) => ()
  }
  let next : Array[Field] = self.fields.map(fn(f) { f })
  next[idx] = self.fields[idx].rename(new_name)
  Ok({ fields: next })
}

///|
/// `Show` renders `Schema([Field { ... }, ...])` for assertion snapshots.
pub impl Show for Schema with output(self, logger) {
  logger.write_string("Schema([")
  for i, f in self.fields {
    if i > 0 {
      logger.write_string(", ")
    }
    f.output(logger)
  }
  logger.write_string("])")
}
