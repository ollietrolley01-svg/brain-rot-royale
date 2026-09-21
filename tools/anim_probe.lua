-- Which animation ids actually load, so bots can be given hold and aim poses.
--
-- Run with: runtest.ps1 -Probe tools/anim_probe.lua
--
-- Bots currently carry exactly three stock R15 tracks — idle, walk, run — picked on speed alone,
-- so they run the empty-handed stock animations while holding a gun. Adding a weapon-hold and an
-- aim pose means adding ids, and `setupAnimations` wraps every load in a pcall and drops failures
-- without a word: a wrong id is not an error, it is simply no animation. That is the same silent
-- failure that left two sound cues dead, so the ids get measured rather than assumed.
--
-- The three ids already in BotService are included as controls. If those come back as failures
-- the probe itself is wrong, not the candidates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function say(...)
	print(string.format("[BRR_Anim] " .. select(1, ...), select(2, ...)))
end

-- label, id, whether it is a known-good control
local CANDIDATES = {
	{ "idle (control)", "rbxassetid://507766388", true },
	{ "walk (control)", "rbxassetid://507777826", true },
	{ "run (control)", "rbxassetid://507767714", true },
	-- Other members of the same stock R15 package, wanted for jumping, falling and climbing.
	{ "jump", "rbxassetid://507765000", false },
	{ "fall", "rbxassetid://507767968", false },
	{ "climb", "rbxassetid://507765644", false },
	{ "swim", "rbxassetid://507784897", false },
	{ "swimidle", "rbxassetid://507785072", false },
	{ "idle variant 2", "rbxassetid://507766666", false },
	{ "idle variant 3", "rbxassetid://507766951", false },
	-- Tool-holding poses. These are the ones that would carry a gun properly.
	{ "tool none", "rbxassetid://507768375", false },
	{ "tool hold", "rbxassetid://507768375", false },
	{ "tool slash", "rbxassetid://522635514", false },
	{ "tool lunge", "rbxassetid://522638767", false },
}

-- A minimal rig: LoadAnimation only needs an Animator inside the DataModel, not a full body.
local rig = Instance.new("Model")
rig.Name = "BRR_AnimProbe"
local root = Instance.new("Part")
root.Name = "HumanoidRootPart"
root.Size = Vector3.new(2, 2, 1)
root.Anchored = true
root.CanCollide = false
root.Transparency = 1
root.Parent = rig
local humanoid = Instance.new("Humanoid")
humanoid.Parent = rig
rig.PrimaryPart = root
rig.Parent = workspace

local animator = Instance.new("Animator")
animator.Parent = humanoid

local loaded = {}
for _, entry in ipairs(CANDIDATES) do
	local animation = Instance.new("Animation")
	animation.AnimationId = entry[2]
	animation.Parent = rig
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	table.insert(loaded, { label = entry[1], id = entry[2], control = entry[3], ok = ok, track = ok and track or nil })
end

-- Length stays 0 until the asset has actually been fetched, so give it a few passes.
for _ = 1, 16 do
	local pending = 0
	for _, entry in ipairs(loaded) do
		if entry.track and entry.track.Length <= 0 then
			pending += 1
		end
	end
	if pending == 0 then
		break
	end
	task.wait(0.25)
end

local good, bad = {}, {}
for _, entry in ipairs(loaded) do
	if entry.track and entry.track.Length > 0 then
		table.insert(good, string.format("%s %.2fs", entry.label, entry.track.Length))
	else
		table.insert(bad, string.format("%s%s", entry.label, entry.control and " [CONTROL — probe is wrong]" or ""))
	end
end

say("RESOLVED %d: %s", #good, table.concat(good, " | "))
say("FAILED %d: %s", #bad, table.concat(bad, " | "))

-- What priorities are available for layering a hold pose over a walk cycle.
-- Indexing an Enum with a name it doesn't have throws rather than returning nil, so each lookup
-- is wrapped: the point is to find out which exist, and an error here would take the whole probe
-- down before it printed anything.
local priorities = {}
for _, name in ipairs({ "Idle", "Movement", "Action", "Action2", "Action3", "Action4", "Core" }) do
	local ok = pcall(function()
		return Enum.AnimationPriority[name]
	end)
	if ok then
		table.insert(priorities, name)
	end
end
say("animation priorities available: %s", table.concat(priorities, ", "))

rig:Destroy()
say("done")
