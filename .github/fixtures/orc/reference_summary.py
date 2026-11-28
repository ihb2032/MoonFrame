"""The reference reader on one ORC file, in a process of its own, as a
JSON summary on standard output: whether it opens the file, the error it
refused with, and else its rows and its columns. The generator calls it
for the files built to be broken: a malformed file may crash the reader's
C++ core, and the generator must go on to the next file.

    python -I -X utf8 tools/reference_summary.py path/to/file.orc
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_fixtures as G  # noqa: E402


def main():
    G.ensure_tzdir()
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    table, error = G.reference_table(data, None)
    if error is not None:
        print(json.dumps({"opens": False, "error": error}))
        return 0
    print(json.dumps({"opens": True, "rows": table.num_rows,
                      "columns": ["%s: %s" % (table.schema.field(i).name, table.schema.field(i).type)
                                  for i in range(table.num_columns)]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
