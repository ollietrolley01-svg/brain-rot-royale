"""Static checks for the Luau sources: names that will read as nil at run time, and the eight bug
patterns this project keeps hitting.

Usage:  python tools/lua_static_check.py .            (whole tree; exit 1 if anything is found)
        Only the FIRST syntax error in a file is reported: fix it and run again to see the next.
        python tools/lua_static_check.py . path.lua   (just those files)
        python tools/lua_static_check.py . --patterns-only     (just the PATTERN stage)
        python tools/lua_static_check.py . --no-patterns       (just SCOPE and SYNTAX)
        python tools/lua_static_check.py . --patterns-strict    (pattern findings fail the run)

Studio is the only real compiler here and a run can wait a long time for the lock, so this finds
the cheapest class of runtime error before a build. It tokenizes each file and walks its blocks
with a scope stack, so a name counts as declared only where Lua would actually see it.

What it reports:

  FORWARD     A name used where no local of that name is in scope, but declared as a local LATER in
              an enclosing scope (usually the top level). Luau compiles the use as a global read, so
              it is nil when the line runs: "attempt to call a nil value". Always a bug, except in the
              rare file that deliberately also sets a global of that name.

  UNDECLARED  A name used that is never declared in scope anywhere above it and is not a Roblox/Luau
              global. Usually a typo or a local that was renamed. Includes `local f = function()
              ... f() ... end`, which in Lua really does read a global `f`.

  SYNTAX      Parse errors Studio would refuse the whole script for. The first one per file comes from
              a recursive-descent Luau parser (see the SYNTAX stage section below). If that parser
              crashes on a file, these token rules report instead:
              - a method colon not followed by a call: `x:Name` then anything but `(`, `{` or a string,
                e.g. `tween(...):Completed:Wait()` (a property read needs `.`);
              - a bracket closed by the wrong kind, closed with nothing open, or never closed;
              - an `end` with no block open, or a block (function/if/for/while/do/repeat) never closed.
              Type annotation colons (`local x: T`, `function f(a: T): R`, `for i: T`) are skipped with
              the annotation, and Luau if-expressions (`x = if a then b else c`, no `end`) are told
              apart from if statements by what comes before the `if`.

And a third stage, the PATTERN stage, which answers a different question: not "will Luau run this"
but "is this one of the shapes that has already cost this project a session". The eight rules are
the patterns written up in COORDINATION.md's 2026-09-21 sections, each with the real bug that paid
for it: CLOCK_WALL_TIME, ATTRIBUTE, SNAPSHOT_AS_EVENT, WEAK_TABLE, RETURN_IGNORED, NIL_HANDLER,
NUMBER_DRIFT, SILENT_REFUSAL. Every run prints, per rule, whether it is EXACT or a HEURISTIC and how
many files and CANDIDATE SITES it examined next to how many it flagged — a filter is a claim about
what it matched, and a rule that has quietly stopped matching reads the same as a clean codebase.

Pattern findings are ADVISORY: they are printed but they do not set the exit code unless
--patterns-strict is passed, because the project has a real population of every one of them and a
linter whose first run fails the build gets turned off. What DOES set the exit code is the fixture
run in tools/patterns/: each rule owns a fault it must flag and a correct file it must not, they run
on every invocation, and a rule that stops catching its own fault fails loudly. That is this file
being broken rather than the project, and it is reported as such.

The `lua static check: N files, M findings` line is still the LAST line of output, because that is
the line HANDOFF.md tells everyone to paste verbatim.

Known false positives and blind spots:
  - Globals this list doesn't know (add them to GLOBALS), and deliberate globals set with `_G.x`.
  - Luau type syntax beyond simple annotations (`local x: T`, `(a: T, b: T)`, `): T`): a type name
    used somewhere else (generics, `type X = ...`) may be reported. Lines starting with `type` or
    `export type` are skipped.
  - Identifiers inside backtick interpolated strings are not checked.
  - A multi-line `local x = <expression>` is declared when the next statement starts, judged by
    line breaks and bracket/block depth; unusual formatting can make that a line early or late.
  - A tools/*.lua probe is pasted into runtest.ps1's plugin wrapper, which provides `plugin` and
    names like `lines`; those are listed as globals when checking tools/.
  - Deliberate globals (a probe that reads a global a wrapper may set): declare them in the file with
    a comment, `-- static-check: globals NAME, OTHER`, and they're not reported there.
"""

import os
import re
import sys

GLOBALS = set("""
game workspace script plugin shared _G _VERSION Enum Enums Instance Vector3 Vector3int16 Vector2 Vector2int16 CFrame Color3
UDim UDim2 Rect Region3 Region3int16 Ray Faces Axes BrickColor NumberSequence NumberSequenceKeypoint ColorSequence
ColorSequenceKeypoint NumberRange PhysicalProperties TweenInfo RaycastParams OverlapParams RaycastResult Random DateTime
Font Content PathWaypoint CatalogSearchParams SharedTable DockWidgetPluginGuiInfo FloatCurveKey RotationCurveKey
Path2DControlPoint math table string os task coroutine debug utf8 bit32 buffer vector
pairs ipairs next type typeof tostring tonumber print warn error pcall xpcall require select setmetatable getmetatable
rawget rawset rawequal rawlen unpack assert tick time elapsedTime wait delay spawn gcinfo newproxy loadstring getfenv
setfenv collectgarbage settings UserSettings stats version self
""".split())

# Names the runtest.ps1 plugin wrapper defines around a pasted probe (tools/*.lua only).
PROBE_GLOBALS = set("lines flush NL RUN_TOKEN".split())

KEYWORDS = set("""
and break do else elseif end false for function if in local nil not or repeat return then true until while continue
""".split())

TOKEN_RE = re.compile(r"""
    (?P<ws>[ \t\r\f\v]+)
  | (?P<nl>\n)
  | (?P<longcomment>--\[(?P<lceq>=*)\[.*?\](?P=lceq)\])
  | (?P<comment>--[^\n]*)
  | (?P<longstring>\[(?P<lseq>=*)\[.*?\](?P=lseq)\])
  | (?P<string>"(?:\\.|\\\n|[^"\\\n])*"|'(?:\\.|\\\n|[^'\\\n])*')
  | (?P<backtick>`(?:\\.|[^`\\])*`)
  | (?P<number>0[xX][0-9a-fA-F_]+|0[bB][01_]+|(?:\d[\d_]*\.?[\d_]*|\.\d[\d_]*)(?:[eE][+-]?\d+)?)
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>\.\.\.|\.\.=|\.\.|==|~=|<=|>=|\+=|-=|\*=|/=|//=|//|%=|\^=|::|->|[-+*/%^#<>=(){}\[\];:,.?&|])
  | (?P<other>.)
""", re.S | re.X)


def tokenize(text):
    tokens = []
    line = 1
    for m in TOKEN_RE.finditer(text):
        kind = m.lastgroup
        value = m.group(0)
        if kind in ("ws",):
            pass
        elif kind == "nl":
            line += 1
            continue
        elif kind in ("comment", "longcomment"):
            pass
        elif kind in ("longstring", "string", "backtick"):
            tokens.append(("str", value, line))
        elif kind == "number":
            tokens.append(("num", value, line))
        elif kind == "name":
            tokens.append(("kw" if value in KEYWORDS else "name", value, line))
        else:
            tokens.append(("op", value, line))
        line += value.count("\n")
    return tokens


# A statement can't start with these, so a new line beginning with one continues the previous one.
CONTINUES_NEXT = set("and or .. + - * / // % ^ == ~= < <= > >= . : ( [ { , ) ] } =".split())
# A line ending with these continues onto the next.
CONTINUES_PREV = set("and or not .. + - * / // % ^ == ~= < <= > >= = , ( [ { return local in".split())


# Tokens after which `if` starts an if-EXPRESSION (no `end`) rather than a statement.
EXPRESSION_BEFORE_IF = set("= ( , { [ == ~= < <= > >= .. + - * / // % ^ # and or not return in then else".split())

CLOSES = {")": "(", "]": "[", "}": "{"}


class Scope:
    def __init__(self, kind, line):
        self.kind = kind
        self.names = set()
        self.line = line


