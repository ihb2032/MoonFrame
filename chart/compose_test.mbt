// Blackbox tests for the composition layer: each operator's emitted
// shape, nesting, the shared frame, the array-ownership contracts on the
// child lists, and the facet channel's column resolution. The corpus
// beside this walks whole compositions against the vendored schema.

///|
/// The fixture frame the composition tests render against.
fn compose_df() -> @frame.DataFrame raise @types.DataError {
  corpus_df()
}

///|
test "a layer emits one shared coordinate system, chrome outside" {
  let spec = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::Layer(
      @chart.VegaLayer::VegaLayer(
        [
          @chart.Chart::of(
            @chart.ChartSpec::point(@chart.field("val"), @chart.field("val")),
          ),
          @chart.Chart::of(
            @chart.ChartSpec::line(@chart.field("val"), @chart.field("val")),
          ),
        ],
        title=@chart.VegaTitle::Text("Correlation"),
        width=@chart.VegaExtent::Px(300),
        resolve=@chart.VegaResolve::VegaResolve(
          legend=@chart.VegaLegendResolve::VegaLegendResolve(
            color=@chart.VegaResolveMode::Independent,
          ),
        ),
      ),
    ),
  )
  // The children carry mark and encoding only — no `$schema`, no `data`:
  // both belong to the top level, and the data is inlined once.
  assert_true(spec.contains("\"layer\":[{\"mark\":\"point\""))
  assert_true(spec.contains("{\"mark\":\"line\""))
  assert_true(spec.contains("\"title\":\"Correlation\""))
  assert_true(spec.contains("\"width\":300"))
  assert_true(spec.contains("\"legend\":{\"color\":\"independent\"}"))
  assert_eq(spec.split("\"$schema\"").count(), 2)
  assert_eq(spec.split("\"data\"").count(), 2)
}

///|
test "the concat family emits its three array keys and the wrap layout" {
  let df = compose_df()
  let cell = fn(mark : @chart.ChartKind) -> @chart.Chart {
    @chart.Chart::of(
      @chart.ChartSpec::of(mark, x=@chart.field("cat"), y=@chart.field("val")),
    )
  }
  let v = @chart.format_vega_lite(
    df,
    @chart.Chart::VConcat(
      @chart.VegaConcat::VegaConcat(
        [cell(@chart.ChartKind::Bar), cell(@chart.ChartKind::Line)],
        bounds=@chart.VegaBounds::Flush,
        center=@chart.VegaCenter::All(true),
        spacing=@chart.VegaSpacing::Px(12),
      ),
    ),
  )
  assert_true(v.contains("\"vconcat\":["))
  assert_true(v.contains("\"bounds\":\"flush\""))
  assert_true(v.contains("\"center\":true"))
  assert_true(v.contains("\"spacing\":12"))
  let h = @chart.format_vega_lite(
    df,
    @chart.Chart::HConcat(
      @chart.VegaConcat::VegaConcat(
        [cell(@chart.ChartKind::Bar)],
        align=@chart.VegaAlignMode::Layout(@chart.VegaLayoutAlign::Each),
        columns=2,
      ),
    ),
  )
  // A directional concat's direction fixes alignment and wrap: the two
  // layout props the wrapper may carry are not emitted for it.
  assert_true(h.contains("\"hconcat\":["))
  assert_true(!h.contains("\"align\""))
  assert_true(!h.contains("\"columns\""))
  let wrapped = @chart.format_vega_lite(
    df,
    @chart.Chart::Concat(
      @chart.VegaConcat::VegaConcat(
        [
          cell(@chart.ChartKind::Bar),
          cell(@chart.ChartKind::Point),
          cell(@chart.ChartKind::Tick),
        ],
        align=@chart.VegaAlignMode::Sides(
          @chart.VegaRowColAlign::VegaRowColAlign(
            row=@chart.VegaLayoutAlign::Each,
            column=@chart.VegaLayoutAlign::All,
          ),
        ),
        center=@chart.VegaCenter::Sides(
          @chart.VegaRowColBool::VegaRowColBool(row=false, column=true),
        ),
        spacing=@chart.VegaSpacing::Sides(
          @chart.VegaRowColDouble::VegaRowColDouble(row=8, column=16),
        ),
        columns=2,
      ),
    ),
  )
  assert_true(wrapped.contains("\"concat\":["))
  assert_true(
    wrapped.contains("\"align\":{\"row\":\"each\",\"column\":\"all\"}"),
  )
  assert_true(wrapped.contains("\"center\":{\"row\":false,\"column\":true}"))
  assert_true(wrapped.contains("\"spacing\":{\"row\":8,\"column\":16}"))
  assert_true(wrapped.contains("\"columns\":2"))
}

