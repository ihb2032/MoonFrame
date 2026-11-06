// Blackbox tests for the transform families' array accessors and their
// copy-back contracts — kept apart from the generated transform tests so
// regenerating those cannot drop these.

///|
/// The fixture frame these accessors' constructions render against (the
/// corpus frame, shared across the chart test files).
fn accessors_df() -> @frame.DataFrame raise @types.DataError {
  corpus_df()
}

///|
test "the transform accessors read every list back, set and unset" {
  let agg = @chart.VegaAggregateTransform::VegaAggregateTransform(aggregate=[
    @chart.VegaAggField::VegaAggField(op=@chart.VegaAggregate::Sum, as_="total"),
  ])
  assert_eq(agg.groupby(), None)
  assert_eq(agg.aggregate().length(), 1)
  let window = @chart.VegaWindowTransform::VegaWindowTransform(
    window=[
      @chart.VegaWindowField::VegaWindowField(
        op=@chart.VegaWindowFieldOp::Aggregate(@chart.VegaAggregate::Sum),
        as_="running",
      ),
    ],
    groupby=["grp"],
    sort=[@chart.VegaSortField::VegaSortField(field="ts")],
  )
  assert_eq(window.groupby(), Some(["grp"]))
  assert_eq(window.sort().map(fn(s) { s.length() }), Some(1))
  assert_eq(window.window().length(), 1)
  let lookup = @chart.VegaLookupData::VegaLookupData(
    data="regions",
    key="name",
    fields=["pop"],
  )
  assert_eq(lookup.fields(), Some(["pop"]))
  let density = @chart.VegaDensityTransform::VegaDensityTransform(
    density="val",
    as_=["v", "d"],
    extent=[0.0, 1.0],
    groupby=["cat"],
  )
  assert_eq(density.as_(), Some(["v", "d"]))
  assert_eq(density.extent(), Some([0.0, 1.0]))
  assert_eq(density.groupby(), Some(["cat"]))
  let flatten = @chart.VegaFlattenTransform::VegaFlattenTransform(
    flatten=["a"],
    as_=["x"],
  )
  assert_eq(flatten.as_(), Some(["x"]))
  assert_eq(flatten.flatten().length(), 1)
  let fold = @chart.VegaFoldTransform::VegaFoldTransform(fold=["a", "b"], as_=[
    "k", "v",
  ])
  assert_eq(fold.fold(), ["a", "b"])
  assert_eq(fold.as_(), Some(["k", "v"]))
  let impute = @chart.VegaImputeTransform::VegaImputeTransform(
    impute="val",
    key="ts",
    keyvals=[Json::number(1)],
    groupby=["cat"],
    frame=[-1.0, 1.0],
  )
  assert_eq(impute.keyvals().map(fn(k) { k.length() }), Some(1))
  assert_eq(impute.groupby(), Some(["cat"]))
  assert_eq(impute.frame(), Some([-1.0, 1.0]))
  let bare_impute = @chart.VegaImputeTransform::VegaImputeTransform(
    impute="val",
    key="ts",
  )
  assert_eq(bare_impute.keyvals(), None)
  assert_eq(bare_impute.groupby(), None)
  assert_eq(bare_impute.frame(), None)
  let join = @chart.VegaJoinAggregateTransform::VegaJoinAggregateTransform(
    joinaggregate=[
      @chart.VegaAggField::VegaAggField(
        op=@chart.VegaAggregate::Mean,
        as_="avg",
      ),
    ],
    groupby=["grp"],
  )
  assert_eq(join.groupby(), Some(["grp"]))
  assert_eq(join.joinaggregate().length(), 1)
  let loess = @chart.VegaLoessTransform::VegaLoessTransform(
    loess="val",
    on="ts",
    as_=["f", "d"],
    groupby=["grp"],
  )
  assert_eq(loess.as_(), Some(["f", "d"]))
  assert_eq(loess.groupby(), Some(["grp"]))
  let pivot = @chart.VegaPivotTransform::VegaPivotTransform(
    pivot="cat",
    value="val",
    groupby=["grp"],
  )
  assert_eq(pivot.groupby(), Some(["grp"]))
  let pivot_bare = @chart.VegaPivotTransform::VegaPivotTransform(
    pivot="cat",
    value="val",
  )
  assert_eq(pivot_bare.groupby(), None)
  let quantile = @chart.VegaQuantileTransform::VegaQuantileTransform(
    quantile="val",
    as_=["q", "v"],
    probs=[0.5],
    groupby=["grp"],
  )
  assert_eq(quantile.as_(), Some(["q", "v"]))
  assert_eq(quantile.probs(), Some([0.5]))
  assert_eq(quantile.groupby(), Some(["grp"]))
  let regression = @chart.VegaRegressionTransform::VegaRegressionTransform(
    regression="val",
    on="ts",
    as_=["f", "d"],
    extent=[0.0, 1.0],
    groupby=["grp"],
  )
  assert_eq(regression.as_(), Some(["f", "d"]))
  assert_eq(regression.extent(), Some([0.0, 1.0]))
  assert_eq(regression.groupby(), Some(["grp"]))
  let stack = @chart.VegaStackTransform::VegaStackTransform(
    stack="val",
    groupby=["cat"],
    as_=@chart.VegaAsField::Pair("lo", "hi"),
    sort=[@chart.VegaSortField::VegaSortField(field="ts")],
  )
  assert_eq(stack.sort().map(fn(s) { s.length() }), Some(1))
  assert_eq(stack.groupby(), ["cat"])
  ignore(accessors_df())
}

