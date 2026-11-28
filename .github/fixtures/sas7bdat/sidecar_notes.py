"""Print, per sidecar, where the reference readers disagree with it.

Usage, from the repository root: uv run --no-project --with pandas --with pyreadstat python -I -X utf8 .github/fixtures/sas7bdat/sidecar_notes.py .github/fixtures/sas7bdat/reference

Lists, for every sidecar, the readers' counts of columns by verdict and
the notes behind the ones that are not ``agrees``; then the columns a
reader disagrees on, by dtype and format; then the totals over the
corpus. The disagreement list in the report comes from this.
"""
import json
import os
import sys

total = {}
for name in sorted(os.listdir(sys.argv[1])):
    if not name.endswith(".json") or name in ("index.json",) or name.endswith(".map.json"):
        continue
    side = json.load(open(os.path.join(sys.argv[1], name), encoding="utf-8"))
    if not side.get("readable"):
        print(f"== {name[:-5]}: REFUSED {side['refusal']}")
        continue
    pandas_counts = side["pandas"]["counts"]
    pyrs_counts = side["pyreadstat"]["counts"]
    print(
        f"== {name[:-5]}: {side['rows']} rows; pandas {pandas_counts}; pyreadstat {pyrs_counts};"
        f" cells from {side['cells_from']}; commands {side['commands']}"
    )
    if side["layout_gap"]["formats_differ_in_columns"] or side["layout_gap"]["widths_differ_in_columns"]:
        print("   layout gap:", side["layout_gap"])
    for reader in ("pandas", "pyreadstat"):
        for note in side[reader]["notes"]:
            print(f"   {reader} note: {note[:300]}")
    for reader in ("pandas", "pyreadstat"):
        notes = side["raw"][reader]["notes"]
        if notes:
            print(f"   raw {reader} note: {notes[0][:300]}")
    disagree = {}
    for column in side["columns"]:
        key = (column["dtype"], column["format"] or "-", column["pandas"], column["pyreadstat"])
        disagree[key] = disagree.get(key, 0) + 1
        both = column["pandas"] == "agrees" and column["pyreadstat"] == "agrees"
        tally = total.setdefault((column["dtype"], column["pandas"], column["pyreadstat"]), [0, 0])
        tally[0] += 1
        tally[1] += len(column["cells"])
    for key, count in sorted(disagree.items()):
        if key[2] != "agrees" or key[3] != "agrees":
            print(f"   {count} x dtype {key[0]}, format {key[1]}: pandas {key[2]}, pyreadstat {key[3]}")
print("total columns and cells by (dtype, pandas, pyreadstat):")
columns = cells = 0
for key, (n, c) in sorted(total.items()):
    columns += n
    cells += c
    print("  ", key, n, "columns", c, "cells")
print("corpus:", columns, "columns,", cells, "cells")