///|
test "a facet resolves its channels against the frame, then the child" {
  let df = compose_df()
  let ok = @chart.format_vega_lite(
    df,
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
        ),
        row=@chart.VegaFacetChannel::VegaFacetChannel(
          field="grp",
          header=@chart.VegaHeader::VegaHeader(
            title="Group",
            label_angle=-30.0,
            orient=@chart.VegaOrient::Left,
          ),
        ),
        column=@chart.VegaFacetChannel::VegaFacetChannel(
          field="cat",
          sort=@chart.VegaChannelSort::Ascending,
        ),
        spacing=@chart.VegaSpacing::Px(10),
        columns=2,
      ),
    ),
  )
  assert_true(
    ok.contains(
      "\"facet\":{\"row\":{\"field\":\"grp\",\"type\":\"nominal\",\"header\":{\"labelAngle\":-30,\"orient\":\"left\",\"title\":\"Group\"}},\"column\":{\"field\":\"cat\",\"type\":\"nominal\",\"sort\":\"ascending\"}}",
    ),
  )
  assert_true(ok.contains("\"spacing\":10"))
  assert_true(ok.contains("\"spec\":{\"mark\":\"bar\""))
  assert_true(ok.contains("\"columns\":2"))
  // A facet channel naming a missing column raises before the child
  // renders — the facet sibling of the encoding resolution.
  let result = Ok(
    @chart.format_vega_lite(
      df,
      @chart.Chart::Facet(
        @chart.VegaFacet::VegaFacet(
          @chart.Chart::of(
            @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
          ),
          row=@chart.VegaFacetChannel::VegaFacetChannel(field="nofacet"),
        ),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_eq(result, Err(@types.DataError::ColumnNotFound("nofacet")))
}

///|
test "a facet channel's by-channel sort raises rather than emits" {
  // The facet host has no bare-channel sort form (FacetFieldDef.sort is
  // an order, a field, an explicit list, or null), so ByChannel is
  // refused loudly instead of shipping a spec the schema would reject.
  let result = Ok(
    @chart.format_vega_lite(
      compose_df(),
      @chart.Chart::Facet(
        @chart.VegaFacet::VegaFacet(
          @chart.Chart::of(
            @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
          ),
          row=@chart.VegaFacetChannel::VegaFacetChannel(
            field="grp",
            sort=@chart.VegaChannelSort::ByChannel(
              @chart.VegaSortChannel::X,
              Some(true),
            ),
          ),
        ),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::InvalidOperation(_)))
}

///|
test "a count facet channel reads no column and carries no type" {
  let spec = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
        ),
        row=@chart.VegaFacetChannel::VegaFacetChannel(
          field="anything",
          aggregate=@chart.VegaAggregate::Count,
          title="Rows",
        ),
      ),
    ),
  )
  assert_true(
    spec.contains(
      "\"facet\":{\"row\":{\"aggregate\":\"count\",\"title\":\"Rows\"}}",
    ),
  )
}

///|
test "a facet channel without a field resolves no column" {
  // Neither a count aggregate nor a field: nothing to resolve, nothing
  // to emit for the channel's own definition (the schema would reject
  // the spec; the emission simply carries no keys).
  let spec = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
        ),
        row=@chart.VegaFacetChannel::VegaFacetChannel(title="Rows"),
      ),
    ),
  )
  assert_true(spec.contains("\"facet\":{\"row\":{\"title\":\"Rows\"}}"))
}

