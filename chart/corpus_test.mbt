// The corpus: golden emitted specs, committed under `chart/corpus/`, one
// per feature family of the export. Every run re-emits each spec and
// compares against the committed file, so the corpus cannot fall behind
// the emitter; the guard `.github/scripts/check_vega_corpus.py` then
// walks each committed spec against the vendored Vega-Lite 6.5.0 schema,
// so a key or enum string the schema does not know fails the build. That
// is the machine-checked half of the hand-written mirror's fidelity.
//
// Refresh (after an intended emission change):
//   MOONFRAME_VEGA_CORPUS_REFRESH=1 moon test -p ihb2032/MoonFrame/chart
// then review the corpus diffs the way a snapshot diff is reviewed —
// every changed byte is a change to what callers' charts look like.

///|
/// The frame every corpus spec renders against: the same column set the
/// channel tests use, so a corpus spec can reach any dtype family.
fn corpus_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x", "y"]),
    @series.Series::from_ints("val", [1, 2]),
    @series.Series::from_strings("grp", ["a", "b"]),
    @series.Series::from_timestamp_options("ts", [
      Some(1_704_067_200_000_000L),
      Some(1_704_075_840_000_000L),
    ]),
  ])
}

///|
/// The corpus itself: one spec per feature family, in the order the
/// files are named.
fn corpus_specs() -> Array[(String, @chart.ChartSpec)] {
  [
    (
      "bar_basic.json",
      @chart.ChartSpec::bar(
        @chart.field("cat"),
        @chart.field("val"),
        color=@chart.field("grp"),
      ),
    ),
    (
      "chrome_full.json",
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        name="revenue-chart",
        description="Revenue by region",
        title=@chart.VegaTitle::Text("Revenue"),
        autosize=@chart.VegaAutoSize::FitX,
        background="#f8f8f8",
        padding=@chart.VegaPadding::Sides(
          @chart.VegaSides::VegaSides(top=10, left=5),
        ),
        width=@chart.VegaExtent::Px(320),
        height=@chart.VegaExtent::Step(24),
      ),
    ),
    (
      "pie_arc_sum.json",
      @chart.ChartSpec::arc(
        @chart.field("val", aggregate=Sum),
        color=@chart.field("grp"),
      ),
    ),
    (
      "donut_arc.json",
      @chart.ChartSpec::arc(
        @chart.field("val", aggregate=Sum),
        color=@chart.field("grp"),
        radius2=@chart.field("val"),
      ),
    ),
    (
      "histogram_bin_count.json",
      @chart.ChartSpec::bar(
        @chart.field(
          "val",
          bin=@chart.VegaBin::Params(
            @chart.VegaBinParams::VegaBinParams(maxbins=20, extent=(0.0, 3.0)),
          ),
        ),
        @chart.VegaChannel::count(),
      ),
    ),
    (
      "line_timeunit.json",
      @chart.ChartSpec::line(
        @chart.field("ts", time_unit=@chart.VegaTimeUnit::Month),
        @chart.field("val", aggregate=Sum),
      ),
    ),
    (
      "scatter_of_channels.json",
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        x_error=@chart.field("val"),
        x_error2=@chart.field("val"),
        y_error=@chart.field("val"),
        y_error2=@chart.field("val"),
        x_offset=@chart.field("val"),
        y_offset=@chart.field("val"),
        fill=@chart.field("grp"),
        stroke=@chart.field("grp"),
        fill_opacity=@chart.field("val"),
        stroke_opacity=@chart.field("val"),
        stroke_width=@chart.field("val"),
        stroke_dash=@chart.field("val"),
        shape=@chart.field("grp"),
        angle=@chart.field("val"),
        time=@chart.field("ts"),
        href=@chart.field("grp"),
        url=@chart.field("grp"),
        description_channel=@chart.field("grp"),
        key=@chart.field("grp"),
        order=@chart.field("val"),
      ),
    ),
    (
      "errorbar_channels.json",
      @chart.ChartSpec::errorbar(
        @chart.field("cat"),
        @chart.field("val"),
        y_error=@chart.field("val"),
        y_error2=@chart.field("val"),
      ),
    ),
    (
      "geoshape_geojson.json",
      @chart.ChartSpec::geoshape(
        @chart.field("cat", type_override=@chart.VegaType::Geojson),
      ),
    ),
    (
      "image_url.json",
      @chart.ChartSpec::image(
        @chart.field("cat"),
        @chart.field("val"),
        @chart.field("grp"),
      ),
    ),
    (
      "sort_forms.json",
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field(
          "cat",
          sort=@chart.VegaChannelSort::ByChannel(
            @chart.VegaSortChannel::Size,
            Some(true),
          ),
        ),
        y=@chart.field("val"),
        color=@chart.field(
          "grp",
          sort=@chart.VegaChannelSort::ByField(
            "val",
            Some(@chart.VegaSort::Descending),
          ),
        ),
      ),
    ),
    (
      "constant_datum_stack.json",
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field(
          "cat",
          sort=@chart.VegaChannelSort::values([
            Json::string("y"),
            Json::string("x"),
          ]),
        ),
        y=@chart.field("val", stack=@chart.VegaStack::Normalize, format="d"),
        color=@chart.constant(Json::string("steelblue")),
        size=@chart.datum(Json::number(60.0)),
      ),
    ),
    (
      "scale_axis.json",
      @chart.ChartSpec::bar(
        @chart.field(
          "cat",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              type_=@chart.VegaScaleType::Band,
              padding_inner=0.3,
            ),
          ),
          axis=@chart.VegaAxisRef::Config(
            @chart.VegaAxis::VegaAxis(
              orient=@chart.VegaAxisOrient::Bottom,
              grid=false,
              label_angle=-30.0,
              label_overlap=@chart.VegaLabelOverlap::Parity,
              tick_count=@chart.VegaTickInterval::Step(
                @chart.VegaTimeInterval::Month,
                2,
              ),
            ),
          ),
        ),
        @chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              type_=@chart.VegaScaleType::Log,
              base=10,
              clamp=true,
              zero=false,
              nice=@chart.VegaNice::Ticks(7),
            ),
          ),
        ),
      ),
    ),
    (
      "legend_scheme.json",
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field("val"),
        y=@chart.field("val", aggregate=Mean),
        color=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              scheme=@chart.VegaScheme::Params(
                @chart.VegaSchemeParams::VegaSchemeParams(
                  name="viridis",
                  count=7,
                ),
              ),
            ),
          ),
          legend=@chart.VegaLegendRef::Config(
            @chart.VegaLegend::VegaLegend(
              type_=@chart.VegaLegendType::Gradient,
              orient=@chart.VegaLegendOrient::TopRight,
              gradient_length=200,
              title="Mean value",
              format=".1f",
            ),
          ),
        ),
      ),
    ),
    (
      "title_view_projection.json",
      @chart.ChartSpec::of(
        @chart.ChartKind::Geoshape,
        shape=@chart.field("grp", type_override=@chart.VegaType::Geojson),
        title=@chart.VegaTitle::Params(
          @chart.VegaTitleParams::VegaTitleParams(
            text="Regions",
            subtitle="by revenue",
            anchor=@chart.VegaAnchor::End,
            offset=10,
          ),
        ),
        view=@chart.VegaViewBackground::VegaViewBackground(
          fill="#ffffff",
          stroke="#dddddd",
          stroke_dash=[4.0, 2.0],
          corner_radius=4,
        ),
        projection=@chart.VegaProjection::VegaProjection(
          type_=@chart.VegaProjectionType::Mercator,
          center=(0.0, 0.0),
          scale=120,
        ),
      ),
    ),
    (
      "boxplot_plain.json",
      @chart.ChartSpec::boxplot(@chart.field("cat"), @chart.field("val")),
    ),
  ]
}

