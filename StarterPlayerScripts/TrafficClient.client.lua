-- Traffic lights. Every signal lamp on the map (MapDecor.TrafficSignal) is tagged TrafficLamp and
-- carries everything needed to run it as attributes: which lamp it is (Lamp red / amber / green),
-- which way its approach runs (Axis x or z), its junction's Phase, the GreenTime / AmberTime /
-- AllRedTime of the cycle, and its OnColor and OffColor. This lights whichever lamp should be on,
-- on the client, so the server never has to replicate a colour change.
--
-- Every client works the cycle out from the server's clock, so all players see the same light at
-- the same moment. Approaches along X are green while approaches along Z are red and the other way
-- round, with an all-red pause between; each junction has its own phase, so neighbours don't all
-- change together. Lamps stream in and out with the map, so they're tracked by tag rather than
-- looked up once.

local CollectionService = game:GetService("CollectionService")

local TAG = "TrafficLamp"

-- Strong tables, cleared when a lamp goes: weak Instance keys lose live entries.
local lamps = {}
local shown = {}

local function track(lamp)
	if lamp:IsA("BasePart") then
		lamps[lamp] = true
	end
end

local function untrack(lamp)
	lamps[lamp] = nil
	shown[lamp] = nil
end

for _, lamp in ipairs(CollectionService:GetTagged(TAG)) do
	track(lamp)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)

-- Which lamp is lit on a signal `t` seconds into its junction's cycle.
local function litLamp(lamp, now)
	local green = lamp:GetAttribute("GreenTime") or 9
	local amber = lamp:GetAttribute("AmberTime") or 2.5
	local allRed = lamp:GetAttribute("AllRedTime") or 1.5
	local half = green + amber + allRed
	local t = (now + (lamp:GetAttribute("Phase") or 0)) % (half * 2)
	if lamp:GetAttribute("Axis") == "z" then
		t = (t + half) % (half * 2)
	end
	if t < green then
		return "green"
	elseif t < green + amber then
		return "amber"
	end
	return "red"
end

while true do
	local now = workspace:GetServerTimeNow()
	for lamp in pairs(lamps) do
		if lamp.Parent then
			local kind = lamp:GetAttribute("Lamp")
			local onColor, offColor = lamp:GetAttribute("OnColor"), lamp:GetAttribute("OffColor")
			if kind and typeof(onColor) == "Color3" and typeof(offColor) == "Color3" then
				local on = litLamp(lamp, now) == kind
				if shown[lamp] ~= on then
					shown[lamp] = on
					lamp.Material = on and Enum.Material.Neon or Enum.Material.SmoothPlastic
					lamp.Color = on and onColor or offColor
				end
			end
		else
			untrack(lamp)
		end
	end
	task.wait(0.2)
end
