// Statistics on a `Series`. Split from `series.mbt` so the structural
// surface stays narrow; everything here is a pure reduction over the
// underlying column.

///|
/// Count of non-null cells.
pub fn Series::count(self : Series) -> Int {
  self.len() - self.null_count()
}

///|
/// Sum of the valid (non-null) cells of an `Int` buffer. Factored out so
/// `sum` and `mean` share a single null-skipping accumulation instead of
/// each carrying its own copy.
fn sum_int_valid(data : Array[Int], validity : @column.Bitmap) -> Int {
  data.foldi(init=0, (i, acc, x) => {
    if validity.is_valid(i).unwrap() {
      acc + x
    } else {
      acc
    }
  })
}

///|
/// Sum and count of the valid, non-`NaN` cells of a `Float` buffer.
/// `NaN` is treated as missing (skipped), matching `min` / `max` and
/// `@ops.sort_by`. The sum accumulates in 64-bit `Double` to limit
/// rounding error — the column stores 32-bit `Float`, and naive 32-bit
/// accumulation drifts as the column grows; callers narrow back to
/// `Float`. The returned count excludes both nulls and `NaN`s, which is
/// the denominator `mean` needs (`Series::count` would over-count NaN).
fn sum_count_float_valid(
  data : Array[Float],
  validity : @column.Bitmap,
) -> (Double, Int) {
  data.foldi(init=((0.0 : Double), 0), (i, acc, x) => {
    let (s, c) = acc
    if validity.is_valid(i).unwrap() && !x.is_nan() {
      (s + x.to_double(), c + 1)
    } else {
      (s, c)
    }
  })
}

///|
/// Sum of non-null cells.
///
/// - `Int` series → `Scalar::Int(sum)`. MoonBit's default `Int` is
///   32-bit so very large inputs wrap silently (no overflow trap in
///   v0.1).
/// - `Float` series → `Scalar::Float(sum)`, accumulated in 64-bit
///   `Double` then narrowed. `NaN` cells are skipped (treated as
///   missing, matching `min` / `max` and `@ops.sort_by`).
/// - Empty / all-null (or all-`NaN` `Float`) numeric series →
///   `Scalar::Int(0)` or `Scalar::Float(0.0)` (additive identity).
/// - Non-numeric series (`Bool`, `String`) → `Err(TypeMismatch)`.
pub fn Series::sum(self : Series) -> Result[@types.Scalar, @types.DataError] {
  match self.storage.int_values() {
    Ok((data, validity)) =>
      Ok(@types.Scalar::Int(sum_int_valid(data, validity)))
    Err(_) =>
      match self.storage.float_values() {
        Ok((data, validity)) => {
          let (s, _) = sum_count_float_valid(data, validity)
          Ok(@types.Scalar::Float(Float::from_double(s)))
        }
        Err(_) =>
          Err(
            @types.DataError::TypeMismatch(
              "sum undefined for " + self.dtype().to_string(),
            ),
          )
      }
  }
}

///|
/// Arithmetic mean of non-null cells, returned as `Float`.
///
/// The division is performed in 64-bit `Double` and narrowed to `Float`
/// on return — for both `Int` and `Float` columns — so a long column
/// whose sum exceeds the 24-bit `Float` significand (`> 2^24`) does not
/// lose precision the way a 32-bit `Float::from_int(sum) / cnt` would.
///
/// - Empty / all-null numeric series → `Err(InvalidOperation(...))`.
/// - Non-numeric series → `Err(TypeMismatch(...))`.
pub fn Series::mean(self : Series) -> Result[Float, @types.DataError] {
  let cnt = self.count()
  match self.storage.int_values() {
    Ok((data, validity)) =>
      if cnt == 0 {
        Err(@types.DataError::InvalidOperation("mean of empty/all-null series"))
      } else {
        // Accumulate / divide in Double, then narrow — keeps the result
        // accurate for sums beyond the 24-bit Float significand.
        Ok(
          Float::from_double(
            sum_int_valid(data, validity).to_double() / cnt.to_double(),
          ),
        )
      }
    Err(_) =>
      match self.storage.float_values() {
        Ok((data, validity)) => {
          // NaN cells are skipped, so divide by the non-NaN count, not
          // `cnt` (which counts NaN as present).
          let (s, c) = sum_count_float_valid(data, validity)
          if c == 0 {
            Err(
              @types.DataError::InvalidOperation(
                "mean of empty / all-null / all-NaN series",
              ),
            )
          } else {
            Ok(Float::from_double(s / c.to_double()))
          }
        }
        Err(_) =>
          Err(
            @types.DataError::TypeMismatch(
              "mean undefined for " + self.dtype().to_string(),
            ),
          )
      }
  }
}

