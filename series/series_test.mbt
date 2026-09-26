// Blackbox tests for `Series` (structural surface). Statistics have their
// own tests; so does the storage-backend machine
// (with a cell-level parity harness beside it).

// ── Constructors ─────────────────────────────────────────────────────

///|
test "from_ints / from_int_options" {
  let raw = Series::from_ints("x", [1, 2, 3])
  assert_eq(raw.dtype(), @types.DataType::Int)
  assert_eq(raw.len(), 3)
  assert_eq(raw.null_count(), 0)
  // No-null raw constructor lands on the Numeric fast path...
  assert_eq(raw.storage_kind(), @column.StorageKind::Numeric)
  let opt = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(opt.null_count(), 1)
  assert_eq(opt.get(1), @types.Scalar::Null)
  // ...the nullable option constructor stays Builtin.
  assert_eq(opt.storage_kind(), @column.StorageKind::Builtin)
}

///|
test "from_floats / from_float_options" {
  let raw = Series::from_floats("x", [1.5, 2.5])
  assert_eq(raw.dtype(), @types.DataType::Float)
  assert_eq(raw.null_count(), 0)
  let opt = Series::from_float_options("x", [None, Some(1.0)])
  assert_eq(opt.null_count(), 1)
}

///|
test "from_bools / from_bool_options" {
  let raw = Series::from_bools("flag", [true, false, true])
  assert_eq(raw.dtype(), @types.DataType::Bool)
  let opt = Series::from_bool_options("flag", [Some(true), None, None])
  assert_eq(opt.null_count(), 2)
}

///|
test "from_strings / from_string_options" {
  let raw = Series::from_strings("name", ["a", "b"])
  assert_eq(raw.dtype(), @types.DataType::String)
  let opt = Series::from_string_options("name", [Some("x"), None])
  assert_eq(opt.len(), 2)
  assert_eq(opt.null_count(), 1)
}

///|
test "from_scalars infers the dtype from the first non-null cell" {
  // A leading null does not decide anything; the first non-null cell does,
  // and later cells of the same dtype build through it.
  let s = Series::from_scalars("x", [
    @types.Scalar::Null,
    @types.Scalar::Int(1),
    @types.Scalar::Null,
  ])
  assert_eq(s.dtype(), @types.DataType::Int)
  assert_eq(s.null_count(), 2)
  assert_eq(s.get(1), @types.Scalar::Int(1))
  // A nullable build stays on the Builtin backend.
  assert_eq(s.storage_kind(), @column.StorageKind::Builtin)
  // Every dtype reaches the same way — one constructor, five columns.
  let f = Series::from_scalars("x", [@types.Scalar::Float(1.5)])
  assert_eq(f.dtype(), @types.DataType::Float)
  let b = Series::from_scalars("x", [@types.Scalar::Bool(true)])
  assert_eq(b.dtype(), @types.DataType::Bool)
  let t = Series::from_scalars("x", [@types.Scalar::String("ab")])
  assert_eq(t.dtype(), @types.DataType::String)
}

///|
test "from_scalars is the public way to build a Date column" {
  let s = Series::from_scalars("d", [
    @types.Scalar::Date(5L),
    @types.Scalar::Null,
  ])
  assert_eq(s.dtype(), @types.DataType::Date)
  assert_eq(s.null_count(), 1)
  assert_eq(s.get(0), @types.Scalar::Date(5L))
}

///|
test "from_scalars with dtype~ locks the column dtype" {
  // Locking agrees with the cells: same build as inference.
  let ok = Series::from_scalars(
    "x",
    [@types.Scalar::Null, @types.Scalar::Int(7)],
    dtype=@types.DataType::Int,
  )
  assert_eq(ok.dtype(), @types.DataType::Int)
  assert_eq(ok.null_count(), 1)
  // An all-null column is buildable only through a locked dtype.
  let all_null = Series::from_scalars(
    "x",
    [@types.Scalar::Null, @types.Scalar::Null],
    dtype=@types.DataType::Float,
  )
  assert_eq(all_null.dtype(), @types.DataType::Float)
  assert_eq(all_null.null_count(), 2)
}

