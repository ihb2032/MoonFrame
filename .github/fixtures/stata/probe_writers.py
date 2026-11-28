"""Which Stata dataset releases and byte orders each reference writer can
produce, and which release code lands in the file. Evidence for the
report's "Versions and variants" section.

    uv run --no-project --with pandas --with pyreadstat \\
        python -I -X utf8 .github/fixtures/stata/probe_writers.py
"""
import tempfile
from pathlib import Path

import pandas as pd
import pyreadstat

tmp = Path(tempfile.mkdtemp(prefix="dta_probe_"))
frame = pd.DataFrame({"a": [1, 2, 3]})


def release_code(path: Path) -> str:
    raw = path.read_bytes()
    if raw[:4] == b"<sta":
        i = raw.index(b"<release>") + len(b"<release>")
        bo = raw.index(b"<byteorder>") + len(b"<byteorder>")
        return f"tagged release={raw[i:i + 3].decode()} byteorder={raw[bo:bo + 3].decode()}"
    return f"binary release={raw[0]} byteorder_flag={raw[1]}"


print(f"pandas {pd.__version__}, pyreadstat {pyreadstat.__version__}")
print("pandas DataFrame.to_stata(version=, byteorder=):")
for version in (113, 114, 115, 116, 117, 118, 119):
    outcomes = []
    for byteorder in ("<", ">"):
        # The byte-order mark cannot be in a Windows file name.
        path = tmp / f"pandas_{version}_{'le' if byteorder == '<' else 'be'}.dta"
        try:
            frame.to_stata(path, version=version, byteorder=byteorder, write_index=False)
            outcomes.append(f"{byteorder}: {release_code(path)}")
        except Exception as exc:  # noqa: BLE001
            outcomes.append(f"{byteorder}: refused ({type(exc).__name__})")
    print(f"  version={version}: " + " | ".join(outcomes))
print("pyreadstat write_dta(version=) — Stata version numbers; no byte-order parameter:")
for version in range(8, 16):
    path = tmp / f"pyreadstat_{version}.dta"
    try:
        pyreadstat.write_dta(frame, str(path), version=version)
        print(f"  version={version}: {release_code(path)}")
    except Exception as exc:  # noqa: BLE001
        print(f"  version={version}: refused ({type(exc).__name__})")
print("reading a file whose release byte says 116 (a 115 file relabelled):")
src = tmp / "pyreadstat_12.dta"
path = tmp / "synthetic_116.dta"
path.write_bytes(bytes([116]) + src.read_bytes()[1:])
for name, read in (("pandas", lambda: pd.read_stata(path)),
                   ("pyreadstat", lambda: pyreadstat.read_dta(str(path)))):
    try:
        read()
        print(f"  {name}: reads it")
    except Exception as exc:  # noqa: BLE001
        print(f"  {name}: refuses ({type(exc).__name__})")
print("pandas DataFrame.to_stata on a table with no column:")
try:
    pd.DataFrame().to_stata(tmp / "empty.dta", version=118, write_index=False)
    print("  written")
except Exception as exc:  # noqa: BLE001
    print(f"  refused ({type(exc).__name__})")
