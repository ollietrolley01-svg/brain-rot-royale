"""Luau's 200-local limit: a function (or a script's main chunk) with more than 200 locals live at
once does not compile, and in Roblox that is the WHOLE script dead with "Out of local registers when
trying to allocate N locals: exceeded limit 200". verify.py counts a file's TOP-LEVEL locals; this counts
what the compiler counts, the peak live at once in every function, including the locals of a do-block
or a loop body on top of the main chunk's (on 09-24 HudClient read 194 top-level in verify.py but 199
live inside one of its do-blocks, one short of dead). HudClient and MenuClient have been creeping up
on it for weeks (COORDINATION.md, Conventions: "Luau 200-local limit").

    python3 tools/local_limit_check.py .            every .lua file; fails at the limit, warns near it
    python3 tools/local_limit_check.py . --plant    the planted faults; every one must be caught

What it counts: named locals in scope at the same moment inside one function, which is what the
Luau compiler counts (Compiler::pushLocal against kMaxLocalCount = 200). A `do ... end` block gives
its locals back when it ends, so wrapping new top-level locals in `do` is a real fix; loop variables
and parameters count; the hidden for-loop registers do not. `if` EXPRESSIONS (`x = if a then b else c`)
open no block and are told apart from statements the same way lua_static_check does.

It prints each file within WARN of the limit, with the line where the peak was reached, so a worker
adding a local to a busy client script sees the headroom before Studio does.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lua_static_check import parser_tokenize  # noqa: E402

LIMIT = 200
WARN = 185
# Tokens after which `if` starts an if-EXPRESSION. `then`/`else` only count when they belong to an
# if-expression already open (`a = if x then if y then 1 else 2 else 3`); after a statement's `then`
# an `if` is a statement.
EXPRESSION_BEFORE_IF = set("= ( , { [ == ~= < <= > >= .. + - * / // % ^ # and or not return in".split())


def skip_type(toks, i):
    """Index after one type annotation starting at toks[i]."""
    depth = 0
    while toks[i][0] != "eof":
        kind, val, _ = toks[i]
        if val in ("(", "{", "<", "["):
            depth += 1
        elif val in (")", "}", ">", "]"):
            if depth == 0:
                return i
            depth -= 1
        elif depth == 0:
            prev = toks[i - 1][1]
            if val in (",", "=") or (kind == "kw" and val not in ("nil", "typeof")):
                return i
            # Two names in a row at depth 0 means the type ended and a new statement began.
            if kind == "name" and prev not in (":", ".", "|", "&", "?", "->", "typeof") and i > 0 \
                    and toks[i - 1][0] in ("name", "op") and prev not in ("(",) and toks[i - 1][1] != ":":
                if toks[i - 1][0] == "name" or prev in (")", "}", "?", ">"):
                    return i
        i += 1
    return i


def peak_locals(src):
    """(peak, line) over every function in the source: the most named locals live at once."""
    toks = parser_tokenize(src)
    frames = [[[]]]  # frame -> list of scopes -> list of names
    stack = []  # parallel structure markers: "block", "func", "ifcond", "ifexpr-cond", "ifexpr-then", "loophead"
    best = (0, 0)

    def live():
        return sum(len(s) for s in frames[-1])

    def declare(names, line):
        nonlocal best
        frames[-1][-1].extend(names)
        n = live()
        if n > best[0]:
            best = (n, line)

    i = 0
    while toks[i][0] != "eof":
        kind, val, line = toks[i]
        if kind == "kw":
            if val == "local":
                if toks[i + 1][1] == "function":
                    declare([toks[i + 2][1]], line)
                    i += 1  # on to `function`, which opens the body's frame
                    continue
                names, j = [], i + 1
                while toks[j][0] == "name":
                    names.append(toks[j][1])
                    j += 1
                    if toks[j][1] == "<":  # Luau attributes: local x <const>
                        j = skip_type(toks, j + 1) + 1
                    if toks[j][1] == ":":
                        j = skip_type(toks, j + 1)
                    if toks[j][1] == ",":
                        j += 1
                    else:
                        break
                declare(names, line)
                i = j
                continue
            if val == "function":
                # A function literal or statement: new frame; params are its first locals.
                j = i + 1
                while toks[j][1] != "(":
                    j += 1
                params, depth, k = [], 0, j
                while True:
                    t = toks[k]
                    if t[1] in ("(", "{", "[", "<"):
                        depth += 1
                    elif t[1] in (")", "}", "]", ">"):
                        depth -= 1
                        if depth == 0:
                            break
                    elif depth == 1 and t[0] == "name" and toks[k - 1][1] in ("(", ","):
                        params.append(t[1])
                    k += 1
                frames.append([[]])
                stack.append("func")
                declare(params, line)
                i = k + 1
                continue
            if val == "if":
                prev = toks[i - 1][1] if i else ""
                in_expr = stack and stack[-1] in ("ifexpr-cond", "ifexpr-then") and prev in ("then", "else")
                stack.append("ifexpr-cond" if i and (prev in EXPRESSION_BEFORE_IF or in_expr) else "ifcond")
            elif val == "then":
                if stack and stack[-1] == "ifexpr-cond":
                    stack[-1] = "ifexpr-then"
                elif stack and stack[-1] == "ifcond":
                    stack[-1] = "block"
                    frames[-1].append([])
            elif val == "elseif":
                if stack and stack[-1] == "ifexpr-then":
                    stack[-1] = "ifexpr-cond"
                elif stack and stack[-1] == "block":
                    frames[-1].pop()
                    stack[-1] = "ifcond"
            elif val == "else":
                if stack and stack[-1] == "ifexpr-then":
                    stack.pop()
                elif stack and stack[-1] == "block":
                    frames[-1].pop()
                    frames[-1].append([])
            elif val in ("while", "for"):
                stack.append("loophead")
                if val == "for":
                    names, j = [], i + 1
                    while toks[j][0] == "name":
                        names.append(toks[j][1])
                        j += 1
                        if toks[j][1] == ":":
                            j = skip_type(toks, j + 1)
                        if toks[j][1] == ",":
                            j += 1
                        else:
                            break
                    stack[-1] = ("loophead", names)
            elif val == "do":
                top = stack[-1] if stack else None
                if isinstance(top, tuple) or top == "loophead":
                    names = top[1] if isinstance(top, tuple) else []
                    stack[-1] = "block"
                    frames[-1].append([])
                    declare(names, line)
                else:
                    stack.append("block")
                    frames[-1].append([])
            elif val == "repeat":
                stack.append("block")
                frames[-1].append([])
            elif val in ("end", "until"):
                # Close any expression-ifs still open on the stack (an else-less one cannot exist,
                # but be forgiving), then the block itself.
                while stack and stack[-1] in ("ifexpr-then", "ifexpr-cond"):
                    stack.pop()
                if stack:
                    top = stack.pop()
                    if top == "func":
                        frames.pop()
                    else:
                        frames[-1].pop()
        i += 1
    return best


def scan(root):
    out = []
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("node_modules",)]
        for f in files:
            if f.endswith(".lua"):
                path = os.path.join(dirpath, f)
                try:
                    peak, line = peak_locals(open(path, encoding="utf-8", errors="replace").read())
                except Exception as err:  # a file the tokenizer refuses is lua_static_check's business
                    continue
                out.append((peak, os.path.relpath(path, root), line))
    return sorted(out, reverse=True)


PLANTS = [
    ("210 top-level locals", "\n".join("local v%d = %d" % (n, n) for n in range(210)), True),
    ("210 locals split by do-blocks (legal)",
     "do\n" + "\n".join("local a%d = 1" % n for n in range(150)) + "\nend\ndo\n"
     + "\n".join("local b%d = 1" % n for n in range(150)) + "\nend", False),
    ("201 locals inside an if-expression-heavy function",
     "local function f()\n" + "\n".join("local w%d = if x then 1 else 2" % n for n in range(201)) + "\nend", True),
    ("typed locals and a for loop past the limit",
     "for i = 1, 2 do\n" + "\n".join("local t%d: {[string]: number}? = nil" % n for n in range(200)) + "\nend", True),
]


def main():
    root = next((a for a in sys.argv[1:] if not a.startswith("--")), ".")
    if "--plant" in sys.argv:
        caught = 0
        for label, src, should_fail in PLANTS:
            fails = peak_locals(src)[0] > LIMIT
            ok = fails == should_fail
            caught += ok
            print("plant %-52s %s (peak %d)" % (label, "caught" if ok else "MISSED", peak_locals(src)[0]))
        print("local_limit_check plants: %d/%d caught" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = scan(root)
    bad = [r for r in rows if r[0] > LIMIT]
    for peak, rel, line in rows:
        if peak >= WARN:
            print("%s %3d live locals (limit %d), peak at %s:%d" % ("FAIL" if peak > LIMIT else "near", peak, LIMIT, rel, line))
    print("local_limit_check: %d files, %d over the limit, busiest %s (%d)"
          % (len(rows), len(bad), rows[0][1] if rows else "-", rows[0][0] if rows else 0))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
