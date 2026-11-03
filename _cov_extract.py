import re
txt = open('_cov.txt', encoding='utf8', errors='replace').read()
cur = None
for line in txt.splitlines():
    m = re.match(r'\s*\d+ uncovered line\(s\) in (.+):', line)
    if m:
        cur = m.group(1)
    if 'UNCOVERED' in line and cur:
        num = re.match(r'\s*(\d+)', line)
        if num:
            print(cur, num.group(1), line.strip()[:110])
