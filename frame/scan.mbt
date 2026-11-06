// The deferred-read plan leaf. The io layer's `scan_*` sources own the
// readers, the options, and the drivers; the engine half lives here — the
// seam those builders reach through, and the leaf state it captures.

///|
/// The engine seam the io layer's `scan_*` sources build on: a `LazyFrame`
/// whose leaf is a deferred read through `driver`, carrying the decimal-probe
/// verdict the builder read off its options. Nothing is read at build — the
/// leaf reads every column and filters nothing when fresh (only the optimizer
/// fills the projection and predicate push-downs), and the first read happens
/// at `collect`, through the driver. The decimal probe rides on the leaf so
/// the decimal value-fence never has to ask the driver for a schema it does
/// not carry: whether the read may produce decimal columns is a fact the io
/// builder states here, the one place the read options are in hand.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn LazyFrame::file_scan(
  driver : @scan.ScanDriver,
  may_carry_decimal~ : Bool,
) -> LazyFrame {
  {
    plan: Scan(
      File({ driver, projection: None, predicate: None, may_carry_decimal, }),
    ),
  }
}
