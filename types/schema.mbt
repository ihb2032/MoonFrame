///|
/// Ordered list of `Field`s describing a `DataFrame`'s columns.
///
/// Construction always validates uniqueness of names; once built, a
/// `Schema` is guaranteed to have no duplicate column names.
///
/// The `fields` array is `priv`: build a schema with `Schema::Schema` and read a
/// copy via `fields()` / `field_names()`. External code cannot reach or
/// mutate the backing array, so a validated schema stays valid.
///
/// `index` is the name→position map behind `index_of`, and through it `field` /
/// `select` / `rename`. It is derived from `fields` and built in lock-step with
/// it, never separately: the constructors are the only writers, and each one
/// builds both. Uniqueness is what makes it total — every name maps to exactly
/// the position that carries it — so it is the same validation pass that
/// establishes both. A schema is immutable, so one scan at construction replaces
/// a scan per lookup: resolving `c` names against a `c`-column schema was `O(c²)`
/// while every resolution walked the array, which is the shape a wide `select`
/// or `rename` hits.
pub struct Schema {
  priv fields : Array[Field]
  priv index : Map[String, Int]
} derive(Eq, Debug)

///|
pub extend Schema with Eq::{equal, not_equal}

///|
pub extend Schema with Show::{to_string, output}

///|
pub extend Schema with Debug::{to_repr}

///|
/// Build a schema from a list of fields. `raise DuplicateColumn(name)` on
/// the first repeated name.
///
/// The input array is copied, so mutating `fields` after construction
/// cannot alter the schema or break the validated no-duplicates invariant.
///
/// The type's own constructor, like `Field::Field` — the spelling every
/// canonically-constructed type in MoonFrame uses.
pub fn Schema::Schema(fields : Array[Field]) -> Schema raise DataError {
  { fields: fields.copy(), index: name_index(fields) }
}

///|
/// The name→position map for a field vector, `raise DuplicateColumn(name)` on
/// the first repeated name. The uniqueness check and the lookup map are the same
/// pass on purpose: a map keyed by name *is* the check (a name already present is
/// the duplicate), and building them separately is how the two could disagree.
/// Every `Schema` value in this file is built through here.
fn name_index(fields : Array[Field]) -> Map[String, Int] raise DataError {
  let index : Map[String, Int] = Map([])
  for i, f in fields {
    if index.contains(f.name) {
      raise DuplicateColumn(f.name)
    }
    index[f.name] = i
  }
  index
}

///|
/// Return a snapshot of the schema's fields.
///
/// A fresh array is returned so callers cannot mutate the schema in place
/// and break the "no duplicate names" invariant enforced by `Schema::Schema`.
pub fn Schema::fields(self : Schema) -> Array[Field] {
  self.fields.copy()
}

///|
/// Number of columns in the schema.
pub fn Schema::len(self : Schema) -> Int {
  self.fields.length()
}

///|
/// `true` when the schema has no columns.
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
/// `O(1)` — the name index is built once, when the schema is.
pub fn Schema::index_of(self : Schema, name : String) -> Int raise DataError {
  match self.index.get(name) {
    Some(i) => i
    None => raise ColumnNotFound(name)
  }
}

///|
/// Return the `Field` for `name`, or `raise ColumnNotFound(name)`.
pub fn Schema::field(self : Schema, name : String) -> Field raise DataError {
  self.fields[self.index_of(name)]
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
  // The result's own name index doubles as the duplicate check, so the
  // projection needs no second membership structure — and the checks stay in
  // `names` order, which is what decides *which* error a bad selection reports.
  let index : Map[String, Int] = Map([])
  for n in names {
    if index.contains(n) {
      raise DuplicateColumn(n)
    }
    // `field` raises `ColumnNotFound(n)` for an unknown name; it propagates.
    picked.push(self.field(n))
    index[n] = picked.length() - 1
  }
  { fields: picked, index }
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
  // A *present* `new_name` is the collision case — an `O(1)` membership check
  // against the name index, with no raising probe.
  if self.index.contains(new_name) {
    raise DuplicateColumn(new_name)
  }
  let next = self.fields.copy()
  next[idx] = self.fields[idx].rename(new_name)
  // Rebuilt rather than patched: the names are unique by the check above, so
  // this cannot raise, and one derivation of the index means there is no second
  // place for it to fall out of step with the fields.
  { fields: next, index: name_index(next) }
}

///|
/// `Show` renders `Schema([Field { ... }, ...])` for assertion snapshots.
pub impl Show for Schema with fn output(self, logger) {
  logger.write_string("Schema([")
  logger.write_string(self.fields.map(f => f.to_string()).join(", "))
  logger.write_string("])")
}
