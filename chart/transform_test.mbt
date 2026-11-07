// Blackbox tests for the transform family: one kitchen sink per
// transform (every property set, emitted through a chart), every
// predicate arm, and the array-ownership contracts. The corpus beside
// this walks transform-bearing charts against the vendored schema.

///|
/// The fixture frame the transform tests render against.
fn transforms_df() -> @frame.DataFrame raise @types.DataError {
  corpus_df()
}

///|
/// Emit one transform list through a single-view chart and hand back
/// the spec string.
fn with_transforms(
  transforms : Array[@chart.VegaTransform],
) -> String raise @types.DataError {
  @chart.format_vega_lite(
    transforms_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        transform=transforms,
      ),
    ),
  )
}

///|
/// The `transform` array parsed out of a spec string.
fn transform_array(spec : String) -> String {
  let parsed = @json.parse(spec) catch { _ => return "<unparsable>" }
  match parsed {
    Object(obj) =>
      match obj.get("transform") {
        Some(arr) => arr.stringify()
        _ => "<missing>"
      }
    _ => "<unparsable>"
  }
}

///|
test "VegaAggregateTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Aggregate(
          @chart.VegaAggregateTransform::VegaAggregateTransform(
            aggregate=[
              @chart.VegaAggField::VegaAggField(
                op=@chart.VegaAggregate::Sum,
                field="val",
                as_="total",
              ),
              @chart.VegaAggField::VegaAggField(
                op=@chart.VegaAggregate::Count,
                as_="n",
              ),
            ],
            groupby=["cat"],
          ),
        ),
      ]),
    ),
    "[{\"aggregate\":[{\"op\":\"sum\",\"field\":\"val\",\"as\":\"total\"},{\"op\":\"count\",\"as\":\"n\"}],\"groupby\":[\"cat\"]}]",
  )
}

///|
test "VegaBinTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Bin(
          @chart.VegaBinTransform::VegaBinTransform(
            bin=@chart.VegaBin::Params(
              @chart.VegaBinParams::VegaBinParams(maxbins=10),
            ),
            field="val",
            as_=@chart.VegaAsField::Pair("val_start", "val_end"),
          ),
        ),
      ]),
    ),
    "[{\"bin\":{\"maxbins\":10},\"field\":\"val\",\"as\":[\"val_start\",\"val_end\"]}]",
  )
}

///|
test "VegaCalculateTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Calculate(
          @chart.VegaCalculateTransform::VegaCalculateTransform(
            calculate="datum.val * 2",
            as_="doubled",
          ),
        ),
      ]),
    ),
    "[{\"calculate\":\"datum.val * 2\",\"as\":\"doubled\"}]",
  )
}

///|
test "VegaDensityTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Density(
          @chart.VegaDensityTransform::VegaDensityTransform(
            density="val",
            as_=["v", "d"],
            bandwidth=0.5,
            counts=true,
            cumulative=true,
            extent=[0.0, 10.0],
            groupby=["cat"],
            steps=20,
            minsteps=2,
            maxsteps=50,
          ),
        ),
      ]),
    ),
    "[{\"density\":\"val\",\"as\":[\"v\",\"d\"],\"bandwidth\":0.5,\"counts\":true,\"cumulative\":true,\"extent\":[0,10],\"groupby\":[\"cat\"],\"steps\":20,\"minsteps\":2,\"maxsteps\":50}]",
  )
}

///|
test "VegaExtentTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Extent(
          @chart.VegaExtentTransform::VegaExtentTransform(
            extent="val",
            param="extent_param",
          ),
        ),
      ]),
    ),
    "[{\"extent\":\"val\",\"param\":\"extent_param\"}]",
  )
}

///|
test "VegaFilterTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Filter(
          @chart.VegaFilterTransform::VegaFilterTransform(
            filter=@chart.VegaPredicate::Expr("datum.val > 1"),
          ),
        ),
      ]),
    ),
    "[{\"filter\":\"datum.val > 1\"}]",
  )
}