///|
test "from_scalars refuses a foreign cell on every dtype arm" {
  // Each remaining arm meets a foreign non-null cell once: a Bool column
  // handed an Int, a String column handed a Bool, a Date column handed a
  // String. `assert_eq` against the whole error — a lowercase identifier in
  // an `is` pattern would bind, not compare, and assert nothing.
  fn foreign(
    target : @types.DataType,
    cell : @types.Scalar,
  ) -> Result[Series, @types.DataError] {
    Ok(Series::from_scalars("x", [@types.Scalar::Null, cell], dtype=target)) catch {
      e => Err(e)
    }
  }
  assert_eq(
    foreign(@types.DataType::Bool, @types.Scalar::Int(1)),
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Expected(
          @types.DataType::Bool,
          @types.DataType::Int,
          "x",
        ),
      ),
    ),
  )
  assert_eq(
    foreign(@types.DataType::String, @types.Scalar::Bool(true)),
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Expected(
          @types.DataType::String,
          @types.DataType::Bool,
          "x",
        ),
      ),
    ),
  )
  assert_eq(
    foreign(@types.DataType::Date, @types.Scalar::String("x")),
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Expected(
          @types.DataType::Date,
          @types.DataType::String,
          "x",
        ),
      ),
    ),
  )
}

///|
test "from_scalars raises on the unbuildable targets" {
  // Nothing to infer from: every cell is null and no dtype~ was passed.
  assert_true(
    (Ok(Series::from_scalars("x", [@types.Scalar::Null, @types.Scalar::Null])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // A Null target names no physical column, locked or otherwise.
  assert_true(
    (Ok(
      Series::from_scalars(
        "x",
        [@types.Scalar::Null],
        dtype=@types.DataType::Null,
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
}

///|
test "from_scalars refuses a foreign cell in cell order" {
  // Without dtype~ the first non-null cell decides, and the Float cell
  // after it is foreign.
  assert_true(
    (Ok(
      Series::from_scalars("x", [
        @types.Scalar::Int(1),
        @types.Scalar::Float(2.0),
      ]),
    ) catch {
      e => Err(e)
    })
    is Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Expected(
          @types.DataType::Int,
          @types.DataType::Float,
          "x"
        )
      )
    ),
  )
  // With dtype~ locked, the Int cell is foreign to the Float column — an
  // Int-to-Float promotion is a cast, not a construction.
  assert_true(
    (Ok(
      Series::from_scalars(
        "x",
        [@types.Scalar::Null, @types.Scalar::Int(1)],
        dtype=@types.DataType::Float,
      ),
    ) catch {
      e => Err(e)
    })
    is Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Expected(
          @types.DataType::Float,
          @types.DataType::Int,
          "x"
        )
      )
    ),
  )
}

///|
// Defensive copy at the Series boundary: a Series is independent of the
// caller's array, on both backends (Numeric for raw ints, Builtin for strings).
test "raw Series constructors copy their input" {
  let ints : Array[Int64] = [1, 2, 3]
  let si = Series::from_ints("x", ints)
  ints[0] = 99
  assert_eq(si.get(0), @types.Scalar::Int(1))
  let strs = ["a", "b"]
  let ss = Series::from_strings("s", strs)
  strs[0] = "z"
  assert_eq(ss.get(0), @types.Scalar::String("a"))
}

///|
test "structural equality compares name + storage" {
  assert_eq(Series::from_ints("a", [1, 2]), Series::from_ints("a", [1, 2]))
  // Same content, different name → not equal.
  assert_not_eq(Series::from_ints("a", [1, 2]), Series::from_ints("b", [1, 2]))
  // Same name, different content → not equal.
  assert_not_eq(Series::from_ints("a", [1, 2]), Series::from_ints("a", [1, 3]))
}

// ── Inspection ───────────────────────────────────────────────────────

///|
test "is_empty true on zero-length, false otherwise" {
  let empty = Series::from_ints("x", [])
  assert_true(empty.is_empty())
  assert_eq(empty.len(), 0)
  let one = Series::from_ints("x", [0])
  assert_false(one.is_empty())
}

///|
test "is_null returns the validity for in-bounds, IndexOutOfBounds otherwise" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(s.is_null(0), false)
  assert_eq(s.is_null(1), true)
  assert_eq(
    Ok(s.is_null(-1)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    Ok(s.is_null(3)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(3)),
  )
}

///|
test "get returns Scalar / Null / IndexOutOfBounds" {
  let s = Series::from_int_options("x", [Some(7), None])
  assert_eq(s.get(0), @types.Scalar::Int(7))
  assert_eq(s.get(1), @types.Scalar::Null)
  assert_eq(
    Ok(s.get(5)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
}

///|
test "storage exposes the underlying column unchanged" {
  // A `String` column is always `Builtin`-backed, so the public constructor
  // reaches the same storage the seam hands back.
  let s = Series::from_strings("c", ["x", "y"])
  assert_eq(
    s.storage(),
    @column.ColumnStorage::Builtin(
      @column.BuiltinColumn::from_strings(["x", "y"]),
    ),
  )
}

// ── rename ───────────────────────────────────────────────────────────

///|
test "rename returns a new series with the new name, sharing storage" {
  let s = Series::from_ints("a", [1, 2])
  let r = s.rename("b")
  assert_eq(r.name(), "b")
  // Original unaffected.
  assert_eq(s.name(), "a")
  assert_eq(r.storage(), s.storage())
}

// ── slice ────────────────────────────────────────────────────────────

///|
test "slice mid-range produces a sub-series preserving name + nulls" {
  let s = Series::from_int_options("x", [Some(10), None, Some(30), Some(40)])
  let part = s.slice(1, length=2)
  assert_eq(part.name(), "x")
  assert_eq(part.len(), 2)
  assert_eq(part.get(0), @types.Scalar::Null)
  assert_eq(part.get(1), @types.Scalar::Int(30))
}

///|
test "slice saturates like the frame verb: negative offset from the end, omitted length to the end" {
  let s = Series::from_ints("x", [1, 2, 3, 4, 5])
  assert_eq(s.slice(2).to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(4),
    @types.Scalar::Int(5),
  ])
  assert_eq(s.slice(-2).to_scalars(), [
    @types.Scalar::Int(4),
    @types.Scalar::Int(5),
  ])
  // Saturation on both ends, and a negative length is an empty window.
  assert_eq(s.slice(-99).len(), 5)
  assert_eq(s.slice(1, length=99).len(), 4)
  assert_eq(s.slice(2, length=-5).len(), 0)
}

// ── gather ───────────────────────────────────────────────────────────

///|
test "gather collects with duplicates and preserves nulls" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3)])
  let out = s.gather([2, 1, 0, 1])
  assert_eq(out.name(), "x")
  assert_eq(out.len(), 4)
  assert_eq(out.get(0), @types.Scalar::Int(3))
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(3), @types.Scalar::Null)
}

