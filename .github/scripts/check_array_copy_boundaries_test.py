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


if __name__ == "__main__":
    unittest.main()
