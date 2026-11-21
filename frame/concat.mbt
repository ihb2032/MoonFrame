// Vertical concatenation: the rows of `other` appended
// under `self`'s, one frame on top of the other. The two frames must agree
// column-for-column **by position** — same column count, same name in each
// slot, same dtype in each slot. Silently stacking one column's values
// under another column's name is the bug the name check exists to prevent,
// so reordering `other`'s columns — or renaming them — is the caller's job
// before `vstack`. The dtype check is exact, not
// unifying: an `Int` column does not stack under a `Float` one; cast first
// when the sources differ. Row counts are unconstrained — stacking onto a
// 0-row frame is the schema-preserving way to "concat" — and the rebuilt
// columns re-converge onto the `Numeric` fast path exactly as any row
// gather's do, since the backend follows the assembled content.

///|
/// The stacking kernel the public two-frame verb and the engine's batch
/// assembly ride: `frames` stacked column-for-column by position — every
/// frame must agree with the first on column count, name, and dtype per
/// slot — one series built per column over all the frames' concatenated
/// cells, so each row is copied once no matter how many frames stack.
/// `verb` names the operation in the refusal messages (the two-frame
/// spelling passes `"vstack"`, the engine's batch assembly its own).
/// The stacked height is the plain sum; a sum past 2^31 would wrap, but
/// every column below materialises that many cells first and allocation
/// fails long before the count wraps — so there is deliberately no guard
/// here, only the comment (a guard would be an untestable dead arm).
fn stack_frames(
  verb : String,
  frames : Array[DataFrame],
) -> DataFrame raise @types.DataError {
  // An empty stack has nothing to disagree about — the 0×0 frame is the
  // total answer (a cursor that yields no batches assembles to it).
  match frames.get(0) {
    None => return DataFrame::from_parts([], 0)
    Some(seed) => {
      let first = seed
      let ncols = first.ncols()
      let mut height = 0L
      for frame in frames {
        if frame.ncols() != ncols {
          raise @types.DataError::TypeMismatch(
            @types.TypeMismatchDetail::Message(
              "\{verb} needs equal column counts: \{ncols} vs \{frame.ncols()}",
            ),
          )
        }
        height = height + frame.nrows().to_int64()
      }
      let cols : Array[Series] = []
      for i in 0..<ncols {
        let top = first.get_column_at(i)
        let name = top.name()
        let dtype = top.dtype()
        // The concatenated cells project through the shared series builder, so
        // the output keeps the declared dtype and takes the gather-style backend
        // canonicalisation — an all-valid numeric stack lands on `Numeric`.
        let cells : Array[@types.Scalar] = []
        for frame in frames {
          let column = frame.get_column_at(i)
          if column.name() != name {
            raise @types.DataError::TypeMismatch(
              @types.TypeMismatchDetail::Message(
                "\{verb} column \{i} is \{name} but the stacked column is \{column.name()}",
              ),
            )
          }
          if column.dtype() != dtype {
            raise @types.DataError::TypeMismatch(
              @types.TypeMismatchDetail::Message(
                "\{verb} column \{i} (\{name}) is \{dtype} but the stacked column is \{column.dtype()}",
              ),
            )
          }
          for c in column.to_scalars() {
            cells.push(c)
          }
        }
        cols.push(scalars_to_series(dtype, name, cells))
      }
      DataFrame::from_parts(cols, height.to_int())
    }
  }
}

///|
/// The rows of `other` appended under `self`'s, as one frame.
/// Raises `TypeMismatch` when the column counts
/// differ, when any same-position pair of columns carries different names,
/// or when any same-position pair carries different dtypes; the message
/// names the count or the first offending column.
pub fn DataFrame::vstack(
  self : DataFrame,
  other : DataFrame,
) -> DataFrame raise @types.DataError {
  stack_frames("vstack", [self, other])
}
