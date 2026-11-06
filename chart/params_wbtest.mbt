// Whitebox tests for the parameter family's package-private emitters.

///|
test "a channel carrying both a field and a repeat reference raises" {
  // The builders cannot build this shape (`field` sets one half,
  // `VegaChannel::repeat` the other), so the guard is pinned here where
  // the struct is in reach: the schema's field slot holds a name or a
  // RepeatRef, never both, and emission says so loudly rather than
  // silently dropping one.
  let both : VegaChannel = VegaChannel::{
    field: Some("val"),
    repeat_ref: Some(Column),
    aggregate: None,
    bin: None,
    time_unit: None,
    sort: None,
    type_override: None,
    title: None,
    format: None,
    stack: None,
    band_position: None,
    scale: None,
    axis: None,
    legend: None,
    condition: None,
    value: None,
    datum: None,
  }
  let refused = Ok(encoding_channel("y", both, None)) catch { e => Err(e) }
  assert_true(refused is Err(@types.DataError::InvalidOperation(_)))
}
