// The equalities this package's own tests assert with, defined where those
// tests live. Comparing two columns, two buffers, or two dtype tags is a
// convenience for an assertion — no production code in this package or above
// it compares any of these types — and a convenience for a test is not a
// reason to publish a symbol. A whitebox file compiles inside the package, so
// these `impl`s satisfy `assert_eq` in every `_wbtest.mbt` here while staying
// out of the generated interface, which is what the internal-surface audit
// reads.
//
// `ColumnStorage`'s equality is the opposite case and stays in production: it
// is content-based, it drives `Series` and `DataFrame` equality, and callers
// depend on it.
//
// Each match is wildcard-free on the same-variant pairs, so a dtype added to
// `ColumnData` fails to compile here until it says what equal means — the
// property the `derive` used to give.
//
// `Bitmap` is here for the same reason and one more: MoonBit promotes a trait
// impl's methods to regular methods, so a `pub impl Eq` cannot help publishing
// `equal` / `not_equal` beside it. Keeping the impl in this file is therefore the
// only way a bitmap comparison stays a test's tool rather than three symbols in
// the interface.

///|
/// Logical equality: two bitmaps are equal iff they have the same length and the
/// same validity bit at every logical slot. The comparison walks the
/// `[offset, offset + len)` windows rather than the raw buffers, so a zero-copy
/// `slice` view equals a freshly packed bitmap with the same bits — where a
/// structural comparison would read `offset` and the shared buffer and call them
/// unequal. That is exactly what makes it a *test's* relation: production never
/// asks whether two validity buffers match (`ColumnStorage::equal` compares
/// cells, one slot at a time), while a test that builds the same window two ways
/// does.
impl Eq for Bitmap with fn equal(self, other) {
  if self.len != other.len {
    false
  } else {
    let mut equal = true
    for i in 0..<self.len {
      if bit_at(self.bits, self.offset + i) !=
        bit_at(other.bits, other.offset + i) {
        equal = false
        break
      }
    }
    equal
  }
}

///|
impl Eq for ColumnData with fn equal(self, other) {
  match (self, other) {
    (Int(a), Int(b)) => a == b
    (Float(a), Float(b)) => a == b
    (Bool(a), Bool(b)) => a == b
    (String(a), String(b)) => a == b
    // A different dtype is a different column, whatever the cells hold.
    (Int(_), _) | (Float(_), _) | (Bool(_), _) | (String(_), _) => false
  }
}

///|
impl Eq for NumericData with fn equal(self, other) {
  match (self, other) {
    (Int(a), Int(b)) => a == b
    (Float(a), Float(b)) => a == b
    (Int(_), _) | (Float(_), _) => false
  }
}

///|
impl Eq for BuiltinColumn with fn equal(self, other) {
  self.data == other.data && self.validity == other.validity
}

///|
impl Eq for NumericColumn with fn equal(self, other) {
  self.data == other.data
}
