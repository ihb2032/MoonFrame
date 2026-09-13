///|
/// Formal structural specification of `DataFrame`. `check_invariants`
/// returns `Ok(())` exactly when every invariant the `DataFrame`
/// docstring promises holds; otherwise it returns `Err(msg)` naming
/// the first violation it finds.
///
/// This file is the **source of truth** for what "a well-formed
/// `DataFrame`" means — the current structural contract, not a snapshot of
/// any one release. Constructors and ops are
/// correct *iff* every output passes `check_invariants()`. Each operator's own
/// suite asserts it on representative outputs — the closest practical analog to
/// formal verification in MoonBit, at a fraction of the cost of carrying
/// `moon prove` contracts through the whole frame layer. It is a discipline
/// applied where an operator's *shape* is what is under test, not a rule every
/// test file follows: a suite about rendering or membership has nothing to gain
/// from re-asserting the frame it built, and many do not.
///
/// The invariants checked here, in order:
///
///   INV1  columns.length() == schema.fields().length()
///   INV2  every column has length == nrows
///   INV3  schema.field_names()[i] == columns[i].name()
///   INV4  schema.fields()[i].dtype() == columns[i].dtype()
///   INV5  nrows >= 0  (the height is a count; INV2 pins it to the columns
///           but ranges only over the columns that exist, so for a
///           column-less `N×0` frame this is the whole constraint)
///
/// Uniqueness of the column names is not re-checked here because it has one
/// home: the `Schema` constructor, which rejects a duplicate name as it
/// builds the name→position index. INV3 pins the column vector to that
/// schema field-for-field, so a frame whose columns disagree on a name
/// cannot pass INV3 against a schema the constructor has already made
/// unique. (A former INV5/INV6 pair watched a second, frame-local
/// name→index cache agree with the columns; the cache is gone — the
/// schema's index is the only one — and with it the two checks and their
/// soundness lemma.)
///
/// Not public API. It exists for the in-module test assertions and the fuzz /
/// property suites, which reach it across package boundaries — `frame`'s own
/// blackbox tests, and `io` / `lazy` / the examples asserting on frames they
/// built. The `INV1..INV5` numbering and the `String` diagnostics are
/// test-facing detail, not a stable surface, and a future *user-facing*
/// validator would be a separate `raise DataError` method.
///
/// Both attributes, therefore. `#doc(hidden)` keeps it out of the generated
/// interface and this reference; `#internal(engine, …)` is what actually stops
/// a downstream caller depending on it, since hiding a symbol from the `.mbti`
/// does not stop anyone calling it. The alert is silent for every package
/// under this module's `ihb2032/MoonFrame/` prefix — including the blackbox
/// test packages named above — and the one in-module caller it does not exempt
/// is the root package, whose name *is* the module name; the root `moon.pkg`
/// allows the alert there for that reason.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn DataFrame::check_invariants(self : DataFrame) -> Result[Unit, String] {
  let ncols = self.columns.length()
  let schema_fields = self.schema.fields()

  // ── INV1: schema-columns arity matches ─────────────────────────────
  if schema_fields.length() != ncols {
    return Err(
      "INV1 violated: schema has \{schema_fields.length()} fields but columns has \{ncols}",
    )
  }

  // ── INV2: every column has length == nrows ─────────────────────────
  for i in 0..<ncols {
    let len = self.columns[i].len()
    if len != self.nrows {
      return Err(
        "INV2 violated: column \{i} (\"\{self.columns[i].name()}\") has length \{len} but nrows is \{self.nrows}",
      )
    }
  }

  // ── INV3 + INV4: schema mirrors columns, name and dtype ────────────
  for i in 0..<ncols {
    let field_name = schema_fields[i].name()
    let col_name = self.columns[i].name()
    if field_name != col_name {
      return Err(
        "INV3 violated: schema field \{i} is named \"\{field_name}\" but columns[\{i}] is named \"\{col_name}\"",
      )
    }
    let field_dt = schema_fields[i].dtype()
    let col_dt = self.columns[i].dtype()
    if field_dt != col_dt {
      return Err(
        "INV4 violated: schema field \"\{field_name}\" has dtype \{field_dt} but its column has dtype \{col_dt}",
      )
    }
  }

  // ── INV5: the row count is a count ─────────────────────────────────
  // A column-less frame is *not* pinned to `0×0`: projecting a frame to zero
  // columns keeps its height, so `N×0` is a legal shape and `nrows` carries
  // that height alone (INV2 above only ranges over the columns that exist,
  // and is vacuous when there are none). What remains true of every frame is
  // that the height is non-negative — for a frame with columns INV2 already
  // forces it, since no `Series` is shorter than empty.
  if self.nrows < 0 {
    return Err("INV5 violated: frame has a negative nrows \{self.nrows}")
  }
  Ok(())
}
