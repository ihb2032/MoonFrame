// The projection family: a typed mirror of the schema's `Projection` object, transcribed
// from the vendored vega_lite_v6_5_0.schema.json and schema-walked through
// the corpus guard. Reached through `@chart` qualification — part of the
// deep mirror family the facade deliberately does not re-export.
//
// The static arms of the schema's unions are mirrored here; the arms that
// carry expressions, conditions, or parameter references (ExprRef /
// Conditional* / ParameterExtent) land with the params stage, so a union
// whose remaining arm is a plain value exposes that plain value directly
// (a `Double` where the schema says `number | ExprRef`).

///|
/// A map projection, one variant per schema value.
#derive(Eq, Debug)
pub(all) enum VegaProjectionType {
  Albers
  AlbersUsa
  AzimuthalEqualArea
  AzimuthalEquidistant
  ConicConformal
  ConicEqualArea
  ConicEquidistant
  EqualEarth
  Equirectangular
  Gnomonic
  Identity
  Mercator
  NaturalEarth1
  Orthographic
  Stereographic
  TransverseMercator
}

///|
pub extend VegaProjectionType with Eq::{equal, not_equal}

///|
pub extend VegaProjectionType with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_projection_type_string(v : VegaProjectionType) -> String {
  match v {
    Albers => "albers"
    AlbersUsa => "albersUsa"
    AzimuthalEqualArea => "azimuthalEqualArea"
    AzimuthalEquidistant => "azimuthalEquidistant"
    ConicConformal => "conicConformal"
    ConicEqualArea => "conicEqualArea"
    ConicEquidistant => "conicEquidistant"
    EqualEarth => "equalEarth"
    Equirectangular => "equirectangular"
    Gnomonic => "gnomonic"
    Identity => "identity"
    Mercator => "mercator"
    NaturalEarth1 => "naturalEarth1"
    Orthographic => "orthographic"
    Stereographic => "stereographic"
    TransverseMercator => "transverseMercator"
  }
}

///|
/// A projection rotation: longitude / latitude, or with a roll angle as the third value.
#derive(Eq, Debug)
pub(all) enum VegaRotate {
  LonLat(Double, Double)
  LonLatRoll(Double, Double, Double)
}

///|
pub extend VegaRotate with Eq::{equal, not_equal}

///|
pub extend VegaRotate with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_rotate_emit_json(v : VegaRotate) -> Json {
  match v {
    LonLat(lon, lat) => Json::array([Json::number(lon), Json::number(lat)])
    LonLatRoll(lon, lat, roll) =>
      Json::array([Json::number(lon), Json::number(lat), Json::number(roll)])
  }
}

///|
/// A geographic projection for geoshape marks and latitude / longitude
/// channels, the schema's `Projection` in static form — the projection type
/// (Mercator, Albers, …), the center / translate / scale / rotate geometry,
/// clip angles and extents, and the per-type numeric parameters (a conic's
/// parallels, an Azimuthal's coefficient). Every property is optional;
/// unset ones fall to the projection's own defaults. The `parallels` array
/// is copied at construction and copied again on read.
#derive(Eq, Debug)
pub struct VegaProjection {
  type_ : VegaProjectionType?
  center : (Double, Double)?
  clip_angle : Double?
  clip_extent : ((Double, Double), (Double, Double))?
  coefficient : Double?
  distance : Double?
  extent : ((Double, Double), (Double, Double))?
  fraction : Double?
  lobes : Double?
  parallel : Double?
  priv parallels : Array[Double]?
  point_radius : Double?
  precision : Double?
  radius : Double?
  ratio : Double?
  reflect_x : Bool?
  reflect_y : Bool?
  rotate : VegaRotate?
  scale : Double?
  size : (Double, Double)?
  spacing : Double?
  tilt : Double?
  translate : (Double, Double)?
}

///|
pub extend VegaProjection with Eq::{equal, not_equal}