def check_file(path, text, extra_globals=frozenset()):
    tokens = tokenize(text)
    # A file can declare globals it sets or expects on purpose: `-- static-check: globals A, B`
    declared_globals = set()
    for m in re.finditer(r"--\s*static-check:\s*globals\s+([A-Za-z_][\w\s,]*)", text):
        declared_globals.update(name for name in re.split(r"[\s,]+", m.group(1)) if name)
    extra_globals = set(extra_globals) | declared_globals
    lines = text.split("\n")
    # Every local declared anywhere, by name -> list of (line, depth) — for telling FORWARD apart.
    findings = []
    stack = [Scope("chunk", 0)]
    brackets = []  # stack of '(', '[', '{'
    pending = []  # [names, bracket_depth, block_depth, line] for `local` awaiting statement end
    bracket_lines = []  # line each open bracket in `brackets` was opened on
    expression_ifs = 0  # Luau if-expressions still waiting for their `else`
    expect_do = 0  # `for`/`while` whose `do` doesn't open another block
    later_locals = {}  # name -> first line declared at any depth (filled by a pre-pass)
    skip_lines = set()

    for index, raw in enumerate(lines, 1):
        stripped = raw.strip()
        if stripped.startswith("type ") or stripped.startswith("export type "):
            skip_lines.add(index)

    # Pre-pass: every `local` / `local function` / `function name` declaration line, for FORWARD.
    for i, (kind, value, line) in enumerate(tokens):
        if kind == "kw" and value == "local":
            j = i + 1
            if j < len(tokens) and tokens[j][1] == "function":
                j += 1
            while j < len(tokens) and tokens[j][0] == "name":
                later_locals.setdefault(tokens[j][1], []).append(line)
                j += 1
                if j < len(tokens) and tokens[j][1] == ":":
                    # type annotation: skip to , or =
                    while j < len(tokens) and tokens[j][1] not in (",", "=") and tokens[j][2] == line:
                        j += 1
                if j < len(tokens) and tokens[j][1] == ",":
                    j += 1
                else:
                    break

    def declare(names):
        stack[-1].names.update(names)

    def in_scope(name):
        return any(name in scope.names for scope in stack)

    def flush_pending():
        keep = []
        for entry in pending:
            names, bracket_depth, block_depth, line = entry
            if block_depth > len(stack) + (1 if names == "POP" else 0):
                continue  # its block has already closed
            if len(brackets) <= bracket_depth and len(stack) <= block_depth:
                if names == "POP":
                    # a `repeat` scope, kept open through its `until` condition
                    while len(stack) >= block_depth and len(stack) > 1:
                        stack.pop()
                else:
                    stack[block_depth - 1].names.update(names)
            else:
                keep.append(entry)
        pending[:] = keep

    def skip_type_annotation(j, stops):
        depth = 0
        start_line = tokens[j][2] if j < len(tokens) else 0
        first = j
        while j < len(tokens):
            v = tokens[j][1]
            if depth == 0 and v in stops:
                return j
            # At depth 0 a type ends with its line: `local t: {T}` with no value mustn't swallow the next one.
            if depth == 0 and j > first and tokens[j][2] != start_line:
                return j
            if v in ("(", "{", "[", "<"):
                depth += 1
            elif v in (")", "}", "]", ">"):
                if depth == 0:
                    return j
                depth -= 1
            j += 1
        return j

    def parse_params(j):
        """tokens[j] is '(' of a parameter list; declare params into the current (new) scope."""
        names = []
        j += 1
        while j < len(tokens) and tokens[j][1] != ")":
            kind, value, _ = tokens[j]
            if kind == "name":
                names.append(value)
                j += 1
                if j < len(tokens) and tokens[j][1] == ":":
                    j = skip_type_annotation(j + 1, (",", ")"))
                continue
            j += 1
        declare(names)
        return j  # at ')'

    i = 0
    prev = None
    while i < len(tokens):
        kind, value, line = tokens[i]
        if line in skip_lines:
            i += 1
            continue

        # A new statement on a new line ends any pending `local` declarations whose depth we're back at.
        if pending and prev is not None and line > prev[2] and prev[1] not in CONTINUES_PREV and value not in CONTINUES_NEXT:
            flush_pending()

        if kind == "op":
            if value in ("(", "[", "{"):
                brackets.append(value)
                bracket_lines.append(line)
            elif value in (")", "]", "}"):
                if not brackets:
                    findings.append(("SYNTAX", line, value, "closes a bracket that was never opened"))
                else:
                    opened = brackets.pop()
                    opened_line = bracket_lines.pop()
                    if CLOSES[value] != opened:
                        findings.append(("SYNTAX", line, value, f"closes the '{opened}' opened at line {opened_line}"))
            elif value == ";":
                flush_pending()
            elif value == ":" and i + 1 < len(tokens) and tokens[i + 1][0] == "name":
                # A method call: `obj:Name(` / `obj:Name{` / `obj:Name"str"`. Annotation colons never reach
                # here (local/param/return/for annotations are skipped where they're parsed).
                before_colon = prev
                after_name = tokens[i + 2] if i + 2 < len(tokens) else None
                callable_before = before_colon is not None and (
                    before_colon[0] in ("name", "str") or before_colon[1] in (")", "]"))
                is_call = after_name is not None and (after_name[1] in ("(", "{") or after_name[0] == "str")
                if callable_before and not is_call:
                    findings.append(("SYNTAX", line, ":" + tokens[i + 1][1],
                        "a method colon must be followed by a call; use '.' to read a property"))
            prev = tokens[i]
            i += 1
            continue

        if kind == "kw":
            if value == "local":
                j = i + 1
                if j < len(tokens) and tokens[j][1] == "function":
                    # A malformed `local function (x)` has no name; the parser reports it, this pass
                    # just mustn't fall over.
                    named = j + 1 < len(tokens) and tokens[j + 1][0] == "name"
                    if named:
                        declare([tokens[j + 1][1]])  # visible inside its own body (recursion)
                    stack.append(Scope("function", line))
                    k = j + 2 if named else j + 1
                    while k < len(tokens) and tokens[k][1] != "(":
                        k += 1
                    k = parse_params(k)
                    if k + 1 < len(tokens) and tokens[k + 1][1] == ":":
                        # A return type annotation runs to the end of the signature's line.
                        colon_line = tokens[k + 1][2]
                        k += 1
                        while k + 1 < len(tokens) and tokens[k + 1][2] == colon_line:
                            k += 1
                    k = min(k, len(tokens) - 1)
                    prev = tokens[k]
                    i = k + 1
                    continue
                names = []
                while j < len(tokens) and tokens[j][0] == "name":
                    names.append(tokens[j][1])
                    j += 1
                    if j < len(tokens) and tokens[j][1] == ":":
                        j = skip_type_annotation(j + 1, (",", "="))
                    if j < len(tokens) and tokens[j][1] == ",":
                        j += 1
                    else:
                        break
                if j < len(tokens) and tokens[j][1] == "=":
                    pending.append([names, len(brackets), len(stack), line])
                else:
                    declare(names)
                prev = tokens[j - 1]
                i = j
                continue
            if value == "function":
                # `function a.b:c(...)` or anonymous `function(...)`
                j = i + 1
                method = False
                while j < len(tokens) and tokens[j][1] != "(":
                    if tokens[j][1] == ":":
                        method = True
                    j += 1
                # The function's own name path is a use of its first segment (e.g. `function M.f()` uses M).
                if j > i + 1 and tokens[i + 1][0] == "name":
                    first = tokens[i + 1]
                    if not in_scope(first[1]) and first[1] not in GLOBALS and first[1] not in extra_globals:
                        findings.append(classify(first[1], first[2], later_locals))
                stack.append(Scope("function", line))
                if method:
                    declare(["self"])
                k = parse_params(j)
                if k + 1 < len(tokens) and tokens[k + 1][1] == ":":
                    # A return type annotation runs to the end of the signature's line.
                    colon_line = tokens[k + 1][2]
                    k += 1
                    while k + 1 < len(tokens) and tokens[k + 1][2] == colon_line:
                        k += 1
                k = min(k, len(tokens) - 1)
                prev = tokens[k]
                i = k + 1
                continue
            if value in ("for", "while"):
                stack.append(Scope(value, line))
                expect_do += 1
                if value == "for":
                    j = i + 1
                    names = []
                    while j < len(tokens) and tokens[j][0] == "name":
                        names.append(tokens[j][1])
                        j += 1
                        if j < len(tokens) and tokens[j][1] == ":":
                            j = skip_type_annotation(j + 1, (",", "=", "in"))
                        if j < len(tokens) and tokens[j][1] == ",":
                            j += 1
                        else:
                            break
                    # Loop variables are visible in the body, not the header; close enough to declare now.
                    declare(names)
                    prev = tokens[j - 1]
                    i = j
                    continue
            elif value == "do":
                if expect_do > 0:
                    expect_do -= 1
                else:
                    stack.append(Scope("do", line))
            elif value == "if":
                if prev is not None and prev[1] in EXPRESSION_BEFORE_IF and prev[2] == line:
                    expression_ifs += 1
                else:
                    stack.append(Scope("if", line))
            elif value == "elseif" and expression_ifs > 0 and stack[-1].kind != "if":
                pass
            elif value == "else" and expression_ifs > 0 and stack[-1].kind != "if":
                expression_ifs -= 1
            elif value in ("elseif", "else"):
                stack[-1].names = set()
            elif value == "repeat":
                stack.append(Scope("repeat", line))
            elif value == "end":
                flush_pending()
                if len(stack) > 1:
                    stack.pop()
                else:
                    findings.append(("SYNTAX", line, "end", "no block is open here"))
            elif value == "until":
                # Locals from the loop body are still visible in the condition: close the scope when
                # the condition's statement ends instead.
                flush_pending()
                pending.append(["POP", len(brackets), len(stack), line])
            prev = tokens[i]
            i += 1
            continue

        if kind == "name":
            before = prev[1] if prev else None
            after = tokens[i + 1][1] if i + 1 < len(tokens) else None
            is_field = before in (".", ":") and prev[0] == "op"
            is_key = after == "=" and brackets and brackets[-1] == "{" and before in ("{", ",", ";")
            if not is_field and not is_key and value not in GLOBALS and value not in extra_globals and not in_scope(value):
                # `x = ...` at statement start assigns a global; still worth reporting.
                findings.append(classify(value, line, later_locals))
        prev = tokens[i]
        i += 1

    # End of file: everything opened must have been closed.
    flush_pending()
    for opened, opened_line in zip(brackets, bracket_lines):
        findings.append(("SYNTAX", opened_line, opened, "never closed"))
    for scope in stack[1:]:
        findings.append(("SYNTAX", scope.line, scope.kind, "block opened here has no matching end"))

    # One report per name per line.
    seen = set()
    unique = []
    for finding in findings:
        key = (finding[0], finding[1], finding[2])
        if key not in seen:
            seen.add(key)
            unique.append(finding)
    return unique



# ----------------------------------------------------------------------------------------------------
# SYNTAX stage: a recursive-descent, syntax-only Luau parser.
#
# Written by the HUD & UX tab (claude-43's worker) as luau_parse.py and adopted here: on a 200-mutation
# corpus it caught 176 syntax errors against 81 for the old token rules (its misses were all still-valid
# Lua). Two changes on adoption: a type after a name ends at a line break at depth 0, and a return type
# ends at a statement keyword, so `local t: {T}` without a value and one-line annotated functions parse.
# It reports the first syntax error in a file. If it ever crashes on a file (a bug here, not in the
# file), the token rules in check_file stand in, so a crash never silently passes a file.
# ----------------------------------------------------------------------------------------------------

PARSER_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local",
            "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"}

class LuauParseError(Exception):
    pass

def parser_tokenize(src):
    toks = []
    i, n, line = 0, len(src), 1
    ops = ["...", "..=", "//=", "==", "~=", "<=", ">=", "..", "::", "->", "+=", "-=", "*=", "/=", "%=", "^=", "//",
           "+", "-", "*", "/", "%", "^", "#", "<", ">", "=", "(", ")", "{", "}", "[", "]", ";", ":", ",", ".", "?", "&", "|"]
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1; i += 1; continue
        if c in " \t\r":
            i += 1; continue
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i)
                if j < 0: raise LuauParseError(f"line {line}: unfinished long comment")
                line += src.count("\n", i, j); i = j + len(close); continue
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        m = re.match(r"\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i)
            if j < 0: raise LuauParseError(f"line {line}: unfinished long string")
            toks.append(("string", "[[", line)); line += src.count("\n", i, j); i = j + len(close); continue
        if c in "\"'`":
            q = c; j = i + 1
            while j < n and src[j] != q:
                if src[j] == "\\": j += 2; continue
                if src[j] == "\n" and q != "`": raise LuauParseError(f"line {line}: unfinished string")
                j += 1
            if j >= n: raise LuauParseError(f"line {line}: unfinished string")
            if q == "`":
                # Luau: every `{` in an interpolated string needs its `}` before the closing backtick.
                depth, k = 0, i + 1
                while k < j:
                    if src[k] == "\\": k += 2; continue
                    if depth > 0 and src[k] in "\"'":
                        # a string inside the {expression}: its braces are text, not delimiters
                        quote, k = src[k], k + 1
                        while k < j and src[k] != quote:
                            k += 2 if src[k] == "\\" else 1
                        k += 1
                        continue
                    if src[k] == "{": depth += 1
                    elif src[k] == "}" and depth > 0: depth -= 1
                    k += 1
                if depth != 0:
                    raise LuauParseError(f"line {line}: malformed interpolated string, expected '}}' before '`'")
            toks.append(("string", q, line)); line += src.count("\n", i, j); i = j + 1; continue
        m = re.match(r"0[xX][0-9a-fA-F_]+|0[bB][01_]+|(\d[\d_]*\.?[\d_]*|\.\d[\d_]*)([eE][+-]?\d+)?", src[i:])
        if m and m.group(0) and (c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit())):
            toks.append(("number", m.group(0), line)); i += len(m.group(0)); continue
        m = re.match(r"[A-Za-z_]\w*", src[i:])
        if m:
            w = m.group(0)
            toks.append(("kw" if w in PARSER_KEYWORDS else "name", w, line)); i += len(w); continue
        for op in ops:
            if src.startswith(op, i):
                toks.append(("op", op, line)); i += len(op); break
        else:
            raise LuauParseError(f"line {line}: unexpected character {c!r}")
    toks.append(("eof", "", line))
    return toks

