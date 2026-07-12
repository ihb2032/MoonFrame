///|
/// A composable, introspectable column expression tree — the reified
/// upgrade over the closure-based surfaces (the v0.1 row-predicate
/// closure) and pre-materialised `Series` columns. An `Expr` is *data*: the
/// evaluator in `frame` pattern-matches
/// it, and the v0.4 lazy layer will print and rewrite it — none of which a
/// closure can offer.
///
/// The enum is `pub` (read-only): other packages — including `frame`, whose
/// evaluator `match`es the tree cross-package — can inspect it but cannot
/// construct variants (`[4036]`). The only way to build an `Expr` is the
/// constructor functions (`col` / `lit` / `lit_*` / `when`), the operator
/// impls and the methods in `expr_ops.mbt`, so every tree is well-formed by
/// construction. Building an expression is **total** — unknown columns and
/// dtype mismatches surface at evaluation time (in `frame`), never here.
///
/// Variant tour (construction route in parentheses):
/// - `Col` / `Lit` / `LitSeries` — leaves (`col`, `lit` / `lit_*`,
///   `lit_series`). `LitSeries` embeds a whole pre-materialised
///   `@series.Series` as a literal column: at evaluation it is used as-is,
///   broadcasting when length 1 and otherwise matching the frame height
///   (`LengthMismatch` on any other length). It is named after the series it
///   carries, so its output column keeps the series' name unless an alias
///   overrides it;
/// - `Binary` — arithmetic `+ - * /`, comparisons `eq/ne/lt/le/gt/ge`,
///   Kleene logic `&`/`|` (also `.land()`/`.lor()` — `and`/`or` are
///   reserved words);
/// - `Unary` — `-e`, `.not()`, `.is_null()`, `.is_not_null()`, `.is_nan()`,
///   `.is_not_nan()`;
/// - `Agg` — `.sum()/.mean()/.min()/.max()/.count()`, reducing its operand
///   to a single value per evaluation scope;
/// - `Str` — the string namespace (`.str_to_uppercase()` /
///   `.str_contains(p)` / …), mapping each cell of its String operand
///   through a `StrOp` transform;
/// - `Cast` — `.cast(dtype)`;
/// - `Alias` — `.with_alias(name)` (`alias` is a reserved word), naming the
///   result column;
/// - `Ternary` — `when(cond).then(a).otherwise(b)`;
/// - `FillNull` / `FillNan` — `.fill_null(value)` / `.fill_nan(value)`,
///   carrying `(operand, value)`. Semantically these are the guarded
///   ternaries `when(operand.is_not_null()).then(operand).otherwise(value)`
///   (resp. `is_not_nan`), but as dedicated nodes the operand appears — and
///   is evaluated, rendered, and compared — **once**: the ternary lowering
///   embedded `self` twice, so a chained coalesce
///   (`e.fill_null(a).fill_null(b)…`) built an exponentially-sized tree;
/// - `IsIn` / `IsBetween` — the membership / range predicates
///   (`.is_in(members)` / `.is_between(lo, hi)`). `IsIn` carries its operand
///   and a literal `Array[Scalar]` set and evaluates as an OR of `eq` (so a
///   member's dtype must compare with the column, and a `Null` member matches
///   nothing); `IsBetween` carries `(operand, lo, hi)` and is the both-closed
///   `lo <= x <= hi`, evaluated as `x.ge(lo) & x.le(hi)` — a dedicated node, so
///   the operand appears (and is evaluated, rendered, compared) **once**, the
///   same reason `FillNull` is not lowered to a `Ternary`;
/// - `Map` — the closure escape hatch (`.map_elements()` / `map_many()`),
///   applying an opaque host function row by row over its input columns.
///   It carries a `label` (for `Show` / `explain`), the input expressions,
///   and the function `(Array[Scalar]) -> Scalar raise`. The closure makes
///   the variant un-`derive`-able, so `Expr` hand-writes `Eq` (below),
///   `@debug.Debug` and `Show` (in `explain.mbt`), each treating the
///   function as opaque — a `Map` is identified by its `(label, inputs)`.
pub enum Expr {
  Col(String)
  Lit(@types.Scalar)
  LitSeries(@series.Series)
  Binary(BinOp, Expr, Expr)
  Unary(UnOp, Expr)
  Agg(AggOp, Expr)
  Str(StrOp, Expr)
  Cast(Expr, @types.DataType)
  Alias(Expr, String)
  Ternary(Expr, Expr, Expr)
  FillNull(Expr, Expr)
  FillNan(Expr, Expr)
  IsIn(Expr, Array[@types.Scalar])
  IsBetween(Expr, Expr, Expr)
  Map(
    String,
    Array[Expr],
    (Array[@types.Scalar]) -> @types.Scalar raise @types.DataError
  )
}

