// The style leaves shared across the guide trees — alignment, baselines,
// font weights, orientations, caps and joins — one enum per schema enum,
// transcribed from the vendored vega_lite_v6_5_0.schema.json and
// schema-walked through the corpus guard. Reached through `@chart`
// qualification: part of the deep mirror family the facade deliberately
// does not re-export.

///|
/// A text alignment: `Left → "left"`, `Center → "center"`, `Right → "right"`.
#derive(Eq, Debug)
pub(all) enum VegaAlign {
  Left
  Center
  Right
}

///|
pub extend VegaAlign with Eq::{equal, not_equal}

///|
pub extend VegaAlign with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_align_string(v : VegaAlign) -> String {
  match v {
    Left => "left"
    Center => "center"
    Right => "right"
  }
}

///|
/// A text baseline: the alphabetic default and the three named baselines.
#derive(Eq, Debug)
pub(all) enum VegaBaseline {
  Alphabetic
  Top
  Middle
  Bottom
  LineTop
  LineBottom
}

///|
pub extend VegaBaseline with Eq::{equal, not_equal}

///|
pub extend VegaBaseline with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_baseline_string(v : VegaBaseline) -> String {
  match v {
    Alphabetic => "alphabetic"
    Top => "top"
    Middle => "middle"
    Bottom => "bottom"
    LineTop => "line-top"
    LineBottom => "line-bottom"
  }
}

///|
/// A font weight: the four named weights or a numeric one (100–900).
#derive(Eq, Debug)
pub(all) enum VegaFontWeight {
  Normal
  Bold
  Lighter
  Bolder
  Weight(Int32)
}

///|
pub extend VegaFontWeight with Eq::{equal, not_equal}

///|
pub extend VegaFontWeight with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_font_weight_emit_json(v : VegaFontWeight) -> Json {
  match v {
    Normal => Json::string("normal")
    Bold => Json::string("bold")
    Lighter => Json::string("lighter")
    Bolder => Json::string("bolder")
    Weight(w) => Json::number(w.to_double())
  }
}

///|
/// An anchor point: `Start`, `Middle`, or `End`.
#derive(Eq, Debug)
pub(all) enum VegaAnchor {
  Start
  Middle
  End
}

///|
pub extend VegaAnchor with Eq::{equal, not_equal}

///|
pub extend VegaAnchor with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_anchor_string(v : VegaAnchor) -> String {
  match v {
    Start => "start"
    Middle => "middle"
    End => "end"
  }
}

///|
/// An axis orientation: the four sides.
#derive(Eq, Debug)
pub(all) enum VegaAxisOrient {
  Top
  Bottom
  Left
  Right
}

///|
pub extend VegaAxisOrient with Eq::{equal, not_equal}

///|
pub extend VegaAxisOrient with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_axis_orient_string(v : VegaAxisOrient) -> String {
  match v {
    Top => "top"
    Bottom => "bottom"
    Left => "left"
    Right => "right"
  }
}

///|
/// A side: `Left → "left"`, `Right → "right"`, `Top → "top"`,
/// `Bottom → "bottom"` (a header's orientation and title side).
#derive(Eq, Debug)
pub(all) enum VegaOrient {
  Left
  Right
  Top
  Bottom
}

///|
pub extend VegaOrient with Eq::{equal, not_equal}

///|
pub extend VegaOrient with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_orient_string(v : VegaOrient) -> String {
  match v {
    Left => "left"
    Right => "right"
    Top => "top"
    Bottom => "bottom"
  }
}

///|
/// A legend orientation: a side or a corner (or `None`, no legend).
#derive(Eq, Debug)
pub(all) enum VegaLegendOrient {
  None
  Left
  Right
  Top
  Bottom
  TopLeft
  TopRight
  BottomLeft
  BottomRight
}

///|
pub extend VegaLegendOrient with Eq::{equal, not_equal}

///|
pub extend VegaLegendOrient with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_legend_orient_string(v : VegaLegendOrient) -> String {
  match v {
    None => "none"
    Left => "left"
    Right => "right"
    Top => "top"
    Bottom => "bottom"
    TopLeft => "top-left"
    TopRight => "top-right"
    BottomLeft => "bottom-left"
    BottomRight => "bottom-right"
  }
}

///|
/// A title orientation: a side or `None`.
#derive(Eq, Debug)
pub(all) enum VegaTitleOrient {
  None
  Left
  Right
  Top
  Bottom
}

///|
pub extend VegaTitleOrient with Eq::{equal, not_equal}

///|
pub extend VegaTitleOrient with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_title_orient_string(v : VegaTitleOrient) -> String {
  match v {
    None => "none"
    Left => "left"
    Right => "right"
    Top => "top"
    Bottom => "bottom"
  }
}