///|
/// Minimum non-null cell, by the natural order of the series' dtype.
///
/// - Empty / all-null → `Ok(Scalar::Null)`.
/// - `Float` NaN is treated as missing (skipped), matching `@ops.sort_by`
///   and pandas. A series of only NaN (and/or nulls) returns
///   `Ok(Scalar::Null)`.
/// - `Bool` order: `false < true`.
pub fn Series::min(self : Series) -> Result[@types.Scalar, @types.DataError] {
  match self.storage.int_values() {
    Ok((data, validity)) => {
      let best = data.foldi(init=(None : Int?), (i, acc, x) => {
        if validity.is_valid(i).unwrap() {
          match acc {
            None => Some(x)
            Some(b) => Some(if x < b { x } else { b })
          }
        } else {
          acc
        }
      })
      Ok(
        match best {
          None => @types.Scalar::Null
          Some(b) => @types.Scalar::Int(b)
        },
      )
    }
    Err(_) =>
      match self.storage.float_values() {
        Ok((data, validity)) => {
          let best = data.foldi(init=(None : Float?), (i, acc, x) => {
            // NaN is treated as missing (skipped), matching `@ops.sort_by`.
            if validity.is_valid(i).unwrap() && !x.is_nan() {
              match acc {
                None => Some(x)
                Some(b) => Some(if x < b { x } else { b })
              }
            } else {
              acc
            }
          })
          Ok(
            match best {
              None => @types.Scalar::Null
              Some(b) => @types.Scalar::Float(b)
            },
          )
        }
        Err(_) =>
          match self.storage.bool_values() {
            Ok((data, validity)) => {
              let best = data.foldi(init=(None : Bool?), (i, acc, x) => {
                if validity.is_valid(i).unwrap() {
                  match acc {
                    None => Some(x)
                    // `false < true`: switch to false the first time one
                    // is seen, then stay there.
                    Some(b) => Some(if !x && b { false } else { b })
                  }
                } else {
                  acc
                }
              })
              Ok(
                match best {
                  None => @types.Scalar::Null
                  Some(b) => @types.Scalar::Bool(b)
                },
              )
            }
            Err(_) => {
              // The remaining dtype is `String` — `string_values`
              // cannot fail here.
              let (data, validity) = self.storage.string_values().unwrap()
              let best = data.foldi(init=(None : String?), (i, acc, x) => {
                if validity.is_valid(i).unwrap() {
                  match acc {
                    None => Some(x)
                    Some(b) =>
                      Some(
                        if @types.compare_string_lex(x, b) < 0 {
                          x
                        } else {
                          b
                        },
                      )
                  }
                } else {
                  acc
                }
              })
              Ok(
                match best {
                  None => @types.Scalar::Null
                  Some(b) => @types.Scalar::String(b)
                },
              )
            }
          }
      }
  }
}

