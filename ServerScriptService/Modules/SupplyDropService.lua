-- Supply drops: a crate falls into the safe zone partway through the match carrying a
-- weapon better than anything on the floor.
--
-- The point is to manufacture conflict. Once the first circle closes, players who found
-- good loot have no reason to move and players who didn't have no way to catch up. A
-- contested, announced, map-marked objective fixes both.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemData = require(Shared:WaitForChild("ItemData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local DestructibleService = require(script.Parent:WaitForChild("DestructibleService"))
local LootService = require(script.Parent:WaitForChild("LootService"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))
local StormService = require(script.Parent:WaitForChild("StormService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local SupplyDropService = {}

local FIRST_DROP_DELAY = 75
local DROP_INTERVAL = 95
local FALL_HEIGHT = 420
local FALL_TIME = 9

-- Seconds between drops this match, and before the first; a Loot Frenzy or Hot Drops match
-- shortens them (nil puts them back).
local dropInterval = DROP_INTERVAL
local firstDelay = FIRST_DROP_DELAY

function SupplyDropService.SetInterval(seconds, first)
	dropInterval = seconds or DROP_INTERVAL
	firstDelay = first or FIRST_DROP_DELAY
end

-- Drops are the only reliable source of Legendary weapons, which is what makes them worth
-- fighting over rather than just looting if convenient.
local DROP_ODDS = { Common = 0, Uncommon = 0, Rare = 26, Epic = 46, Legendary = 28 }

local supplyDrop = Remotes.Event("SupplyDrop")

local running = false
local generation = 0
local container = nil

-- Each drop gets an integer id so clients can match "claimed" to the right marker without
-- comparing float positions across a serialisation boundary.
local dropCounter = 0

local function ensureContainer()
	if container and container.Parent then
		return container
	end
	container = Instance.new("Folder")
	container.Name = "SupplyDrops"
	container.Parent = workspace
	return container
end

-- A gun for the crate. `staged` guns are held back from players (a design still being tested), and
-- this pool used to ignore that and hand them out, since it reads WeaponData directly rather than
-- going through the loot weights.
local function rollWeapon()
	local rarity = Rarity.Roll(DROP_ODDS)
	local pool = {}
	for _, def in pairs(WeaponData.Weapons) do
		if def.rarity == rarity and not def.staged then
			table.insert(pool, def)
		end
	end
	if #pool == 0 then
		return WeaponData.Get("CrocodiloRifle")
	end
	return pool[math.random(1, #pool)]
end

-- For tools/audit_supplydrop_staged.lua, so the roll can be sampled without dropping crates.
SupplyDropService.RollWeapon = rollWeapon

local function buildCrate(def, landingPosition)
	local parent = ensureContainer()
	local color = Rarity.Color(def.rarity)

	local crate = Instance.new("Part")
	crate.Name = "SupplyCrate"
	crate.Size = Vector3.new(9, 8, 9)
	crate.Color = Color3.fromRGB(146, 112, 64)
	crate.Material = Enum.Material.WoodPlanks
	crate.Anchored = true
	crate.CFrame = CFrame.new(landingPosition + Vector3.new(0, FALL_HEIGHT, 0))

	-- Rarity-coloured band so you can read the tier before you reach it. Must be unanchored:
	-- an anchored part ignores its weld, so the band would stay hanging in the sky while the
	-- crate tweened down away from it.
	local band = Instance.new("Part")
	band.Name = "Band"
	band.Size = Vector3.new(9.4, 1.6, 9.4)
	band.Color = color
	band.Material = Enum.Material.Neon
	band.Anchored = false
	band.CanCollide = false
	band.CanQuery = false
	band.Massless = true
	band.CFrame = crate.CFrame
	band.Parent = crate

	-- Lid, welded like the band so it falls with the crate. LootFxClient flips it open locally
	-- when the crate is claimed.
	local lid = Instance.new("Part")
	lid.Name = "Lid"
	lid.Size = Vector3.new(9.6, 1.2, 9.6)
	lid.Color = Color3.fromRGB(120, 90, 52)
	lid.Material = Enum.Material.WoodPlanks
	lid.Anchored = false
	lid.CanCollide = false
	lid.CanQuery = false
	lid.Massless = true
	lid.CFrame = crate.CFrame * CFrame.new(0, 4.6, 0)
	lid.Parent = crate

	-- No two faces left flush, then the welds (after, so only the one part moved).
	ZFight.Fix({ crate }, { all = true, terrain = false })

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = crate
	weld.Part1 = band
	weld.Parent = band

	local lidWeld = Instance.new("WeldConstraint")
	lidWeld.Part0 = crate
	lidWeld.Part1 = lid
	lidWeld.Parent = lid

	-- Beacon: visible from across the map, which is the whole point.
	local beam = Instance.new("Part")
	beam.Name = "Beacon"
	beam.Size = Vector3.new(6, 900, 6)
	beam.Color = color
	beam.Material = Enum.Material.Neon
	beam.Transparency = 0.72
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.CFrame = CFrame.new(landingPosition + Vector3.new(0, 450, 0))
	beam.Parent = parent

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 60
	light.Brightness = 3
	light.Parent = crate

	-- Parented last, with the welded band and light already attached, so the crate enters the
	-- world whole. The band's CFrame was set from the crate's above, so the weld holds position.
	crate.Parent = parent

	return crate, beam
end

-- Shared end of every claim, player or bot. The beacon is parented under the crate, so
-- destroying the crate always takes its own beacon with it.
local function finishCrate(crate)
	local dropId = crate:GetAttribute("DropId")

	-- Stays long enough for clients to play the lid flip (LootFxClient watches "Opened").
	-- `Claimed` is already set by both callers, so nothing can claim it again meanwhile.
	crate:SetAttribute("Opened", true)
	local prompt = crate:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Enabled = false
	end
	task.delay(1.6, function()
		if crate.Parent then
			crate:Destroy()
		end
	end)

	-- Tell clients so the minimap marker goes away with the crate.
	supplyDrop:FireAllClients({ claimed = true, dropId = dropId })
end

local function attachPrompt(crate, def, beam, landing)
	-- Everything a claim needs lives on the crate itself. "Claimed" used to be a local inside
	-- the player prompt's closure, which a bot claim couldn't see — so a bot and a player could
	-- both have been granted the same drop.
	crate:SetAttribute("WeaponId", def.id)
	crate:SetAttribute("LootRarity", def.rarity)
	crate:SetAttribute("Landing", landing)
	crate:SetAttribute("Landed", true)
	if beam and beam.Parent then
		beam.Parent = crate
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Take"
	prompt.ObjectText = def.name
	prompt.HoldDuration = 1.2
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	-- B, not the default X: X is Reload, so a pad player reloading beside the crate would open it
	-- (#86; the same key LootService's prompts use).
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonB
	prompt.Parent = crate

	-- Bots give way to a player who's already mid-hold, same as with chests.
	prompt.PromptButtonHoldBegan:Connect(function()
		crate:SetAttribute("PlayerHolding", true)
	end)
	prompt.PromptButtonHoldEnded:Connect(function()
		crate:SetAttribute("PlayerHolding", false)
	end)

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(10, 2.4)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 220

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = string.upper(def.rarity) .. " SUPPLY DROP"
	label.TextColor3 = Rarity.Color(def.rarity)
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.Parent = billboard

	-- The crate has landed and is live by now, so the billboard goes on with its label attached.
	billboard.Parent = crate

	prompt.Triggered:Connect(function(player)
		if crate:GetAttribute("Claimed") or not crate.Parent then
			return
		end
		crate:SetAttribute("Claimed", true)
		prompt.Enabled = false

		-- The crate spills onto the ground the way a chest does (#85, Oliver 2026-09-22: "chests and
		-- supply drops should drop contents on the ground, not into inventory"): the gun, the
		-- recovery and the bunker land in front of the crate, toward whoever opened it, and are
		-- picked up the normal way, so a full loadout is the opener's choice rather than a swap. Seven
		-- studs out, not a chest's four: the crate is nine wide and stands for a moment yet.
		-- Ammo still goes straight to the opener: there is no ground pickup for ammo.
		local opener = player.Character and player.Character.PrimaryPart
		local toward = opener and (opener.Position - crate.Position) * Vector3.new(1, 0, 1) or Vector3.zero
		local spill = crate.Position + (toward.Magnitude > 0.1 and toward.Unit * 7 or Vector3.new(0, 0, 7))
		LootService.DropWeapon(def.id, spill, nil, crate.Position)
		-- Somewhere to hold what you just fought for: the Pop-up Bunker.
		local spilled = { def.name }
		for _, id in ipairs({ "MedKit", "ShieldPotion", "PopupBunker" }) do
			LootService.DropItem(id, spill, 1, crate.Position)
			table.insert(spilled, ItemData.Get(id).name)
		end
		WeaponService.GiveAmmo(player, 1)
		QuestService.Progress(player, "supply", 1)
		-- Every piece named, the way a chest's toast names its spill: "and supplies" left a first-time
		-- player walking away from a bunker they never knew was there (#86). Kept to the list: the
		-- toast is one unwrapped line on the HUD.
		StateSync.Notify(player, "Supply drop: " .. table.concat(spilled, ", ") .. " on the ground")

		finishCrate(crate)
	end)
end

-- The crate is 8 studs tall. It used to land at a fixed height of 6, so on any hillside it
-- ended up buried in the slope, and in a dip it hovered. Now it lands on whatever surface is
-- actually beneath it, preferring open ground: a spot that would drop it onto a roof or into a
-- tree canopy is re-rolled, so the crate stays reachable. Roads count as ground — they sit
-- flush on the terrain.
local CRATE_HALF_HEIGHT = 4
local LANDING_ATTEMPTS = 12

local function findLanding(storm)
	local radius = math.max(40, storm.radius * 0.55)

	local everything = RaycastParams.new()
	everything.FilterType = Enum.RaycastFilterType.Include
	local include = { workspace.Terrain }
	local map = workspace:FindFirstChild("Map")
	if map then
		table.insert(include, map)
	end
	everything.FilterDescendantsInstances = include

	local terrainOnly = RaycastParams.new()
	terrainOnly.FilterType = Enum.RaycastFilterType.Include
	terrainOnly.FilterDescendantsInstances = { workspace.Terrain }
	-- Through the water to the bed. Rays hit water by default, so over a bay both rays stopped on
	-- the same surface, the roof check below read 0, and the crate was "landed" afloat. Measured
	-- against the bed, deep water fails that check the way a roof does; shallows still pass.
	terrainOnly.IgnoreWater = true

	local fallback = nil
	for _ = 1, LANDING_ATTEMPTS do
		local angle = math.random() * math.pi * 2
		local distance = math.sqrt(math.random()) * radius
		local x = storm.center.X + math.cos(angle) * distance
		local z = storm.center.Z + math.sin(angle) * distance

		local from, down = Vector3.new(x, 1500, z), Vector3.new(0, -3000, 0)
		local surface = workspace:Raycast(from, down, everything)
		if surface then
			local landing = Vector3.new(x, surface.Position.Y + CRATE_HALF_HEIGHT, z)
			local ground = workspace:Raycast(from, down, terrainOnly)
			if not ground or surface.Position.Y - ground.Position.Y < 3 then
				return landing
			end
			fallback = fallback or landing
		end
	end

	return fallback or storm.center + Vector3.new(0, CRATE_HALF_HEIGHT, 0)
end

local function dropOne()
	local storm = StormService.GetState()
	local landing = findLanding(storm)
	local def = rollWeapon()
	local crate, beam = buildCrate(def, landing)

	dropCounter += 1
	local dropId = dropCounter
	crate:SetAttribute("DropId", dropId)

	supplyDrop:FireAllClients({
		dropId = dropId,
		position = landing,
		rarity = def.rarity,
		weapon = def.name,
		incoming = true,
	})

	TweenService:Create(crate, TweenInfo.new(FALL_TIME, Enum.EasingStyle.Linear), {
		CFrame = CFrame.new(landing),
	}):Play()

	task.delay(FALL_TIME, function()
		if not crate.Parent then
			return
		end
		attachPrompt(crate, def, beam, landing)
		if beam.Parent then
			beam.Transparency = 0.85
		end
		supplyDrop:FireAllClients({
			dropId = dropId,
			position = landing,
			rarity = def.rarity,
			weapon = def.name,
			incoming = false,
		})
	end)
end

--------------------------------------------------------------------------------
-- Bot access
--------------------------------------------------------------------------------

function SupplyDropService.FindNearest(position, radius)
	if not container or not container.Parent then
		return nil
	end

	local best, bestDistance = nil, radius
	for _, crate in ipairs(container:GetChildren()) do
		if crate.Name == "SupplyCrate" and crate:GetAttribute("Landed") and not crate:GetAttribute("Claimed") then
			local distance = (crate.Position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = crate, distance
			end
		end
	end
	return best, bestDistance
end

-- Returns the weapon def the bot gets, or nil if the crate isn't available to it.
function SupplyDropService.ClaimForBot(crate)
	if not crate or not crate.Parent or not crate:GetAttribute("Landed") then
		return nil
	end
	if crate:GetAttribute("Claimed") or crate:GetAttribute("PlayerHolding") then
		return nil
	end

	crate:SetAttribute("Claimed", true)
	local id = crate:GetAttribute("WeaponId")
	finishCrate(crate)
	return id and WeaponData.Get(id) or nil
end

function SupplyDropService.Start()
	SupplyDropService.Stop()

	generation += 1
	local myGeneration = generation
	running = true

	task.spawn(function()
		task.wait(math.min(firstDelay, dropInterval))
		while running and generation == myGeneration do
			-- Only drop while there's still a meaningful zone to drop into.
			if StormService.GetState().radius > 60 then
				local ok, err = pcall(dropOne)
				if not ok then
					warn("[SupplyDropService] drop failed: " .. tostring(err))
				end
			end
			task.wait(dropInterval)
		end
	end)
end

function SupplyDropService.Stop()
	running = false
	generation += 1
	if container then
		container:Destroy()
		container = nil
	end
	supplyDrop:FireAllClients({ cleared = true })
end

-- A crate that landed on a roof or an upper floor stays where it landed when that breaks. Nothing
-- here turns or bobs on the client from a remembered frame, so the crate is simply put down on what
-- is under it now (DestructibleService.OnPartBroken).
DestructibleService.OnPartBroken(function(cframe, size)
	if not container or not container.Parent then
		return
	end
	-- Only crates that have already landed: one still on its way down is being flown by its own
	-- fall, and putting it on the ground now would cut that short.
	local landed = {}
	for _, crate in ipairs(container:GetChildren()) do
		if crate:GetAttribute("Landed") then
			table.insert(landed, crate)
		end
	end
	local resting = DestructibleService.RestingOn(cframe, size, landed)
	if #resting == 0 then
		return
	end
	task.defer(function()
		for _, crate in ipairs(resting) do
			if crate:GetAttribute("Landed") then
				DestructibleService.SettleDown(crate)
			end
		end
	end)
end)

return SupplyDropService
