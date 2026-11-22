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
  priv height : Int32
}

///|
/// Assemble a batch from its columns and its row count. `columns` is copied,
/// so the batch owns its list and the caller's array stays theirs.
pub fn ScanBatch::batch(
  columns : Array[@series.Series],
  height : Int32,
) -> ScanBatch {
  { columns: columns.copy(), height, }
}

///|
/// The columns the read built, in the source's own order (a pushed projection
/// re-orders only via the optimizer, never here). A copy, like the
/// constructor's: handing out the batch's own array would let a caller
/// mutate the batch through the reader.
pub fn ScanBatch::columns(self : ScanBatch) -> Array[@series.Series] {
  self.columns.copy()
}

///|
/// The source's row count, even when zero columns were built (the `N×0`
/// shape).
pub fn ScanBatch::height(self : ScanBatch) -> Int32 {
  self.height
}

///|
/// A row window over the source, in the eager window verbs' own
/// vocabulary — the shape a sunk `head` / `tail` / `slice` takes when
/// the optimizer absorbs it into a scan leaf. The resolution against a
/// known row count (`resolve`) is the same saturation arithmetic the
/// eager verbs run, on the same helpers, so a window a driver applies
/// and the eager verb the plan would have run spell one window.
pub(all) enum ScanWindow {
  Head(Int32)
  Tail(Int32)
  Slice(Int32, Int32?)
}

///|
/// Resolve the window against a known row count: the half-open
/// `[start, start + len)` row range it keeps, saturating exactly as the
/// eager `head` / `tail` / `slice` verbs do (a negative `Head` bound
/// keeps all but the last rows, a negative `Slice` offset counts from
/// the end, an omitted length runs to the end).
pub fn ScanWindow::resolve(self : ScanWindow, total : Int32) -> (Int32, Int32) {
  match self {
    Head(n) => {
      let m = @order.window_take(n, total)
      (0, m)
    }
    Tail(n) => {
      let m = @order.window_take(n, total)
      (total - m, m)
    }
    Slice(offset, length) => {
      let start = @order.slice_start(offset, total)
      (start, @order.slice_len(start, total, length))
    }
  }
}

///|
/// The batches one opened read yields, in source order: `next` hands
/// back the next batch until the read is exhausted (`None`), raising the
/// read's own `DataError` where an eager read would raise it. A cursor
/// is single-shot — the engine opens one per read and walks it once.
pub struct BatchCursor {
  priv next_fn : () -> ScanBatch? raise @types.DataError
}

///|
/// Assemble a cursor from its next step.
pub fn BatchCursor::cursor(
  next_fn : () -> ScanBatch? raise @types.DataError,
) -> BatchCursor {
  { next_fn, }
}

///|
/// The next batch of the opened read, or `None` at exhaustion.
pub fn BatchCursor::next(
  self : BatchCursor,
) -> ScanBatch? raise @types.DataError {
  (self.next_fn)()
}

///|
/// A cursor over `self` whose batches never exceed `cap` rows — a
/// source whose own batches run coarser (a textual source's whole-read
/// batch, a wide row group) answers in row windows of `cap` instead,
/// its rows' order untouched (the cap slices, it never re-orders or
/// drops). A batch already inside the cap passes through as it was, and
/// an empty batch answers as itself; the wrapping is one cursor per
/// `capped` call, single-shot like the cursor it wraps.
pub fn BatchCursor::capped(self : BatchCursor, cap : Int32) -> BatchCursor {
  // The held batch and how many of its rows have left: array cells, so
  // the step closure sees its own earlier answers on every later call.
  let held : Array[ScanBatch?] = [None]
  let at : Array[Int32] = [0]
  BatchCursor::cursor(() => {
    while true {
      let batch = match held[0] {
        None =>
          match self.next() {
            None => return None
            Some(fresh) => {
              held[0] = Some(fresh)
              at[0] = 0
              fresh
            }
          }
        // A held batch always has rows left: every path that sets it
        // either pairs it with a fresh `at` below its height or clears
        // it as its last window leaves.
        Some(kept) => kept
      }
      // A batch inside the cap passes through whole (its height rides
      // unchanged, an `N×0` batch included — zero rows never slices).
      if at[0] == 0 && batch.height() <= cap {
        held[0] = None
        return Some(batch)
      }
      let remaining = batch.height() - at[0]
      let take = if remaining < cap { remaining } else { cap }
      let window = batch.columns().map(c => c.slice_series(at[0], take))
      at[0] = at[0] + take
      if at[0] >= batch.height() {
        held[0] = None
      }
      return Some(ScanBatch::batch(window, take))
    }
    // The loop answers on every path that reaches it; this is the
    // shape the compiler needs after `while true`.
    None
  })
}

