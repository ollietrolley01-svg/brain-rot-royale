-- Ziplines: a rope from a high anchor down to a low one, ridden from the top. Landmarks hang
-- them off their high points (the Signal Hill platform, the Beacon's gallery, the Rot Bowl's top
-- tier, the Sigma Spire's roof) and every plateau has one down from its rim, so the high ground
-- has a fast way off it.
--
-- The server builds the posts, the rope and the handle with its prompt, and checks the rider is
-- really at the top; the ride itself is the rider's own client moving their character along the
-- line (ZiplineClient), since that's who simulates it. Jump to let go early.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local ZiplineService = {}

local ride = Remotes.Event("Zipline")

local RIDE_SPEED = 54
-- How far below the rope the character hangs.
local HANG = 4.4
local POST_HEIGHT = 9
local REACH = 16

local IRON = Color3.fromRGB(58, 60, 68)
local STEEL = Color3.fromRGB(160, 164, 172)
local ROPE = Color3.fromRGB(46, 44, 50)
local HANDLE = Color3.fromRGB(255, 196, 64)

local function piece(parent, size, cframe, color, material, shape)
	local part = Instance.new("Part")
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function decor(part)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

-- A zipline from ground point `from` (the high end; a post goes up from it) to ground point `to`.
-- `fromTop`, if given, is where the rope starts instead of a post — a platform's rail, say.
function ZiplineService.Create(parent, from, to, fromTop)
	local topA = fromTop or (from + Vector3.new(0, POST_HEIGHT, 0))
	local topB = to + Vector3.new(0, POST_HEIGHT, 0)
	if topB.Y >= topA.Y - 4 then
		-- Not a drop: nobody would move along it.
		return nil
	end

	local model = Instance.new("Model")
	model.Name = "Zipline"

	-- Post, base plate and landing mat all start below the ground at staggered depths (post -0.3,
	-- plate -0.2, mat -0.1). They all used to start exactly at the ground, and their bottom faces on
	-- one plane were three flush pairs on every zipline for the map's z-fight pass to nudge. What
	-- shows above the ground is unchanged.
	local function post(foot)
		piece(model, Vector3.new(POST_HEIGHT + 0.3, 1.2, 1.2), CFrame.new(foot + Vector3.new(0, POST_HEIGHT / 2 - 0.15, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			IRON, Enum.Material.Metal, Enum.PartType.Cylinder)
		piece(model, Vector3.new(3, 0.8, 3), CFrame.new(foot + Vector3.new(0, 0.2, 0)), IRON, Enum.Material.DiamondPlate)
	end
	if not fromTop then
		post(from)
	end
	post(to)
	-- A crossbar on each post the rope runs from, and a landing mat at the bottom.
	for _, top in ipairs({ topA, topB }) do
		decor(piece(model, Vector3.new(0.5, 0.5, 2.4), CFrame.lookAt(top, top + Vector3.new(topB.X - topA.X, 0, topB.Z - topA.Z)) * CFrame.Angles(0, math.pi / 2, 0),
			STEEL, Enum.Material.Metal))
	end
	decor(piece(model, Vector3.new(7, 0.4, 7), CFrame.new(to + Vector3.new(0, 0.1, 0)), Color3.fromRGB(200, 60, 70), Enum.Material.Fabric))

	-- The rope, and the handle hanging from it at the top.
	local length = (topB - topA).Magnitude
	decor(piece(model, Vector3.new(length, 0.28, 0.28), CFrame.lookAt(topA:Lerp(topB, 0.5), topB) * CFrame.Angles(0, math.pi / 2, 0), ROPE,
		Enum.Material.Fabric, Enum.PartType.Cylinder))
	local direction = (topB - topA).Unit
	local handleAt = topA + direction * 2
	-- The hanger runs from inside the rope down into the handle. It is narrower than the handle is
	-- thick, so on a rope running along a world axis its faces don't lie 0.05 from the handle's (two
	-- flush pairs), and it reaches up into the rope (it stopped 0.06 under it).
	decor(piece(model, Vector3.new(0.3, 1.55, 0.3), CFrame.new(handleAt - Vector3.new(0, 0.825, 0)), STEEL, Enum.Material.Metal))
	local handle = decor(piece(model, Vector3.new(2.6, 0.5, 0.5), CFrame.lookAt(handleAt - Vector3.new(0, 1.8, 0), handleAt - Vector3.new(0, 1.8, 0) + direction)
		* CFrame.Angles(0, math.pi / 2, 0), HANDLE, Enum.Material.Neon))
	handle.Name = "ZiplineHandle"
	handle.CanQuery = true

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Ride"
	prompt.ObjectText = "Zipline"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	-- B, not Roblox's default X: X is Reload in a match, so a pad player reloading within 12 studs of a
	-- handle also rode the line. The same fix and reason as LootService's makePrompt (#86).
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonB
	prompt.Parent = handle

	prompt.Triggered:Connect(function(player)
		if not model.Parent then
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid or humanoid.Health <= 0 then
			return
		end
		if (root.Position - handleAt).Magnitude > REACH then
			return
		end
		-- `line`: the rider lets go if it is gone mid-ride (shot out: DestructibleService snaps the
		-- whole line as one thing).
		ride:FireClient(player, { from = topA, to = topB, speed = RIDE_SPEED, hang = HANG, line = model })
	end)

	model.Parent = parent
	return model
end

return ZiplineService
