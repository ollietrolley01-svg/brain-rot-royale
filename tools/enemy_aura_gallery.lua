-- Does the enemy aura show through walls? (Oliver's list #27.)
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/enemy_aura_gallery.lua -OutDir <dir>
--
-- The requirement is "red aura, must NOT show through walls", and the failure mode is silent: a
-- Highlight defaults to DepthMode AlwaysOnTop, which draws over every wall in the map and hands
-- every player a wallhack. Nobody would see that in a code review; it looks like a highlight.
--
-- So this renders three figures behind three identical walls:
--
--   LEFT    Occluded, no wall in front      -- what the player should see: a red enemy
--   MIDDLE  Occluded, wall in front         -- the requirement: the wall hides it
--   RIGHT   AlwaysOnTop, wall in front      -- the PLANTED FAULT: glows through the wall
--
-- The right-hand one is there so the picture can fail. If all three looked the same, the render
-- would be proving nothing about depth and I would not be able to tell. It is also exactly what
-- ships if someone deletes one line from EnemyAura.client.lua.
--
-- It also reads StarterPlayerScripts.EnemyAura's own source and asserts the line is there, so the
-- picture and the shipped script cannot drift apart.

local StarterPlayer = game:GetService("StarterPlayer")

local AURA_COLOR = Color3.fromRGB(232, 92, 92)

local views = {}
local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function part(parent, size, cframe, color, props)
	local p = Instance.new("Part")
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props or {}) do
		p[key] = value
	end
	p.Parent = parent
	return p
end

-- A blocky stand-in for a player: a Highlight adorns any Model, and the shape is irrelevant to
-- whether a wall occludes it.
local function figure(parent, x, depthMode, wall)
	local model = Instance.new("Model")
	model.Name = "Figure"
	model.Parent = parent

	local torso = part(model, Vector3.new(2, 3, 1), CFrame.new(x, 4.5, 0), Color3.fromRGB(70, 80, 105))
	part(model, Vector3.new(1.6, 1.6, 1.6), CFrame.new(x, 7.1, 0), Color3.fromRGB(90, 100, 125))
	part(model, Vector3.new(0.8, 3, 0.8), CFrame.new(x - 1.4, 4.5, 0), Color3.fromRGB(70, 80, 105))
	part(model, Vector3.new(0.8, 3, 0.8), CFrame.new(x + 1.4, 4.5, 0), Color3.fromRGB(70, 80, 105))
	part(model, Vector3.new(0.9, 3, 0.9), CFrame.new(x - 0.5, 1.5, 0), Color3.fromRGB(58, 66, 88))
	part(model, Vector3.new(0.9, 3, 0.9), CFrame.new(x + 0.5, 1.5, 0), Color3.fromRGB(58, 66, 88))
	model.PrimaryPart = torso

	local aura = Instance.new("Highlight")
	aura.FillColor = AURA_COLOR
	aura.FillTransparency = 0.65
	aura.OutlineColor = AURA_COLOR
	aura.OutlineTransparency = 0.15
	aura.DepthMode = depthMode
	aura.Adornee = model
	aura.Parent = model

	if wall then
		-- Between the camera and the figure, not touching it.
		part(parent, Vector3.new(7, 9, 1), CFrame.new(x, 4.5, 7), Color3.fromRGB(120, 116, 110))
	end
	return model
end

table.insert(views, {
	name = "enemy_aura_through_walls",
	settle = 1.0,
	setup = function(folder, camera)
		part(folder, Vector3.new(60, 1, 40), CFrame.new(0, 0, 0), Color3.fromRGB(86, 122, 78))

		figure(folder, -14, Enum.HighlightDepthMode.Occluded, false)
		figure(folder, 0, Enum.HighlightDepthMode.Occluded, true)
		figure(folder, 14, Enum.HighlightDepthMode.AlwaysOnTop, true)

		camera.CFrame = CFrame.lookAt(Vector3.new(0, 7, 34), Vector3.new(0, 4.5, 0))

		-- The shipped script must set Occluded, and must not set AlwaysOnTop anywhere.
		local script_ = StarterPlayer:FindFirstChild("StarterPlayerScripts")
		local source = script_ and script_:FindFirstChild("EnemyAura")
		if source then
			local text = source.Source
			-- The ASSIGNMENT, not the word. The first version of this check searched for
			-- "AlwaysOnTop" anywhere and reported the script as faulty because its comment explains
			-- what AlwaysOnTop would do. A check that a correct file fails is a check nobody will
			-- believe the third time it fires.
			local occluded = string.find(text, "DepthMode = Enum.HighlightDepthMode.Occluded", 1, true) ~= nil
			local assignsTop = string.find(text, "DepthMode = Enum.HighlightDepthMode.AlwaysOnTop", 1, true) ~= nil
			note(string.format("EnemyAura source: assigns Occluded = %s, assigns AlwaysOnTop = %s (want true / false)",
				tostring(occluded), tostring(assignsTop)))
		else
			note("EnemyAura source: NOT FOUND in StarterPlayerScripts")
		end
		note("left: occluded, no wall (visible). middle: occluded behind a wall (must be hidden). "
			.. "right: AlwaysOnTop behind the same wall -- the planted fault, must glow through.")
	end,
})

return views
