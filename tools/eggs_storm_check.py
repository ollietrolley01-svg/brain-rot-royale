#!/usr/bin/env python3
"""Headless geometry check for the easter eggs (#41, #42) and the storm wall (#45).

Runs the REAL source of ServerScriptService/Modules/EasterEggs.lua and
StarterPlayerScripts/StormClient.client.lua under lupa, on the stand-in Roblox types in
tools/eggs_rbx_mock.lua.part, and measures what they build. It cannot render anything: it proves the
numbers a render would otherwise have to be squinted at, and tools/eggs_gallery.lua is still the
picture (see the end of this docstring).

    python3 tools/eggs_storm_check.py .            # the tree as it is
    python3 tools/eggs_storm_check.py . --ref HEAD~2   # also report a git ref's numbers as "before"

Checks (each carries a permanent planted fault, run every time):
  * FLUSH: pairs of box faces pointing the same way, within 0.03 of one plane and overlapping
    (sampled 5x5 over each face). That is the z-fight shape. Planted: two slabs 0.01 apart.
  * FOOTPRINT: every visible part of an egg inside its declared `footprint` radius (plus 0.1),
    measured shape-true (cylinders round their end circles, balls as centre plus radius, sphere
    meshes over their ellipsoid, everything else by its corners). Planted: a part 3 studs past the
    SixSeven footprint; a 46-stud disc must read 23, not its box's 32.5; a ball reads centre + radius.
  * FLUSH and FOOTPRINT are asserted for EVERY egg (#42), each line naming how many parts it examined.
    Against the tree before #42 this fails 10 checks (Camp 22 flush, Obby 16, Arrest 26.2/20, ...).
  * ARREST ARMS (#41): every limb (a decor Fabric block, square across, over twice as long as it
    is wide) has a Ball joint over BOTH ends, so no arm stops in mid-air. Planted: a limb with no
    joint at its far end.
  * ARREST ROOF (#41): each slate slab's underside centre lies on an attic wedge's slope (within
    0.02), and its inner end's top edge is under the ridge cap. Planted: a slab lifted 0.3.
  * SIXSEVEN GLOVES (#42): at the bottom of its bob a glove's lowest point stays above its
    pedestal cap. Planted: the same test against a cap 1.5 higher.
  * STORM (#45): exactly 192 BaseParts wider than a stud in StormWall (the arena gallery's
    contract, tools/arena_gallery.lua:571-580), the first child on the ring, no flush pair between
    a wall and its band, at most 24 emitters, only those within range of the camera running, the
    live-particle ceiling (sum of Rate x max Lifetime over running emitters) under 300, and an
    Idle broadcast takes the ring down with every emitter off. Planted: the ring's own parts plus
    one band pulled onto its wall's face must produce a flush pair.

Not proved here: how any of it LOOKS. Oliver's machine renders it with
    powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/eggs_gallery.lua -OutDir <folder> -PlaceFile <private build>
with EasterEggsBefore / StormClientBefore copied from the ref before these commits into that
private place only (the gallery's own header explains).
"""
import os
import re
import subprocess
import sys

from lupa import LuaRuntime

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else ".")
REF = None
if "--ref" in sys.argv:
    REF = sys.argv[sys.argv.index("--ref") + 1]

EGGS = "ServerScriptService/Modules/EasterEggs.lua"
STORM = "StarterPlayerScripts/StormClient.client.lua"


def read(path, ref=None):
    if ref:
        return subprocess.run(["git", "-C", ROOT, "show", f"{ref}:{path}"], capture_output=True, text=True, check=True).stdout
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


