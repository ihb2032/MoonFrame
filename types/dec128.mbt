// The IEEE 754-2019 decimal128 value the Decimal dtype rides — a
// decimal *floating*-point number: a sign, a coefficient of up to 34
// decimal digits, and a per-value quantum exponent in
// [Etiny, Emax] = [-6176, 6144], plus the three exceptional shapes the
// format shares with the binary floats (±infinity, NaN, and signed
// zero). Every operation computes exactly and rounds once — to 34
// significant digits, ties to even, the standard's recommended default
// — then clamps into the format: a magnitude past 10^Emax is ±Inf, one
// below the smallest subnormal is (signed) zero. Exact results keep
// the operation's *preferred exponent* (the addends' finer one for
// add/sub, the sum for multiply, the difference for divide), so a
// cohort's trailing zeros survive arithmetic the way the standard's
// cohort rules say they do.
//
// The coefficient rides four base-10^9 limbs, little-endian — decimal
// shifts, digit counting, and rendering are all base-10 native then,
// and a schoolbook limb product stays far inside Int64 (each limb
// product is below 10^18, the four-term accumulations below 2^63).
// Intermediates borrow an eight-limb workspace: a full 34-by-34-digit
// product is 68 digits, and the adder's 33-digit alignment guard fits
// with it.

///|
/// One limb's radix — nine decimal digits per Int64.
let dec_base : Int64 = 1_000_000_000L

///|
/// The stored coefficient's limb count — four limbs hold 36 digits,
/// the format's 34 with room for a carry.
let dec_limbs : Int32 = 4

///|
/// The workspace limb count — eight limbs hold 72 digits: the 68-digit
/// exact product, and the aligned addends, both with headroom.
let dec_work_limbs : Int32 = 8

///|
/// The format's precision — significant decimal digits.
let dec_prec : Int32 = 34

///|
/// The format's exponent ceiling, and its subnormal floor —
/// Etiny = Emin − (p − 1).
let dec_emax : Int32 = 6144

///|
let dec_etiny : Int32 = -6176

///|
/// The guard width the adder aligns at — 33 digits below the coarser
/// addend's exponent keeps every digit a 34-digit sum can read, with the
/// round-up carry to spare (69 of the workspace's 70 digits).$
let dec_align_guard : Int32 = 35

///|
/// The digit headroom the parser and the shifts keep — 70 of the
/// workspace's 72 digits, so a shift-and-add carry never leaves the
/// top limb.
let dec_digit_limit : Int32 = 70

///|
/// An IEEE 754 decimal128 value. The fields are the representation,
/// not the API: build values with the constructors (`of_int64`,
/// `parse_opt`, …) and read them with the predicates and conversions —
/// `neg` is the sign bit (true = negative; on NaN it carries nothing),
/// `kind` names the exceptional shapes (0 finite, 1 infinity, 2 NaN),
/// `limbs` is the little-endian base-10^9 coefficient, and `exp` the
/// quantum exponent (the value is ±(Σ limbs[i]·BASE^i)·10^exp).
pub struct Dec128 {
  priv neg : Bool
  priv kind : Int32 // 0 finite, 1 infinity, 2 NaN
  priv limbs : FixedArray[Int64]
  priv exp : Int32
}

///|
/// The value kinds, spelled — `kind`'s three numbers, once.
let dec_kind_finite : Int32 = 0

///|
let dec_kind_inf : Int32 = 1

///|
let dec_kind_nan : Int32 = 2

// ── workspace mechanics ───────────────────────────────────────────────

///|
/// A zeroed workspace.
fn dec_work() -> FixedArray[Int64] {
  FixedArray::makei(dec_work_limbs, _ => 0L)
}

///|
/// Propagate every limb into range — carry from the little end. The
/// callers keep the value inside eight limbs by construction.
fn dec_carry(fa : FixedArray[Int64]) -> Unit {
  for i in 0..<(dec_work_limbs - 1) {
    let v = fa[i]
    if v >= dec_base {
      fa[i] = v % dec_base
      fa[i + 1] = fa[i + 1] + v / dec_base
    }
  }
}

///|
/// The significant limb count — the highest nonzero limb plus one, or
/// zero for an all-zero array. Reads the array's own length: the
/// stored coefficient carries four limbs, a workspace eight.
fn dec_sig_limbs(fa : FixedArray[Int64]) -> Int32 {
  let mut n = fa.length()
  while n > 0 && fa[n - 1] == 0L {
    n = n - 1
  }
  n
}

///|
/// The significant decimal digit count — nine per limb below the top,
/// the top limb's own count on top.
fn dec_sig_digits(fa : FixedArray[Int64]) -> Int32 {
  let n = dec_sig_limbs(fa)
  if n == 0 {
    return 0
  }
  let mut top = fa[n - 1]
  let mut d = 1
  while top >= 10L {
    top = top / 10L
    d = d + 1
  }
  (n - 1) * 9 + d
}

///|
/// Any nonzero limb.
fn dec_nonzero(fa : FixedArray[Int64]) -> Bool {
  for v in fa {
    if v != 0L {
      return true
    }
  }
  false
}

///|
/// Zero every limb — the array's own length, like `dec_sig_limbs`.
fn dec_clear(fa : FixedArray[Int64]) -> Unit {
  for i in 0..<fa.length() {
    fa[i] = 0L
  }
}

///|
/// Shift a workspace's value left by `k` decimal digits — the
/// coefficient times 10^k, the value scaled up. The callers bound k so
/// the result stays inside the workspace.
fn dec_shift_left(fa : FixedArray[Int64], k : Int32) -> Unit {
  if k <= 0 {
    return
  }
  let whole = k / 9
  if whole > 0 {
    for j = dec_work_limbs - 1; j >= whole; j = j - 1 {
      fa[j] = fa[j - whole]
    }
    for j in 0..<whole {
      fa[j] = 0L
    }
  }
  let part = k % 9
  if part > 0 {
    let mut scale = 1L
    for _ in 0..<part {
      scale = scale * 10L
    }
    for j = dec_work_limbs - 1; j >= 0; j = j - 1 {
      fa[j] = fa[j] * scale
    }
    dec_carry(fa)
  }
}

