-- Ready pad probe (task 09): a character on the lobby ready pad presses un-ready, in Run mode, with the real
-- buildReadyPad Touched handler, the real MatchService.SetReady and Roblox's own physics touches. For the
-- pictures; tools/ready_pad_check.py is the proof with a mock clock.
--
--   python tools/linux/studio.py gallery -Gallery tools/ready_pad_probe.lua -OutDir <dir> -PlaceFile <build>
--   (tools/gallery.ps1 on Windows)
--
-- Run mode has no Player, so Players:GetPlayerFromCharacter would turn every touch away. The probe clones
-- LobbyService, swaps only its `local Players = game:GetService("Players")` line for a shim that answers
-- GetPlayerFromCharacter with a stand-in player for the probe's rig (and forwards everything else to the real
-- service), and exposes buildReadyPad. The stand-in's OnReadyPad is Bootstrap's one line,
-- MatchService.SetReady(player, true). Run it on a build of main and a build of the branch, same probe.
--
-- The rig is a server-simulated R15 playing Roblox's default idle and walk animations on the server (no
-- client runs, so no Animate script): it stands still for 2 s (touches counted), then shuffles between spots
-- on the pad. Without the animations its feet never move and it never touches the pad again. Measured
-- 2026-09-26: 0 touches standing still, 50-57 in 10 s shuffling. Whether a real client's character
-- re-touches the pad the same way is the Play test's to say.
--
-- Lines to read: "flips: READY at .., not ready at 4.00 s, READY at .." is main re-readying a player on the
-- pad; the branch's flips end at "not ready".
--
-- Timeline from the first frame: walk onto the pad at 0.3 s, stand still 2-4 s, un-ready (SetReady false,
-- what the pill and the Ready key send) at 4 s, shuffle to the end. Lines start "[BRR_ReadyPad]".

local UNREADY_AT = 4
local STILL_FROM, STILL_TO = 2, 4
local END_AT = 14
local CLIP_FRAMES = 20
local CENTER = Vector3.new(0, 1500, -6000)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")

local function say(fmt, ...)
	print(string.format("[BRR_ReadyPad] " .. fmt, ...))
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(4)

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MatchService = require(modules:WaitForChild("MatchService"))

-- The shim LobbyService's copy requires in place of the Players service.
local shimModule = Instance.new("ModuleScript")
shimModule.Name = "BRR_ReadyPadPlayersShim"
shimModule.Source = [[
local real = game:GetService("Players")
local shim = { playerFor = {} }
function shim:GetPlayerFromCharacter(character)
	return shim.playerFor[character] or real:GetPlayerFromCharacter(character)
end
return setmetatable(shim, { __index = function(_, key)
	local value = real[key]
	if type(value) == "function" then
		return function(_, ...)
			return value(real, ...)
		end
	end
	return value
end })
]]
shimModule.Parent = modules
local shim = require(shimModule)

local original = modules:WaitForChild("LobbyService")
local source = original.Source
local fixed = string.find(source, "PAD_REACH", 1, true) ~= nil
local tree = fixed and "task/unready (after)" or "main (before)"
local copy = original:Clone()
copy.Name = "BRR_ReadyPadLobbyCopy"
local swapped, n1 = string.gsub(source, 'local Players = game:GetService%("Players"%)',
	'local Players = require(script.Parent:WaitForChild("BRR_ReadyPadPlayersShim"))', 1)
local exposed, n2 = string.gsub(swapped, "\nreturn LobbyService%s*$", "\nLobbyService.BRR_buildReadyPad = buildReadyPad\nreturn LobbyService\n")
say("tree %s; source patched: players line %d, export %d", tree, n1, n2)
copy.Source = exposed
copy.Parent = modules
local Lobby = require(copy)
Lobby.OnReadyPad = function(player)
	MatchService.SetReady(player, true)
end

