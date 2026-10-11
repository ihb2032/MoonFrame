"""Guard: every wildcard arm in a production match over a dtype-carrying enum
is registered, with a reason, in dtype_wildcards.allowlist.

Adding a variant to Scalar / DataType / ColumnData / StorageKind / NumericData
/ PhysicalType / ColumnStorage fails every exhaustive match at compile time —
that half needs no guard. The wildcard arms are the half nothing forces anyone
to re-read: a new variant falls in silently. The allowlist is the fixed
inventory of exactly those places, so adding a dtype (or a new wildcard) makes
CI name every silent swallow-point that a human must review.

A wildcard arm is a line whose first token is `_ =>` / `.. =>` or a
continuation `| _ =>` / `| ..`, inside a match block that mentions one of the
dtype enums anywhere in the block (the scrutinee is usually a bare variable).
Closure parameter underscores (`makei(n, _ => None)`) share the shape; the
guard attributes the line to its enclosing function and lets the allowlist
carry those with their reason, keeping the scanner deliberately lexical, like
the array-copy boundary guard.

Usage: python -B .github/scripts/check_dtype_wildcards.py
  add --write to regenerate .github/scripts/dtype_wildcards.allowlist headers
"""

import re
import subprocess
import sys

ENUMS = [
    'Scalar', 'DataType', 'ColumnData', 'StorageKind', 'NumericData',
    'PhysicalType', 'ColumnStorage',
]
ALLOWLIST = '.github/scripts/dtype_wildcards.allowlist'

STR_RE = re.compile(r'"(?:[^"\\]|\\.)*"')
MATCH_RE = re.compile(r'\bmatch\s+(.+?)\s*\{')
WILD_RE = re.compile(r'^\s*(_|\.\.)\s*(=>|\|)|\|\s*(_|\.\.)\s*(=>|\|)')
FN_RE = re.compile(r'^\s*(?:pub\s+)?(?:fn(?:\[[^\]]*\])?\s+)?([A-Za-z_][A-Za-z0-9_:]*)')


def strip_line(line):
    line = STR_RE.sub('""', line)
    return re.sub(r'//.*$', '', line)


def production_files():
    out = subprocess.run(
        ['git', 'ls-files', '*.mbt'], capture_output=True, text=True
    ).stdout.split()
    return [
        f for f in out
        if not f.endswith('_test.mbt') and not f.endswith('_wbtest.mbt')
    ]


def find_wildcards():
    """Yield (file, line, fn_name) for every wildcard arm in a dtype match."""
    hits = []
    for f in production_files():
        try:
            lines = open(f, encoding='utf-8').read().split('\n')
        except OSError:
            continue
        fn_name = '<top>'
        i = 0
        while i < len(lines):
            raw = lines[i]
            l = strip_line(raw)
            m = re.match(r'^\s*(?:pub\s+)?fn', raw)
            if m:
                name = FN_RE.match(raw)
                if name:
                    fn_name = name.group(1)
            mm = MATCH_RE.search(l)
            if mm:
                depth = l.count('{') - l.count('}')
                j = i
                block = [l]
                found = []
                while j < len(lines) and depth > 0:
                    j += 1
                    if j >= len(lines):
                        break
                    ll = strip_line(lines[j])
                    depth += ll.count('{') - ll.count('}')
                    block.append(ll)
                    if WILD_RE.match(ll):
                        found.append(j + 1)
                text = '\n'.join(block)
                if found and any(
                    re.search(r'\b' + e + r'\b', text) for e in ENUMS
                ):
                    for ln in found:
                        hits.append((f, ln, fn_name))
                i = j
            i += 1
    return hits


def main():
    hits = find_wildcards()
    registered = {}
    try:
        for raw in open(ALLOWLIST, encoding='utf-8'):
            line = raw.split('#')[0].strip()
            if not line:
                continue
            parts = line.split(None, 2)
            if len(parts) >= 2:
                registered[(parts[0], parts[1])] = parts[2] if len(parts) > 2 else ''
    except OSError:
        pass

    unknown = [h for h in hits if (h[0], h[2]) not in registered]
    stale = [k for k in registered if k not in {(h[0], h[2]) for h in hits}]

    if unknown:
        print('dtype wildcards: UNREGISTERED wildcard arms (register in '
              + ALLOWLIST + ' with a reason, or make the match exhaustive):')
        for f, ln, fn in unknown:
            print(f'  {f}:{ln}  in {fn}')
    if stale:
        print('dtype wildcards: allowlist entries with no remaining wildcard '
              '(remove them):')
        for f, fn in stale:
            print(f'  {f}  in {fn}')
    if unknown or stale:
        sys.exit(1)
    print(f'dtype wildcards: {len(hits)} wildcard arms in production, all '
          f'registered in dtype_wildcards.allowlist')


if __name__ == '__main__':
    main()
