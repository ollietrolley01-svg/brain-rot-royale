-- Kill animations (#24), two stills each, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/killanim_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Rebuild the place first: this reads KillAnimFxClient's Source out of the built place.
--
-- The animations last under three seconds and gallery.ps1 captures about a second after "ready"
-- (COORDINATION.md), so a live one can't be caught at a known moment. Instead each view runs the
-- REAL client source against a stand-in clock: task.delay, tweens and the NumberValues that drive
-- the moving pieces are replaced (only here) by a virtual timeline that is run forward to the
-- view's moment and then stopped, so the scene stands still for as long as the capture takes.
-- Tweens are interpolated linearly, so a Back or Sine ease sits slightly off where the game would
-- have it at that instant; the shapes, sizes, colours and where things end up are exact.
--
-- Each view uses a fresh copy of the module, so the MAX_LIVE count never fills up across views.
-- Things to look at: the bat meets the ground on the spot (not beside it), the drum sits upright
-- (a Cylinder's length is its X axis), the puddle and stamp ring lie flat, the ghost's eyes face
-- the camera side, nothing is buried in the plate.

local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CosmeticData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CosmeticData"))

local V = Vector3.new
local HIGH = V(600, 1400, -2600)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

-- Moments to freeze each one at, in seconds after the kill.
local FREEZE = {
	KillConfettiPop = { 0.3, 1.0 },
	KillRotPuddle = { 0.6, 1.5 },
	KillBigBonk = { 0.2, 0.6 },
	KillRotGhost = { 0.5, 1.5 },
	KillDrumStamp = { 0.2, 0.7 },
	KillCoinFountain = { 0.6, 1.2 },
	KillBrainBlast = { 0.6, 1.0 },
}

--------------------------------------------------------------------------------
-- The stand-in clock
--------------------------------------------------------------------------------

local function newTimeline()
	local timeline = { now = 0, queue = {}, tweens = {} }

	local function lerp(a, b, alpha)
		if type(a) == "number" then
			return a + (b - a) * alpha
		end
		return a:Lerp(b, alpha)
	end

	local function advance(to)
		for _, tween in ipairs(timeline.tweens) do
			local alpha = math.clamp((to - tween.start) / math.max(tween.time, 1e-3), 0, 1)
			for key, goal in pairs(tween.goal) do
				local ok = pcall(function()
					tween.inst[key] = lerp(tween.from[key], goal, alpha)
				end)
				if not ok then
					tween.inst[key] = alpha >= 1 and goal or tween.from[key]
				end
			end
			if tween.inst.__fire then
				tween.inst.__fire(tween.inst.Value)
			end
		end
		timeline.now = to
	end

	function timeline.runTo(limit)
		while true do
			table.sort(timeline.queue, function(a, b)
				return a.at < b.at
			end)
			local nextItem = timeline.queue[1]
			if not nextItem or nextItem.at > limit then
				break
			end
			table.remove(timeline.queue, 1)
			advance(nextItem.at)
			nextItem.fn()
		end
		advance(limit)
		timeline.queue = {}
	end

	timeline.task = {
		delay = function(seconds, fn)
			table.insert(timeline.queue, { at = timeline.now + seconds, fn = fn })
		end,
	}

	timeline.TweenService = {
		Create = function(_, inst, info, goal)
			return {
				Play = function()
					local from = {}
					for key in pairs(goal) do
						from[key] = inst[key]
					end
					table.insert(timeline.tweens, { inst = inst, goal = goal, from = from, start = timeline.now, time = info.Time })
				end,
			}
		end,
	}

	-- NumberValues become plain tables whose Changed fires when the timeline moves them; every
	-- other class is a real instance.
	timeline.Instance = {
		new = function(className)
			if className ~= "NumberValue" then
				return Instance.new(className)
			end
			local listeners = {}
			local value = { Value = 0 }
			value.Changed = {
				Connect = function(_, fn)
					table.insert(listeners, fn)
				end,
			}
			value.__fire = function(v)
				for _, fn in ipairs(listeners) do
					fn(v)
				end
			end
			return value
		end,
	}

	return timeline
end

--------------------------------------------------------------------------------
-- The real client, rewired to the stand-in clock
--------------------------------------------------------------------------------

local clientScript = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("KillAnimFxClient")
local SWAPS = {
	{ 'local TweenService = game:GetService%("TweenService"%)', "local TweenService = _G.BRR_KillAnimTimeline.TweenService\nlocal task = _G.BRR_KillAnimTimeline.task\nlocal Instance = _G.BRR_KillAnimTimeline.Instance" },
	{ 'local Remotes = require%(Shared:WaitForChild%("Remotes"%)%)', "" },
	{ 'local Sfx = require%(script.Parent:WaitForChild%("Sfx"%)%)', "local Sfx = { PlayAt = function() end }" },
	{ 'local killAnimFx = Remotes.Event%("KillAnimFx"%)', "local killAnimFx = { OnClientEvent = { Connect = function() end } }" },
}

local function freshPlay()
	local source = clientScript.Source
	for _, swap in ipairs(SWAPS) do
		local count
		source, count = source:gsub(swap[1], swap[2])
		if count ~= 1 then
			note("KillAnimFxClient no longer has the line " .. swap[1] .. "; the gallery needs updating")
		end
	end
	local module = Instance.new("ModuleScript")
	module.Name = "BRR_KillAnimGallery"
	module.Source = source .. "\nreturn play\n"
	module.Parent = ServerStorage
	local play = require(module)
	module:Destroy()
	return play
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

local function clearOld()
	for _, child in ipairs(workspace:GetChildren()) do
		if child.Name == "KillAnimFx" then
			child:Destroy()
		end
	end
end

local function stage(folder, at)
	local plate = Instance.new("Part")
	plate.Anchored = true
	plate.Size = V(60, 1, 60)
	plate.CFrame = CFrame.new(at - V(0, 0.5, 0))
	plate.Color = Color3.fromRGB(96, 150, 80)
	plate.Material = Enum.Material.Grass
	plate.Parent = folder
	-- A body-sized block beside the spot, for scale.
	local body = Instance.new("Part")
	body.Anchored = true
	body.Size = V(2, 5, 1)
	body.CFrame = CFrame.new(at + V(5, 2.5, 0))
	body.Color = Color3.fromRGB(160, 160, 170)
	body.Parent = folder
end

local views = {}

for _, id in ipairs(CosmeticData.OfKind("KillAnimation")) do
	for index, moment in ipairs(FREEZE[id] or { 0.3, 1.0 }) do
		table.insert(views, {
			name = string.format("killanim_%s_%d_%.1fs", id, index, moment),
			settle = 1.4,
			hold = 4,
			setup = function(folder, camera)
				clearOld()
				local at = HIGH
				stage(folder, at)
				local timeline = newTimeline()
				_G.BRR_KillAnimTimeline = timeline
				camera.FieldOfView = 50
				camera.CFrame = CFrame.lookAt(at + V(14, 10, -20), at + V(0, 3, 0))
				local ok, err = pcall(function()
					local play = freshPlay()
					play(id, at + V(0, 3, 0))
					timeline.runTo(moment)
				end)
				if not ok then
					note(id .. " failed: " .. tostring(err))
				end
				local parts = 0
				for _, child in ipairs(workspace:GetChildren()) do
					if child.Name == "KillAnimFx" then
						for _, part in ipairs(child:GetDescendants()) do
							if part:IsA("BasePart") then
								parts += 1
							end
						end
					end
				end
				note(string.format("%s at %.1f s: %d parts", id, moment, parts))
			end,
		})
	end
end

table.insert(views, {
	name = "killanim_cleanup",
	settle = 1.2,
	hold = 2,
	setup = function(_, camera)
		clearOld()
		camera.CFrame = CFrame.lookAt(HIGH + V(14, 10, -20), HIGH)
	end,
})

return views