///|
test "VegaFlattenTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Flatten(
          @chart.VegaFlattenTransform::VegaFlattenTransform(
            flatten=["a", "b"],
            as_=["x", "y"],
          ),
        ),
      ]),
    ),
    "[{\"flatten\":[\"a\",\"b\"],\"as\":[\"x\",\"y\"]}]",
  )
}

///|
test "VegaFoldTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Fold(
          @chart.VegaFoldTransform::VegaFoldTransform(fold=["val", "ts"], as_=[
            "k", "v",
          ]),
        ),
      ]),
    ),
    "[{\"fold\":[\"val\",\"ts\"],\"as\":[\"k\",\"v\"]}]",
  )
}

///|
test "VegaImputeTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Impute(
          @chart.VegaImputeTransform::VegaImputeTransform(
            impute="val",
            key="ts",
            keyvals=[Json::number(1), Json::number(2)],
            method_=@chart.VegaImputeMethod::Mean,
            value=Json::number(0),
            groupby=["cat"],
            frame=[-1.0, 1.0],
          ),
        ),
      ]),
    ),
    "[{\"impute\":\"val\",\"key\":\"ts\",\"keyvals\":[1,2],\"method\":\"mean\",\"value\":0,\"groupby\":[\"cat\"],\"frame\":[-1,1]}]",
  )
}

///|
test "VegaJoinAggregateTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::JoinAggregate(
          @chart.VegaJoinAggregateTransform::VegaJoinAggregateTransform(
            joinaggregate=[
              @chart.VegaAggField::VegaAggField(
                op=@chart.VegaAggregate::Mean,
                field="val",
                as_="avg",
              ),
            ],
            groupby=["grp"],
          ),
        ),
      ]),
    ),
    "[{\"joinaggregate\":[{\"op\":\"mean\",\"field\":\"val\",\"as\":\"avg\"}],\"groupby\":[\"grp\"]}]",
  )
}

///|
test "VegaLoessTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Loess(
          @chart.VegaLoessTransform::VegaLoessTransform(
            loess="val",
            on="ts",
            as_=["f", "d"],
            bandwidth=0.3,
            groupby=["grp"],
          ),
        ),
      ]),
    ),
    "[{\"loess\":\"val\",\"on\":\"ts\",\"as\":[\"f\",\"d\"],\"bandwidth\":0.3,\"groupby\":[\"grp\"]}]",
  )
}

///|
test "VegaLookupTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Lookup(
          @chart.VegaLookupTransform::VegaLookupTransform(
            lookup="cat",
            from_=@chart.VegaLookupFrom::Data(
              @chart.VegaLookupData::VegaLookupData(
                data="regions",
                key="name",
                fields=["pop"],
              ),
            ),
            as_=@chart.VegaAsField::One("population"),
            default=Json::number(0),
          ),
        ),
      ]),
    ),
    "[{\"lookup\":\"cat\",\"from\":{\"data\":\"regions\",\"key\":\"name\",\"fields\":[\"pop\"]},\"as\":\"population\",\"default\":0}]",
  )
}

///|
test "VegaPivotTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Pivot(
          @chart.VegaPivotTransform::VegaPivotTransform(
            pivot="cat",
            value="val",
            groupby=["grp"],
            limit=5,
            op=@chart.VegaAggregate::Sum,
          ),
        ),
      ]),
    ),
    "[{\"pivot\":\"cat\",\"value\":\"val\",\"groupby\":[\"grp\"],\"limit\":5,\"op\":\"sum\"}]",
  )
}

///|
test "VegaQuantileTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Quantile(
          @chart.VegaQuantileTransform::VegaQuantileTransform(
            quantile="val",
            as_=["q", "v"],
            probs=[0.25, 0.75],
            step=0.01,
            groupby=["grp"],
          ),
        ),
      ]),
    ),
    "[{\"quantile\":\"val\",\"as\":[\"q\",\"v\"],\"probs\":[0.25,0.75],\"step\":0.01,\"groupby\":[\"grp\"]}]",
  )
}