///|
/// Structural equality, handwritten because the `Map` variant's closure
/// payload has no `Eq` (so the enum cannot `derive` one). Every other
/// variant compares exactly as the derived impl would — operands and tags
/// recursively — and two `Map` nodes are equal when their `label` and
/// `inputs` match: the function is **opaque** (functions have no equality),
/// so identically-built maps compare equal regardless of which closure
/// instance they hold. The comparison matches on one operand wildcard-free
/// (each arm then checks the other), so a *new* `Expr` variant fails to
/// compile here until its equality case is written — the same discipline
/// `Expr::children` and `eval_expr` follow.
pub impl Eq for Expr with fn equal(self, other) {
  exprs_structurally_equal(self, other)
}

///|
/// Structural equality over an explicit work-stack of node pairs rather than
/// the call stack: a deeply nested tree (`col("a") + col("a") + …` tens of
/// thousands deep) would otherwise overflow the native stack and abort — the
/// same never-abort hazard the introspection walks in `explain.mbt` dodge,
/// reached here through `==` / `assert_eq` / `inspect` and the derived `Eq` of
/// any structure embedding an `Expr` (`DataFrame`, the lazy `LogicalPlan`).
/// Semantics match the derived impl exactly: tags and operands compared
/// recursively, two `Map` nodes equal on `(label, inputs)` with the function
/// opaque, a mismatched variant unequal. Each iteration matches the first
/// operand wildcard-free and then the second, so a differing variant short-
/// circuits to `false` and a newly added `Expr` variant fails to compile here
/// until its case is written. Children are pushed so a mismatch anywhere in
/// the tree short-circuits to `false`.
fn exprs_structurally_equal(first : Expr, second : Expr) -> Bool {
  let stack : Array[(Expr, Expr)] = [(first, second)]
  for ;; {
    match stack.pop() {
      None => break
      // Match the first operand exhaustively (no wildcard); each arm then
      // matches the second, where a differing variant is never equal. A new
      // `Expr` variant is thus forced to declare its equality here.
      Some((a, b)) =>
        match a {
          Col(x) =>
            match b {
              Col(y) => if x != y { return false }
              _ => return false
            }
          Lit(x) =>
            match b {
              Lit(y) => if x != y { return false }
              _ => return false
            }
          LitSeries(x) =>
            match b {
              LitSeries(y) => if x != y { return false }
              _ => return false
            }
          Binary(o1, l1, r1) =>
            match b {
              Binary(o2, l2, r2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((l1, l2))
                stack.push((r1, r2))
              }
              _ => return false
            }
          Unary(o1, e1) =>
            match b {
              Unary(o2, e2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Agg(o1, e1) =>
            match b {
              Agg(o2, e2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Str(o1, e1) =>
            match b {
              Str(o2, e2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Cast(e1, t1) =>
            match b {
              Cast(e2, t2) => {
                if t1 != t2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Alias(e1, n1) =>
            match b {
              Alias(e2, n2) => {
                if n1 != n2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Ternary(c1, t1, f1) =>
            match b {
              Ternary(c2, t2, f2) => {
                stack.push((c1, c2))
                stack.push((t1, t2))
                stack.push((f1, f2))
              }
              _ => return false
            }
          FillNull(o1, v1) =>
            match b {
              FillNull(o2, v2) => {
                stack.push((o1, o2))
                stack.push((v1, v2))
              }
              _ => return false
            }
          FillNan(o1, v1) =>
            match b {
              FillNan(o2, v2) => {
                stack.push((o1, o2))
                stack.push((v1, v2))
              }
              _ => return false
            }
          IsIn(e1, m1) =>
            match b {
              // The set is literal data, compared structurally by `Array`'s
              // derived `Eq` (which is `Scalar`'s derived `Eq`: `Int(2)` and
              // `Float(2.0)` are distinct nodes even though `is_in` would match
              // them, and `NaN` members never compare equal — as for a `Lit`).
              IsIn(e2, m2) => {
                if m1 != m2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          IsBetween(x1, l1, h1) =>
            match b {
              IsBetween(x2, l2, h2) => {
                stack.push((x1, x2))
                stack.push((l1, l2))
                stack.push((h1, h2))
              }
              _ => return false
            }
          Map(l1, i1, _) =>
            match b {
              Map(l2, i2, _) => {
                if l1 != l2 || i1.length() != i2.length() {
                  return false
                }
                for k in 0..<i1.length() {
                  stack.push((i1[k], i2[k]))
                }
              }
              _ => return false
            }
        }
    }
  }
  true
}

///|
/// Binary operator tag carried by `Expr::Binary`. `pub` read-only rather
/// than `priv`: a `pub` enum cannot carry a `priv` payload (`[4046]`), and
/// the evaluator in `frame` must `match` the tag cross-package. Inert from
/// the outside — no public API returns a bare `BinOp`, so users never name
/// one; it is not re-exported through the facade.
///
/// `And` / `Or` are the Kleene three-valued logical connectives (`&` / `|`
/// at the call site), not bitwise operations; the comparison tags produce
/// `Bool` columns under the evaluator's null-propagation rules.
pub enum BinOp {
  Add
  Sub
  Mul
  Div
  FloorDiv
  Mod
  Pow
  Eq
  Ne
  Lt
  Le
  Gt
  Ge
  And
  Or
} derive(Eq, Debug)

///|
/// Unary operator tag carried by `Expr::Unary` — same read-only-not-`priv`
/// rationale as `BinOp`. `Neg` is numeric negation (`-e`), `Not` is Kleene
/// logical negation (`not(null) = null`), the null probes
/// `IsNull` / `IsNotNull` read validity only (total, never null), and the NaN
/// probes `IsNan` / `IsNotNan` test a numeric cell for the IEEE `NaN` value.
/// Unlike the null probes, the NaN probes *propagate* nulls — a missing cell
/// is neither NaN nor not-NaN, so the result cell is null — and an `Int` cell
/// is never `NaN`; a non-numeric operand is a `TypeMismatch` at evaluation.
pub enum UnOp {
  Neg
  Not
  IsNull
  IsNotNull
  IsNan
  IsNotNan
  Abs
  Floor
  Ceil
  Sign
  Round
} derive(Eq, Debug)

///|
/// Aggregation tag carried by `Expr::Agg` — same read-only-not-`priv`
/// rationale as `BinOp`. Evaluation inherits the shared reduction kernel's
/// semantics wholesale: `Sum` / `Mean` propagate NaN and `Std` / `Var` (the
/// sample statistics, `ddof = 1`) carry it through the mean; `Min` / `Max` and
/// the order statistic `Median` skip it; `Count` counts non-null cells and
/// `NUnique` the distinct non-null values (NaN one bucket); `First` / `Last`
/// are positional and skip nothing.
///
/// This variant list is mirrored by `@series.ReduceOp`, the constructible
/// vocabulary the reduction kernel speaks (`@expr.AggOp` is read-only outside
/// `expr`, so `frame`'s `reduce_op_of_agg` maps each variant here onto its
/// `ReduceOp` twin one-to-one). Keep the two lists in lockstep — a variant added
/// here must be added to `ReduceOp` and to that 1:1 map, which alone is
/// exhaustive, so the compiler flags a missed map arm but not a missed enum.
pub enum AggOp {
  Sum
  Mean
  Min
  Max
  Count
  Std
  Var
  Median
  NUnique
  First
  Last
} derive(Eq, Debug)

///|
/// String-operation tag carried by `Expr::Str` — same read-only-not-`priv`
/// rationale as `BinOp`. Each variant is one method of the string namespace
/// (`Expr::str_*`); the parameterised ones carry their literal arguments, so
/// a tag is self-contained and structurally comparable — two `Contains("a")`
/// tags are equal, `Contains("a")` and `Contains("b")` are not (which is why
/// the `Str` arm of `Expr`'s handwritten `Eq` can compare tags by `==`).
/// Every operation maps a String cell to its result cell by cell:
/// `ToUppercase` / `ToLowercase` / `StripChars` / `Replace` / `ReplaceAll` /
/// `Reverse` / `PadStart` / `PadEnd` / `ReplaceRegex` / `ReplaceAllRegex` yield
/// a String, `LenChars` an `Int` (the Unicode character count), and the
/// `Contains` / `StartsWith` / `EndsWith` / `ContainsRegex` predicates a
/// `Bool`. Null cells pass through as null and a non-String operand is a
/// `TypeMismatch` at evaluation. `Reverse` reverses Unicode characters
/// (surrogate pairs respected), and the `PadStart` / `PadEnd` widths count
/// characters, both consistent with `LenChars`.
///
/// The `*Regex` variants carry a POSIX regular-expression pattern (the core
/// engine's dialect — `[[:digit:]]`, not the PCRE `\d`); the literal `Contains`
/// / `Replace` / `ReplaceAll` are unchanged. Every operation is per-value total
/// (a null cell nulls out, no *value* can raise), and matching is literal
/// **except** the `*Regex` variants: those compile the pattern **once** per
/// evaluation, so an invalid pattern raises `InvalidOperation` at evaluation —
/// the one non-total path in this namespace, and pattern-, not value-,
/// dependent.
pub enum StrOp {
  ToUppercase
  ToLowercase
  StripChars
  LenChars
  Contains(String)
  StartsWith(String)
  EndsWith(String)
  Replace(String, String)
  ReplaceAll(String, String)
  Reverse
  PadStart(Int, Char)
  PadEnd(Int, Char)
  ContainsRegex(String)
  ReplaceRegex(String, String)
  ReplaceAllRegex(String, String)
} derive(Eq, Debug)
