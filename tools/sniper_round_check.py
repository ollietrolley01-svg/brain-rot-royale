"""Task 17: sniper rifles fire real rounds (Ballistics "sniperRound") instead of hitscan.

Runs the game's REAL CombatService, ProjectileService, Ballistics, WeaponData (every pack merged) and
VehicleCover in lupa, in tools/explosive_dispatch_world.lua's world, through tools/sniper_round_check.lua's
scenes. Every player shot goes through the real CombatService.Fire and is stepped through the real
ProjectileService (its RoundState flight and its sweep). Where a scene says "same as hitscan", the very same
shot is fired a second time with the gun's `round` cleared, which is the hitscan firePellet it had before,
and the two outcomes are compared.

  A. Flight. Travel time and drop at 100, 300 and 600 studs from the real RoundState; a still target at
     each range is hit after that travel time (so it is not hitscan), with a headshot still a headshot at
     300. The speed options for Oliver (600 / 900 / 1200) come from the same maths.
  B. Damage. All five snipers at 30 studs, head and body: the round deals exactly what the hitscan shot
     dealt, with the same headshot flag. At 300 studs (a still target, body) too.
  C. Tunnelling. A 0.5-stud wall between the shooter and an enemy 30 studs behind it (past the ruling
     ray's 16-stud reach back, so only the sweep can stop the round), at 40 distances from 20 to 800 studs,
     stepped at 1/60, 1/30 and 0.1 s (the longest step ProjectileService takes: 90 studs): the wall is struck
     every time and the enemy behind it never takes anything. Also measured, not a check (every round kind
     has it): ProjectileService.sweep looks at most 8 things a step, so 8 panes inside one step let a round
     through the wall behind them.
  D. On-hit abilities. Pierce: three enemies in a line, the first two hit and the third not, as hitscan.
     Lifesteal (Nanna Nanna Puff) heals the shooter what hitscan healed. A killing round leaves the gun as
     the last attacker, so its killEffect (freeze) plays; Hose Down's hits carry its weaponId, which is what
     StatusEffects' chill reads. Six-Seven's bank shot off a wall reaches an enemy on the reflected line for
     the same damage as the hitscan bank.
  E. Rider cover. A rider behind a car body (VehicleCover "body"), behind glass ("glass", the round's
     ruling ray starts far enough back to cross it) and in the open: rider and vehicle damage the same as
     hitscan.
  F. Bots. BotService's own shootAt (cut from the real file): a hit roll fires a round that lands after
     its flight at the bot's damage scale, the same damage its hitscan roll dealt; a miss roll lands
     nothing; a target running steadily is still hit (the bot leads), and one that turns back at the shot
     dodges it.

    python tools/sniper_round_check.py .            the checks
    python tools/sniper_round_check.py . --plant    the planted faults; every one must be caught

Not covered: the look of the round and the feel of leading a shot (a Studio Play test), the ping cost (a
round is not rewound; see the PR), and the real VehicleCover.CrossesGlass geometry (stood in for by a plane
here; tools/rewound_cover_check.py covers the real panes). The world is boxes.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import explosive_dispatch_check as D  # noqa: E402  (the loader: real modules in lupa)

SNIPERS = ["LarilaSniper", "SixSevenMarksman", "DeadAirPrecision", "QuietHours", "HoseDownSniper"]


class Result:
    def __init__(self):
        self.rows, self.failed, self.lines = 0, [], []

    def check(self, ok, what):
        self.rows += 1
        if not ok:
            self.failed.append(what)

    def say(self, line):
        self.lines.append(line)


def close(a, b, tol=1e-6):
    return abs(a - b) <= tol * max(1.0, abs(a), abs(b))


def load(tree):
    lua, w, S = D.load_world(tree)
    harness = lua.execute("return function(...) " + open(os.path.join(HERE, "sniper_round_check.lua"), encoding="utf-8").read() + " end")
    H = harness(w, S)
    return lua, w, S, H


def flight(lua, w, S, H, R):
    B = S.B
    spec = B.Rounds["sniperRound"]
    g = 196.2
    R.check(spec is not None, "sniperRound is registered")
    V3 = w.M.Vector3.new
    rows = []
    for d in (100, 300, 600):
        t = B.RoundTimeFor(spec, d)
        pos = B.RoundState(spec, V3(0, 0, 0), V3(0, 0, -1), g, t)[0]
        rows.append((d, t, -pos.Y))
    R.say("A. flight (real RoundState, gravity 196.2): " + "; ".join("%d studs %.3f s, drop %.2f" % r for r in rows))
    for speed in (600, 900, 1200):
        R.say("   option %4d studs/s at gravityScale %.2f: 300 studs in %.3f s, drop %.2f studs; 600 in %.3f s, drop %.2f" % (
            speed, spec.gravityScale, 300 / speed, 0.5 * g * spec.gravityScale * (300 / speed) ** 2,
            600 / speed, 0.5 * g * spec.gravityScale * (600 / speed) ** 2))
    # Hit a still target at each range, head-high at 300 (the drop is inside the head), chest-high at 100/600.
    for d, aimY in ((100, 3.4), (300, 4.8), (600, 3.4)):
        H.reset()
        shooter = H.person("Shooter", 0, 0, "A")[0]
        shooter.isPlayer = True
        enemy = H.person("Enemy", 0, -d, "B", 1000)[0]
        at = H.fire(shooter, "LarilaSniper", V3(0, aimY, -d * 2), False)
        H.run(1 / 60, 3)
        amount, n, head, first = H.took(enemy)
        took = (first - at) if first else None
        want = d / spec.speed
        R.say("   still target at %d studs: hit %s after %s s (flight %.3f s), headshot %s" % (
            d, n, "%.3f" % took if took is not None else "-", want, head))
        R.check(n == 1 and took is not None and abs(took - want) <= 1 / 60 + 1e-6, "still target at %d: hit once, after the flight time" % d)
        R.check(took is not None and took >= 0.1, "a round at %d studs is not hitscan (took %s s)" % (d, took))
        if d == 300:
            R.check(head, "a head-centre shot at 300 studs is still a headshot (drop %.2f < 0.6)" % rows[1][2])


def damage(lua, w, S, H, R):
    V3 = w.M.Vector3.new
    out = []
    for gid in SNIPERS:
        for label, aimY, dist in (("head", 4.8, 30), ("body", 3.4, 30), ("body@300", 3.4, 300)):
            got = []
            for hitscan in (True, False):
                H.reset()
                shooter = H.person("Shooter", 0, 0, "A")[0]
                shooter.isPlayer = True
                enemy = H.person("Enemy", 0, -dist, "B", 5000)[0]
                H.fire(shooter, gid, V3(0, aimY, -dist * 2), hitscan)
                H.run(1 / 60, 3)
                amount, n, head, _ = H.took(enemy)
                got.append((amount, n, head))
            R.check(got[0][1] == 1 and got[1] == got[0], "%s %s: round %s == hitscan %s" % (gid, label, got[1], got[0]))
            out.append("%s %s %.1f%s" % (gid, label, got[1][0], "H" if got[1][2] else ""))
    R.say("B. damage, round == hitscan on every row: " + ", ".join(out))
    # Past the gun's reach (Hose Down, 420 studs) a hitscan shot did nothing; neither does the round.
    got = []
    for hitscan in (True, False):
        H.reset()
        shooter = H.person("Shooter", 0, 0, "A")[0]
        shooter.isPlayer = True
        enemy = H.person("Enemy", 0, -500, "B", 5000)[0]
        H.fire(shooter, "HoseDownSniper", V3(0, 4.8, -1000), hitscan)
        H.run(1 / 60, 3)
        got.append(H.took(enemy)[1])
    R.check(got == [0, 0], "Hose Down at 500 studs (reach 420): hitscan %d hit(s), round %d" % tuple(got))
    R.say("   past reach (Hose Down at 500, reach 420): hitscan %d hit(s), round %d" % tuple(got))


def tunnelling(lua, w, S, H, R):
    V3 = w.M.Vector3.new
    examined, passed = 0, []
    for dt in (1 / 60, 1 / 30, 0.1):
        for i in range(40):
            d = 20 + i * 19.7
            H.reset()
            shooter = H.person("Shooter", 0, 0, "A")[0]
            shooter.isPlayer = True
            H.box("ThinWall", V3(0, 4, -d), V3(20, 12, 0.5), lua.table_from({"destructible": True}))
            enemy = H.person("Enemy", 0, -d - 30, "B", 5000)[0]
            H.fire(shooter, "LarilaSniper", V3(0, 4.8, -d - 30), False)
            H.run(dt, 3)
            examined += 1
            amount, n, _, _ = H.took(enemy)
            walls = [h for h in H.wallHits.values() if h.name == "ThinWall"]
            if n or not walls:
                passed.append("dt %.3f wall at %.1f: enemy hits %d, wall hits %d" % (dt, d, n, len(walls)))
    R.check(not passed, "a 0.5-stud wall is never passed: %s" % passed[:3])
    # Not a sniper fault, reported: ProjectileService.sweep looks at most 8 things a step, and panes (and
    # anything non-colliding) each use one. Measured with N panes a stud apart before a wall, one 15-stud step.
    cap = []
    for n in (6, 7, 8, 9):
        H.reset()
        shooter = H.person("Shooter", 0, 0, "A")[0]
        shooter.isPlayer = True
        for i in range(n):
            H.box("WindowGlass", V3(0, 4, -31 - i), V3(20, 12, 0.2), lua.table_from({"destructible": True, "glass": True}))
        H.box("ThinWall", V3(0, 4, -31.5 - n), V3(20, 12, 0.5), lua.table_from({"destructible": True}))
        enemy = H.person("Enemy", 0, -60, "B", 5000)[0]
        H.fire(shooter, "LarilaSniper", V3(0, 4.8, -60), False)
        H.run(1 / 60, 3)
        cap.append("%d panes: %s" % (n, "wall passed" if H.took(enemy)[1] else "stopped"))
    R.say("   finding (ProjectileService.sweep's 8-cast cap, every round kind): " + ", ".join(cap))
    R.say("C. tunnelling: %d shots examined (40 distances 20-788 studs x steps 1/60, 1/30, 0.1 s = up to 90 studs a step), %d passed the wall" % (examined, len(passed)))


def abilities(lua, w, S, H, R):
    V3 = w.M.Vector3.new
    # Pierce: three in a line.
    got = []
    for hitscan in (True, False):
        H.reset()
        shooter = H.person("Shooter", 0, 0, "A")[0]
        shooter.isPlayer = True
        es = [H.person("E%d" % i, 0, -30 - 10 * i, "B", 5000)[0] for i in range(3)]
        H.fire(shooter, "LarilaSniper", V3(0, 3.4, -200), hitscan)
        H.run(1 / 60, 3)
        got.append(tuple(H.took(e)[1] for e in es))
    R.check(got[0] == (1, 1, 0) and got[1] == got[0], "pierce: hitscan %s, round %s (want 1,1,0)" % (got[0], got[1]))
    R.say("D. pierce (Larila, 3 in a line): hitscan %s, round %s" % (got[0], got[1]))

    # Lifesteal: Nanna Nanna Puff heals the shooter.
    heal = []
    for hitscan in (True, False):
        H.reset()
        shooter = H.person("Shooter", 0, 0, "A")[0]
        shooter.isPlayer = True
        hum = w.W.humanoids[shooter]
        hum.Health = 40
        H.person("Enemy", 0, -30, "B", 5000)
        H.fire(shooter, "QuietHours", V3(0, 3.4, -60), hitscan)
        H.run(1 / 60, 3)
        heal.append(hum.Health - 40)
    R.check(heal[0] > 0 and close(heal[0], heal[1]), "lifesteal: hitscan healed %.2f, round %.2f" % tuple(heal))
    R.say("   lifesteal (Nanna Nanna Puff): hitscan heals %.2f, round %.2f" % tuple(heal))

    # Kill effects: the round's kill leaves the gun as the last attacker (DeathFx reads it).
    kills = []
    for gid in SNIPERS:
        H.reset()
        shooter = H.person("Shooter", 0, 0, "A")[0]
        shooter.isPlayer = True
        enemy = H.person("Enemy", 0, -30, "B", 20)[0]
        H.fire(shooter, gid, V3(0, 4.8, -60), False)
        H.run(1 / 60, 3)
        _, weapon, _ = S.CS.GetLastAttacker(enemy)
        dead = w.W.humanoids[enemy].Health <= 0
        effect = S.WD.KillEffects[gid]
        R.check(dead and weapon == gid, "%s: the round's kill is credited to the gun (%s)" % (gid, weapon))
        kills.append("%s->%s" % (gid, effect))
    R.check(all(S.WD.KillEffects[g] == "freeze" for g in ("LarilaSniper", "SixSevenMarksman", "DeadAirPrecision", "QuietHours", "HoseDownSniper")),
            "the snipers' kill effect is freeze")
    R.say("   kills credited to the gun, so DeathFx plays its effect: " + ", ".join(kills))
    # Chill: StatusEffects reads WeaponData[weaponId].chill off the damage event.
    H.reset()
    shooter = H.person("Shooter", 0, 0, "A")[0]
    shooter.isPlayer = True
    H.person("Enemy", 0, -30, "B", 5000)
    H.fire(shooter, "HoseDownSniper", V3(0, 3.4, -60), False)
    H.run(1 / 60, 3)
    ids = [d.weaponId for d in H.dealt.values()]
    R.check(ids == ["HoseDownSniper"] and S.WD.Get("HoseDownSniper").chill is not None, "Hose Down's round hit carries its weaponId (%s)" % ids)
    R.say("   Hose Down's hit reaches the damage listeners as %s (StatusEffects' chill key)" % ids)

    # Six-Seven's bank: aim at a wall at an angle; an enemy stands on the reflected line.
    bank = []
    for hitscan in (True, False):
        H.reset()
        shooter = H.person("Shooter", 0, 0, "A")[0]
        shooter.isPlayer = True
        H.box("BankWall", V3(0, 4, -40.5), V3(400, 12, 1))
        # head (0, 4.8, 0) along (0.6, 0, -0.8): meets the wall face (z -40) at x 30, banks to (0.6, 0, 0.8)
        enemy = H.person("Enemy", 45, -20, "B", 5000)[0]
        H.fire(shooter, "SixSevenMarksman", V3(60, 4.8, -80), hitscan)
        H.run(1 / 60, 3)
        amount, n, head, _ = H.took(enemy)
        bank.append((round(amount, 3), n, head))
    R.check(bank[0][1] == 1 and bank[1] == bank[0], "bank shot: hitscan %s, round %s" % (bank[0], bank[1]))
    R.say("   Six-Seven bank off a wall onto an enemy: hitscan %s, round %s (amount, hits, headshot)" % (bank[0], bank[1]))


def riders(lua, w, S, H, R):
    V3 = w.M.Vector3.new
    VC = S.module("VehicleCover")
    out = []
    for case in ("body", "glass", "open"):
        got = []
        for hitscan in (True, False):
            H.reset()
            shooter = H.person("Shooter", 0, 0, "A")[0]
            shooter.isPlayer = True
            car = H.vehicle("Rotster")
            rider = H.person("Rider", 0, -60, "B", 5000)[0]
            H.seat(rider, car, "DriverSeat")
            if case == "body":
                H.box("Door", V3(0, 3.5, -56), V3(6, 3, 1), lua.table_from({"vehicleModel": car, "Parent": car}))
            elif case == "glass":
                # A pane 4 studs in front of the rider; glass is never in a ray (CanQuery off), so
                # CombatService asks VehicleCover.CrossesGlass about the shot's line.
                lua.execute("return function(VC) VC.CrossesGlass = function(_, from, to) return from.Z > -56 and to.Z < -56 end end")(VC)
            H.fire(shooter, "LarilaSniper", V3(0, 3.4, -120), hitscan)
            H.run(1 / 60, 3)
            amount, n, _, _ = H.took(rider)
            got.append((round(amount, 3), round(sum(H.vehicleHits.values()), 3)))
        R.check(got[0][0] > 0 and got[1] == got[0], "rider %s: hitscan %s, round %s (rider, vehicle)" % (case, got[0], got[1]))
        out.append("%s rider/vehicle hitscan %s round %s" % (case, got[0], got[1]))
    R.say("E. rider cover (Rotster driver): " + "; ".join(out))


def bots(lua, w, S, H, R, tree):
    V3 = w.M.Vector3.new
    block = D.bot_source(tree)
    shootAt, usable, env = lua.execute("return function(...) " + D.BOT_ENV + " end")(w, S, block)
    # BOT_ENV leaves Vector3 to a stand-in (its scenes only roll hits); a miss offset needs the real one.
    env.Vector3 = w.M.Vector3
    MC = S.module("MatchConfig")
    gid = "LarilaSniper"
    R.check(bool(usable(S.WD.Get(gid))), "bots may still hold a sniper (BotService.Loot.usable)")

    def scene(roll, hitscan, move=None):
        H.reset()
        model, root = w.M.character("Bot", w.M.CFrame.new(0, 3, 0))
        bot = lua.table_from({"name": "Bot", "Character": model, "team": "A", "nextShotAt": 0, "burstLeft": 3, "acquiredAt": 0, "isBot": True})
        bot.weapon = S.WD.Get(gid)
        w.W.tokens[model] = bot
        w.W.humanoids[bot] = w.M.instance("Humanoid", "Humanoid", model, lua.table_from({"Health": 100, "MaxHealth": 100}))
        target, tmodel, troot = H.person("Target", 0, -300, "B", 5000)
        each = None
        if move:
            vx, turn = move
            H.setVelocity(troot, V3(vx, 0, 0))

            def each(t):
                x = vx * (t if not turn else -t)
                H.moveRoot(troot, x, -300)
        def_ = S.WD.Get(gid)
        saved = def_.round
        if hitscan:
            def_.round = None
        env.roll.v = roll
        w.now.t = w.now.t + 60
        at = w.now.t
        shootAt(bot, target, troot, 300, model.FindFirstChild(model, "Head"))
        def_.round = saved
        H.run(1 / 60, 3, each)
        amount, n, head, first = H.took(target)
        return amount, n, head, (first - at) if first else None

    hs = scene(0.01, True)
    rd = scene(0.01, False)
    R.check(hs[1] == 1 and rd[1] == 1 and close(hs[0], rd[0]), "bot hit roll: round %s == hitscan %s" % (rd[:3], hs[:3]))
    R.check(rd[3] is not None and rd[3] >= 0.25, "a bot's sniper round flies (landed after %s s)" % rd[3])
    miss = scene(0.99, False)
    R.check(miss[1] == 0, "bot miss roll lands nothing (%s)" % (miss,))
    run = scene(0.01, False, (18, False))
    dodge = scene(0.01, False, (18, True))
    R.check(run[1] == 1, "a bot leads a steady runner and hits (%s)" % (run,))
    R.check(dodge[1] == 0, "a runner who turns back at the shot dodges it (%s)" % (dodge,))
    R.say("F. bots (shootAt, Larila at 300 studs, BotDamageScale %.2f): hit roll hitscan %.1f, round %.1f after %.3f s; "
          "miss roll %d hits; steady runner %d hit; runner turning back %d hits" % (
              MC.BotDamageScale, hs[0], rd[0], rd[3] or -1, miss[1], run[1], dodge[1]))


def sources(tree, R):
    cs = tree.text("CombatService")
    bal = tree.text("Ballistics")
    pierce = re.search(r"local PIERCE_TARGETS = (\d+)", cs)
    mine = re.search(r"Ballistics\.SniperRound = \{[^}]*\bpierce = (\d+)", bal)
    R.check(pierce and mine and pierce.group(1) == mine.group(1),
            "the round pierces as many bodies as hitscan (PIERCE_TARGETS %s, SniperRound.pierce %s)" % (
                pierce and pierce.group(1), mine and mine.group(1)))


def run(root, swaps=None):
    tree = D.Tree(root, swaps)
    lua, w, S, H = load(tree)
    R = Result()
    sources(tree, R)
    for part in (flight, damage, tunnelling, abilities, riders):
        part(lua, w, S, H, R)
    bots(lua, w, S, H, R, tree)
    return R


PLANTS = [
    ("the sweep lets a solid part through", {"ProjectileService": [(
        "elseif instance:IsA(\"BasePart\") and not instance.CanCollide and not combatantOf(instance) then",
        "elseif not combatantOf(instance) then")]}),
    ("a round is tested only where each step ends (no swept path)", {"ProjectileService": [(
        "local hit = sweep(entry, entry.position, spec.radius, displacement)",
        "local hit = sweep(entry, position - displacement.Unit * 0.05, spec.radius, displacement.Unit * 0.05)")]}),
    ("Fire no longer launches a sniper's round (hitscan again)", {"CombatService": [(
        "if (def.projectile or def.round) and CombatService.LaunchProjectile then",
        "if def.projectile and CombatService.LaunchProjectile then")]}),
    ("the round is effectively instant", {"Ballistics": [(
        "\tspeed = 900,\n\tgravityScale = 0.05,\n\tradius = 0.1,", "\tspeed = 90000,\n\tgravityScale = 0.05,\n\tradius = 0.1,")]}),
    ("the ruling ray starts at the contact (a rider's glass is off it)", {"Ballistics": [(
        "Ballistics.SniperRound = { back = 16,", "Ballistics.SniperRound = { back = 0.3,")]}),
    ("the ruling drops the gun's ability (lifesteal lost)", {"CombatService": [(
        "ability = def.ability ~= \"pierce\" and def.ability or false,", "ability = false,")]}),
    ("the round pierces one body more than hitscan", {"Ballistics": [(
        "minBack = 0.25, past = 0.5, pierce = 2,", "minBack = 0.25, past = 0.5, pierce = 3,")]}),
    ("the round never banks", {"Ballistics": [(
        "elseif struck == \"map\" and def.ricochet and api.Launch then", "elseif false then")]}),
    ("a bot's round skips BotDamageScale", {"BotService": [(
        "local scaled = setmetatable({ damage = def.damage * MatchConfig.BotDamageScale }, { __index = def })",
        "local scaled = def")]}),
    ("a bot fires at where the target is, not where it will be", {"BotService": [(
        "aimAt = projectiles.LeadAim(def.id, head.Position, aimAt, targetRoot.AssemblyLinearVelocity)",
        "aimAt = aimAt")]}),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    if "--plant" in sys.argv:
        caught = 0
        for name, swaps in PLANTS:
            R = run(root, swaps)
            ok = bool(R.failed)
            caught += ok
            print("  %s  %s%s" % ("caught" if ok else "MISSED", name, (": " + R.failed[0]) if ok else ""))
        print("sniper_round_check --plant: %d/%d planted faults caught" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    R = run(root)
    for line in R.lines:
        print(line)
    for f in R.failed:
        print("  FAIL: " + f)
    print("sniper_round_check: %d checks, %d failed" % (R.rows, len(R.failed)))
    sys.exit(1 if R.failed else 0)


if __name__ == "__main__":
    main()
