// The temporal arithmetic — the one place a rider dtype's cells combine
// with another's. The pairs the dtype docstrings promise:
// `Timestamp − Timestamp → Duration` (the microsecond difference), `Date −
// Date → Duration` (whole days, scaled to microseconds), `Timestamp ±
// Duration → Timestamp` (checked), and `Date ± Duration → Timestamp` (a
// day-granular date promoted to the microsecond instant the span names —
// `Date` has no sub-day cells to hold the result). Everything else — a
// `Duration` combined with a `Duration` or with a numeric, a temporal
// combined with a numeric — declines to `None`, the caller's numeric path
// which refuses it.

///|
/// Evaluate a temporal operand pair when its dtypes name one of the
/// temporal combinations, or `None` when they do not. A null operand cell
/// nulls the output cell; the temporal cells ride the shared I64 buffer,
/// so the folds read the boxed cells and rebuild through the
/// dtype-carrying constructors, and every widening step is checked — an
/// instant or difference that leaves `Int64` fails the whole column at
/// once (`InvalidOperation`, never a wrap), like the decimal
/// arithmetic's own overflow refusal.
fn temporal_arith(
  left : Series,
  right : Series,
  verb : String,
) -> Series? raise @types.DataError {
  let lt = left.dtype()
  let rt = right.dtype()
  // The instant-difference pairs: both sides temporal instants of one
  // spelling, the difference a Duration.
  if verb == "subtract" &&
    (
      (lt is @types.DataType::Timestamp && rt is @types.DataType::Timestamp) ||
      (lt is @types.DataType::Date && rt is @types.DataType::Date)
    ) {
    let cells : Array[Int64?] = []
    let mut overflow = false
    let ls = left.to_scalars()
    let rs = right.to_scalars()
    for i in 0..<ls.length() {
      match (ls[i], rs[i]) {
        (Timestamp(a), Timestamp(b)) =>
          match @numeric.sub_checked(a, b) {
            Some(v) => cells.push(Some(v))
            None => {
              overflow = true
              cells.push(None)
            }
          }
        (Date(a), Date(b)) =>
          match @numeric.sub_checked(a, b) {
            Some(days) =>
              match @numeric.mul_checked(days, 86_400_000_000L) {
                Some(v) => cells.push(Some(v))
                None => {
                  overflow = true
                  cells.push(None)
                }
              }
            None => {
              overflow = true
              cells.push(None)
            }
          }
        _ => cells.push(None)
      }
    }
    if overflow {
      raise @types.DataError::InvalidOperation(
        "temporal subtract: the difference leaves the microsecond range",
      )
    }
    return Some(Series::from_duration_options(left.name(), cells))
  }
  // The shift pairs: an instant plus or minus a Duration lands on the
  // microsecond instant (a Date promoted — its own granularity cannot
  // hold a sub-day shift).
  if (lt is @types.DataType::Timestamp || lt is @types.DataType::Date) &&
    rt is @types.DataType::Duration &&
    (verb == "add" || verb == "subtract") {
    let add = verb == "add"
    let cells : Array[Int64?] = []
    let mut overflow = false
    let ls = left.to_scalars()
    let rs = right.to_scalars()
    for i in 0..<ls.length() {
      match (ls[i], rs[i]) {
        (Timestamp(a), Duration(d)) =>
          match shift_us(a, d, add) {
            Some(v) => cells.push(Some(v))
            None => {
              overflow = true
              cells.push(None)
            }
          }
        (Date(a), Duration(d)) =>
          match @numeric.mul_checked(a, 86_400_000_000L) {
            Some(micros) =>
              match shift_us(micros, d, add) {
                Some(v) => cells.push(Some(v))
                None => {
                  overflow = true
                  cells.push(None)
                }
              }
            None => {
              overflow = true
              cells.push(None)
            }
          }
        _ => cells.push(None)
      }
    }
    if overflow {
      raise @types.DataError::InvalidOperation(
        "temporal shift: the instant leaves the microsecond range",
      )
    }
    return Some(Series::from_timestamp_options(left.name(), cells))
  }
  None
}

///|
/// The checked instant shift: `a ± d` — the numeric package's own
/// checked add / subtract / multiply over the microsecond counts.
fn shift_us(a : Int64, d : Int64, add : Bool) -> Int64? {
  if add {
    @numeric.add_checked(a, d)
  } else {
    @numeric.sub_checked(a, d)
  }
}
