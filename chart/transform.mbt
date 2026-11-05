// The transforms: a typed mirror of the schema's transform array, transcribed
// from the vendored vega_lite_v6_5_0.schema.json and schema-walked
// through the corpus guard. Reached through `@chart` qualification —
// part of the deep mirror family the facade deliberately does not
// re-export. The Vega expression language stays a `String` throughout:
// the mirror passes an expression through, it does not parse one. Field
// references (the transform's input fields, its group-by and sort keys)
// escape through `escape_vega_field` the way encoding channels do;
// output names (`as`) and the expression inside a `calculate` do not —
// an output name is whatever the caller wants the new field called,
// and an expression's field spellings are the caller's to write.

///|
/// One aggregated output: the operation, the input field it runs over (absent for `Count`), and the output name.
#derive(Eq, Debug)
pub struct VegaAggField {
  op : VegaAggregate
  field : String?
  as_ : String
}

///|
pub extend VegaAggField with Eq::{equal, not_equal}

///|
pub extend VegaAggField with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaAggField::VegaAggField(
  op~ : VegaAggregate,
  as_~ : String,
  field? : String,
) -> VegaAggField {
  { op, field, as_, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_agg_field_emit_json(x : VegaAggField) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.op
    obj["op"] = Json::string(aggregate_string(v))
  }
  if x.field is Some(v) {
    obj["field"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.as_
    obj["as"] = Json::string(v)
  }
  Json::object(obj)
}

///|
/// A window-only operation, the schema's `WindowOnlyOp` — the ranking
/// and offset functions that exist inside a window transform and
/// nowhere else (`row_number`, `rank`, `lag`, …), one variant per
/// value. Several take no input field, and `lag` / `lead` / `nth_value`
/// take the schema's `param` offset (a `VegaWindowField`'s `param`).
/// `pub(all)` so callers can name the variants.
#derive(Eq, Debug)
pub(all) enum VegaWindowOnlyOp {
  RowNumber
  Rank
  DenseRank
  PercentRank
  CumeDist
  Ntile
  Lag
  Lead
  FirstValue
  LastValue
  NthValue
}

///|
pub extend VegaWindowOnlyOp with Eq::{equal, not_equal}

///|
pub extend VegaWindowOnlyOp with Debug::{to_repr}

///|
/// The schema's `WindowOnlyOp` string for a variant, one arm per
/// variant — generated from the vendored schema's own enum list.
fn window_only_op_string(op : VegaWindowOnlyOp) -> String {
  match op {
    RowNumber => "row_number"
    Rank => "rank"
    DenseRank => "dense_rank"
    PercentRank => "percent_rank"
    CumeDist => "cume_dist"
    Ntile => "ntile"
    Lag => "lag"
    Lead => "lead"
    FirstValue => "first_value"
    LastValue => "last_value"
    NthValue => "nth_value"
  }
}

///|
/// A windowed output's operation: an aggregate that runs over the
/// window frame (`sum`, `mean`, …), or one of the window-only
/// functions. The schema's `WindowFieldDef.op` is exactly this union —
/// spelling it as one keeps a window-only verb reachable, which a bare
/// `VegaAggregate` silently was not. `pub(all)` so callers can build
/// the variants.
#derive(Eq, Debug)
pub(all) enum VegaWindowFieldOp {
  Aggregate(VegaAggregate)
  WindowOnly(VegaWindowOnlyOp)
}

///|
pub extend VegaWindowFieldOp with Eq::{equal, not_equal}

///|
pub extend VegaWindowFieldOp with Debug::{to_repr}

///|
/// One windowed output: the operation, the input field (absent for the
/// field-less window functions — `rank`, `row_number`, and kin), the
/// output name, and the window functions' numeric parameter (the `lag`
/// / `lead` offset, the `nth_value` index, the `ntile` count).
#derive(Eq, Debug)
pub struct VegaWindowField {
  op : VegaWindowFieldOp
  field : String?
  as_ : String
  param : Double?
}

///|
pub extend VegaWindowField with Eq::{equal, not_equal}

///|
pub extend VegaWindowField with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaWindowField::VegaWindowField(
  op~ : VegaWindowFieldOp,
  as_~ : String,
  field? : String,
  param? : Double,
) -> VegaWindowField {
  { op, field, as_, param, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_window_field_emit_json(x : VegaWindowField) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.op
    obj["op"] = Json::string(
      match v {
        Aggregate(op) => aggregate_string(op)
        WindowOnly(op) => window_only_op_string(op)
      },
    )
  }
  if x.field is Some(v) {
    obj["field"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.as_
    obj["as"] = Json::string(v)
  }
  if x.param is Some(v) {
    obj["param"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// One sort key: the field, and whether it sorts descending.
#derive(Eq, Debug)
pub struct VegaSortField {
  field : String
  order : VegaSort?
}

///|
pub extend VegaSortField with Eq::{equal, not_equal}

///|
pub extend VegaSortField with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaSortField::VegaSortField(
  field~ : String,
  order? : VegaSort,
) -> VegaSortField {
  { field, order, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_sort_field_emit_json(x : VegaSortField) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.field
    obj["field"] = Json::string(escape_vega_field(v))
  }
  if x.order is Some(v) {
    obj["order"] = Json::string(vega_sort_order_string(v))
  }
  Json::object(obj)
}

///|
/// The lookup table side: a named data source, its key field, and the fields to bring in (all, when unset).
#derive(Eq, Debug)
pub struct VegaLookupData {
  data : String
  key : String
  priv fields : Array[String]?
}

///|
pub extend VegaLookupData with Eq::{equal, not_equal}

///|
pub extend VegaLookupData with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaLookupData::VegaLookupData(
  data~ : String,
  key~ : String,
  fields? : Array[String],
) -> VegaLookupData {
  {
    data,
    key,
    fields: match fields {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The `fields` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaLookupData::fields(self : VegaLookupData) -> Array[String]? {
  match self.fields {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_lookup_data_emit_json(x : VegaLookupData) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.data
    obj["data"] = Json::string(v)
  }
  {
    let v = x.key
    obj["key"] = Json::string(escape_vega_field(v))
  }
  if x.fields is Some(v) {
    obj["fields"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  Json::object(obj)
}

///|
/// A generated key sequence to impute over: a start, a stop, and a step.
#derive(Eq, Debug)
pub struct VegaImputeSequence {
  start : Double?
  stop : Double
  step : Double?
}

///|
pub extend VegaImputeSequence with Eq::{equal, not_equal}

///|
pub extend VegaImputeSequence with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaImputeSequence::VegaImputeSequence(
  stop~ : Double,
  start? : Double,
  step? : Double,
) -> VegaImputeSequence {
  { start, stop, step, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_impute_sequence_emit_json(x : VegaImputeSequence) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.start is Some(v) {
    obj["start"] = Json::number(v)
  }
  {
    let v = x.stop
    obj["stop"] = Json::number(v)
  }
  if x.step is Some(v) {
    obj["step"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// The aggregate transform: one row per group, the outputs from the
/// aggregated-field list, the groups from the group-by fields (the whole
/// frame, when unset).
#derive(Eq, Debug)
pub struct VegaAggregateTransform {
  priv aggregate : Array[VegaAggField]
  priv groupby : Array[String]?
}

///|
pub extend VegaAggregateTransform with Eq::{equal, not_equal}

///|
pub extend VegaAggregateTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaAggregateTransform::VegaAggregateTransform(
  aggregate~ : Array[VegaAggField],
  groupby? : Array[String],
) -> VegaAggregateTransform {
  {
    aggregate: aggregate.copy(),
    groupby: match groupby {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The `aggregate` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaAggregateTransform::aggregate(
  self : VegaAggregateTransform,
) -> Array[VegaAggField] {
  self.aggregate.copy()
}

///|
/// The `groupby` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaAggregateTransform::groupby(
  self : VegaAggregateTransform,
) -> Array[String]? {
  match self.groupby {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_aggregate_transform_emit_json(x : VegaAggregateTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.aggregate
    obj["aggregate"] = Json::array(v.map(fn(e) { vega_agg_field_emit_json(e) }))
  }
  if x.groupby is Some(v) {
    obj["groupby"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  Json::object(obj)
}

///|
/// The bin transform: bin `field` into `maxbins` buckets, writing the range to the output name (or the start / end pair).
#derive(Eq, Debug)
pub struct VegaBinTransform {
  bin : VegaBin
  field : String
  as_ : VegaAsField
}

///|
pub extend VegaBinTransform with Eq::{equal, not_equal}

///|
pub extend VegaBinTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaBinTransform::VegaBinTransform(
  bin~ : VegaBin,
  field~ : String,
  as_~ : VegaAsField,
) -> VegaBinTransform {
  { bin, field, as_, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_bin_transform_emit_json(x : VegaBinTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.bin
    obj["bin"] = bin_json(v)
  }
  {
    let v = x.field
    obj["field"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.as_
    obj["as"] = vega_as_field_emit_json(v)
  }
  Json::object(obj)
}

///|
/// The calculate transform: a Vega expression over each row, written to the output name.
#derive(Eq, Debug)
pub struct VegaCalculateTransform {
  calculate : String
  as_ : String
}

///|
pub extend VegaCalculateTransform with Eq::{equal, not_equal}

///|
pub extend VegaCalculateTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaCalculateTransform::VegaCalculateTransform(
  calculate~ : String,
  as_~ : String,
) -> VegaCalculateTransform {
  { calculate, as_, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key. The expression passes through verbatim: it is Vega
/// expression source the mirror does not parse, so a dotted column it
/// references is the caller's to spell escaped (`datum["a.b"]`); the
/// `as` output name is emitted as written for the same reason.
fn vega_calculate_transform_emit_json(x : VegaCalculateTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.calculate
    obj["calculate"] = Json::string(v)
  }
  {
    let v = x.as_
    obj["as"] = Json::string(v)
  }
  Json::object(obj)
}

///|
/// The density transform: a kernel density estimate over `density`, optionally grouped, cumulative, as counts, over an extent or a step budget.
#derive(Eq, Debug)
pub struct VegaDensityTransform {
  density : String
  priv as_ : Array[String]?
  bandwidth : Double?
  counts : Bool?
  cumulative : Bool?
  priv extent : Array[Double]?
  priv groupby : Array[String]?
  steps : Double?
  minsteps : Double?
  maxsteps : Double?
}

///|
pub extend VegaDensityTransform with Eq::{equal, not_equal}

///|
pub extend VegaDensityTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaDensityTransform::VegaDensityTransform(
  density~ : String,
  as_? : Array[String],
  bandwidth? : Double,
  counts? : Bool,
  cumulative? : Bool,
  extent? : Array[Double],
  groupby? : Array[String],
  steps? : Double,
  minsteps? : Double,
  maxsteps? : Double,
) -> VegaDensityTransform {
  {
    density,
    as_: match as_ {
      Some(a) => Some(a.copy())
      None => None
    },
    bandwidth,
    counts,
    cumulative,
    extent: match extent {
      Some(a) => Some(a.copy())
      None => None
    },
    groupby: match groupby {
      Some(a) => Some(a.copy())
      None => None
    },
    steps,
    minsteps,
    maxsteps,
  }
}

///|
/// The `as_` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaDensityTransform::as_(self : VegaDensityTransform) -> Array[String]? {
  match self.as_ {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `extent` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaDensityTransform::extent(
  self : VegaDensityTransform,
) -> Array[Double]? {
  match self.extent {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `groupby` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaDensityTransform::groupby(
  self : VegaDensityTransform,
) -> Array[String]? {
  match self.groupby {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_density_transform_emit_json(x : VegaDensityTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.density
    obj["density"] = Json::string(escape_vega_field(v))
  }
  if x.as_ is Some(v) {
    obj["as"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  if x.bandwidth is Some(v) {
    obj["bandwidth"] = Json::number(v)
  }
  if x.counts is Some(v) {
    obj["counts"] = Json::boolean(v)
  }
  if x.cumulative is Some(v) {
    obj["cumulative"] = Json::boolean(v)
  }
  if x.extent is Some(v) {
    obj["extent"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.groupby is Some(v) {
    obj["groupby"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  if x.steps is Some(v) {
    obj["steps"] = Json::number(v)
  }
  if x.minsteps is Some(v) {
    obj["minsteps"] = Json::number(v)
  }
  if x.maxsteps is Some(v) {
    obj["maxsteps"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// The extent transform: the min / max of `extent`, bound to the named parameter (consumed by scales and brushes).
#derive(Eq, Debug)
pub struct VegaExtentTransform {
  extent : String
  param : String
}

///|
pub extend VegaExtentTransform with Eq::{equal, not_equal}

///|
pub extend VegaExtentTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaExtentTransform::VegaExtentTransform(
  extent~ : String,
  param~ : String,
) -> VegaExtentTransform {
  { extent, param, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_extent_transform_emit_json(x : VegaExtentTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.extent
    obj["extent"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.param
    obj["param"] = Json::string(v)
  }
  Json::object(obj)
}

///|
/// The filter transform: keep the rows the predicate accepts.
#derive(Eq, Debug)
pub struct VegaFilterTransform {
  filter : VegaPredicate
}

///|
pub extend VegaFilterTransform with Eq::{equal, not_equal}

///|
pub extend VegaFilterTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaFilterTransform::VegaFilterTransform(
  filter~ : VegaPredicate,
) -> VegaFilterTransform {
  { filter, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_filter_transform_emit_json(x : VegaFilterTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.filter
    obj["filter"] = vega_predicate_emit_json(v)
  }
  Json::object(obj)
}

///|
/// The flatten transform: one row per element of the array fields, the outputs renamed.
#derive(Eq, Debug)
pub struct VegaFlattenTransform {
  priv flatten : Array[String]
  priv as_ : Array[String]?
}

///|
pub extend VegaFlattenTransform with Eq::{equal, not_equal}

///|
pub extend VegaFlattenTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaFlattenTransform::VegaFlattenTransform(
  flatten~ : Array[String],
  as_? : Array[String],
) -> VegaFlattenTransform {
  {
    flatten: flatten.copy(),
    as_: match as_ {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The `flatten` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaFlattenTransform::flatten(
  self : VegaFlattenTransform,
) -> Array[String] {
  self.flatten.copy()
}

///|
/// The `as_` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaFlattenTransform::as_(self : VegaFlattenTransform) -> Array[String]? {
  match self.as_ {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_flatten_transform_emit_json(x : VegaFlattenTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.flatten
    obj["flatten"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  if x.as_ is Some(v) {
    obj["as"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  Json::object(obj)
}

///|
/// The fold transform: the named columns gathered into a key / value pair (wide to long), the outputs renamed.
#derive(Eq, Debug)
pub struct VegaFoldTransform {
  priv fold : Array[String]
  priv as_ : Array[String]?
}

///|
pub extend VegaFoldTransform with Eq::{equal, not_equal}

///|
pub extend VegaFoldTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaFoldTransform::VegaFoldTransform(
  fold~ : Array[String],
  as_? : Array[String],
) -> VegaFoldTransform {
  {
    fold: fold.copy(),
    as_: match as_ {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The `fold` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaFoldTransform::fold(self : VegaFoldTransform) -> Array[String] {
  self.fold.copy()
}

///|
/// The `as_` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaFoldTransform::as_(self : VegaFoldTransform) -> Array[String]? {
  match self.as_ {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_fold_transform_emit_json(x : VegaFoldTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.fold
    obj["fold"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  if x.as_ is Some(v) {
    obj["as"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  Json::object(obj)
}

///|
/// The impute transform: fill missing `impute` values, keyed by `key`, with a method or a constant, over a frame or a generated sequence, optionally per group.
#derive(Eq, Debug)
pub struct VegaImputeTransform {
  impute : String
  key : String
  priv keyvals : Array[Json]?
  keyvals_sequence : VegaImputeSequence?
  method_ : String?
  value : Json?
  priv groupby : Array[String]?
  priv frame : Array[Double]?
}

///|
pub extend VegaImputeTransform with Eq::{equal, not_equal}

///|
pub extend VegaImputeTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaImputeTransform::VegaImputeTransform(
  impute~ : String,
  key~ : String,
  keyvals? : Array[Json],
  keyvals_sequence? : VegaImputeSequence,
  method_? : String,
  value? : Json,
  groupby? : Array[String],
  frame? : Array[Double],
) -> VegaImputeTransform {
  {
    impute,
    key,
    keyvals: match keyvals {
      Some(a) => Some(a.copy())
      None => None
    },
    keyvals_sequence,
    method_,
    value,
    groupby: match groupby {
      Some(a) => Some(a.copy())
      None => None
    },
    frame: match frame {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The `keyvals` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaImputeTransform::keyvals(self : VegaImputeTransform) -> Array[Json]? {
  match self.keyvals {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `groupby` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaImputeTransform::groupby(
  self : VegaImputeTransform,
) -> Array[String]? {
  match self.groupby {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `frame` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaImputeTransform::frame(self : VegaImputeTransform) -> Array[Double]? {
  match self.frame {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_impute_transform_emit_json(x : VegaImputeTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.impute
    obj["impute"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.key
    obj["key"] = Json::string(escape_vega_field(v))
  }
  if x.keyvals is Some(v) {
    obj["keyvals"] = Json::array(v.copy())
  }
  if x.keyvals_sequence is Some(v) {
    obj["keyvals"] = vega_impute_sequence_emit_json(v)
  }
  if x.method_ is Some(v) {
    obj["method"] = Json::string(v)
  }
  if x.value is Some(v) {
    obj["value"] = json_identity(v)
  }
  if x.groupby is Some(v) {
    obj["groupby"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  if x.frame is Some(v) {
    obj["frame"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  Json::object(obj)
}

///|
/// The join-aggregate transform: aggregate over the whole frame (or groups), the results joined onto every row.
#derive(Eq, Debug)
pub struct VegaJoinAggregateTransform {
  priv joinaggregate : Array[VegaAggField]
  priv groupby : Array[String]?
}

///|
pub extend VegaJoinAggregateTransform with Eq::{equal, not_equal}

///|
pub extend VegaJoinAggregateTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaJoinAggregateTransform::VegaJoinAggregateTransform(
  joinaggregate~ : Array[VegaAggField],
  groupby? : Array[String],
) -> VegaJoinAggregateTransform {
  {
    joinaggregate: joinaggregate.copy(),
    groupby: match groupby {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The `joinaggregate` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaJoinAggregateTransform::joinaggregate(
  self : VegaJoinAggregateTransform,
) -> Array[VegaAggField] {
  self.joinaggregate.copy()
}

///|
/// The `groupby` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaJoinAggregateTransform::groupby(
  self : VegaJoinAggregateTransform,
) -> Array[String]? {
  match self.groupby {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_join_aggregate_transform_emit_json(
  x : VegaJoinAggregateTransform,
) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.joinaggregate
    obj["joinaggregate"] = Json::array(
      v.map(fn(e) { vega_agg_field_emit_json(e) }),
    )
  }
  if x.groupby is Some(v) {
    obj["groupby"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  Json::object(obj)
}

///|
/// The loess transform: a locally-estimated scatterplot smoothing of `loess` against `on`, optionally grouped, with a bandwidth.
#derive(Eq, Debug)
pub struct VegaLoessTransform {
  loess : String
  on : String
  priv as_ : Array[String]?
  bandwidth : Double?
  priv groupby : Array[String]?
}

///|
pub extend VegaLoessTransform with Eq::{equal, not_equal}

///|
pub extend VegaLoessTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaLoessTransform::VegaLoessTransform(
  loess~ : String,
  on~ : String,
  as_? : Array[String],
  bandwidth? : Double,
  groupby? : Array[String],
) -> VegaLoessTransform {
  {
    loess,
    on,
    as_: match as_ {
      Some(a) => Some(a.copy())
      None => None
    },
    bandwidth,
    groupby: match groupby {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The `as_` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaLoessTransform::as_(self : VegaLoessTransform) -> Array[String]? {
  match self.as_ {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `groupby` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaLoessTransform::groupby(self : VegaLoessTransform) -> Array[String]? {
  match self.groupby {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_loess_transform_emit_json(x : VegaLoessTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.loess
    obj["loess"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.on
    obj["on"] = Json::string(escape_vega_field(v))
  }
  if x.as_ is Some(v) {
    obj["as"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  if x.bandwidth is Some(v) {
    obj["bandwidth"] = Json::number(v)
  }
  if x.groupby is Some(v) {
    obj["groupby"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  Json::object(obj)
}

///|
/// The lookup transform: enrich each row from another data source (a named table, or a parameter-driven selection), keyed by `lookup`.
#derive(Eq, Debug)
pub struct VegaLookupTransform {
  lookup : String
  from_ : VegaLookupFrom
  as_ : VegaAsField?
  default : Json?
}

///|
pub extend VegaLookupTransform with Eq::{equal, not_equal}

///|
pub extend VegaLookupTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaLookupTransform::VegaLookupTransform(
  lookup~ : String,
  from_~ : VegaLookupFrom,
  as_? : VegaAsField,
  default? : Json,
) -> VegaLookupTransform {
  { lookup, from_, as_, default, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_lookup_transform_emit_json(x : VegaLookupTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.lookup
    obj["lookup"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.from_
    obj["from"] = vega_lookup_from_emit_json(v)
  }
  if x.as_ is Some(v) {
    obj["as"] = vega_as_field_emit_json(v)
  }
  if x.default is Some(v) {
    obj["default"] = json_identity(v)
  }
  Json::object(obj)
}

///|
/// The pivot transform: long to wide — one column per value of `pivot`, holding `value` aggregated by `op`.
#derive(Eq, Debug)
pub struct VegaPivotTransform {
  pivot : String
  value : String
  priv groupby : Array[String]?
  limit : Double?
  op : VegaAggregate?
}

///|
pub extend VegaPivotTransform with Eq::{equal, not_equal}

///|
pub extend VegaPivotTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaPivotTransform::VegaPivotTransform(
  pivot~ : String,
  value~ : String,
  groupby? : Array[String],
  limit? : Double,
  op? : VegaAggregate,
) -> VegaPivotTransform {
  {
    pivot,
    value,
    groupby: match groupby {
      Some(a) => Some(a.copy())
      None => None
    },
    limit,
    op,
  }
}

///|
/// The `groupby` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaPivotTransform::groupby(self : VegaPivotTransform) -> Array[String]? {
  match self.groupby {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_pivot_transform_emit_json(x : VegaPivotTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.pivot
    obj["pivot"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.value
    obj["value"] = Json::string(escape_vega_field(v))
  }
  if x.groupby is Some(v) {
    obj["groupby"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  if x.limit is Some(v) {
    obj["limit"] = Json::number(v)
  }
  if x.op is Some(v) {
    obj["op"] = Json::string(aggregate_string(v))
  }
  Json::object(obj)
}

///|
/// The quantile transform: the quantile values of `quantile`, over a probability list or a step grid.
#derive(Eq, Debug)
pub struct VegaQuantileTransform {
  quantile : String
  priv as_ : Array[String]?
  priv probs : Array[Double]?
  step : Double?
  priv groupby : Array[String]?
}

///|
pub extend VegaQuantileTransform with Eq::{equal, not_equal}

///|
pub extend VegaQuantileTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaQuantileTransform::VegaQuantileTransform(
  quantile~ : String,
  as_? : Array[String],
  probs? : Array[Double],
  step? : Double,
  groupby? : Array[String],
) -> VegaQuantileTransform {
  {
    quantile,
    as_: match as_ {
      Some(a) => Some(a.copy())
      None => None
    },
    probs: match probs {
      Some(a) => Some(a.copy())
      None => None
    },
    step,
    groupby: match groupby {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The `as_` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaQuantileTransform::as_(
  self : VegaQuantileTransform,
) -> Array[String]? {
  match self.as_ {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `probs` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaQuantileTransform::probs(
  self : VegaQuantileTransform,
) -> Array[Double]? {
  match self.probs {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `groupby` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaQuantileTransform::groupby(
  self : VegaQuantileTransform,
) -> Array[String]? {
  match self.groupby {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_quantile_transform_emit_json(x : VegaQuantileTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.quantile
    obj["quantile"] = Json::string(escape_vega_field(v))
  }
  if x.as_ is Some(v) {
    obj["as"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  if x.probs is Some(v) {
    obj["probs"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.step is Some(v) {
    obj["step"] = Json::number(v)
  }
  if x.groupby is Some(v) {
    obj["groupby"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  Json::object(obj)
}

///|
/// The regression transform: fit `regression` against `on` (linear, poly, exp, log, pow, or quad), optionally grouped, over an extent, keeping the model parameters.
#derive(Eq, Debug)
pub struct VegaRegressionTransform {
  regression : String
  on : String
  priv as_ : Array[String]?
  priv extent : Array[Double]?
  method_ : String?
  order : Double?
  priv groupby : Array[String]?
  params : Bool?
}

///|
pub extend VegaRegressionTransform with Eq::{equal, not_equal}

///|
pub extend VegaRegressionTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaRegressionTransform::VegaRegressionTransform(
  regression~ : String,
  on~ : String,
  as_? : Array[String],
  extent? : Array[Double],
  method_? : String,
  order? : Double,
  groupby? : Array[String],
  params? : Bool,
) -> VegaRegressionTransform {
  {
    regression,
    on,
    as_: match as_ {
      Some(a) => Some(a.copy())
      None => None
    },
    extent: match extent {
      Some(a) => Some(a.copy())
      None => None
    },
    method_,
    order,
    groupby: match groupby {
      Some(a) => Some(a.copy())
      None => None
    },
    params,
  }
}

///|
/// The `as_` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaRegressionTransform::as_(
  self : VegaRegressionTransform,
) -> Array[String]? {
  match self.as_ {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `extent` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaRegressionTransform::extent(
  self : VegaRegressionTransform,
) -> Array[Double]? {
  match self.extent {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `groupby` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaRegressionTransform::groupby(
  self : VegaRegressionTransform,
) -> Array[String]? {
  match self.groupby {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_regression_transform_emit_json(x : VegaRegressionTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.regression
    obj["regression"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.on
    obj["on"] = Json::string(escape_vega_field(v))
  }
  if x.as_ is Some(v) {
    obj["as"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  if x.extent is Some(v) {
    obj["extent"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.method_ is Some(v) {
    obj["method"] = Json::string(v)
  }
  if x.order is Some(v) {
    obj["order"] = Json::number(v)
  }
  if x.groupby is Some(v) {
    obj["groupby"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  if x.params is Some(v) {
    obj["params"] = Json::boolean(v)
  }
  Json::object(obj)
}

///|
/// The sample transform: draw `sample` rows from the frame.
#derive(Eq, Debug)
pub struct VegaSampleTransform {
  sample : Double
}

///|
pub extend VegaSampleTransform with Eq::{equal, not_equal}

///|
pub extend VegaSampleTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaSampleTransform::VegaSampleTransform(
  sample~ : Double,
) -> VegaSampleTransform {
  { sample, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_sample_transform_emit_json(x : VegaSampleTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.sample
    obj["sample"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// The stack transform: stack `stack` end to end within groups, sorted, offset (zero, center, or normalize), writing the start / end pair.
#derive(Eq, Debug)
pub struct VegaStackTransform {
  stack : String
  priv groupby : Array[String]
  as_ : VegaAsField
  offset : String?
  priv sort : Array[VegaSortField]?
}

///|
pub extend VegaStackTransform with Eq::{equal, not_equal}

///|
pub extend VegaStackTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaStackTransform::VegaStackTransform(
  stack~ : String,
  groupby~ : Array[String],
  as_~ : VegaAsField,
  offset? : String,
  sort? : Array[VegaSortField],
) -> VegaStackTransform {
  {
    stack,
    groupby: groupby.copy(),
    as_,
    offset,
    sort: match sort {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The `groupby` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaStackTransform::groupby(self : VegaStackTransform) -> Array[String] {
  self.groupby.copy()
}

///|
/// The `sort` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaStackTransform::sort(
  self : VegaStackTransform,
) -> Array[VegaSortField]? {
  match self.sort {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_stack_transform_emit_json(x : VegaStackTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.stack
    obj["stack"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.groupby
    obj["groupby"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  {
    let v = x.as_
    obj["as"] = vega_as_field_emit_json(v)
  }
  if x.offset is Some(v) {
    obj["offset"] = Json::string(v)
  }
  if x.sort is Some(v) {
    obj["sort"] = Json::array(v.map(fn(e) { vega_sort_field_emit_json(e) }))
  }
  Json::object(obj)
}

///|
/// The time-unit transform: truncate `field` to calendar units, written to the output name.
#derive(Eq, Debug)
pub struct VegaTimeUnitTransform {
  time_unit : VegaTimeUnit
  field : String
  as_ : String
}

///|
pub extend VegaTimeUnitTransform with Eq::{equal, not_equal}

///|
pub extend VegaTimeUnitTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaTimeUnitTransform::VegaTimeUnitTransform(
  time_unit~ : VegaTimeUnit,
  field~ : String,
  as_~ : String,
) -> VegaTimeUnitTransform {
  { time_unit, field, as_, }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_time_unit_transform_emit_json(x : VegaTimeUnitTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.time_unit
    obj["timeUnit"] = Json::string(time_unit_string(v))
  }
  {
    let v = x.field
    obj["field"] = Json::string(escape_vega_field(v))
  }
  {
    let v = x.as_
    obj["as"] = Json::string(v)
  }
  Json::object(obj)
}

///|
/// The window transform: per-row windowed aggregates (a running sum, a rank), over a frame, sorted, grouped, ignoring or counting peer rows.
#derive(Eq, Debug)
pub struct VegaWindowTransform {
  priv window : Array[VegaWindowField]
  priv groupby : Array[String]?
  priv sort : Array[VegaSortField]?
  frame : (VegaFrameLimit, VegaFrameLimit)?
  ignore_peers : Bool?
}

///|
pub extend VegaWindowTransform with Eq::{equal, not_equal}

///|
pub extend VegaWindowTransform with Debug::{to_repr}

///|
/// The array properties are copied at construction, so
/// arrays the caller mutates afterwards cannot move a
/// chart already built; read them back through their
/// accessors, which copy again.
pub fn VegaWindowTransform::VegaWindowTransform(
  window~ : Array[VegaWindowField],
  groupby? : Array[String],
  sort? : Array[VegaSortField],
  frame? : (VegaFrameLimit, VegaFrameLimit),
  ignore_peers? : Bool,
) -> VegaWindowTransform {
  {
    window: window.copy(),
    groupby: match groupby {
      Some(a) => Some(a.copy())
      None => None
    },
    sort: match sort {
      Some(a) => Some(a.copy())
      None => None
    },
    frame,
    ignore_peers,
  }
}

///|
/// The `window` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaWindowTransform::window(
  self : VegaWindowTransform,
) -> Array[VegaWindowField] {
  self.window.copy()
}

///|
/// The `groupby` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaWindowTransform::groupby(
  self : VegaWindowTransform,
) -> Array[String]? {
  match self.groupby {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `sort` list, copied — reading the field
/// itself would hand the caller the array the
/// spec holds.
pub fn VegaWindowTransform::sort(
  self : VegaWindowTransform,
) -> Array[VegaSortField]? {
  match self.sort {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object, every set property under its
/// schema key.
fn vega_window_transform_emit_json(x : VegaWindowTransform) -> Json {
  let obj : Map[String, Json] = Map([])
  {
    let v = x.window
    obj["window"] = Json::array(v.map(fn(e) { vega_window_field_emit_json(e) }))
  }
  if x.groupby is Some(v) {
    obj["groupby"] = Json::array(
      v.map(fn(f) { Json::string(escape_vega_field(f)) }),
    )
  }
  if x.sort is Some(v) {
    obj["sort"] = Json::array(v.map(fn(e) { vega_sort_field_emit_json(e) }))
  }
  if x.frame is Some(v) {
    obj["frame"] = vega_frame_pair_emit_json(v)
  }
  if x.ignore_peers is Some(v) {
    obj["ignorePeers"] = Json::boolean(v)
  }
  Json::object(obj)
}

///|
/// The lookup source: a named data table, or a parameter reference.
#derive(Eq, Debug)
pub(all) enum VegaLookupFrom {
  Data(VegaLookupData)
  Param(String)
}

///|
pub extend VegaLookupFrom with Eq::{equal, not_equal}

///|
pub extend VegaLookupFrom with Debug::{to_repr}

///|
/// The JSON of the lookup source.
fn vega_lookup_from_emit_json(v : VegaLookupFrom) -> Json {
  match v {
    Data(data) => vega_lookup_data_emit_json(data)
    Param(name) => {
      let obj : Map[String, Json] = Map([])
      obj["param"] = Json::string(name)
      Json::object(obj)
    }
  }
}

///|
/// A value passed through as JSON already is.
fn json_identity(v : Json) -> Json {
  v
}

///|
/// One transform, by kind — the mirror of the schema's transform union.
/// `pub(all)` so callers build the variants; the array-carrying
/// payloads take copies at their own constructors.
#derive(Eq, Debug)
pub(all) enum VegaTransform {
  Aggregate(VegaAggregateTransform)
  Bin(VegaBinTransform)
  Calculate(VegaCalculateTransform)
  Density(VegaDensityTransform)
  Extent(VegaExtentTransform)
  Filter(VegaFilterTransform)
  Flatten(VegaFlattenTransform)
  Fold(VegaFoldTransform)
  Impute(VegaImputeTransform)
  JoinAggregate(VegaJoinAggregateTransform)
  Loess(VegaLoessTransform)
  Lookup(VegaLookupTransform)
  Pivot(VegaPivotTransform)
  Quantile(VegaQuantileTransform)
  Regression(VegaRegressionTransform)
  Sample(VegaSampleTransform)
  Stack(VegaStackTransform)
  TimeUnit(VegaTimeUnitTransform)
  Window(VegaWindowTransform)
}

///|
pub extend VegaTransform with Eq::{equal, not_equal}

///|
pub extend VegaTransform with Debug::{to_repr}

///|
/// The JSON of one transform, its own object shape.
fn vega_transform_emit_json(t : VegaTransform) -> Json {
  match t {
    Aggregate(x) => vega_aggregate_transform_emit_json(x)
    Bin(x) => vega_bin_transform_emit_json(x)
    Calculate(x) => vega_calculate_transform_emit_json(x)
    Density(x) => vega_density_transform_emit_json(x)
    Extent(x) => vega_extent_transform_emit_json(x)
    Filter(x) => vega_filter_transform_emit_json(x)
    Flatten(x) => vega_flatten_transform_emit_json(x)
    Fold(x) => vega_fold_transform_emit_json(x)
    Impute(x) => vega_impute_transform_emit_json(x)
    JoinAggregate(x) => vega_join_aggregate_transform_emit_json(x)
    Loess(x) => vega_loess_transform_emit_json(x)
    Lookup(x) => vega_lookup_transform_emit_json(x)
    Pivot(x) => vega_pivot_transform_emit_json(x)
    Quantile(x) => vega_quantile_transform_emit_json(x)
    Regression(x) => vega_regression_transform_emit_json(x)
    Sample(x) => vega_sample_transform_emit_json(x)
    Stack(x) => vega_stack_transform_emit_json(x)
    TimeUnit(x) => vega_time_unit_transform_emit_json(x)
    Window(x) => vega_window_transform_emit_json(x)
  }
}

///|
/// A transform list as the schema's `transform` array.
fn vega_transforms_emit_json(transforms : Array[VegaTransform]) -> Json {
  Json::array(transforms.map(fn(t) { vega_transform_emit_json(t) }))
}

///|
/// The schema string of a sort order for a transform sort key.
fn vega_sort_order_string(v : VegaSort) -> String {
  match v {
    Ascending => "ascending"
    Descending => "descending"
  }
}
