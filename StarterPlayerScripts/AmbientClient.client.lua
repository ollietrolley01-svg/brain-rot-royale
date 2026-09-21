-- Purely decorative motion, done on the client.
--
-- Loot pickups, showcase displays and the lobby coin all spin. Doing that on the server means
-- every CFrame write replicates to every client, every frame. A CFrame change made on the
-- client to a server-owned anchored part stays local and costs nothing to send, and since the
-- server never touches these CFrames again, the local rotation isn't overwritten.
--
-- Spinning parts are tracked as they're added and removed rather than gathered with
-- GetChildren every frame, which allocated a fresh array of every pickup on the map sixty times
-- a second. Anything too far from the camera to see spinning is skipped.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local LOOT_SPEED = math.rad(70)
local DISPLAY_SPEED = math.rad(50)
local COIN_SPEED = math.rad(28)
local SPIN_DISTANCE = 220

local SPINNING_LOOT = {
	GroundWeapon = true,
	HealPickup = true,
	ItemPickup = true,
}

local camera = workspace.CurrentCamera

-- Pickups built as a base part with a model on it (a gun on its pad, a med kit) turn as one
-- piece: the base and every part on it keep their offsets from the base's rest frame, and the whole
-- lot is moved with one BulkMoveTo a frame. A gun on the floor is a couple of hundred parts, and
-- writing CFrame part by part for every pickup in view was a real cost.
-- base part -> { base = CFrame (rest), angle, speed, parts = { part }, offsets = { CFrame }, watch }
local spinGroups = {}
local moveParts, moveFrames = {}, {}

-- With streaming on, parts on a base can arrive after it does, and a group can be dropped and rebuilt
-- round parts already turned. A part that has never been turned still sits where the server put it, so
-- its offset is measured against the base's rest frame, never its turned one; once measured, the rest
-- frame and every offset are remembered per base, so a rebuilt group doesn't measure anything at an
-- angle.
--
-- base part -> { frame = rest CFrame, offsets = { [part] = CFrame }, goneSince = clock or nil }
-- Strong keys on purpose: Roblox can collect an Instance's Lua handle while the part lives on, so a
-- weak-keyed entry can vanish in exactly the stream-out-and-back case this is for. A record goes when
-- its base is destroyed, or once the base has been out of the world for REST_RECORD_LIFE seconds (a
-- pickup taken while streamed out never fires Destroying on this client).
--
-- None of that relies on the record surviving, though, because of one invariant: a part that isn't in
-- a live spin group is at its rest pose. dropGroup puts every part it turned back before letting the
-- group go, so whatever is measured next (a rebuilt group, a record rebuilt after the sweep, the same
-- instance streaming back in after any length of time) is measured at rest.
local REST_RECORD_LIFE = 120
local restRecords = {}

local function restRecord(base)
	local record = restRecords[base]
	if not record then
		record = { frame = base.CFrame, offsets = {} }
		restRecords[base] = record
		base.Destroying:Connect(function()
			record.destroyed = true
			if restRecords[base] == record then
				restRecords[base] = nil
			end
		end)
	end
	record.goneSince = nil
	return record
end

local function addToGroup(group, part)
	if not table.find(group.parts, part) then
		local offsets = group.record.offsets
		local offset = offsets[part] or group.base:ToObjectSpace(part.CFrame)
		offsets[part] = offset
		table.insert(group.parts, part)
		table.insert(group.offsets, offset)
	end
end