///|
pub extend VegaProjection with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaProjection::VegaProjection(
  type_? : VegaProjectionType,
  center? : (Double, Double),
  clip_angle? : Double,
  clip_extent? : ((Double, Double), (Double, Double)),
  coefficient? : Double,
  distance? : Double,
  extent? : ((Double, Double), (Double, Double)),
  fraction? : Double,
  lobes? : Double,
  parallel? : Double,
  parallels? : Array[Double],
  point_radius? : Double,
  precision? : Double,
  radius? : Double,
  ratio? : Double,
  reflect_x? : Bool,
  reflect_y? : Bool,
  rotate? : VegaRotate,
  scale? : Double,
  size? : (Double, Double),
  spacing? : Double,
  tilt? : Double,
  translate? : (Double, Double),
) -> VegaProjection {
  {
    type_,
    center,
    clip_angle,
    clip_extent,
    coefficient,
    distance,
    extent,
    fraction,
    lobes,
    parallel,
    parallels: match parallels {
      Some(a) => Some(a.copy())
      None => None
    },
    point_radius,
    precision,
    radius,
    ratio,
    reflect_x,
    reflect_y,
    rotate,
    scale,
    size,
    spacing,
    tilt,
    translate,
  }
}

///|
/// The `parallels` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaProjection::parallels(self : VegaProjection) -> Array[Double]? {
  match self.parallels {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object of a `VegaProjection`, every set property
/// under its schema key.
fn vega_projection_emit_json(x : VegaProjection) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.type_ is Some(v) {
    obj["type"] = Json::string(vega_projection_type_string(v))
  }
  if x.center is Some(v) {
    let (a, b) = v
    obj["center"] = Json::array([Json::number(a), Json::number(b)])
  }
  if x.clip_angle is Some(v) {
    obj["clipAngle"] = Json::number(v)
  }
  if x.clip_extent is Some(v) {
    let ((a, b), (c, d2)) = v
    obj["clipExtent"] = Json::array([
      Json::array([Json::number(a), Json::number(b)]),
      Json::array([Json::number(c), Json::number(d2)]),
    ])
  }
  if x.coefficient is Some(v) {
    obj["coefficient"] = Json::number(v)
  }
  if x.distance is Some(v) {
    obj["distance"] = Json::number(v)
  }
  if x.extent is Some(v) {
    let ((a, b), (c, d2)) = v
    obj["extent"] = Json::array([
      Json::array([Json::number(a), Json::number(b)]),
      Json::array([Json::number(c), Json::number(d2)]),
    ])
  }
  if x.fraction is Some(v) {
    obj["fraction"] = Json::number(v)
  }
  if x.lobes is Some(v) {
    obj["lobes"] = Json::number(v)
  }
  if x.parallel is Some(v) {
    obj["parallel"] = Json::number(v)
  }
  if x.parallels is Some(v) {
    obj["parallels"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.point_radius is Some(v) {
    obj["pointRadius"] = Json::number(v)
  }
  if x.precision is Some(v) {
    obj["precision"] = Json::number(v)
  }
  if x.radius is Some(v) {
    obj["radius"] = Json::number(v)
  }
  if x.ratio is Some(v) {
    obj["ratio"] = Json::number(v)
  }
  if x.reflect_x is Some(v) {
    obj["reflectX"] = Json::boolean(v)
  }
  if x.reflect_y is Some(v) {
    obj["reflectY"] = Json::boolean(v)
  }
  if x.rotate is Some(v) {
    obj["rotate"] = vega_rotate_emit_json(v)
  }
  if x.scale is Some(v) {
    obj["scale"] = Json::number(v)
  }
  if x.size is Some(v) {
    let (a, b) = v
    obj["size"] = Json::array([Json::number(a), Json::number(b)])
  }
  if x.spacing is Some(v) {
    obj["spacing"] = Json::number(v)
  }
  if x.tilt is Some(v) {
    obj["tilt"] = Json::number(v)
  }
  if x.translate is Some(v) {
    let (a, b) = v
    obj["translate"] = Json::array([Json::number(a), Json::number(b)])
  }
  Json::object(obj)
}
