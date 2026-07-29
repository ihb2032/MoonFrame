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