///|
/// Drop the low `k` decimal digits — the coefficient divided by 10^k —
/// answering the first dropped digit (the rounder's guard) and whether
/// any digit below it was nonzero (the sticky tail).
fn dec_drop_digits(fa : FixedArray[Int64], k : Int32) -> (Int32, Bool) {
  if k <= 0 {
    return (0, false)
  }
  // The first dropped digit is the one at position k−1 — readable only
  // while it sits inside the array (an alignment can drop thousands of
  // positions at once; every position past the array's own digits is a
  // zero by construction, so the guard reads 0 and the whole value is
  // the tail).
  let readable = fa.length() * 9
  let mut guard_digit = 0
  let mut tail = false
  if k >= readable {
    tail = dec_nonzero(fa)
    dec_clear(fa)
    return (0, tail)
  }
  for pos in 0..<k {
    let d = dec_digit_at(fa, pos)
    if pos == k - 1 {
      guard_digit = d
    } else if d != 0 {
      tail = true
    }
  }
  let whole = k / 9
  if whole > 0 {
    for j in 0..<(dec_work_limbs - whole) {
      fa[j] = fa[j + whole]
    }
    for j in (dec_work_limbs - whole)..<dec_work_limbs {
      fa[j] = 0L
    }
  }
  let part = k % 9
  if part > 0 {
    let mut scale = 1L
    for _ in 0..<part {
      scale = scale * 10L
    }
    let mut rem = 0L
    for j = dec_work_limbs - 1; j >= 0; j = j - 1 {
      let cur = fa[j] + rem * dec_base
      fa[j] = cur / scale
      rem = cur % scale
    }
  }
  (guard_digit, tail)
}

///|
/// The decimal digit at position `pos` from the little end.
fn dec_digit_at(fa : FixedArray[Int64], pos : Int32) -> Int32 {
  let limb = fa[pos / 9]
  let mut v = limb
  for _ in 0..<(pos % 9) {
    v = v / 10L
  }
  (v % 10L).to_int()
}

///|
/// Add one at the coefficient's little end — the round-up step. The
/// carry may ripple into a fresh top digit (all nines), which the
/// finisher reads as its one-digit bump.
fn dec_add_one(fa : FixedArray[Int64]) -> Unit {
  fa[0] = fa[0] + 1L
  dec_carry(fa)
}

///|
/// Round half-to-even by a guard digit: past 5 rounds up, below 5
/// stays, and exactly 5 rounds up when the sticky tail was nonzero or
/// the kept last digit is odd.
fn dec_round_guard(
  fa : FixedArray[Int64],
  guard_digit : Int32,
  sticky : Bool,
) -> Unit {
  if guard_digit > 5 {
    // Even an all-zero coefficient takes the up-round — the one is the
    // carried digit itself (a value past half the target's unit).
    dec_add_one(fa)
  } else if guard_digit == 5 {
    // The kept last digit lives at the coefficient's little end —
    // limb 0's lowest digit, little-endian.
    if sticky || fa[0] % 10L % 2L == 1L {
      dec_add_one(fa)
    }
  }
}

// ── the finisher: round into the format ──────────────────────────────

///|
/// Round a finite intermediate into decimal128 — carry-normalized
/// workspace, its quantum exponent, and the sticky bit of digits
/// already dropped elsewhere. The standard's two stations in its own
/// order: precision first (34 significant digits, ties to even, the
/// dropped tail joining the sticky bit), then range (a magnitude past
/// 10^Emax is ±Inf; a quantum exponent below Etiny rounds once more at
/// the subnormal floor, and one that underflows it whole is a signed
/// zero). Answers the value and whether it came through
/// *representationally exact* — no digit dropped at either station —
/// the flag a cohort refinement may only run on (a rounded value that
/// gained trailing zeros would read exact).
fn dec_finish(
  neg : Bool,
  fa : FixedArray[Int64],
  exp : Int32,
  sticky : Bool,
) -> (Dec128, Bool) {
  dec_carry(fa)
  let mut exp = exp
  let mut sticky = sticky
  let mut exact = !sticky
  // Precision: at most 34 significant digits.
  let mut digits = dec_sig_digits(fa)
  if digits > dec_prec {
    let (guard_digit, tail) = dec_drop_digits(fa, digits - dec_prec)
    sticky = sticky || tail
    // Exactness survives a drop of zeros only — a guard digit or a
    // nonzero tail is a digit the value lost.
    if guard_digit != 0 || tail {
      exact = false
    }
    exp = dec_add_i32(exp, digits - dec_prec)
    dec_round_guard(fa, guard_digit, sticky)
    // The round-up may carry a fresh top digit out (all nines): one
    // digit past the format, dropped exactly — the zero it leaves
    // cannot round again.
    digits = dec_sig_digits(fa)
    if digits > dec_prec {
      let _ = dec_drop_digits(fa, digits - dec_prec)
      exp = dec_add_i32(exp, digits - dec_prec)
    }
  }
  // Range: the subnormal floor, then the ceiling.
  if dec_sig_limbs(fa) == 0 {
    let e = if exp > dec_emax {
      dec_emax
    } else if exp < dec_etiny {
      dec_etiny
    } else {
      exp
    }
    return (dec_of_parts(neg, dec_kind_finite, fa, e), exact)
  }
  if exp < dec_etiny {
    let (guard_digit, tail) = dec_drop_digits(fa, dec_sub_i32(dec_etiny, exp))
    sticky = sticky || tail
    if guard_digit != 0 || tail {
      exact = false
    }
    exp = dec_etiny
    dec_round_guard(fa, guard_digit, sticky)
    if dec_sig_limbs(fa) == 0 {
      return (dec_of_parts(neg, dec_kind_finite, fa, dec_etiny), exact)
    }
  }
  // The ceiling is the VALUE's, not the quantum's: a magnitude whose
  // leading digit sits past 10^Emax is an infinity however many
  // trailing zeros its cohort carries (the adjusted exponent reads
  // the leading digit's place).
  if dec_add_i32(exp, dec_sig_digits(fa) - 1) > dec_emax {
    return (Dec128::infinity(neg~), exact)
  }
  (dec_of_parts(neg, dec_kind_finite, fa, exp), exact)
}

