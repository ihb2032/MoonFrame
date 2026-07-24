///|
/// Formal structural specification of `DataFrame`. `check_invariants`
/// returns `Ok(())` exactly when every invariant the `DataFrame`
/// docstring promises holds; otherwise it returns `Err(msg)` naming
/// the first violation it finds.
///
/// This file is the **source of truth** for what "a well-formed
/// `DataFrame`" means in MoonFrame v0.1. Constructors and ops are
/// correct *iff* every output passes `check_invariants()`. Every
/// `*_test.mbt` that builds or transforms a frame calls this helper as
/// a final assertion — the closest practical analog to formal
/// verification in MoonBit (real `moon prove` is overkill for v0.1).
///
/// The invariants checked here, in order:
///
///   INV1  columns.length() == schema.fields().length()
///   INV2  every column has length == nrows
///   INV3  schema.field_names()[i] == columns[i].name()
///   INV4  schema.fields()[i].dtype() == columns[i].dtype()
///   INV5  name_to_index.length() == columns.length()
///   INV6  for every (name, i) in name_to_index:
///           0 ≤ i < ncols AND columns[i].name() == name
///   INV7  nrows >= 0  (the height is a count; INV2 pins it to the columns
///           but ranges only over the columns that exist, so for a
///           column-less `N×0` frame this is the whole constraint)
///
/// Soundness lemma — INV5 ∧ INV6 imply the cache is a *bijection*
/// onto column indices, hence:
///   * column names are unique;
///   * every column is reachable by name through the cache.
/// Proof sketch: each cache entry pins a distinct index (two entries
/// with the same `i` would force their key names equal via INV6 and
/// collapse into one cache slot). With `ncols` entries each pinning a
/// unique slot in `[0, ncols)`, the relation is a bijection.
/// Consequently we do not separately check "every column has a cache
/// entry" — it's a corollary, and the test budget is better spent on
/// the irredundant checks above.
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

  // ── INV5: name_to_index covers exactly the columns ─────────────────
  if self.name_to_index.length() != ncols {
    return Err(
      "INV5 violated: name_to_index has \{self.name_to_index.length()} entries but columns has \{ncols}",
    )
  }

  // ── INV6: every cache entry points at the matching column ─────────
  for name, i in self.name_to_index {
    if i < 0 || i >= ncols {
      return Err(
        "INV6 violated: name_to_index[\"\{name}\"] = \{i} is out of range [0, \{ncols})",
      )
    }
    let col_name = self.columns[i].name()
    if col_name != name {
      return Err(
        "INV6 violated: name_to_index[\"\{name}\"] points at columns[\{i}] whose name is \"\{col_name}\"",
      )
    }
  }

  // ── INV7: the row count is a count ─────────────────────────────────
  // A column-less frame is *not* pinned to `0×0`: projecting a frame to zero
  // columns keeps its height, so `N×0` is a legal shape and `nrows` carries
  // that height alone (INV2 above only ranges over the columns that exist,
  // and is vacuous when there are none). What remains true of every frame is
  // that the height is non-negative — for a frame with columns INV2 already
  // forces it, since no `Series` is shorter than empty.
  if self.nrows < 0 {
    return Err("INV7 violated: frame has a negative nrows \{self.nrows}")
  }
  Ok(())
}
