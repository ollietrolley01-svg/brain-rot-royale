-- The phone HUD, state by state (the phone HUD polish, 2026-09-28): what a phone player sees on foot, in
-- the lobby, spectating, and in each seat of a vehicle, at 844x390, 667x375 and 932x430 on its side and
-- 390x844 upright.
--
--   python tools/hud_layout_check.py . --gallery <out.lua>
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery <out.lua> -OutDir <dir> -PlaceFile <rbxlx>
--
-- This file is a TEMPLATE: the HUD's rects are not worked out here but measured by hud_layout_check,
-- which runs the real client scripts (HudClient, BoonHud, VehicleClient, VehicleWeaponClient, ModeScoreHud,
-- GunfireCueClient with the real PhoneLayout) in its mocked client, and `--gallery` writes a copy of this
-- file with the `local HUD = {}` line below filled in. So every panel drawn is where the game draws it.
--
-- The touch buttons ARE worked out here, in the built place: from the real PhoneLayout.TouchButtons when
-- the place has it (the seat-aware sets), and otherwise from the ContextActionService positions the
-- scripts set before it (the BEFORE picture), capped at the seven buttons ContextActionService draws.
-- A ContextActionService button is 45 px (Roblox's ContextActionTouch); a PhoneLayout one is its slot.
-- Roblox's own controls (the thumbstick's zone and rest, the jump button, the top bar) are PhoneLayout's.
--
-- Red: a panel or button that overlaps another, a tappable thing in Roblox's zones, a button under the
-- finger minimum. A dashed red chip is a button the state needs and cannot have. Each view also prints
-- its counts as notes. The camera looks at what the state is about: a car, its gun, a bike, the ground.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local PhoneLayout = require(Scripts:WaitForChild("PhoneLayout"))
local UiKit = require(Scripts:WaitForChild("UiKit"))
local VehicleModels = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("VehicleModels"))

local create = UiKit.create

-- Filled in by hud_layout_check.py --gallery: ["WxH|scene"] = { { var, gui, x, y, w, h }, ... }.
local HUD = {}
local PHASE = "?" -- filled in too: "before" or "after", for the captions

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

-- The states, as PhoneLayout.TouchButtons names them.
local STATES = {
	["battle royale"] = { context = "match", seat = "foot" },
	["team match"] = { context = "match", seat = "foot" },
	driving = { context = "match", seat = "driver", armed = true },
	gunner = { context = "match", seat = "gunner" },
	passenger = { context = "match", seat = "passenger" },
	bike = { context = "match", seat = "bike" },
	lobby = { context = "lobby", seat = "foot" },
	spectate = { context = "spectate", seat = "foot" },
}

-- BEFORE: where the scripts put their ContextActionService buttons (UDim2 offsets from the bottom right),
-- in the order they are bound. The first seven are bound at load and never let go, so they show in every
-- state; anything a seat binds after them gets no button.
local OLD_ON_FOOT = {
	{ "FIRE", -140, -180 }, { "AIM", -250, -180 }, { "RUN", -250, -280 }, { "RELOAD", -140, -280 },
	{ "PET", -360, -180 }, { "CROUCH", -360, -280 }, { "MOVE", -470, -280 },
}
local OLD_SEAT = {
	driving = { { "BRAKE", -180, -150 }, { "FIRE", -140, -180 } },
	gunner = { { "FIRE", -90, -280 }, { "AIM", -170, -280 }, { "RELOAD", -250, -280 }, { "LEAVE", -330, -280 } },
	bike = { { "BRAKE", -180, -150 } },
	passenger = {},
}

local function buttonsFor(scene, W, H)
	local state = STATES[scene]
	local shown, missing = {}, {}
	if type(PhoneLayout.TouchButtons) == "function" then
		for _, b in ipairs(PhoneLayout.TouchButtons(Vector2.new(W, H), state.context, state.seat, { armed = state.armed })) do
			table.insert(shown, { label = b.label, x = b.x, y = b.y, w = b.w, h = b.h })
		end
		return shown, missing, "PhoneLayout.TouchButtons"
	end
	for _, b in ipairs(OLD_ON_FOOT) do
		table.insert(shown, { label = b[1], x = W + b[2], y = H + b[3], w = 45, h = 45 })
	end
	for _, b in ipairs(OLD_SEAT[scene] or {}) do
		table.insert(missing, { label = b[1], x = W + b[2], y = H + b[3], w = 45, h = 45 })
	end
	return shown, missing, "ContextActionService literals (cap 7)"
end

