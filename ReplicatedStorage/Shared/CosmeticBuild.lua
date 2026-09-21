-- Builds the pieces of an accessory from its CosmeticData entry.
--
-- AccessoryService welds the result onto a wearer; the menu and the crate reveal build the same
-- pieces into a ViewportFrame. Both go through here so a preview is the geometry the player actually
-- gets, rather than a second drawing of it that drifts the first time a design changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))

local CosmeticBuild = {}

-- Pieces are authored against an R15 head this tall; everything scales from it.
CosmeticBuild.ReferenceHeadHeight = 1.2

-- One piece. `origin` is the anchor frame its offset is relative to, `scale` how much bigger the
-- wearer's head is than the reference one.
function CosmeticBuild.Piece(spec, origin, scale, fallbackColor)
	-- "Wedge" is a real WedgePart: its profile is a right triangle, full height at +Z falling to an
	-- edge at -Z, so a pair back to back makes a point rather than a staircase of blocks.
	local part = Instance.new(spec.shape == "Wedge" and "WedgePart" or "Part")
	if spec.shape == "Ball" then
		part.Shape = Enum.PartType.Ball
	elseif spec.shape == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder
	end
	part.Size = spec.size * scale

	local offset = spec.offset or CFrame.new()
	part.CFrame = origin * CFrame.new(offset.Position * scale) * offset.Rotation

	part.Color = spec.color or fallbackColor
	part.Material = spec.material or Enum.Material.SmoothPlastic
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = part.Material ~= Enum.Material.Neon
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	if spec.shape == "Sphere" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
	end

	return part
end

-- Every piece of `item`, in a Model, with no two faces left flush. Unparented and unwelded: the
-- caller decides where it goes and what holds it there.
function CosmeticBuild.Model(item, origin, scale, name)
	local model = Instance.new("Model")
	model.Name = name or "Cosmetic"

	local pieces = {}
	for index, spec in ipairs(item.parts) do
		local part = CosmeticBuild.Piece(spec, origin, scale or 1, item.color)
		part.Name = "Piece" .. index
		part.Parent = model
		table.insert(pieces, part)
	end

	ZFight.Fix({ model }, { all = true })
	return model, pieces
end

return CosmeticBuild