///|
/// Int32 add that saturates rather than wraps — exponent arithmetic
/// over hostile inputs must fold to the range clamps, not wrap back
/// inside them.
fn dec_add_i32(a : Int32, b : Int32) -> Int32 {
  let sum = a.to_int64() + b.to_int64()
  if sum > 2_147_483_647L {
    2_147_483_647L.to_int()
  } else if sum < -2_147_483_648L {
    (-2_147_483_648L).to_int()
  } else {
    sum.to_int()
  }
}

///|
/// Int32 subtract that saturates — `dec_add_i32`'s twin.
fn dec_sub_i32(a : Int32, b : Int32) -> Int32 {
  dec_add_i32(a, -b)
}

///|
/// Wrap a workspace into a stored value — the caller has already
/// carried; the stored four limbs take the little end, the top
/// workspace limbs zero by the finisher's invariants.
fn dec_of_parts(
  neg : Bool,
  kind : Int32,
  fa : FixedArray[Int64],
  exp : Int32,
) -> Dec128 {
  { neg, kind, limbs: FixedArray::makei(dec_limbs, i => fa[i]), exp, }
}

// ── constructors ─────────────────────────────────────────────────────

///|
/// The NaN — one quiet NaN; the payload the format allows carries
/// nothing a value layer can read.
pub fn Dec128::nan() -> Dec128 {
  {
    neg: false,
    kind: dec_kind_nan,
    limbs: FixedArray::makei(dec_limbs, _ => 0L),
    exp: 0,
  }
}

///|
/// An infinity — `infinity(neg=true)` is −∞.
pub fn Dec128::infinity(neg~ : Bool = false) -> Dec128 {
  {
    neg,
    kind: dec_kind_inf,
    limbs: FixedArray::makei(dec_limbs, _ => 0L),
    exp: 0,
  }
}

///|
/// The zeroes — `zero()` is +0, `zero(neg=true)` the negative zero the
/// format keeps a sign for.
pub fn Dec128::zero(neg~ : Bool = false) -> Dec128 {
  {
    neg,
    kind: dec_kind_finite,
    limbs: FixedArray::makei(dec_limbs, _ => 0L),
    exp: 0,
  }
}

///|
/// The magnitude of an Int64 as workspace limbs (the unsigned domain —
/// `Int64::MIN`'s own magnitude is not a positive Int64), with its
/// sign.
fn dec_load_i64(v : Int64) -> (Bool, FixedArray[Int64]) {
  let neg = v < 0L
  let bits = v.reinterpret_as_uint64()
  let mag = if neg { 0UL - bits } else { bits }
  let fa = dec_work()
  let mut rest = mag
  let mut i = 0
  let base = dec_base.reinterpret_as_uint64()
  while rest > 0UL && i < dec_work_limbs {
    fa[i] = (rest % base).reinterpret_as_int64()
    rest = rest / base
    i = i + 1
  }
  (neg, fa)
}

///|
/// An integer as a decimal — exact, at exponent zero.
pub fn Dec128::of_int64(v : Int64) -> Dec128 {
  let (neg, fa) = dec_load_i64(v)
  dec_finish(neg, fa, 0, false).0
}

///|
/// `v × 10^-scale` as a decimal — the fixed-point spellings' lift (a
/// parquet DECIMAL cell, an unscaled magnitude under a scale). The
/// value rounds into the format like every finite one.
pub fn Dec128::of_int64_scale(v : Int64, scale~ : Int32) -> Dec128 {
  let (neg, fa) = dec_load_i64(v)
  dec_finish(neg, fa, -scale, false).0
}

///|
/// A Double as a decimal — the double's shortest round-trip spelling,
/// read back exactly and rounded once into 34 digits; the exceptional
/// doubles map to the exceptional decimals.
pub fn Dec128::from_double(d : Double) -> Dec128 {
  if d.is_nan() {
    return Dec128::nan()
  }
  if d == @double.infinity || d == @double.neg_infinity {
    return Dec128::infinity(neg=d < 0.0)
  }
  // The signed zero's sign rides the bit pattern — the shortest
  // round-trip spelling may not carry it (the literal printer's own
  // precedent reads the reinterpreted bits).
  if d == 0.0 {
    return Dec128::zero(neg=d.reinterpret_as_int64() != 0L)
  }
  Dec128::parse_opt(d.to_string()).unwrap_or(Dec128::zero())
}

// ── predicates and reads ─────────────────────────────────────────────

///|
/// NaN — the value that equals nothing, itself included.
pub fn Dec128::is_nan(self : Dec128) -> Bool {
  self.kind == dec_kind_nan
}

///|
/// ±∞.
pub fn Dec128::is_infinite(self : Dec128) -> Bool {
  self.kind == dec_kind_inf
}

///|
/// A finite value — the zeroes and the subnormals among them.
pub fn Dec128::is_finite(self : Dec128) -> Bool {
  self.kind == dec_kind_finite
}

///|
/// The sign bit — negative for the negative finite values, −0, and −∞;
/// false on NaN (its sign carries nothing).
pub fn Dec128::is_negative(self : Dec128) -> Bool {
  if self.kind == dec_kind_nan {
    false
  } else {
    self.neg
  }
}

///|
/// A zero coefficient — +0 or −0 (never true on the exceptionals).
pub fn Dec128::is_zero(self : Dec128) -> Bool {
  self.kind == dec_kind_finite && dec_sig_limbs(self.limbs) == 0
}

///|
/// The quantum exponent — the power of ten the coefficient scales by;
/// `None` on the exceptionals (their exponent is not part of the
/// value). A cohort's members differ in exactly this and the
/// coefficient's trailing zeros.
pub fn Dec128::exponent(self : Dec128) -> Int32? {
  if self.kind == dec_kind_finite {
    Some(self.exp)
  } else {
    None
  }
}

///|
/// The adjusted exponent — exponent + significant digits − 1, the
/// power of ten the leading digit sits at (the ordering magnitude);
/// `None` on the exceptionals.
pub fn Dec128::adjusted_exponent(self : Dec128) -> Int32? {
  if self.kind == dec_kind_finite {
    Some(dec_add_i32(self.exp, dec_sig_digits(self.limbs) - 1))
  } else {
    None
  }
}