PARSER_BINARY = {"or": 1, "and": 2, "<": 3, ">": 3, "<=": 3, ">=": 3, "~=": 3, "==": 3, "..": 5, "+": 6, "-": 6,
          "*": 7, "/": 7, "//": 7, "%": 7, "^": 10}
PARSER_RIGHT = {"..", "^"}
PARSER_UNARY = 8

class LuauParser:
    def __init__(self, toks):
        self.t = toks; self.p = 0
        # Luau refuses `break`/`continue` outside a loop and `...` outside a vararg function (the main
        # chunk is vararg); a nested function starts outside any loop.
        self.loops = 0; self.vararg = True
    def loop_block(self, terminators):
        self.loops += 1
        try:
            self.block(terminators)
        finally:
            self.loops -= 1
    def peek(self, k=0):
        return self.t[self.p + k]
    def is_(self, kind, val=None, k=0):
        tok = self.peek(k)
        return tok[0] == kind and (val is None or tok[1] == val)
    def isop(self, val, k=0):
        return self.is_("op", val, k)
    def iskw(self, val, k=0):
        return self.is_("kw", val, k)
    def take(self):
        tok = self.t[self.p]; self.p += 1; return tok
    def expect(self, kind, val=None):
        tok = self.peek()
        if tok[0] != kind or (val is not None and tok[1] != val):
            raise LuauParseError(f"line {tok[2]}: expected {val or kind}, got {tok[1] or tok[0]!r}")
        return self.take()

    # --- types (skipped, balanced) ---
    def skip_type(self, stops, newline_ends=False):
        depth = 0
        start = self.p
        start_line = self.peek()[2]
        while True:
            tok = self.peek()
            if tok[0] == "eof": raise LuauParseError(f"line {tok[2]}: unfinished type")
            v = tok[1]
            if newline_ends and depth == 0 and self.p > start and tok[2] != start_line: break
            if depth == 0 and tok[0] == "op" and v in stops: break
            if depth == 0 and tok[0] == "kw" and v in stops: break
            if tok[0] == "op" and v in "({[" or (tok[0] == "op" and v == "<"):
                depth += 1
            elif tok[0] == "op" and v in ")}]" or (tok[0] == "op" and v == ">"):
                if depth == 0: break
                depth -= 1
            self.take()
        if self.p == start: raise LuauParseError(f"line {self.peek()[2]}: expected a type")

    # --- blocks ---
    def block(self, terminators):
        while True:
            tok = self.peek()
            if tok[0] == "eof" or (tok[0] == "kw" and tok[1] in terminators):
                return
            if self.iskw("return"):
                self.take()
                if not (self.peek()[0] == "eof" or (self.peek()[0] == "kw" and self.peek()[1] in terminators) or self.isop(";")):
                    self.exprlist()
                if self.isop(";"): self.take()
                tok = self.peek()
                if not (tok[0] == "eof" or (tok[0] == "kw" and tok[1] in terminators)):
                    raise LuauParseError(f"line {tok[2]}: code after return")
                return
            self.statement()

    def statement(self):
        tok = self.peek()
        if self.isop(";"): self.take(); return
        if tok[0] == "kw":
            v = tok[1]
            if v == "local":
                self.take()
                if self.iskw("function"):
                    self.take(); self.expect("name"); self.funcbody(); return
                self.expect("name"); self.opt_type_after_name()
                while self.isop(","):
                    self.take(); self.expect("name"); self.opt_type_after_name()
                if self.isop("="):
                    self.take(); self.exprlist()
                return
            if v == "function":
                self.take(); self.expect("name")
                while self.isop("."):
                    self.take(); self.expect("name")
                if self.isop(":"):
                    self.take(); self.expect("name")
                self.funcbody(); return
            if v == "if":
                self.take(); self.expr(); self.expect("kw", "then"); self.block({"elseif", "else", "end"})
                while self.iskw("elseif"):
                    self.take(); self.expr(); self.expect("kw", "then"); self.block({"elseif", "else", "end"})
                if self.iskw("else"):
                    self.take(); self.block({"end"})
                self.expect("kw", "end"); return
            if v == "while":
                self.take(); self.expr(); self.expect("kw", "do"); self.loop_block({"end"}); self.expect("kw", "end"); return
            if v == "do":
                self.take(); self.block({"end"}); self.expect("kw", "end"); return
            if v == "repeat":
                self.take(); self.loop_block({"until"}); self.expect("kw", "until"); self.expr(); return
            if v == "for":
                self.take(); self.expect("name"); self.opt_type_after_name()
                if self.isop("="):
                    self.take(); self.expr(); self.expect("op", ","); self.expr()
                    if self.isop(","): self.take(); self.expr()
                else:
                    while self.isop(","):
                        self.take(); self.expect("name"); self.opt_type_after_name()
                    self.expect("kw", "in"); self.exprlist()
                self.expect("kw", "do"); self.loop_block({"end"}); self.expect("kw", "end"); return
            if v == "break":
                if self.loops == 0:
                    raise LuauParseError(f"line {tok[2]}: break outside a loop")
                self.take(); return
            raise LuauParseError(f"line {tok[2]}: unexpected {v!r}")
        if tok[0] == "name" and tok[1] == "continue" and not (self.isop("(", 1) or self.isop("=", 1) or self.isop(".", 1) or self.isop(":", 1) or self.isop("[", 1)):
            if self.loops == 0:
                raise LuauParseError(f"line {tok[2]}: continue outside a loop")
            self.take(); return
        if tok[0] == "name" and tok[1] in ("type", "export") and self.peek(1)[0] == "name":
            # type declarations: skip to the end of the line
            line = tok[2]
            while self.peek()[2] == line and self.peek()[0] != "eof": self.take()
            return
        # expression statement: call or assignment
        start_line = tok[2]
        kind = self.suffixedexp()
        if self.isop("=") or self.isop(","):
            if kind not in ("var",): raise LuauParseError(f"line {start_line}: cannot assign to that")
            while self.isop(","):
                self.take()
                if self.suffixedexp() != "var": raise LuauParseError(f"line {start_line}: cannot assign to that")
            self.expect("op", "="); self.exprlist(); return
        if self.peek()[0] == "op" and self.peek()[1] in ("+=", "-=", "*=", "/=", "%=", "^=", "..=", "//="):
            if kind != "var": raise LuauParseError(f"line {start_line}: cannot assign to that")
            self.take(); self.expr(); return
        if kind != "call":
            raise LuauParseError(f"line {self.peek()[2]}: syntax error near {self.peek()[1]!r} (a statement must be a call or an assignment)")

    def opt_type_after_name(self):
        if self.isop(":"):
            self.take(); self.skip_type({",", "=", ")", "in", "do"}, newline_ends=True)

    def funcbody(self):
        if self.isop("<"):
            self.take(); self.skip_type({">"}); self.expect("op", ">")
        self.expect("op", "(")
        vararg = False
        if not self.isop(")"):
            while True:
                if self.isop("..."):
                    vararg = True
                    self.take()
                    if self.isop(":"): self.take(); self.skip_type({")"})
                    break
                self.expect("name"); self.opt_type_after_name()
                if self.isop(","): self.take(); continue
                break
        self.expect("op", ")")
        if self.isop(":"):
            self.take()
            # a return type runs to the first token on a later line, or a statement keyword
            line = self.peek()[2]
            depth = 0
            while True:
                tok = self.peek()
                if tok[0] == "eof": break
                if depth == 0 and tok[2] != line: break
                if depth == 0 and tok[0] == "kw" and tok[1] not in ("nil", "true", "false"): break
                if tok[0] == "op" and tok[1] in "({[<": depth += 1
                if tok[0] == "op" and tok[1] in ")}]>": depth -= 1
                self.take()
        saved = (self.loops, self.vararg)
        self.loops, self.vararg = 0, vararg
        try:
            self.block({"end"})
        finally:
            self.loops, self.vararg = saved
        self.expect("kw", "end")

    def exprlist(self):
        self.expr()
        while self.isop(","):
            self.take(); self.expr()

    def primaryexp(self):
        tok = self.peek()
        if tok[0] == "name":
            self.take(); return "var"
        if self.isop("("):
            self.take(); self.expr(); self.expect("op", ")"); return "paren"
        raise LuauParseError(f"line {tok[2]}: unexpected {tok[1] or tok[0]!r}")

    def suffixedexp(self):
        kind = self.primaryexp()
        while True:
            if self.isop("."):
                self.take(); self.expect("name"); kind = "var"
            elif self.isop("["):
                self.take(); self.expr(); self.expect("op", "]"); kind = "var"
            elif self.isop(":") and self.peek(1)[0] == "name":
                self.take(); self.take()
                if not (self.isop("(") or self.is_("string") or self.isop("{")):
                    tok = self.peek()
                    raise LuauParseError(f"line {tok[2]}: expected '(', '{{' or <string> when parsing function call, got {tok[1]!r}")
                self.callargs(); kind = "call"
            elif self.isop(":"):
                tok = self.peek(1)
                raise LuauParseError(f"line {tok[2]}: expected a method name after ':', got {tok[1]!r}")
            elif self.isop("(") or self.is_("string") or self.isop("{"):
                if self.isop("(") and self.peek()[2] != self.t[self.p - 1][2]:
                    # Lua allows it, but it's ambiguous; accept
                    pass
                self.callargs(); kind = "call"
            else:
                return kind

    def callargs(self):
        if self.is_("string"):
            self.take(); return
        if self.isop("{"):
            self.table(); return
        self.expect("op", "(")
        if not self.isop(")"):
            self.exprlist()
        self.expect("op", ")")

    def table(self):
        self.expect("op", "{")
        while not self.isop("}"):
            if self.isop("["):
                self.take(); self.expr(); self.expect("op", "]"); self.expect("op", "="); self.expr()
            elif self.peek()[0] == "name" and self.isop("=", 1):
                self.take(); self.take(); self.expr()
            else:
                self.expr()
            if self.isop(",") or self.isop(";"):
                self.take()
            elif not self.isop("}"):
                tok = self.peek()
                raise LuauParseError(f"line {tok[2]}: expected ',' or '}}' in table, got {tok[1]!r}")
        self.take()

    def simpleexp(self):
        tok = self.peek()
        if tok[0] in ("number", "string"):
            self.take(); return
        if tok[0] == "kw" and tok[1] in ("nil", "true", "false"):
            self.take(); return
        if self.isop("..."):
            if not self.vararg:
                raise LuauParseError(f"line {tok[2]}: '...' used outside a vararg function")
            self.take(); return
        if self.isop("{"):
            self.table(); return
        if self.iskw("function"):
            self.take(); self.funcbody(); return
        if self.iskw("if"):
            self.take(); self.expr(); self.expect("kw", "then"); self.expr()
            while self.iskw("elseif"):
                self.take(); self.expr(); self.expect("kw", "then"); self.expr()
            self.expect("kw", "else"); self.expr(); return
        self.suffixedexp()

    def expr(self, limit=0):
        tok = self.peek()
        if (tok[0] == "kw" and tok[1] == "not") or (tok[0] == "op" and tok[1] in ("-", "#")):
            self.take(); self.expr(PARSER_UNARY)
        else:
            self.simpleexp()
        if self.isop("::"):
            self.take(); self.skip_type({",", ")", "]", "}", "then", "do", "end", "=", ";", "else", "elseif"} | set(PARSER_BINARY))
        while True:
            tok = self.peek()
            op = tok[1] if (tok[0] == "op" or (tok[0] == "kw" and tok[1] in ("and", "or"))) else None
            if op is None or op not in PARSER_BINARY or PARSER_BINARY[op] <= limit:
                return
            self.take()
            self.expr(PARSER_BINARY[op] - 1 if op in PARSER_RIGHT else PARSER_BINARY[op])