-- The deck the pad stands on (its top at CENTER, like the airship's), and the pad itself.
local arena = Instance.new("Model")
arena.Name = "BRR_ReadyPadProbe"
arena.Parent = workspace
local deck = Instance.new("Part")
deck.Anchored = true
deck.Size = Vector3.new(40, 2, 40)
deck.CFrame = CFrame.new(CENTER - Vector3.new(0, 1, 0))
deck.Material = Enum.Material.WoodPlanks
deck.Color = Color3.fromRGB(150, 104, 62)
deck.Parent = arena
Lobby.BRR_buildReadyPad(arena, CENTER)
local pad = arena:FindFirstChild("ReadyPad")

-- The rig, and the stand-in player the shim hands back for it.
local rig
for _ = 1, 3 do
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and model then
		rig = model
		break
	end
	task.wait(2)
end
rig.Name = "ReadyPadRig"
local humanoid = rig:FindFirstChildOfClass("Humanoid")
local root = rig:WaitForChild("HumanoidRootPart")
rig:PivotTo(CFrame.lookAt(CENTER + Vector3.new(0, 3, 14), CENTER + Vector3.new(0, 3, 0)))
rig.Parent = arena

-- A client's Animate script moves a player's limbs; this rig has none, so without these its feet never
-- leave the pad and never touch it again. Roblox's default R15 idle and walk, played on the server.
local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
local function track(id)
	local animation = Instance.new("Animation")
	animation.AnimationId = "rbxassetid://" .. id
	local ok, loaded = pcall(animator.LoadAnimation, animator, animation)
	return ok and loaded or nil
end
local idleTrack, walkTrack = track(507766666), track(507777826)
if idleTrack then
	idleTrack.Looped = true
	idleTrack:Play()
end
humanoid.Running:Connect(function(speed)
	if not walkTrack then
		return
	end
	if speed > 0.5 and not walkTrack.IsPlaying then
		walkTrack.Looped = true
		walkTrack:Play()
	elseif speed <= 0.5 and walkTrack.IsPlaying then
		walkTrack:Stop()
	end
end)
task.wait(1)
say("animations: idle %s (%.2f s), walk %s (%.2f s)", tostring(idleTrack ~= nil), idleTrack and idleTrack.Length or 0,
	tostring(walkTrack ~= nil), walkTrack and walkTrack.Length or 0)

local attrs = { Ready = false }
local stand = {
	Name = "ProbePlayer",
	UserId = -9001,
	Parent = workspace,
	Character = rig,
	GetAttribute = function(_, key)
		return attrs[key]
	end,
	SetAttribute = function(_, key, value)
		attrs[key] = value
	end,
}
shim.playerFor[rig] = stand

local touches = { still = 0, shuffle = 0, all = 0 }
local phase = "walk"
pad.Touched:Connect(function(hit)
	if hit:IsDescendantOf(rig) then
		touches.all += 1
		if touches[phase] then
			touches[phase] += 1
		end
	end
end)

-- The label: which tree, the clock, and the Ready state, big enough to read in a GIF frame.
local gui = Instance.new("ScreenGui")
gui.Name = "BRR_ReadyPadLabel"
gui.IgnoreGuiInset = true
gui.DisplayOrder = 99999
local function label(y, size)
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 0.25
	text.BackgroundColor3 = Color3.new(0, 0, 0)
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Position = UDim2.fromOffset(16, y)
	text.Size = UDim2.fromOffset(460, size)
	text.Parent = gui
	return text
end
local treeLabel = label(16, 34)
local clockLabel = label(54, 28)
local readyLabel = label(86, 48)
local eventLabel = label(138, 28)
treeLabel.Text = tree
gui.Parent = CoreGui
local head = rig:FindFirstChild("Head")
local tag = Instance.new("BillboardGui")
tag.Size = UDim2.fromOffset(200, 50)
tag.StudsOffset = Vector3.new(0, 2.5, 0)
tag.AlwaysOnTop = true
tag.Adornee = head
local tagText = Instance.new("TextLabel")
tagText.Size = UDim2.fromScale(1, 1)
tagText.BackgroundTransparency = 1
tagText.Font = Enum.Font.GothamBlack
tagText.TextScaled = true
tagText.TextStrokeTransparency = 0
tagText.Parent = tag
tag.Parent = arena

local started = nil
local flips = {}
local lastReady = false
local function draw(t)
	local ready = attrs.Ready == true
	clockLabel.Text = string.format("t = %.1f s", t)
	readyLabel.Text = ready and "Ready: YES" or "Ready: NO"
	readyLabel.TextColor3 = ready and Color3.fromRGB(90, 255, 120) or Color3.fromRGB(255, 90, 90)
	tagText.Text = ready and "READY" or "NOT READY"
	tagText.TextColor3 = readyLabel.TextColor3
	if t < UNREADY_AT then
		eventLabel.Text = t < STILL_FROM and "walks onto the pad" or "standing on the pad"
	else
		eventLabel.Text = string.format("pressed UN-READY at %d s, shuffling on the pad", UNREADY_AT)
	end
end

local SPOTS = { Vector3.new(-2, 0, 1), Vector3.new(2, 0, -1), Vector3.new(1.5, 0, 2), Vector3.new(-1.5, 0, -2) }
local function run()
	started = tick()
	humanoid:MoveTo(CENTER)
	local pressed, spot, nextMove = false, 0, STILL_TO
	while true do
		local t = tick() - started
		if t >= END_AT then
			break
		end
		phase = (t < STILL_FROM and "walk") or (t < STILL_TO and "still") or "shuffle"
		if phase == "still" then
			humanoid:Move(Vector3.zero)
		end
		if not pressed and t >= UNREADY_AT then
			pressed = true
			MatchService.SetReady(stand, false)
			say("un-ready pressed at %.2f s: Ready now %s", t, tostring(attrs.Ready == true))
		end
		if phase == "shuffle" and t >= nextMove then
			spot = spot % #SPOTS + 1
			humanoid:MoveTo(CENTER + SPOTS[spot])
			nextMove = t + 0.8
		end
		local ready = attrs.Ready == true
		if ready ~= lastReady then
			table.insert(flips, string.format("%s at %.2f s", ready and "READY" or "not ready", t))
			lastReady = ready
		end
		draw(t)
		task.wait()
	end
	say("%s: Ready at the end %s; flips: %s", tree, tostring(attrs.Ready == true), table.concat(flips, ", "))
	say("touches from the rig: %d in all, %d while standing still (%d-%d s), %d while shuffling (%d-%d s)",
		touches.all, touches.still, STILL_FROM, STILL_TO, touches.shuffle, STILL_TO, END_AT)
	say("done")
end
draw(0)

local views = {}
for frame = 1, CLIP_FRAMES do
	table.insert(views, {
		name = string.format("clip_%03d", frame),
		settle = 0.05,
		hold = 0.75,
		setup = function(_, camera)
			if not started then
				task.spawn(run)
			end
			camera.FieldOfView = 50
			camera.CFrame = CFrame.lookAt(CENTER + Vector3.new(14, 11, 20), CENTER + Vector3.new(0, 2, 0))
		end,
	})
end
return views