///|
/// One readable source: a label for the plan renderer and the batched
/// read itself. Implementations live beside the format they read (io's
/// CSV / NDJSON / JSON / Parquet drivers); the lazy engine sees only
/// this record.
pub struct ScanDriver {
  /// The format-facing part of the plan label — the format token and the
  /// origin, with the path already escaped (e.g. `CSV "a,b.csv"`). The
  /// renderer prefixes `SCAN_` and appends the pushed projection and the
  /// absorbed predicate, which are plan state, not driver state.
  priv label_fn : () -> String
  /// Open the source under the pushed narrowing and hand back its batch
  /// cursor. `projection` narrows the read to the named columns (`None`
  /// = every column, in the source's own order; a name the source lacks
  /// is simply never built — whichever expression references it raises
  /// at evaluation, exactly as the unoptimized read would).
  /// `predicate`, when absorbed, prunes rows: the driver may build only
  /// the predicate's columns for all rows and the rest for the
  /// survivors — or ignore it entirely, if the format has no
  /// cheaper-than-full-read pruning; correctness never depends on
  /// absorption. `window`, when absorbed, is the row range the driver
  /// itself applies — a columnar source skips the batches outside it
  /// outright, a textual one reads whole and slices; a driver that
  /// cannot apply it still receives it, and applies it after the read
  /// (the row range is the same wherever the cut lands).
  priv batches_fn : (Array[String]?, @expr.Expr?, ScanWindow?) -> BatchCursor raise @types.DataError
  /// Whether the optimizer may sink a window into this source — a
  /// columnar one skips the batches outside the window outright, so
  /// absorption pays; a textual one would read whole and cut, no cheaper
  /// than the window node it would replace, so it says `false` and the
  /// window stays a node above the scan (still applied if a window
  /// reaches the driver by another path — the row range is the same
  /// wherever the cut lands).
  priv absorbs_window : Bool
}

///|
/// Assemble a driver from its label, its batched read, and whether the
/// optimizer may sink a window into the source.
pub fn ScanDriver::driver(
  label_fn : () -> String,
  batches_fn : (Array[String]?, @expr.Expr?, ScanWindow?) -> BatchCursor raise @types.DataError,
  absorbs_window~ : Bool = false,
) -> ScanDriver {
  { label_fn, batches_fn, absorbs_window, }
}

///|
/// The format-facing part of the plan label — the format token and the
/// origin, with the path already escaped; the renderer adds the plan state
/// around it.
pub fn ScanDriver::label(self : ScanDriver) -> String {
  (self.label_fn)()
}

///|
/// Whether the optimizer may sink a window into this source.
pub fn ScanDriver::absorbs_window(self : ScanDriver) -> Bool {
  self.absorbs_window
}

///|
/// Open the source under the pushed projection, the absorbed predicate,
/// and the absorbed window, and hand back its batch cursor. Raises the
/// read's own opening failures — a missing file, a malformed footer —
/// here, and the per-batch failures at `next`.
pub fn ScanDriver::batches(
  self : ScanDriver,
  projection? : Array[String]?,
  predicate? : @expr.Expr?,
  window? : ScanWindow?,
) -> BatchCursor raise @types.DataError {
  (self.batches_fn)(
    projection.unwrap_or(None),
    predicate.unwrap_or(None),
    window.unwrap_or(None),
  )
}
