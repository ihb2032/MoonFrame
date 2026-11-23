// The nested column bodies: the two layouts `ColumnData::List` and
// `ColumnData::Struct` carry, in Arrow's own shape. A list column is a
// run of offsets over one flattened child column — cell `i` owns the
// child's rows `[offsets[i], offsets[i + 1])` — and a struct column is
// one child column per field, every child as long as the parent. In both
// the parent's validity bitmap says which *cells* are null and each
// child's own validity says which *elements* are null, so a null list
// and a list of nulls are different columns, as they should be.
//
// The bodies are opaque outside this package: a reader reaches the
// offsets and the children through the accessors, which answer views and
// values — never the backing array — so a nested column is as immutable
// as every other column, and the flattened child a reader holds cannot
// be written through. The sub-view helpers (`slice_view` / `take_view`)
// are the two row verbs' bodies: a slice re-bases the offsets it keeps,
// a gather re-lays the child the gathered cells need and rebuilds the
// offsets over it.

///|
/// A variable-length list column's body: the offsets and the flattened
/// child. `offsets` holds `len + 1` entries, the first `0` and the last
/// the child's length, each no smaller than the one before it.
#derive(Debug)
pub struct ListArray {
  priv offsets : ArrayView[Int32]
  priv child : ColumnStorage
}

///|
/// A struct column's body: one child column per field, in the struct
/// dtype's field order, every child as long as the parent.
#derive(Debug)
pub struct StructArray {
  priv children : Array[ColumnStorage]
}

// ── Construction ──────────────────────────────────────────────────────

///|
/// Assemble a list body from its offsets and its flattened child. The
/// offsets must start at `0`, never decrease, and end at the child's
/// length — the three facts a cell's `[offsets[i], offsets[i + 1])` read
/// relies on — and a violation raises `InvalidOperation` naming `name`,
/// the column the body belongs to, and the first index that broke the
/// rule. The offsets array is copied, so the body owns it; the child is
/// held as given (a column is immutable by construction).
fn ListArray::from_parts(
  offsets : Array[Int32],
  child : ColumnStorage,
  name~ : String,
) -> ListArray raise @types.DataError {
  let n = offsets.length()
  if n == 0 {
    raise @types.DataError::InvalidOperation(
      "column \"\{name}\": the offsets carry no entry, where a list needs one more than its cells",
    )
  }
  if offsets[0] != 0 {
    raise @types.DataError::InvalidOperation(
      "column \"\{name}\": the offsets start at \{offsets[0]} rather than 0",
    )
  }
  for i in 1..<n {
    if offsets[i] < offsets[i - 1] {
      raise @types.DataError::InvalidOperation(
        "column \"\{name}\": the offsets decrease at \{i} (\{offsets[i]} after \{offsets[i - 1]})",
      )
    }
  }
  let total = child.len()
  if offsets[n - 1] != total {
    raise @types.DataError::InvalidOperation(
      "column \"\{name}\": the offsets end at \{offsets[n - 1]} but the child holds \{total} elements",
    )
  }
  { offsets: offsets.copy(), child, }
}

///|
/// Assemble a struct body from its children, one per field. Every child
/// must be as long as the first; a disagreement raises
/// `LengthMismatch(first, other)`. The array is copied, so the body owns
/// its list.
fn StructArray::from_parts(
  children : Array[ColumnStorage],
) -> StructArray raise @types.DataError {
  match children.get(0) {
    None => ()
    Some(first) => {
      let len = first.len()
      for i in 1..<children.length() {
        if children[i].len() != len {
          raise @types.DataError::LengthMismatch(len, children[i].len())
        }
      }
    }
  }
  { children: children.copy(), }
}

// ── Inspection ────────────────────────────────────────────────────────

///|
/// How many cells (lists) the body holds.
fn ListArray::len(self : ListArray) -> Int32 {
  self.offsets.length() - 1
}

///|
/// Where cell `index`'s elements begin in the child. `index` in
/// `[0, len]` is in range (`len` names the end of the last cell); any
/// other index reads as the nearest bound rather than raising, so a
/// reader walking a window never aborts on a stray index.
fn ListArray::offset(self : ListArray, index : Int32) -> Int32 {
  if index <= 0 {
    0
  } else if index >= self.offsets.length() {
    self.offsets[self.offsets.length() - 1]
  } else {
    self.offsets[index]
  }
}

///|
/// The flattened child column — every cell's elements in order. A value,
/// so a reader holding it holds a column and not a window onto this one's
/// storage.
fn ListArray::child(self : ListArray) -> ColumnStorage {
  self.child
}

///|
/// How many cells (structs) the body holds — the first child's length,
/// or `0` for a struct with no fields.
fn StructArray::len(self : StructArray) -> Int32 {
  match self.children.get(0) {
    Some(first) => first.len()
    None => 0
  }
}

///|
/// The children in field order — a read-only view, one child per field.
/// The walk a cell read takes: every child contributes one value to the
/// cell, so the walk never has to ask whether a position has a child.
fn StructArray::children(self : StructArray) -> ArrayView[ColumnStorage] {
  self.children
}

// ── Sub-views (the row verbs' bodies) ─────────────────────────────────

///|
/// The `[start, start + n)` window of the body: the kept cells' offsets
/// re-based to start at `0`, over the child's own `[offsets[start],
/// offsets[start + n])` window — so a slice holds only the elements its
/// cells own, and the child a reader sees is no longer than it needs to
/// be. The caller guarantees `0 <= start <= start + n <= len` (the
/// column's slice clamps first).
fn ListArray::slice_view(
  self : ListArray,
  start : Int32,
  n : Int32,
) -> ListArray {
  let base = self.offset(start)
  let offsets : Array[Int32] = Array::makei(n + 1, i => {
    self.offset(start + i) - base
  })
  let end = self.offset(start + n)
  { offsets, child: self.child.slice_total(base, end), }
}

///|
/// The gather of the body: the gathered cells' elements laid
/// consecutively in a new child, the offsets rebuilt over it. A gather
/// of a nested column re-lays the child rather than indexing it, because
/// the offsets are positions in *this* child — an index into the old
/// one would spell another cell's elements. The caller has validated
/// every index against the parent's length.
fn ListArray::take_view(
  self : ListArray,
  indices : ArrayView[Int32],
) -> ListArray raise @types.DataError {
  // The gathered cells' element positions, in order.
  let picks : Array[Int32] = []
  let offsets : Array[Int32] = [0]
  for i in indices {
    let lo = self.offset(i)
    let hi = self.offset(i + 1)
    for j in lo..<hi {
      picks.push(j)
    }
    offsets.push(picks.length())
  }
  { offsets, child: self.child.take(picks), }
}

///|
/// The `[start, start + n)` window of the body: every child sliced the
/// same way.
fn StructArray::slice_view(
  self : StructArray,
  start : Int32,
  n : Int32,
) -> StructArray {
  { children: self.children.map(child => child.slice_total(start, start + n)), }
}

///|
/// The gather of the body: every child gathered by the same indices.
fn StructArray::take_view(
  self : StructArray,
  indices : ArrayView[Int32],
) -> StructArray raise @types.DataError {
  { children: self.children.map(child => child.take(indices)), }
}
