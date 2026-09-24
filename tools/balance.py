import os, re, sys, pathlib

_STRIP_NEXT = re.compile(r'--|\[=*\[|["\'`]')
_LONG_OPEN = re.compile(r'\[(=*)\[')

def strip(src):
    # Linear scan: jump straight to the next comment, long bracket or quote instead of re-slicing
    # the rest of the file at every character (that was quadratic, and BotService is 260 KB).
    out, i, n = [], 0, len(src)
    while i < n:
        m = _STRIP_NEXT.search(src, i)
        if not m:
            out.append(src[i:])
            break
        out.append(src[i:m.start()])
        i = m.start()
        c = src[i]
        if c == '-':
            lm = _LONG_OPEN.match(src, i + 2)
            if lm:
                close = ']' + lm.group(1) + ']'
                j = src.find(close, i)
                i = n if j < 0 else j + len(close)
                continue
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if c == '[':
            close = ']' + m.group()[1:-1] + ']'
            j = src.find(close, i)
            i = n if j < 0 else j + len(close)
            out.append(' "" ')
            continue
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
    return ''.join(out)

bad = 0
# Directories that are never game or probe source. `.claude/worktrees` holds whole agent checkouts
# nested inside the repo: walking them multiplied the work (and judged other branches' files).
SKIP_DIRS = {'.git', '.claude', '__pycache__', 'node_modules', '.venv', 'venv'}

def lua_paths(root):
    for base, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith('.'))
        for name in files:
            if name.endswith('.lua'):
                yield pathlib.Path(base, name)

for p in sorted(lua_paths(sys.argv[1])):
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
