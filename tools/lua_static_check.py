"""Static scope check for the Luau sources: catches names that will read as nil at run time.

Usage:  python tools/lua_static_check.py .            (whole tree; exit 1 if anything is found)
        Only the FIRST syntax error in a file is reported: fix it and run again to see the next.
        python tools/lua_static_check.py . path.lua   (just those files)

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


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    only = sys.argv[2:]
    total = 0
    files = 0
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
    print(f"lua static check: {files} files, {total} findings")
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
