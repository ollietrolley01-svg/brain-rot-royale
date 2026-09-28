"""Bug test of the build machine's fixes of 2026-09-25 (Oliver, 2026-09-25 03:00: "run bug tests").

The fixes' own checks (roadkill_proof_check, explosive_dispatch_check, vote_menu_proof, trial_guns_proof_check,
bot_lag_proof_check, clock_ratchet) prove what each fix claims. This one aims at the edges they don't plant:
what sits next to each change, and the cases a fix's own scenes don't build. It reuses their worlds, so the
game code under test is the same REAL modules they load (nothing is re-implemented here):

  K  roadkill (pc/roadkill-rules), tools/roadkill_proof_world.lua through roadkill_proof_check's scenes:
     K1  the driver's client (RoadkillPass.Sheltered, which leaves a rider out of the sweep) and the server
         (VehicleService.ShieldingVehicle, which refuses the hit) agree on every seat of every model, parked
         and wrecked, and both follow the rule: sheltered only in an armoured cabin, never the gunner's
         hatch, never in a wreck;
     K2  a gunner in an armoured car's hatch can still be run over (Oliver 09-25: "a gunner's hatch can
         still be run down"), measured through the server's Touched path;
     then FINDING lines (not failures): a "ratio'd" victim hit by a driverless car, a graze under half a
     point, and a bailed car hitting its old driver's team-mate.
  X  explosive ammo (pc/explosive-followups), tools/explosive_dispatch_world.lua:
     X1  every gun with a bullet blast, on 1 to 12 pellets: the pellets' blasts add up to the gun's ammo
         (damage and wall damage), no pellet's blast is bigger than the whole gun's, none is under 2 studs,
         and one pellet is the ammo untouched;
     then a FINDING: a round whose owner has left bursts on the team-mate in front of the enemy.
  C  clocks (pc/clock-deadlines), static, over every game .lua file:
     C1  no expression mixes a tick() reading with an os.clock() reading (the fix moved some deadlines to
         tick(); a half-moved pair would compare two clocks). Names are followed through plain locals and
         table fields in the same file.
     then FINDING lines: os.clock() deadlines still left in MovementService, the file the fix edited.
  M  bot routes (pc/bot-movement-smooth), BotNav's continueRoute cut from the real file:
     M1  a bot's MoveToFinished continues its route only in the one case the fix names, and refuses every
         other: seated in a vehicle, dead, mid-parkour, a think since the hand-out, the next waypoint a jump,
         a detour, climbing, a replaced route, the bot not at its waypoint, the route's end.

    python tools/tonight_fixes_bugtest_check.py [root]            the checks
    python tools/tonight_fixes_bugtest_check.py [root] --plant    the planted faults; every one must be caught

Not covered: anything a player sees or feels (a throw, an animation), Roblox's physics and its Humanoid
events' real timing, and a live server. The drop-picker and range-reload fixes are covered by their own
checks (vote_menu_proof 11/11, trial_guns_proof_check 16/16); reports/bugtest-tonight-fixes.md says what
was read for them instead.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("tonight_fixes_bugtest_check: needs lupa (pip install lupa)")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import roadkill_proof_check as rk  # noqa: E402  (its world and scenes; main() is guarded)
import explosive_dispatch_check as xd  # noqa: E402


# ---------------------------------------------------------------------------------------------- K roadkill

K_SCENES = r"""
-- The seat rule, written from VehicleArmor's data (the armoured ids come from the file, not the function):
-- sheltered iff the model is armoured, the seat is not the gunner's, and the car is not a wreck.
local armoured = pins.armoured
-- The world's cars are boxes with a driver and passengers only. An armed model (VehicleModels.Mounts, read
-- from the real file) gets its gun seat here, above the middle, as the real Build adds one.
local realBuild = w.VehicleModels.Build
w.VehicleModels.Build = function(modelId, ...)
    local model, info = realBuild(modelId, ...)
    if pins.armed[modelId] and info.kind ~= "bike" then
        info.seats.gunner = w.CFrame.new(0, 5, 1)
    end
    return model, info
end
local function rule(id, seatName, wrecked)
    return armoured[id] == true and seatName ~= "GunnerSeat" and not wrecked
end