def parse_syntax(text):
    """Returns None when the file parses, (line, message) for its first syntax error, or raises on a
    parser bug (the caller falls back to the token rules)."""
    try:
        parser = LuauParser(parser_tokenize(text))
        parser.block(set())
        if parser.peek()[0] != "eof":
            tok = parser.peek()
            raise LuauParseError(f"line {tok[2]}: unexpected {tok[1]!r}")
        return None
    except LuauParseError as error:
        message = str(error)
        match = re.match(r"line (\d+): (.*)", message)
        if match:
            return int(match.group(1)), match.group(2)
        return 0, message
    except RecursionError:
        return 0, "too deeply nested for the parser"

def classify(name, line, later_locals):
    later = [at for at in later_locals.get(name, []) if at > line]
    if later:
        return ("FORWARD", line, name, f"declared as a local at line {later[0]}, below this use")
    return ("UNDECLARED", line, name, "not a local in scope here, and not a known global")


# ====================================================================================================
# PATTERN stage: the eight recurring bug patterns from COORDINATION.md's 2026-09-21 sections.
#
# The SCOPE and SYNTAX stages above answer "will Luau run this file". This stage answers a different
# question — "is this one of the shapes that has already cost this project a session" — so it is kept
# separate and it does NOT gate the exit code by default. A linter whose first run produces four
# hundred findings gets turned off, and every pattern below has a real population in this tree.
# What DOES gate the exit code is the permanent fixture run (see run_pattern_self_test): if a rule
# stops catching its own planted fault, that is this file being broken and it fails loudly.
#
# Every rule reads its input through tokenize() above. That matters: tokenize drops comments and
# keeps string literals intact, which is the opposite of tools/verify.py:31's _strip_lua (it replaces
# every string with an empty one). A check on what a string SAYS — rule P7 here — is dead on arrival
# if it is fed stripped source, and it passed a green self-test on this project already because the
# needle was handed a raw literal while the real check was fed stripped source. Both the real input
# and the fixtures here travel the same open() -> tokenize() -> rule route.
#
# Every rule reports how many FILES and how many CANDIDATE SITES it examined next to how many it
# flagged: a filter is a claim about what it matched, and a rule matching nothing otherwise reads
# identically to a rule that is broken.
#
# EXACT vs HEURISTIC is recorded per rule and printed on every run. A heuristic pretending to be
# exact gets switched off by the first person it annoys.
# ====================================================================================================

# Where the game's own code lives. tools/ is swept too, but a probe is judged differently from a
# module the players run, so some rules report tools/ separately.
GAME_DIRS = ("ServerScriptService", "ReplicatedStorage", "StarterPlayerScripts", "StarterGui")

# Fixture files live here (see run_pattern_self_test). They are NOT swept as project files: the
# whole point of them is to be wrong. They are counted as game code by the one membership test
# below so that every rule runs its fixture through exactly the code path it runs real input
# through — no second route for the needle.
PATTERN_FIXTURE_DIR = "tools/patterns"


class ScanFile:
    """One file's text and tokens. `rel` is project-relative with forward slashes."""

    __slots__ = ("rel", "text", "tokens", "by_line", "is_game")

    def __init__(self, rel, text):
        self.rel = rel.replace("\\", "/")
        self.text = text
        self.tokens = tokenize(text)
        self.by_line = {}
        for token in self.tokens:
            self.by_line.setdefault(token[2], []).append(token)
        first = self.rel.split("/")[0]
        self.is_game = first in GAME_DIRS or self.rel.startswith(PATTERN_FIXTURE_DIR)


class PatternReport:
    """Findings, per-rule coverage counts, and notes (things worth a human's eye but not findings)."""

    def __init__(self):
        self.findings = []  # (rel, line, code, subject, note)
        self.notes = []  # (code, text)
        self.stats = {}  # code -> {files, candidates, flagged}

    def rule(self, code):
        return self.stats.setdefault(code, {"files": 0, "candidates": 0, "flagged": 0})

    def flag(self, code, rel, line, subject, note):
        self.findings.append((rel, line, code, subject, note))
        self.rule(code)["flagged"] += 1

    def note(self, code, text):
        self.notes.append((code, text))

    def codes_flagged(self):
        return {finding[2] for finding in self.findings}


# --- small token helpers shared by the rules -------------------------------------------------------

def _string_content(literal):
    """The text inside a string token, quotes/long brackets removed. Escapes are left alone: every
    rule here looks for digits, and no escape produces one."""
    if literal.startswith("["):
        match = re.match(r"\[(=*)\[(.*)\]\1\]$", literal, re.S)
        return match.group(2) if match else literal
    return literal[1:-1]


def _dotted_before(tokens, i):
    """The `a.b:c` chain ending at the name tokens[i], as a list of segments."""
    parts = [tokens[i][1]]
    j = i - 1
    while j - 1 >= 0 and tokens[j][0] == "op" and tokens[j][1] in (".", ":") and tokens[j - 1][0] == "name":
        parts.insert(0, tokens[j - 1][1])
        j -= 2
    return parts, j + 1


def _matching_close(tokens, i):
    """tokens[i] is an opening bracket; index of its match, or None."""
    opens = {"(": ")", "[": "]", "{": "}"}
    if tokens[i][1] not in opens:
        return None
    depth = 0
    for j in range(i, len(tokens)):
        value = tokens[j][1]
        if tokens[j][0] != "op":
            continue
        if value in opens:
            depth += 1
        elif value in (")", "]", "}"):
            depth -= 1
            if depth == 0:
                return j
    return None


def _statement_end(tokens, i):
    """Index one past the statement starting at tokens[i], judged the same way the scope pass judges
    it: bracket depth, then a line break that neither side continues."""
    depth = 0
    prev = None
    j = i
    while j < len(tokens):
        kind, value, line = tokens[j]
        if kind == "op" and value in ("(", "[", "{"):
            depth += 1
        elif kind == "op" and value in (")", "]", "}"):
            if depth == 0:
                return j
            depth -= 1
        elif depth == 0:
            if kind == "op" and value == ";":
                return j
            # No statement STARTS with a block-closing keyword, so this is right at j == i too:
            # `warn(...) return end` has an empty return, and reading past the `end` was how the
            # SILENT_REFUSAL rule managed to stop matching its own planted fault.
            if kind == "kw" and value in ("end", "else", "elseif", "until"):
                return j
            if prev is not None and line > prev[2] and prev[1] not in CONTINUES_PREV and value not in CONTINUES_NEXT:
                return j
        prev = tokens[j]
        j += 1
    return j


def _param_names(tokens, i):
    """tokens[i] is the '(' of a parameter list. Returns (names, index of the ')')."""
    names = []
    close = _matching_close(tokens, i)
    if close is None:
        return names, min(i, len(tokens) - 1)
    depth = 0
    j = i + 1
    while j < close:
        kind, value, _ = tokens[j]
        if kind == "op" and value in ("(", "[", "{", "<"):
            depth += 1
        elif kind == "op" and value in (")", "]", "}", ">"):
            depth -= 1
        elif depth == 0 and kind == "name" and (j == i + 1 or tokens[j - 1][1] == ","):
            names.append(value)
        j += 1
    return names, close


def function_frames(tokens):
    """Every function in a file: its name, params and token range.

    A small independent block walk rather than a change to check_file's scope pass, which is doing a
    different job and is not mine to restructure. Keys: name (dotted, or None for an anonymous one),
    params, start (the `function` keyword), body (first token after the signature), end (its `end`).
    """
    frames = []
    stack = []  # (kind, frame or None)
    expect_do = 0
    expression_ifs = 0
    prev = None
    i = 0
    count = len(tokens)
    while i < count:
        kind, value, line = tokens[i]
        if kind == "kw":
            if value == "function":
                j = i + 1
                parts = []
                while j < count and tokens[j][1] != "(":
                    if tokens[j][0] == "name":
                        parts.append(tokens[j][1])
                    j += 1
                if j >= count:
                    break
                if not parts and prev is not None and prev[1] == "=" and i - 2 >= 0 and tokens[i - 2][0] == "name":
                    # `M.f = function(...)` — the name is on the other side of the '='.
                    parts, _ = _dotted_before(tokens, i - 2)
                params, close = _param_names(tokens, j)
                frame = {
                    "name": ".".join(parts) if parts else None,
                    "params": params,
                    "start": i,
                    "body": close + 1,
                    "end": None,
                    "line": line,
                }
                frames.append(frame)
                stack.append(("function", frame))
                prev = tokens[close]
                i = close + 1
                continue
            if value in ("for", "while"):
                stack.append((value, None))
                expect_do += 1
            elif value == "do":
                if expect_do > 0:
                    expect_do -= 1
                else:
                    stack.append(("do", None))
            elif value == "if":
                if prev is not None and prev[1] in EXPRESSION_BEFORE_IF and prev[2] == line:
                    expression_ifs += 1
                else:
                    stack.append(("if", None))
            elif value == "else" and expression_ifs > 0 and (not stack or stack[-1][0] != "if"):
                expression_ifs -= 1
            elif value == "repeat":
                stack.append(("repeat", None))
            elif value == "end":
                if stack:
                    _, frame = stack.pop()
                    if frame is not None:
                        frame["end"] = i
            elif value == "until":
                if stack:
                    stack.pop()
        prev = tokens[i]
        i += 1
    return [frame for frame in frames if frame["end"] is not None]


def _owning_frame(frames, index):
    """The innermost frame containing a token index — the function a statement really belongs to."""
    best = None
    for frame in frames:
        if frame["body"] <= index < frame["end"] and (best is None or frame["body"] > best["body"]):
            best = frame
    return best


def _last_segment(name):
    return name.rsplit(".", 1)[-1] if name else name


# --- P1: os.clock used as wall time ---------------------------------------------------------------
# os.clock() is process CPU TIME in Roblox, not wall clock. A build that takes 20 s of a player's
# time can read as 8 s, and the gap moves with how much the code yields — so every cooldown, budget
# and deadline specified in seconds and counted in os.clock() is wrong by an amount nobody can
# predict. Use os.time(), tick() or DateTime.now().UnixTimestampMillis.
#
# EXACT on the fact (os.clock is CPU time; the call is unambiguous). The site classification below
# is what keeps the list readable: a reading that only feeds an accumulator or a one-off profile
# print is counted as a candidate and not flagged, because CPU time is arguably what it wanted.

