"""Print where the reference readers and this script's model disagree,
cell by cell, for the sidecars that name a disagreement. Evidence while
the corpus is built, and for the report's "Reference comparison".

    uv run --no-project python -I -X utf8 .github/fixtures/xport/sidecar_report.py
"""
import json
import sys
from pathlib import Path

REFERENCE = Path(__file__).resolve().parent / "reference"


def main() -> int:
    only = sys.argv[1:2]
    total_cells = total_files = 0
    for path in sorted(REFERENCE.glob("*.json")):
        if path.name == "index.json" or (only and only[0] not in path.name):
            continue
        side = json.loads(path.read_text(encoding="utf-8"))
        if not side["readable"]:
            continue
        total_files += 1
        reference = side["reference"]
        for column in side["columns"]:
            total_cells += len(column["cells"])
            lines = []
            if not column["pyreadstat"]["agrees"]:
                lines.append(f"pyreadstat disagrees (it reads the column as {column['pyreadstat']['dtype']})")
            if reference["pandas"] is not None and not column["pandas"]["agrees"]:
                pcells = column["pandas"]["cells"]
                shared = min(len(pcells), len(column["cells"]))
                # pandas spells a missing cell as the bits of its NaN.
                same = [r for r in range(shared)
                        if pcells[r] == column["cells"][r]
                        or (column["cells"][r] == "Null" and pcells[r] == "Float 7ff8000000000000")]
                differ = [r for r in range(shared) if r not in same]
                lines.append(f"pandas disagrees on {len(differ)} of {shared} cells" +
                             (f" and reads {len(pcells)} rows against the model's {len(column['cells'])}"
                              if len(pcells) != len(column["cells"]) else ""))
                for r in differ[:6]:
                    lines.append(f"    row {r + 1}: model {column['cells'][r]} | pandas {pcells[r]}")
            if lines:
                print(f"{side['file']} :: {column['name']} [{column['format'] or '-'}] -> {column['dtype']}")
                for line in lines:
                    print("    " + line)
    print(f"files {total_files}, cells {total_cells}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
