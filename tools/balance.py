import re, sys, pathlib

def strip(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        # long bracket comment/string
        m = re.match(r'--\[(=*)\[', src[i:])
        if m:
            close = ']' + m.group(1) + ']'
            j = src.find(close, i)
            i = n if j < 0 else j + len(close)
            continue
        if src.startswith('--', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        m = re.match(r'\[(=*)\[', src[i:])
        if m:
            close = ']' + m.group(1) + ']'
            j = src.find(close, i)
            i = n if j < 0 else j + len(close)
            out.append(' "" ')
            continue
        if c in '"\'`':
            q, i = c, i + 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == q:
                    i += 1
                    break
                i += 1
            out.append(' "" ')
            continue
        out.append(c)
        i += 1
    return ''.join(out)

bad = 0
for p in sorted(pathlib.Path(sys.argv[1]).rglob('*.lua')):
    s = strip(p.read_text(encoding='utf-8'))
    toks = re.findall(r'\b[A-Za-z_]\w*\b', s)
    opens = sum(1 for t in toks if t in ('function', 'if', 'do'))
    opens -= sum(1 for t in toks if t == 'elseif')  # 'elseif' matched as separate token already
    ends = sum(1 for t in toks if t == 'end')
    # 'if' inside 'elseif' is not a separate token, so no correction needed
    opens = sum(1 for t in toks if t in ('function', 'if', 'do'))
    delta = opens - ends
    flag = '' if delta == 0 else '   <<< UNBALANCED'
    if delta:
        bad += 1
    print(f'{delta:+3d}  {p.relative_to(sys.argv[1])}{flag}')
print('\nfiles unbalanced:', bad)
