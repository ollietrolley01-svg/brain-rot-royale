-- Every cosmetic has a preview, and every preview is a real model, for tools/runtest.ps1 -Probe:
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/cosmetic_preview_probe.lua [-PlaceFile <rbxlx>]
--
-- Shared/CosmeticPreview is what the menu, the shop and the crate reveal show for an item. A cosmetic
-- with no preview is a blank square in the shop, and a preview that costs 200 ms is a hitch when a
-- page opens, so both are measured here:
--
--   model     every id of every kind builds something with parts in it, all anchored, with a finite
--             bounding box -- a preview that builds nothing is the bug this exists to catch
--   cost      how long the first build of each kind takes, and how long a clone takes after, since
--             the page pays the first once and the clone per row
--   budget    parts per preview, because twenty rows of a 300-part model is not a thumbnail
--   throttle  five slots filled at once must build at most one model in the first frame, so a
--             page of rows spreads its cost instead of paying for all of them on the first draw
--   teardown  Destroy and Release leave nothing behind

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local CosmeticPreview = require(Shared:WaitForChild("CosmeticPreview"))

local failures = 0
local function out(format, ...)
	print("[Preview] " .. string.format(format, ...))
end
local function fail(format, ...)
	failures += 1
	out("FAIL " .. format, ...)
end

-- A thumbnail's worth. The gun previews are the heavy ones and they set this.
local PART_BUDGET = 260

local KINDS = { "Accessory", "Parachute", "GunSkin", "Aura" }

local totals = { ids = 0, parts = 0, heaviest = 0, heaviestId = "-" }
local firstBuild = {}

-- Straight off CosmeticData.Items rather than OfKind, which hides bundleOnly and rankOnly items --
-- 18 of them, every prestige and mastery reward. A player owns and equips those, the menu shows them,
-- and a preview that skipped them would be a blank square on the items people are proudest of.
local byKind = {}
for id, item in pairs(CosmeticData.Items) do
	byKind[item.kind] = byKind[item.kind] or {}
	table.insert(byKind[item.kind], id)
end
for _, list in pairs(byKind) do
	table.sort(list)
end