///|
test "a repeat emits its field lists and the child spec" {
  let row = ["val"]
  let spec = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::Repeat(
      @chart.VegaRepeat::VegaRepeat(
        @chart.Chart::of(
          @chart.ChartSpec::line(@chart.field("cat"), @chart.field("val")),
        ),
        row~,
        column=["val", "ts"],
        spacing=@chart.VegaSpacing::Px(6),
      ),
    ),
  )
  row.set(0, "mutated")
  assert_true(
    spec.contains("\"repeat\":{\"row\":[\"val\"],\"column\":[\"val\",\"ts\"]}"),
  )
  assert_true(spec.contains("\"spec\":{\"mark\":\"line\""))
  assert_true(spec.contains("\"spacing\":6"))
}

///|
test "compositions nest: a concat whose child is a layer" {
  let df = compose_df()
  let layered = @chart.Chart::Layer(
    @chart.VegaLayer::VegaLayer([
      @chart.Chart::of(
        @chart.ChartSpec::point(@chart.field("val"), @chart.field("val")),
      ),
      @chart.Chart::of(
        @chart.ChartSpec::line(@chart.field("val"), @chart.field("val")),
      ),
    ]),
  )
  let spec = @chart.format_vega_lite(
    df,
    @chart.Chart::VConcat(
      @chart.VegaConcat::VegaConcat([
        layered,
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
        ),
      ]),
    ),
  )
  assert_true(spec.contains("\"vconcat\":[{\"layer\":["))
  // The nested layer carries no data of its own either — the frame is
  // inlined exactly once, at the top.
  assert_eq(spec.split("\"data\"").count(), 2)
}

///|
test "a layer member drops the chrome its UnitSpec host disallows" {
  // A spec built with the full top-level chrome (width, autosize,
  // background, padding, config, usermeta) keeps all of it at the top
  // level and none of it as a `layer` member: the schema's `UnitSpec`
  // carries mark, encoding, name, description, title, projection,
  // transform, and params alone, so the rest is filtered at emission
  // rather than shipped as a spec the schema would reject.
  let spec = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::Layer(
      @chart.VegaLayer::VegaLayer([
        @chart.Chart::of(
          @chart.ChartSpec::of(
            @chart.ChartKind::Bar,
            x=@chart.field("cat"),
            y=@chart.field("val"),
            name="child",
            description="a chrome-heavy member",
            title=@chart.VegaTitle::Text("Child"),
            width=@chart.VegaExtent::Px(400),
            height=@chart.VegaExtent::Step(20),
            autosize=@chart.VegaAutoSize::Fit,
            background="#123456",
            padding=@chart.VegaPadding::Px(5),
            config=@chart.VegaConfig::VegaConfig(background="#654321"),
            usermeta=Json::object({ "k": Json::string("v") }),
          ),
        ),
        @chart.Chart::of(
          @chart.ChartSpec::line(@chart.field("val"), @chart.field("val")),
        ),
      ]),
    ),
  )
  // The member keeps its allowed chrome…
  assert_true(spec.contains("\"layer\":[{\"name\":\"child\""))
  assert_true(spec.contains("\"description\":\"a chrome-heavy member\""))
  assert_true(spec.contains("\"title\":\"Child\""))
  assert_true(spec.contains("\"mark\":\"bar\""))
  // …and none of the host-disallowed keys appear anywhere.
  assert_eq(spec.split("\"width\"").count(), 1)
  assert_eq(spec.split("\"height\"").count(), 1)
  assert_true(!spec.contains("\"autosize\""))
  assert_true(!spec.contains("\"background\""))
  assert_true(!spec.contains("\"padding\""))
  assert_true(!spec.contains("\"config\""))
  assert_true(!spec.contains("\"usermeta\""))
}

///|
test "a facet child keeps the view frame and drops top-level chrome" {
  // The facet host (the schema's `FacetedUnitSpec`) allows `width` /
  // `height` / `view` on its child — the panels size themselves — but
  // not `autosize` / `background` / `padding` / `config` / `usermeta`,
  // which exist on the top-level specs alone.
  let spec = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        @chart.Chart::of(
          @chart.ChartSpec::of(
            @chart.ChartKind::Bar,
            x=@chart.field("cat"),
            y=@chart.field("val"),
            width=@chart.VegaExtent::Px(150),
            view=@chart.VegaViewBackground::VegaViewBackground(fill="#eee"),
            autosize=@chart.VegaAutoSize::FitX,
            config=@chart.VegaConfig::VegaConfig(background="#000000"),
            usermeta=Json::object({ "k": Json::string("v") }),
          ),
        ),
        row=@chart.VegaFacetChannel::VegaFacetChannel(field="grp"),
      ),
    ),
  )
  assert_true(spec.contains("\"spec\":{\"width\":150"))
  assert_true(spec.contains("\"view\":{\"fill\":\"#eee\"}"))
  assert_true(!spec.contains("\"autosize\""))
  assert_true(!spec.contains("\"config\""))
  assert_true(!spec.contains("\"usermeta\""))
}

