"""Third-person reload and aim pose check (#13), without Studio.

Runs the REAL StarterPlayerScripts/GunPoseClient.client.lua -- its scan and its Stepped handler -- with
the REAL Viewmodel and GunModels under lupa (the mock is tools/fps_arms_mock.lua.txt), on a mock R15 body
holding each gun's real HeldGun model (GunModels.Build, the model WeaponService mounts), and steps it
through a reload the way a client sees one: the body's `Reloading` attribute set to the reload's length,
game time moving on.

Invariants, on every gun:
  B1  mid-reload, the left arm's shoulder and elbow are exactly the first-person clip's pose at that
      moment (Viewmodel.BodyArm of Viewmodel.ClipFor for this gun), to 1e-6 -- the same table and the same
      timing drive both views;
  B2  the reload is seen: somewhere in it the left shoulder turns at least 20 degrees from the held pose;
  B3  with no `Reloading` the left arm is the held pose, and after the reload clears it goes back to it;
  B4  `Aiming` cants the head (the Neck turns) and clearing it brings the head back.

    python3 tools/fps_arms_body_check.py [repo]           the checks
    python3 tools/fps_arms_body_check.py [repo] --plant   the planted faults; every one must be caught
"""

import math
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("fps_arms_body_check: needs lupa (pip install lupa)")

GRID = [i / 20 for i in range(21)]
SECONDS = 2.0

HARNESS = r"""
local stepped
local clock = 0
function time() return clock end
function setClock(t) clock = t end
task = { spawn = function(f) SCAN = f end, wait = function() error("__stop__") end, delay = function() end }
local runService = { Stepped = { Connect = function(_, f) stepped = f; return {} end } }
local baseGet = game.GetService
game.GetService = function(self, name)
	if name == "RunService" then return runService end
	return baseGet(self, name)
end
workspace.CurrentCamera = { CFrame = CFrame.new() }

function makeBody(gun)
	local body = Instance.new("Model")
	body.Name = "Body"
	local humanoid = Instance.new("Humanoid")
	humanoid.Health = 100
	humanoid.Parent = body
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.CFrame = CFrame.new(0, 0, -10)
	root.AssemblyLinearVelocity = Vector3.zero
	root.Parent = body
	local function joint(partName, jointName)
		local part = Instance.new("Part")
		part.Name = partName
		part.Parent = body
		local motor = Instance.new("Motor6D")
		motor.Name = jointName
		motor.Transform = CFrame.identity
		motor.Parent = part
	end
	joint("RightUpperArm", "RightShoulder")
	joint("LeftUpperArm", "LeftShoulder")
	joint("RightLowerArm", "RightElbow")
	joint("LeftLowerArm", "LeftElbow")
	joint("UpperTorso", "Waist")
	joint("Head", "Neck")
	gun.Name = "HeldGun"
	gun.Parent = body
	body.Parent = workspace
	return body
end

function frame(t)
	clock = t
	-- The Animator writes each joint's Transform before Stepped; here it writes the rest pose.
	for _, d in ipairs(workspace:GetDescendants()) do
		if d.ClassName == "Motor6D" then d.Transform = CFrame.identity end
	end
	stepped(t, 1 / 60)
end

function scanOnce() pcall(SCAN) end

function angle(a, b)
	local r = a:Inverse() * b
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = r:GetComponents()
	local c = math.max(-1, math.min(1, (r00 + r11 + r22 - 1) / 2))
	return math.deg(math.acos(c))
end
function joints(body)
	return body.LeftUpperArm.LeftShoulder.Transform, body.LeftLowerArm.LeftElbow.Transform, body.Head.Neck.Transform
end
"""


def luau_to_lua(src):
    return re.sub(r"^(\s*)([\w.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", r"\1\2 = \2 \3 (\4)", src, flags=re.M)


def sources(repo):
    shared = os.path.join(repo, "ReplicatedStorage", "Shared")
    out = {n[:-4]: open(os.path.join(shared, n), encoding="utf-8").read() for n in os.listdir(shared) if n.endswith(".lua")}
    scripts = os.path.join(repo, "StarterPlayerScripts")
    out["Viewmodel"] = open(os.path.join(scripts, "Viewmodel.lua"), encoding="utf-8").read()
    out["GunPoseClient"] = open(os.path.join(scripts, "GunPoseClient.client.lua"), encoding="utf-8").read()
    return out