CLOCK_TIMESTAMP_NAME = re.compile(
    r"^(at|now|since|start|started|begin|began|t0|"
    r"last[A-Z_]?\w*|next[A-Z_]?\w*|\w*[Tt]ime|\w*[Uu]ntil|\w*[Ss]tamp|\w*[Dd]eadline|\w*[Ee]xpires?|"
    r"\w*[Cc]ooldown|\w*[Aa]t)$")
CLOCK_COMPARE = {"<", "<=", ">", ">=", "==", "~="}
CLOCK_ACCUMULATE = {"+=", "-="}


def _clock_use(scan_file, index):
    """Why this os.clock() reading is a wall-clock use, or None when it is only CPU profiling."""
    line = scan_file.tokens[index][2]
    row = scan_file.by_line.get(line, [])
    values = [token[1] for token in row]
    if any(value in CLOCK_COMPARE for value in values):
        return "compared as a duration"
    after = scan_file.tokens[index + 5] if index + 5 < len(scan_file.tokens) else None
    if after is not None and after[1] == "+" and after[2] == line:
        return "a deadline (os.clock() + seconds)"
    if any(value in CLOCK_ACCUMULATE for value in values):
        return None  # `STATS.x += os.clock() - t` is a CPU-time accumulator, not a budget
    if "=" in values:
        target = None
        for token in row:
            if token[1] == "=":
                break
            if token[0] == "name":
                target = token[1]
        if target and CLOCK_TIMESTAMP_NAME.match(target):
            return f"stored as a timestamp in `{target}`"
    return None


def pattern_os_clock(scan, report, targets):
    code = "CLOCK_WALL_TIME"
    stats = report.rule(code)
    stats["files"] = len(scan)
    per_file = {}
    tool_sites = 0
    tool_files = set()
    for scan_file in scan:
        for index, (kind, value, _) in enumerate(scan_file.tokens):
            if kind != "name" or value != "os":
                continue
            tokens = scan_file.tokens
            if not (index + 2 < len(tokens) and tokens[index + 1][1] == "." and tokens[index + 2][1] == "clock"):
                continue
            stats["candidates"] += 1
            why = _clock_use(scan_file, index)
            if why is None:
                continue
            if scan_file.is_game:
                per_file.setdefault(scan_file.rel, []).append((tokens[index][2], why))
            else:
                tool_sites += 1
                tool_files.add(scan_file.rel)
    # One finding per FILE, not per site: 217 separate findings for one systemic mistake is how a
    # linter gets turned off. The lines are all in the note.
    for rel, uses in sorted(per_file.items()):
        if rel not in targets:
            continue
        lines = [line for line, _ in uses]
        shown = ", ".join(str(line) for line in lines[:8])
        if len(lines) > 8:
            shown += f", +{len(lines) - 8} more"
        report.flag(code, rel, lines[0], "os.clock",
                    f"{len(uses)} wall-clock use(s) of os.clock(), which is CPU time in Roblox; "
                    f"lines {shown}; first is {uses[0][1]}")
    if tool_sites:
        report.note(code, f"{tool_sites} wall-clock os.clock() use(s) in {len(tool_files)} tools/ file(s) "
                          f"— not flagged (a probe timing itself is a judgement call, but a probe "
                          f"timeout keyed off os.clock() can never fire)")


# --- P2: an attribute written and never read, and the reverse -------------------------------------
# The admin Fly power set an attribute nothing in the project read, so the button did nothing at all.
# Sweeps SetAttribute against GetAttribute / GetAttributeChangedSignal across the whole tree.
#
# HEURISTIC. The index it builds is exact — "no literal read of this name exists in the swept Lua" —
# but an attribute can also be set by the place file, by a Studio property, or read by a name this
# pass cannot see. Names built by concatenation are the big one: `"KP_" .. name` is reported
# SEPARATELY, and any literal name that shares a prefix or suffix with a concatenated fragment is
# demoted to a note rather than flagged.

ATTR_WRITERS = {"SetAttribute"}
ATTR_READERS = {"GetAttribute", "GetAttributeChangedSignal"}


def _string_constants(scan_file):
    """`local NAME = "literal"` in this file, so `part:SetAttribute(BASE_COLOR, v)` resolves."""
    found = {}
    tokens = scan_file.tokens
    for index in range(len(tokens) - 3):
        if tokens[index][1] != "local" or tokens[index][0] != "kw":
            continue
        if tokens[index + 1][0] == "name" and tokens[index + 2][1] == "=" and tokens[index + 3][0] == "str":
            after = tokens[index + 4] if index + 4 < len(tokens) else None
            if after is None or after[1] != "..":
                found[tokens[index + 1][1]] = _string_content(tokens[index + 3][1])
    return found


def pattern_attributes(scan, report, targets):
    code = "ATTRIBUTE"
    stats = report.rule(code)
    stats["files"] = len(scan)
    writes, reads = {}, {}
    computed = []  # (rel, line, kind, fragment or None)
    fragments = {"prefix": set(), "suffix": set()}
    for scan_file in scan:
        constants = _string_constants(scan_file)
        tokens = scan_file.tokens
        for index, (kind, value, line) in enumerate(tokens):
            if kind != "name" or (value not in ATTR_WRITERS and value not in ATTR_READERS):
                continue
            if index == 0 or tokens[index - 1][1] not in (":", "."):
                continue
            if index + 2 >= len(tokens) or tokens[index + 1][1] != "(":
                continue
            stats["candidates"] += 1
            side = writes if value in ATTR_WRITERS else reads
            first = tokens[index + 2]
            after = tokens[index + 3] if index + 3 < len(tokens) else None
            if first[0] == "str" and after is not None and after[1] == "..":
                fragments["prefix"].add(_string_content(first[1]))
                computed.append((scan_file.rel, line, value, _string_content(first[1]) + ".."))
                continue
            if first[0] == "str" and after is not None and after[1] in (",", ")"):
                side.setdefault(_string_content(first[1]), []).append((scan_file.rel, line, scan_file.is_game))
                continue
            if first[0] == "name" and first[1] in constants and after is not None and after[1] in (",", ")"):
                side.setdefault(constants[first[1]], []).append((scan_file.rel, line, scan_file.is_game))
                continue
            # A name built at run time. Record any literal fragment in the expression so a literal
            # name that could be its output is not reported as unread.
            close = _matching_close(tokens, index + 1)
            end = close if close is not None else index + 2
            for j in range(index + 2, end):
                if tokens[j][0] == "str" and tokens[j][1] not in ("''", '""'):
                    text = _string_content(tokens[j][1])
                    if tokens[j - 1][1] == "..":
                        fragments["suffix"].add(text)
                    else:
                        fragments["prefix"].add(text)
            computed.append((scan_file.rel, line, value, None))

    def concatenation_touched(name):
        for prefix in fragments["prefix"]:
            if prefix and (name.startswith(prefix) or prefix.startswith(name)):
                return prefix
        for suffix in fragments["suffix"]:
            if suffix and (name.endswith(suffix) or suffix.endswith(name)):
                return suffix
        return None

    demoted, tools_only = [], []
    for name, sites in sorted(writes.items()):
        if name in reads:
            if not any(is_game for _, _, is_game in reads[name]):
                tools_only.append(name)
            continue
        game_sites = [(rel, line) for rel, line, is_game in sites if is_game]
        if not game_sites:
            continue
        touched = concatenation_touched(name)
        if touched:
            demoted.append(f"{name} (shares text with a concatenated name `{touched}`)")
            continue
        rel, line = game_sites[0]
        if rel in targets:
            report.flag(code, rel, line, name,
                        f"attribute written at {len(sites)} site(s) and never read: no "
                        f"GetAttribute(\"{name}\") or GetAttributeChangedSignal(\"{name}\") anywhere")
    for name, sites in sorted(reads.items()):
        if name in writes:
            continue
        game_sites = [(rel, line) for rel, line, is_game in sites if is_game]
        if not game_sites:
            continue
        touched = concatenation_touched(name)
        if touched:
            demoted.append(f"{name} (read-only; shares text with a concatenated name `{touched}`)")
            continue
        rel, line = game_sites[0]
        if rel in targets:
            report.flag(code, rel, line, name,
                        f"attribute read at {len(sites)} site(s) and never written by any Lua here "
                        f"— either dead or it comes from the place file")
    if computed:
        report.note(code, f"{len(computed)} attribute name(s) built at run time, reported separately and "
                          f"NOT flagged: " + ", ".join(sorted({f"{rel}:{line}" for rel, line, _, _ in computed})[:10]))
    if demoted:
        report.note(code, f"{len(demoted)} name(s) held back from the findings because a concatenated "
                          f"name could produce or consume them: " + "; ".join(sorted(demoted)))
    if tools_only:
        report.note(code, f"{len(tools_only)} attribute(s) whose only reader is a tools/ probe — written "
                          f"by the game, read by nothing the players run: " + ", ".join(sorted(tools_only)))


# --- P4: a weak-keyed table holding state, and the property-cache version -------------------------
# Weak-keyed tables drop live Instances, so one holding STATE loses it silently. The sharper version:
# a weak table whose VALUE was read off a property the same module later WRITES. A lamp cache
# captured a part's original colour, the consumer overwrote that colour, and every rebuild re-primed
# from the already-dimmed value — headlights fading permanently towards black.
#
# The property half is EXACT about what it matched (a property read into a weak table, and a write to
# that same property in the same file). Whether a given weak table is a cache or state is not
# decidable here, so every weak table found is listed as a note for review instead.

WRITABLE_PROPS = ("Color", "Size", "CFrame", "Transparency", "Position", "Material", "Orientation",
                  "BrickColor", "Reflectance", "Rotation", "Anchored", "Massless", "Texture")


def pattern_weak_tables(scan, report, targets):
    code = "WEAK_TABLE"
    stats = report.rule(code)
    stats["files"] = len(scan)
    for scan_file in scan:
        tokens = scan_file.tokens
        weak = {}  # table name -> line
        for index, (kind, value, line) in enumerate(tokens):
            if kind != "name" or value != "__mode":
                continue
            if not (index + 2 < len(tokens) and tokens[index + 1][1] == "=" and tokens[index + 2][0] == "str"):
                continue
            if "k" not in _string_content(tokens[index + 2][1]):
                continue
            stats["candidates"] += 1
            name = None
            for j in range(index, max(-1, index - 12), -1):
                if tokens[j][1] == "=" and j >= 1 and tokens[j - 1][0] == "name":
                    name = tokens[j - 1][1]
                    break
            weak[name or f"<line {line}>"] = line
            report.note(code, f"{scan_file.rel}:{line}: weak-keyed table `{name or '?'}` — a cache is "
                              f"fine here, state is not; the collector takes entries for live "
                              f"Instances")
        if not weak:
            continue
        written_props = set()
        for index in range(len(tokens) - 2):
            if tokens[index][1] == "." and tokens[index + 1][1] in WRITABLE_PROPS and tokens[index + 2][1] == "=":
                written_props.add(tokens[index + 1][1])
        if not written_props:
            continue
        for name, declared in weak.items():
            if name.startswith("<line "):
                continue
            for index, (kind, value, line) in enumerate(tokens):
                if kind != "name" or value != name or index + 1 >= len(tokens) or tokens[index + 1][1] != "[":
                    continue
                close = _matching_close(tokens, index + 1)
                if close is None or close + 1 >= len(tokens) or tokens[close + 1][1] != "=":
                    continue
                end = _statement_end(tokens, close + 2)
                for j in range(close + 2, end):
                    if tokens[j][1] == "." and j + 1 < end and tokens[j + 1][1] in written_props:
                        prop = tokens[j + 1][1]
                        if scan_file.rel in targets:
                            report.flag(code, scan_file.rel, line, name,
                                        f"weak table primed from `.{prop}`, a property this file also "
                                        f"writes (line {declared} declares it) — a rebuild re-primes "
                                        f"from the already-changed value")
                        break
                else:
                    continue
                break