///|
/// A label-overlap strategy: the boolean of the default greedy mode, or a named one.
#derive(Eq, Debug)
pub(all) enum VegaLabelOverlap {
  Bool(Bool)
  Parity
  Greedy
}

///|
pub extend VegaLabelOverlap with Eq::{equal, not_equal}

///|
pub extend VegaLabelOverlap with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_label_overlap_emit_json(v : VegaLabelOverlap) -> Json {
  match v {
    Bool(b) => Json::boolean(b)
    Parity => Json::string("parity")
    Greedy => Json::string("greedy")
  }
}

///|
/// A stroke cap: butt, round, or square.
#derive(Eq, Debug)
pub(all) enum VegaCap {
  Butt
  Round
  Square
}

///|
pub extend VegaCap with Eq::{equal, not_equal}

///|
pub extend VegaCap with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_cap_string(v : VegaCap) -> String {
  match v {
    Butt => "butt"
    Round => "round"
    Square => "square"
  }
}

///|
/// A stroke join: miter, round, or bevel.
#derive(Eq, Debug)
pub(all) enum VegaJoin {
  Miter
  Round
  Bevel
}

///|
pub extend VegaJoin with Eq::{equal, not_equal}

///|
pub extend VegaJoin with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_join_string(v : VegaJoin) -> String {
  match v {
    Miter => "miter"
    Round => "round"
    Bevel => "bevel"
  }
}

///|
/// A grid alignment for legends and titles: all, each, or none.
#derive(Eq, Debug)
pub(all) enum VegaLayoutAlign {
  All
  Each
  None
}

///|
pub extend VegaLayoutAlign with Eq::{equal, not_equal}

///|
pub extend VegaLayoutAlign with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_layout_align_string(v : VegaLayoutAlign) -> String {
  match v {
    All => "all"
    Each => "each"
    None => "none"
  }
}

///|
/// A title frame of reference: the group or the bounds.
#derive(Eq, Debug)
pub(all) enum VegaTitleFrame {
  Bounds
  Group
}

///|
pub extend VegaTitleFrame with Eq::{equal, not_equal}

///|
pub extend VegaTitleFrame with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_title_frame_string(v : VegaTitleFrame) -> String {
  match v {
    Bounds => "bounds"
    Group => "group"
  }
}

///|
/// A direction: horizontal or vertical.
#derive(Eq, Debug)
pub(all) enum VegaDirection {
  Horizontal
  Vertical
}

///|
pub extend VegaDirection with Eq::{equal, not_equal}

///|
pub extend VegaDirection with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_direction_string(v : VegaDirection) -> String {
  match v {
    Horizontal => "horizontal"
    Vertical => "vertical"
  }
}

///|
/// A CSS cursor name, one variant per schema value.
#derive(Eq, Debug)
pub(all) enum VegaCursor {
  Auto
  Default
  None
  ContextMenu
  Help
  Pointer
  Progress
  Wait
  Cell
  Crosshair
  Text
  VerticalText
  Alias
  Copy
  Move
  NoDrop
  NotAllowed
  EResize
  NResize
  NeResize
  NwResize
  SResize
  SeResize
  SwResize
  WResize
  EwResize
  NsResize
  NeswResize
  NwseResize
  ColResize
  RowResize
  AllScroll
  ZoomIn
  ZoomOut
  Grab
  Grabbing
}

///|
pub extend VegaCursor with Eq::{equal, not_equal}

///|
pub extend VegaCursor with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_cursor_string(v : VegaCursor) -> String {
  match v {
    Auto => "auto"
    Default => "default"
    None => "none"
    ContextMenu => "context-menu"
    Help => "help"
    Pointer => "pointer"
    Progress => "progress"
    Wait => "wait"
    Cell => "cell"
    Crosshair => "crosshair"
    Text => "text"
    VerticalText => "vertical-text"
    Alias => "alias"
    Copy => "copy"
    Move => "move"
    NoDrop => "no-drop"
    NotAllowed => "not-allowed"
    EResize => "e-resize"
    NResize => "n-resize"
    NeResize => "ne-resize"
    NwResize => "nw-resize"
    SResize => "s-resize"
    SeResize => "se-resize"
    SwResize => "sw-resize"
    WResize => "w-resize"
    EwResize => "ew-resize"
    NsResize => "ns-resize"
    NeswResize => "nesw-resize"
    NwseResize => "nwse-resize"
    ColResize => "col-resize"
    RowResize => "row-resize"
    AllScroll => "all-scroll"
    ZoomIn => "zoom-in"
    ZoomOut => "zoom-out"
    Grab => "grab"
    Grabbing => "grabbing"
  }
}