///|
test "a nested child's selection params drop their views key" {
  // `views` (which facet views a selection spans) exists only on the
  // top-level selection-parameter form; a child spec's params are the
  // plain form, so the key is stripped when the same spec nests.
  let params = [
    @chart.VegaParam::Selection(
      @chart.VegaSelectionParam::VegaSelectionParam(
        name="brush",
        select=@chart.VegaSelect::Interval(
          @chart.VegaIntervalSelect::VegaIntervalSelect(encodings=["x"]),
        ),
        views=["view_1", "view_2"],
      ),
    ),
  ]
  let nested = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        @chart.Chart::of(
          @chart.ChartSpec::of(
            @chart.ChartKind::Point,
            x=@chart.field("val"),
            y=@chart.field("val"),
            params~,
          ),
        ),
        row=@chart.VegaFacetChannel::VegaFacetChannel(field="grp"),
      ),
    ),
  )
  assert_true(!nested.contains("\"views\""))
  let top = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field("val"),
        y=@chart.field("val"),
        params~,
      ),
    ),
  )
  assert_true(top.contains("\"views\":[\"view_1\",\"view_2\"]"))
}

///|
test "the child lists and field lists are copied at construction" {
  let children = [
    @chart.Chart::of(
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
    ),
  ]
  let layer = @chart.VegaLayer::VegaLayer(children)
  children.set(
    0,
    @chart.Chart::of(
      @chart.ChartSpec::line(@chart.field("cat"), @chart.field("val")),
    ),
  )
  // The wrapper kept its own copy: the read-back ignores the mutation.
  assert_true(layer.layer()[0] is Single(_))
  let concat_children = [
    @chart.Chart::of(
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
    ),
  ]
  let concat = @chart.VegaConcat::VegaConcat(concat_children)
  concat_children.set(
    0,
    @chart.Chart::of(
      @chart.ChartSpec::line(@chart.field("cat"), @chart.field("val")),
    ),
  )
  assert_true(concat.concat()[0] is Single(_))
  let fields = ["val"]
  let repeat = @chart.VegaRepeat::VegaRepeat(
    @chart.Chart::of(
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
    ),
    row=fields,
  )
  fields.set(0, "mutated")
  assert_eq(repeat.row(), Some(["val"]))
  assert_eq(repeat.column(), None)
}

///|
test "the scale and axis resolve maps emit their set channels" {
  let spec = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::VConcat(
      @chart.VegaConcat::VegaConcat(
        [
          @chart.Chart::of(
            @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
          ),
        ],
        resolve=@chart.VegaResolve::VegaResolve(
          scale=@chart.VegaScaleResolve::VegaScaleResolve(
            x=@chart.VegaResolveMode::Shared,
            y=@chart.VegaResolveMode::Independent,
            color=@chart.VegaResolveMode::Independent,
            theta=@chart.VegaResolveMode::Shared,
            x_offset=@chart.VegaResolveMode::Shared,
          ),
          axis=@chart.VegaAxisResolve::VegaAxisResolve(
            x=@chart.VegaResolveMode::Independent,
          ),
        ),
      ),
    ),
  )
  assert_true(
    spec.contains(
      "\"scale\":{\"x\":\"shared\",\"y\":\"independent\",\"color\":\"independent\",\"theta\":\"shared\",\"xOffset\":\"shared\"}",
    ),
  )
  assert_true(spec.contains("\"axis\":{\"x\":\"independent\"}"))
}

///|
test "Chart::of wraps a single view, and the emission is byte-identical" {
  let df = compose_df()
  let spec = @chart.ChartSpec::bar(
    @chart.field("cat"),
    @chart.field("val"),
    title="T",
  )
  assert_eq(
    @chart.format_vega_lite(df, @chart.Chart::of(spec)),
    @chart.format_vega_lite(df, @chart.Chart::Single(spec)),
  )
}