///|
/// The coefficient's decimal digits, most significant first, trailing
/// zeros kept — the cohort's own spelling ("150" at exponent −2 is
/// 1.50, not 1.5). Empty for a zero; `None` on the exceptionals.
pub fn Dec128::coefficient_digits(self : Dec128) -> Array[Int32]? {
  if self.kind != dec_kind_finite {
    return None
  }
  let out : Array[Int32] = []
  let n = dec_sig_limbs(self.limbs)
  if n == 0 {
    return Some(out)
  }
  // The top limb unpadded, every limb below it to nine digits.
  let top = self.limbs[n - 1].to_string()
  for ch in top {
    out.push(ch.to_int() - 48)
  }
  for j = n - 2; j >= 0; j = j - 1 {
    let mut limb = self.limbs[j]
    let rev : Array[Int32] = []
    for _ in 0..<9 {
      rev.push((limb % 10L).to_int())
      limb = limb / 10L
    }
    for k = 8; k >= 0; k = k - 1 {
      out.push(rev[k])
    }
  }
  Some(out)
}

// ── comparison ───────────────────────────────────────────────────────

///|
/// The magnitudes' order: −1, 0, or 1 by numeric magnitude, cohorts
/// compared by value — equal adjusted exponents compare digit strings
/// with implicit trailing zeros (1.0 against 1.00 reads equal). Both
/// finite and nonzero (the callers screen zero and the exceptionals).
fn dec_cmp_magnitude(a : Dec128, b : Dec128) -> Int32 {
  let aa = dec_add_i32(a.exp, dec_sig_digits(a.limbs) - 1)
  let ab = dec_add_i32(b.exp, dec_sig_digits(b.limbs) - 1)
  if aa != ab {
    return if aa < ab { -1 } else { 1 }
  }
  let da = a.coefficient_digits().unwrap_or([])
  let db = b.coefficient_digits().unwrap_or([])
  let len = if da.length() > db.length() { da.length() } else { db.length() }
  for i in 0..<len {
    let va = if i < da.length() { da[i] } else { 0 }
    let vb = if i < db.length() { db[i] } else { 0 }
    if va != vb {
      return if va < vb { -1 } else { 1 }
    }
  }
  0
}

///|
/// The total order the sort and order-statistics read — the decimal
/// twin of the Float stack's: NaN past everything (one NaN bucket),
/// −∞ < finite < +∞, −0 and +0 equal (they are value-equal, and a
/// stable sort keeps their input order), magnitudes ascending.
pub fn Dec128::cmp_total(self : Dec128, other : Dec128) -> Int32 {
  let rank = (d : Dec128) => {
    if d.kind == dec_kind_nan {
      3
    } else if d.kind == dec_kind_inf {
      2
    } else {
      1
    }
  }
  let ra = rank(self)
  let rb = rank(other)
  if ra != rb {
    // NaN past everything, either side. An infinity against a finite
    // value reads the infinity's own sign: −∞ sits below every finite,
    // +∞ above — whichever side of the pair carries it.
    if ra == 3 || rb == 3 {
      return if ra == 3 { 1 } else { -1 }
    }
    if ra == 2 {
      return if self.neg { -1 } else { 1 }
    }
    return if other.neg { 1 } else { -1 }
  }
  if ra == 3 {
    return 0 // one NaN bucket in the total order
  }
  if ra == 2 {
    return if self.neg == other.neg { 0 } else if self.neg { -1 } else { 1 }
  }
  let za = dec_sig_limbs(self.limbs) == 0
  let zb = dec_sig_limbs(other.limbs) == 0
  if za || zb {
    if za && zb {
      return 0 // −0 and +0 equal
    }
    // A zero against a nonzero finite: the zero sits before every
    // positive and after every negative, its own sign unobservable
    // here (−0 equals +0 in the total order's zero bucket).
    let fin_negative = if za { other.neg } else { self.neg }
    return if fin_negative { 1 } else { -1 }
  }
  if self.neg != other.neg {
    return if self.neg { -1 } else { 1 }
  }
  let m = dec_cmp_magnitude(self, other)
  if self.neg {
    -m
  } else {
    m
  }
}

///|
/// Value equality — the cohort's whole set is one value (1.0 equals
/// 1.00), ±0 equals ∓0, and NaN equals nothing, itself included (the
/// Double Eq precedent; a hash carrier must canonicalize first).
pub fn Dec128::equal(self : Dec128, other : Dec128) -> Bool {
  if self.kind == dec_kind_nan || other.kind == dec_kind_nan {
    return false
  }
  if self.kind != other.kind {
    return false
  }
  if self.kind != dec_kind_finite {
    return self.neg == other.neg
  }
  let za = dec_sig_limbs(self.limbs) == 0
  let zb = dec_sig_limbs(other.limbs) == 0
  if za || zb {
    return za && zb
  }
  self.neg == other.neg && dec_cmp_magnitude(self, other) == 0
}

///|
/// IEEE less-than — `false` whenever either side is NaN.
pub fn Dec128::lt(self : Dec128, other : Dec128) -> Bool {
  if self.kind == dec_kind_nan || other.kind == dec_kind_nan {
    false
  } else {
    self.cmp_total(other) < 0
  }
}

///|
/// IEEE less-or-equal — `false` whenever either side is NaN.
pub fn Dec128::le(self : Dec128, other : Dec128) -> Bool {
  if self.kind == dec_kind_nan || other.kind == dec_kind_nan {
    false
  } else {
    self.cmp_total(other) <= 0
  }
}

///|
/// IEEE greater-than — `false` whenever either side is NaN.
pub fn Dec128::gt(self : Dec128, other : Dec128) -> Bool {
  other.lt(self)
}

///|
/// IEEE greater-or-equal — `false` whenever either side is NaN.
pub fn Dec128::ge(self : Dec128, other : Dec128) -> Bool {
  other.le(self)
}