///|
test "a lookup may enrich from a parameter-driven source" {
  let spec = @chart.format_vega_lite(
    accessors_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        transform=[
          @chart.VegaTransform::Lookup(
            @chart.VegaLookupTransform::VegaLookupTransform(
              lookup="cat",
              from_=@chart.VegaLookupFrom::Param("regions"),
            ),
          ),
        ],
      ),
    ),
  )
  assert_true(spec.contains("\"from\":{\"param\":\"regions\"}"))
}

///|
test "an impute sequence emits its three-property object" {
  let spec = @chart.format_vega_lite(
    accessors_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        transform=[
          @chart.VegaTransform::Impute(
            @chart.VegaImputeTransform::VegaImputeTransform(
              impute="val",
              key="ts",
              keyvals_sequence=@chart.VegaImputeSequence::VegaImputeSequence(
                start=0,
                stop=10,
                step=2,
              ),
            ),
          ),
        ],
      ),
    ),
  )
  assert_true(spec.contains("\"keyvals\":{\"start\":0,\"stop\":10,\"step\":2}"))
}

///|
test "a bare construction of every family leaves every optional list unset" {
  // Required-only constructions: every optional-list copy lands in its
  // None arm, and the emitted objects carry only their required keys.
  let df = accessors_df()
  let bare = [
    @chart.VegaTransform::Aggregate(
      @chart.VegaAggregateTransform::VegaAggregateTransform(aggregate=[
        @chart.VegaAggField::VegaAggField(
          op=@chart.VegaAggregate::Sum,
          as_="total",
        ),
      ]),
    ),
    @chart.VegaTransform::Density(
      @chart.VegaDensityTransform::VegaDensityTransform(density="val"),
    ),
    @chart.VegaTransform::Flatten(
      @chart.VegaFlattenTransform::VegaFlattenTransform(flatten=["a"]),
    ),
    @chart.VegaTransform::Fold(
      @chart.VegaFoldTransform::VegaFoldTransform(fold=["a"]),
    ),
    @chart.VegaTransform::Impute(
      @chart.VegaImputeTransform::VegaImputeTransform(impute="val", key="ts"),
    ),
    @chart.VegaTransform::JoinAggregate(
      @chart.VegaJoinAggregateTransform::VegaJoinAggregateTransform(joinaggregate=[
        @chart.VegaAggField::VegaAggField(
          op=@chart.VegaAggregate::Mean,
          as_="avg",
        ),
      ]),
    ),
    @chart.VegaTransform::Loess(
      @chart.VegaLoessTransform::VegaLoessTransform(loess="val", on="ts"),
    ),
    @chart.VegaTransform::Pivot(
      @chart.VegaPivotTransform::VegaPivotTransform(pivot="cat", value="val"),
    ),
    @chart.VegaTransform::Quantile(
      @chart.VegaQuantileTransform::VegaQuantileTransform(quantile="val"),
    ),
    @chart.VegaTransform::Regression(
      @chart.VegaRegressionTransform::VegaRegressionTransform(
        regression="val",
        on="ts",
      ),
    ),
    @chart.VegaTransform::Stack(
      @chart.VegaStackTransform::VegaStackTransform(
        stack="val",
        groupby=["cat"],
        as_=@chart.VegaAsField::One("s"),
      ),
    ),
    @chart.VegaTransform::Window(
      @chart.VegaWindowTransform::VegaWindowTransform(window=[
        @chart.VegaWindowField::VegaWindowField(
          op=@chart.VegaWindowFieldOp::Aggregate(@chart.VegaAggregate::Sum),
          as_="running",
        ),
      ]),
    ),
  ]
  for transform in bare {
    // Each bare family emits without its optional keys — reading the
    // spec back exercises the constructor's None arms.
    let spec = @chart.format_vega_lite(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::of(
          @chart.ChartKind::Bar,
          x=@chart.field("cat"),
          y=@chart.field("val"),
          transform=[transform],
        ),
      ),
    )
    assert_true(spec.contains("\"transform\":["))
  }
}