///|
/// The composition half of the corpus: one chart per operator.
fn corpus_charts() -> Array[(String, @chart.Chart)] {
  [
    (
      "layer_line_point.json",
      @chart.Chart::Layer(
        @chart.VegaLayer::VegaLayer(
          [
            @chart.Chart::of(
              @chart.ChartSpec::point(@chart.field("val"), @chart.field("val")),
            ),
            @chart.Chart::of(
              @chart.ChartSpec::line(
                @chart.field("val"),
                @chart.field("val"),
                color=@chart.field("grp"),
              ),
            ),
          ],
          title=@chart.VegaTitle::Text("Value against itself"),
          resolve=@chart.VegaResolve::VegaResolve(
            legend=@chart.VegaLegendResolve::VegaLegendResolve(
              color=@chart.VegaResolveMode::Independent,
            ),
          ),
        ),
      ),
    ),
    (
      "facet_header.json",
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
            ),
          ),
          column=@chart.VegaFacetChannel::VegaFacetChannel(
            field="cat",
            sort=@chart.VegaChannelSort::ByField(
              "val",
              Some(@chart.VegaSort::Descending),
            ),
            bin=@chart.VegaBin::On,
          ),
          columns=2,
          spacing=@chart.VegaSpacing::Px(8),
        ),
      ),
    ),
    (
      "repeat_columns.json",
      @chart.Chart::Repeat(
        @chart.VegaRepeat::VegaRepeat(
          @chart.Chart::of(
            @chart.ChartSpec::line(
              @chart.field("cat"),
              @chart.field("val"),
              title="Dummy",
            ),
          ),
          column=["val", "ts"],
          spacing=@chart.VegaSpacing::Px(6),
        ),
      ),
    ),
    (
      "concat_wrap.json",
      @chart.Chart::Concat(
        @chart.VegaConcat::VegaConcat(
          [
            @chart.Chart::of(
              @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
            ),
            @chart.Chart::Layer(
              @chart.VegaLayer::VegaLayer([
                @chart.Chart::of(
                  @chart.ChartSpec::point(
                    @chart.field("val"),
                    @chart.field("val"),
                  ),
                ),
              ]),
            ),
          ],
          align=@chart.VegaAlignMode::Layout(@chart.VegaLayoutAlign::Each),
          columns=1,
          resolve=@chart.VegaResolve::VegaResolve(
            scale=@chart.VegaScaleResolve::VegaScaleResolve(
              y=@chart.VegaResolveMode::Independent,
            ),
          ),
        ),
      ),
    ),
    (
      "vconcat_pair.json",
      @chart.Chart::VConcat(
        @chart.VegaConcat::VegaConcat(
          [
            @chart.Chart::of(
              @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
            ),
            @chart.Chart::of(
              @chart.ChartSpec::area(
                @chart.field("ts", time_unit=@chart.VegaTimeUnit::Month),
                @chart.field("val"),
              ),
            ),
          ],
          bounds=@chart.VegaBounds::Flush,
        ),
      ),
    ),
    (
      "transforms_filter.json",
      @chart.Chart::of(
        @chart.ChartSpec::of(
          @chart.ChartKind::Bar,
          x=@chart.field("cat"),
          y=@chart.field("val"),
          transform=[
            @chart.VegaTransform::Filter(
              @chart.VegaFilterTransform::VegaFilterTransform(
                filter=@chart.VegaPredicate::all_of([
                  @chart.VegaPredicate::Valid("val", true, None),
                  @chart.VegaPredicate::Expr("datum.cat != 'z'"),
                ]),
              ),
            ),
            @chart.VegaTransform::Calculate(
              @chart.VegaCalculateTransform::VegaCalculateTransform(
                calculate="datum.val * 2",
                as_="doubled",
              ),
            ),
          ],
        ),
      ),
    ),
    (
      "transforms_window.json",
      @chart.Chart::of(
        @chart.ChartSpec::of(
          @chart.ChartKind::Line,
          x=@chart.field("ts", time_unit=@chart.VegaTimeUnit::Month),
          y=@chart.field("val", aggregate=Sum),
          transform=[
            @chart.VegaTransform::Window(
              @chart.VegaWindowTransform::VegaWindowTransform(
                window=[
                  @chart.VegaWindowField::VegaWindowField(
                    op=@chart.VegaAggregate::Sum,
                    field="val",
                    as_="running",
                  ),
                ],
                sort=[
                  @chart.VegaSortField::VegaSortField(
                    field="ts",
                    order=@chart.VegaSort::Ascending,
                  ),
                ],
                frame=(
                  @chart.VegaFrameLimit::Open,
                  @chart.VegaFrameLimit::Num(0),
                ),
              ),
            ),
            @chart.VegaTransform::Fold(
              @chart.VegaFoldTransform::VegaFoldTransform(
                fold=["val", "running"],
                as_=["measure", "amount"],
              ),
            ),
          ],
        ),
      ),
    ),
    (
      "params_brush.json",
      @chart.Chart::of(
        @chart.ChartSpec::of(
          @chart.ChartKind::Area,
          x=@chart.field("ts"),
          y=@chart.field("val"),
          params=[
            @chart.VegaParam::Selection(
              @chart.VegaSelectionParam::VegaSelectionParam(
                name="brush",
                select=@chart.VegaSelect::Interval(
                  @chart.VegaIntervalSelect::VegaIntervalSelect(
                    encodings=["x"],
                    mark=@chart.VegaBrush::VegaBrush(
                      fill="#669eff",
                      fill_opacity=0.2,
                    ),
                  ),
                ),
                bind=@chart.VegaBind::Range(
                  @chart.VegaBindRange::VegaBindRange(min=0, max=100),
                ),
              ),
            ),
            @chart.VegaParam::Variable(
              @chart.VegaVariableParam::VegaVariableParam(
                name="cutoff",
                value=Json::number(10),
                bind=@chart.VegaBind::Checkbox(
                  @chart.VegaBindCheckbox::VegaBindCheckbox(),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    (
      "params_condition.json",
      @chart.Chart::of(
        @chart.ChartSpec::of(
          @chart.ChartKind::Point,
          x=@chart.field("val"),
          y=@chart.field("val"),
          color=@chart.field(
            "grp",
            condition=@chart.VegaCondition::When(
              @chart.VegaPredicate::Expr("datum.val > 1"),
              Json::string("orangered"),
            ),
          ),
          params=[
            @chart.VegaParam::Selection(
              @chart.VegaSelectionParam::VegaSelectionParam(
                name="picked",
                select=@chart.VegaSelect::Point(
                  @chart.VegaPointSelect::VegaPointSelect(
                    on="click",
                    fields=["cat"],
                    nearest=true,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    (
      "config_theme.json",
      @chart.Chart::of(
        @chart.ChartSpec::of(
          @chart.ChartKind::Bar,
          x=@chart.field("cat"),
          y=@chart.field("val"),
          config=@chart.VegaConfig::VegaConfig(
            background="#fafafa",
            font="sans-serif",
            count_title="Rows",
            mark=@chart.VegaMarkStyle::VegaMarkStyle(
              color="steelblue",
              fill_opacity=0.8,
            ),
            bar=@chart.VegaMarkStyle::VegaMarkStyle(bin_spacing=2),
            scale=@chart.VegaScaleConfig::VegaScaleConfig(clamp=true),
            axis=@chart.VegaAxis::VegaAxis(grid=false),
            legend=@chart.VegaLegendConfig::VegaLegendConfig(
              orient=@chart.VegaLegendOrient::Right,
              symbol_type="circle",
              columns=2,
            ),
            title=@chart.VegaTitleConfig::VegaTitleConfig(
              anchor=@chart.VegaAnchor::End,
              subtitle_font_size=11,
            ),
            view=@chart.VegaViewConfig::VegaViewConfig(
              step=24,
              fill="#fff",
              discrete_width=@chart.VegaDiscreteSize::Step(30),
            ),
            range=@chart.VegaRangeConfig::VegaRangeConfig(category=[
              "#1f77b4", "#ff7f0e",
            ]),
            number_format=".2f",
          ),
          usermeta=Json::object({ "owner": Json::string("dashboard") }),
        ),
      ),
    ),
  ]
}

///|
test "corpus: every committed spec matches the emitter byte for byte" {
  let df = corpus_df()
  let refresh = @env.get_env_var("MOONFRAME_VEGA_CORPUS_REFRESH") is Some("1")
  for entry in corpus_specs() {
    let (file, spec) = entry
    let emitted = @chart.format_vega_lite(df, @chart.Chart::of(spec))
    let path = "chart/corpus/" + file
    if refresh {
      @fs.write_string_to_file(path, emitted)
    } else {
      assert_eq(emitted, @fs.read_file_to_string(path))
    }
  }
  for entry in corpus_charts() {
    let (file, chart) = entry
    let emitted = @chart.format_vega_lite(df, chart)
    let path = "chart/corpus/" + file
    if refresh {
      @fs.write_string_to_file(path, emitted)
    } else {
      assert_eq(emitted, @fs.read_file_to_string(path))
    }
  }
  if refresh {
    println(
      "corpus: refreshed — review the diffs, then rerun without the variable",
    )
  }
}
