"""Guard: every wildcard arm in a production match over a dtype-carrying enum
is registered, with a reason, in dtype_wildcards.allowlist.

Adding a variant to Scalar / DataType / ColumnData / StorageKind / NumericData
/ PhysicalType / ColumnStorage fails every exhaustive match at compile time —
that half needs no guard. The wildcard arms are the half nothing forces anyone
to re-read: a new variant falls in silently. The allowlist is the fixed
inventory of exactly those places, so adding a dtype (or a new wildcard) makes
CI name every silent swallow-point that a human must review.

A wildcard arm is a catch-all arm: a line whose first token is `_ =>` / `.. =>
` / a bare lowercase binding (`other =>` — semantically the same catch-all,
which is why it registers like one), or the `|`-continuation of either, inside
a match block that mentions one of the dtype enums anywhere in the block (the
scrutinee is usually a bare variable). A single-line match (`match dt { A =>
1; _ => 0 }`) is scanned on its own line — its `;`-separated segments never
enter the multi-line walk. Closure parameter underscores (`makei(n, _ =>
None)`) share the shape; the guard attributes the line to its enclosing
function and lets the allowlist carry those with their reason, keeping the
scanner deliberately lexical, like the array-copy boundary guard. String and
character literals are masked first, so a `'{'` inside one cannot open or
close a block span; `.github/` fixtures are outside the production set, like
the array-copy guard's own exclusion.

Usage: python -B .github/scripts/check_dtype_wildcards.py
  add --write to append the unregistered arms to
  .github/scripts/dtype_wildcards.allowlist with a TODO reason to fill in
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
CHAR_RE = re.compile(r"'(?:[^'\\]|\\.)'")
MATCH_RE = re.compile(r'\bmatch\s+(.+?)\s*\{')
# A catch-all arm pattern: the whole pattern is `_`, `..`, or a bare
# lowercase / underscore-led binding — an enum variant is capitalized, so a
# lowercase identifier alone can only bind, and `_v` is MoonBit's own
# spelling of one. A guard (`_ if cond =>`) is the same catch-all with a
# condition on it: `.*?` runs to the first `=>` or `|`, and either match
# marks the line (a `|` inside the guard continues the same arm). The second
# alternative is the `|`-continuation of a multi-pattern arm.
WILD_RE = re.compile(
    r'^\s*(_|\.\.|[_a-z][_a-z0-9_\']*)\s*(?:if\b.*?)?\s*(=>|\|)'
    r'|\|\s*(_|\.\.|[_a-z][_a-z0-9_\']*)\s*(?:if\b.*?)?\s*(=>|\|)'
)
# The same test for one `;`-separated segment of a single-line match.
SEGMENT_RE = re.compile(
    r'^\s*(?:\|)?\s*(_|\.\.|[_a-z][_a-z0-9_\']*)\s*(?:if\b.*?)?\s*=>'
)
FN_RE = re.compile(r'^\s*(?:pub\s+)?(?:fn(?:\[[^\]]*\])?\s+)?([A-Za-z_][A-Za-z0-9_:]*)')


def strip_line(line):
    line = STR_RE.sub('""', line)
    line = CHAR_RE.sub("''", line)
    return re.sub(r'//.*$', '', line)


def production_files(root='.'):
    out = subprocess.run(
        ['git', '-C', root, 'ls-files', '*.mbt'],
        capture_output=True, text=True,
    ).stdout.split()
    return [
        f for f in out
        if not f.endswith('_test.mbt')
        and not f.endswith('_wbtest.mbt')
        and not f.startswith('.github/')
    ]


def find_wildcards(root='.'):
    """Yield (file, line, fn_name) for every wildcard arm in a dtype match."""
    hits = []
    for f in production_files(root):
        try:
            lines = open(
                # Paths come back relative to `root`; the caller passing a
                # foreign root is a test fixture, whose cwd differs.
                f if root == '.' else f'{root}/{f}',
                encoding='utf-8',
            ).read().split('\n')
        except OSError:
            continue
        fn_name = '<top>'
        fn_start = None
        i = 0
        while i < len(lines):
            raw = lines[i]
            l = strip_line(raw)
            m = re.match(r'^\s*(?:pub\s+)?fn', raw)
            if m:
                name = FN_RE.match(raw)
                if name:
                    fn_name = name.group(1)
                fn_start = i
            mm = MATCH_RE.search(l)
            if mm is None:
                mbegin = re.search(r'\bmatch\b', l)
                if mbegin and '{' not in l[mbegin.end():]:
                    # A wrapped scrutinee: `moon fmt` folds a long one onto
                    # its own lines, the `{` landing further down — a shape
                    # the same-line `MATCH_RE` never sees, leaving the whole
                    # block outside the scan. Join the lines through the one
                    # that opens the block, so the block scan and the enum
                    # detection both see the whole scrutinee.
                    j2 = i
                    joined = l
                    while (j2 + 1 < len(lines) and
                           '{' not in joined[mbegin.end():]):
                        j2 += 1
                        joined = joined + ' ' + strip_line(lines[j2])
                    if '{' in joined[mbegin.end():]:
                        mm = MATCH_RE.search(joined)
                        if mm:
                            i = j2
                            l = joined
            if mm:
                depth = l.count('{') - l.count('}')
                j = i
                block = [l]
                found = []
                if depth == 0:
                    # A single-line match: its arms ride the match line
                    # itself, `;`-separated, and the walk below never runs
                    # (depth starts at 0) — scan the line's own segments.
                    for seg in l.split(';'):
                        if SEGMENT_RE.match(seg):
                            found.append(i + 1)
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
                # Attribution names a dtype enum through the block's own
                # text *or* through the enclosing function's signature —
                # `fn cell(... : DataType)` — because a match whose arms
                # are bare variant names (`Int =>`, or a bare catch-all
                # binding) carries no enum spelling into the block, and
                # the signature is the other place the scrutinee's type is
                # written. The signature half runs from the `fn` line to
                # the match, the span a reader scans to learn what is
                # matched; over-attributing is the safe direction (it can
                # only ask for an allowlist entry, never hide one).
                sig_text = (
                    '\n'.join(
                        strip_line(x) for x in lines[fn_start:i + 1]
                    ) if fn_start is not None else ''
                )
                if found and any(
                    re.search(r'\b' + e + r'\b', text + '\n' + sig_text)
                    for e in ENUMS
                ):
                    for ln in found:
                        hits.append((f, ln, fn_name))
                i = j
            i += 1
    return hits


def main(allowlist=ALLOWLIST, argv=None, root='.'):
    if argv is None:
        argv = sys.argv[1:]
    hits = find_wildcards(root)
    registered = {}
    try:
        for raw in open(allowlist, encoding='utf-8'):
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

    if '--write' in argv:
        if unknown:
            with open(allowlist, 'a', encoding='utf-8') as out:
                for f, ln, fn in unknown:
                    out.write(f'{f} {fn} TODO(reason)\n')
            print(f'dtype wildcards: appended {len(unknown)} arms to '
                  + allowlist + ' — fill in the TODO reasons')
        else:
            print('dtype wildcards: nothing to append')
        return

    if unknown:
        print('dtype wildcards: UNREGISTERED wildcard arms (register in '
              + allowlist + ' with a reason, or make the match exhaustive):')
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
