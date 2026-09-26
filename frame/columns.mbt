// The column-set editing verbs: `with_columns` appends derived columns to
// the frame, and `rename` / `rename_with` change column names in place —
// the incremental edits that keep every existing column (`select` /
// `drop`, which replace the column set wholesale, live in their own file).

///|
/// Evaluate each expression against `self` and add the results as
/// columns. Derived columns are *declared* (`col("a") + col("b")`) rather
/// than pre-materialised (a `lit_series(s)` carries a ready-made `Series`).
/// Every `Expr` the evaluator supports is accepted here — aggregations
/// included, evaluating to length-1 and broadcasting back over the frame —
/// under the evaluator's shared dtype / null / NaN rules, which are also
/// where the node set is enumerated.
///
/// Naming and placement:
/// - each result takes its expression's output name — an alias if the tree
///   carries one, else the leftmost column reference, else `"literal"` for a
///   pure-literal tree (`Expr::output_name`). The alias clause is what decides
///   replace-vs-append below: `col("a").with_alias("b")` appends `b`, it does
///   not replace `a`;
/// - an output name already present in `self` **replaces** that column in
///   place (original position kept);
/// - a new output name **appends** rightmost, in expression order;
/// - two expressions producing the same output name raise
///   `DuplicateColumn` at the second — nothing silently wins.
///
/// Every result rides the shared length contract: a frame-tall one
/// becomes the column, a length-1 one (a literal) broadcasts to `nrows` — to
/// zero rows on an empty frame — and any other length raises `LengthMismatch`,
/// which only a `lit_series` or a `map_batches` closure can produce. Errors
/// (unknown columns, dtype mismatches, the unrepresentable `Null` literal, an
/// off-frame length) surface here at evaluation time;
/// building the expressions was total. `with_columns([])` adds nothing and
/// returns the frame itself — a literal identity, declared schema included.
/// A call that adds or replaces a column leaves the schema of every *other*
/// column alone: each keeps the field it arrived with, declared `nullable`
/// included. The column an expression writes takes a carried field when the
/// expression only renames one (a bare `col("x")`, or an aliased one — so a
/// replacement inherits from whichever column now supplies the cells) and a
/// freshly derived one, `nullable = true`, when it computes.
pub fn DataFrame::with_columns(
  self : DataFrame,
  exprs : Array[@expr.Expr],
) -> DataFrame raise @types.DataError {
  // Nothing to evaluate and nothing to add: return `self` rather than
  // rebuilding an equal frame.
  if exprs.is_empty() {
    return self
  }
  let n = self.nrows()
  let scope = Array::makei(n, i => i)
  // `column_series` returns a fresh, owned array, so in-place replacement
  // can't perturb `self`.
  let out = self.column_series()
  // The field vector travels beside the column vector: an untouched column
  // keeps the field it arrived with, and a replaced or added one takes the
  // field its expression carries. `fields` is mutated in step with `out`, so
  // the source lookup reads its own copy.
  let fields = self.schema.fields()
  let source_fields = self.schema.fields()
  let seen : Map[String, Unit] = Map([])
  for expr in exprs {
    let column = @kernel.broadcast_series(eval_expr(expr, self, scope), n)
    let name = expr.output_name()
    if seen.contains(name) {
      raise @types.DataError::DuplicateColumn(name)
    }
    seen[name] = ()
    let field = self.carried_field(source_fields, expr, column, name)
    let renamed = column.rename(name)
    // The schema's index decides overwrite-or-append: a name the frame
    // already carries replaces that column in place, a new name appends.
    match self.schema.index_maybe(name) {
      Some(i) => {
        out[i] = renamed
        fields[i] = field
      }
      None => {
        out.push(renamed)
        fields.push(field)
      }
    }
  }
  DataFrame::from_parts_with_fields(out, fields, n)
}