///|
/// The cohort's canonical member — trailing zeros stripped (one digit
/// left on a zero), so value-equal decimals hash and key alike. The
/// exceptionals are their own canonical shapes.
pub fn Dec128::canonical(self : Dec128) -> Dec128 {
  if self.kind != dec_kind_finite {
    return self
  }
  let fa = dec_work()
  for i in 0..<dec_limbs {
    fa[i] = self.limbs[i]
  }
  let mut exp = self.exp
  if dec_sig_limbs(fa) == 0 {
    return dec_of_parts(self.neg, dec_kind_finite, fa, 0)
  }
  while dec_sig_digits(fa) > 1 && dec_digit_at(fa, 0) == 0 {
    let _ = dec_drop_digits(fa, 1)
    exp = dec_add_i32(exp, 1)
  }
  dec_of_parts(self.neg, dec_kind_finite, fa, exp)
}

// ── arithmetic ───────────────────────────────────────────────────────

///|
/// Negation — the sign flipped on the finite values and the zeroes
/// (−0 stays a value); NaN unchanged (its sign carries nothing).
pub fn Dec128::neg(self : Dec128) -> Dec128 {
  if self.kind == dec_kind_nan {
    return self
  }
  { ..self, neg: !self.neg, }
}

///|
/// Absolute value — the sign cleared; NaN unchanged.
pub fn Dec128::abs(self : Dec128) -> Dec128 {
  if self.kind == dec_kind_nan {
    return self
  }
  { ..self, neg: false, }
}

///|
/// Copy the stored limbs into a fresh workspace.
fn dec_load(d : Dec128) -> FixedArray[Int64] {
  let fa = dec_work()
  for i in 0..<dec_limbs {
    fa[i] = d.limbs[i]
  }
  fa
}

///|
/// Addition. NaN dominates; a like-signed infinity absorbs (opposing
/// ones make the NaN); a zero operand vanishes cohort and all. Finite
/// pairs align at 33 digits below the coarser exponent — every digit a
/// 34-digit sum can read, one spare for the carry — the digits that
/// fall below the alignment folded into the sticky bit. An exact sum
/// refines to the addends' finer exponent (the preferred exponent)
/// while the format's 34 digits hold.
pub fn Dec128::add(self : Dec128, other : Dec128) -> Dec128 {
  dec_add_sub(self, other, false)
}

///|
/// Subtraction — the subtrahend negated, cohort and sign carried.
pub fn Dec128::sub(self : Dec128, other : Dec128) -> Dec128 {
  dec_add_sub(self, other, true)
}

///|
/// The adder behind `add` / `sub`.
fn dec_add_sub(a : Dec128, b : Dec128, sub : Bool) -> Dec128 {
  if a.kind == dec_kind_nan || b.kind == dec_kind_nan {
    return Dec128::nan()
  }
  let bn = if sub { b.neg() } else { b }
  if a.kind == dec_kind_inf || bn.kind == dec_kind_inf {
    if a.kind == dec_kind_inf && bn.kind == dec_kind_inf {
      if a.neg == bn.neg {
        return a
      }
      return Dec128::nan() // ∞ + (−∞): the invalid shape
    }
    return if a.kind == dec_kind_inf { a } else { bn }
  }
  if dec_sig_limbs(bn.limbs) == 0 {
    return a
  }
  if dec_sig_limbs(a.limbs) == 0 {
    return bn
  }
  // The alignment: the addends' finer exponent, unless the exponents
  // sit more than the guard width apart — then the finer addend's
  // digits all fall below the coarser one's 35-digit guard window, and
  // the alignment works at the window's foot instead (the fallen digits
  // riding the sticky bit). The guard (35) plus a 34-digit addend is 69
  // digits, inside the workspace's 70 with the carry to spare.
  let e_fine = if a.exp < bn.exp { a.exp } else { bn.exp }
  let e_coarse = if a.exp >= bn.exp { a.exp } else { bn.exp }
  let window_foot = dec_add_i32(e_coarse, -dec_align_guard)
  let e_work = if window_foot > e_fine { window_foot } else { e_fine }
  let wa = dec_load(a)
  let wb = dec_load(bn)
  let sa = dec_align_to(wa, a.exp, e_work)
  let sb = dec_align_to(wb, bn.exp, e_work)
  let sticky = sa || sb
  if a.neg == bn.neg {
    dec_add_work(wa, wb)
    dec_finish(a.neg, wa, e_work, sticky).0
  } else {
    let m = dec_cmp_work(wa, wb)
    if m == 0 {
      Dec128::zero() // x + (−x): the positive zero
    } else if m > 0 {
      dec_sub_work(wa, wb)
      dec_finish(a.neg, wa, e_work, sticky).0
    } else {
      dec_sub_work(wb, wa)
      dec_finish(bn.neg, wb, e_work, sticky).0
    }
  }
}

///|
/// Refine an exact result toward a coarser (larger) preferred
/// exponent: trailing zeros stripped from the coefficient, never past
/// the preferred. Division's refinement — the exact quotient's guard
/// scaling shifts back out.
fn dec_refine_up(out : Dec128, preferred : Int32) -> Dec128 {
  if out.kind != dec_kind_finite || dec_sig_limbs(out.limbs) == 0 {
    return out
  }
  if out.exp >= preferred {
    return out
  }
  let fa = dec_load(out)
  let mut exp = out.exp
  while exp < preferred && dec_sig_digits(fa) > 1 && dec_digit_at(fa, 0) == 0 {
    let _ = dec_drop_digits(fa, 1)
    exp = dec_add_i32(exp, 1)
  }
  dec_of_parts(out.neg, dec_kind_finite, fa, exp)
}

///|
/// Move a workspace from exponent `from` to the alignment `to`,
/// answering the sticky bit of digits lost below the workspace. A
/// finer target shifts left (trailing zeros appended — exact, bounded
/// by the adder's guard); a coarser one drops digits with the tail
/// folded into the sticky bit.
fn dec_align_to(fa : FixedArray[Int64], from : Int32, to : Int32) -> Bool {
  if to == from {
    return false
  }
  if to < from {
    dec_shift_left(fa, dec_sub_i32(from, to))
    return false
  }
  let (_, tail) = dec_drop_digits(fa, dec_sub_i32(to, from))
  tail
}