# --- P5: an ignored return value -------------------------------------------------------------------
# WeaponService.GiveWeapon returns a third value naming the weapon it displaced; three callers
# ignored it and one silently deleted the player's held gun.
#
# HEURISTIC. Lua truncates return values as a matter of course, so "returns 3, captures 1" is not by
# itself a bug and flagging it produces hundreds of findings. What is flagged is DISAGREEMENT: a
# function whose callers capture different numbers of values, which is the shape above — somebody
# needed the extra value and somebody else did not know it existed. Sites capturing fewer than the
# definition's arity with no disagreeing sibling are counted as candidates, not flagged.
#
# One part of it IS exact and is flagged on its own: a caller capturing MORE values than the function
# can return has a target that is always nil.
#
# Name resolution follows Lua's scoping, which is most of what keeps this rule usable, and two
# versions of it were wrong before this one:
#   - A single-name definition (`local function travel`) is file-local, so only calls in the SAME
#     FILE resolve to it. Without that, one `travel` helper in Ballistics.lua matched a different
#     `travel` in five other files and the rule produced 60 findings, none about the same function.
#   - A call is NEVER resolved by its last segment alone. `PlayerData.Get(giver)` matched
#     `StatusEffects.Get` on the strength of the word "Get", which invented a caller that needed
#     two values and put 48 innocent call sites on the list behind it. Only `self:Method()` falls
#     back, because there the qualifier is a variable and the method is the only name there is.
# The disagreeing caller must also be in game code: "a tools/ probe captures three" is not evidence
# about what the game needs.

def _return_arity(tokens, index):
    """tokens[index] is a `return`. Returns (arity, known)."""
    end = _statement_end(tokens, index + 1)
    if end <= index + 1:
        return 0, True
    depth = 0
    commas = []
    for j in range(index + 1, end):
        kind, value, _ = tokens[j]
        if kind == "op" and value in ("(", "[", "{"):
            depth += 1
        elif kind == "op" and value in (")", "]", "}"):
            depth -= 1
        elif kind == "op" and value == "," and depth == 0:
            commas.append(j)
    last_start = (commas[-1] + 1) if commas else (index + 1)
    tail = tokens[last_start:end]
    known = True
    if tail:
        if tail[-1][1] == "...":
            known = False
        elif tail[-1][1] == ")":
            # A call in the tail position expands to any number of values.
            depth = 0
            for j in range(end - 1, last_start - 1, -1):
                value = tokens[j][1]
                if value in (")", "]", "}"):
                    depth += 1
                elif value in ("(", "[", "{"):
                    depth -= 1
                    if depth == 0:
                        before = tokens[j - 1] if j >= 1 else None
                        if before is not None and (before[0] in ("name", "str") or before[1] in (")", "]", "}")):
                            known = False
                        break
    return len(commas) + 1, known


def _capture_count(tokens, start, call_open):
    """How many values the call whose chain starts at `start` has captured. None = a context this
    pass will not claim to understand (an argument, an operand, a table field)."""
    before = tokens[start - 1] if start >= 1 else None
    close = _matching_close(tokens, call_open)
    if before is not None and before[0] == "op" and before[1] == "=":
        # Count the assignment targets to the left of the '='.
        equals = start - 1
        depth = 0
        targets = 1
        j = equals - 1
        while j >= 0:
            kind, value, line = tokens[j]
            right = tokens[j + 1]
            # Stop at the start of the statement. Without this the walk ran back over earlier lines
            # and counted THEIR commas: `allowed, sent = stream(...)` read as five targets, and the
            # exact half of this rule reported "the extra targets are always nil" about a call that
            # captured exactly what it should.
            if depth == 0 and line < right[2] and value not in CONTINUES_PREV \
                    and right[1] not in CONTINUES_NEXT:
                break
            if kind == "op" and value in (")", "]", "}"):
                depth += 1
            elif kind == "op" and value in ("(", "[", "{"):
                depth -= 1
                if depth < 0:
                    return None  # inside a bracket: a table field or an argument, not an assignment
            elif depth == 0:
                if kind == "op" and value == ",":
                    targets += 1
                elif kind == "kw" and value == "local":
                    break
                elif kind == "op" and value == ";":
                    break
                elif kind == "kw" and value in ("end", "then", "do", "else", "elseif", "return", "until"):
                    break
                elif kind == "op" and value in ("==", "~=", "<", "<=", ">", ">=", "+", "-", "*", "/"):
                    return None
            j -= 1
        return targets
    starts_statement = before is None or (
        before[0] == "kw" and before[1] in ("then", "do", "else", "end", "repeat", "until")) or (
        before[0] == "op" and before[1] == ";") or (
        before[2] < tokens[start][2] and before[1] not in CONTINUES_PREV)
    if starts_statement and close is not None:
        after = tokens[close + 1] if close + 1 < len(tokens) else None
        if after is None or after[1] == ";" or after[2] > tokens[close][2] or (
                after[0] == "kw" and after[1] in ("end", "else", "elseif", "until", "return")):
            return 0
    return None


def pattern_ignored_return(scan, report, targets):
    code = "RETURN_IGNORED"
    stats = report.rule(code)
    stats["files"] = len(scan)
    definitions = {}  # key -> {rel, line, arity, known, name}; key is "M.f" or "<rel>::f" (file-local)
    for scan_file in scan:
        tokens = scan_file.tokens
        frames = function_frames(tokens)
        for frame in frames:
            if not frame["name"]:
                continue
            arity, known = 0, True
            for index in range(frame["body"], frame["end"]):
                if tokens[index][0] != "kw" or tokens[index][1] != "return":
                    continue
                if _owning_frame(frames, index) is not frame:
                    continue
                count, ok = _return_arity(tokens, index)
                arity = max(arity, count)
                known = known and ok
            if arity < 2:
                continue
            qualified = "." in frame["name"]
            key = frame["name"] if qualified else f"{scan_file.rel}::{frame['name']}"
            earlier = definitions.get(key)
            if earlier is None:
                definitions[key] = {"rel": scan_file.rel, "line": frame["line"], "arity": arity,
                                    "known": known, "name": frame["name"], "qualified": qualified,
                                    "definitions": 1}
            else:
                # This project fills seams by assignment: `LobbyService.OnDailySpin` is a 2-value
                # stub in its own module and a 3-value implementation in Bootstrap, and whichever
                # was read last used to win. Take the widest arity, and stop making the exact
                # "always nil" claim about a name that is defined more than once.
                earlier["definitions"] += 1
                if arity > earlier["arity"]:
                    earlier.update({"rel": scan_file.rel, "line": frame["line"], "arity": arity})
                earlier["known"] = earlier["known"] and known
    by_short = {}
    for key, definition in definitions.items():
        if definition["qualified"]:
            by_short.setdefault(_last_segment(definition["name"]), []).append(key)
    call_sites = {}  # definition key -> [(rel, line, captured, is_game)]
    for scan_file in scan:
        tokens = scan_file.tokens
        for index, (kind, value, line) in enumerate(tokens):
            if kind != "name" or index + 1 >= len(tokens) or tokens[index + 1][1] != "(":
                continue
            parts, start = _dotted_before(tokens, index)
            resolved = None
            if len(parts) == 1:
                # A bare name is a local or a global: only this file's definition can be it.
                local_key = f"{scan_file.rel}::{parts[0]}"
                resolved = local_key if local_key in definitions else None
            else:
                dotted = ".".join(parts)
                if dotted in definitions:
                    resolved = dotted
                elif parts[0] == "self" and len(parts) == 2:
                    candidates = by_short.get(parts[-1], [])
                    resolved = candidates[0] if len(candidates) == 1 else None
            if resolved is None:
                continue
            stats["candidates"] += 1
            captured = _capture_count(tokens, start, index + 1)
            if captured is None:
                continue
            call_sites.setdefault(resolved, []).append((scan_file.rel, line, captured, scan_file.is_game))
    probe_sites = [0]
    probe_files = set()
    for key, sites in sorted(call_sites.items()):
        definition = definitions[key]
        if not definition["known"]:
            continue
        name = definition["name"]
        arity = definition["arity"]
        # Exact half: a target that can never be filled. Only where the name has ONE definition,
        # because a seam's arity is whatever the widest of its implementations returns.
        for rel, line, captured, _ in sites if definition["definitions"] == 1 else []:
            if captured > arity and rel in targets:
                report.flag(code, rel, line, name,
                            f"captures {captured} values from `{name}`, which returns at most "
                            f"{arity} ({definition['rel']}:{definition['line']}) — the extra "
                            f"target(s) are always nil")
        usable = [(rel, line, captured, is_game) for rel, line, captured, is_game in sites
                  if captured <= arity]
        game_counts = [captured for _, _, captured, is_game in usable if is_game]
        if not game_counts or len({captured for _, _, captured, _ in usable}) < 2:
            continue
        best = max(game_counts)
        user = next((f"{rel}:{line}" for rel, line, captured, is_game in usable
                     if is_game and captured == best), None)
        if user is None:
            continue
        # One finding per FILE per function. And only for GAME code: a gallery or probe deliberately
        # taking one value out of three is not a bug, and 400 probe sites is how a linter gets
        # turned off. The probe count goes in a note instead.
        short_callers = {}
        for rel, line, captured, is_game in usable:
            if captured >= best:
                continue
            if is_game:
                short_callers.setdefault(rel, []).append((line, captured))
            else:
                probe_sites[0] += 1
                probe_files.add(rel)
        for rel, hits in sorted(short_callers.items()):
            if rel not in targets:
                continue
            lines = ", ".join(str(line) for line, _ in hits[:8])
            if len(hits) > 8:
                lines += f", +{len(hits) - 8} more"
            report.flag(code, rel, hits[0][0], name,
                        f"captures {hits[0][1]} of the {arity} value(s) `{name}` returns "
                        f"({definition['rel']}:{definition['line']}) at {len(hits)} site(s) "
                        f"(lines {lines}), while {user} captures {best} — the callers disagree "
                        f"about what it returns")
    if probe_sites[0]:
        report.note(code, f"{probe_sites[0]} short call(s) in {len(probe_files)} tools/ file(s) — not "
                          f"flagged: a probe or gallery taking one value out of three is a choice, "
                          f"not an oversight")


