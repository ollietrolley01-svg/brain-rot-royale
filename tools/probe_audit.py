"""Audit the harness's own checks for ones that cannot fail. Usage: python probe_audit.py <project>

This project's probes have repeatedly printed green while proving nothing: a filter that matched
nothing, a pattern that could not parse the site carrying the bug, a sample that excluded the case
the check existed to catch. This sweeps for the machine-decidable half of that.

Three detectors, and the honest limits of each:

  ALWAYS TRUE    a Lua check whose condition no game state can falsify. Exact, no judgement.
  UNGUARDED      a Lua check that only runs inside a loop over a collection, where nothing in the
                 file fails when that collection is empty. An empty filter prints a clean sweep.
                 Reported as a site to read, not a verdict -- some sweeps are guarded by a count
                 line this cannot see.
  NEVER MATCHED  a regex site in a Python checker that matched nothing during a full run over the
                 real project. Not a heuristic: the checker is actually executed and every re call
                 it makes is counted. Two very different things land here and only reading tells
                 them apart -- a parser that cannot read its input (the failure this audit exists
                 for), and a detector for something the project is currently clean of (healthy).
                 The tool reports the site with the size of the haystack it was handed, which is
                 what tells the two apart: a detector searching 0 bytes is dead whatever it looks
                 for. PROBE_AUDIT.md says which each one is.

What it cannot decide, and what the written audit in PROBE_AUDIT.md covers instead: whether a
stand-in body matches the real one, and whether a planted fault has expired. Both need the real
code read beside the probe.

Every run ends with a self-test, and it gates the exit code: each detector owns a `_bad` fixture
under tools/probe_audit_fixtures/ that MUST be flagged and a `_good` fixture that must NOT be. A
detector that has stopped firing is indistinguishable from a clean harness, which is the exact
failure this whole audit is about, so the detectors are not allowed to be the unaudited part.

The plants are aimed at each detector's INVARIANT -- "a condition no state can falsify must be
reported" -- not at any check in tools/ today, so they cannot expire when a probe is fixed. They
travel the same route real input does: the Lua fixtures go through the same check_sites() scan and
the Python fixture is run as a subprocess by the same trace_child().

Fixtures are named .lua.fixture and .py.fixture, not .lua and .py, for the reason tools/patterns/
gives: balance.py globs **/*.lua and verify.py walks every .lua under the root, so a deliberately
wrong .lua here would land in two other people's checks.
"""
import json
import os
import re
import subprocess
import sys

# Checkers that only read. The two generators (menu_hud_audit.py, brainrot_asset_audit.py) and the
# three builders write files into the tree, so they are read by hand rather than executed here.
TRACEABLE = [
    "verify.py",
    "balance.py",
    "lua_static_check.py",
    "achievement_check.py",
    "keybind_check.py",
    "weapon_stats.py",
    "progression_model.py",
]

# The harness's assertion vocabulary. Every file defines its own local helper; these are the names
# in use across tools/*.lua, found by reading all 162 of them.
CHECK_NAMES = ("check", "expect", "assert", "require_", "mustBe", "want", "verify")

# ---------------------------------------------------------------------------
# Lua: pull out every check site and the condition it turns on
# ---------------------------------------------------------------------------

CALL = re.compile(r"\b(" + "|".join(CHECK_NAMES) + r")([A-Za-z_]*)\s*\(")
HELPER_DEF = re.compile(r"local function (\w+)\s*\(([^)]*)\)")
# The parameter a helper turns on. Signatures in tools/ are (ok, fmt, ...), (label, ok, detail) and
# (name, ok, detail), so the condition is not always the first argument and guessing costs accuracy.
CONDITION_PARAMS = {"ok", "cond", "condition", "passed", "pass", "good", "result", "isok", "valid"}