///|
/// Workspace add — little-endian limb sums, carries after.
fn dec_add_work(a : FixedArray[Int64], b : FixedArray[Int64]) -> Unit {
  for i in 0..<dec_work_limbs {
    a[i] = a[i] + b[i]
  }
  dec_carry(a)
}

///|
/// Workspace subtract — `a − b`, magnitudes, a ≥ b by the callers.
fn dec_sub_work(a : FixedArray[Int64], b : FixedArray[Int64]) -> Unit {
  let mut borrow = 0L
  for i in 0..<dec_work_limbs {
    let cur = a[i] - b[i] + borrow
    if cur < 0L {
      a[i] = cur + dec_base
      borrow = -1L
    } else {
      a[i] = cur
      borrow = 0L
    }
  }
}

///|
/// Workspace magnitude compare — little-endian from the top.
fn dec_cmp_work(a : FixedArray[Int64], b : FixedArray[Int64]) -> Int32 {
  for i = dec_work_limbs - 1; i >= 0; i = i - 1 {
    if a[i] != b[i] {
      return if a[i] < b[i] { -1 } else { 1 }
    }
  }
  0
}

///|
/// Multiplication. NaN dominates, an infinity times a zero is the
/// NaN, an infinity times anything else the signed infinity. The
/// finite product is exact in the workspace (68 digits), rounded once,
/// an exact one keeping the operands' exponents' sum — the preferred
/// exponent, cohort trailing zeros and all.
pub fn Dec128::mul(self : Dec128, other : Dec128) -> Dec128 {
  if self.kind == dec_kind_nan || other.kind == dec_kind_nan {
    return Dec128::nan()
  }
  if self.kind == dec_kind_inf || other.kind == dec_kind_inf {
    // ∞ × 0 is the NaN — and the zero test reads the *finite* side's
    // coefficient: an infinity's own limbs are zero by construction.
    let self_zero = self.kind == dec_kind_finite &&
      dec_sig_limbs(self.limbs) == 0
    let other_zero = other.kind == dec_kind_finite &&
      dec_sig_limbs(other.limbs) == 0
    if self_zero || other_zero {
      return Dec128::nan()
    }
    return Dec128::infinity(neg=self.neg != other.neg)
  }
  if dec_sig_limbs(self.limbs) == 0 || dec_sig_limbs(other.limbs) == 0 {
    return Dec128::zero(neg=self.neg != other.neg)
  }
  let out = dec_work()
  let na = dec_sig_limbs(self.limbs)
  let nb = dec_sig_limbs(other.limbs)
  for i in 0..<na {
    for j in 0..<nb {
      out[i + j] = out[i + j] + self.limbs[i] * other.limbs[j]
      dec_carry(out)
    }
  }
  dec_finish(
    self.neg != other.neg,
    out,
    dec_add_i32(self.exp, other.exp),
    false,
  ).0
}

///|
/// Division. 0/0 and ∞/∞ are the NaN; a nonzero over a zero the
/// signed infinity; a zero over a nonzero the signed zero; an infinity
/// over a finite (or the mirror) the fitting extreme. The finite
/// quotient carries 35 digits before its one rounding (the 35th is
/// the guard a tie reads), and an exact quotient's guard scaling
/// shifts back out toward the preferred exponent — dividend exponent
/// minus divisor exponent.
pub fn Dec128::div(self : Dec128, other : Dec128) -> Dec128 {
  if self.kind == dec_kind_nan || other.kind == dec_kind_nan {
    return Dec128::nan()
  }
  if self.kind == dec_kind_inf {
    if other.kind == dec_kind_inf {
      return Dec128::nan()
    }
    return Dec128::infinity(neg=self.neg != other.neg)
  }
  if other.kind == dec_kind_inf {
    return Dec128::zero(neg=self.neg != other.neg)
  }
  let a_zero = dec_sig_limbs(self.limbs) == 0
  let b_zero = dec_sig_limbs(other.limbs) == 0
  if a_zero && b_zero {
    return Dec128::nan()
  }
  if b_zero {
    return Dec128::infinity(neg=self.neg != other.neg)
  }
  if a_zero {
    return Dec128::zero(neg=self.neg != other.neg)
  }
  // Scale the dividend so the quotient shows at least 35 digits — the
  // stored operands hold at most 34 digits each, so the width is never
  // negative (the clamp a 35-plus-digit dividend would need cannot
  // arise inside the format).
  let da = dec_sig_digits(self.limbs)
  let db = dec_sig_digits(other.limbs)
  let s = dec_prec + 1 + db - da
  let numer = dec_load(self)
  dec_shift_left(numer, s)
  let divisor = dec_load(other)
  let (quot, rem_exact) = dec_div_work(numer, divisor)
  let exp = dec_add_i32(dec_sub_i32(self.exp, other.exp), -s)
  let (out, fin_exact) = dec_finish(
    self.neg != other.neg,
    quot,
    exp,
    !rem_exact,
  )
  if !rem_exact || !fin_exact {
    return out
  }
  dec_refine_up(out, dec_sub_i32(self.exp, other.exp))
}

///|
/// Long division of workspaces: `numer / divisor`, the dividend
/// already scaled so the quotient's digits fit — schoolbook in base
/// 10^9, one quotient limb per step (an Int64 estimate off the top
/// limbs, corrected by at most a couple of compares). Answers the
/// quotient workspace and whether the remainder came out exactly zero.
fn dec_div_work(
  numer : FixedArray[Int64],
  divisor : FixedArray[Int64],
) -> (FixedArray[Int64], Bool) {
  let nb = dec_sig_limbs(divisor)
  let top = divisor[nb - 1]
  let quot = dec_work()
  // The running remainder, one limb longer than the divisor's count.
  let rem = FixedArray::makei(dec_work_limbs + 1, _ => 0L)
  for i = dec_work_limbs - 1; i >= 0; i = i - 1 {
    // rem = rem · BASE + numer[i].
    let mut carry = numer[i]
    for j = 0; j <= dec_work_limbs; j = j + 1 {
      let cur = rem[j] * dec_base + carry
      rem[j] = cur % dec_base
      carry = cur / dec_base
    }
    if carry != 0L || !dec_rem_zero(rem) {
      // The estimate, off the remainder's window around the divisor's
      // top limb; corrected down while it overshot.
      let rem_top = rem[nb] * dec_base + rem[nb - 1]
      let mut q = rem_top / top
      if q >= dec_base {
        q = dec_base - 1L
      }
      while q > 0L && dec_rem_lt_mul(rem, divisor, q) {
        q = q - 1L
      }
      dec_rem_sub_mul(rem, divisor, q)
      quot[i] = q
    }
  }
  (quot, dec_rem_zero(rem))
}