def to_lua(source):
    """Luau's compound assignment is not Lua 5.4: `a.b += c` becomes `a.b = a.b + (c)`."""
    return re.sub(r"^(\s*)([\w\.\[\]\"]+)\s*([+\-*/])=\s*(.+?)\s*$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


ANALYSIS = r"""
local A = {}

local function boxes(model)
	local out = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.ClassName == "Part" and d.Shape == "PartType.Block" and d.Transparency < 1
			and not d:FindFirstChildOfClass("SpecialMesh") then
			table.insert(out, d)
		end
	end
	return out
end
A.boxes = boxes

local AXES = { { "RightVector", "X", "UpVector", "Y", "LookVector", "Z" }, { "UpVector", "Y", "RightVector", "X", "LookVector", "Z" },
	{ "LookVector", "Z", "RightVector", "X", "UpVector", "Y" } }
local function faces(part)
	local c, s, out = part.CFrame, part.Size, {}
	for _, ax in ipairs(AXES) do
		for _, sign in ipairs({ -1, 1 }) do
			local n = c[ax[1]] * sign
			table.insert(out, { n = n, c = c.Position + n * (s[ax[2]] / 2), u = c[ax[3]], hu = s[ax[4]] / 2, v = c[ax[5]], hv = s[ax[6]] / 2 })
		end
	end
	return out
end

local function radiusOf(part)
	return part.Size.Magnitude / 2
end

function A.flushPairs(parts)
	local pairsFound, list = 0, {}
	local fs = {}
	for i, p in ipairs(parts) do fs[i] = faces(p) end
	for i = 1, #parts do
		for j = i + 1, #parts do
			local a, b = parts[i], parts[j]
			if (a.Position - b.Position).Magnitude <= radiusOf(a) + radiusOf(b) + 0.05 then
				local hit = false
				for _, fa in ipairs(fs[i]) do
					for _, fb in ipairs(fs[j]) do
						-- A face lying on the ground plane pointing down is against the terrain and never seen.
						local grounded = fa.n.Y < -0.999 and math.abs(fa.c.Y) < 0.05
						if not hit and not grounded and fa.n:Dot(fb.n) > 0.9999 and math.abs((fb.c - fa.c):Dot(fa.n)) < 0.03 then
							for si = -2, 2 do
								for sj = -2, 2 do
									local q = fa.c + fa.u * (si / 2.5 * fa.hu) + fa.v * (sj / 2.5 * fa.hv)
									local d = q - fb.c
									if math.abs(d:Dot(fb.u)) < fb.hu - 1e-3 and math.abs(d:Dot(fb.v)) < fb.hv - 1e-3 then
										hit = true
									end
								end
							end
						end
					end
				end
				if hit then
					pairsFound = pairsFound + 1
					if #list < 20 then table.insert(list, string.format("%s(%.2f,%.2f,%.2f)@(%.2f,%.2f,%.2f)/%s(%.2f,%.2f,%.2f)@(%.2f,%.2f,%.2f)", a.Material, a.Size.X, a.Size.Y, a.Size.Z,
						a.Position.X, a.Position.Y, a.Position.Z, b.Material, b.Size.X, b.Size.Y, b.Size.Z, b.Position.X, b.Position.Y, b.Position.Z)) end
				end
			end
		end
	end
	return pairsFound, list
end

-- How far one part's visible surface reaches across the ground from `origin`. Shape-true, because
-- the question is "does the egg stay on its levelled site" and a box's corners overstate a round
-- thing by up to 41% (a 46-stud ripple disc read 32.5 against its true 23): a Cylinder is sampled
-- round both end circles (its length is its X axis), a Ball is its centre plus radius, a block with
-- a sphere mesh is sampled over its ellipsoid, and everything else (blocks, wedges) by its corners.
local function partReach(part, origin)
	local c, s = part.CFrame, part.Size
	local worst = 0
	local function at(p)
		worst = math.max(worst, Vector3.new(p.X - origin.X, 0, p.Z - origin.Z).Magnitude)
	end
	local mesh = part:FindFirstChildOfClass("SpecialMesh")
	if part.Shape == "PartType.Cylinder" then
		local r = math.min(s.Y, s.Z) / 2
		for _, x in ipairs({ -1, 1 }) do
			for k = 0, 63 do
				local t = k / 64 * math.pi * 2
				at(c * Vector3.new(x * s.X / 2, math.cos(t) * r, math.sin(t) * r))
			end
		end
	elseif part.Shape == "PartType.Ball" then
		local p = c.Position
		worst = Vector3.new(p.X - origin.X, 0, p.Z - origin.Z).Magnitude + math.min(s.X, s.Y, s.Z) / 2
	elseif mesh then
		for i = 0, 8 do
			local phi = i / 8 * math.pi
			for k = 0, 31 do
				local t = k / 32 * math.pi * 2
				at(c * Vector3.new(math.sin(phi) * math.cos(t) * s.X / 2, math.cos(phi) * s.Y / 2, math.sin(phi) * math.sin(t) * s.Z / 2))
			end
		end
	else
		for _, x in ipairs({ -1, 1 }) do for _, y in ipairs({ -1, 1 }) do for _, z in ipairs({ -1, 1 }) do
			at(c * Vector3.new(x * s.X / 2, y * s.Y / 2, z * s.Z / 2))
		end end end
	end
	return worst
end

-- Returns the worst reach, how many visible parts were examined, and up to 20 of those past `limit`.
function A.reach(model, origin, limit)
	local worst, examined, over = 0, 0, {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency < 1 then
			examined = examined + 1
			local r = partReach(part, origin)
			worst = math.max(worst, r)
			if limit and r > limit and #over < 20 then
				table.insert(over, string.format("%s %s(%.2f,%.2f,%.2f)@(%.1f,%.1f,%.1f) reach %.2f", part.Material, part.Shape,
					part.Size.X, part.Size.Y, part.Size.Z, part.Position.X - origin.X, part.Position.Y, part.Position.Z - origin.Z, r))
			end
		end
	end
	return worst, examined, over
end

function A.limbsWithoutJoints(model)
	local balls, limbs = {}, 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Shape == "PartType.Ball" then table.insert(balls, d) end
	end
	local bad = 0
	for _, d in ipairs(model:GetDescendants()) do
		local s = d:IsA("BasePart") and d.Size
		if s and d.ClassName == "Part" and d.Shape == "PartType.Block" and d.Material == "Material.Fabric" and not d.CanCollide
			and math.abs(s.X - s.Z) < 1e-6 and s.Y > 1.3 * s.X then
			limbs = limbs + 1
			for _, sign in ipairs({ -1, 1 }) do
				local tip = d.Position + d.CFrame.UpVector * (sign * s.Y / 2)
				local covered = false
				for _, ball in ipairs(balls) do
					if (ball.Position - tip).Magnitude < ball.Size.X / 2 - 0.05 then covered = true end
				end
				if not covered then bad = bad + 1 end
			end
		end
	end
	return limbs, bad
end

function A.roof(model)
	local wedges, slabs, cap = {}, {}, nil
	for _, d in ipairs(model:GetDescendants()) do
		if d.ClassName == "WedgePart" then table.insert(wedges, d)
		elseif d:IsA("BasePart") and d.Material == "Material.Slate" then
			if math.abs(d.Size.Y - 0.5) < 1e-6 then table.insert(slabs, d) elseif math.abs(d.Size.Y - 0.8) < 1e-6 then cap = d end
		end
	end
	local worstGap, uncapped = 0, 0
	for _, slab in ipairs(slabs) do
		local under = slab.CFrame * Vector3.new(0, -slab.Size.Y / 2, 0)
		local best = math.huge
		for _, w in ipairs(wedges) do
			local l = w.CFrame:PointToObjectSpace(under)
			local Y, Z = w.Size.Y, w.Size.Z
			if math.abs(l.X) <= w.Size.X / 2 + 0.01 and math.abs(l.Z) <= Z / 2 + 0.01 then
				best = math.min(best, math.abs(l.Y / Y - l.Z / Z) / math.sqrt(1 / (Y * Y) + 1 / (Z * Z)))
			end
		end
		worstGap = math.max(worstGap, best)
		-- The inner end's top edge: whichever end of the slab is nearer the cap.
		for _, x in ipairs({ -1, 1 }) do
			local top = slab.CFrame * Vector3.new(x * slab.Size.X / 2, slab.Size.Y / 2, 0)
			if cap and (top - cap.Position).Magnitude < 2 then
				local l = cap.CFrame:PointToObjectSpace(top)
				if math.abs(l.X) > cap.Size.X / 2 or math.abs(l.Y) > cap.Size.Y / 2 then uncapped = uncapped + 1 end
			end
		end
	end
	return #wedges, #slabs, worstGap, uncapped
end

function A.gloveClearance(model, capLift)
	-- Every bobbing part's lowest point at the bottom of its bob, against the top of the nearest
	-- neon cap under it.
	local caps, worst = {}, math.huge
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Material == "Material.Neon" and d.Shape == "PartType.Cylinder" then table.insert(caps, d) end
	end
	for _, d in ipairs(model:GetDescendants()) do
		local bobH = d:IsA("BasePart") and d:GetAttribute("BobHeight")
		if bobH and d.Name ~= "SwayHull" then
			local low = math.huge
			local c, s = d.CFrame, d.Size
			for _, x in ipairs({ -1, 1 }) do for _, y in ipairs({ -1, 1 }) do for _, z in ipairs({ -1, 1 }) do
				low = math.min(low, (c * Vector3.new(x * s.X / 2, y * s.Y / 2, z * s.Z / 2)).Y)
			end end end
			for _, cap in ipairs(caps) do
				if Vector3.new(cap.Position.X - d.Position.X, 0, cap.Position.Z - d.Position.Z).Magnitude < 3 then
					-- An upright cylinder's height is its X size.
					worst = math.min(worst, low - bobH - (cap.Position.Y + cap.Size.X / 2 + capLift))
				end
			end
		end
	end
	return worst
end

return A
"""


def fresh():
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(ROOT, "tools", "eggs_rbx_mock.lua.part"), encoding="utf-8") as handle:
        lua.execute(handle.read())
    return lua