///|
test "VegaRegressionTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Regression(
          @chart.VegaRegressionTransform::VegaRegressionTransform(
            regression="val",
            on="ts",
            as_=["f", "d"],
            extent=[0.0, 1.0],
            method_=@chart.VegaRegressionMethod::Poly,
            order=2,
            groupby=["grp"],
            params=true,
          ),
        ),
      ]),
    ),
    "[{\"regression\":\"val\",\"on\":\"ts\",\"as\":[\"f\",\"d\"],\"extent\":[0,1],\"method\":\"poly\",\"order\":2,\"groupby\":[\"grp\"],\"params\":true}]",
  )
}

///|
test "VegaSampleTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Sample(
          @chart.VegaSampleTransform::VegaSampleTransform(sample=100),
        ),
      ]),
    ),
    "[{\"sample\":100}]",
  )
}

///|
test "VegaStackTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Stack(
          @chart.VegaStackTransform::VegaStackTransform(
            stack="val",
            groupby=["cat"],
            as_=@chart.VegaAsField::Pair("lo", "hi"),
            offset=@chart.VegaStackOffset::Normalize,
            sort=[
              @chart.VegaSortField::VegaSortField(
                field="ts",
                order=@chart.VegaSort::Descending,
              ),
            ],
          ),
        ),
      ]),
    ),
    "[{\"stack\":\"val\",\"groupby\":[\"cat\"],\"as\":[\"lo\",\"hi\"],\"offset\":\"normalize\",\"sort\":[{\"field\":\"ts\",\"order\":\"descending\"}]}]",
  )
}

///|
test "VegaTimeUnitTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::TimeUnit(
          @chart.VegaTimeUnitTransform::VegaTimeUnitTransform(
            time_unit=@chart.VegaTimeUnit::Month,
            field="ts",
            as_="month",
          ),
        ),
      ]),
    ),
    "[{\"timeUnit\":\"month\",\"field\":\"ts\",\"as\":\"month\"}]",
  )
}

///|
test "VegaWindowTransform emits its every property under its schema keys" {
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Window(
          @chart.VegaWindowTransform::VegaWindowTransform(
            window=[
              @chart.VegaWindowField::VegaWindowField(
                op=@chart.VegaWindowFieldOp::Aggregate(
                  @chart.VegaAggregate::Sum,
                ),
                field="val",
                as_="running",
              ),
            ],
            groupby=["grp"],
            sort=[
              @chart.VegaSortField::VegaSortField(
                field="ts",
                order=@chart.VegaSort::Ascending,
              ),
            ],
            frame=(@chart.VegaFrameLimit::Open, @chart.VegaFrameLimit::Num(0)),
            ignore_peers=true,
          ),
        ),
      ]),
    ),
    "[{\"window\":[{\"op\":\"sum\",\"field\":\"val\",\"as\":\"running\"}],\"groupby\":[\"grp\"],\"sort\":[{\"field\":\"ts\",\"order\":\"ascending\"}],\"frame\":[null,0],\"ignorePeers\":true}]",
  )
}

///|
test "each window-only op emits the schema's own string" {
  // The schema's WindowOnlyOp list, one line per variant with the exact
  // string it must emit — the same table shape the aggregate table
  // uses, so a variant and its spelling live one line apart.
  let table : Array[(@chart.VegaWindowOnlyOp, String)] = [
    (RowNumber, "row_number"),
    (Rank, "rank"),
    (DenseRank, "dense_rank"),
    (PercentRank, "percent_rank"),
    (CumeDist, "cume_dist"),
    (Ntile, "ntile"),
    (Lag, "lag"),
    (Lead, "lead"),
    (FirstValue, "first_value"),
    (LastValue, "last_value"),
    (NthValue, "nth_value"),
  ]
  for entry in table {
    let (op, expected) = entry
    assert_eq(
      transform_array(
        with_transforms([
          @chart.VegaTransform::Window(
            @chart.VegaWindowTransform::VegaWindowTransform(window=[
              @chart.VegaWindowField::VegaWindowField(
                op=@chart.VegaWindowFieldOp::WindowOnly(op),
                as_="out",
              ),
            ]),
          ),
        ]),
      ),
      "[{\"window\":[{\"op\":\"" + expected + "\",\"as\":\"out\"}]}]",
    )
  }
}