///|
/// The remainder workspace's all-zero-ness.
fn dec_rem_zero(rem : FixedArray[Int64]) -> Bool {
  for v in rem {
    if v != 0L {
      return false
    }
  }
  true
}

///|
/// Whether `rem < q · divisor` — the quotient estimate's overshoot
/// test, on the product accumulated limb-wise into a scratch.
fn dec_rem_lt_mul(
  rem : FixedArray[Int64],
  divisor : FixedArray[Int64],
  q : Int64,
) -> Bool {
  let prod = FixedArray::makei(dec_work_limbs + 1, _ => 0L)
  let mut carry = 0L
  for i in 0..<(dec_work_limbs + 1) {
    let d = if i < dec_work_limbs { divisor[i] } else { 0L }
    let cur = q * d + carry
    prod[i] = cur % dec_base
    carry = cur / dec_base
  }
  // rem < prod, little-endian from the top (carry-out past prod means
  // the product left the window — rem is certainly below it).
  for i = dec_work_limbs; i >= 0; i = i - 1 {
    if rem[i] != prod[i] {
      return rem[i] < prod[i]
    }
  }
  false
}

///|
/// `rem −= q · divisor` in place — magnitudes, the callers having
/// proven the product fits under the remainder.
fn dec_rem_sub_mul(
  rem : FixedArray[Int64],
  divisor : FixedArray[Int64],
  q : Int64,
) -> Unit {
  let mut borrow = 0L
  for i in 0..<(dec_work_limbs + 1) {
    let d = if i < dec_work_limbs { divisor[i] } else { 0L }
    let sub = q * d + borrow
    borrow = sub / dec_base
    let mut cur = rem[i] - sub % dec_base
    while cur < 0L {
      cur = cur + dec_base
      borrow = borrow + 1L
    }
    rem[i] = cur
  }
}

// ── quantize, conversions ────────────────────────────────────────────

///|
/// Round to `places` decimal places — the `round` verb's quantum
/// arithmetic: the result's exponent is exactly −places, the value
/// rounded half-to-even into it (NaN and ±∞ pass through). A finite
/// value whose coefficient cannot hold that exponent (past 34 digits
/// there) is the quantize-invalid shape, a NaN.
pub fn Dec128::quantize(self : Dec128, places~ : Int32) -> Dec128 {
  if self.kind != dec_kind_finite {
    return self
  }
  let target = dec_add_i32(0, -places)
  // The two impossible targets: an exponent below the subnormal floor,
  // and a value whose digits past the target run beyond the format's
  // 34 (a coefficient that cannot exist there). Both are the
  // quantize-invalid shape, a NaN.
  if target < dec_etiny {
    return Dec128::nan()
  }
  let adj = dec_add_i32(self.exp, dec_sig_digits(self.limbs) - 1)
  if dec_sub_i32(adj, target) + 1 > dec_prec {
    return Dec128::nan()
  }
  let fa = dec_load(self)
  let mut sticky = false
  let mut guard_digit = 0
  if target > self.exp {
    // Coarser (fewer places): the digits past the target drop off and
    // the guard rounds them.
    let (g, tail) = dec_drop_digits(fa, dec_sub_i32(target, self.exp))
    guard_digit = g
    sticky = tail
  } else if target < self.exp {
    // Finer (more places): trailing zeros appended, exact — the width
    // the earlier check refuses is exactly the width this shift cannot
    // hold, so no second refusal exists here.
    dec_shift_left(fa, dec_sub_i32(self.exp, target))
  }
  dec_round_guard(fa, guard_digit, sticky)
  dec_of_parts(self.neg, dec_kind_finite, fa, target)
}

///|
/// The value as an Int64 — exact when every digit is an integer digit,
/// `None` otherwise (a fraction, a magnitude past Int64, or an
/// exceptional).
pub fn Dec128::to_int64(self : Dec128) -> Int64? {
  if self.kind != dec_kind_finite {
    return None
  }
  let fa = dec_load(self)
  if self.exp < 0 {
    // Integral only when every dropped digit is zero — the guard digit
    // included (2.50 is 2.5, not 2).
    let (guard_digit, tail) = dec_drop_digits(fa, -self.exp)
    if guard_digit != 0 || tail {
      return None
    }
  } else if self.exp > 0 {
    let digits = dec_sig_digits(fa)
    if digits + self.exp > dec_work_limbs * 9 {
      return None
    }
    dec_shift_left(fa, self.exp)
  }
  dec_work_to_int64(self.neg, fa)
}

///|
/// The workspace's limbs as a signed Int64 — `None` past the range.
fn dec_work_to_int64(neg : Bool, fa : FixedArray[Int64]) -> Int64? {
  let mut mag = 0UL
  for i = dec_work_limbs - 1; i >= 0; i = i - 1 {
    mag = mag * dec_base.reinterpret_as_uint64() + fa[i].reinterpret_as_uint64()
  }
  let limit = if neg {
    9_223_372_036_854_775_808UL // |MIN| reads back exactly
  } else {
    9_223_372_036_854_775_807UL
  }
  if mag > limit {
    return None
  }
  let v = mag.reinterpret_as_int64()
  Some(if neg { -v } else { v })
}

///|
/// The render's own spelling always parses as a double — the catch is
/// the never-taken arm a total conversion must still spell, so the
/// helper carries the skip.
#coverage.skip
fn dec_parse_double_or_nan(s : String) -> Double {
  @string.parse_double(s.clamped_view()) catch {
    _ => @double.not_a_number
  }
}