def run_eggs(source):
    lua = fresh()
    lua.execute("""
        script = { Parent = { WaitForChild = function(_, name) return name end } }
        local realRequire = require
        require = function(m) if type(m) == 'string' and not m:find('%.') then return { SurfaceLift = 2 } end return realRequire(m) end
    """)
    module = lua.execute(to_lua(source))
    analysis = lua.execute(to_lua(ANALYSIS))
    parent = lua.eval("Instance.new('Folder')")
    models = module.BuildAll(parent, lua.eval("Vector3.new(0, 0, 0)"), 90)
    warnings = lua.eval("MockWarnings or 0")
    footprints = {m.group(1): float(m.group(2)) for m in re.finditer(r'id = "(\w+)".*?footprint = ([\d.]+)', source)}
    result = {"warnings": warnings, "eggs": {}}
    for index in range(1, len(models) + 1):
        model = models[index]
        origin = lua.eval(f"Vector3.new({(index - 1) * 90}, 0, 0)")
        parts = [d for d in model.GetDescendants(model).values() if d.IsA(d, "BasePart")]
        boxes = analysis.boxes(model)
        flush, examples = analysis.flushPairs(boxes)
        footprint = footprints.get(model.Name)
        reach, examined, over = analysis.reach(model, origin, (footprint or 0) + 0.1)
        result["eggs"][model.Name] = {
            "parts": len(parts), "boxes": len(list(boxes.values())), "flush": flush, "examples": list(examples.values()),
            "reach": reach, "reached": examined, "over": list(over.values()),
            "footprint": footprint, "model": model, "origin": origin,
        }
    return lua, analysis, result


