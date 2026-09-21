-- The placement ghost for a sticky throwable (the Clingy Crumpet): a translucent copy of the item's
-- own model standing where the throw will stick, underside on the surface, green when the throw
-- meets something it can hold and red when it meets nothing (out of range, over the edge). No
-- text: the ghost, its tint and ProjectileClient's dotted arc say it, the way DefensePreview does
-- for a barricade. A ModuleScript so ProjectileClient drives it and tools/throwables_gallery.lua
-- renders it without a match.
--
--   StickyPreview.Show(itemId, position, normal, valid)   the ghost at a surface point, facing out
--   StickyPreview.Hide()
--
-- The ghost's parts never collide, query or touch, so neither the throw preview's own sweeps nor
-- anyone's raycasts see it, and it lives in BRR_Throwables, one of the folders DefensePreview
-- already leaves out of its site checks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))

local StickyPreview = {}

StickyPreview.ValidColor = Color3.fromRGB(94, 214, 122)
StickyPreview.InvalidColor = Color3.fromRGB(232, 92, 92)
StickyPreview.Transparency = 0.55

-- { itemId, model, parts = { { part, color } }, valid }
local ghost = nil

local function folder()
	local existing = workspace:FindFirstChild("BRR_Throwables")
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "BRR_Throwables"
	created.Parent = workspace
	return created
end

local function build(itemId)
	local model = ItemModels.Build(itemId, { name = "BRR_StickyGhost" })
	if not model then
		return nil
	end
	local parts = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			if part.Transparency < 1 then
				part.Material = Enum.Material.SmoothPlastic
				part.Transparency = StickyPreview.Transparency
				table.insert(parts, { part = part, color = part.Color })
			end
		end
	end
	return { itemId = itemId, model = model, parts = parts, valid = nil }
end

function StickyPreview.Show(itemId, position, normal, valid)
	if ghost and ghost.itemId ~= itemId then
		StickyPreview.Hide()
	end
	if not ghost then
		ghost = build(itemId)
		if not ghost then
			return
		end
	end
	if ghost.valid ~= valid then
		ghost.valid = valid
		local tint = valid and StickyPreview.ValidColor or StickyPreview.InvalidColor
		for _, entry in ipairs(ghost.parts) do
			entry.part.Color = entry.color:Lerp(tint, 0.65)
		end
	end
	local spec = Ballistics.Throwables[itemId]
	ghost.model:PivotTo(Ballistics.StuckFrame(position, normal, spec and spec.stickOffset or 0))
	if ghost.model.Parent == nil then
		ghost.model.Parent = folder()
	end
end

function StickyPreview.Hide()
	if ghost then
		ghost.model:Destroy()
		ghost = nil
	end
end

-- For the gallery and probes: the live ghost model, or nil.
function StickyPreview.Model()
	return ghost and ghost.model or nil
end

return StickyPreview