-- Everything the group turned goes back to rest, in the world with one BulkMoveTo, out of it (streamed
-- out, or on its way out) part by part. Skipped for a base being destroyed: nothing will measure it
-- again, and a whole Loot folder going at the end of a match would be thousands of writes for nothing.
local function restoreGroup(group)
	if not group.turned or group.record.destroyed then
		return
	end
	local cframes = table.create(#group.parts)
	for index, offset in ipairs(group.offsets) do
		cframes[index] = group.base * offset
	end
	local inWorld = group.parts[1]:IsDescendantOf(workspace)
	if inWorld then
		inWorld = pcall(function()
			workspace:BulkMoveTo(group.parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
		end)
	end
	if not inWorld then
		for index, part in ipairs(group.parts) do
			pcall(function()
				part.CFrame = cframes[index]
			end)
		end
	end
	group.turned = false
end

local function spinGroup(base, speed)
	-- A group already turning this base is put back to rest and let go first, so nothing below is ever
	-- measured turned.
	local previous = spinGroups[base]
	if previous then
		previous.watch:Disconnect()
		spinGroups[base] = nil
		restoreGroup(previous)
	end
	local record = restRecord(base)
	local group = { base = record.frame, record = record, angle = 0, speed = speed, parts = { base }, offsets = { CFrame.identity } }
	for _, descendant in ipairs(base:GetDescendants()) do
		if descendant:IsA("BasePart") then
			addToGroup(group, descendant)
		end
	end
	group.watch = base.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") and spinGroups[base] == group then
			addToGroup(group, descendant)
		end
	end)
	spinGroups[base] = group
end

local function dropGroup(base)
	local group = spinGroups[base]
	if group then
		group.watch:Disconnect()
		spinGroups[base] = nil
		restoreGroup(group)
	end
	local record = restRecords[base]
	if record and not base.Parent then
		record.goneSince = os.clock()
	end
end

-- Records of bases that have stayed out of the world too long.
local lastRecordSweep = 0
local function sweepRestRecords(now)
	if now - lastRecordSweep < 10 then
		return
	end
	lastRecordSweep = now
	for base, record in pairs(restRecords) do
		if base.Parent then
			record.goneSince = nil
		elseif not record.goneSince then
			record.goneSince = now
		elseif now - record.goneSince > REST_RECORD_LIFE and not spinGroups[base] then
			restRecords[base] = nil
		end
	end
end

local function track(folder, filter, speed)
	local function consider(child)
		if child:IsA("BasePart") and filter(child) then
			spinGroup(child, speed)
		end
	end

	for _, child in ipairs(folder:GetChildren()) do
		consider(child)
	end
	folder.ChildAdded:Connect(consider)
	folder.ChildRemoved:Connect(dropGroup)
end

-- The Loot folder is destroyed and recreated every match, so watch for it arriving rather
-- than hooking it once.
local function watchFolder(name, filter, speed)
	local function hook(child)
		if child.Name == name and child:IsA("Folder") then
			track(child, filter, speed)
		end
	end

	local existing = workspace:FindFirstChild(name)
	if existing then
		hook(existing)
	end
	workspace.ChildAdded:Connect(hook)
end

watchFolder("Loot", function(part)
	return SPINNING_LOOT[part.Name] == true
end, LOOT_SPEED)

watchFolder("Showcase", function(part)
	return part.Name == "Display"
end, DISPLAY_SPEED)

-- Whatever's on the lobby's crate stage turns the same way, and so do the arena's podium guns.
watchFolder("StageDisplay", function(part)
	return part.Name == "Display"
end, DISPLAY_SPEED)
watchFolder("GunDisplays", function(part)
	return part.Name == "Display"
end, DISPLAY_SPEED)

-- Anything the server tags: map easter eggs so far. "AmbientSpin" turns a part about its own
-- Y axis at its SpinSpeed attribute (degrees per second); "AmbientBob" floats it up and down
-- around where it was placed. Streaming a part out and back in re-fires the added signal, so
-- the bob's base position is always the server's.
local BOB_DISTANCE = 300
local bobbing = {}

-- A tagged part with parts under it turns as one piece (a ferris wheel and its cabins, a
-- carousel and its horses), about the tagged part's own Y axis.
local function onSpinTagged(part)
	if not part:IsA("BasePart") then
		return
	end
	spinGroup(part, math.rad(part:GetAttribute("SpinSpeed") or 45))
end

local function onBobTagged(part)
	if part:IsA("BasePart") then
		bobbing[part] = {
			base = part.CFrame,
			height = part:GetAttribute("BobHeight") or 0.5,
			speed = part:GetAttribute("BobSpeed") or 2,
			phase = part:GetAttribute("BobPhase") or 0,
		}
	end
end

for _, part in ipairs(CollectionService:GetTagged("AmbientSpin")) do
	onSpinTagged(part)
end
CollectionService:GetInstanceAddedSignal("AmbientSpin"):Connect(onSpinTagged)
CollectionService:GetInstanceRemovedSignal("AmbientSpin"):Connect(dropGroup)

for _, part in ipairs(CollectionService:GetTagged("AmbientBob")) do
	onBobTagged(part)
end
CollectionService:GetInstanceAddedSignal("AmbientBob"):Connect(onBobTagged)
CollectionService:GetInstanceRemovedSignal("AmbientBob"):Connect(function(part)
	bobbing[part] = nil
end)

-- "AmbientPulse" cycles a part's colour round the hue wheel (the disco floor): PulseSpeed is
-- turns per second, PulsePhase an offset so neighbouring tiles differ.
local pulsing = {}

local function onPulseTagged(part)
	if part:IsA("BasePart") then
		pulsing[part] = { speed = part:GetAttribute("PulseSpeed") or 0.2, phase = part:GetAttribute("PulsePhase") or 0 }
	end
end

for _, part in ipairs(CollectionService:GetTagged("AmbientPulse")) do
	onPulseTagged(part)
end
CollectionService:GetInstanceAddedSignal("AmbientPulse"):Connect(onPulseTagged)
CollectionService:GetInstanceRemovedSignal("AmbientPulse"):Connect(function(part)
	pulsing[part] = nil
end)

-- "AmbientSway" swings a tagged hub part, and every part under it, about one of the hub's own
-- axes (SwayAxis "X" or "Y"): SwayAngle degrees either way at SwaySpeed radians a second, from
-- SwayPhase, plus SwaySpin degrees a second of steady turning on top. The Cloud Climb's springy
-- branches flap about a hinge where they leave the trunk, and its thorn rotors just spin.
-- These are obstacles people time jumps against, so the angle comes from the server's clock
-- rather than this client's: everyone watching the same branch sees it in the same place.
local SWAY_DISTANCE = 300
local swaying = {}
-- hub -> its DescendantAdded connection
local swayWatchers = {}

local function onSwayTagged(hub)
	if not hub:IsA("BasePart") then
		return
	end
	local parts, offsets = { hub }, { CFrame.identity }
	for _, descendant in ipairs(hub:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
			table.insert(offsets, hub.CFrame:ToObjectSpace(descendant.CFrame))
		end
	end
	-- With streaming on, the tag can arrive before all of the hub's parts have. A part that comes
	-- later still sits where the server put it, so its offset is taken from the stored rest frame,
	-- never from the hub, which may already be swung.
	if swayWatchers[hub] then
		swayWatchers[hub]:Disconnect()
	end
	swayWatchers[hub] = hub.DescendantAdded:Connect(function(descendant)
		local entry = swaying[hub]
		if entry and descendant:IsA("BasePart") and not table.find(entry.parts, descendant) then
			table.insert(entry.parts, descendant)
			table.insert(entry.offsets, entry.base:ToObjectSpace(descendant.CFrame))
		end
	end)
	swaying[hub] = {
		base = hub.CFrame,
		axis = hub:GetAttribute("SwayAxis") == "Y" and Vector3.yAxis or Vector3.xAxis,
		amplitude = math.rad(hub:GetAttribute("SwayAngle") or 0),
		speed = hub:GetAttribute("SwaySpeed") or 1,
		phase = hub:GetAttribute("SwayPhase") or 0,
		spin = math.rad(hub:GetAttribute("SwaySpin") or 0),
		parts = parts,
		offsets = offsets,
		frames = table.create(#parts),
	}
end

for _, part in ipairs(CollectionService:GetTagged("AmbientSway")) do
	onSwayTagged(part)
end
CollectionService:GetInstanceAddedSignal("AmbientSway"):Connect(onSwayTagged)
CollectionService:GetInstanceRemovedSignal("AmbientSway"):Connect(function(part)
	swaying[part] = nil
	if swayWatchers[part] then
		swayWatchers[part]:Disconnect()
		swayWatchers[part] = nil
	end
end)

local coin = nil

RunService.RenderStepped:Connect(function(delta)
	local focus = camera.CFrame.Position

	-- Destroying a folder doesn't reliably fire ChildRemoved for every child, so anything that's gone
	-- is pruned here (clearing the current key mid-pairs is safe in Lua). The arrays are reused frame
	-- to frame; clearing keeps their capacity.
	sweepRestRecords(os.clock())
	table.clear(moveParts)
	table.clear(moveFrames)
	for base, group in pairs(spinGroups) do
		if not base.Parent then
			dropGroup(base)
		elseif (group.base.Position - focus).Magnitude < SPIN_DISTANCE then
			group.angle += group.speed * delta
			group.turned = true
			local frame = group.base * CFrame.Angles(0, group.angle, 0)
			for index, part in ipairs(group.parts) do
				if part.Parent then
					local n = #moveParts + 1
					moveParts[n] = part
					moveFrames[n] = frame * group.offsets[index]
				end
			end
		end
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	local now = os.clock()
	for part, entry in pairs(bobbing) do
		if not part.Parent then
			bobbing[part] = nil
		elseif (entry.base.Position - focus).Magnitude < BOB_DISTANCE then
			part.CFrame = entry.base + Vector3.new(0, math.sin(now * entry.speed + entry.phase) * entry.height, 0)
		end
	end

	local serverNow = workspace:GetServerTimeNow()
	for hub, entry in pairs(swaying) do
		if not hub.Parent then
			swaying[hub] = nil
		elseif (entry.base.Position - focus).Magnitude < SWAY_DISTANCE then
			local angle = math.sin(serverNow * entry.speed + entry.phase) * entry.amplitude + (serverNow * entry.spin) % (math.pi * 2)
			local frame = entry.base * CFrame.fromAxisAngle(entry.axis, angle)
			for index, offset in ipairs(entry.offsets) do
				entry.frames[index] = frame * offset
			end
			workspace:BulkMoveTo(entry.parts, entry.frames, Enum.BulkMoveMode.FireCFrameChanged)
		end
	end

	for part, entry in pairs(pulsing) do
		if not part.Parent then
			pulsing[part] = nil
		elseif (part.Position - focus).Magnitude < BOB_DISTANCE then
			part.Color = Color3.fromHSV((now * entry.speed + entry.phase) % 1, 0.75, 1)
		end
	end

	if not coin or not coin.Parent then
		local lobby = workspace:FindFirstChild("Lobby")
		coin = lobby and lobby:FindFirstChild("SahurCoin") or nil
	end
	if coin then
		-- The coin is a cylinder rotated upright, so its local X axis is vertical.
		coin.CFrame = coin.CFrame * CFrame.Angles(COIN_SPEED * delta, 0, 0)
	end
end)