///|
/// Maximum non-null cell. Mirrors `min` with `>` in place of `<`; the
/// `Float` NaN and empty-series rules are identical.
pub fn Series::max(self : Series) -> Result[@types.Scalar, @types.DataError] {
  match self.storage.int_values() {
    Ok((data, validity)) => {
      let best = data.foldi(init=(None : Int?), (i, acc, x) => {
        if validity.is_valid(i).unwrap() {
          match acc {
            None => Some(x)
            Some(b) => Some(if x > b { x } else { b })
          }
        } else {
          acc
        }
      })
      Ok(
        match best {
          None => @types.Scalar::Null
          Some(b) => @types.Scalar::Int(b)
        },
      )
    }
    Err(_) =>
      match self.storage.float_values() {
        Ok((data, validity)) => {
          let best = data.foldi(init=(None : Float?), (i, acc, x) => {
            // NaN is treated as missing (skipped), matching `@ops.sort_by`.
            if validity.is_valid(i).unwrap() && !x.is_nan() {
              match acc {
                None => Some(x)
                Some(b) => Some(if x > b { x } else { b })
              }
            } else {
              acc
            }
          })
          Ok(
            match best {
              None => @types.Scalar::Null
              Some(b) => @types.Scalar::Float(b)
            },
          )
        }
        Err(_) =>
          match self.storage.bool_values() {
            Ok((data, validity)) => {
              let best = data.foldi(init=(None : Bool?), (i, acc, x) => {
                if validity.is_valid(i).unwrap() {
                  match acc {
                    None => Some(x)
                    // `true > false`: switch to true the first time one
                    // is seen, then stay there.
                    Some(b) => Some(if x && !b { true } else { b })
                  }
                } else {
                  acc
                }
              })
              Ok(
                match best {
                  None => @types.Scalar::Null
                  Some(b) => @types.Scalar::Bool(b)
                },
              )
            }
            Err(_) => {
              // The remaining dtype is `String` — `string_values`
              // cannot fail here.
              let (data, validity) = self.storage.string_values().unwrap()
              let best = data.foldi(init=(None : String?), (i, acc, x) => {
                if validity.is_valid(i).unwrap() {
                  match acc {
                    None => Some(x)
                    Some(b) =>
                      Some(
                        if @types.compare_string_lex(x, b) > 0 {
                          x
                        } else {
                          b
                        },
                      )
                  }
                } else {
                  acc
                }
              })
              Ok(
                match best {
                  None => @types.Scalar::Null
                  Some(b) => @types.Scalar::String(b)
                },
              )
            }
          }
      }
  }
}

///|
/// Number of distinct non-null values. The value-form rendering
/// (`Scalar::to_string`) is used as the canonical key — within a
/// fixed-dtype series two cells collide only when their values are
/// equal. As a deliberate consequence, every `Float` NaN collapses to
/// a single bucket (its `to_string` is `"NaN"`), matching pandas'
/// `nunique` behaviour on NaN-only inputs.
pub fn Series::unique_count(self : Series) -> Int {
  let n = self.len()
  let seen : Map[String, Unit] = {}
  for i in 0..<n {
    // `is_null` cannot fail in `[0, n)`.
    if !self.storage.is_null(i).unwrap() {
      // `get` cannot fail in `[0, n)` and only returns `Scalar::Null`
      // when `is_null` would have been true — already excluded above.
      let s = self.storage.get(i).unwrap().to_string()
      seen[s] = ()
    }
  }
  seen.length()
}

