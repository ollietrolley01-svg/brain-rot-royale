-- Isolated Creator Store candidate review.  Nothing here is used by the game or saved into the
-- production place.  Each asset is loaded while unparented, all executable/interactive objects are
-- removed, and only then is the inert art parented into the temporary gallery scene.

local InsertService = game:GetService("InsertService")

local CANDIDATES = {
	{ name = "Tung Tung Tung Sahur", id = 138151705692565, creator = "ATMnou" },
	{ name = "Bombardiro Crocodilo", id = 91327024837680, creator = "F0g_02" },
	{ name = "Tralalero Tralala", id = 129482668414941, creator = "F0g_02" },
	{ name = "Chimpanzini Bananini", id = 83732984780551, creator = "xXH3nry_AltXx" },
	{ name = "Boneca Ambalabu", id = 125906339004688, creator = "Haxcyc_LDC" },
	{ name = "Lirili Larila", id = 77231614368559, creator = "giacomorixYT" },
	{ name = "Ballerina Cappuccina", id = 75983792852042, creator = "hexsunez251" },
	{ name = "Brr Brr Patapim", id = 100538198930997, creator = "Haxcyc_LDC" },
	{ name = "Frigo Camelo", id = 136392638607318, creator = "Thaiskiy" },
	{ name = "Bombombini Gusini", id = 76661728011648, creator = "Luciano_Lol97" },
	{ name = "La Vacca Saturno Saturnita", id = 79911767286448, creator = "hexsunez251" },
}

local ORIGIN = Vector3.new(6000, 400, 6000)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function pad(folder)
	local floor = Instance.new("Part")
	floor.Name = "Pad"
	floor.Anchored = true
	floor.Size = Vector3.new(22, 1, 18)
	floor.CFrame = CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0))
	floor.Color = Color3.fromRGB(140, 144, 152)
	floor.Parent = folder
	local wall = floor:Clone()
	wall.Name = "Backdrop"
	wall.Size = Vector3.new(22, 30, 1)
	wall.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 15, 9))
	wall.Color = Color3.fromRGB(202, 207, 216)
	wall.Parent = folder
end

local function inert(container)
	local removedScripts = 0
	for _, object in ipairs(container:GetDescendants()) do
		if object:IsA("LuaSourceContainer") or object:IsA("RemoteEvent") or object:IsA("RemoteFunction")
			or object:IsA("BindableEvent") or object:IsA("BindableFunction") or object:IsA("ClickDetector")
			or object:IsA("ProximityPrompt") or object:IsA("Tool") or object:IsA("Sound") then
			if object:IsA("LuaSourceContainer") then removedScripts += 1 end
			object:Destroy()
		elseif object:IsA("BasePart") then
			object.Anchored = true
			object.CanCollide = false
			object.CanTouch = false
			object.CanQuery = false
		end
	end
	return removedScripts
end

local function loadCandidate(candidate)
	local ok, package = pcall(InsertService.LoadAsset, InsertService, candidate.id)
	if not ok or not package then
		return nil, "LoadAsset failed: " .. tostring(package)
	end
	local removedScripts = inert(package)
	local art = Instance.new("Model")
	art.Name = candidate.name
	for _, child in ipairs(package:GetChildren()) do
		child.Parent = art
	end
	package:Destroy()
	local partCount, meshCount = 0, 0
	for _, object in ipairs(art:GetDescendants()) do
		if object:IsA("BasePart") then
			partCount += 1
			if object:IsA("MeshPart") then
				meshCount += 1
			end
		end
	end
	if partCount == 0 then
		art:Destroy()
		return nil, "asset contained no geometry"
	end
	local _, initialSize = art:GetBoundingBox()
	art:ScaleTo(5 / math.max(initialSize.Y, 0.1))
	local box, size = art:GetBoundingBox()
	art:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, size.Y / 2, 0)) * CFrame.Angles(0, -0.2, 0) * box:ToObjectSpace(art:GetPivot()))
	return art, string.format("%d parts, %d meshes, %d script(s) stripped", partCount, meshCount, removedScripts)
end

local views = {}
for index, candidate in ipairs(CANDIDATES) do
	table.insert(views, {
		name = string.format("asset_%02d_%s_%s", index, string.gsub(candidate.name, "[^%w]", ""), tostring(candidate.id)),
		settle = 1.5,
		hold = 3,
		setup = function(folder, camera)
			pad(folder)
			local art, result = loadCandidate(candidate)
			if not art then
				error(string.format("%s (%s): %s", candidate.name, tostring(candidate.id), result))
			end
			art.Parent = folder
			local box, size = art:GetBoundingBox()
			local fov = 30
			local half = math.max(size.X, size.Y, size.Z) / 2
			local distance = half / math.tan(math.rad(fov) / 2) * 1.25 + 1.5
			camera.FieldOfView = fov
			camera.CFrame = CFrame.lookAt(box.Position + Vector3.new(distance * 0.2, size.Y * 0.16, -distance), box.Position)
			note(string.format("candidate %s | asset %s | by %s | %s", candidate.name, tostring(candidate.id), candidate.creator, result))
		end,
	})
end

return views
