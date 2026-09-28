"""#29 / #70: a blast's scorch never floats, and isn't a giant black pool.

Runs the REAL StarterPlayerScripts/ExplosiveFx.lua under lupa with tools/destruct_mocks.lua, in a
small world of box parts and a ground plane at y = 0 that a crater (a sphere of air, as
DestructibleService's Terrain:FillBall digs) can be cut into. ExplosiveFx.Explosion is called the
way ProjectileClient calls it, and the scorch patches it leaves are measured:

  A  open ground: the mark lies on the ground, and no wider than ExplosiveFx.ScorchWidest
  B  the server digs a crater under it a moment later: by a second on, no patch floats over the
     hole, and the middle one has gone down into it
  C  a blast near the edge of an upper floor: no patch hangs off the edge in the air
  D  that floor breaks (DestructibleService destroys the part): every patch is gone next frame

A patch "floats" when there is no solid within 0.3 studs under its centre along its own normal.
Then four faults are planted in the source, one per check, and each must be caught:
  crater relay off (B), casting off so patches lie flat like the old disc (C), riders off (D),
  the width cap removed (A).

    python3 tools/scorch_check.py .
"""
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".")

WORLD = r"""
return function(mock)
local ground = { crater = nil }
mock.world = ground
local boxes = {}
function mock.box(name, size, centre)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = CFrame.new(centre)
	p.Anchored = true
	p.Parent = workspace
	table.insert(boxes, p)
	return p
end
local function excluded(inst, params)
	for _, root in ipairs(params and params.FilterDescendantsInstances or {}) do
		if inst == root or inst:IsDescendantOf(root) then return true end
	end
	return false
end
local function solidGround(p)
	if p.Y > 0 then return false end
	local c = ground.crater
	if c and (p - c.centre).Magnitude < c.radius then return false end
	return true
end
mock.raycast = function(origin, direction, params)
	local best, bestT = nil, math.huge
	local len = direction.Magnitude
	for _, b in ipairs(boxes) do
		if b.Parent and not excluded(b, params) then
			local lo, hi = b.Position - b.Size / 2, b.Position + b.Size / 2
			local tmin, tmax, nrm = 0, 1, nil
			local ok = true
			for _, axis in ipairs({ "X", "Y", "Z" }) do
				local o, d = origin[axis], direction[axis]
				if math.abs(d) < 1e-9 then
					if o < lo[axis] or o > hi[axis] then ok = false end
				else
					local t1, t2 = (lo[axis] - o) / d, (hi[axis] - o) / d
					local n = d > 0 and -1 or 1
					if t1 > t2 then t1, t2 = t2, t1 end
					if t1 > tmin then
						tmin = t1
						nrm = Vector3.new(axis == "X" and n or 0, axis == "Y" and n or 0, axis == "Z" and n or 0)
					end
					tmax = math.min(tmax, t2)
				end
			end
			if ok and tmin <= tmax and nrm and tmin < bestT then
				bestT = tmin
				best = { Instance = b, Position = origin + direction * tmin, Normal = nrm, Material = b.Material }
			end
		end
	end
	-- The ground, marched.
	if not excluded(workspace.Terrain, params) then
		local steps = math.ceil(len / 0.02)
		for i = 0, steps do
			local t = i / steps
			if t >= bestT then break end
			local p = origin + direction * t
			if solidGround(p) then
				local c = ground.crater
				local n = Vector3.yAxis
				if c and (p - c.centre).Magnitude < c.radius + 0.05 then n = (c.centre - p).Unit end
				return { Instance = workspace.Terrain, Position = p, Normal = n, Material = Enum.Material.Grass }
			end
		end
	end
	return best
end
function workspace.Terrain.FillBall(_, centre, radius) ground.crater = { centre = centre, radius = radius } end

local fx = mock.fx
local function patches()
	local list = {}
	for _, c in ipairs(fx.Folder():GetChildren()) do
		if (c.Name == "Scorch" or c.Name == "ScorchEdge") and c.Transparency < 0.99 then table.insert(list, c) end
	end
	return list
end
local params = RaycastParams.new()
params.FilterDescendantsInstances = { fx.Folder() }
local function floats(p)
	local down = -p.CFrame.RightVector
	return mock.raycast(p.Position - down * 0.05, down * 0.35, params) == nil
end
local function report(tag)
	local list, floating, widest, centreY = patches(), 0, 0, nil
	local mid
	for _, p in ipairs(list) do
		if floats(p) then floating = floating + 1 end
		if p.Name == "Scorch" then centreY = p.Position.Y; mid = p.Position end
	end
	for _, p in ipairs(list) do
		for _, q in ipairs(list) do
			local a, b = p.Position, q.Position
			local flat = Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude + (p.Size.Y + q.Size.Y) / 2
			widest = math.max(widest, flat)
		end
	end
	return { n = #list, floating = floating, widest = widest, centreY = centreY or 99 }
end

return function()
	local out, fails = {}, {}
	local function fail(t) table.insert(fails, t) end
	local function say(s) table.insert(out, s) end
	fx.Paused = true

	-- A: open ground.
	fx.Clear(); ground.crater = nil
	local at = Vector3.new(0, 0.3, 0)
	fx.Explosion(at, Vector3.yAxis, "rocket", 13)
	fx.Advance(0.05)
	local r = report()
	say(string.format("A ground: %d patches, %d floating, %.2f studs across (cap %s)", r.n, r.floating, r.widest, tostring(fx.ScorchWidest)))
	if r.n < 5 or r.floating > 0 then fail("A the mark isn't lying on open ground") end
	if r.widest > 7.6 then fail("A the mark is wider than the cap") end

	-- B: the crater arrives (DestructibleService digs size = clamp(13 * 0.5 * 0.3, 1.5, 4.5)).
	workspace.Terrain:FillBall(Vector3.new(0, 0, 0), 1.95, Enum.Material.Air)
	for _ = 1, 40 do fx.Advance(1 / 30) end
	r = report()
	say(string.format("B crater dug: %d patches, %d floating, middle patch at y %.2f (was 0)", r.n, r.floating, r.centreY))
	if r.floating > 0 or r.centreY > -0.8 then fail("B the mark floats over the crater") end

	-- C: near the edge of an upper floor (x from -12 to 12, top at 12.5), blast 1.5 in from the edge.
	fx.Clear(); ground.crater = nil
	local floor = mock.box("UpperFloor", Vector3.new(24, 1, 24), Vector3.new(100, 12, 0))
	fx.Explosion(Vector3.new(110.5, 12.8, 0), Vector3.yAxis, "rocket", 13)
	fx.Advance(0.05)
	r = report()
	say(string.format("C floor edge: %d patches drawn, %d floating", r.n, r.floating))
	if r.n < 3 or r.floating > 0 then fail("C patches hang off the floor's edge") end

	-- D: the floor breaks.
	floor:Destroy()
	fx.Advance(1 / 60)
	r = report()
	say(string.format("D floor destroyed: %d patches left", r.n))
	if r.n > 0 then fail("D the mark outlived its floor") end
	return table.concat(out, "\n"), fails
end
end
"""


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w\.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def load_fx(fx_src):
    """The real ExplosiveFx on tools/destruct_mocks.lua, drawing realistic blasts: (lua, mock), mock.fx set.
    tools/scorch_sink_check.py builds its own world on this."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    mock = lua.execute((ROOT / "tools" / "destruct_mocks.lua").read_text(encoding="utf-8"))
    lua.execute(r"""
        local Vector3 = Vector3
        Vector3.xAxis = Vector3.xAxis or Vector3.new(1, 0, 0)
        Vector3.yAxis = Vector3.yAxis or Vector3.new(0, 1, 0)
        Vector3.zAxis = Vector3.zAxis or Vector3.new(0, 0, 1)
        Vector3.zero = Vector3.zero or Vector3.new(0, 0, 0)
        Vector3.one = Vector3.one or Vector3.new(1, 1, 1)
        Vector2 = { new = function(x, y) return { X = x, Y = y } end }
        require = function(module)
            -- The realistic blast: no silly-gun theme (ThemeFor nil), so ExplosiveFx draws its own look.
            if module and module.Name == "SillyExplosionFx" then
                return setmetatable({ ThemeFor = function() return nil end }, { __index = function() return function() end end })
            end
            return setmetatable({}, { __index = function() return function() return 0 end end })
        end
        -- ExplosiveFx's siblings (SillyExplosionFx since the silly guns): a folder the script sits in.
        local scripts = Instance.new("Folder")
        Instance.new("ModuleScript", scripts).Name = "SillyExplosionFx"
        script = { Parent = scripts }
        local shared = Instance.new("Folder", game:GetService("ReplicatedStorage"))
        shared.Name = "Shared"
        for _, n in ipairs({ "Ballistics", "SoundConfig" }) do Instance.new("ModuleScript", shared).Name = n end
    """)
    mock.fx = lua.execute(luau_to_lua(fx_src))
    return lua, mock


def run(fx_src):
    lua, mock = load_fx(fx_src)
    text, fails = lua.execute(WORLD)(mock)()
    return text, list(fails.values())


PLANTS = [
    ("crater relay off (B)", "local SCORCH_RELAY = { 0.3, 1, 2.5, 5 }", "local SCORCH_RELAY = {}", "B"),
    ("casting off, flat disc (C)", "local function layPatch(patch, centre, normal, flat)\n\tlocal mark = patch.mark\n\tif flat then",
     "local function layPatch(patch, centre, normal, flat)\n\tlocal mark = patch.mark\n\tif true then", "C"),
    ("riders off (D)", "ExplosiveFx.MarksFollow = true", "ExplosiveFx.MarksFollow = false", "D"),
    ("width cap removed (A)", "\tdiameter = math.min(diameter, SCORCH_WIDEST)\n", "\tdiameter = diameter * 2\n", "A"),
]


def main():
    src = (ROOT / "StarterPlayerScripts" / "ExplosiveFx.lua").read_text(encoding="utf-8")
    text, fails = run(src)
    print(text)
    bad = 0
    for f in fails:
        print("PROBLEM", f)
        bad += 1
    for name, old, new, tag in PLANTS:
        if old not in src:
            print("PROBLEM plant anchor missing:", name)
            bad += 1
            continue
        _, pf = run(src.replace(old, new, 1))
        caught = any(f.startswith(tag + " ") for f in pf)
        print(f"planted {name}: {'caught' if caught else 'NOT CAUGHT'} ({'; '.join(pf) or 'no failures'})")
        bad += 0 if caught else 1
    # #85: a supply crate's claim spills onto the ground like a chest (LootService's chest prompt),
    # never straight into the inventory. Read from source: the player's Triggered handler.
    supply = (ROOT / "ServerScriptService" / "Modules" / "SupplyDropService.lua").read_text(encoding="utf-8")
    for label, text, want in (("as is", supply, True), ("planted: GiveWeapon back in", supply.replace(
            "LootService.DropWeapon(def.id, spill", "WeaponService.GiveWeapon(player, def.id)\n\t\tLootService.DropWeapon(def.id, spill", 1), False)):
        start = text.index("prompt.Triggered:Connect(function(player)")
        handler = text[start:text.index("finishCrate(crate)", start)]
        into = re.findall(r"GiveWeapon|GiveOrDrop|GiveConsumable", handler)
        spills = all(f"{f}(" in handler for f in ("LootService.DropWeapon", "LootService.DropItem"))
        ok = spills and not into
        print(f"#85 supply claim ({label}): spills={spills}, into inventory={into or 'none'}")
        if ok != want:
            print("PROBLEM #85", "supply drop doesn't spill like a chest" if want else "planted inventory grant not caught")
            bad += 1
    print("scorch_check:", "OK" if bad == 0 else f"{bad} problem(s)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