///|
/// Return a copy of `self` with one or more columns renamed. Renames
/// are applied in input order: each step's `new_name` becomes
/// visible to subsequent renames, which is what makes the three-step
/// swap `[(a, _t), (b, a), (_t, b)]` work.
///
/// Raises:
/// - `ColumnNotFound(old_name)` — `old_name` doesn't exist (or was
///   already renamed away by an earlier step).
/// - `DuplicateColumn(new_name)` — `new_name` collides with another
///   column that still bears that name at this step.
///
/// An empty mapping returns the frame itself — a literal identity. A
/// `(name, name)` mapping is a no-op that still validates the source name's
/// existence.
///
/// Only names change: each field is edited through `Field::rename`, so its
/// dtype and its declared `nullable` flag ride along instead of being
/// re-derived (`DataFrame::DataFrame` would reset the flag to the `Field`
/// constructor default). All structural invariants follow from re-validating
/// the edited field vector through `Schema::Schema`, which catches any residual
/// duplicate.
pub fn DataFrame::rename(
  self : DataFrame,
  mapping : Array[(String, String)],
) -> DataFrame raise @types.DataError {
  if mapping.is_empty() {
    return self
  }
  // Work on a mutable *field* vector aligned with the column vector (INV1 /
  // INV3 in `check_invariants`), so each step sees the result of earlier
  // renames and carries the rest of the field's metadata, plus a
  // `name -> slot` index so each step's lookup and collision check are
  // amortised `O(1)`: a wide frame renamed column-by-column
  // (`|mapping| ≈ ncols`) was `O(ncols^2)` through the linear `search` /
  // `contains`. The index mirrors `fields` exactly — every step retargets
  // `new_name` and retires `old_name` — so the two stay equivalent (frame
  // names are unique, so each name maps to a single slot).
  let fields : Array[@types.Field] = self.schema().fields()
  let index : Map[String, Int] = Map([])
  for i in 0..<fields.length() {
    index[fields[i].name()] = i
  }
  for pair in mapping {
    let (old_name, new_name) = pair
    // Locate old_name in the current name set.
    let idx = match index.get(old_name) {
      Some(i) => i
      None => raise @types.DataError::ColumnNotFound(old_name)
    }
    // Reject a collision with any *other* current name. `fields[idx]` is still
    // named `old_name` here (≠ `new_name` in this branch), so any occurrence of
    // `new_name` must sit at a different slot — a plain membership test is
    // therefore equivalent to "exists at some i ≠ idx".
    if old_name != new_name && index.get(new_name) is Some(_) {
      raise @types.DataError::DuplicateColumn(new_name)
    }
    fields[idx] = fields[idx].rename(new_name)
    index.remove(old_name)
    index[new_name] = idx
  }
  // Rebuild under the final names. The original column ordering, identity, and
  // per-field metadata are preserved; only each `name` is refreshed.
  self.with_renamed_fields(fields)
}

///|
/// Return a copy of `self` with **every** column renamed through `f`: each
/// column's new name is `f(old_name)`. The callable form of `rename` — Polars'
/// `df.rename(function)` — for a uniform transform (a prefix, a case fold) over
/// the whole schema rather than an explicit `old -> new` list.
///
/// `f` is total, so the only failure is a collision: if `f` maps two distinct
/// columns to the same name, the re-validating `Schema::Schema` raises
/// `DuplicateColumn`. (There is no `ColumnNotFound` — every existing column is
/// renamed, none is looked up by name.)
///
/// The identity `f = name => name` is a no-op. Column order, dtypes, the row
/// count, and each field's declared `nullable` flag are unchanged; only the
/// names are refreshed, through the same `Field::rename` edit `rename` applies.
pub fn DataFrame::rename_with(
  self : DataFrame,
  f : (String) -> String,
) -> DataFrame raise @types.DataError {
  self.with_renamed_fields(
    self.schema().fields().map(field => field.rename(f(field.name()))),
  )
}