///|
test "gather with empty index array returns empty series" {
  let s = Series::from_ints("x", [1, 2])
  let out = s.gather([])
  assert_true(out.is_empty())
  assert_eq(out.name(), "x")
  assert_eq(out.dtype(), @types.DataType::Int)
}

///|
test "gather out-of-bounds reports the first offender" {
  let s = Series::from_ints("x", [1, 2])
  assert_eq(
    Ok(s.gather([0, 5])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_eq(
    Ok(s.gather([-1])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
}

// ── drop_nulls ───────────────────────────────────────────────────────

///|
test "drop_nulls removes every null, shrinking length" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3), None, Some(5)])
  let cleaned = s.drop_nulls()
  assert_eq(cleaned.name(), "x")
  assert_eq(cleaned.len(), 3)
  assert_eq(cleaned.null_count(), 0)
  assert_eq(cleaned.get(0), @types.Scalar::Int(1))
  assert_eq(cleaned.get(1), @types.Scalar::Int(3))
  assert_eq(cleaned.get(2), @types.Scalar::Int(5))
}

///|
test "drop_nulls is a no-op when there are no nulls" {
  let s = Series::from_ints("x", [1, 2, 3])
  let out = s.drop_nulls()
  assert_eq(out, s)
}

///|
test "drop_nulls on all-null produces an empty series" {
  let s = Series::from_int_options("x", [None, None])
  let out = s.drop_nulls()
  assert_eq(out.len(), 0)
  assert_eq(out.dtype(), @types.DataType::Int)
}

///|
test "drop_nulls on empty series returns empty series" {
  let s = Series::from_int_options("x", [])
  let out = s.drop_nulls()
  assert_true(out.is_empty())
}

// ── fill_null ────────────────────────────────────────────────────────

///|
test "fill_null on Int series fills nulls with the given Int" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3), None])
  let out = s.fill_null(@types.Scalar::Int(0))
  assert_eq(out.null_count(), 0)
  assert_eq(out.get(0), @types.Scalar::Int(1))
  assert_eq(out.get(1), @types.Scalar::Int(0))
  assert_eq(out.get(2), @types.Scalar::Int(3))
  assert_eq(out.get(3), @types.Scalar::Int(0))
}

