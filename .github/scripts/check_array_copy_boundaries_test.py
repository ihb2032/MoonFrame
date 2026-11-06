#!/usr/bin/env python3
"""Focused regression tests for the MoonBit Array ownership guard.

Two halves: `retained_parameters`, the lexical judgement about one function, and
the repository walk that decides *which* functions it is asked about. The second
half used to go untested, which is the half whose failure is silent — a guard
that looks at nothing still prints that it passed.
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

from check_array_copy_boundaries import audit, retained_parameters, source_files


class ArrayCopyBoundaryTests(unittest.TestCase):
    def retained(self, body: str) -> list[str]:
        return retained_parameters(body)

    def test_bare_constructor(self) -> None:
        source = """pub fn Plan::new(values : Array[Int]) -> Plan {
  Values(values)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_type_qualified_constructor(self) -> None:
        source = """pub fn Plan::new(values : Array[Int]) -> Plan {
  PlanNode::Values(values)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_package_and_type_qualified_constructor(self) -> None:
        source = """pub fn Plan::new(values : Array[Int]) -> Plan {
  @plan.PlanNode::Values(values)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_explicit_record_field(self) -> None:
        source = """pub fn Box::new(values : Array[Int]) -> Box {
  { other: values }
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_record_field_shorthand(self) -> None:
        source = """pub fn Box::new(values : Array[Int]) -> Box {
  { values }
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_explicit_copy_is_safe(self) -> None:
        source = """pub fn Box::new(values : Array[Int]) -> Box {
  { values: values.copy() }
}"""
        self.assertEqual(self.retained(source), [])

    def test_nested_transparent_wrappers(self) -> None:
        source = """pub fn Plan::new(values : Array[Int]) -> Res {
  Res(Ok(Some(values)))
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_assignment_whose_rhs_is_the_parameter(self) -> None:
        # `=` is not `:` — a mut field or a global stash written through
        # plain assignment retains the array just like a record literal.
        source = """pub fn stash(values : Array[Int]) -> Unit {
  sink = values
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_field_path_assignment_is_retention_too(self) -> None:
        source = """pub fn load(self : Box, values : Array[Int]) -> Unit {
  self.held = values
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_assignment_of_a_copy_is_safe(self) -> None:
        source = """pub fn stash(values : Array[Int]) -> Unit {
  sink = values.copy()
}"""
        self.assertEqual(self.retained(source), [])

    def test_assignment_with_other_rhs_is_untouched(self) -> None:
        source = """pub fn stash(values : Array[Int]) -> Unit {
  sink = values.len()
  other = 1 + 2
}"""
        self.assertEqual(self.retained(source), [])

    def test_retention_through_a_single_hop_alias(self) -> None:
        # The alias detector reads `let v2 = values` as the hand-off point:
        # a later shadow copy rebinds the parameter, never the alias.
        source = """pub fn Plan::new(values : Array[Int]) -> Plan {
  let v2 = values
  let values = values.copy()
  Plan(cols = v2)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_alias_bound_after_the_copy_is_safe(self) -> None:
        # The other order names the copy, not the caller's array.
        source = """pub fn Plan::new(values : Array[Int]) -> Plan {
  let values = values.copy()
  let v2 = values
  Plan(cols = v2)
}"""
        self.assertEqual(self.retained(source), [])

    def test_a_borrowed_alias_is_a_read_not_a_retention(self) -> None:
        source = """pub fn total(values : Array[Int]) -> Int {
  let v2 = values
  v2.fold(0, (a, b) => a + b)
}"""
        self.assertEqual(self.retained(source), [])

    def test_shadow_binding_to_copy_is_safe(self) -> None:
        source = """pub fn Box::new(values : Array[Int]) -> Box {
  let values = values.copy()
  { values }
}"""
        self.assertEqual(self.retained(source), [])

    def test_borrowed_algorithm_is_safe(self) -> None:
        source = """pub fn sum(values : Array[Int]) -> Int {
  values.fold(init=0, (acc, value) => acc + value)
}"""
        self.assertEqual(self.retained(source), [])

    def test_optional_parameter_is_seen(self) -> None:
        source = """pub fn Plan::drop_nulls(subset? : Array[Expr]) -> Plan {
  DropNulls(subset)
}"""
        self.assertEqual(self.retained(source), ["subset"])

    def test_labelled_parameter_is_seen(self) -> None:
        source = """pub fn Plan::gate(keys~ : Array[Expr]) -> Plan {
  { keys }
}"""
        self.assertEqual(self.retained(source), ["keys"])

    def test_option_payload_in_constructor(self) -> None:
        source = """pub fn Plan::drop_nulls(subset : Array[Expr]) -> Plan {
  DropNulls(Some(subset))
}"""
        self.assertEqual(self.retained(source), ["subset"])

    def test_option_payload_in_record_field(self) -> None:
        source = """pub fn Box::new(values : Array[Int]) -> Box {
  { held: Some(values) }
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_option_payload_copy_is_safe(self) -> None:
        source = """pub fn Plan::drop_nulls(subset : Array[Expr]) -> Plan {
  DropNulls(Some(subset.copy()))
}"""
        self.assertEqual(self.retained(source), [])

    def test_optional_parameter_mapped_copy_is_safe(self) -> None:
        source = """pub fn Plan::drop_nulls(subset? : Array[Expr]) -> Plan {
  { plan: DropNulls(self.plan, subset.map(keys => keys.copy())) }
}"""
        self.assertEqual(self.retained(source), [])

    def test_match_arm_binding_is_not_retention(self) -> None:
        source = """pub fn DataFrame::drop_nulls(subset? : Array[Expr]) -> DataFrame {
  let names = match subset {
    None => self.columns()
    Some(keys) => keys.map(key => key.output_name())
  }
  self.take(names)
}"""
        self.assertEqual(self.retained(source), [])

    def test_similar_parameter_name_is_not_confused(self) -> None:
        source = """pub fn Box::new(values : Array[Int]) -> Box {
  { values: values_copy }
}"""
        self.assertEqual(self.retained(source), [])

    def test_comments_and_strings_do_not_trigger(self) -> None:
        source = '''pub fn inspect(values : Array[Int]) -> String {
  // PlanNode::Values(values)
  "{ values }"
}'''
        self.assertEqual(self.retained(source), [])

    def test_retain_before_shadow_copy_is_unsafe(self) -> None:
        source = """pub fn Box::new(values : Array[Int]) -> Box {
  let result = Box(values)
  let values = values.copy()
  ignore(values)
  result
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_branch_local_shadow_copy_is_unsafe(self) -> None:
        source = """pub fn Box::new(flag : Bool, values : Array[Int]) -> Box {
  if flag {
    let values = values.copy()
    Box(values)
  } else {
    Box(values)
  }
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_char_literal_brace_does_not_hide_a_branch_copy(self) -> None:
        # `'}'` must not close the function body: doing so would make the
        # branch-local copy below look like a top-level one.
        source = """pub fn Box::new(flag : Bool, values : Array[Int]) -> Box {
  let close = '}'
  ignore(close)
  if flag {
    let values = values.copy()
    Box(values)
  } else {
    Box(values)
  }
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_char_literal_brace_does_not_hide_a_top_level_copy(self) -> None:
        # The mirror: `'{'` must not open a scope, which would demote a real
        # top-level copy and report a safe boundary.
        source = """pub fn Box::new(values : Array[Int]) -> Box {
  let open = '{'
  ignore(open)
  let values = values.copy()
  Box(values)
}"""
        self.assertEqual(self.retained(source), [])

    def test_char_literal_quote_does_not_swallow_the_body(self) -> None:
        # `'"'` used to start a string that ran to the next double quote,
        # blanking the retention in between.
        source = '''pub fn Box::new(values : Array[Int]) -> Box {
  let quote = '"'
  ignore(quote)
  Box(values)
}'''
        self.assertEqual(self.retained(source), ["values"])

    def test_underscore_prefixed_parameter_is_scanned(self) -> None:
        # `_values` is a binding the body references, not a discard; the
        # parameter-name pattern used to require a lowercase first letter,
        # which left the whole function unscanned.
        source = """pub fn make(_values : Array[Int]) -> Frame {
  Frame(cols = _values)
}"""
        self.assertEqual(self.retained(source), ["_values"])

    def test_underscore_prefixed_parameter_copy_is_safe(self) -> None:
        source = """pub fn make(_values : Array[Int]) -> Frame {
  Frame(cols = _values.copy())
}"""
        self.assertEqual(self.retained(source), [])

    def test_wrapper_alias_is_followed_like_a_bare_one(self) -> None:
        # `let v2 = Some(values)` names the caller's array under a second
        # name exactly the way `let v2 = values` does — the wrapper does not
        # own the array, only a copy does. Alias tracking used to accept a
        # bare parameter as the whole right-hand side and nothing else.
        source = """pub fn Plan::new(values : Array[Int]) -> Plan {
  let v2 = Some(values)
  Plan(cols = v2)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_parenthesised_alias_is_followed_like_a_bare_one(self) -> None:
        source = """pub fn Plan::new(values : Array[Int]) -> Plan {
  let v2 = (values)
  Plan(cols = v2)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_method_call_argument_is_retention(self) -> None:
        # `stash.push(values)` keeps the array wherever `push` decides; the
        # retain detectors read fields and constructors, never an argument
        # list. Conservative by design — the callee could be a reader.
        source = """pub fn load(values : Array[Int]) -> Unit {
  stash.push(values)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_method_call_on_self_is_retention(self) -> None:
        source = """pub fn load(self : Box, values : Array[Int]) -> Unit {
  self.init(values)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_method_call_with_a_wrapped_argument_is_retention(self) -> None:
        source = """pub fn load(values : Array[Int]) -> Unit {
  stash.push(Some(values))
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_method_call_argument_of_a_copy_is_safe(self) -> None:
        source = """pub fn load(values : Array[Int]) -> Unit {
  stash.push(values.copy())
}"""
        self.assertEqual(self.retained(source), [])

    def test_method_receiver_is_a_read_not_retention(self) -> None:
        # `values.fold(…)` hands the array's *contents* out, not the array;
        # only the argument position counts.
        source = """pub fn total(values : Array[Int]) -> Int {
  values.fold(0, (a, b) => a + b)
}"""
        self.assertEqual(self.retained(source), [])

    def test_package_qualified_call_is_not_a_method_call(self) -> None:
        # `@parquet.read_parquet_columns(bytes, projection)` — the `@pkg.`
        # prefix is a package qualifier and the call a free function under it,
        # the same spelling `read_parquet_columns(bytes, projection)` wears
        # without the qualifier. The guard has never read an unqualified free
        # function's argument list, so an import alias must not be what
        # decides whether the boundary is flagged.
        source = """pub fn parse(bytes : Bytes, projection? : Array[String]) -> Int {
  @parquet.read_parquet_columns(bytes, projection).length()
}"""
        self.assertEqual(self.retained(source), [])

    def test_qualifier_does_not_shield_a_chained_method_call(self) -> None:
        # The exemption reads the text immediately before the dot: once a
        # call returns, the receiver is a value again, and `.push(values)`
        # on it is the ordinary method-shape retention.
        source = """pub fn load(values : Array[Int]) -> Unit {
  @stash.fresh().push(values)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_conditional_assignment_rhs_is_retention(self) -> None:
        # `self.f = if c { values } else { other }` hands the caller's array
        # into the field on the paths that take it; the plain-assignment
        # detector demanded the parameter be the whole right-hand side, which
        # a branch expression never is.
        source = """pub fn load(self : Box, flag : Bool, values : Array[Int]) -> Unit {
  self.held = if flag { values } else { self.held }
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_conditional_assignment_of_copies_is_safe(self) -> None:
        source = """pub fn load(self : Box, flag : Bool, values : Array[Int]) -> Unit {
  self.held = if flag { values.copy() } else { self.held }
}"""
        self.assertEqual(self.retained(source), [])

    def test_free_fn_handoff_that_retains_is_retention(self) -> None:
        # `hand_off(values)` — the bypass this rule closes: an unqualified
        # lower-case free call was invisible to every detector, and the helper
        # here keeps the array. Same-file, so the callee is readable and the
        # retention decidable.
        source = """fn hand_off(items : Array[Int]) -> Box {
  { items }
}

pub fn make(values : Array[Int]) -> Box {
  hand_off(values)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_free_fn_hand_off_two_hops_down_is_retention(self) -> None:
        # A helper handing the array one step further down is the same
        # hand-off; the recursion follows the chain rather than stopping at
        # the first callee, which retains nothing itself.
        source = """fn stash(items : Array[Int]) -> Unit {
  sink = items
}

fn hand_off(items : Array[Int]) -> Unit {
  stash(items)
}

pub fn make(values : Array[Int]) -> Unit {
  hand_off(values)
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_free_fn_that_only_reads_is_not_retention(self) -> None:
        # The precision half of the rule: a same-file helper that only reads
        # its argument (`names_of_exprs(keys)` is the shape this repository
        # actually carries) does not make the boundary a retention — which is
        # what keeps the rule from demanding copies at every read-only
        # delegation.
        source = """fn total(items : Array[Int]) -> Int {
  items.fold(0, (a, b) => a + b)
}

pub fn sum(values : Array[Int]) -> Int {
  total(values)
}"""
        self.assertEqual(self.retained(source), [])

    def test_free_fn_hand_off_after_a_visible_copy_is_safe(self) -> None:
        source = """fn hand_off(items : Array[Int]) -> Box {
  { items }
}

pub fn make(values : Array[Int]) -> Box {
  let values = values.copy()
  hand_off(values)
}"""
        self.assertEqual(self.retained(source), [])

    def test_free_fn_hand_off_with_a_labelled_argument_is_retention(self) -> None:
        source = """fn hand_off(keys~ : Array[Int], name : String) -> Box {
  { keys }
}

pub fn make(values : Array[Int]) -> Box {
  hand_off(keys~ = values, "k")
}"""
        self.assertEqual(self.retained(source), ["values"])

    def test_a_helper_outside_the_file_is_not_followed(self) -> None:
        # A builtin or another package's function is not declared here, so
        # nothing can read it: the call stays outside the rule, as it has
        # always been — the documented limit, pinned as a test.
        source = """pub fn make(values : Array[Int]) -> Int {
  println(values)
  0
}"""
        self.assertEqual(self.retained(source), [])

    def test_match_scrutinee_mentioning_the_parameter_is_not_a_call(self) -> None:
        # `match (flag, values) { … }` is shaped exactly like a call to a
        # function named `match`; the scrutinee is a read, not a hand-off.
        source = """fn first(items : Array[Int]) -> Int {
  items[0]
}

pub fn make(flag : Bool, values : Array[Int]) -> Int {
  match (flag, values) {
    (true, _) => first(values)
    (false, _) => 0
  }
}"""
        self.assertEqual(self.retained(source), [])

    def test_block_string_brace_does_not_skew_the_depth_count(self) -> None:
        # A `#|` segment is text: a `}` inside one must not close the body,
        # which would make the branch-local copy below look top-level and
        # report a safe boundary that is not.
        source = '''pub fn Box::new(flag : Bool, values : Array[Int]) -> Box {
  let doc = #| }
  ignore(doc)
  if flag {
    let values = values.copy()
    Box(values)
  } else {
    Box(values)
  }
}'''
        self.assertEqual(self.retained(source), ["values"])

    def test_block_string_content_is_not_code(self) -> None:
        # Nothing written inside a `#|` segment is a hand-off — not even a
        # line that would flag itself as one if it were code.
        source = '''fn hand_off(items : Array[Int]) -> Box {
  { items }
}

pub fn make(values : Array[Int]) -> Box {
  let note = #| hand_off(values) { values }
  ignore(note)
  Box(0)
}'''
        self.assertEqual(self.retained(source), [])

    def test_second_pub_fn_in_a_block_is_scanned(self) -> None:
        # One `///|` block may stack two public functions; only the first
        # signature used to be read, leaving the second's boundary unguarded.
        source = """pub fn first(rows : Array[Int]) -> Int {
  rows.len()
}

pub fn second(items : Array[Int]) -> Box {
  { items }
}"""
        self.assertEqual(self.retained(source), ["items"])


class SourceDiscoveryTests(unittest.TestCase):
    """The repository walk: what the guard is handed to judge.

    Each case builds a throwaway git repository, because tracking is what
    `source_files` asks about — the point of reading the index instead of a list
    of directory names is that a package nobody remembered to list is still
    covered.
    """

    def repo(self, files: dict[str, str]) -> Path:
        # `ignore_cleanup_errors` because `git init` leaves read-only objects
        # behind, which a plain teardown refuses to unlink on some platforms;
        # failing to delete a temporary directory is not a test result.
        holder = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.addCleanup(holder.cleanup)
        root = Path(holder.name)
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        return root

    def relative(self, root: Path) -> list[str]:
        return [path.relative_to(root).as_posix() for path in source_files(root)]

    def test_a_package_nobody_listed_is_still_scanned(self) -> None:
        root = self.repo(
            {
                "moon.pkg": "{}",
                "facade.mbt": "",
                "brand_new_package/moon.pkg": "{}",
                "brand_new_package/thing.mbt": "",
                "internal/deep/nested.mbt": "",
            }
        )
        self.assertEqual(
            self.relative(root),
            ["brand_new_package/thing.mbt", "facade.mbt", "internal/deep/nested.mbt"],
        )

    def test_tests_and_the_downstream_fixture_are_excluded(self) -> None:
        root = self.repo(
            {
                "frame/frame.mbt": "",
                "frame/frame_test.mbt": "",
                "frame/frame_wbtest.mbt": "",
                ".github/fixtures/smoke/smoke.mbt": "",
            }
        )
        self.assertEqual(self.relative(root), ["frame/frame.mbt"])

    def test_an_untracked_file_is_not_part_of_the_surface(self) -> None:
        root = self.repo({"frame/frame.mbt": ""})
        (root / "frame" / "scratch.mbt").write_text("", encoding="utf-8")
        self.assertEqual(self.relative(root), ["frame/frame.mbt"])

    def test_audit_reports_a_retention_in_a_discovered_package(self) -> None:
        root = self.repo(
            {
                "brand_new_package/thing.mbt": """///|
pub fn Box::Box(values : Array[Int]) -> Box {
  { values }
}
""",
            }
        )
        self.assertEqual(
            audit(root),
            [
                "brand_new_package/thing.mbt: Box::Box directly retains Array "
                "parameter 'values'; copy it at the public boundary"
            ],
        )

    def test_audit_passes_a_package_that_copies(self) -> None:
        root = self.repo(
            {
                "brand_new_package/thing.mbt": """///|
pub fn Box::Box(values : Array[Int]) -> Box {
  { values: values.copy() }
}
""",
            }
        )
        self.assertEqual(audit(root), [])

    def test_a_pub_extend_method_boundary_is_scanned(self) -> None:
        # An `extend` block publishes its methods without repeating `pub`
        # on each `fn` - the boundary shape the original `pub fn` pattern
        # never matched, and the module boundary is what makes one public.
        root = self.repo(
            {
                "brand_new_package/thing.mbt": """///|
pub extend Box with fn feed(self : Box, values : Array[Int]) -> Box {
  { values: values }
}
""",
            }
        )
        self.assertEqual(
            audit(root),
            [
                "brand_new_package/thing.mbt: feed directly retains Array "
                "parameter 'values'; copy it at the public boundary"
            ],
        )

    def test_audit_attributes_a_retention_to_the_second_pub_fn(self) -> None:
        # The failure message names the function that retains, which a
        # block-level answer cannot do: two public functions, and the second
        # one holds the boundary.
        root = self.repo(
            {
                "brand_new_package/thing.mbt": """///|
pub fn first(rows : Array[Int]) -> Int {
  rows.len()
}

pub fn second(items : Array[Int]) -> Box {
  { items }
}
""",
            }
        )
        self.assertEqual(
            audit(root),
            [
                "brand_new_package/thing.mbt: second directly retains Array "
                "parameter 'items'; copy it at the public boundary"
            ],
        )


if __name__ == "__main__":
    unittest.main()