local function overlaps(a, b)
	local w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
	local h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
	return w > 0.5 and h > 0.5
end

-- The 3D behind the screen: the thing the state is about, on a ground plate, with the camera on it.
local function stage(folder, camera, scene)
	local ground = Instance.new("Part")
	ground.Anchored = true
	ground.Size = Vector3.new(400, 1, 400)
	ground.Position = Vector3.new(0, 4999.5, 0)
	ground.Color = Color3.fromRGB(96, 132, 88)
	ground.Material = Enum.Material.Grass
	ground.Parent = folder
	local origin = Vector3.new(0, 5000, 0)
	local id = (scene == "bike") and "PatapimScrambler" or ((scene == "driving" or scene == "gunner" or scene == "passenger") and "Rotster" or nil)
	if id then
		local ok, model = pcall(function()
			return (VehicleModels.Build(id, Random.new(7), { scheme = 1 }))
		end)
		if ok and model then
			model:PivotTo(CFrame.new(origin + Vector3.new(0, 3, 0)))
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
				end
			end
			model.Parent = folder
		end
		-- From behind and above, the way the vehicle camera sits, with the car in the lower middle.
		local eye = scene == "gunner" and Vector3.new(0, 16, 30) or Vector3.new(0, 14, 34)
		camera.CFrame = CFrame.lookAt(origin + eye, origin + Vector3.new(0, 2, -20))
	else
		-- On foot: a dummy target down range, where the crosshair points.
		local target = Instance.new("Part")
		target.Anchored = true
		target.Size = Vector3.new(4, 7, 1)
		target.Position = origin + Vector3.new(0, 3.5, -30)
		target.Color = Color3.fromRGB(200, 90, 70)
		target.Parent = folder
		camera.CFrame = CFrame.lookAt(origin + Vector3.new(0, 6, 0), target.Position + Vector3.new(0, 1, 0))
	end
end

local COLORS = {
	BrrHud = Color3.fromRGB(90, 200, 255),
	BoonHud = Color3.fromRGB(190, 140, 255),
	VehicleHud = Color3.fromRGB(255, 190, 80),
	VehicleWeaponHud = Color3.fromRGB(255, 150, 60),
	ModeScoreHud = Color3.fromRGB(120, 230, 160),
	GunnerSight = Color3.fromRGB(255, 255, 255),
	GunfireCue = Color3.fromRGB(150, 150, 150),
}
local RED = Color3.fromRGB(240, 60, 60)