# --- P6: a handler slot filled with nil at construction --------------------------------------------
# The menu's X button hovered and depressed and was connected to nothing: the constructor read
# `options.onClose` at build time and its caller's table did not carry that key. Nothing errors —
# the button is simply inert, which is the worst kind of bug to find by eye.
#
# HEURISTIC, but a narrow one: it only looks at callers that build the options table INLINE, where
# the keys are visible. A caller passing a variable is counted as a candidate and not flagged. A
# constructor that defaults the field (`options.onClose or noop`) or tests it is not a finding.

BAG_PARAM = {"options", "opts", "props", "config", "conf", "spec", "def", "definition", "params", "info"}
HANDLER_FIELD = re.compile(
    r"^(on[A-Z]\w*|\w*(Callback|Handler|Activated|Clicked|Pressed|Toggled|Selected)|callback|handler)$")
HANDLER_GUARD_BEFORE = {"if", "elseif", "while", "not", "and", "or", "assert", "return"}
HANDLER_GUARD_AFTER = {"or", "and", "==", "~="}


def pattern_nil_handler(scan, report, targets):
    code = "NIL_HANDLER"
    stats = report.rule(code)
    stats["files"] = len(scan)
    wanted = {}  # definition name -> {rel, line, fields: {field: guarded}}
    for scan_file in scan:
        tokens = scan_file.tokens
        for frame in function_frames(tokens):
            if not frame["name"]:
                continue
            bags = [param for param in frame["params"] if param in BAG_PARAM]
            if not bags:
                continue
            fields = {}
            for index in range(frame["body"], frame["end"] - 2):
                if tokens[index][0] != "name" or tokens[index][1] not in bags:
                    continue
                if tokens[index + 1][1] != "." or tokens[index + 2][0] != "name":
                    continue
                field = tokens[index + 2][1]
                if not HANDLER_FIELD.match(field):
                    continue
                stats["candidates"] += 1
                before = tokens[index - 1][1] if index >= 1 else None
                after = tokens[index + 3][1] if index + 3 < len(tokens) else None
                guarded = before in HANDLER_GUARD_BEFORE or after in HANDLER_GUARD_AFTER
                fields[field] = fields.get(field, False) or guarded
            unguarded = sorted(field for field, guarded in fields.items() if not guarded)
            if unguarded:
                wanted[frame["name"]] = {"rel": scan_file.rel, "line": frame["line"], "fields": unguarded}
    if not wanted:
        return
    probe_sites = 0
    probe_files = set()
    by_short = {}
    for name in wanted:
        by_short.setdefault(_last_segment(name), []).append(name)
    for scan_file in scan:
        tokens = scan_file.tokens
        # Fields this file fills in AFTER construction. MenuClient does exactly that on purpose and
        # says why at MenuShell.lua:92 — the shell reads `self.onBack` at click time, so assigning it
        # later works. Without this the deliberate idiom reads as three nil handlers.
        assigned_later = {tokens[i + 1][1] for i in range(len(tokens) - 2)
                          if tokens[i][1] == "." and tokens[i + 1][0] == "name"
                          and tokens[i + 2][1] == "=" and tokens[i + 2][0] == "op"}
        for index, (kind, value, line) in enumerate(tokens):
            if kind != "name" or index + 1 >= len(tokens) or tokens[index + 1][1] not in ("(", "{"):
                continue
            parts, _ = _dotted_before(tokens, index)
            dotted = ".".join(parts)
            resolved = dotted if dotted in wanted else None
            if resolved is None:
                candidates = by_short.get(parts[-1], [])
                resolved = candidates[0] if len(candidates) == 1 else None
            if resolved is None:
                continue
            if wanted[resolved]["rel"] == scan_file.rel and abs(wanted[resolved]["line"] - line) < 1:
                continue
            close = _matching_close(tokens, index + 1)
            if close is None:
                continue
            # The last top-level table literal in the argument list is the options bag.
            depth = 0
            brace = None
            for j in range(index + 1, close):
                if tokens[j][0] != "op":
                    continue
                if tokens[j][1] in ("(", "["):
                    depth += 1
                elif tokens[j][1] in (")", "]"):
                    depth -= 1
                elif tokens[j][1] == "{" and depth == 1:
                    brace = j
                    break
                elif tokens[j][1] == "{" and depth == 0 and tokens[index + 1][1] == "{":
                    brace = j
                    break
            stats["candidates"] += 1
            if brace is None:
                continue
            brace_close = _matching_close(tokens, brace)
            if brace_close is None:
                continue
            keys = set()
            depth = 0
            for j in range(brace + 1, brace_close):
                if tokens[j][0] == "op" and tokens[j][1] in ("(", "[", "{"):
                    depth += 1
                elif tokens[j][0] == "op" and tokens[j][1] in (")", "]", "}"):
                    depth -= 1
                elif depth == 0 and tokens[j][0] == "name" and tokens[j + 1][1] == "=" \
                        and tokens[j - 1][1] in ("{", ",", ";"):
                    keys.add(tokens[j][1])
            missing = [field for field in wanted[resolved]["fields"]
                       if field not in keys and field not in assigned_later]
            if not missing:
                continue
            if not scan_file.is_game:
                # A gallery builds widgets to photograph, not to click. Counted, not flagged.
                probe_sites += 1
                probe_files.add(scan_file.rel)
                continue
            if scan_file.rel in targets:
                report.flag(code, scan_file.rel, line, resolved,
                            f"builds the options table inline without {', '.join(missing)}, which "
                            f"{wanted[resolved]['rel']}:{wanted[resolved]['line']} uses as a handler "
                            f"and does not default — the slot is nil at construction")
    if probe_sites:
        report.note(code, f"{probe_sites} inline options table(s) in {len(probe_files)} tools/ file(s) "
                          f"missing a handler field — not flagged: a gallery builds widgets to "
                          f"photograph, not to click")


# --- P7: a stale copy of a number defined elsewhere ------------------------------------------------
# A mode said "first to 50" while its scoreTarget said 100, a few lines apart in the same table,
# because a change to the number never reached the sentence. tools/verify.py:1139 has a narrow
# version of this (GameModes.lua, `description` against `scoreTarget`); this generalises it to every
# swept file, every description-shaped key, and any numeric field in the same table constructor.
#
# HEURISTIC, and read the claim carefully because it is weaker than "these two numbers disagree".
# What it reports is: this sentence quotes a quantity that agrees with NO number beside it, so
# nothing keeps the two in step. That is checkable; "the sentence means this field" is not. It has to
# be the weaker claim because a description may legitimately quote a second number ("rank score =
# prestige x 100 + rank") and requiring EVERY number to match flags all of those. The recorded fix
# for this pattern is the same either way: do not copy a number into prose, compose the prose from
# the number. Expect some findings to be flavour text — that is what triage is for.
#
# A sentence containing a number written as a WORD is reported INCONCLUSIVE, not clean and not
# flagged: "top 10 fifty times" cannot be compared with 50 by any amount of regex.
#
# Note on input: this rule is why the whole stage runs off tokenize(). verify.py's _strip_lua
# replaces every string literal with an empty one, so a check on what a string SAYS reads "" and
# passes forever. tokenize() drops comments and keeps strings.

DESCRIPTION_KEYS = {"description", "desc", "blurb", "summary", "detail", "details", "tooltip", "hint",
                    "tagline", "subtitle", "caption", "flavour", "flavor", "note", "body"}
# A number spelled as a word, and what it is worth. A description is only INCONCLUSIVE when one of
# its words could BE a number beside it: "top 10 fifty times" next to target=50 is a sentence this
# rule cannot read, but "First to 50" next to scoreTarget=100 is the bug it exists for, and an
# earlier version suppressed it because "first" was on the list at all.
NUMBER_WORDS = {
    "a": 1, "an": 1, "one": 1, "once": 1, "single": 1, "first": 1,
    "two": 2, "twice": 2, "double": 2, "second": 2, "pair": 2,
    "three": 3, "thrice": 3, "triple": 3, "third": 3,
    "four": 4, "fourth": 4, "five": 5, "fifth": 5, "six": 6, "sixth": 6, "seven": 7, "seventh": 7,
    "eight": 8, "eighth": 8, "nine": 9, "ninth": 9, "ten": 10, "tenth": 10, "eleven": 11,
    "twelve": 12, "dozen": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
    "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    "hundred": 100, "thousand": 1000, "million": 1000000, "half": 0.5,
}
NUMBER_WORD = re.compile(r"\b(" + "|".join(sorted(NUMBER_WORDS)) + r")\b", re.I)
STRING_NUMBER = re.compile(r"(?<![\w.])(\d(?:[\d,]*\d)?(?:\.\d+)?)")


def _table_frames(tokens):
    """Every table constructor in a file, with its own scalar `key = <number>` and `key = "string"`
    fields. A field belongs to the innermost constructor it is written in, and each frame keeps its
    nested ones: a crate's `description = "3% Secret"` sits beside `odds = { Secret = 3 }`, so a rule
    that only looked at one level reported drift against a number written two lines below it."""
    stack = []
    done = []
    for index, (kind, value, line) in enumerate(tokens):
        if kind == "op" and value == "{":
            frame = {"numbers": {}, "strings": {}, "line": line, "children": []}
            if stack:
                stack[-1]["children"].append(frame)
            stack.append(frame)
            continue
        if kind == "op" and value == "}":
            if stack:
                done.append(stack.pop())
            continue
        if not stack or kind != "name":
            continue
        if index + 2 >= len(tokens) or tokens[index + 1][1] != "=" or tokens[index + 1][0] != "op":
            continue
        if index == 0 or tokens[index - 1][1] not in ("{", ",", ";"):
            continue
        j = index + 2
        negative = tokens[j][1] == "-"
        if negative:
            j += 1
        if j + 1 >= len(tokens):
            continue
        terminator = tokens[j + 1][1]
        if terminator not in (",", ";", "}"):
            continue  # an expression, a call or a nested constructor: not a scalar this rule can use
        if tokens[j][0] == "num":
            try:
                number = float(tokens[j][1].replace("_", ""))
            except ValueError:
                continue
            stack[-1]["numbers"][value] = (-number if negative else number, tokens[j][2])
        elif tokens[j][0] == "str" and not negative:
            stack[-1]["strings"][value] = (_string_content(tokens[j][1]), tokens[j][2])
    return done + stack


def _nested_numbers(frame):
    values = set()
    for child in frame["children"]:
        values |= {value for value, _ in child["numbers"].values()}
        values |= _nested_numbers(child)
    return values