def strip_lua_comments(src):
    """Blank out comments and string bodies, keeping every byte offset and newline in place."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        m = re.match(r"--\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i)
            j = n if j < 0 else j + len(close)
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
            continue
        if src.startswith("--", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if src[i] in "\"'":
            quote, j = src[i], i + 1
            while j < n and src[j] != quote:
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            for k in range(i + 1, j - 1):
                if out[k] != "\n":
                    out[k] = "."          # keep it a string, lose its content
            i = j
            continue
        i += 1
    return "".join(out)


def first_argument(src, open_paren):
    """Text of the first argument of a call, given the index of its '('. None if unbalanced."""
    depth, i, n = 0, open_paren, len(src)
    start = open_paren + 1
    while i < n:
        c = src[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return src[start:i].strip()
        elif c == "," and depth == 1:
            return src[start:i].strip()
        i += 1
    return None


def condition_index(clean):
    """Which argument each local helper treats as its condition, by reading its parameter list.

    A helper with no boolean-looking parameter is recorded as None: its call sites still count as
    checks, they are just not classifiable by condition text.
    """
    index = {}
    for m in HELPER_DEF.finditer(clean):
        params = [p.strip() for p in m.group(2).split(",") if p.strip()]
        slot = None
        for i, param in enumerate(params):
            if param.lower() in CONDITION_PARAMS:
                slot = i
                break
        index[m.group(1)] = slot
    return index


def nth_argument(src, open_paren, n):
    """Text of the nth (0-based) argument of a call. None if there is no such argument."""
    depth, i, start, found = 0, open_paren, open_paren + 1, 0
    while i < len(src):
        c = src[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return src[start:i].strip() if found == n else None
        elif c == "," and depth == 1:
            if found == n:
                return src[start:i].strip()
            found += 1
            start = i + 1
        i += 1
    return None


def check_sites(path, src):
    """Every check call in one Lua file: (line, name, condition text or None if unclassifiable)."""
    clean = strip_lua_comments(src)
    slots = condition_index(clean)
    sites = []
    for m in CALL.finditer(clean):
        name = m.group(1) + m.group(2)
        # A definition is not a call site.
        line_start = clean.rfind("\n", 0, m.start()) + 1
        if re.match(r"\s*(local\s+)?function\s", clean[line_start:m.start() + 1]):
            continue
        slot = 0 if name == "assert" else slots.get(name, 0)
        cond = None if slot is None else nth_argument(clean, m.end() - 1, slot)
        if cond is not None:
            cond = " ".join(cond.split())
        sites.append((clean.count("\n", 0, m.start()) + 1, name, cond))
    return sites


# A condition no game state can falsify. Each shape here was written against a real one found in
# tools/, or is the textbook form of one.
ALWAYS_TRUE = [
    (re.compile(r"^true$"), "literal true"),
    (re.compile(r"^\d+$"), "a number is truthy in Lua"),
    (re.compile(r"^\"[^\"]*\"$|^'[^']*'$"), "a string is truthy in Lua"),
    (re.compile(r"\bor\s+true\s*$"), "'or true' makes the whole condition true"),
    (re.compile(r"^not\s+(false|nil)$"), "negation of a constant"),
    (re.compile(r"^#\s*[\w.\[\]():]+\s*>=\s*0$"), "a length is never negative"),
    (re.compile(r"^[\w.]+\s*>=\s*0$"), "compared >= 0; true for any count"),
    (re.compile(r"^#\s*[\w.\[\]():]+\s*(?:==|>=)\s*#\s*[\w.\[\]():]+$"), "compares a length with itself"),
    (re.compile(r"^([\w.]+)\s*==\s*\1$"), "compares a value with itself"),
    (re.compile(r"^[\w.]+\s*~=\s*nil\s+or\s+[\w.]+\s*==\s*nil$"), "covers both cases"),
]


def flag_always_true(cond):
    for pattern, why in ALWAYS_TRUE:
        if pattern.search(cond):
            # '>= 0' on something that can legitimately go negative is a real check; a count or a
            # length cannot, so only flag the names that read like one.
            if why.startswith("compared >= 0") and not re.search(
                r"count|total|num|len|size|samples|hits|found|tally|checked", cond, re.I
            ):
                continue
            return why
    return None


LOOP = re.compile(r"^(\s*)for\s+.*\bin\s+(?:ipairs|pairs)\s*\(\s*([^)]*?)\s*\)\s*do\b")
# Anything that would make an empty collection visible: a count compared against zero, or a
# reported sample total.
GUARD = re.compile(r"[#\w.\[\]()]+\s*(?:>|>=|~=)\s*(?:0|1)\b|\bnext\s*\(")


def constant_tables(clean):
    """Locals bound to a non-empty table literal in the file itself. These can never sweep empty.

    The literal is read to its balanced close, because most of them run over several lines and a
    single-line match would leave them looking like runtime collections.
    """
    names = set()
    for m in re.finditer(r"local\s+(\w+)\s*=\s*\{", clean):
        depth, i = 0, m.end() - 1
        while i < len(clean):
            if clean[i] == "{":
                depth += 1
            elif clean[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if clean[m.end():i].strip():
            names.add(m.group(1))
    return names


def unguarded_sweeps(path, src):
    """Loops whose only checks are per-item, in files where an empty collection fails nothing.

    Block extent comes from indentation: every file in tools/ is tab-indented and the matching
    'end' sits at the loop's own indent. A loop whose body cannot be delimited is skipped and
    counted, never silently dropped.
    """
    clean = strip_lua_comments(src)
    lines = clean.split("\n")
    constants = constant_tables(clean)
    found, skipped = [], 0
    for i, line in enumerate(lines):
        m = LOOP.match(line)
        if not m:
            continue
        indent, subject = m.group(1), m.group(2)
        # A loop over a literal written into the file, or over a local bound to one, sweeps a
        # collection that cannot be empty. Only runtime-built collections are at risk.
        if subject.startswith("{") or subject.split(".")[0].split("[")[0] in constants:
            continue
        end = None
        for j in range(i + 1, len(lines)):
            if lines[j].rstrip() == indent + "end" or lines[j].rstrip() == indent + "end)":
                end = j
                break
        if end is None:
            skipped += 1
            continue
        body = "\n".join(lines[i + 1:end])
        if not CALL.search(body):
            continue
        # Does anything anywhere in the file fail when this collection is empty?
        base = subject.split(".")[-1].split("(")[0].strip() or subject
        guarded = False
        for ln, _name, cond in check_sites(path, src):
            if cond is None:
                continue
            if ln > i + 1 and ln <= end + 1:
                continue                                  # a check inside the loop cannot guard it
            if base and base in cond and GUARD.search(cond):
                guarded = True
                break
        if not guarded:
            found.append((i + 1, subject, len(CALL.findall(body))))
    return found, skipped


# ---------------------------------------------------------------------------
# Python: run each checker for real and count what every regex actually matched
# ---------------------------------------------------------------------------

def trace_child(target, root):
    """Run one checker with an instrumented re module; print one JSON line of per-site hit counts.

    Call sites are found by walking frames rather than by traceback.extract_stack, which reads
    source for every frame and turned a six-second checker into a ten-minute one.
    """
    target = os.path.abspath(target)
    stats = {}

    def site_line():
        frame = sys._getframe(1)
        while frame is not None:
            if frame.f_code.co_filename == target:
                return frame.f_lineno
            frame = frame.f_back
        return None

    def record(pattern, line, hit, haystack=None):
        """Keyed by call site, not by pattern text.

        Several sites build a pattern per name inside a loop -- 'is this local ever used' asks a
        different question of each one. Keying by text would call every unused name a dead check
        and drown the real finding; the question that matters is whether the SITE ever matched
        anything at all.
        """
        text = pattern.pattern if hasattr(pattern, "pattern") else pattern
        if not isinstance(text, str):
            return
        entry = stats.setdefault(str(line), [0, 0, text, set(), 0, None])
        entry[0] += 1
        entry[1] += 1 if hit else 0
        if len(entry[3]) < 50:
            entry[3].add(text)
        if isinstance(haystack, str):
            entry[4] = max(entry[4], len(haystack))
            entry[5] = len(haystack) if entry[5] is None else min(entry[5], len(haystack))

    def wrap(fn, hit_test):
        def inner(pattern, *args, **kwargs):
            result = fn(pattern, *args, **kwargs)
            line = site_line()
            if line is not None:
                record(pattern, line, hit_test(result), args[0] if args else None)
            return result
        return inner

    truthy = lambda r: r is not None and r is not False
    nonempty = lambda r: bool(r) and len(r) > 0
    real_finditer = re.finditer

    re.search = wrap(re.search, truthy)
    re.match = wrap(re.match, truthy)
    re.fullmatch = wrap(re.fullmatch, truthy)
    re.findall = wrap(re.findall, nonempty)
    re.finditer = wrap(lambda p, *a, **k: list(real_finditer(p, *a, **k)), nonempty)

    # re.Pattern methods are C slots and cannot be patched, so compiled patterns are traced at
    # re.compile time instead: the object handed back carries the wrappers.
    real_compile = re.compile

    def compile_traced(pattern, flags=0):
        compiled = real_compile(pattern, flags)
        line = site_line()

        class Traced:
            pattern = compiled.pattern

            def __getattr__(self, name):
                attribute = getattr(compiled, name)
                if name in ("search", "match", "fullmatch", "findall", "finditer", "split"):
                    test = truthy if name in ("search", "match", "fullmatch") else nonempty
                    def call(*args, **kwargs):
                        result = attribute(*args, **kwargs)
                        if name == "finditer":
                            result = list(result)
                        if line is not None:
                            record(compiled, line, test(result), args[0] if args else None)
                        return result
                    return call
                return attribute

        return Traced() if line is not None else compiled

    re.compile = compile_traced

    source = open(target, encoding="utf-8").read()
    sys.argv = [target, root]
    namespace = {"__name__": "__main__", "__file__": target}
    code = compile(source, target, "exec")
    try:
        exec(code, namespace)
    except SystemExit:
        pass
    payload = {k: [v[0], v[1], v[2], len(v[3]), v[4], v[5] or 0] for k, v in stats.items()}
    sys.stderr.write("PROBE_AUDIT_JSON " + json.dumps(payload) + "\n")


def trace_python(root, tools_dir):
    """Every regex site in the read-only checkers, with attempts and hits over the real project."""
    results = []
    for name in TRACEABLE:
        path = os.path.join(tools_dir, name)
        if not os.path.exists(path):
            continue
        run = subprocess.run(
            [sys.executable, os.path.abspath(__file__), "--trace-child", path, root],
            capture_output=True, text=True, cwd=root,
        )
        payload = None
        for line in run.stderr.split("\n"):
            if line.startswith("PROBE_AUDIT_JSON "):
                payload = json.loads(line[len("PROBE_AUDIT_JSON "):])
        if payload is None:
            results.append((name, None, run.stderr.strip().split("\n")[-1][:200]))
            continue
        sites = []
        for line, row in sorted(payload.items(), key=lambda kv: int(kv[0])):
            attempts, hits, pattern, variants, biggest, smallest = row
            sites.append((int(line), pattern, attempts, hits, variants, biggest, smallest))
        results.append((name, sites, None))
    return results


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def lua_report(tools_dir):
    files = sorted(f for f in os.listdir(tools_dir) if f.endswith(".lua"))
    total_sites, opaque, always, sweeps, skipped_blocks, asserting = 0, 0, [], [], 0, 0
    for name in files:
        path = os.path.join(tools_dir, name)
        src = open(path, encoding="utf-8", errors="replace").read()
        sites = check_sites(path, src)
        if sites:
            asserting += 1
        total_sites += len(sites)
        for line, helper, cond in sites:
            if cond is None:
                opaque += 1
                continue
            why = flag_always_true(cond)
            if why:
                always.append((name, line, helper, cond, why))
        found, skip = unguarded_sweeps(path, src)
        skipped_blocks += skip
        for line, subject, count in found:
            sweeps.append((name, line, subject, count))
    return files, asserting, total_sites, opaque, always, sweeps, skipped_blocks


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    tools_dir = os.path.join(root, "tools")
    files, asserting, total_sites, opaque, always, sweeps, skipped = lua_report(tools_dir)

    print("probe audit: %d lua files in tools/, %d of them assert, %d check sites"
          % (len(files), asserting, total_sites))
    print("probe audit: %d sites have no boolean parameter to classify; read by hand instead"
          % opaque)
    for name, line, helper, cond, why in always:
        print("  ALWAYS TRUE  tools/%s:%d  %s(%s)  -- %s" % (name, line, helper, cond, why))
    print("probe audit: always-true conditions: %d" % len(always))

    for name, line, subject, count in sweeps:
        print("  UNGUARDED    tools/%s:%d  %d check(s) inside a loop over '%s'; nothing fails when "
              "it is empty" % (name, line, count, subject))
    print("probe audit: unguarded sweeps: %d (blocks skipped, unmatched indent: %d)"
          % (len(sweeps), skipped))

    traced = trace_python(root, tools_dir)
    regex_total, dead = 0, []
    for name, sites, error in traced:
        if sites is None:
            print("  TRACE FAILED tools/%s: %s" % (name, error))
            continue
        regex_total += len(sites)
        for line, pattern, attempts, hits, variants, biggest, smallest in sites:
            if hits == 0:
                dead.append((name, line, pattern, attempts, variants, biggest, smallest))
    for name, line, pattern, attempts, variants, biggest, smallest in dead:
        print("  NEVER MATCHED tools/%s:%d  %d attempts%s, 0 matches, searched %d-%d bytes  %r"
              % (name, line, attempts, " (%d patterns)" % variants if variants > 1 else "",
                 smallest, biggest, pattern[:80]))
    print("probe audit: %d python checkers traced, %d regex sites, %d never matched"
          % (sum(1 for _n, s, _e in traced if s is not None), regex_total, len(dead)))

    total = len(always) + len(sweeps) + len(dead)
    print("probe audit: %d check sites examined, %d flagged" % (total_sites + regex_total, total))

    report = self_test(root)
    print("\n".join(report))
    # A detector that has stopped firing is the same failure this audit is about, so it fails the
    # run rather than printing a quiet note under a clean-looking summary.
    return 1 if any("did NOT" in line or "false positive" in line for line in report) else 0


# ---------------------------------------------------------------------------
# Self-test: the detectors are not allowed to be the unaudited part
# ---------------------------------------------------------------------------

FIXTURE_DIR = "probe_audit_fixtures"


def must_flag_lines(src):
    """Line numbers a fixture marks `MUST FLAG`.

    The bad fixtures plant several shapes each, so 'something was flagged' is too coarse a test:
    the first draft of this self-test stayed green with one of the four ALWAYS TRUE shapes deleted,
    which is the same too-wide sample the audit exists to find. Every planted shape names its own
    line, and the detector must flag that exact set.
    """
    marked = set()
    for i, line in enumerate(src.split("\n"), 1):
        if "MUST FLAG" not in line:
            continue
        # A trailing marker on a line of code, not prose in the header that happens to name it.
        code = re.split(r"--|#", line, maxsplit=1)[0].strip()
        if code:
            marked.add(i)
    return marked


def self_test(root):
    """Run every detector over its planted fault and its clean twin. Returns report lines.

    A line containing 'did NOT' or 'false positive' means this file is broken, not the harness.
    """
    base = os.path.join(root, "tools", FIXTURE_DIR)
    lines, fired, clean, total = [], 0, 0, 3
    if not os.path.isdir(base):
        return ["probe audit self-test: no fixtures under tools/%s — every detector is unproven"
                % FIXTURE_DIR]

    def lua(name):
        path = os.path.join(base, name)
        return path, open(path, encoding="utf-8").read()

    # ALWAYS TRUE
    path, src = lua("always_true_bad.lua.fixture")
    want = must_flag_lines(src)
    got = {l for l, _n, c in check_sites(path, src) if c is not None and flag_always_true(c)}
    if want and got >= want:
        fired += 1
    else:
        lines.append("probe audit self-test: ALWAYS TRUE did NOT flag every planted fault in "
                     "always_true_bad.lua.fixture (missed line%s %s) — that shape is testing nothing"
                     % ("" if len(want - got) == 1 else "s",
                        ", ".join(str(l) for l in sorted(want - got)) or "none marked"))
    path, src = lua("always_true_good.lua.fixture")
    noise = [c for _l, _n, c in check_sites(path, src) if c is not None and flag_always_true(c)]
    if noise:
        lines.append("probe audit self-test: ALWAYS TRUE flagged correct code in "
                     "always_true_good.lua.fixture (%s) — it produces false positives" % noise[0])
    else:
        clean += 1

    # UNGUARDED
    path, src = lua("unguarded_bad.lua.fixture")
    want = must_flag_lines(src)
    got = {line for line, _subject, _n in unguarded_sweeps(path, src)[0]}
    if want and got >= want:
        fired += 1
    else:
        lines.append("probe audit self-test: UNGUARDED did NOT flag every planted fault in "
                     "unguarded_bad.lua.fixture (missed line%s %s) — that shape is testing nothing"
                     % ("" if len(want - got) == 1 else "s",
                        ", ".join(str(l) for l in sorted(want - got)) or "none marked"))
    path, src = lua("unguarded_good.lua.fixture")
    found, _skipped = unguarded_sweeps(path, src)
    if found:
        lines.append("probe audit self-test: UNGUARDED flagged the guarded sweep in "
                     "unguarded_good.lua.fixture — it produces false positives")
    else:
        clean += 1

    # NEVER MATCHED — through trace_child, the same route verify.py takes
    bad_path = os.path.join(base, "never_matched_bad.py.fixture")
    want = must_flag_lines(open(bad_path, encoding="utf-8").read())
    got = set(traced_zero_hits(root, bad_path))
    if want and got >= want:
        fired += 1
    else:
        lines.append("probe audit self-test: NEVER MATCHED did NOT flag every planted fault in "
                     "never_matched_bad.py.fixture (missed line%s %s) — that shape is testing "
                     "nothing" % ("" if len(want - got) == 1 else "s",
                                  ", ".join(str(l) for l in sorted(want - got)) or "none marked"))
    good = traced_zero_hits(root, os.path.join(base, "never_matched_good.py.fixture"))
    if good:
        lines.append("probe audit self-test: NEVER MATCHED flagged line %d of "
                     "never_matched_good.py.fixture, where every pattern matches — false positive"
                     % good[0])
    else:
        clean += 1

    lines.append("probe audit self-test: %d/%d planted faults fired, %d/%d clean fixtures stayed "
                 "quiet" % (fired, total, clean, total))
    return lines


def traced_zero_hits(root, path):
    """Line numbers of regex sites in one checker that matched nothing. Used on fixtures."""
    run = subprocess.run(
        [sys.executable, os.path.abspath(__file__), "--trace-child", path, root],
        capture_output=True, text=True, cwd=root,
    )
    for line in run.stderr.split("\n"):
        if line.startswith("PROBE_AUDIT_JSON "):
            payload = json.loads(line[len("PROBE_AUDIT_JSON "):])
            return sorted(int(k) for k, row in payload.items() if row[1] == 0)
    return []


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--trace-child":
        trace_child(sys.argv[2], sys.argv[3])
    elif len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        report = self_test(sys.argv[2] if len(sys.argv) > 2 else ".")
        print("\n".join(report))
        sys.exit(1 if any("did NOT" in l or "false positive" in l for l in report) else 0)
    else:
        sys.exit(main())
