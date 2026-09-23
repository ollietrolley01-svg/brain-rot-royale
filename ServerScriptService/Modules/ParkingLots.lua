-- Parking lots for the towns (Oliver's #31, "real parking lots for cars to spawn on"; landed
-- 2026-09-22 on "land the parking lots feature too").
--
-- Each town gets one painted car park near its square: flat asphalt (MapTerrain.FlattenPad, so it is
-- never on a slope or floating), white bay lines, and a "P" sign. The bays are published on the town as
-- the attributes VehicleService.ParkInTowns already reads (it was written ahead of this and did nothing
-- while no town had any):
--   ParkingBays      how many
--   ParkingBay_<i>   CFrame at the bay's centre on the asphalt, LookVector = the way the car's nose points
--   ParkingBaySize   Vector3 (width, 1, length), TownKinds.Bay
-- The bay count comes from the town's kind (TownKinds `bays.count`), clamped to 4..12.
--
--   ParkingLots.Build(town, center, spread, count, space, rectFree) -> number of bays, or 0
--
-- A site that is taken, reaches a road's corridor, or would need more than MAX_CUT / MAX_FILL of
-- earthworks is skipped for the next candidate. If none fit, the town simply has no car park and its
-- cars stay on the verge, as before; nothing is ever built unpadded.

local ServerScriptService = game:GetService("ServerScriptService")
local Modules = ServerScriptService:WaitForChild("Modules")
local MapTerrain = require(Modules:WaitForChild("MapTerrain"))
local TownKinds = require(Modules:WaitForChild("TownKinds"))

local ParkingLots = {}

local BAY = TownKinds.Bay or { width = 8.9, length = 16.6 }
local AISLE = 9 -- drive aisle between two rows, or in front of one
local EDGE = 2 -- asphalt round the bays
local MAX_CUT, MAX_FILL = 7, 7
local LINE = Color3.fromRGB(238, 238, 232)

local function part(parent, size, cframe, color, material)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function sign(parent, at, facing)
	local post = part(parent, Vector3.new(0.4, 6, 0.4), CFrame.new(at + Vector3.new(0, 3, 0)), Color3.fromRGB(90, 94, 100), Enum.Material.Metal)
	post.CanCollide = true
	post.CanQuery = true
	local board = part(parent, Vector3.new(2.6, 2.6, 0.25),
		CFrame.lookAt(at + Vector3.new(0, 6.4, 0), at + Vector3.new(0, 6.4, 0) + facing), Color3.fromRGB(40, 90, 200))
	board.CanQuery = true
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.CanvasSize = Vector2.new(100, 100)
		gui.LightInfluence = 0.3
		gui.Parent = board
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBlack
		label.Text = "P"
		label.TextScaled = true
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Parent = gui
	end
end

function ParkingLots.Build(town, center, spread, count, space, rectFree)
	if not town or not center or not space or not rectFree then
		return 0
	end
	count = math.clamp(math.floor(count or 6), 4, 12)
	local rows = count > 6 and 2 or 1
	local perRow = math.ceil(count / rows)
	local width = perRow * BAY.width + EDGE * 2
	local depth = rows * BAY.length + AISLE + EDGE * 2
	local halfX, halfZ = width / 2 + 2, depth / 2 + 2

	local c = Vector3.new(center.X, 0, center.Z)
	-- Candidates: eight directions at three distances out from the square, nearest first, the lot's
	-- aisle side (+Z of the lot) facing back toward the square so it reads as the town's car park.
	local candidates = {}
	for _, distance in ipairs({ spread * 0.55, spread * 0.8, spread + 12 }) do
		for index = 0, 7 do
			local angle = index / 8 * math.pi * 2 + distance * 0.013
			table.insert(candidates, c + Vector3.new(math.cos(angle), 0, math.sin(angle)) * (distance + halfZ))
		end
	end

	for _, at in ipairs(candidates) do
		local toSquare = c - at
		-- yaw such that the lot's +Z points at the square.
		local yaw = math.atan2(toSquare.X, toSquare.Z)
		local frame = CFrame.new(at.X, 0, at.Z) * CFrame.Angles(0, yaw, 0)
		if rectFree(space, at.X, at.Z, yaw, halfX, halfZ, nil) then
			local ok, height = pcall(MapTerrain.FlattenPad, frame, Vector3.new(width, 0, depth), {
				height = "mean", margin = 2, maxCut = MAX_CUT, maxFill = MAX_FILL,
				material = Enum.Material.Asphalt, space = space,
			})
			if ok and type(height) == "number" then
				space:AddRect(at.X, at.Z, halfX, halfZ, yaw)
				local lot = Instance.new("Model")
				lot.Name = "ParkingLot"
				lot.Parent = town
				local base = frame + Vector3.new(0, height, 0)
				local bays = {}
				for row = 1, rows do
					-- Row 1 backs onto the lot's far edge (-Z) with noses pointing out that way; row 2
					-- backs onto the near edge (+Z). The aisle runs between them, or in front of row 1.
					local sign_ = row == 1 and -1 or 1
					local rowZ = sign_ * (depth / 2 - EDGE - BAY.length / 2)
					if rows == 1 then
						rowZ = -depth / 2 + EDGE + BAY.length / 2
					end
					local inRow = row == 1 and perRow or (count - perRow)
					for i = 1, inRow do
						local x = -width / 2 + EDGE + (i - 0.5) * BAY.width
						local centre = base * CFrame.new(x, 0, rowZ)
						local nose = base:VectorToWorldSpace(Vector3.new(0, 0, sign_))
						table.insert(bays, CFrame.lookAt(centre.Position, centre.Position + nose))
					end
					-- Bay lines: one at each side of every bay, running the bay's length.
					for i = 0, inRow do
						local x = -width / 2 + EDGE + i * BAY.width
						part(lot, Vector3.new(0.3, 0.06, BAY.length - 1), base * CFrame.new(x, 0.04, rowZ), LINE)
					end
					-- The line across the back of the row.
					part(lot, Vector3.new(inRow * BAY.width, 0.06, 0.3),
						base * CFrame.new(-width / 2 + EDGE + inRow * BAY.width / 2, 0.04, rowZ + sign_ * (BAY.length / 2 - 0.3)), LINE)
				end
				sign(lot, (base * CFrame.new(width / 2 - 1, 0, depth / 2 - 1)).Position, base.LookVector * -1)

				town:SetAttribute("ParkingBays", #bays)
				town:SetAttribute("ParkingBaySize", Vector3.new(BAY.width, 1, BAY.length))
				for index, cf in ipairs(bays) do
					town:SetAttribute("ParkingBay_" .. index, cf)
				end
				return #bays
			end
		end
	end
	return 0
end

return ParkingLots