local function box(parent, r, color, text, filled, shape)
	local frame = create("Frame", {
		Position = UDim2.fromOffset(r.x, r.y),
		Size = UDim2.fromOffset(math.max(r.w, 2), math.max(r.h, 2)),
		BackgroundColor3 = color,
		BackgroundTransparency = filled and 0.55 or 0.8,
		BorderSizePixel = 0,
		Parent = parent,
	}, {
		create("UIStroke", { Color = color, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	})
	if shape == "circle" then
		create("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = frame })
	end
	if text and text ~= "" then
		create("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = text,
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.3,
			TextScaled = true,
			Parent = frame,
		}, { create("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 6 }) })
	end
	return frame
end

local SIZES = {
	{ 844, 390 }, { 667, 375 }, { 932, 430 }, { 390, 844 },
}
local SCENES = { "battle royale", "team match", "lobby", "spectate", "driving", "gunner", "passenger", "bike" }
-- Upright: the states that differ most.
local UPRIGHT_SCENES = { ["battle royale"] = true, driving = true, gunner = true }

-- One screen at a time: the harness clears each view's folder, but this gui lives in CoreGui.
local current = nil

local views = {}
for _, size in ipairs(SIZES) do
	local W, H = size[1], size[2]
	for _, scene in ipairs(SCENES) do
		local key = string.format("%dx%d|%s", W, H, scene)
		if HUD[key] and (W > H or UPRIGHT_SCENES[scene]) then
			table.insert(views, {
				name = string.format("%dx%d_%s", W, H, (scene:gsub(" ", "_"))),
				settle = 1.2,
				hold = 1.8,
				setup = function(folder, camera)
					stage(folder, camera, scene)
					if current then
						current:Destroy()
					end
					local root = Instance.new("ScreenGui")
					current = root
					root.IgnoreGuiInset = true
					root.ResetOnSpawn = false
					root.Parent = game:GetService("CoreGui")
					local viewport = camera.ViewportSize
					local fitScale = math.min(1, (viewport.X - 40) / W, (viewport.Y - 70) / H)
					local screen = create("Frame", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.new(0.5, 0, 0.5, 14),
						Size = UDim2.fromOffset(W, H),
						BackgroundTransparency = 1,
						ClipsDescendants = false,
						Parent = root,
					}, {
						create("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2 }),
						create("UIScale", { Scale = fitScale }),
					})
					-- Roblox's own controls, from PhoneLayout (its measurement of the CoreScripts).
					local spots = PhoneLayout.Rects(Vector2.new(W, H))
					local zone = spots.moveZone
					box(screen, { x = zone.x, y = zone.y, w = zone.w, h = zone.h }, Color3.fromRGB(0, 0, 0), "", false)
					box(screen, spots.stick, Color3.fromRGB(230, 230, 230), "stick", false, "circle")
					box(screen, spots.jump, Color3.fromRGB(230, 230, 230), "JUMP", false, "circle")
					box(screen, spots.topBar, Color3.fromRGB(200, 200, 200), "Roblox bar", false)

					local panels = {}
					for _, e in ipairs(HUD[key]) do
						table.insert(panels, { name = e[1], gui = e[2], x = e[3], y = e[4], w = e[5], h = e[6] })
					end
					local shown, missing, source = buttonsFor(scene, W, H)
					if scene == "spectate" then
						-- CombatClient's spectate plate and its NEXT / LEAVE (its own TextButtons, not CAS).
						local plateW = math.min(W - 24, 620)
						table.insert(panels, { name = "spectating", gui = "SpectateHud", x = W / 2 - plateW / 2, y = H - 24 - 48, w = plateW, h = 48 })
						table.insert(shown, { label = "NEXT", x = W / 2 - 66 - 60, y = H - 80 - 44, w = 120, h = 44, own = true })
						table.insert(shown, { label = "LEAVE", x = W / 2 + 66 - 60, y = H - 80 - 44, w = 120, h = 44, own = true })
					end
					local bad = {}
					local hits = 0
					local all = {}
					for _, p in ipairs(panels) do
						if p.gui ~= "GunfireCue" and p.name ~= "crosshair" and p.name ~= "hitmarker" and p.name ~= "reticle" and p.gui ~= "GunnerSight" then
							table.insert(all, p)
						end
					end
					for _, b in ipairs(shown) do
						table.insert(all, b)
					end
					for i = 1, #all do
						for j = i + 1, #all do
							if overlaps(all[i], all[j]) then
								bad[all[i]], bad[all[j]] = true, true
								hits += 1
							end
						end
					end
					local small, zoned = 0, 0
					for _, b in ipairs(shown) do
						if math.min(b.w, b.h) < 44 then
							bad[b] = true
							small += 1
						end
						if overlaps(b, zone) or overlaps(b, spots.jump) or overlaps(b, spots.topBar) then
							bad[b] = true
							zoned += 1
						end
					end
					for _, p in ipairs(panels) do
						local color = COLORS[p.gui] or Color3.fromRGB(200, 200, 200)
						local label = p.name
						if p.name == "crosshair" or p.name == "reticle" or p.gui == "GunnerSight" then
							label = "+"
						elseif p.gui == "GunfireCue" then
							label = ""
						end
						box(screen, p, bad[p] and RED or color, label, bad[p] == true)
					end
					for _, b in ipairs(shown) do
						box(screen, b, bad[b] and RED or Color3.fromRGB(255, 255, 255), b.label, true, b.own and nil or "circle")
					end
					for _, b in ipairs(missing) do
						local chip = box(screen, b, RED, "NO " .. b.label, false, "circle")
						chip.BackgroundTransparency = 1
					end
					create("TextLabel", {
						Position = UDim2.fromOffset(0, -26),
						Size = UDim2.fromOffset(W, 22),
						BackgroundTransparency = 1,
						Font = Enum.Font.GothamBold,
						Text = string.format("%s  %dx%d  %s   buttons: %d shown, %d missing   overlaps: %d   under 44 px: %d   in Roblox's zones: %d",
							string.upper(PHASE), W, H, string.upper(scene), #shown, #missing, hits, small, zoned),
						TextColor3 = Color3.new(1, 1, 1),
						TextStrokeTransparency = 0.2,
						TextSize = 15,
						TextXAlignment = Enum.TextXAlignment.Left,
						Parent = screen,
					})
					note(string.format("%s %s: %d panels, buttons from %s: %d shown, %d missing; %d overlapping pairs, %d buttons under 44 px, %d in Roblox's zones",
						PHASE, key, #panels, source, #shown, #missing, hits, small, zoned))
				end,
			})
		end
	end
end

return views
