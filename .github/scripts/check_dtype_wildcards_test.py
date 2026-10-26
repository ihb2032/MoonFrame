#!/usr/bin/env python3
"""Regression tests for the dtype wildcard guard's scanner.

The guard's judgement is lexical, and the lexical shapes that silently
swallow a new dtype variant come in more spellings than `_`: a bare
lowercase binding (`other =>`) is the same catch-all, a single-line match
carries its arms on the match line itself, and a character literal holding
a brace must not open or close a block span. These tests pin each shape
against a git-initialized fixture tree — the guard reads `git ls-files`, so
a bare directory would look at nothing and still pass.
"""

import io
import contextlib
import subprocess
import tempfile
import unittest
from pathlib import Path

from check_dtype_wildcards import find_wildcards, main, strip_line


class DtypeWildcardScannerTests(unittest.TestCase):
    def repo(self, files: dict) -> Path:
        # `ignore_cleanup_errors` because `git init` leaves read-only
        # objects behind, which a plain teardown refuses to unlink on some
        # platforms; failing to delete a temporary directory is not a test
        # result.
        holder = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.addCleanup(holder.cleanup)
        root = Path(holder.name)
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8')
        subprocess.run(['git', 'init', '-q'], cwd=root, check=True)
        subprocess.run(['git', 'add', '-A'], cwd=root, check=True)
        return root

    def arms(self, files: dict) -> list:
        root = self.repo(files)
        return sorted({(f, fn) for f, _ln, fn in find_wildcards(str(root))})

    def test_underscore_arm_in_a_dtype_block_is_flagged(self) -> None:
        arms = self.arms({
            'a/moon.pkg': '{}',
            'a/a.mbt': (
                'fn label(dt : DataType) -> String {\n'
                '  match dt {\n'
                '    @types.DataType::Int => "i"\n'
                '    _ => "?"\n'
                '  }\n'
                '}\n'
            ),
        })
        self.assertEqual(arms, [('a/a.mbt', 'label')])

    def test_binding_name_catch_all_is_flagged_like_an_underscore(self) -> None:
        # A bare lowercase binding catches everything an `_` does; the
        # inventory promise covers both spellings.
        arms = self.arms({
            'a/moon.pkg': '{}',
            'a/a.mbt': (
                'fn as_int(self : Scalar) -> Int64 {\n'
                '  match self {\n'
                '    @types.Scalar::Int(v) => v\n'
                '    other => refuse(other)\n'
                '  }\n'
                '}\n'
            ),
        })
        self.assertEqual(arms, [('a/a.mbt', 'as_int')])

    def test_capitalized_variant_arms_are_not_flagged(self) -> None:
        arms = self.arms({
            'a/moon.pkg': '{}',
            'a/a.mbt': (
                'fn label(dt : DataType) -> String {\n'
                '  match dt {\n'
                '    @types.DataType::Int => "i"\n'
                '    @types.DataType::Float => "f"\n'
                '  }\n'
                '}\n'
            ),
        })
        self.assertEqual(arms, [])

    def test_a_block_that_names_no_dtype_enum_is_ignored(self) -> None:
        arms = self.arms({
            'a/moon.pkg': '{}',
            'a/a.mbt': (
                'fn pick(opt : Int?) -> Int {\n'
                '  match opt {\n'
                '    Some(v) => v\n'
                '    other => 0\n'
                '  }\n'
                '}\n'
            ),
        })
        self.assertEqual(arms, [])

    def test_single_line_match_arms_are_scanned(self) -> None:
        # A balanced match line never enters the multi-line walk (its depth
        # starts at 0); the `;`-separated segments must be scanned on the
        # line itself or the arm is invisible.
        arms = self.arms({
            'a/moon.pkg': '{}',
            'a/a.mbt': (
                'fn label(dt : DataType) -> String {\n'
                '  let v = match dt { @types.DataType::Int => "1"; _ => "0" }\n'
                '  v\n'
                '}\n'
            ),
        })
        self.assertEqual(arms, [('a/a.mbt', 'label')])

    def test_brace_characters_inside_char_literals_do_not_close_the_block(
        self,
    ) -> None:
        # `'}'` is a value, not a brace; an unmasked literal would close the
        # match span early and the wildcard below it would escape.
        arms = self.arms({
            'a/moon.pkg': '{}',
            'a/a.mbt': (
                'fn render(dt : DataType) -> String {\n'
                '  match dt {\n'
                '    @types.DataType::String(s) => escape(s, \'{\')\n'
                '    _ => "?"\n'
                '  }\n'
                '}\n'
            ),
        })
        self.assertEqual(arms, [('a/a.mbt', 'render')])

    def test_fixture_trees_under_github_are_outside_the_production_set(
        self,
    ) -> None:
        arms = self.arms({
            '.github/fixtures/smoke/smoke.mbt': (
                'fn label(dt : DataType) -> String {\n'
                '  match dt {\n'
                '    Int => "i"\n'
                '    _ => "?"\n'
                '  }\n'
                '}\n'
            ),
        })
        self.assertEqual(arms, [])

    def test_write_appends_the_unknown_arms_with_a_todo_reason(self) -> None:
        root = self.repo({
            'a/moon.pkg': '{}',
            'a/a.mbt': (
                'fn label(dt : DataType) -> String {\n'
                '  match dt {\n'
                '    @types.DataType::Int => "i"\n'
                '    _ => "?"\n'
                '  }\n'
                '}\n'
            ),
        })
        allowlist = root / 'allow.txt'
        allowlist.write_text('', encoding='utf-8')
        with contextlib.redirect_stdout(io.StringIO()) as held:
            with self.assertRaises(SystemExit) as refused:
                main(allowlist=str(allowlist), argv=[], root=str(root))
        self.assertEqual(refused.exception.code, 1)
        self.assertIn('UNREGISTERED', held.getvalue())
        self.assertEqual(allowlist.read_text(encoding='utf-8'), '')
        with contextlib.redirect_stdout(io.StringIO()) as held:
            main(allowlist=str(allowlist), argv=['--write'], root=str(root))
        self.assertIn('appended 1', held.getvalue())
        self.assertEqual(
            allowlist.read_text(encoding='utf-8'),
            'a/a.mbt label TODO(reason)\n',
        )

    def test_guard_arm_is_flagged_like_a_plain_catch_all(self) -> None:
        # `_ if cond =>` swallows every variant the condition accepts; the
        # guard spelling hid from the original pattern, which demanded `=>`
        # right after the binding.
        arms = self.arms({
            'a/moon.pkg': '{}',
            'a/a.mbt': (
                'fn label(dt : DataType) -> String {\n'
                '  match dt {\n'
                '    @types.DataType::Int => "i"\n'
                '    _ if reachable => "?"\n'
                '  }\n'
                '}\n'
            ),
        })
        self.assertEqual(arms, [('a/a.mbt', 'label')])

    def test_underscore_led_binding_is_flagged(self) -> None:
        # `_v =>` is a binding, not the discard `_`; the original identifier
        # character class did not accept a leading underscore.
        arms = self.arms({
            'a/moon.pkg': '{}',
            'a/a.mbt': (
                'fn as_int(self : Scalar) -> Int64 {\n'
                '  match self {\n'
                '    @types.Scalar::Int(v) => v\n'
                '    _rest => refuse(_rest)\n'
                '  }\n'
                '}\n'
            ),
        })
        self.assertEqual(arms, [('a/a.mbt', 'as_int')])

    def test_wrapped_scrutinee_block_is_scanned(self) -> None:
        # moon fmt folds a long scrutinee onto its own lines, the `{`
        # landing below — the whole block sat outside the original
        # same-line match detection.
        arms = self.arms({
            'a/moon.pkg': '{}',
            'a/a.mbt': (
                'fn label(\n'
                '  self : ColumnStorage,\n'
                ') -> String {\n'
                '  match\n'
                '    self.storage_kind()\n'
                '  {\n'
                '    @column.StorageKind::Builtin => "b"\n'
                '    _ => "?"\n'
                '  }\n'
                '}\n'
            ),
        })
        self.assertEqual(arms, [('a/a.mbt', 'label')])


if __name__ == '__main__':
    unittest.main()
