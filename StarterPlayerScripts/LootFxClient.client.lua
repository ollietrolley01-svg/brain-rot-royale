-- Opening animations for chests and supply crates on the map.
--
-- The server marks a claimed container with an "Opened" attribute (and "LootRarity" for what
-- came out) and keeps it around for a moment before removing it. Here, locally: the lid swings
-- back on its hinge, a column of light in the loot's rarity colour shoots up, and sparks
-- scatter. Nothing replicates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rarity = require(Shared:WaitForChild("Rarity"))

local Sfx = require(script.Parent:WaitForChild("Sfx"))

local EFFECT_DISTANCE = 400
local CONTAINERS = { Chest = true, SupplyCrate = true }

local camera = workspace.CurrentCamera
-- Containers already wired up, dropped when they're destroyed. (A weak-keyed table loses live
-- Instances: Roblox collects an instance's Lua handle when only a weak table holds it.)
local watched = {}

local fxFolder = Instance.new("Folder")
fxFolder.Name = "LootFx"
fxFolder.Parent = workspace

local function neon(size, cframe, color, transparency)
	local part = Instance.new("Part")
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = transparency or 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = fxFolder
	return part
end

local function swingLid(container)
	local lid = container:FindFirstChild("Lid")
	if not lid or not lid:IsA("BasePart") then
		return
	end

	-- Supply crate lids are welded so they fall with the crate; free this copy to animate it.
	local weld = lid:FindFirstChildOfClass("WeldConstraint")
	if weld then
		weld.Enabled = false
	end
	lid.Anchored = true

	-- Anything decorating the lid (bands, the lock) swings with it.
	local attached = {}
	for _, descendant in ipairs(lid:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(attached, { part = descendant, offset = lid.CFrame:ToObjectSpace(descendant.CFrame) })
		end
	end

	-- Hinged along the back edge (+Z; containers face -Z), swinging the front up and over.
	local length = lid.Size.Z
	local hinge = lid.CFrame * CFrame.new(0, 0, length / 2)

	local driver = Instance.new("NumberValue")
	driver.Changed:Connect(function(value)
		if not lid.Parent then
			return
		end
		local frame = hinge * CFrame.Angles(math.rad(105) * value, 0, 0) * CFrame.new(0, 0, -length / 2)
		lid.CFrame = frame
		for _, entry in ipairs(attached) do
			entry.part.CFrame = frame * entry.offset
		end
	end)
	TweenService:Create(driver, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Value = 1 }):Play()
	task.delay(0.6, function()
		driver:Destroy()
	end)
end

local function playOpen(container)
	if not container.Parent then
		return
	end
	local position = container.Position
	if (position - camera.CFrame.Position).Magnitude > EFFECT_DISTANCE then
		return
	end

	local color = Rarity.Color(container:GetAttribute("LootRarity") or "Rare")
	local top = position + Vector3.new(0, container.Size.Y / 2, 0)

	swingLid(container)
	Sfx.PlayAt("CrateOpen", position, 0.1)

	-- Column of light.
	local column = neon(Vector3.new(1.4, 0.5, 1.4), CFrame.new(top), color, 0.15)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 20
	light.Brightness = 4
	light.Parent = column
	TweenService:Create(column, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.4, 16, 0.4),
		CFrame = CFrame.new(top + Vector3.new(0, 8, 0)),
		Transparency = 1,
	}):Play()
	TweenService:Create(light, TweenInfo.new(0.8), { Brightness = 0 }):Play()
	task.delay(0.85, function()
		column:Destroy()
	end)

	-- Sparks.
	for _ = 1, 10 do
		local spark = neon(Vector3.new(0.35, 0.35, 0.35), CFrame.new(top), color, 0)
		local direction = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
		direction = direction.Magnitude > 0.01 and direction.Unit or Vector3.new(1, 0, 0)
		local goal = top + direction * (3 + math.random() * 3) + Vector3.new(0, 3 + math.random() * 4, 0)
		local time = 0.55 + math.random() * 0.35
		TweenService:Create(spark, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(goal) * CFrame.Angles(math.random() * 6, math.random() * 6, 0),
			Transparency = 1,
		}):Play()
		task.delay(time + 0.05, function()
			spark:Destroy()
		end)
	end
end

local function watch(item)
	if watched[item] or not item:IsA("BasePart") or not CONTAINERS[item.Name] then
		return
	end
	watched[item] = true
	item.Destroying:Connect(function()
		watched[item] = nil
	end)
	item:GetAttributeChangedSignal("Opened"):Connect(function()
		if item:GetAttribute("Opened") then
			playOpen(item)
		end
	end)
end

-- Loot and SupplyDrops folders are recreated every match, so watch for them arriving.
local function watchFolder(name)
	local function hook(folder)
		if folder.Name ~= name or not folder:IsA("Folder") then
			return
		end
		for _, child in ipairs(folder:GetChildren()) do
			watch(child)
		end
		folder.ChildAdded:Connect(watch)
	end

	local existing = workspace:FindFirstChild(name)
	if existing then
		hook(existing)
	end
	workspace.ChildAdded:Connect(hook)
end

watchFolder("Loot")
watchFolder("SupplyDrops")
