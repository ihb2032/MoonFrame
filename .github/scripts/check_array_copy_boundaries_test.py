#!/usr/bin/env python3
"""Focused regression tests for the MoonBit Array ownership guard."""

import unittest

from check_array_copy_boundaries import retained_parameters


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

    def test_comments_and_strings_do_not_trigger(self) -> None:
        source = '''pub fn inspect(values : Array[Int]) -> String {
  // PlanNode::Values(values)
  "{ values }"
}'''
        self.assertEqual(self.retained(source), [])


if __name__ == "__main__":
    unittest.main()