///|
test "fill_null on Float series fills nulls with the given Float" {
  let s = Series::from_float_options("x", [None, Some(2.5)])
  let out = s.fill_null(@types.Scalar::Float(1.5))
  assert_eq(out.get(0), @types.Scalar::Float(1.5))
  assert_eq(out.get(1), @types.Scalar::Float(2.5))
}

///|
test "fill_null on Bool series fills nulls with the given Bool" {
  let s = Series::from_bool_options("x", [Some(true), None, None])
  let out = s.fill_null(@types.Scalar::Bool(false))
  assert_eq(out.get(0), @types.Scalar::Bool(true))
  assert_eq(out.get(1), @types.Scalar::Bool(false))
  assert_eq(out.get(2), @types.Scalar::Bool(false))
}

///|
test "fill_null on String series fills nulls with the given String" {
  let s = Series::from_string_options("x", [Some("a"), None])
  let out = s.fill_null(@types.Scalar::String("z"))
  assert_eq(out.get(0), @types.Scalar::String("a"))
  assert_eq(out.get(1), @types.Scalar::String("z"))
}

///|
test "fill_null rejects Scalar::Null fill values" {
  let s = Series::from_int_options("x", [Some(1), None])
  assert_true(
    (Ok(s.fill_null(@types.Scalar::Null)) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}

///|
test "fill_null rejects dtype-mismatched Int fill" {
  let s = Series::from_floats("x", [1.0])
  assert_true(
    (Ok(s.fill_null(@types.Scalar::Int(0))) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}

///|
test "fill_null rejects dtype-mismatched Float fill" {
  let s = Series::from_ints("x", [1])
  assert_true(
    (Ok(s.fill_null(@types.Scalar::Float(0.0))) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}

///|
test "fill_null rejects dtype-mismatched Bool fill" {
  let s = Series::from_ints("x", [1])
  assert_true(
    (Ok(s.fill_null(@types.Scalar::Bool(true))) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}

///|
test "fill_null rejects dtype-mismatched String fill" {
  let s = Series::from_ints("x", [1])
  assert_true(
    (Ok(s.fill_null(@types.Scalar::String("z"))) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}

// ── cast (Int / Float / String targets) ──────────────────────────────
// `cast(dtype)` is the single cross-dtype entry; the per-source-dtype
// behaviour pinned below is what the retired `to_int` / `to_float` /
// `to_string_series` convenience wrappers used to expose.

///|
test "cast dispatches by target dtype" {
  let s = Series::from_ints("x", [1, 2, 3])
  assert_eq(s.cast(@types.DataType::Int).dtype(), @types.DataType::Int)
  assert_eq(s.cast(@types.DataType::Float).dtype(), @types.DataType::Float)
  assert_eq(s.cast(@types.DataType::String).dtype(), @types.DataType::String)
  assert_true(
    (Ok(s.cast(@types.DataType::Bool)) catch { e => Err(e) })
    is Err(Unsupported(_)),
  )
  assert_true(
    (Ok(s.cast(@types.DataType::Null)) catch { e => Err(e) })
    is Err(Unsupported(_)),
  )
}

///|
test "cast to Int: identity / Float→Int / Bool→Int / String→Int" {
  let i = Series::from_ints("x", [1, 2])
  // cast borrows the Builtin road, so an identity Int→Int cast materialises
  // onto the Builtin backend — it equals the widened original, not `i` itself.
  assert_eq(i.cast(@types.DataType::Int), builtin_twin(i))
  assert_eq(
    i.cast(@types.DataType::Int).storage_kind(),
    @column.StorageKind::Builtin,
  )
  let f = Series::from_floats("x", [1.5, 2.7])
  let f_to_i = f.cast(@types.DataType::Int)
  assert_eq(f_to_i.get(0), @types.Scalar::Int(1))
  let b = Series::from_bools("x", [true, false])
  let b_to_i = b.cast(@types.DataType::Int)
  assert_eq(b_to_i.get(0), @types.Scalar::Int(1))
  assert_eq(b_to_i.get(1), @types.Scalar::Int(0))
  let bad = Series::from_strings("x", ["nope"])
  assert_true(
    (Ok(bad.cast(@types.DataType::Int)) catch { e => Err(e) })
    is Err(ParseError(_)),
  )
}

///|
test "cast to Float: identity / Int→Float / Bool→Float / String→Float" {
  let f = Series::from_floats("x", [1.0])
  // Same as the Int cast: identity Float→Float materialises onto the Builtin
  // backend.
  assert_eq(f.cast(@types.DataType::Float), builtin_twin(f))
  let i = Series::from_ints("x", [3])
  assert_eq(i.cast(@types.DataType::Float).get(0), @types.Scalar::Float(3.0))
  let b = Series::from_bools("x", [true, false])
  let b_to_f = b.cast(@types.DataType::Float)
  assert_eq(b_to_f.get(0), @types.Scalar::Float(1.0))
  assert_eq(b_to_f.get(1), @types.Scalar::Float(0.0))
  let bad = Series::from_strings("x", ["x"])
  assert_true(
    (Ok(bad.cast(@types.DataType::Float)) catch { e => Err(e) })
    is Err(ParseError(_)),
  )
}

///|
test "cast to String renders value-style across dtypes" {
  let i = Series::from_int_options("x", [Some(7), None])
  let s_i = i.cast(@types.DataType::String)
  assert_eq(s_i.get(0), @types.Scalar::String("7"))
  assert_eq(s_i.get(1), @types.Scalar::Null)
  let f = Series::from_floats("x", [1.5])
  assert_eq(
    f.cast(@types.DataType::String).get(0),
    @types.Scalar::String("1.5"),
  )
  let b = Series::from_bools("x", [true, false])
  let s_b = b.cast(@types.DataType::String)
  assert_eq(s_b.get(0), @types.Scalar::String("true"))
  assert_eq(s_b.get(1), @types.Scalar::String("false"))
  let s = Series::from_strings("x", ["already"])
  assert_eq(s.cast(@types.DataType::String), s)
}

// ── ordering verbs ────────────────────────────────────────────────────

///|
test "Series::sort orders values, defaulting to ascending with nulls first, as Polars" {
  let s = @series.Series::from_int_options("v", [
    Some(3),
    None,
    Some(1),
    Some(2),
  ])
  assert_eq(s.sort().to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
  // Missing placement is direction-independent, as in Polars:
  // `nulls_last = false` keeps nulls leading even under `descending` —
  // the flag says where nulls sit, and only the value comparison turns
  // around.
  assert_eq(s.sort(descending=true).to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(3),
    @types.Scalar::Int(2),
    @types.Scalar::Int(1),
  ])
  assert_eq(s.sort(nulls_last=true).to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
    @types.Scalar::Null,
  ])
  // The name rides along; sorting an empty series is the empty series.
  assert_eq(s.sort().name(), "v")
  assert_eq(@series.Series::from_ints("e", []).sort().len(), 0)
}

///|
test "Series::sort orders NaN as a value, independent of the null placement" {
  let nan = 0.0 / 0.0
  let s = @series.Series::from_float_options("f", [
    Some(2.5),
    Some(nan),
    Some(1.5),
    None,
  ])
  // Ascending, default nulls first: the null leads (it is missing), then
  // the values in order, with the NaN — the total order's largest — last.
  let asc = s.sort().to_scalars()
  assert_eq(asc[0], @types.Scalar::Null)
  assert_eq(asc[1], @types.Scalar::Float(1.5))
  assert_eq(asc[2], @types.Scalar::Float(2.5))
  assert_true(
    match asc[3] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  // Descending: the null still leads the missing placement
  // (direction-independent), then the values with the NaN — the largest —
  // first.
  let desc = s.sort(descending=true).to_scalars()
  assert_eq(desc[0], @types.Scalar::Null)
  assert_true(
    match desc[1] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  assert_eq(desc[2], @types.Scalar::Float(2.5))
  assert_eq(desc[3], @types.Scalar::Float(1.5))
  // Nulls last moves only the null; the NaN keeps its value position.
  let tail = s.sort(nulls_last=true).to_scalars()
  assert_eq(tail[0], @types.Scalar::Float(1.5))
  assert_eq(tail[3], @types.Scalar::Null)
}

///|
test "Series::head / tail / reverse mirror the DataFrame verbs" {
  let s = @series.Series::from_ints("v", [1, 2, 3, 4])
  assert_eq(s.head(2).to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
  assert_eq(s.tail(2).to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(4),
  ])
  assert_eq(s.reverse().to_scalars(), [
    @types.Scalar::Int(4),
    @types.Scalar::Int(3),
    @types.Scalar::Int(2),
    @types.Scalar::Int(1),
  ])
  // Clamping: an oversized count is everything; a negative one drops from
  // the opposite end, as Polars' head / tail do.
  assert_eq(s.head(-1).len(), 3)
  assert_eq(s.head(-1).get(2), @types.Scalar::Int(3))
  assert_eq(s.tail(-1).len(), 3)
  assert_eq(s.tail(-1).get(0), @types.Scalar::Int(2))
  assert_eq(s.head(99), s)
  assert_eq(s.tail(99), s)
  // Names ride along, and reversing twice is the identity.
  assert_eq(s.reverse().name(), "v")
  assert_eq(s.reverse().reverse(), s)
}

// ── reduction column builder ─────────────────────────────────────────

///|
test "scalars_to_series projects reduced cells onto the probe dtype" {
  // The probe fixes the dtype; each cell projects "matching variant → value,
  // anything else (including Null) → null". An all-valid numeric result then
  // converges onto the Numeric backend, like every other computed column.
  let ints = scalars_to_series(@types.DataType::Int, "n", [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
  assert_eq(ints.dtype(), @types.DataType::Int)
  assert_eq(ints.storage_kind(), @column.StorageKind::Numeric)
  let mixed = scalars_to_series(@types.DataType::Float, "f", [
    @types.Scalar::Float(1.5),
    @types.Scalar::Int(2),
    @types.Scalar::Null,
  ])
  assert_eq(mixed.to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  assert_eq(mixed.storage_kind(), @column.StorageKind::Builtin)
}

///|
test "scalars_to_series rejects Null, the dtype with no column backend" {
  // No reduction can produce it — `reducer_for`'s probes come from a column's
  // own dtype and `infer_cells_dtype` returns `None` rather than `Null` — so
  // this arm exists to keep the projection total over `DataType`, and says so
  // the same way `Series::empty_of` does.
  assert_eq(
    Ok(scalars_to_series(@types.DataType::Null, "n", [@types.Scalar::Null])) catch {
      e => Err(e)
    },
    Err(@types.DataError::Unsupported("cannot build a column of dtype Null: n")),
  )
}

///|
test "s[i] reads a cell (no negative wrap); s[a:b] is the bracket-slice sugar" {
  let s = Series::from_int_options("v", [Some(1), None, Some(3), Some(4)])
  assert_eq(s[0], @types.Scalar::Int(1))
  assert_eq(s[1], @types.Scalar::Null)
  assert_true(
    (Ok(s[9]) catch { e => Err(e) })
    is Err(@types.DataError::IndexOutOfBounds(9)),
  )
  // MoonBit indexing convention: a negative index raises rather than
  // wrapping — negatives count from the end in the slice spelling only.
  assert_true(
    (Ok(s[-1]) catch { e => Err(e) })
    is Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(s[1:3].len(), 2)
  assert_eq(s[1:3].get(0), @types.Scalar::Null)
  assert_eq(s[2:].len(), 2)
  assert_eq(s[:2].len(), 2)
  assert_eq(s[:].len(), 4)
  assert_eq(s[:-1].len(), 3)
  assert_eq(s[-2:].get(0), @types.Scalar::Int(3))
  assert_eq(s[3:1].len(), 0)
  assert_eq(s[1:3], s.slice(1, length=2))
}

///|
test "sort places equal-NaN and signed-zero cells stably" {
  let nan = 0.0 / 0.0
  // Two NaNs compare equal under the total order, so the stable sort keeps
  // their input order.
  let s = @series.Series::from_float_options("f", [
    Some(nan),
    Some(1.0),
    Some(nan),
  ])
  let sorted = s.sort().to_scalars()
  assert_eq(sorted[0], @types.Scalar::Float(1.0))
  assert_true(
    match sorted[1] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  assert_true(
    match sorted[2] {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
  // `-0.0` and `+0.0` compare equal (IEEE-equal), so the sort keeps their
  // input order too rather than ordering by sign.
  let z = @series.Series::from_floats("z", [-0.0, 0.0, -0.0])
  let zs = z.sort().to_scalars()
  assert_true(
    match zs[0] {
      @types.Scalar::Float(v) => v == 0.0 && 1.0 / v == @double.neg_infinity
      _ => false
    },
  )
}
