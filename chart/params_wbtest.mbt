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

///|
test "format_vega_lite refuses the double-set channel at the public entry" {
  // The same refusal driven through the public entry: the channel's field
  // resolves first (`channel_dtype` doubles as the existence check), so a
  // real column does not let the malformed channel through — the emitter
  // refuses it before any spec is shipped. A whitebox file sees the
  // package's own imports only, so the frame comes from `from_rows`
  // rather than the `@series` builders the blackbox corpus test uses.
  let both : VegaChannel = { ..field("val"), repeat_ref: Some(Column), }
  let df = @frame.DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("val", @types.DataType::Int, nullable=false),
    ]),
    [[@types.Scalar::Int(1)], [@types.Scalar::Int(2)]],
  )
  let refused = Ok(
    format_vega_lite(
      df,
      Chart::of(ChartSpec::of(ChartKind::Point, x=both, y=field("val"))),
    ),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    refused,
    Err(
      @types.DataError::InvalidOperation(
        "a channel cannot carry both a field and a repeat reference — the schema's field slot holds one or the other; build the channel with `field` or with `VegaChannel::repeat`, not both",
      ),
    ),
  )
}
