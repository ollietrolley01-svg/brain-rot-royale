"""Task 05 — sweep for finished work that nothing can run.

    python tools/census.py .

Four shapes were asked for. Three of them are decidable by reading the source and are swept here;
the fourth (an unreachable branch) is not, in general, and is handled by hand in CENSUS.md rather
than guessed at by a regex. What this file does:

  shape 1  a module with no production requirer      -- required only from tools/, or not at all
  shape 2  an exported function with no caller       -- the module is wired, the function is not
  shape 4  a declared thing with no consumer         -- three enumerable kinds: sound cues,
                                                        remote channels, and instance attributes

This becomes a delete list, so **a false positive costs more than a miss**. Every rule below is
written to under-report, and the three guards that matter were each paid for by a wrong answer
during the sweep that produced CENSUS.md:

  * A FUNCTION PASSED AS A VALUE is called. `CombatService.DestructiblePassesThrough =
    DestructibleService.PassesThrough` is a live caller and never writes `.PassesThrough(`. Match
    the bare member, not the call.
  * A NAME BUILT AT RUN TIME is not a literal. `SetAttribute("KP_" .. name)` writes an attribute
    that no literal search will find. Names that are only ever seen as a concatenation prefix are
    reported as UNSETTLED, never as findings.
  * A STRING IS A CALL when something dispatches on it. The client reaches the Prestige remote
    through `call(ctx, "Prestige", ...)`, not through `Remotes.Function("Prestige")`. Count bare
    string literals as references.

Comments are stripped before any of it, because this project documents callers that do not exist
and a comment naming a function is not a call to it.

Exit code is 0 only if the real sweep ran AND the fixtures behaved: the must-flag fixture was
flagged and the must-not-flag fixture was not. A sweep whose fixtures did not behave has not been
shown to work, whatever it printed.
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
PROD_DIRS = ("ReplicatedStorage", "ServerScriptService", "StarterPlayerScripts")


def strip_comments(src):
    """Lua comments out. A comment that names a caller is not a caller."""
    src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
    return "\n".join(re.sub(r"--.*$", "", line) for line in src.split("\n"))


def load(root):
    prod = sorted(p for d in PROD_DIRS for p in (root / d).rglob("*.lua"))
    tools = sorted(p for p in (root / "tools").rglob("*.lua"))
    return ({p: strip_comments(p.read_text(encoding="utf-8")) for p in prod},
            {p: strip_comments(p.read_text(encoding="utf-8")) for p in tools})


def stem(path):
    return path.name.replace(".server.lua", "").replace(".client.lua", "").replace(".lua", "")


def shown(path):
    """A readable path, whichever tree the file came from."""
    for base in (ROOT, pathlib.Path(__file__).parent / "census_fixtures"):
        try:
            return str(path.relative_to(base))
        except ValueError:
            continue
    return str(path)


# ---------------------------------------------------------------------------
# shape 1 — a module with no production requirer
# ---------------------------------------------------------------------------

def sweep_modules(prod, tools):
    # A ModuleScript is anything build_place.py does not turn into a Script or LocalScript.
    modules = [p for p in prod if not p.name.endswith((".client.lua", ".server.lua"))]
    findings = []
    for m in modules:
        name = stem(m)
        # Deliberately broad: any mention of the name as a child or a member counts as a possible
        # load. Under-reporting is the point.
        pat = re.compile(r'(WaitForChild\(\s*"%s"|FindFirstChild\(\s*"%s"|[.:]%s\b|"%s")'
                         % ((re.escape(name),) * 4))
        in_prod = [p for p in prod if p != m and pat.search(prod[p])]
        if in_prod:
            continue
        in_tools = [p for p in tools if pat.search(tools[p])]
        findings.append({
            "name": name,
            "path": shown(m),
            "lines": prod[m].count("\n") + 1,
            "tools": len(in_tools),
        })
    return len(modules), findings


# ---------------------------------------------------------------------------
# shape 2 — an exported function with no caller
# ---------------------------------------------------------------------------

def sweep_functions(prod, tools, skip_modules=()):
    examined = 0
    findings = []
    for p in prod:
        if stem(p) in skip_modules:
            continue                              # its whole module is already a shape 1 finding
        src = prod[p]
        returned = re.findall(r"^return\s+(\w+)\s*$", src, re.M)
        if not returned:
            continue                              # an entry-point script exports nothing
        table = returned[-1]
        for tbl, fn in re.findall(r"^function\s+(\w+)[.:](\w+)\s*\(", src, re.M):
            if tbl != table:
                continue                          # an internal helper table, not the module's API
            if fn.startswith("_"):
                continue                          # private by this project's convention
            examined += 1
            member = re.compile(r"[.:]%s\b" % re.escape(fn))   # a call OR a value
            literal = re.compile(r'"%s"' % re.escape(fn))      # possible run-time dispatch
            if any(member.search(prod[q]) or literal.search(prod[q]) for q in prod if q != p):
                continue
            if len(member.findall(src)) > 1 or literal.search(src):
                continue                          # used inside its own module: it runs
            in_tools = [q for q in tools if member.search(tools[q]) or literal.search(tools[q])]
            findings.append({
                "name": "%s.%s" % (table, fn),
                "path": shown(p),
                "tools": len(in_tools),
            })
    return examined, findings


# ---------------------------------------------------------------------------
# shape 4 — a declared thing with no consumer
# ---------------------------------------------------------------------------

def sweep_sound_cues(prod, tools):
    cue_file = next((p for p in prod if p.name == "SoundConfig.lua"), None)
    if not cue_file:
        return 0, []
    block = prod[cue_file].split("SoundConfig.Sounds = {", 1)[-1]
    cues = re.findall(r"^\t(\w+) = \{", block, re.M)
    findings = []
    for cue in cues:
        lit = re.compile(r'"%s"' % re.escape(cue))
        if any(lit.search(prod[p]) for p in prod if p != cue_file):
            continue
        findings.append({"name": cue, "tools": sum(1 for p in tools if lit.search(tools[p]))})
    return len(cues), findings


def sweep_remotes(prod):
    """A remote wired on one side only. Bare string literals count: the client reaches several
    through a dispatcher that takes the name as an argument."""
    names = set()
    for p in prod:
        names |= set(re.findall(r'Remotes\.(?:Event|Function)\(\s*"(\w+)"', prod[p]))
    findings = []
    for name in sorted(names):
        lit = re.compile(r'"%s"' % name)
        sides = {("server" if "ServerScriptService" in str(p) else "client")
                 for p in prod if lit.search(prod[p])}
        if len(sides) == 1:
            findings.append({"name": name, "side": sides.pop()})
    return len(names), findings


def sweep_attributes(prod, tools):
    """Attributes read but never written. Returns (examined, findings, unsettled).

    `unsettled` is the whole reason this is safe to run: an attribute whose name is built by
    concatenation cannot be found by a literal search, so it is quarantined rather than reported.
    """
    read, written, concat = {}, set(), set()
    for p in prod:
        src = prod[p]
        for n in re.findall(r'GetAttribute\(\s*"(\w+)"', src):
            read.setdefault(n, []).append(p)
        written |= set(re.findall(r'SetAttribute\(\s*"(\w+)"', src))
        # "Prefix_" .. something. Only prefixes ending in an underscore count, which is this
        # project's run-time-name convention -- a looser rule would quarantine real findings,
        # because any short string literal followed by `..` would become a prefix.
        concat |= {c for c in re.findall(r'"(\w+_)"\s*\.\.', src)}
    findings, unsettled = [], []
    for name, readers in sorted(read.items()):
        if name in written:
            continue
        row = {"name": name,
               "readers": sorted({stem(p) for p in readers}),
               "tools_write": sum(1 for p in tools
                                  if re.search(r'SetAttribute\(\s*"%s"' % name, tools[p]))}
        # Quarantined if the name IS a run-time prefix, or is one a prefix could have built.
        # `SetAttribute("KP_" .. name)` writes KP_Muzzle, which no literal search will ever find.
        if name.endswith("_") or any(name.startswith(c) for c in concat):
            unsettled.append(row)
        else:
            findings.append(row)
    return len(read), findings, unsettled


# ---------------------------------------------------------------------------
# fixtures — the census must flag the dead one and must NOT flag the live one
# ---------------------------------------------------------------------------

def run_fixtures():
    """Analyse the fixture tree through the same functions as the real tree.

    The must-not-flag fixture is the one that matters. It holds a module that is only ever
    required through a variable, and a function that is only ever referenced as a value — the two
    shapes that produced wrong answers while this sweep was being written. If a future change to
    the guards above reintroduces either, this goes red.
    """
    root = pathlib.Path(__file__).parent / "census_fixtures"
    prod, tools = load(root)
    if not prod:
        sys.exit("census: fixtures missing from %s" % root)
    _, dead_modules = sweep_modules(prod, tools)
    _, dead_fns = sweep_functions(prod, tools)
    flagged = {f["name"] for f in dead_modules} | {f["name"] for f in dead_fns}

    must_flag = {"DeadModule", "LiveModule.NeverCalled"}
    must_not_flag = {"AliasedModule", "LiveModule.CalledAsValue", "LiveModule.CalledNormally"}
    missed = must_flag - flagged
    false_positives = must_not_flag & flagged
    return flagged, missed, false_positives


def main():
    prod, tools = load(ROOT)
    print("production .lua: %d     tools/ .lua: %d\n" % (len(prod), len(tools)))

    n_modules, dead_modules = sweep_modules(prod, tools)
    print("== shape 1: modules with no production requirer ==")
    print("modules examined: %d, flagged: %d" % (n_modules, len(dead_modules)))
    for f in sorted(dead_modules, key=lambda f: -f["lines"]):
        where = "tools/ only (%d files)" % f["tools"] if f["tools"] else "NOTHING anywhere"
        print("  %5d lines  %-52s %s" % (f["lines"], f["path"], where))

    skip = {f["name"] for f in dead_modules}
    n_fns, dead_fns = sweep_functions(prod, tools, skip_modules=skip)
    seam = [f for f in dead_fns if f["tools"]]
    nothing = [f for f in dead_fns if not f["tools"]]
    print("\n== shape 2: exported functions with no caller ==")
    print("exported functions examined: %d, flagged: %d" % (n_fns, len(dead_fns)))
    print("  called only from tools/ (a harness seam, not dead): %d" % len(seam))
    print("  called by nothing anywhere:                         %d" % len(nothing))
    for f in sorted(nothing, key=lambda f: f["name"]):
        print("      %-34s %s" % (f["name"], f["path"]))

    n_cues, dead_cues = sweep_sound_cues(prod, tools)
    n_remotes, lonely = sweep_remotes(prod)
    n_attrs, dead_attrs, unsettled = sweep_attributes(prod, tools)
    print("\n== shape 4: declared things with no consumer ==")
    print("sound cues examined: %d, no play site: %d" % (n_cues, len(dead_cues)))
    for f in dead_cues:
        print("      %-24s %s" % (f["name"], "tools/ only" if f["tools"] else "nowhere at all"))
    print("remote channels examined: %d, wired one side only: %d" % (n_remotes, len(lonely)))
    for f in lonely:
        print("      %-24s %s only" % (f["name"], f["side"]))
    print("attributes read: %d, read but never written: %d" % (n_attrs, len(dead_attrs)))
    for f in dead_attrs:
        print("      %-24s read in %s" % (f["name"], ", ".join(f["readers"])))
    print("  UNSETTLED, name built at run time — NOT findings: %d" % len(unsettled))
    for f in unsettled:
        print("      %-24s read in %s" % (f["name"], ", ".join(f["readers"])))

    flagged, missed, false_positives = run_fixtures()
    print("\n== fixtures ==")
    print("must-flag missed:    %s" % (sorted(missed) if missed else "none — both flagged"))
    print("must-NOT-flag flagged: %s" % (sorted(false_positives) if false_positives
                                         else "none — no false positives"))
    if missed:
        sys.exit("census: FAIL — the must-flag fixture was not flagged; the sweep is not working")
    if false_positives:
        sys.exit("census: FAIL — a must-not-flag fixture was flagged; the sweep would delete live code")
    print("\ncensus: OK — fixtures behaved; findings above are candidates for CENSUS.md, "
          "not a delete list on their own")


if __name__ == "__main__":
    main()