for _, kind in ipairs(KINDS) do
	local ids = byKind[kind] or {}
	local shopVisible = #CosmeticData.OfKind(kind)
	out("%s: %d (%d in the shop lists, %d bundle or rank rewards)", kind, #ids, shopVisible, #ids - shopVisible)
	for _, id in ipairs(ids) do
		totals.ids += 1
		local started = os.clock()
		local ok, model = pcall(CosmeticPreview.Model, id)
		local seconds = os.clock() - started
		if not ok then
			fail("%s (%s) errored: %s", id, kind, tostring(model))
		elseif not model then
			fail("%s (%s) built no preview at all -- it would be an empty square in the shop", id, kind)
		else
			local parts, loose = 0, 0
			local box, size = model:GetBoundingBox()
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					parts += 1
					if not part.Anchored then
						loose += 1
					end
				end
			end
			if parts == 0 then
				fail("%s (%s) has no parts in it", id, kind)
			end
			if loose > 0 then
				fail("%s (%s) has %d unanchored parts, which fall out of frame in a ViewportFrame", id, kind, loose)
			end
			if size.Magnitude ~= size.Magnitude or size.Magnitude == 0 then
				fail("%s (%s) has no size (%s), so the camera cannot frame it", id, kind, tostring(size))
			end
			if box.Position.Magnitude ~= box.Position.Magnitude then
				fail("%s (%s) has a bounding box that is not a number", id, kind)
			end
			if parts > PART_BUDGET then
				fail("%s (%s) is %d parts, over the %d a thumbnail should cost", id, kind, parts, PART_BUDGET)
			end
			totals.parts += parts
			if parts > totals.heaviest then
				totals.heaviest, totals.heaviestId = parts, id
			end
			if not firstBuild[kind] then
				firstBuild[kind] = { seconds = seconds, parts = parts, id = id }
			end
			-- The second build of the same id is the clone the rows actually pay for.
			local again = os.clock()
			local clone = CosmeticPreview.Model(id)
			local cloneSeconds = os.clock() - again
			if clone then
				clone:Destroy()
			end
			if firstBuild[kind] and not firstBuild[kind].clone then
				firstBuild[kind].clone = cloneSeconds
			end
			model:Destroy()
		end
	end
end

for _, kind in ipairs(KINDS) do
	local first = firstBuild[kind]
	if first then
		out("%-10s first build %6.1f ms (%s, %d parts), then %5.2f ms a copy", kind, first.seconds * 1000, first.id, first.parts,
			(first.clone or 0) * 1000)
	end
end

--------------------------------------------------------------------------------
-- Fill: lazy, and cleans up after itself
--------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "PreviewProbe"
gui.Parent = game:GetService("ServerStorage")

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(102, 102)
frame.Parent = gui

local handle = CosmeticPreview.Fill(frame, "CrownOfRot")
task.wait(0.2)
local viewport = frame:FindFirstChild("CosmeticPreview")
if not viewport then
	fail("Fill put no ViewportFrame in the frame it was given")
else
	-- The contract is not "never builds" -- it is "at most one build per frame", so a page of twenty
	-- rows spreads its work instead of paying for every row on the first draw. The earlier version of
	-- this check asserted that a frame with no layout builds NOTHING, which is false: Roblox gives a
	-- ScreenGui's children a nominal size even outside a PlayerGui, so the frame is laid out enough to
	-- build. It failed on correct behaviour every run, which is the same disease as a check that
	-- passes on broken behaviour.
	local SLOT_IDS = { "CrownOfRot", "GoldenHalo", "BonkStick", "CactinoCrown", "StinkoSock" }
	local slots, handles = {}, {}
	for index = 1, 5 do
		local slot = Instance.new("Frame")
		slot.Size = UDim2.fromOffset(102, 102)
		slot.Position = UDim2.fromOffset(0, (index - 1) * 110)
		slot.Parent = gui
		slots[index] = slot
	end
	for index, slot in ipairs(slots) do
		handles[index] = CosmeticPreview.Fill(slot, SLOT_IDS[index])
	end
	task.wait()
	local builtAfterOneFrame = 0
	for _, slot in ipairs(slots) do
		local view = slot:FindFirstChild("CosmeticPreview")
		if view and #view:GetChildren() > 1 then
			builtAfterOneFrame += 1
		end
	end
	if builtAfterOneFrame > 1 then
		fail("five slots filled at once built %d models in one frame; the throttle is meant to allow one", builtAfterOneFrame)
	else
		out("throttle: %d of 5 slots built in the first frame, so a page spreads its cost", builtAfterOneFrame)
	end
	for _, h in ipairs(handles) do
		h:Destroy()
	end
	for _, slot in ipairs(slots) do
		slot:Destroy()
	end
end

handle:Destroy()
if frame:FindFirstChild("CosmeticPreview") then
	fail("Destroy left the viewport behind")
else
	out("teardown: Destroy removed the viewport")
end

CosmeticPreview.Fill(frame, "GoldenHalo")
CosmeticPreview.Release(frame)
if frame:FindFirstChild("CosmeticPreview") then
	fail("Release left the viewport behind")
else
	out("teardown: Release removed the viewport")
end

-- Filling twice must not stack two viewports in one slot.
CosmeticPreview.Fill(frame, "GoldenHalo")
CosmeticPreview.Fill(frame, "CrownOfRot")
local viewports = 0
for _, child in ipairs(frame:GetChildren()) do
	if child:IsA("ViewportFrame") then
		viewports += 1
	end
end
if viewports ~= 1 then
	fail("filling the same frame twice left %d viewports in it", viewports)
else
	out("reuse: filling a slot again replaces what was there")
end
CosmeticPreview.Release(frame)

--------------------------------------------------------------------------------
-- Planted faults
--------------------------------------------------------------------------------
-- The checks above pass on a module that returns a model for everything. These prove they would not
-- pass on one that doesn't.

local missing = CosmeticPreview.Model("NoSuchCosmetic")
if missing ~= nil then
	fail("self-test: an id that does not exist returned something (%s)", tostring(missing))
else
	out("self-test: an unknown id returns nil rather than erroring")
end

local blank = Instance.new("Model")
local blankParts = 0
for _, part in ipairs(blank:GetDescendants()) do
	if part:IsA("BasePart") then
		blankParts += 1
	end
end
if blankParts ~= 0 then
	fail("self-test: an empty model counted %d parts, so the parts check is not measuring parts", blankParts)
else
	out("self-test: an empty model reads as 0 parts, which is what the model check fails on")
end
blank:Destroy()

gui:Destroy()

out("SUMMARY: %d cosmetics, %d failures, %d parts across the previews, heaviest %s at %d", totals.ids, failures, totals.parts,
	totals.heaviestId, totals.heaviest)