///|
test "a header carries every property it declares" {
  let spec = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
        ),
        row=@chart.VegaFacetChannel::VegaFacetChannel(
          field="grp",
          header=@chart.VegaHeader::VegaHeader(
            format=".1f",
            format_type="number",
            label_align=@chart.VegaAlign::Left,
            label_anchor=@chart.VegaAnchor::End,
            label_baseline=@chart.VegaBaseline::Middle,
            label_color="#333",
            label_expr="datum.value",
            label_font="sans",
            label_font_size=11,
            label_font_style="italic",
            label_font_weight=@chart.VegaFontWeight::Bold,
            label_limit=90,
            label_line_height=14,
            label_orient=@chart.VegaOrient::Right,
            label_padding=4,
            labels=true,
            orient=@chart.VegaOrient::Bottom,
            title="T",
            title_align=@chart.VegaAlign::Right,
            title_anchor=@chart.VegaAnchor::Start,
            title_angle=15,
            title_baseline=@chart.VegaBaseline::Top,
            title_color="#111",
            title_font="serif",
            title_font_size=13,
            title_font_style="normal",
            title_font_weight=@chart.VegaFontWeight::Weight(400),
            title_limit=100,
            title_line_height=16,
            title_orient=@chart.VegaOrient::Top,
            title_padding=6,
          ),
          band_position=0.5,
        ),
      ),
    ),
  )
  assert_true(spec.contains("\"format\":\".1f\""))
  assert_true(spec.contains("\"formatType\":\"number\""))
  assert_true(spec.contains("\"labelAlign\":\"left\""))
  assert_true(spec.contains("\"labelAnchor\":\"end\""))
  assert_true(spec.contains("\"labelBaseline\":\"middle\""))
  assert_true(spec.contains("\"labelExpr\":\"datum.value\""))
  assert_true(spec.contains("\"labelFontWeight\":\"bold\""))
  assert_true(spec.contains("\"labelOrient\":\"right\""))
  assert_true(spec.contains("\"orient\":\"bottom\""))
  assert_true(spec.contains("\"titleFontWeight\":400"))
  assert_true(spec.contains("\"titleOrient\":\"top\""))
  assert_true(spec.contains("\"bandPosition\":0.5"))
}