def run(repo, src, only=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(repo, "tools", "fps_arms_mock.lua.txt"), encoding="utf-8").read())
    lua.execute(HARNESS)
    table = lua.globals().SOURCES
    for name, text in src.items():
        table[name] = luau_to_lua(text)
    g = lua.globals()
    weapons = lua.eval('loadModule("WeaponData")')
    gm = lua.eval('loadModule("GunModels")')
    vm = lua.eval('loadModule("Viewmodel")')
    # The LocalScript itself, with `script.Parent:WaitForChild("Viewmodel")` handing back the module.
    chunk = lua.eval('function(src) return load(src, "=GunPoseClient", "t", setmetatable({ script = { Parent = SHARED } }, { __index = _G })) end')(table["GunPoseClient"])
    faults, examined = [], 0
    chunk()
    ids = [i for i in sorted(weapons.Weapons.keys()) if not only or i in only]
    for gun in ids:
        model = gm.Build(weapons.Get(gun), None, None, lua.table_from({}))[0]
        body = g.makeBody(model)
        g.scanOnce()
        clip = vm.ClipFor(model, "reload", False, 1)
        g.frame(0.0)
        held_s, held_e, neck0 = g.joints(body)
        body.SetAttribute(body, "Reloading", SECONDS)
        start = 1.0
        g.frame(start)
        widest = 0.0
        for p in GRID:
            g.frame(start + p * SECONDS)
            s, e, _ = g.joints(body)
            want_s, want_e = vm.BodyArm(clip, p)[0:2]
            examined += 1
            err = max(g.angle(s, want_s), g.angle(e, want_e))
            if err > 1e-3:
                faults.append("B1 %s at %.2f of the reload: left arm %.2f degrees off the first-person clip's pose" % (gun, p, err))
                break
            widest = max(widest, g.angle(s, held_s))
        if widest < 20:
            faults.append("B2 %s: the left shoulder never turns more than %.1f degrees in the reload" % (gun, widest))
        body.SetAttribute(body, "Reloading", None)
        g.frame(start + SECONDS + 0.5)
        s, e, _ = g.joints(body)
        if g.angle(s, held_s) > 1e-3 or g.angle(e, held_e) > 1e-3:
            faults.append("B3 %s: the left arm did not go back to the held pose after the reload" % gun)
        body.SetAttribute(body, "Aiming", True)
        for k in range(30):
            g.frame(start + SECONDS + 1 + k / 60)
        _, _, neck = g.joints(body)
        if g.angle(neck, neck0) < 5:
            faults.append("B4 %s: aiming turned the head %.1f degrees" % (gun, g.angle(neck, neck0)))
        body.SetAttribute(body, "Aiming", None)
        for k in range(60):
            g.frame(start + SECONDS + 2 + k / 60)
        _, _, neck = g.joints(body)
        if g.angle(neck, neck0) > 0.5:
            faults.append("B4 %s: the head stayed %.1f degrees turned after aiming stopped" % (gun, g.angle(neck, neck0)))
        body.Parent = None
        g.scanOnce()
    return faults, examined, len(ids)


PLANTS = [
    ("B1 the reload timed on the wrong clock", "GunPoseClient",
     "local progress = math.clamp((now - entry.reload.start) / seconds, 0, 1)",
     "local progress = math.clamp((now - entry.reload.start) / (seconds * 2), 0, 1)"),
    ("B2 the body never reads the reload", "GunPoseClient",
     'local seconds = character:GetAttribute("Reloading")', 'local seconds = nil'),
    ("B2 every anchor drawn as the held pose", "Viewmodel",
     "local entry = BODY_LEFT[name] or BODY_LEFT.SupportHand", "local entry = BODY_LEFT.SupportHand"),
    ("B4 aiming ignored", "GunPoseClient",
     'character:GetAttribute("Aiming") == true', 'character:GetAttribute("Aimed") == true'),
]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    repo = args[0] if args else "."
    src = sources(repo)
    if "--plant" in sys.argv:
        caught = 0
        for name, target, old, new in PLANTS:
            if old not in src[target]:
                print("PLANT %s: the text to break is not in %s any more" % (name, target))
                continue
            broken = dict(src)
            broken[target] = src[target].replace(old, new, 1)
            faults, examined, guns = run(repo, broken, only=["SahurPistol", "CrocodiloRifle", "TralalaShotgun", "SigmaRevolver"])
            hit = [f for f in faults if f.startswith(name.split()[0] + " ")]
            caught += bool(hit)
            print("%s %s: %d flags%s" % ("CAUGHT" if hit else "MISSED", name, len(hit), (" (" + hit[0] + ")") if hit else ""))
        print("planted faults caught: %d of %d" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    faults, examined, guns = run(repo, src)
    for fault in faults:
        print(fault)
    print("fps arms body: %d guns, %d reload moments examined, %d flagged" % (guns, examined, len(faults)))
    sys.exit(1 if faults else 0)


if __name__ == "__main__":
    main()