def run_storm(source):
    lua = fresh()
    lua.execute("""
        StormEvent = MockSignal()
        RenderStepped = MockSignal()
        PlayedCues = {}
        local stubs = {
            Remotes = { Event = function() return { OnClientEvent = StormEvent } end },
            MatchConfig = { LobbyPosition = Vector3.new(0, 500, 0) },
            Sfx = { Play = function(name) table.insert(PlayedCues, name) end },
        }
        local shared = { WaitForChild = function(_, name) return name end }
        local rs = { WaitForChild = function() return shared end }
        LocalRoot = Instance.new("Part")
        LocalRoot.Name = "HumanoidRootPart"
        local character = Instance.new("Model")
        LocalRoot.Parent = character
        local players = { LocalPlayer = { Character = character } }
        local get = game.GetService
        game.GetService = function(self, name)
            if name == 'ReplicatedStorage' then return rs end
            if name == 'RunService' then return { RenderStepped = RenderStepped } end
            if name == 'Players' then return players end
            return get(self, name)
        end
        script = { Parent = { WaitForChild = function(_, name) return name end } }
        require = function(m) return stubs[m] or error('no stub for ' .. tostring(m)) end
    """)
    lua.execute(to_lua(source))
    analysis = lua.execute(to_lua(ANALYSIS))
    return lua, analysis


