// The filter predicates: a typed mirror of the schema's transform array, transcribed
// from the vendored vega_lite_v6_5_0.schema.json and schema-walked
// through the corpus guard. Reached through `@chart` qualification —
// part of the deep mirror family the facade deliberately does not
// re-export. The Vega expression language stays a `String` throughout:
// the mirror passes an expression through, it does not parse one.

///|
/// A filter predicate, the schema's `PredicateComposition`: a Vega
/// expression string (`Expr` — passed through verbatim), a parameter
/// reference (`Param` — a brush or input widget, by name), a field
/// comparison (`Equal` / `Range` / `OneOf` / `Valid`, each with an
/// optional `timeUnit` truncation), or a composition of predicates
/// (`Not` / `And` / `Or`). `pub(all)` so callers build the variants;
/// the array-carrying ones take copies at the builder functions.
#derive(Eq, Debug)
pub(all) enum VegaPredicate {
  Expr(String)
  Param(String)
  Equal(String, Json, VegaTimeUnit?)
  Lt(String, Double, VegaTimeUnit?)
  Lte(String, Double, VegaTimeUnit?)
  Gt(String, Double, VegaTimeUnit?)
  Gte(String, Double, VegaTimeUnit?)
  Range(String, (Double, Double), VegaTimeUnit?)
  OneOf(String, Array[Json], VegaTimeUnit?)
  Valid(String, Bool, VegaTimeUnit?)
  Not(VegaPredicate)
  And(Array[VegaPredicate])
  Or(Array[VegaPredicate])
}

///|
pub extend VegaPredicate with Eq::{equal, not_equal}

///|
pub extend VegaPredicate with Debug::{to_repr}

///|
/// The `oneOf` predicate from a caller's value list: the spec keeps its
/// own copy, so an array the caller mutates afterwards cannot move a
/// chart already built.
pub fn VegaPredicate::one_of(
  field : String,
  values : Array[Json],
  time_unit? : VegaTimeUnit,
) -> VegaPredicate {
  OneOf(field, values.copy(), time_unit)
}

///|
/// The `and` composition from a caller's predicate list, copied.
pub fn VegaPredicate::all_of(
  predicates : Array[VegaPredicate],
) -> VegaPredicate {
  And(predicates.copy())
}

///|
/// The `or` composition from a caller's predicate list, copied.
pub fn VegaPredicate::any_of(
  predicates : Array[VegaPredicate],
) -> VegaPredicate {
  Or(predicates.copy())
}

///|
/// The JSON of a predicate: the expression / parameter reference as an
/// object, the field comparisons with their optional `timeUnit`, and
/// the compositions as their arrays.
fn vega_predicate_emit_json(p : VegaPredicate) -> Json {
  let obj : Map[String, Json] = Map([])
  match p {
    Expr(expr) => Json::string(expr)
    Param(name) => {
      obj["param"] = Json::string(name)
      Json::object(obj)
    }
    Equal(field, value, time_unit) => {
      obj["field"] = Json::string(field)
      obj["equal"] = value
      put_predicate_time_unit(obj, time_unit)
      Json::object(obj)
    }
    Lt(field, bound, time_unit) => {
      obj["field"] = Json::string(field)
      obj["lt"] = Json::number(bound)
      put_predicate_time_unit(obj, time_unit)
      Json::object(obj)
    }
    Lte(field, bound, time_unit) => {
      obj["field"] = Json::string(field)
      obj["lte"] = Json::number(bound)
      put_predicate_time_unit(obj, time_unit)
      Json::object(obj)
    }
    Gt(field, bound, time_unit) => {
      obj["field"] = Json::string(field)
      obj["gt"] = Json::number(bound)
      put_predicate_time_unit(obj, time_unit)
      Json::object(obj)
    }
    Gte(field, bound, time_unit) => {
      obj["field"] = Json::string(field)
      obj["gte"] = Json::number(bound)
      put_predicate_time_unit(obj, time_unit)
      Json::object(obj)
    }
    Range(field, bounds, time_unit) => {
      let (lo, hi) = bounds
      obj["field"] = Json::string(field)
      obj["range"] = Json::array([Json::number(lo), Json::number(hi)])
      put_predicate_time_unit(obj, time_unit)
      Json::object(obj)
    }
    OneOf(field, values, time_unit) => {
      obj["field"] = Json::string(field)
      obj["oneOf"] = Json::array(values.copy())
      put_predicate_time_unit(obj, time_unit)
      Json::object(obj)
    }
    Valid(field, valid, time_unit) => {
      obj["field"] = Json::string(field)
      obj["valid"] = Json::boolean(valid)
      put_predicate_time_unit(obj, time_unit)
      Json::object(obj)
    }
    Not(inner) => {
      obj["not"] = vega_predicate_emit_json(inner)
      Json::object(obj)
    }
    And(parts) => {
      obj["and"] = Json::array(parts.map(fn(q) { vega_predicate_emit_json(q) }))
      Json::object(obj)
    }
    Or(parts) => {
      obj["or"] = Json::array(parts.map(fn(q) { vega_predicate_emit_json(q) }))
      Json::object(obj)
    }
  }
}

///|
/// A predicate's optional `timeUnit` truncation, present only when set.
fn put_predicate_time_unit(
  obj : Map[String, Json],
  time_unit : VegaTimeUnit?,
) -> Unit {
  if time_unit is Some(unit) {
    obj["timeUnit"] = Json::string(time_unit_string(unit))
  }
}

///|
/// An output-name pair: one field, or the start / end pair a binned or
/// windowed transform writes.
#derive(Eq, Debug)
pub(all) enum VegaAsField {
  One(String)
  Pair(String, String)
}

///|
pub extend VegaAsField with Eq::{equal, not_equal}

///|
pub extend VegaAsField with Debug::{to_repr}

///|
/// The JSON of an output-name pair: a bare string, or the two-element
/// array.
fn vega_as_field_emit_json(v : VegaAsField) -> Json {
  match v {
    One(name) => Json::string(name)
    Pair(lo, hi) => Json::array([Json::string(lo), Json::string(hi)])
  }
}

///|
/// One bound of a window frame: a row offset from the current row, or
/// `Open` (the schema's `null` — the frame runs to the data's edge).
#derive(Eq, Debug)
pub(all) enum VegaFrameLimit {
  Num(Double)
  Open
}

///|
pub extend VegaFrameLimit with Eq::{equal, not_equal}

///|
pub extend VegaFrameLimit with Debug::{to_repr}

///|
/// The JSON of a window frame pair, each bound a number or null.
fn vega_frame_pair_emit_json(v : (VegaFrameLimit, VegaFrameLimit)) -> Json {
  let (lo, hi) = v
  let bound = fn(b : VegaFrameLimit) -> Json {
    match b {
      Num(n) => Json::number(n)
      Open => Json::null()
    }
  }
  Json::array([bound(lo), bound(hi)])
}