--------------------------------------------------------------------------------
-- K1: the client's sweep and the server agree on who is sheltered, on every seat
--------------------------------------------------------------------------------
do
    local examined, gunners, armouredSeats, bad = 0, 0, 0, {}
    for _, id in ipairs(ids) do
        local entry = vehicle(id, nextPlace())
        local seats = { entry.seat }
        for _, s in ipairs(entry.passengers or {}) do
            table.insert(seats, s)
        end
        if entry.gunnerSeat then
            table.insert(seats, entry.gunnerSeat)
            gunners = gunners + 1
        end
        for index, seat in ipairs(seats) do
            local token, model, hum = bot("k1_" .. id .. "_" .. index, seat.Position)
            local sat = sitBot(token, entry, seat)
            if not sat then
                table.insert(bad, id .. "/" .. seat.Name .. ": could not sit")
            else
                for _, wrecked in ipairs({ false, true }) do
                    entry.wrecked = wrecked
                    entry.model:SetAttribute("Wrecked", wrecked or nil)
                    local client = RoadkillPass.Sheltered(hum) == true
                    local server = VS.ShieldingVehicle(token) ~= nil
                    local want = rule(id, seat.Name, wrecked)
                    examined = examined + 1
                    if want then
                        armouredSeats = armouredSeats + 1
                    end
                    if client ~= want or server ~= want then
                        table.insert(bad, string.format("%s/%s%s: sweep %s, server %s, rule %s", id, seat.Name,
                            wrecked and " (wreck)" or "", tostring(client), tostring(server), tostring(want)))
                    end
                end
                entry.wrecked = false
                entry.model:SetAttribute("Wrecked", nil)
            end
        end
        clear()
    end
    check("K1 the driver's client (RoadkillPass.Sheltered) and the server (ShieldingVehicle) agree with the rule on every seat, parked and wrecked",
        #bad == 0 and examined > 0,
        string.format("%d seat states examined (%d models, %d with a gunner seat, %d sheltered): %s", examined, #ids, gunners,
            armouredSeats, #bad == 0 and "all agree" or table.concat(bad, "; ")))
end

--------------------------------------------------------------------------------
-- K2: an armoured car's gunner stands in the open and can be run over
--------------------------------------------------------------------------------
do
    local tried, hurt, detail = 0, 0, {}
    for _, id in ipairs(ids) do
        if armoured[id] then
            local parked = vehicle(id, nextPlace())
            if parked.gunnerSeat then
                tried = tried + 1
                local gunner, gunnerModel, gunnerHum = bot("k2_gunner_" .. id, parked.gunnerSeat.Position, 1000)
                sitBot(gunner, parked, parked.gunnerSeat)
                local mover = vehicle("Rotster", nextPlace())
                local driver = bot("k2_driver_" .. id, mover.seat.Position)
                sitBot(driver, mover, mover.seat)
                drive(mover, 60)
                run(0.1)
                mover.rig.chassis.Touched:Fire(gunnerModel.Torso)
                local dealt = 1000 - gunnerHum.Health
                if near(dealt, expected(60)) then
                    hurt = hurt + 1
                end
                table.insert(detail, id .. " gunner dealt " .. f(dealt) .. " (want " .. f(expected(60)) .. ")")
            end
            clear()
        end
    end
    check("K2 a gunner in an armoured car's hatch is run over like anyone in the open (server Touched at 60)",
        tried == hurt, tried == 0 and "no armoured model has a gunner seat" or table.concat(detail, "; "))
end

--------------------------------------------------------------------------------
-- FINDINGS: the scaled driverless hit and a "ratio'd" victim; a graze; a bailed car and its old team
--------------------------------------------------------------------------------
do
    -- DealDamage multiplies a hit WITH an attacker by DamageTakenScale ("ratio'd": takes more from everyone).
    -- The driverless hit is scaled in VehicleService instead, and gets only CombatDamageScale.
    local driven = vehicle("Rotster", nextPlace())
    local driver = bot("k3_driver", driven.seat.Position)
    sitBot(driver, driven, driven.seat)
    local empty = vehicle("Rotster", nextPlace())
    local v1, m1, h1 = player("k3_victim_driven", ahead(driven, 200), 1000)
    local v2, m2, h2 = player("k3_victim_empty", ahead(empty, 200), 1000)
    CS.DamageTakenScale = function(token)
        return (token == v1 or token == v2) and 1.5 or 1
    end
    drive(driven, 60)
    drive(empty, 60)
    driven.rig.chassis.Touched:Fire(m1.Torso)
    empty.rig.chassis.Touched:Fire(m2.Torso)
    CS.DamageTakenScale = nil
    local a, b = 1000 - h1.Health, 1000 - h2.Health
    table.insert(rows, { k = "ratiod", driven = a, driverless = b })
    if not near(a, b) then
        finding("K3 a \"ratio'd\" victim (DamageTakenScale 1.5) takes " .. f(a) .. " from a driven car at 60 but " .. f(b)
            .. " from a driverless one: the driverless hit gets CombatDamageScale (VehicleService roadkill) but not the status")
    end
    clear()
end

do
    -- The veto test reads DealDamage's rounded `dealt`: a hit under half a point hurts and is not thrown.
    local entry = vehicle("Rotster", nextPlace())
    local driver = bot("k4_driver", entry.seat.Position)
    sitBot(driver, entry, entry.seat)
    local victim, model, hum = player("k4_victim", ahead(entry, 200), 1000)
    local before = #W.launches
    drive(entry, 12.3)
    entry.rig.chassis.Touched:Fire(model.Torso)
    local lost = 1000 - hum.Health
    local thrown = #W.launches > before
    table.insert(rows, { k = "graze", lost = lost, thrown = thrown })
    -- The same rounding on a kill: a victim left on under half a point, hit at 60, dies with no RoadkillThrow
    -- for DeathFxService to throw the body by (a victim on 10 keeps it).
    local marks = {}
    for _, hp in ipairs({ 10, 0.3 }) do
        local v, m, h = player("k4_dying_" .. hp, ahead(entry, 200), 100)
        h.Health = hp
        now.t = now.t + 1
        drive(entry, 60)
        entry.rig.chassis.Touched:Fire(m.Torso)
        marks[hp] = { dead = h.Health <= 0, mark = m:GetAttribute("RoadkillThrow") ~= nil }
    end
    table.insert(rows, { k = "dying", normal = marks[10].mark, low = marks[0.3].mark })
    if lost > 0 and not thrown then
        finding("K4 VehicleService reads DealDamage's rounded `dealt` as \"vetoed\": a graze at 12.3 studs/s takes "
            .. string.format("%.3f", lost) .. " health and is not thrown; a victim on 0.3 health killed at 60 "
            .. (marks[0.3].dead and "dies" or "lives") .. " with RoadkillThrow " .. (marks[0.3].mark and "kept" or "cleared")
            .. " (on 10 health: " .. (marks[10].mark and "kept" or "cleared") .. "), so DeathFxService has no throw for that body")
    end
    clear()
end

do
    -- Team mode: the driver bails at speed and the car rolls on into the driver's own team-mate.
    teamMode(true)
    local entry = vehicle("TralalaGT", nextPlace())
    local driver = player("k5_driver", entry.seat.Position)
    sitPlayer(driver, entry, entry.seat)
    startDriving(driver, entry)
    run(0.1)
    drive(entry, 60)
    run(0.1)
    driver.Character:FindFirstChildOfClass("Humanoid").Sit = false
    w.runTimers()
    run(0.1)
    local mate, mateModel, mateHum = player("k5_mate", ahead(entry, 20), 1000)
    mt.teamOf[driver], mt.teamOf[mate] = 1, 1
    local before = #W.launches
    run(1.5, function() return mateHum.Health < 1000 end)
    local thrown = false
    for index = before + 1, #W.launches do
        if W.launches[index].character == mateModel then
            thrown = true
        end
    end
    teamMode(false)
    local lost = 1000 - mateHum.Health
    table.insert(rows, { k = "bail", lost = lost, thrown = thrown })
    if lost > 0 then
        finding("K5 team mode: a car its driver bailed out of at 60 hits the driver's own team-mate for " .. f(lost)
            .. (thrown and " and throws them" or "") .. ", credited to nobody (no attacker, so no veto: Oliver's decision 4A)")
    end
    clear()
end

for _, warning in ipairs(w.warnings) do
    finding("a module warned", warning)
end

return results, findings, rows
"""

K_SPLIT = "--------------------------------------------------------------------------------\n-- I1: a player at the wheel"


def armoured_ids(root):
    text = open(os.path.join(root, "ReplicatedStorage", "Shared", "VehicleArmor.lua"), encoding="utf-8").read()
    return sorted(set(re.findall(r"^\t(\w+) = \{[^\n]*cabin = \"armored\"", text, re.M)))


def armed_ids(root):
    text = open(os.path.join(root, "ReplicatedStorage", "Shared", "VehicleModels.lua"), encoding="utf-8").read()
    a = text.index("\nVehicleModels.Mounts = {\n")
    block = text[a:text.index("\n}\n", a)]
    return sorted(set(re.findall(r"^\t(\w+) = \{", block, re.M)))


def roadkill(root, swaps=None):
    head, sep, _ = rk.SCENES.partition(K_SPLIT)
    if not sep:
        sys.exit("tonight_fixes_bugtest_check: roadkill_proof_check's scenes changed shape (no I1 header)")
    # The model list the I1 section builds, which these scenes use too.
    ids = "local ids = {}\nfor i = 1, #C.models do\n    table.insert(ids, C.models[i][1])\nend\ntable.sort(ids)\n"
    scenes = head + ids + K_SCENES
    tree = rk.Tree(root, swaps)
    lua = LuaRuntime(unpack_returned_tuples=True)
    world_text = open(os.path.join(HERE, "roadkill_proof_world.lua"), encoding="utf-8").read()
    compile_ = lua.eval("load")
    world = compile_(world_text, "roadkill_proof_world")(lambda name: tree.lua(name), compile_)
    c = rk.cuts(tree)
    ctable = lua.table_from({k: v for k, v in c.items() if k != "models"})
    ctable["models"] = lua.table_from([lua.table_from(list(m)) for m in c["models"]])
    armoured = armoured_ids(root)
    pins = lua.table_from({"floor": rk.PIN_FLOOR, "per": rk.PIN_PER, "scale": rk.PIN_SCALE,
                           "armoured": lua.table_from({a: True for a in armoured}),
                           "armed": lua.table_from({a: True for a in armed_ids(root)})})
    results, findings, rows = lua.execute(scenes, world, ctable, pins)
    out = [(r[1], bool(r[2]), r[3]) for r in results.values()]
    return out, [(x[1] + ": " + x[2]) if x[2] and x[1] == "a module warned" else x[1] for x in findings.values()]


# ---------------------------------------------------------------------------------------------- X explosive

X_SPLIT = r"""
local S, def, n = ...
local copy = {}
for k, v in pairs(def) do copy[k] = v end
copy.pellets = n
local b = S.CS.BulletBlast(copy)
if not b then return nil end
return b.damage, b.radius, b.wallDamage or 0
"""


def explosive(root, swaps=None):
    tree = xd.Tree(root, swaps)
    lua, w, S = xd.load_world(tree)
    rows, findings = [], []

    # X1: every gun with a bullet blast, on 1 to 12 pellets.
    split = lua.execute("return function(...) " + X_SPLIT + " end")
    examined, guns, bad = 0, [], []
    for gid, d in sorted(S.WD.Weapons.items(), key=lambda kv: kv[0]):
        whole = split(S, d, 1)
        if whole is None or whole[0] is None:
            continue
        guns.append("%s (%s pellet%s)" % (gid, d.pellets or 1, "" if (d.pellets or 1) == 1 else "s"))
        dmg1, rad1, wall1 = whole
        ammo = d.explosiveAmmo
        if ammo is not None and (dmg1 != ammo.damage or rad1 != ammo.radius or wall1 != (ammo.wallDamage or 0)):
            bad.append("%s on 1 pellet: %s/%s/%s, not its ammo %s/%s/%s" % (gid, dmg1, rad1, wall1, ammo.damage, ammo.radius, ammo.wallDamage))
        for n in range(1, 13):
            dmg, rad, wall = split(S, d, n)
            examined += 1
            if abs(dmg * n - dmg1) > 1e-6 or abs(wall * n - wall1) > 1e-6:
                bad.append("%s on %d pellets: %d x %.3f = %.3f damage, %d x %.3f = %.3f wall (whole %s, %s)"
                           % (gid, n, n, dmg, dmg * n, n, wall, wall * n, dmg1, wall1))
            # Oliver 09-25: each pellet's blast is smaller than the whole gun's (unless that is 2 studs or
            # less already), and never under 2 studs.
            smaller = rad < rad1 - 1e-9 if (n > 1 and rad1 > 2) else rad <= rad1 + 1e-9
            if not smaller or rad < min(2, rad1) - 1e-9:
                bad.append("%s on %d pellets: radius %s (whole %s; smaller than the whole, never under 2)" % (gid, n, rad, rad1))
    rows.append(("X1 every gun with a bullet blast, on 1-12 pellets: the pellets' blasts add up to the whole (damage and wall "
                 "damage), each is smaller than the whole and never under 2 studs, one pellet is the ammo untouched",
                 len(bad) == 0 and examined > 0,
                 "%d gun(s) (%s), %d pellet counts examined: %s" % (len(guns), ", ".join(guns), examined,
                                                                   "all hold" if not bad else "; ".join(bad[:6]))))

    # FINDING: a round whose owner has left no longer flies on through the team-mate in front.
    rows_, hand, _vehicle = xd.inventory(S)
    scene_text = xd.SCENE.replace("for _ = 1, 480 do", "if S.leave then S.leave(shooter) end\nfor _ = 1, 480 do", 1)
    scene = lua.execute("return function(...) " + scene_text + " end")
    combatants = w.module("Combatants")
    real_exists = combatants.Exists
    leave = lua.execute("return function(C, real) return function(tok) tok.left = true end, "
                        "function(tok) return tok ~= nil and not tok.left and real(tok) end end")
    mark, exists = leave(combatants, real_exists)
    stopped = []
    rounds = [g for g in sorted(hand, key=lambda g: g["id"]) if g["route"] == "round"]
    try:
        for g in rounds:
            S.leave = None
            stay = xd.pyval(scene(w, S, g["id"], "mate+enemy"))
            S.leave = mark
            combatants.Exists = exists
            try:
                gone = xd.pyval(scene(w, S, g["id"], "mate+enemy"))
            finally:
                combatants.Exists = real_exists
                S.leave = None
            z_stay = sorted(round(b["z"], 1) for b in stay["blasts"].values())
            z_gone = sorted(round(b["z"], 1) for b in gone["blasts"].values())
            if z_gone != z_stay:
                stopped.append("%s bursts at z %s (owner here: z %s)" % (g["id"], z_gone, z_stay))
    finally:
        combatants.Exists = real_exists
    if stopped:
        findings.append("X2 a round whose owner leaves the server in flight bursts on the team-mate in front (z -15) instead of "
                        "flying on to the enemy (z -30): ProjectileService mateInTheWay asks creditable(entry.owner), not the "
                        "team stamped on the round (entry.ownerTeam). %d of %d launchers: %s"
                        % (len(stopped), len(rounds), "; ".join(stopped[:4])))
    return rows, findings


# ---------------------------------------------------------------------------------------------- C clocks

GAME_DIRS = ["ServerScriptService", "ReplicatedStorage", "StarterPlayerScripts", "StarterGui", "StarterCharacterScripts"]
CLOCK_CALL = {"tick": re.compile(r"\btick\(\s*\)"), "cpu": re.compile(r"\bos\.clock\(\s*\)")}
# `a = tick()`, `local a = os.clock() + x`, `x.a = tick()`, `{ a = tick(), ... }`: the name `a` reads that clock.
ASSIGN = re.compile(r"(?:\blocal\s+)?([A-Za-z_][\w.]*|\[[^\]]+\])\s*=\s*(?!=)([^,;{}]*)")
MIXING_OP = re.compile(r"(?<![-=<>~])(-|<=?|>=?)(?!=)")


def game_files(root):
    for d in GAME_DIRS:
        for dirpath, _, names in os.walk(os.path.join(root, d)):
            for n in sorted(names):
                if n.endswith(".lua"):
                    yield os.path.join(dirpath, n)


def code_lines(text):
    state, out = None, []
    for line in text.split("\n"):
        code, state = xd._strip(line, state)
        out.append(code)
    return out


def clock_of(expr, names):
    """The clock an expression reads: 'tick', 'cpu', or None (neither, or both)."""
    kinds = set()
    for kind, rx in CLOCK_CALL.items():
        if rx.search(expr):
            kinds.add(kind)
    bare = CLOCK_CALL["cpu"].sub(" ", CLOCK_CALL["tick"].sub(" ", expr))
    for ident in re.findall(r"[A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)*", bare):
        leaf = ident.split(".")[-1]
        kind = names.get(ident) or names.get("." + leaf)
        if kind in ("tick", "cpu"):
            kinds.add(kind)
    return kinds


def clock_scan(text):
    """Lines of `text` where one expression puts a tick() reading against an os.clock() reading.

    Plain names take the clock of their latest assignment (a local `now` is a different clock in different
    functions); a field (`entry.startedAt`, a table key) takes the clock of every assignment in the file,
    and a field set from both clocks is left out as ambiguous. Returns (sites examined, mixes, ambiguous fields)."""
    lines = code_lines(text)
    fields = {}
    for code in lines:
        for m in ASSIGN.finditer(code):
            target, expr = m.group(1), m.group(2)
            kinds = set(k for k, rx in CLOCK_CALL.items() if rx.search(expr))
            if len(kinds) == 1 and ("." in target or code.lstrip().startswith(target) is False or "{" in code):
                leaf = "." + target.split(".")[-1]
                fields.setdefault(leaf, set()).update(kinds)
    field_clock = {k: (next(iter(v)) if len(v) == 1 else "both") for k, v in fields.items()}
    ambiguous = sorted(k[1:] for k, v in field_clock.items() if v == "both")
    names = dict(field_clock)
    # A plain name only ever set from one clock in the file (an upvalue like `loadoutPushedAt`, read in one
    # function and set in another) reads that clock everywhere; the pass below still follows local re-sets.
    plain = {}
    for code in lines:
        for m in ASSIGN.finditer(code):
            target, expr = m.group(1), m.group(2)
            if "." not in target and not target.startswith("["):
                kinds = set(k for k, rx in CLOCK_CALL.items() if rx.search(expr))
                if kinds:
                    plain.setdefault(target, set()).update(kinds)
    unique = {k: next(iter(v)) for k, v in plain.items() if len(v) == 1}
    names.update(unique)
    examined, mixes = 0, []
    for number, code in enumerate(lines, 1):
        if not (CLOCK_CALL["tick"].search(code) or CLOCK_CALL["cpu"].search(code)
                or any(re.search(r"\b" + re.escape(k[1:]) + r"\b", code) for k, v in field_clock.items() if v != "both")
                or any(re.search(r"\b" + re.escape(k) + r"\b", code) for k in names if not k.startswith("."))):
            continue
        # Right-hand sides and conditions: every piece split at `=`/`,`/`and`/`or`/`then` is judged on its own.
        for piece in re.split(r"(?<![=<>~])=(?!=)|,|\band\b|\bor\b|\bthen\b|\bif\b|\breturn\b", code):
            if not MIXING_OP.search(piece):
                continue
            kinds = clock_of(piece, names)
            if kinds:
                examined += 1
            if kinds == {"tick", "cpu"}:
                mixes.append((number, code.strip()))
        # Then the assignments on this line update the plain names' clocks.
        for m in ASSIGN.finditer(code):
            target, expr = m.group(1), m.group(2)
            if "." in target or target.startswith("["):
                continue
            kinds = clock_of(expr, names)
            if len(kinds) == 1:
                names[target] = next(iter(kinds))
            elif target in names and not kinds and target not in unique:
                names.pop(target)
    return examined, mixes, ambiguous


def clocks(root, swaps=None):
    swaps = swaps or {}
    files, examined, mixes = 0, 0, []
    for path in game_files(root):
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        text = open(path, encoding="utf-8").read()
        for before, after in swaps.get(rel, []):
            if text.count(before) != 1:
                sys.exit("tonight_fixes_bugtest_check: plant anchor missing or not unique in %s: %r" % (rel, before[:80]))
            text = text.replace(before, after, 1)
        if "tick()" not in text and "os.clock()" not in text:
            continue
        files += 1
        n, found, _ = clock_scan(text)
        examined += n
        mixes += ["%s:%d  %s" % (rel, line, code[:110]) for line, code in found]
    rows = [("C1 no expression in the game puts a tick() reading against an os.clock() reading", not mixes,
             "%d files with a clock, %d clock expressions examined: %s" % (files, examined,
                                                                          "none mixed" if not mixes else " | ".join(mixes[:5])))]
    findings = []
    # The fix's file: os.clock() deadlines it left (CPU time, the lesson in COORDINATION.md).
    ms = open(os.path.join(root, "ServerScriptService", "Modules", "MovementService.lua"), encoding="utf-8").read()
    left = [str(i) for i, code in enumerate(code_lines(ms), 1) if CLOCK_CALL["cpu"].search(code)]
    if left:
        findings.append("C2 MovementService.lua still times with os.clock() on lines %s (the pad cooldown, the canopy's "
                        "settle and timeout, LastGlass, ClientParkour's 0.3 s gate); pc/clock-deadlines moved only the bot "
                        "glide and the parkour move to tick()" % ", ".join(left))
    return rows, findings


# ---------------------------------------------------------------------------------------------- M bot routes

M_WORLD = r"""
local block = ...
local V3mt = {}
V3mt.__index = V3mt
local function V3(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3mt) end
V3mt.__sub = function(a, b) return V3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3mt.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
V3mt.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    return rawget(V3mt, k)
end
local Enum = { PathWaypointAction = { Walk = "Walk", Jump = "Jump", Custom = "Custom" } }
local STATS = setmetatable({}, { __index = function() return 0 end })
local env = setmetatable({ Vector3 = { new = V3 }, Enum = Enum, STATS = STATS, ROOT_ABOVE_FLOOR = 3 }, { __index = _G })
local continueRoute, watchArrivals = assert(load(block, "BotNav", "t", env))()

local function signal()
    local s = { handlers = {} }
    function s:Connect(fn) table.insert(self.handlers, fn) return { Disconnect = function() end } end
    function s:Fire(...) for _, fn in ipairs(self.handlers) do fn(...) end end
    return s
end

-- One case: a bot handed waypoint 1 of three by its latest think, standing on it; `edit` changes one thing.
local function case(edit, reached)
    local points = { V3(0, 0, 0), V3(0, 0, -4), V3(0, 0, -8) }
    local waypoints = {}
    for i, p in ipairs(points) do waypoints[i] = { Position = p, Action = "Walk" } end
    local attrs = {}
    local humanoid = { Health = 100, HipHeight = 2, MoveToFinished = signal(), moves = {} }
    function humanoid:MoveTo(p) table.insert(self.moves, p) end
    local root = { Position = V3(0, 3, 0), Size = V3(2, 2, 1) }
    local character = { GetAttribute = function(_, k) return attrs[k] end,
        FindFirstChildOfClass = function(_, c) if c == "Humanoid" then return humanoid end end }
    local nav = { waypoints = waypoints, index = 1, moveTarget = points[1], handedAt = 10 }
    local bot = { character = character, nav = nav, thoughtAt = 10 }
    local t = { bot = bot, nav = nav, humanoid = humanoid, root = root, attrs = attrs, waypoints = waypoints, points = points }
    if edit then edit(t) end
    watchArrivals(bot, nav, humanoid, root)
    humanoid.MoveToFinished:Fire(reached ~= false)
    local first = humanoid.moves[1]
    local went = first ~= nil and first == points[2] and nav.index == 2
    -- Arriving again at the next point: does the chain carry on without a think?
    local chained = 0
    if first then
        chained = 1
        root.Position = V3(first.X, 3, first.Z)
        humanoid.MoveToFinished:Fire(true)
        if humanoid.moves[2] then chained = 2 end
    end
    return went, chained, #humanoid.moves
end

local out = {}
local function row(name, want, edit, reached)
    local went, chained, moves = case(edit, reached)
    table.insert(out, { name = name, want = want, got = went, chained = chained, moves = moves })
end
row("the plain case: arrived at the waypoint its latest think handed, the next is a walk", true, nil)
row("seated in a vehicle (SeatPart)", false, function(t) t.humanoid.SeatPart = {} end)
row("dead (Health 0)", false, function(t) t.humanoid.Health = 0 end)
row("mid-parkour (the Parkour attribute)", false, function(t) t.attrs.Parkour = "vault" end)
row("a think since the hand-out (thoughtAt later)", false, function(t) t.bot.thoughtAt = 10.3 end)
row("the next waypoint is a jump", false, function(t) t.waypoints[2].Action = "Jump" end)
row("a detour set", false, function(t) t.nav.detour = V3(5, 0, 0) end)
row("climbing", false, function(t) t.nav.climbing = true end)
row("the route replaced (bot.nav is a new table)", false, function(t) t.bot.nav = { waypoints = t.waypoints, index = 1 } end)
row("sent somewhere else since (moveTarget is not the waypoint)", false, function(t) t.nav.moveTarget = V3(9, 0, 9) end)
row("not at its waypoint (10 studs off)", false, function(t) t.root.Position = V3(10, 3, 0) end)
row("the route's last waypoint", false, function(t) t.nav.index = 3; t.nav.moveTarget = t.points[3]; t.root.Position = V3(0, 3, -8) end)
row("the route dropped (waypoints nil)", false, function(t) t.nav.waypoints = nil end)
row("MoveToFinished(false): gave up, not arrived", false, nil, false)
return out
"""


def bot_routes(root, swaps=None):
    path = os.path.join(root, "ServerScriptService", "Modules", "BotNav.lua")
    text = open(path, encoding="utf-8").read()
    for before, after in (swaps or {}).get("BotNav", []):
        if text.count(before) != 1:
            sys.exit("tonight_fixes_bugtest_check: plant anchor missing or not unique in BotNav: %r" % before[:80])
        text = text.replace(before, after, 1)
    parts = [xd.cut(text, "local ADVANCE_FLAT ="), xd.cut(text, "local ADVANCE_RISE ="),
             xd.cut(text, "local function footHeight("), xd.cut(text, "local function flatDistance("),
             xd.cut(text, "local function continueRoute("), xd.cut(text, "local function watchArrivals("),
             "return continueRoute, watchArrivals"]
    lua = LuaRuntime(unpack_returned_tuples=True)
    out = lua.execute("return function(...) " + M_WORLD + " end")(xd.luau_to_lua("\n".join(parts)))
    bad, cases, chained = [], 0, None
    for r in out.values():
        cases += 1
        if bool(r.got) != bool(r.want):
            bad.append("%s: %s" % (r.name, "continued" if r.got else "stood"))
        if r.want:
            chained = r.chained
    rows = [("M1 a bot's MoveToFinished continues its route only when it arrived at the waypoint its latest think "
             "handed and the next is a walk; seated, dead, mid-parkour, a think since, a jump next, a detour, climbing, "
             "a new route, sent elsewhere, off its waypoint, the route's end, a dropped route or a give-up all stand",
             not bad and cases > 1, "%d cases: %s" % (cases, "all as the fix says" if not bad else "; ".join(bad)))]
    findings = []
    if chained == 2:
        findings.append("M2 the continuation chains on without a think: arriving at waypoint 2 walks it on to waypoint 3 too "
                        "(nav.moveTarget follows each step), so a bot the LOD rarely thinks for walks its whole route between "
                        "thinks. That is the #99 fix working; noted because the comment says \"only from the waypoint it handed\"")
    return rows, findings


# ---------------------------------------------------------------------------------------------- run

def run_all(root, swaps=None):
    rows, findings = roadkill(root, swaps)
    for part in (explosive, clocks, bot_routes):
        r, f = part(root, swaps)
        rows += r
        findings += f
    return rows, findings


def sub(name, before, after):
    return {name: [(before, after)]}


PLANTS = [
    ("K1: the driver's client shelters a wreck's riders (RoadkillPass.Sheltered ignores Wrecked)",
     sub("RoadkillPass", 'if not model or model:GetAttribute("Wrecked") then', "if not model then")),
    ("K1: the server shelters the gunner's hatch (ShieldingVehicle reads every seat as the driver's)",
     sub("VehicleService", 'if entry and not entry.wrecked and VehicleArmor.Protects(model:GetAttribute("VehicleModel"), seat.Name) then',
         'if entry and not entry.wrecked and VehicleArmor.Protects(model:GetAttribute("VehicleModel"), "DriverSeat") then')),
    ("K1/K2: the armour covers the gunner too (VehicleArmor.Protects loses its gunner exception)",
     sub("VehicleArmor", 'return entry ~= nil and entry.cabin == "armored" and seatName ~= "GunnerSeat"',
         'return entry ~= nil and entry.cabin == "armored"')),
    ("X1: each pellet's blast carries the whole ammo's damage",
     sub("CombatService", "\t\t\tdamage = ammo.damage / pellets,\n", "\t\t\tdamage = ammo.damage,\n")),
    ("X1: each pellet's blast carries the whole ammo's wall damage",
     sub("CombatService", "\t\t\twallDamage = (ammo.wallDamage or 0) / pellets,\n", "\t\t\twallDamage = ammo.wallDamage or 0,\n")),
    ("X1: each pellet's blast at the whole ammo's radius",
     sub("CombatService", "radius = math.max(PELLET_BLAST_MIN_RADIUS, ammo.radius * PELLET_BLAST_RADIUS_SCALE),",
         "radius = ammo.radius,")),
    ("C1: a bot's glide stamped on os.clock again while stepDrops reads tick() (half of the fix undone)",
     sub("ServerScriptService/Modules/MovementService.lua", "onLanded = onLanded, startedAt = tick(),",
         "onLanded = onLanded, startedAt = os.clock(),")),
    ("C1: a shot in flight stamped on os.clock again while roundsInHand ages it on tick()",
     sub("StarterPlayerScripts/CombatClient.client.lua", "table.insert(shotsInFlight, { t = tick(),",
         "table.insert(shotsInFlight, { t = os.clock(),")),
    ("C1: the loadout push stamped on os.clock again (compared with the tick() shot stamps)",
     sub("StarterPlayerScripts/CombatClient.client.lua", "\tloadoutPushedAt = tick()\n", "\tloadoutPushedAt = os.clock()\n")),
    ("M1: a seated bot's route continues (the SeatPart guard gone)",
     sub("BotNav", "humanoid.Health <= 0 or humanoid.SeatPart", "humanoid.Health <= 0")),
    ("M1: a route continues after a later think (the thoughtAt guard gone)",
     sub("BotNav", "or (bot.thoughtAt or 0) > (nav.handedAt or -math.huge)", "or false")),
    ("M1: a route continues onto a jump waypoint (the Walk check gone)",
     sub("BotNav", "or following.Action ~= Enum.PathWaypointAction.Walk then", "then")),
]


def main():
    root = next((a for a in sys.argv[1:] if not a.startswith("--")), ".")
    if "--plant" in sys.argv:
        missed = 0
        for name, swaps in PLANTS:
            rows, _ = run_all(root, swaps)
            failed = [r for r in rows if not r[1]]
            if failed:
                print("  CAUGHT: %s -> %s" % (name, failed[0][0][:90]))
            else:
                missed += 1
                print("  MISSED: %s" % name)
        print("tonight_fixes_bugtest_check planted faults: %d/%d caught" % (len(PLANTS) - missed, len(PLANTS)))
        sys.exit(1 if missed else 0)
    rows, findings = run_all(root)
    for name, ok, detail in rows:
        print(("ok   " if ok else "FAIL ") + name + "  (" + detail + ")")
    for line in findings:
        print("  FINDING " + line)
    failed = sum(1 for r in rows if not r[1])
    print("tonight_fixes_bugtest_check: %d checks, %d failed, %d finding(s)" % (len(rows), failed, len(findings)))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
