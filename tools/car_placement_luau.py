"""Luau -> plain Lua for the whole-map harness (tools/car_placement_check.py).

The other harnesses load one or two modules each and get by with destruct_map_check.luau_to_lua,
which only rewrites `name += value`. The whole map runs a dozen modules, and between them they use
three more pieces of Luau that plain Lua (lupa) lacks:
  * compound assignment onto an indexed target: `t[why or "node"] += 1`
  * compound assignment onto a call's field: `k:disc(...).CFrame *= r` (the call must run once)
  * `continue`, rewritten to a goto to a label at the end of the enclosing loop's body
"""

import re

OPS = r"(\+|-|\*|/|%|\^|\.\.|//)"
KEYWORDS = ("if ", "elseif ", "while ", "for ", "local ", "return ", "until ", "function ", "else", "then")


def _split_comment(line):
    """(code, comment): the comment starts at the first `--` outside a string."""
    quote = None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif line.startswith("--", i):
            return line[:i], line[i:]
        i += 1
    return line, ""


def _balanced(text):
    depth = 0
    quote = None
    for ch in text:
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0 and quote is None


def _lvalue(text):
    text = text.strip()
    if not text or not re.match(r"[A-Za-z_]", text) or text.startswith(KEYWORDS):
        return False
    if not _balanced(text):
        return False
    # Top-level spaces mean it's an expression, not a target (`a = b + c` must not match).
    depth, quote = 0, None
    for ch in text:
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == " " and depth == 0:
            return False
    return True


def _last_access(target):
    """Splits `obj.field` / `obj[key]` at the last top-level access: (obj, accessor text)."""
    depth, quote = 0, None
    cut = None
    for i, ch in enumerate(target):
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
        elif ch in "([{":
            if depth == 0 and ch == "[":
                cut = i
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "." and depth == 0:
            cut = i
    return (target[:cut], target[cut:]) if cut else (None, None)


COMPOUND = re.compile(r"^(\s*)(.+?)\s*" + OPS + r"=(?!=)\s*(.+?)\s*$")
INLINE = re.compile(r"\b([A-Za-z_][\w.]*) (\+|-)= ([\w.]+)\b")


def _compound(code):
    m = COMPOUND.match(code)
    if not m:
        return None
    indent, target, op, value = m.groups()
    if not _lvalue(target):
        return None
    if op == "//":
        op, wrap = "/", True
    else:
        wrap = False
    if "(" in target:
        obj, access = _last_access(target)
        if obj:
            rhs = "__o%s %s (%s)" % (access, op, value)
            if wrap:
                rhs = "math.floor(%s)" % rhs
            return "%sdo local __o = %s; __o%s = %s end" % (indent, obj, access, rhs)
    rhs = "%s %s (%s)" % (target, op, value)
    if wrap:
        rhs = "math.floor(%s)" % rhs
    return "%s%s = %s" % (indent, target, rhs)


def _indent(line):
    return len(line) - len(line.lstrip("\t"))


def _continues(lines):
    """`continue` -> `goto __continue_N`, with the label just before the enclosing loop's `end`."""
    labels = {}
    count = 0
    for i, line in enumerate(lines):
        code, _ = _split_comment(line)
        if not re.search(r"\bcontinue\b", code):
            continue
        level = _indent(line)
        header = None
        for j in range(i - 1, -1, -1):
            text = lines[j].strip()
            if not text or text.startswith("--"):
                continue
            if _indent(lines[j]) < level:
                level = _indent(lines[j])
                if re.match(r"(for|while)\b", text):
                    header = j
                    break
        if header is None:
            raise ValueError("continue with no loop at line %d" % (i + 1))
        loop_indent = _indent(lines[header])
        close = next(k for k in range(i + 1, len(lines))
                     if _indent(lines[k]) == loop_indent and lines[k].strip().startswith("end"))
        count += 1
        name = labels.setdefault(close, "__continue_%d" % count)
        lines[i] = re.sub(r"\bcontinue\b", "goto " + name, line)
    for close in sorted(labels, reverse=True):
        lines.insert(close, "\t" * (_indent(lines[close]) + 1) + "::%s::" % labels[close])
    return lines


def luau_to_lua(source):
    out = []
    for line in source.split("\n"):
        code, comment = _split_comment(line)
        converted = _compound(code)
        if converted is None:
            converted = INLINE.sub(lambda m: "%s = %s %s %s" % (m.group(1), m.group(1), m.group(2), m.group(3)), code)
        out.append(converted + comment)
    return "\n".join(_continues(out))
