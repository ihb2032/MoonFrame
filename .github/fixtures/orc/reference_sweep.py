"""The reference reader on the files of the codec's replacement sweep, in
a process of its own, a JSON line a file on standard output: whether it
opens the file, the error it refused with, and else its cells. The
generator calls it for the sweep's mutated files — a mutated file may
crash the reader's core, and the generator resumes after the crash.

    python -I -X utf8 tools/reference_sweep.py <directory> <first index>
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_fixtures as G  # noqa: E402


def main():
    G.ensure_tzdir()
    directory, first = sys.argv[1], int(sys.argv[2])
    with open(os.path.join(directory, "order.json"), encoding="utf-8") as f:
        order = json.load(f)
    for key in order[first:]:
        with open(os.path.join(directory, key + ".orc"), "rb") as f:
            data = f.read()
        table, error = G.reference_table(data, None)
        if error is not None:
            line = {"key": key, "opens": False, "error": error[:200]}
        else:
            try:
                line = {"key": key, "opens": True, "rows": table.num_rows,
                        "cells": [G.cells_of(table.column(i).combine_chunks()) for i in range(table.num_columns)]}
            except ValueError as e:
                line = {"key": key, "opens": False, "error": "cannot hold the values: %s" % e}
        print(json.dumps(line, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
