// The exponentially-weighted kernel — `ewm_mean` / `ewm_std` /
// `ewm_variance`'s shared recurrence over one numeric column. Each cell
// blends the running weighted moments with the incoming value by `alpha`;
// null cells null the output and either skip the recurrence entirely
// (`ignore_nulls`) or let the running weights decay as if a value had been
// seen (the default, matching the weight-sum semantics of a window whose
// cells pass by unobserved). The deviation / variance read the standard
// biased relation over the running first and second moments. Always
// `Float`.

///|
/// Evaluate one exponentially-weighted statistic over an operand column,
/// keeping the operand's name (the naming verb renames through
/// `output_name`). `alpha` must sit in `(0, 1]` and `min_samples` at or
/// above `1` — the builder's span/alpha handshake decodes into an `alpha`
/// here, so the envelope check lives with the recurrence it guards.
/// Numeric operand only; the output is `Float`, a cell staying null until
/// `min_samples` non-null values have occurred.
fn eval_ewm(
  stat : @ir.EwmStat,
  alpha : Double,
  adjust : Bool,
  min_samples : Int32,
  ignore_nulls : Bool,
  operand : Series,
) -> Series raise @types.DataError {
  if !(alpha > 0.0 && alpha <= 1.0) {
    raise @types.DataError::InvalidOperation(
      "ewm requires alpha in (0, 1], or exactly one of span (> 1) / alpha; got \{alpha}",
    )
  }
  if min_samples < 1 {
    raise @types.DataError::InvalidOperation(
      "ewm min_samples must be at least 1, got \{min_samples}",
    )
  }
  let dtype = operand.dtype()
  if !dtype.is_numeric() {
    raise @types.DataError::TypeMismatch(
      @types.TypeMismatchDetail::Message(
        "ewm statistic requires a numeric operand, got \{dtype}",
      ),
    )
  }
  let name = operand.name()
  // The running state: the weight sum `w`, the weighted first moment `m1`,
  // and the weighted second raw moment `m2` — each decayed by `(1 - alpha)`
  // before the incoming value joins. `adjust` keeps the denominator (the
  // weighted mean divides by `w`); without it the plain recursive blend
  // `y = (1 - alpha) * y + alpha * x` answers, which weights the first
  // sample fully regardless of `w`.
  let decay = 1.0 - alpha
  let mut w = 0.0
  let mut m1 = 0.0
  let mut m2 = 0.0
  let mut y_prev = 0.0
  let mut seen = 0
  let out : Array[Double?] = []
  for cell in operand.to_scalars() {
    let x : Double? = match cell {
      Int(v) => Some(v.to_double())
      Float(v) => Some(v)
      _ => None
    }
    match x {
      None =>
        // A null cell: the output nulls; the recurrence either skips it
        // entirely or decays in place, per `ignore_nulls`.
        if ignore_nulls {
          out.push(None)
        } else {
          w = w * decay
          m1 = m1 * decay
          m2 = m2 * decay
          y_prev = y_prev * decay
          out.push(None)
        }
      Some(v) => {
        seen = seen + 1
        w = w * decay + 1.0
        m1 = m1 * decay + v
        m2 = m2 * decay + v * v
        let mean = m1 / w
        // The first observed value seeds the recursive blend at its full
        // weight (`adjust` needs no seed — the quotient handles it), so a
        // one-value column answers that value under either policy.
        y_prev = if adjust {
          mean
        } else if seen == 1 {
          v
        } else {
          decay * y_prev + alpha * v
        }
        if seen >= min_samples {
          match stat {
            EwmMean => out.push(Some(y_prev))
            EwmVariance => out.push(Some(m2 / w - mean * mean))
            EwmStd => out.push(Some((m2 / w - mean * mean).sqrt()))
          }
        } else {
          out.push(None)
        }
      }
    }
  }
  @series.Series::from_float_options(name, out)
}