///|
test "a window field carries the window functions' numeric parameter" {
  // lag / lead / nth_value take a param (the offset or the index), and
  // the field-less forms (rank and kin) carry no field key.
  assert_eq(
    transform_array(
      with_transforms([
        @chart.VegaTransform::Window(
          @chart.VegaWindowTransform::VegaWindowTransform(window=[
            @chart.VegaWindowField::VegaWindowField(
              op=@chart.VegaWindowFieldOp::WindowOnly(Lag),
              field="val",
              as_="previous",
              param=1,
            ),
            @chart.VegaWindowField::VegaWindowField(
              op=@chart.VegaWindowFieldOp::WindowOnly(Rank),
              as_="rank",
            ),
          ]),
        ),
      ]),
    ),
    "[{\"window\":[{\"op\":\"lag\",\"field\":\"val\",\"as\":\"previous\",\"param\":1},{\"op\":\"rank\",\"as\":\"rank\"}]}]",
  )
}

///|
test "every predicate arm emits its own shape" {
  let cases = [
    (@chart.VegaPredicate::Expr("datum.a"), "\"datum.a\""),
    (@chart.VegaPredicate::Param("brush"), "{\"param\":\"brush\"}"),
    (
      @chart.VegaPredicate::Equal("cat", Json::string("x"), None),
      "{\"field\":\"cat\",\"equal\":\"x\"}",
    ),
    (
      @chart.VegaPredicate::Equal(
        "ts",
        Json::number(1),
        Some(@chart.VegaTimeUnit::Month),
      ),
      "{\"field\":\"ts\",\"equal\":1,\"timeUnit\":\"month\"}",
    ),
    (
      @chart.VegaPredicate::Lt("val", Json::number(5), None),
      "{\"field\":\"val\",\"lt\":5}",
    ),
    (
      @chart.VegaPredicate::Lte("val", Json::number(5), None),
      "{\"field\":\"val\",\"lte\":5}",
    ),
    (
      @chart.VegaPredicate::Gt(
        "val",
        Json::number(5),
        Some(@chart.VegaTimeUnit::Year),
      ),
      "{\"field\":\"val\",\"gt\":5,\"timeUnit\":\"year\"}",
    ),
    (
      @chart.VegaPredicate::Gte("val", Json::number(5), None),
      "{\"field\":\"val\",\"gte\":5}",
    ),
    // The comparison bound is the schema's number | string | DateTime
    // union, so a string bound passes through like Equal's does.
    (
      @chart.VegaPredicate::Lt("cat", Json::string("m"), None),
      "{\"field\":\"cat\",\"lt\":\"m\"}",
    ),
    (
      @chart.VegaPredicate::Gte("cat", Json::string("m"), None),
      "{\"field\":\"cat\",\"gte\":\"m\"}",
    ),
    (
      @chart.VegaPredicate::Range("val", (0, 10), None),
      "{\"field\":\"val\",\"range\":[0,10]}",
    ),
    (
      @chart.VegaPredicate::Range("ts", (1, 2), Some(@chart.VegaTimeUnit::Year)),
      "{\"field\":\"ts\",\"range\":[1,2],\"timeUnit\":\"year\"}",
    ),
    (
      @chart.VegaPredicate::one_of("cat", [Json::string("a"), Json::string("b")]),
      "{\"field\":\"cat\",\"oneOf\":[\"a\",\"b\"]}",
    ),
    (
      @chart.VegaPredicate::Valid("val", true, None),
      "{\"field\":\"val\",\"valid\":true}",
    ),
    (
      @chart.VegaPredicate::Not(@chart.VegaPredicate::Valid("val", false, None)),
      "{\"not\":{\"field\":\"val\",\"valid\":false}}",
    ),
    (
      @chart.VegaPredicate::all_of([
        @chart.VegaPredicate::Valid("val", true, None),
        @chart.VegaPredicate::Expr("datum.b"),
      ]),
      "{\"and\":[{\"field\":\"val\",\"valid\":true},\"datum.b\"]}",
    ),
    (
      @chart.VegaPredicate::any_of([
        @chart.VegaPredicate::Valid("val", true, None),
        @chart.VegaPredicate::Param("p"),
      ]),
      "{\"or\":[{\"field\":\"val\",\"valid\":true},{\"param\":\"p\"}]}",
    ),
  ]
  for c in cases {
    let (predicate, expected) = c
    let spec = @chart.format_vega_lite(
      transforms_df(),
      @chart.Chart::of(
        @chart.ChartSpec::of(
          @chart.ChartKind::Bar,
          x=@chart.field("cat"),
          y=@chart.field("val"),
          transform=[
            @chart.VegaTransform::Filter(
              @chart.VegaFilterTransform::VegaFilterTransform(filter=predicate),
            ),
          ],
        ),
      ),
    )
    assert_eq(transform_array(spec), "[{\"filter\":" + expected + "}]")
  }
}