def pattern_number_drift(scan, report, targets):
    code = "NUMBER_DRIFT"
    stats = report.rule(code)
    stats["files"] = len(scan)
    inconclusive = 0
    for scan_file in scan:
        for frame in _table_frames(scan_file.tokens):
            if not frame["numbers"]:
                continue
            own = {value for value, _ in frame["numbers"].values()}
            nested = _nested_numbers(frame)
            siblings = own | nested
            for key, (content, line) in sorted(frame["strings"].items()):
                if key.lower() not in DESCRIPTION_KEYS:
                    continue
                found = STRING_NUMBER.findall(content)
                if not found:
                    continue
                stats["candidates"] += 1
                spelled = {NUMBER_WORDS[word.lower()] for word in NUMBER_WORD.findall(content)}
                if spelled & siblings:
                    inconclusive += 1
                    continue
                numbers = []
                for text in found:
                    try:
                        numbers.append(float(text.replace(",", "")))
                    except ValueError:
                        pass
                if not numbers or any(number in siblings for number in numbers):
                    continue
                if scan_file.rel not in targets:
                    continue
                quoted = ", ".join(text for text in found)
                beside = ", ".join(f"{name}={_pretty_number(value)}"
                                   for name, (value, _) in sorted(frame["numbers"].items()))
                if nested:
                    shown = ", ".join(_pretty_number(value) for value in sorted(nested)[:8])
                    beside += f"; nested: {shown}"
                report.flag(code, scan_file.rel, line, key,
                            f"`{key}` quotes {quoted} and no number beside it agrees ({beside}) — a "
                            f"quantity hard-coded in prose that nothing keeps in step; compose the "
                            f"sentence from the number instead of copying it")
    if inconclusive:
        report.note(code, f"{inconclusive} description(s) INCONCLUSIVE, not clean and not flagged: they "
                          f"spell a number as a word, which cannot be compared with a numeric field")


def _pretty_number(value):
    return str(int(value)) if value == int(value) else str(value)


# --- the rule table -------------------------------------------------------------------------------
# code, one-line title, EXACT or HEURISTIC, the function, and the fixture pair that must and must not
# fire. The fixtures are the permanent planted faults: see run_pattern_self_test.

PATTERN_RULES = [
    ("CLOCK_WALL_TIME", "os.clock used as wall time", "EXACT", pattern_os_clock,
     "p1_clock_bad", "p1_clock_good"),
    ("ATTRIBUTE", "an attribute written and never read, or read and never written", "HEURISTIC",
     pattern_attributes, "p2_attribute_bad", "p2_attribute_good"),
    ("WEAK_TABLE", "a weak-keyed table primed from a property the module writes", "EXACT",
     pattern_weak_tables, "p4_weak_bad", "p4_weak_good"),
    ("RETURN_IGNORED", "an ignored return value, where the callers disagree", "HEURISTIC",
     pattern_ignored_return, "p5_return_bad", "p5_return_good"),
    ("NIL_HANDLER", "a handler slot filled with nil at construction", "HEURISTIC",
     pattern_nil_handler, "p6_handler_bad", "p6_handler_good"),
    ("NUMBER_DRIFT", "a stale copy of a number defined elsewhere", "HEURISTIC",
     pattern_number_drift, "p7_number_bad", "p7_number_good"),
]


def run_patterns(scan, targets=None):
    """Run every rule over `scan` (all files, so the cross-file rules can see every reader), reporting
    findings only for `targets` (project-relative paths; None means all of them)."""
    if targets is None:
        targets = {scan_file.rel for scan_file in scan}
    report = PatternReport()
    for code, _, _, rule, _, _ in PATTERN_RULES:
        report.rule(code)
        rule(scan, report, targets)
    return report


def load_scan(root, paths):
    """Read and tokenize files. The one route every rule's input takes, fixtures included."""
    scan = []
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        scan.append(ScanFile(os.path.relpath(path, root), text))
    return scan


# --- the permanent planted faults ------------------------------------------------------------------
# Each rule owns two fixtures under tools/patterns/: `<name>_bad.lua.fixture` MUST be flagged and
# `<name>_good.lua.fixture` MUST NOT be. They run on every invocation and they gate the exit code,
# because a rule that has stopped firing is indistinguishable from a clean codebase.
#
# Each fixture is aimed at the rule's INVARIANT, not at the bug that prompted it. "The admin Fly
# attribute is still unread" would have died the moment somebody added the reader — and the reader
# has since been added, so that plant would now be silently proving nothing. "An attribute written
# and never read must be reported" cannot expire.
#
# The fixtures are named .lua.fixture rather than .lua on purpose: tools/balance.py globs **/*.lua
# from the project root and tools/verify.py walks every .lua under it, so a deliberately-wrong .lua
# file here would show up in two other people's checks. The extension keeps them out of those sweeps
# while they still travel this stage's own open() -> ScanFile -> rule route, which is the route real
# input takes (`lua_static_check.py . <path>` reads explicit paths the same way).

def pattern_fixture_paths(root):
    base = os.path.join(root, "tools", "patterns")
    if not os.path.isdir(base):
        return []
    return [os.path.join(base, name) for name in sorted(os.listdir(base)) if name.endswith(".lua.fixture")]


def run_pattern_self_test(root):
    """Returns (lines, problems). `problems` non-empty means this file is broken, not the project."""
    paths = pattern_fixture_paths(root)
    if not paths:
        return [], [f"pattern self-test: no fixtures found under {os.path.join(root, 'tools', 'patterns')} "
                    f"— every rule is unproven"]
    scan = load_scan(root, paths)
    report = run_patterns(scan)
    by_file = {}
    for rel, line, code, subject, note in report.findings:
        by_file.setdefault(rel, set()).add(code)
    problems = []
    fired = 0
    clean = 0
    for code, title, _, _, bad, good in PATTERN_RULES:
        bad_rel = f"tools/patterns/{bad}.lua.fixture"
        good_rel = f"tools/patterns/{good}.lua.fixture"
        if not any(path.endswith(f"{bad}.lua.fixture") for path in paths):
            problems.append(f"pattern self-test: {code} has no planted fault ({bad}.lua.fixture is missing)")
        elif code in by_file.get(bad_rel, ()):
            fired += 1
        else:
            problems.append(f"pattern self-test: {code} did NOT flag its planted fault "
                            f"({bad}.lua.fixture) — the rule is testing nothing")
        if not any(path.endswith(f"{good}.lua.fixture") for path in paths):
            problems.append(f"pattern self-test: {code} has no false-positive fixture "
                            f"({good}.lua.fixture is missing)")
        elif code in by_file.get(good_rel, ()):
            problems.append(f"pattern self-test: {code} flagged {good}.lua.fixture, which is correct code "
                            f"— it produces false positives")
        else:
            clean += 1
    total = len(PATTERN_RULES)
    lines = [f"pattern self-test: {fired}/{total} planted faults fired, {clean}/{total} correct "
             f"fixtures stayed clean ({len(paths)} fixture files)"]
    return lines, problems


def print_pattern_report(report, scan, self_test_lines):
    for rel, line, code, subject, note in sorted(report.findings, key=lambda f: (f[0], f[1])):
        print(f"{rel}:{line}: {code} {subject} ({note})")
    print("pattern rules (advisory — they do not set the exit code unless --patterns-strict):")
    for code, title, kind, _, _, _ in PATTERN_RULES:
        stats = report.stats.get(code, {"files": 0, "candidates": 0, "flagged": 0})
        print(f"  {code:<18} {kind:<9} files={stats['files']:<5} candidates={stats['candidates']:<6} "
              f"flagged={stats['flagged']:<4} {title}")
    if report.notes:
        print("pattern notes (looked at, deliberately not findings):")
        for code, text in report.notes:
            print(f"  {code}: {text}")
    for line in self_test_lines:
        print(line)
    candidates = sum(stats["candidates"] for stats in report.stats.values())
    print(f"lua pattern check: {len(scan)} files, {len(PATTERN_RULES)} rules, "
          f"{candidates} candidate sites, {len(report.findings)} findings")


def lua_files(root, only):
    if only:
        for path in only:
            yield path
        return
    for folder in ("ServerScriptService", "ReplicatedStorage", "StarterPlayerScripts", "StarterGui", "tools"):
        base = os.path.join(root, folder)
        for dirpath, _, files in os.walk(base):
            for name in sorted(files):
                if name.endswith(".lua") or name.endswith(".luau"):
                    yield os.path.join(dirpath, name)


def pattern_files(root):
    """The files the PATTERN stage sweeps: the set lua_files walks, minus the fixtures. The fixtures
    are .lua.fixture so they are already outside lua_files' filter; this keeps them out if anyone
    ever drops a plain .lua in there."""
    for path in lua_files(root, None):
        if os.path.join("tools", "patterns") in path:
            continue
        yield path


def main():
    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    flags = {arg for arg in sys.argv[1:] if arg.startswith("--")}
    root = args[0] if args else "."
    only = args[1:]
    unknown = flags - {"--no-patterns", "--patterns-only", "--patterns-strict"}
    if unknown:
        print(f"unknown option(s): {' '.join(sorted(unknown))}")
        print("usage: lua_static_check.py <root> [file...] [--no-patterns|--patterns-only] [--patterns-strict]")
        sys.exit(2)
    total = 0
    files = 0
    if "--patterns-only" in flags:
        return run_pattern_stage(root, only, flags, scope_findings=0, scope_files=0, scope_only=True)
    for path in lua_files(root, only):
        files += 1
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        rel = os.path.relpath(path, root)
        extra = PROBE_GLOBALS if rel.replace("\\", "/").startswith("tools/") else frozenset()
        try:
            findings = check_file(path, text, extra)
        except Exception as crash:  # a bug in the scope pass: say so, and still run the parser on the file
            print(f"{rel}: note: the scope check crashed ({type(crash).__name__}: {crash}); syntax only for this file")
            findings = []
        try:
            syntax = parse_syntax(text)
            findings = [f for f in findings if f[0] != "SYNTAX"]
            if syntax:
                findings.append(("SYNTAX", syntax[0], "parse", syntax[1]))
        except Exception as crash:  # a parser bug: keep the token rules' SYNTAX findings for this file
            print(f"{rel}: note: the syntax parser crashed ({type(crash).__name__}: {crash}); using token rules")
        findings.sort(key=lambda f: f[1])
        for kind, line, name, note in findings:
            print(f"{rel}:{line}: {kind} {name} ({note})")
            total += 1
    return run_pattern_stage(root, only, flags, scope_findings=total, scope_files=files)


def run_pattern_stage(root, only, flags, scope_findings, scope_files, scope_only=False):
    """The PATTERN stage, then the SCOPE/SYNTAX summary line — in that order, so the line HANDOFF.md
    tells everyone to paste verbatim (`lua static check: N files, M findings`) is still the last line
    of output. Pattern findings are advisory by default; what gates the exit code is the self-test,
    because a rule that has stopped firing is this file being broken."""
    problems = []
    pattern_findings = 0
    if "--no-patterns" not in flags:
        scan = load_scan(root, list(pattern_files(root)))
        targets = None
        if only:
            targets = {os.path.relpath(path, root).replace("\\", "/") for path in only}
        report = run_patterns(scan, targets)
        self_test_lines, problems = run_pattern_self_test(root)
        print_pattern_report(report, scan, self_test_lines)
        for problem in problems:
            print(problem)
        pattern_findings = len(report.findings)
    if not scope_only:
        print(f"lua static check: {scope_files} files, {scope_findings} findings")
    bad = scope_findings or problems or (pattern_findings and "--patterns-strict" in flags)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