def storm_numbers(lua, analysis, camera, root):
    lua.execute(f"workspace.CurrentCamera.CFrame = CFrame.new({camera}); LocalRoot.CFrame = CFrame.new({root})")
    lua.execute("StormEvent:Fire({ status = 'Shrinking', center = Vector3.new(0, 0, 0), radius = 175 })")
    lua.execute("for _ = 1, 60 do RenderStepped:Fire(1 / 60) end")
    wall = lua.eval("workspace:FindFirstChild('StormWall')")
    out = {"up": wall is not None}
    if wall is None:
        return out
    kids = list(wall.GetChildren(wall).values())
    wide = [k for k in kids if k.IsA(k, "BasePart") and k.Size.X > 1]
    first = kids[0]
    out["wide"] = len(wide)
    out["first_r"] = (first.Position.X ** 2 + first.Position.Z ** 2) ** 0.5
    emitters = [d for d in wall.GetDescendants(wall).values() if d.ClassName == "ParticleEmitter"]
    running = [e for e in emitters if e.Enabled]
    out["emitters"], out["running"] = len(emitters), len(running)
    out["ceiling"] = sum(e.Rate * e.Lifetime[2] for e in running)
    # A wall and its band are the same index: children go wall, band, wall, band...
    tbl = lua.table_from(wide)
    flush, _ = analysis.flushPairs(tbl)
    out["flush"] = flush
    out["cues"] = list(lua.eval("PlayedCues").values())
    return out