///|
/// The value as a Double — the decimal spelling read by the double
/// parser (a correctly-rounded conversion), the exceptionals mapped
/// across.
pub fn Dec128::to_double(self : Dec128) -> Double {
  if self.kind == dec_kind_nan {
    return @double.not_a_number
  }
  if self.kind == dec_kind_inf {
    return if self.neg { @double.neg_infinity } else { @double.infinity }
  }
  dec_parse_double_or_nan(self.to_string())
}

// ── parse and render ─────────────────────────────────────────────────

///|
/// Parse a decimal spelling — the render's own forms read back
/// exactly: an optional sign, digits with an optional point (`.5`
/// among them), an optional decimal exponent `[eE][+-]?digits`, and
/// the exceptional spellings `inf` / `+inf` / `-inf` / `NaN`. The
/// significant digits accumulate into the workspace and round once (a
/// hundred-digit literal is a value past 34 significant digits, not a
/// refusal); `None` for any other shape.
pub fn Dec128::parse_opt(s : String) -> Dec128? {
  let n = s.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let neg = if s[i] == '+' {
    i = 1
    false
  } else if s[i] == '-' {
    i = 1
    true
  } else {
    false
  }
  if i >= n {
    return None
  }
  let is_digit = (u : Int32) => u >= 48 && u <= 57
  // The exceptional spellings, sign already read.
  if n - i == 3 {
    if s[i].to_int() == 105 &&
      s[i + 1].to_int() == 110 &&
      s[i + 2].to_int() == 102 {
      return Some(Dec128::infinity(neg~))
    }
    if !neg &&
      s[i].to_int() == 78 &&
      s[i + 1].to_int() == 97 &&
      s[i + 2].to_int() == 78 {
      return Some(Dec128::nan())
    }
  }
  // Digits: the integer part, an optional point, the fraction. Leading
  // zeros carry no magnitude — skipped before the workspace; past 70
  // significant digits the tail drops into the sticky bit.
  let fa = dec_work()
  let mut seen_any_digit = false
  let mut seen_significant = false
  let mut sig_collected = 0
  let mut tail_nonzero = false
  let mut frac_digits = 0
  let mut int_overflow_digits = 0
  // One digit in: `true` when the workspace was already full — an
  // integer-part digit then scales the value (×10 each), a fraction
  // digit only folds its nonzero-ness into the sticky tail.
  fn take_digit(unit : Int32, is_int : Bool) -> Bool {
    let d = unit - 48
    seen_any_digit = true
    if d == 0 && !seen_significant {
      return false // a leading zero scales nothing
    }
    seen_significant = true
    if sig_collected < dec_digit_limit {
      // fa = fa·10 + d, little-endian.
      let mut carry = d.to_int64()
      for k in 0..<dec_work_limbs {
        let cur = fa[k] * 10L + carry
        fa[k] = cur % dec_base
        carry = cur / dec_base
      }
      sig_collected = sig_collected + 1
      return false
    }
    if d != 0 {
      tail_nonzero = true
    }
    is_int
  }
  while i < n && is_digit(s[i].to_int()) {
    if take_digit(s[i].to_int(), true) {
      int_overflow_digits = int_overflow_digits + 1
    }
    i = i + 1
  }
  if i < n && s[i] == '.' {
    i = i + 1
    while i < n && is_digit(s[i].to_int()) {
      let _ = take_digit(s[i].to_int(), false)
      frac_digits = frac_digits + 1
      i = i + 1
    }
  }
  if !seen_any_digit {
    return None
  }
  // The exponent tail.
  let mut exp10 = 0
  if i < n && (s[i] == 'e' || s[i] == 'E') {
    i = i + 1
    let eneg = if i < n && s[i] == '+' {
      i = i + 1
      false
    } else if i < n && s[i] == '-' {
      i = i + 1
      true
    } else {
      false
    }
    if i >= n || !is_digit(s[i].to_int()) {
      return None
    }
    let mut ev = 0L
    while i < n && is_digit(s[i].to_int()) {
      if ev < 9_000_000_000L {
        ev = ev * 10L + (s[i].to_int() - 48).to_int64()
      }
      i = i + 1
    }
    // Saturate into the finisher's clamps rather than wrap.
    if ev > 2_000_000_000L {
      ev = 2_000_000_000L
    }
    exp10 = if eneg { -ev.to_int() } else { ev.to_int() }
  }
  if i != n {
    return None
  }
  let exp = dec_add_i32(dec_add_i32(exp10, int_overflow_digits), -frac_digits)
  Some(dec_finish(neg, fa, exp, tail_nonzero).0)
}

///|
/// The value's own spelling — the exact stored value, cohort kept:
/// positional when the leading digit sits from 10^-6 to 10^40,
/// scientific beyond (the digit string, a point after the first digit,
/// `E` and the adjusted exponent); the zeroes signed, the exceptionals
/// `inf` / `-inf` / `NaN`. `parse_opt` reads every spelling back
/// exactly.
pub fn Dec128::to_string(self : Dec128) -> String {
  if self.kind == dec_kind_nan {
    return "NaN"
  }
  if self.kind == dec_kind_inf {
    return if self.neg { "-inf" } else { "inf" }
  }
  let sign = if self.neg { "-" } else { "" }
  let digits = self.coefficient_digits().unwrap_or([])
  if digits.length() == 0 {
    return sign + "0.0"
  }
  let adj = dec_add_i32(self.exp, digits.length() - 1)
  if adj >= 40 || adj <= -7 {
    // Scientific.
    let mut out = sign + "\{digits[0]}"
    if digits.length() > 1 {
      out = out + "."
      for k in 1..<digits.length() {
        out = out + "\{digits[k]}"
      }
    }
    out + "E\{adj}"
  } else if adj >= 0 {
    // Positional with an integer part.
    let int_len = adj + 1
    let mut out = sign
    for k in 0..<int_len {
      out = out + "\{if k < digits.length() { digits[k] } else { 0 }}"
    }
    out = out + "."
    if int_len >= digits.length() {
      out = out + "0"
    } else {
      for k in int_len..<digits.length() {
        out = out + "\{digits[k]}"
      }
    }
    out
  } else {
    // A pure fraction.
    let zeros = -adj - 1
    let mut out = sign + "0."
    for _ in 0..<zeros {
      out = out + "0"
    }
    for d in digits {
      out = out + "\{d}"
    }
    out
  }
}