///|
test "every operator carries its full chrome" {
  let df = compose_df()
  let cell = @chart.Chart::of(
    @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
  )
  // Layer: the view size / background / projection half.
  let layer = @chart.format_vega_lite(
    df,
    @chart.Chart::Layer(
      @chart.VegaLayer::VegaLayer(
        [cell],
        name="l",
        description="a layer",
        height=@chart.VegaExtent::Px(200),
        view=@chart.VegaViewBackground::VegaViewBackground(fill="#fff"),
        projection=@chart.VegaProjection::VegaProjection(
          type_=@chart.VegaProjectionType::Mercator,
        ),
        resolve=@chart.VegaResolve::VegaResolve(),
      ),
    ),
  )
  assert_true(layer.contains("\"name\":\"l\""))
  assert_true(layer.contains("\"description\":\"a layer\""))
  assert_true(layer.contains("\"height\":200"))
  assert_true(layer.contains("\"view\":{\"fill\":\"#fff\"}"))
  assert_true(layer.contains("\"projection\":{\"type\":\"mercator\"}"))
  assert_true(layer.contains("\"resolve\":{}"))
  // Concat: the wrapped half's chrome, including the title block.
  let concat = @chart.format_vega_lite(
    df,
    @chart.Chart::Concat(
      @chart.VegaConcat::VegaConcat(
        [cell],
        name="c",
        description="a concat",
        title=@chart.VegaTitle::Text("CT"),
        resolve=@chart.VegaResolve::VegaResolve(),
      ),
    ),
  )
  assert_true(concat.contains("\"name\":\"c\""))
  assert_true(concat.contains("\"description\":\"a concat\""))
  assert_true(concat.contains("\"title\":\"CT\""))
  assert_true(concat.contains("\"resolve\":{}"))
  // Facet: the layout half plus chrome, bounds at its default arm.
  let facet = @chart.format_vega_lite(
    df,
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        cell,
        row=@chart.VegaFacetChannel::VegaFacetChannel(field="grp"),
        align=@chart.VegaAlignMode::Layout(@chart.VegaLayoutAlign::All),
        bounds=@chart.VegaBounds::Full,
        center=@chart.VegaCenter::All(false),
        columns=3,
        name="f",
        description="a facet",
        title=@chart.VegaTitle::Text("FT"),
        resolve=@chart.VegaResolve::VegaResolve(),
      ),
    ),
  )
  assert_true(facet.contains("\"align\":\"all\""))
  assert_true(facet.contains("\"bounds\":\"full\""))
  assert_true(facet.contains("\"center\":false"))
  assert_true(facet.contains("\"name\":\"f\""))
  assert_true(facet.contains("\"description\":\"a facet\""))
  assert_true(facet.contains("\"title\":\"FT\""))
  // Repeat: the same layout and chrome set.
  let repeat = @chart.format_vega_lite(
    df,
    @chart.Chart::Repeat(
      @chart.VegaRepeat::VegaRepeat(
        cell,
        row=["val"],
        column=["ts"],
        align=@chart.VegaAlignMode::Layout(@chart.VegaLayoutAlign::Each),
        bounds=@chart.VegaBounds::Flush,
        center=@chart.VegaCenter::All(true),
        name="r",
        description="a repeat",
        title=@chart.VegaTitle::Text("RT"),
        resolve=@chart.VegaResolve::VegaResolve(),
      ),
    ),
  )
  assert_true(repeat.contains("\"align\":\"each\""))
  assert_true(repeat.contains("\"bounds\":\"flush\""))
  assert_true(repeat.contains("\"center\":true"))
  assert_true(repeat.contains("\"name\":\"r\""))
  assert_true(repeat.contains("\"title\":\"RT\""))
}

///|
test "facet channels infer numeric, temporal, and overridden types" {
  let df = compose_df()
  let numeric = @chart.format_vega_lite(
    df,
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
        ),
        row=@chart.VegaFacetChannel::VegaFacetChannel(
          field="val",
          bin=@chart.VegaBin::On,
        ),
      ),
    ),
  )
  assert_true(
    numeric.contains(
      "\"facet\":{\"row\":{\"field\":\"val\",\"type\":\"quantitative\",\"bin\":true}}",
    ),
  )
  let temporal = @chart.format_vega_lite(
    df,
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
        ),
        row=@chart.VegaFacetChannel::VegaFacetChannel(
          field="ts",
          time_unit=@chart.VegaTimeUnit::Month,
        ),
      ),
    ),
  )
  assert_true(temporal.contains("\"type\":\"temporal\""))
  assert_true(temporal.contains("\"timeUnit\":\"month\""))
  let overridden = @chart.format_vega_lite(
    df,
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
        ),
        row=@chart.VegaFacetChannel::VegaFacetChannel(
          field="val",
          type_override=@chart.VegaType::Ordinal,
        ),
      ),
    ),
  )
  assert_true(overridden.contains("\"type\":\"ordinal\""))
}

///|
test "a repeat over rows alone, its accessors read back both halves" {
  let spec = @chart.format_vega_lite(
    compose_df(),
    @chart.Chart::Repeat(
      // No column list: the repeat is a single row of panels, and the
      // wrapper's chrome carries the wrap count instead.
      @chart.VegaRepeat::VegaRepeat(
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
        ),
        row=["val"],
        columns=1,
      ),
    ),
  )
  assert_true(spec.contains("\"repeat\":{\"row\":[\"val\"]}"))
  assert_true(spec.contains("\"columns\":1"))
  // The accessors: the set half copies, the unset half reads None.
  let repeat = @chart.VegaRepeat::VegaRepeat(
    @chart.Chart::of(
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
    ),
    row=["a", "b"],
    column=["c"],
  )
  assert_eq(repeat.row(), Some(["a", "b"]))
  assert_eq(repeat.column(), Some(["c"]))
  let rowless = @chart.VegaRepeat::VegaRepeat(
    @chart.Chart::of(
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
    ),
    column=["c"],
  )
  assert_eq(rowless.row(), None)
}