///|
test "the predicate and transform arrays are copied at construction" {
  let values = [Json::number(1)]
  let predicate = @chart.VegaPredicate::one_of("cat", values)
  values.set(0, Json::number(9))
  // The builder copied; the emitted oneOf still reads 1.
  let spec = with_transforms([
    @chart.VegaTransform::Filter(
      @chart.VegaFilterTransform::VegaFilterTransform(filter=predicate),
    ),
  ])
  assert_true(spec.contains("\"oneOf\":[1]"))
  let predicates = [
    @chart.VegaPredicate::Valid("val", true, None),
    @chart.VegaPredicate::Expr("datum.b"),
  ]
  let combined = @chart.VegaPredicate::all_of(predicates)
  predicates.set(1, @chart.VegaPredicate::Expr("datum.c"))
  let combined_spec = with_transforms([
    @chart.VegaTransform::Filter(
      @chart.VegaFilterTransform::VegaFilterTransform(filter=combined),
    ),
  ])
  assert_true(combined_spec.contains("datum.b"))
  // A chart's transform pipeline is copied, and read back copied again.
  let pipeline = [
    @chart.VegaTransform::Sample(
      @chart.VegaSampleTransform::VegaSampleTransform(sample=5),
    ),
  ]
  let chart = @chart.ChartSpec::of(
    @chart.ChartKind::Bar,
    x=@chart.field("cat"),
    y=@chart.field("val"),
    transform=pipeline,
  )
  pipeline.set(
    0,
    @chart.VegaTransform::Sample(
      @chart.VegaSampleTransform::VegaSampleTransform(sample=99),
    ),
  )
  assert_true(chart.transform() is Some([_, ..]))
  ignore(chart.transform().unwrap().copy())
  match chart.transform() {
    Some(ts) => {
      ts.set(
        0,
        @chart.VegaTransform::Sample(
          @chart.VegaSampleTransform::VegaSampleTransform(sample=99),
        ),
      )
      match chart.transform().unwrap()[0] {
        Sample(t) => assert_eq(t.sample, 5)
        _ => fail("expected the unmutated sample transform")
      }
    }
    None => fail("transform pipeline missing")
  }
}