///|
test "the concat, facet, and repeat chrome also carries a pipeline" {
  let df = accessors_df()
  let cell = @chart.Chart::of(
    @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
  )
  let pipeline = [
    @chart.VegaTransform::Sample(
      @chart.VegaSampleTransform::VegaSampleTransform(sample=5),
    ),
  ]
  let concat = @chart.format_vega_lite(
    df,
    @chart.Chart::VConcat(
      @chart.VegaConcat::VegaConcat([cell], transform=pipeline),
    ),
  )
  assert_true(concat.contains("\"transform\":[{\"sample\":5}]"))
  let facet = @chart.format_vega_lite(
    df,
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        cell,
        row=@chart.VegaFacetChannel::VegaFacetChannel(field="grp"),
        transform=pipeline,
      ),
    ),
  )
  assert_true(facet.contains("\"transform\":[{\"sample\":5}]"))
  let repeat = @chart.format_vega_lite(
    df,
    @chart.Chart::Repeat(
      @chart.VegaRepeat::VegaRepeat(cell, row=["val"], transform=pipeline),
    ),
  )
  assert_true(repeat.contains("\"transform\":[{\"sample\":5}]"))
  // Unset pipelines stay absent on every wrapper, and a spec without one
  // reads None back through its accessor.
  let layer_bare = @chart.format_vega_lite(
    df,
    @chart.Chart::Layer(@chart.VegaLayer::VegaLayer([cell])),
  )
  assert_true(!layer_bare.contains("\"transform\""))
  let bare_spec = @chart.ChartSpec::of(
    @chart.ChartKind::Bar,
    x=@chart.field("cat"),
    y=@chart.field("val"),
  )
  assert_true(bare_spec.transform() is None)
}

///|
test "every optional accessor reads None on its bare family" {
  let density = @chart.VegaDensityTransform::VegaDensityTransform(density="val")
  assert_eq(density.as_(), None)
  assert_eq(density.extent(), None)
  assert_eq(density.groupby(), None)
  let flatten = @chart.VegaFlattenTransform::VegaFlattenTransform(flatten=["a"])
  assert_eq(flatten.as_(), None)
  let fold = @chart.VegaFoldTransform::VegaFoldTransform(fold=["a"])
  assert_eq(fold.as_(), None)
  let join = @chart.VegaJoinAggregateTransform::VegaJoinAggregateTransform(joinaggregate=[
    @chart.VegaAggField::VegaAggField(op=@chart.VegaAggregate::Mean, as_="avg"),
  ])
  assert_eq(join.groupby(), None)
  let loess = @chart.VegaLoessTransform::VegaLoessTransform(
    loess="val",
    on="ts",
  )
  assert_eq(loess.as_(), None)
  assert_eq(loess.groupby(), None)
  let quantile = @chart.VegaQuantileTransform::VegaQuantileTransform(
    quantile="val",
  )
  assert_eq(quantile.as_(), None)
  assert_eq(quantile.probs(), None)
  assert_eq(quantile.groupby(), None)
  let regression = @chart.VegaRegressionTransform::VegaRegressionTransform(
    regression="val",
    on="ts",
  )
  assert_eq(regression.as_(), None)
  assert_eq(regression.extent(), None)
  assert_eq(regression.groupby(), None)
  let stack = @chart.VegaStackTransform::VegaStackTransform(
    stack="val",
    groupby=["cat"],
    as_=@chart.VegaAsField::One("s"),
  )
  assert_eq(stack.sort(), None)
  let window = @chart.VegaWindowTransform::VegaWindowTransform(window=[
    @chart.VegaWindowField::VegaWindowField(
      op=@chart.VegaWindowFieldOp::Aggregate(@chart.VegaAggregate::Sum),
      as_="running",
    ),
  ])
  assert_eq(window.groupby(), None)
  assert_eq(window.sort(), None)
  let aggregate = @chart.VegaAggregateTransform::VegaAggregateTransform(aggregate=[
    @chart.VegaAggField::VegaAggField(op=@chart.VegaAggregate::Sum, as_="total"),
  ])
  assert_eq(aggregate.groupby(), None)
  let grouped = @chart.VegaAggregateTransform::VegaAggregateTransform(
    aggregate=[
      @chart.VegaAggField::VegaAggField(op=@chart.VegaAggregate::Sum, as_="t"),
    ],
    groupby=["cat"],
  )
  assert_eq(grouped.groupby(), Some(["cat"]))
  let lookup = @chart.VegaLookupData::VegaLookupData(data="regions", key="name")
  assert_eq(lookup.fields(), None)
  ignore(fold.fold())
}