///|
/// One-row summary `DataFrame`.
///
/// Every series produces `count`, `null_count`, and `unique_count`
/// (`Int`). Numeric series additionally carry `mean` (`Float`, `Null`
/// when the series is empty / all-null). All dtypes carry `min` and
/// `max` in the source dtype, with `Null` cells when the reduction has
/// no value (empty / all-null).
///
/// Column order:
/// - numeric (`Int` / `Float`): `count`, `null_count`, `unique_count`,
///   `mean`, `min`, `max`.
/// - `Bool` / `String`: `count`, `null_count`, `unique_count`, `min`,
///   `max`.
///
/// The dispatch chains through the typed accessors
/// (`int_values` / `float_values` / `bool_values` / `string_values`)
/// rather than matching on `DataType`. That keeps the function total —
/// `Series` storage is always one of the four concrete dtypes, so the
/// `String` branch (the last `Err(_) =>`) is the unambiguous fallback
/// and there's no dead `Null`-dtype arm to keep in sync.
pub fn Series::describe(self : Series) -> DataFrame {
  let cols : Array[Series] = []
  cols.push(Series::from_ints("count", [self.count()]))
  cols.push(Series::from_ints("null_count", [self.null_count()]))
  cols.push(Series::from_ints("unique_count", [self.unique_count()]))
  match self.storage.int_values() {
    Ok(_) => describe_push_int_stats(self, cols)
    Err(_) =>
      match self.storage.float_values() {
        Ok(_) => describe_push_float_stats(self, cols)
        Err(_) =>
          match self.storage.bool_values() {
            Ok(_) => describe_push_bool_stats(self, cols)
            // The remaining dtype is `String` — `string_values`
            // cannot fail here.
            Err(_) => describe_push_string_stats(self, cols)
          }
      }
  }
  // Names are hardcoded and unique, every column has length 1 — the
  // constructor cannot fail. `unwrap` here is a structural assertion,
  // not a real error path.
  DataFrame::new(cols).unwrap()
}

///|
/// Append `mean`, `min`, `max` columns for an `Int` series.
fn describe_push_int_stats(s : Series, cols : Array[Series]) -> Unit {
  let mean_col = match s.mean() {
    Ok(v) => Series::from_float_options("mean", [Some(v)])
    Err(_) => Series::from_float_options("mean", [None])
  }
  cols.push(mean_col)
  let min_cell : Int? = match s.min().unwrap() {
    @types.Scalar::Int(x) => Some(x)
    _ => None
  }
  let max_cell : Int? = match s.max().unwrap() {
    @types.Scalar::Int(x) => Some(x)
    _ => None
  }
  cols.push(Series::from_int_options("min", [min_cell]))
  cols.push(Series::from_int_options("max", [max_cell]))
}

///|
/// Append `mean`, `min`, `max` columns for a `Float` series.
fn describe_push_float_stats(s : Series, cols : Array[Series]) -> Unit {
  let mean_col = match s.mean() {
    Ok(v) => Series::from_float_options("mean", [Some(v)])
    Err(_) => Series::from_float_options("mean", [None])
  }
  cols.push(mean_col)
  let min_cell : Float? = match s.min().unwrap() {
    @types.Scalar::Float(x) => Some(x)
    _ => None
  }
  let max_cell : Float? = match s.max().unwrap() {
    @types.Scalar::Float(x) => Some(x)
    _ => None
  }
  cols.push(Series::from_float_options("min", [min_cell]))
  cols.push(Series::from_float_options("max", [max_cell]))
}

///|
/// Append `min`, `max` columns for a `Bool` series (no `mean`).
fn describe_push_bool_stats(s : Series, cols : Array[Series]) -> Unit {
  let min_cell : Bool? = match s.min().unwrap() {
    @types.Scalar::Bool(x) => Some(x)
    _ => None
  }
  let max_cell : Bool? = match s.max().unwrap() {
    @types.Scalar::Bool(x) => Some(x)
    _ => None
  }
  cols.push(Series::from_bool_options("min", [min_cell]))
  cols.push(Series::from_bool_options("max", [max_cell]))
}

///|
/// Append `min`, `max` columns for a `String` series (no `mean`).
fn describe_push_string_stats(s : Series, cols : Array[Series]) -> Unit {
  let min_cell : String? = match s.min().unwrap() {
    @types.Scalar::String(x) => Some(x)
    _ => None
  }
  let max_cell : String? = match s.max().unwrap() {
    @types.Scalar::String(x) => Some(x)
    _ => None
  }
  cols.push(Series::from_string_options("min", [min_cell]))
  cols.push(Series::from_string_options("max", [max_cell]))
}