def main():
    failures, checks = 0, 0

    def check(ok, text):
        nonlocal failures, checks
        checks += 1
        if not ok:
            failures += 1
        print(("PASS  " if ok else "FAIL  ") + text)

    # ---- eggs -------------------------------------------------------------------------------
    if REF:
        _, _, before = run_eggs(read(EGGS, REF))
        print(f"before ({REF}):")
        for name, e in before["eggs"].items():
            print(f"  {name:11s} parts {e['parts']:4d}  flush {e['flush']:3d}  reach {e['reach']:5.1f} / {e['footprint']}")
    lua, A, now = run_eggs(read(EGGS))
    print("now:")
    for name, e in now["eggs"].items():
        print(f"  {name:11s} parts {e['parts']:4d}  flush {e['flush']:3d}  reach {e['reach']:5.1f} / {e['footprint']}"
              + (f"  e.g. {e['examples'][:3]}" if e["flush"] else ""))
    check(now["warnings"] == 0 and len(now["eggs"]) == 10, f"all {len(now['eggs'])} eggs build with {now['warnings']} warnings")

    # #42: every egg, not just the ones last worked on, is held at zero flush pairs and inside its
    # declared footprint. Each line names how many parts it examined, so a filter that matched nothing
    # can't read as a clean sweep.
    for name, e in now["eggs"].items():
        check(e["boxes"] > 0 and e["flush"] == 0,
              f"{name}: {e['flush']} flush face pairs among {e['boxes']} boxes" + (f"  e.g. {e['examples'][:2]}" if e["flush"] else ""))
        check(e["footprint"] is not None and e["reached"] > 0 and e["reach"] <= e["footprint"] + 0.1,
              f"{name}: {e['reached']} visible parts reach {e['reach']:.2f} from its centre, footprint {e['footprint']}"
              + (f"  past it: {e['over'][:2]}" if e["over"] else ""))

    six = now["eggs"]["SixSeven"]
    check(six["flush"] == 0, f"SixSeven: {six['flush']} flush face pairs among {len(list(A.boxes(six['model']).values()))} boxes")
    check(six["reach"] <= six["footprint"] + 0.1, f"SixSeven: reaches {six['reach']:.2f} from its centre, footprint {six['footprint']}")
    clearance = A.gloveClearance(six["model"], 0)
    check(0 < clearance < 5, f"SixSeven: a glove at the bottom of its bob clears its pedestal cap by {clearance:.2f}")
    if REF:
        for name, e in now["eggs"].items():
            old = before["eggs"].get(name)
            if old:
                check(e["flush"] <= old["flush"], f"{name}: flush pairs {old['flush']} -> {e['flush']} (no egg gains one)")

    arrest = now["eggs"]["Arrest"]
    limbs, bare = A.limbsWithoutJoints(arrest["model"])
    check(limbs >= 12 and bare == 0, f"Arrest arms: {limbs} limbs examined, {bare} ends without a joint over them")
    wedges, slabs, gap, uncapped = A.roof(arrest["model"])
    check(wedges == 2 and slabs == 2 and gap < 0.02 and uncapped == 0,
          f"Arrest roof: {wedges} attic wedges, {slabs} slate slabs, worst underside off its slope {gap:.4f}, {uncapped} inner top edges outside the ridge cap")
    check(arrest["flush"] == 0, f"Arrest: {arrest['flush']} flush face pairs")

    # Planted faults, every run.
    planted = lua.eval("""function(...)
        local A, model, origin = ...
        local out = {}
        local f = Instance.new('Folder')
        local a = Instance.new('Part') a.Size = Vector3.new(4, 1, 4) a.CFrame = CFrame.new(0, 0, 0) a.Parent = f
        local b = Instance.new('Part') b.Size = Vector3.new(4, 1, 4) b.CFrame = CFrame.new(1, 0.01, 1) b.Parent = f
        out.flush = (A.flushPairs(A.boxes(f)))
        local far = Instance.new('Part') far.Size = Vector3.new(1, 1, 1) far.CFrame = CFrame.new(origin.X + 17, 1, origin.Z) far.Parent = model
        out.reach = A.reach(model, origin)
        far.Parent = nil
        return out
    end""")(A, six["model"], six["origin"])
    check(planted["flush"] == 1, f"planted: two slabs 0.01 apart give {planted['flush']} flush pair (want 1)")
    check(planted["reach"] > six["footprint"] + 0.1, f"planted: a part past the footprint reads as reach {planted['reach']:.1f}")
    # The shape-true reach both ways: a flat disc 46 across reads its true 23 (a box's corners said
    # 32.5), and the same disc is still caught past a 14-stud footprint; a ball's reach is its centre
    # plus its radius.
    disc, ball = lua.eval("""function(...)
        local A = ...
        local f = Instance.new('Folder')
        local d = Instance.new('Part') d.Shape = 'PartType.Cylinder' d.Size = Vector3.new(0.2, 46, 46)
        d.CFrame = CFrame.new(0, 0.4, 0) * CFrame.Angles(0, 0, math.pi / 2) d.Parent = f
        local disc = A.reach(f, Vector3.new(0, 0, 0))
        d.Parent = nil
        local b = Instance.new('Part') b.Shape = 'PartType.Ball' b.Size = Vector3.new(3, 3, 3) b.CFrame = CFrame.new(10, 2, 0) b.Parent = f
        return disc, (A.reach(f, Vector3.new(0, 0, 0)))
    end""")(A)
    check(abs(disc - 23) < 0.05 and disc > 14.1, f"planted: a disc 46 across reads reach {disc:.2f} (want 23, and past a 14 footprint)")
    check(abs(ball - 11.5) < 1e-6, f"planted: a ball 3 across centred 10 out reads reach {ball:.2f} (want 11.50)")
    check(A.gloveClearance(six["model"], 1.5) < 0, "planted: a cap 1.5 higher is reported as inside a bobbing glove")
    bare_planted = lua.eval("""function(...)
        local A, model = ...
        local limb = Instance.new('Part') limb.Size = Vector3.new(1, 4, 1) limb.Material = 'Material.Fabric' limb.CanCollide = false
        limb.CFrame = CFrame.new(500, 50, 500) limb.Parent = model
        local _, bad = A.limbsWithoutJoints(model)
        limb.Parent = nil
        return bad
    end""")(A, arrest["model"])
    check(bare_planted == 2, f"planted: a limb with no joints gives {bare_planted} bare ends (want 2)")
    lifted = lua.eval("""function(...)
        local A, model = ...
        for _, d in ipairs(model:GetDescendants()) do
            if d.Material == 'Material.Slate' and math.abs(d.Size.Y - 0.5) < 1e-6 then
                local keep = d.CFrame
                d.CFrame = keep + Vector3.new(0, 0.3, 0)
                local _, _, gap = A.roof(model)
                d.CFrame = keep
                return gap
            end
        end
    end""")(A, arrest["model"])
    check(lifted > 0.2, f"planted: a slab lifted 0.3 reads {lifted:.3f} off its slope")

    # ---- storm ------------------------------------------------------------------------------
    if REF:
        slua, sA = run_storm(read(STORM, REF))
        old = storm_numbers(slua, sA, "0, 10, -150", "0, 5, 0")
        print(f"storm before ({REF}): {old}")
    slua, sA = run_storm(read(STORM))
    # Camera near the south edge of a 175 ring, player inside.
    near = storm_numbers(slua, sA, "0, 10, -150", "0, 5, 0")
    print(f"storm now, camera at the south edge: { {k: v for k, v in near.items() if k != 'cues'} }")
    check(near.get("wide") == 192, f"storm: {near.get('wide')} BaseParts wider than a stud in StormWall (arena gallery wants 192)")
    check(abs(near.get("first_r", 0) - 175) < 2, f"storm: the folder's first child stands {near.get('first_r', 0):.1f} from the centre")
    check(near.get("flush") == 0, f"storm: {near.get('flush')} flush pairs between wall and band segments")
    check(near.get("emitters", 99) <= 24, f"storm: {near.get('emitters')} swirl emitters in the ring")
    check(0 < near.get("running", 0) < near.get("emitters", 0), f"storm: {near.get('running')} of {near.get('emitters')} running with the camera at one edge")
    check(near.get("ceiling", 999) < 300, f"storm: live-particle ceiling {near.get('ceiling', 0):.0f}")
    # A final circle: radius 20, camera inside it, so every emitter is in range: the ceiling's worst case.
    slua.execute("StormEvent:Fire({ status = 'Final', center = Vector3.new(0, 0, 0), radius = 20 }); for _ = 1, 600 do RenderStepped:Fire(1 / 60) end")
    wall = slua.eval("workspace:FindFirstChild('StormWall')")
    running = [e for e in wall.GetDescendants(wall).values() if e.ClassName == "ParticleEmitter" and e.Enabled]
    ceiling = sum(e.Rate * e.Lifetime[2] for e in running)
    check(ceiling < 300, f"storm: final circle, {len(running)} emitters running, ceiling {ceiling:.0f} particles")
    # The player walks out of a radius-20 circle, then back in.
    slua.execute("LocalRoot.CFrame = CFrame.new(60, 5, 0); for _ = 1, 60 do RenderStepped:Fire(1 / 60) end")
    slua.execute("LocalRoot.CFrame = CFrame.new(0, 5, 0); for _ = 1, 60 do RenderStepped:Fire(1 / 60) end")
    slua.execute("LocalRoot.CFrame = CFrame.new(60, 500, 0); for _ = 1, 60 do RenderStepped:Fire(1 / 60) end")
    cues = list(slua.eval("PlayedCues").values())
    check(cues == ["StormEnter", "StormLeave"], f"storm: cues on out, in, then to the lobby: {cues}")
    slua.execute("StormEvent:Fire({ status = 'Idle' })")
    gone = slua.eval("workspace:FindFirstChild('StormWall')") is None
    still = [e for e in wall.GetDescendants(wall).values() if e.ClassName == "ParticleEmitter" and e.Enabled]
    check(gone and not still, f"storm: Idle takes the ring down ({'gone' if gone else 'STILL UP'}), {len(still)} emitters left on")
    # Planted: a band pulled flush onto its wall's front face.
    pulled = slua.eval("""function(...)
        local A, wall = ...
        local kids = wall:GetChildren()
        local w, b = kids[1], kids[2]
        local keepS, keepC = b.Size, b.CFrame
        b.Size = Vector3.new(w.Size.X, b.Size.Y, w.Size.Z)
        local n = A.flushPairs({ w, b })
        b.Size, b.CFrame = keepS, keepC
        return n
    end""")(sA, wall)
    check(pulled >= 1, f"planted: a band the wall's own length and depth gives {pulled} flush pair")

    print(f"RESULT {'PASS' if failures == 0 else 'FAIL'}: {checks} checks, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
