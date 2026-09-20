// The scan-driver seam: the interface a *readable source* implements so the
// lazy engine can execute, narrow, and render it without knowing the format.
// A new scannable format is one driver (with its own options
// type) plus the `scan_*` builder that hands it to the engine — the
// optimizer's projection / predicate push-down and the plan renderer apply
// to it automatically, because those are driver calls, not format-aware
// branches.
//
// P4 (production over assembly): a driver returns columns, never a
// `DataFrame`. The lazy executor assembles the frame; an eager reader that
// wants one assembles its own. The pushed projection and absorbed predicate
// are arguments of a read, not driver state — the same driver value can sit
// under any number of plan shapes.
//
// A record of two closures rather than a trait: the driver is one runtime
// object handed across a package boundary, and a record keeps both the
// implementation and the engine side free of trait machinery.

///|
/// The columns one scan read produced, plus the row count. Height rides
/// separately so a projection that matches no column keeps the source's rows
/// (the `N×0` shape) instead of collapsing to zero rows.
pub struct ScanBatch {
  priv columns : Array[@series.Series]
  priv height : Int
}

///|
/// Assemble a batch from its columns and its row count. `columns` is copied,
/// so the batch owns its list and the caller's array stays theirs.
pub fn ScanBatch::batch(
  columns : Array[@series.Series],
  height : Int,
) -> ScanBatch {
  { columns: columns.copy(), height, }
}

///|
/// The columns the read built, in the source's own order (a pushed projection
/// re-orders only via the optimizer, never here).
pub fn ScanBatch::columns(self : ScanBatch) -> Array[@series.Series] {
  self.columns
}

///|
/// The source's row count, even when zero columns were built (the `N×0`
/// shape).
pub fn ScanBatch::height(self : ScanBatch) -> Int {
  self.height
}

///|
/// One readable source: a label for the plan renderer and the read itself.
/// Implementations live beside the format they read (io's CSV / NDJSON
/// drivers); the lazy engine sees only this record.
pub struct ScanDriver {
  /// The format-facing part of the plan label — the format token and the
  /// origin, with the path already escaped (e.g. `CSV "a,b.csv"`). The
  /// renderer prefixes `SCAN_` and appends the pushed projection and the
  /// absorbed predicate, which are plan state, not driver state.
  priv label_fn : () -> String
  /// Read the source. `projection` narrows the read to the named columns
  /// (`None` = every column, in the source's own order; a name the source
  /// lacks is simply never built — whichever expression references it raises
  /// at evaluation, exactly as the unoptimized read would). `predicate`, when
  /// absorbed, prunes rows: the driver may build only the predicate's columns
  /// for all rows and the rest for the survivors — or ignore it entirely, if
  /// the format has no cheaper-than-full-read pruning; correctness never
  /// depends on absorption.
  priv scan_fn : (Array[String]?, @expr.Expr?) -> ScanBatch raise @types.DataError
}

///|
/// Assemble a driver from its label and its read.
pub fn ScanDriver::driver(
  label_fn : () -> String,
  scan_fn : (Array[String]?, @expr.Expr?) -> ScanBatch raise @types.DataError,
) -> ScanDriver {
  { label_fn, scan_fn, }
}

///|
/// The format-facing part of the plan label — the format token and the
/// origin, with the path already escaped; the renderer adds the plan state
/// around it.
pub fn ScanDriver::label(self : ScanDriver) -> String {
  (self.label_fn)()
}

///|
/// Read the source under the pushed projection and the absorbed predicate.
pub fn ScanDriver::scan(
  self : ScanDriver,
  projection? : Array[String]?,
  predicate? : @expr.Expr?,
) -> ScanBatch raise @types.DataError {
  (self.scan_fn)(projection.unwrap_or(None), predicate.unwrap_or(None))
}