///|
test "a composition carries its own transform pipeline" {
  let spec = @chart.format_vega_lite(
    transforms_df(),
    @chart.Chart::Layer(
      @chart.VegaLayer::VegaLayer(
        [
          @chart.Chart::of(
            @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
          ),
        ],
        transform=[
          @chart.VegaTransform::Filter(
            @chart.VegaFilterTransform::VegaFilterTransform(
              filter=@chart.VegaPredicate::Valid("val", true, None),
            ),
          ),
        ],
      ),
    ),
  )
  // The layer's transform sits beside its layer array — the composition
  // runs the pipeline before its children render.
  assert_true(spec.contains("\"layer\":[{\"mark\":\"bar\""))
  assert_true(
    spec.contains(
      "],\"transform\":[{\"filter\":{\"field\":\"val\",\"valid\":true}}]",
    ),
  )
}

///|
test "each VegaStackOffset variant emits the schema's offset string" {
  let cases = [
    (@chart.VegaStackOffset::Zero, "zero"),
    (@chart.VegaStackOffset::Center, "center"),
    (@chart.VegaStackOffset::Normalize, "normalize"),
  ]
  for c in cases {
    let (offset, expected) = c
    assert_eq(
      transform_array(
        with_transforms([
          @chart.VegaTransform::Stack(
            @chart.VegaStackTransform::VegaStackTransform(
              stack="val",
              groupby=["cat"],
              as_=@chart.VegaAsField::One("stacked"),
              offset~,
            ),
          ),
        ]),
      ),
      "[{\"stack\":\"val\",\"groupby\":[\"cat\"],\"as\":\"stacked\",\"offset\":\"\{expected}\"}]",
    )
  }
}

///|
test "each VegaImputeMethod variant emits the schema's method string" {
  let cases = [
    (@chart.VegaImputeMethod::Value, "value"),
    (@chart.VegaImputeMethod::Median, "median"),
    (@chart.VegaImputeMethod::Max, "max"),
    (@chart.VegaImputeMethod::Min, "min"),
    (@chart.VegaImputeMethod::Mean, "mean"),
  ]
  for c in cases {
    let (method_, expected) = c
    assert_eq(
      transform_array(
        with_transforms([
          @chart.VegaTransform::Impute(
            @chart.VegaImputeTransform::VegaImputeTransform(
              impute="val",
              key="ts",
              method_~,
            ),
          ),
        ]),
      ),
      "[{\"impute\":\"val\",\"key\":\"ts\",\"method\":\"\{expected}\"}]",
    )
  }
}

///|
test "each VegaRegressionMethod variant emits the schema's method string" {
  let cases = [
    (@chart.VegaRegressionMethod::Linear, "linear"),
    (@chart.VegaRegressionMethod::Log, "log"),
    (@chart.VegaRegressionMethod::Exp, "exp"),
    (@chart.VegaRegressionMethod::Pow, "pow"),
    (@chart.VegaRegressionMethod::Quad, "quad"),
    (@chart.VegaRegressionMethod::Poly, "poly"),
  ]
  for c in cases {
    let (method_, expected) = c
    assert_eq(
      transform_array(
        with_transforms([
          @chart.VegaTransform::Regression(
            @chart.VegaRegressionTransform::VegaRegressionTransform(
              regression="val",
              on="ts",
              method_~,
            ),
          ),
        ]),
      ),
      "[{\"regression\":\"val\",\"on\":\"ts\",\"method\":\"\{expected}\"}]",
    )
  }
}

///|
test "a density transform resolves its densities independently or shared" {
  let independent = transform_array(
    with_transforms([
      @chart.VegaTransform::Density(
        @chart.VegaDensityTransform::VegaDensityTransform(
          density="val",
          resolve=@chart.VegaResolveMode::Independent,
        ),
      ),
    ]),
  )
  assert_eq(independent, "[{\"density\":\"val\",\"resolve\":\"independent\"}]")
  let shared = transform_array(
    with_transforms([
      @chart.VegaTransform::Density(
        @chart.VegaDensityTransform::VegaDensityTransform(
          density="val",
          resolve=@chart.VegaResolveMode::Shared,
        ),
      ),
    ]),
  )
  assert_eq(shared, "[{\"density\":\"val\",\"resolve\":\"shared\"}]")
}
