"""#78 / #20 / #24: the menu's screens, built for real and measured, at phone, tablet and desktop sizes.

    python3 tools/menu_screens_check.py            # the check, then every planted fault
    python3 tools/menu_screens_check.py --no-plants

Runs the REAL StarterPlayerScripts/MenuClient.client.lua (and MenuShell, MenuScreens, UiKit, UiParts,
ProgressionPanel, PhoneLayout, and the Shared data modules) under lupa against tools/menu_mocks.lua:
mocked Instances with a UDim2 / UIListLayout / UIGridLayout / AutomaticSize layout engine. The profile
it renders is the server's own: ServerScriptService's StateSync.Build over PlayerData's default data,
with some coins, brainrots and cosmetics added so every section has rows.

It clicks each HUD button, then each tab in that screen's navigation, at five screen sizes, and holds
the menu to these, every one of which the code must keep forever:

  screens    every tab is on exactly one screen; each HUD button opens its screen, whose title and
             navigation are that screen's and nobody else's; a one-tab screen draws no navigation
  renders    every tab renders without an error and draws something (an empty tab says so)
  overflow   no visible GUI object leaves its parent sideways, and none leaves a fixed-height parent
             downwards (a scrolling or auto-sized parent may grow); the panel fits the screen
  wiring     every live button (not greyed out) has a handler; every BUY / EQUIP / price button on
             the cosmetic tabs, clicked, reaches the BuyCosmetic / EquipCosmetic remote with its id
  previews   every item row on the Cosmetics and Kill Animations tabs has a preview, and it touches
             no button and no text on its row
  kill anims the Kill Animations tab lists CosmeticData.OfKind("KillAnimation") (fixtures injected
             here, since the real entries are another worker's), and shows its empty line with none

Not modelled: UIScale, size constraints, fonts (text width is estimated at 0.55 of TextSize, so
text overflow is reported as advice, not failure), and anything 3D. The previews are stub models:
this proves where a preview sits and that it is asked for, not what it looks like. That is the render
tools/menu_screens_gallery.lua makes on Oliver's machine.
"""
import os
import re
import sys

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SIZES = [
    # name, width, height, touch
    ("phone-portrait", 390, 844, True),
    ("phone-small", 320, 640, True),
    ("phone-landscape", 844, 390, True),
    ("tablet", 1024, 768, True),
    ("desktop", 1920, 1080, False),
]


def luau_to_lua(source):
    # Compound assignment is the only Luau-only syntax the menu's files use (checked by compiling
    # every file this loads; one that fails is reported, not silently stubbed).
    return re.sub(r"^(\s*)([\w.\[\]\"]+) (\.\.|[-+*/])= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def read(path):
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        return None
    with open(full, encoding="utf-8") as handle:
        return handle.read()


DRIVER = r"""
local M, getSource, overrides = ...

local STUBS = {}
local function anyModel() return Instance.new("Model") end
local function stubModule(extra)
	return setmetatable(extra or {}, { __index = function() return anyModel end })
end
local remoteLog = {}
M.remoteLog = remoteLog
local profileHolder = {}
M.profileHolder = profileHolder
local remotesByName = {}
STUBS.Remotes = {
	Event = function(name)
		remotesByName[name] = remotesByName[name] or { OnClientEvent = M.Signal(), FireServer = function(_, ...) table.insert(remoteLog, { name, ... }) end }
		return remotesByName[name]
	end,
	Function = function(name)
		remotesByName[name] = remotesByName[name] or {
			InvokeServer = function(_, ...)
				table.insert(remoteLog, { name, ... })
				if name == "RequestProfile" then return profileHolder.profile end
				return true
			end,
		}
		return remotesByName[name]
	end,
}
M.remotes = remotesByName
STUBS.Sfx = setmetatable({}, { __index = function() return function() end end })
STUBS.MergeDialog = setmetatable({}, { __index = function() return function() end end })
STUBS.BrainrotModels = stubModule({ FrameViewport = function() end })
STUBS.CrateModels = stubModule()
STUBS.ParachuteModels = stubModule({ WornScale = 1, FrameCamera = function() end })
STUBS.CosmeticBuild = stubModule()
STUBS.GunModels = stubModule()
STUBS.Monetization = { Owns = function() return false end, TempRemaining = function() return 0 end, CrateLuck = function() return 1 end }
-- The real CosmeticPreview is geometry (claude-df's); here it is where a preview goes and whether one
-- could be built. Kinds with no builder there get none here either, which is the case the swatch is for.
local BUILDABLE = { Accessory = true, Parachute = true, GunSkin = true, Aura = true }
STUBS.CosmeticPreview = {
	Model = function(id)
		local CosmeticData = M.requireShared("CosmeticData")
		local item = CosmeticData.Get(id)
		if item and BUILDABLE[item.kind] then return Instance.new("Model") end
		return nil
	end,
	Fill = function(frame, id)
		local viewport = Instance.new("ViewportFrame")
		viewport.Name = "CosmeticPreview"
		viewport.Size = UDim2.fromScale(1, 1)
		viewport.Parent = frame
		return { Destroy = function() viewport:Destroy() end }
	end,
	Release = function() end,
}
M.STUBS = STUBS

local cache = {}
M.loadErrors = {}
local function loadModule(inst)
	if cache[inst] ~= nil then return cache[inst] end
	local stub = rawget(inst, "__stub")
	if stub then cache[inst] = stub; return stub end
	local path = rawget(inst, "__source")
	local source = overrides[path] or getSource(path)
	local env = setmetatable({ script = inst }, { __index = _G })
	local chunk, err = load(source, "@" .. path, "t", env)
	if not chunk then error("compile " .. path .. ": " .. tostring(err)) end
	local result = chunk()
	cache[inst] = result
	return result
end
require = function(inst)
	if type(inst) ~= "table" then error("require of a non-instance: " .. tostring(inst), 2) end
	return loadModule(inst)
end

local function folder(parent, name, dir, files)
	local f = M.newInstance("Folder", name)
	f.Parent = parent
	for _, file in ipairs(files) do
		local module = M.newInstance("ModuleScript", file)
		rawset(module, "__source", dir .. "/" .. file .. ".lua")
		if STUBS[file] then rawset(module, "__stub", STUBS[file]) end
		module.Parent = f
	end
	return f
end
M.folder = folder

function M.setup(sharedFiles, clientFiles, serverFiles)
	local RS = M.service("ReplicatedStorage")
	M.Shared = folder(RS, "Shared", "ReplicatedStorage/Shared", sharedFiles)
	M.PlayerScripts = folder(M.player, "PlayerScripts", "StarterPlayerScripts", clientFiles)
	M.ServerModules = folder(M.service("ServerScriptService"), "Modules", "ServerScriptService/Modules", serverFiles)
end
function M.requireShared(name) return require(M.Shared:WaitForChild(name)) end
function M.requireClient(name) return require(M.PlayerScripts:WaitForChild(name)) end
function M.requireServer(name) return require(M.ServerModules:WaitForChild(name)) end

function M.runClient(name)
	local script = M.newInstance("LocalScript", name)
	rawset(script, "__source", "StarterPlayerScripts/" .. name .. ".client.lua")
	script.Parent = M.PlayerScripts
	local source = overrides[rawget(script, "__source")] or getSource(rawget(script, "__source"))
	local env = setmetatable({ script = script }, { __index = _G })
	local chunk, err = load(source, "@" .. name, "t", env)
	if not chunk then error("compile " .. name .. ": " .. tostring(err)) end
	local co = coroutine.create(chunk)
	local ok, runErr = coroutine.resume(co)
	if not ok then error(name .. " failed while loading: " .. tostring(runErr) .. "\n" .. debug.traceback(co)) end
	return coroutine.status(co)
end
return M
"""

CHECKS = r"""
local M, fixtures = ...
local out = { failures = {}, notes = {}, text = {}, counts = {} }
local function fail(msg) table.insert(out.failures, msg) end
local function note(msg) table.insert(out.notes, msg) end
local counts = out.counts
local function bump(key, n) counts[key] = (counts[key] or 0) + (n or 1) end

local MenuScreens = M.requireClient("MenuScreens")
local UiKit = M.requireClient("UiKit")
local CosmeticData = M.requireShared("CosmeticData")
local C = UiKit.Colors
local shell = M.shell
local screenGui = shell.layer.Parent

local function visibleChain(inst)
	local node = inst
	while node and node ~= screenGui do
		if node.Visible == false then return false end
		node = node.Parent
	end
	return true
end
local function rect(inst)
	local p, s = inst.AbsolutePosition, inst.AbsoluteSize
	return { x = p.X, y = p.Y, w = s.X, h = s.Y }
end
local function overlaps(a, b)
	return a.x < b.x + b.w - 1 and b.x < a.x + a.w - 1 and a.y < b.y + b.h - 1 and b.y < a.y + a.h - 1
end
local function live(button)
	if button.Active == false then return false end
	if button.TextColor3 == C.Muted and button.BackgroundColor3 == C.PanelAlt then return false end
	return true
end
local function wired(button)
	return button.Activated:Count() + button.MouseButton1Click:Count() + button.MouseButton1Down:Count() > 0
end

local describe
-- The whole panel, measured.
local function measure(where)
	local panel = shell.panel
	local pr = rect(panel)
	local vp = M.viewport
	-- UIScale is not modelled, so the panel is measured at scale 1 and its fit scale is read back.
	local scale = shell.fitScale or 1
	if pr.w * scale > vp.X + 1 or pr.h * scale > vp.Y + 1 then
		fail(string.format("%s: panel %dx%d (scale %.2f) is bigger than the %dx%d screen", where, pr.w, pr.h, scale, vp.X, vp.Y))
	end
	for _, inst in ipairs(panel:GetDescendants()) do
		if inst:IsA("GuiObject") and visibleChain(inst) and inst.Parent:IsA("GuiObject") then
			bump("objects")
			local parent = inst.Parent
			local a, b = rect(inst), rect(parent)
			local pad = parent:FindFirstChildOfClass("UIPadding")
			local l = pad and pad.PaddingLeft.Offset or 0
			local r = pad and pad.PaddingRight.Offset or 0
			-- A UIStroke or rounded corner is not a child GuiObject; a ScrollingFrame's canvas may be
			-- wider than its window only if it scrolls sideways, which none of the menu's do.
			local tol = 1
			-- A knob or a badge centred on its parent's edge is drawn to overhang it: anchored at its
			-- middle with the middle inside the parent. Anything else that leaves its parent is a fault.
			local centred = inst.AnchorPoint.X == 0.5 and inst.AnchorPoint.Y == 0.5
				and a.x + a.w / 2 >= b.x - tol and a.x + a.w / 2 <= b.x + b.w + tol
				and a.y + a.h / 2 >= b.y - tol and a.y + a.h / 2 <= b.y + b.h + tol
			if centred then tol = math.max(a.w, a.h) / 2 + 1 end
			-- Decoration a clipping parent cuts off on purpose (a card's sweeping shine): no text and
			-- nothing to press, so nothing a player can lose. Text or a button cut off still fails.
			if parent.ClipsDescendants and not inst:IsA("GuiButton") and not inst:IsA("TextLabel")
				and not inst:FindFirstChildWhichIsA("TextLabel", true) and not inst:FindFirstChildWhichIsA("GuiButton", true) then
				tol = math.huge
			end
			if a.w > 0 and (a.x < b.x - tol or a.x + a.w > b.x + b.w + tol) then
				fail(string.format("%s: %s [%s] sticks out of %s sideways (%.0f..%.0f in %.0f..%.0f)", where,
					(inst:GetFullName():gsub("^.-MenuShell%.", "")), describe(inst), parent.Name, a.x, a.x + a.w, b.x, b.x + b.w))
			end
			local grows = parent:IsA("ScrollingFrame") or (parent.AutomaticSize and parent.AutomaticSize.Name ~= "None")
			if not grows and a.h > 0 and (a.y < b.y - tol or a.y + a.h > b.y + b.h + tol) then
				fail(string.format("%s: %s [%s] sticks out of %s vertically (%.0f..%.0f in %.0f..%.0f)", where,
					(inst:GetFullName():gsub("^.-MenuShell%.", "")), describe(inst), parent.Name, a.y, a.y + a.h, b.y, b.y + b.h))
			end
			if inst:IsA("TextLabel") or inst:IsA("TextButton") then
				if not inst.TextWrapped and not inst.TextScaled and inst.TextTruncate.Name == "None" and inst.AutomaticSize.Name == "None"
					and inst.TextBounds.X > a.w + 4 and #tostring(inst.Text) > 0 then
					bump("textTight")
					if #out.text < 12 then
						table.insert(out.text, string.format("%s: %q wants ~%.0f px, has %.0f", where, tostring(inst.Text):sub(1, 40), inst.TextBounds.X, a.w))
					end
				end
			end
			if inst:IsA("GuiButton") and #tostring(inst.Text) > 0 and live(inst) then
				bump("liveButtons")
				if not wired(inst) then
					fail(string.format("%s: live button %q has no handler", where, tostring(inst.Text)))
				end
			end
		end
	end
end

describe = function(inst)
	local label = inst:IsA("GuiObject") and (inst:FindFirstChildWhichIsA("TextLabel", true) or inst:FindFirstChildWhichIsA("TextButton", true))
	local text = (inst.Text and #tostring(inst.Text) > 0 and inst.Text) or (label and label.Text) or ""
	return string.format("%s %dx%d %q", inst.ClassName, inst.AbsoluteSize.X, inst.AbsoluteSize.Y, tostring(text):sub(1, 24))
end

local function contentFrame()
	for _, child in ipairs(shell.Content:GetChildren()) do
		if child:IsA("Frame") then return child end
	end
end
local function contentText(frame)
	local parts = {}
	for _, inst in ipairs(frame:GetDescendants()) do
		if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and #tostring(inst.Text) > 0 then table.insert(parts, tostring(inst.Text)) end
	end
	return table.concat(parts, " | ")
end

local function navButtons()
	local list = {}
	for _, inst in ipairs(shell.nav:GetDescendants()) do
		if inst:IsA("GuiButton") then table.insert(list, inst) end
	end
	table.sort(list, function(a, b)
		local pa, pb = a.AbsolutePosition, b.AbsolutePosition
		if math.abs(pa.Y - pb.Y) > 1 then return pa.Y < pb.Y end
		return pa.X < pb.X
	end)
	return list
end

local function hudButton(label)
	for _, inst in ipairs(screenGui:GetDescendants()) do
		if inst:IsA("TextButton") and inst.Text == label and not inst:IsDescendantOf(shell.layer) then return inst end
	end
end

local function itemRows(frame)
	local rows = {}
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("Frame") and child:FindFirstChildWhichIsA("GuiButton", true) then table.insert(rows, child) end
	end
	return rows
end

-- Rows on a cosmetic tab: each has a preview, clear of its buttons and its text.
local function checkPreviews(where, frame)
	for _, row in ipairs(itemRows(frame)) do
		bump("itemRows")
		local preview = row:FindFirstChild("RowPreview")
		local viewport = preview or row:FindFirstChildOfClass("ViewportFrame")
		if not viewport then
			fail(where .. ": a row has no preview: " .. contentText(row):sub(1, 60))
		else
			bump("previews")
			local pr = rect(viewport)
			for _, inst in ipairs(row:GetDescendants()) do
				if (inst:IsA("GuiButton") or (inst:IsA("TextLabel") and inst.Parent == row and #tostring(inst.Text) > 0))
					and visibleChain(inst) and not inst:IsDescendantOf(viewport) and viewport.Visible then
					local r = rect(inst)
					if inst:IsA("TextLabel") then
						-- A label's box runs the row's width; what matters is the text in it.
						r.w = math.min(r.w, inst.TextBounds.X)
						if inst.TextXAlignment.Name == "Right" then r.x = r.x + rect(inst).w - r.w end
					end
					if overlaps(pr, r) then
						fail(string.format("%s: preview meets %q on its row", where, tostring(inst.Text):sub(1, 30)))
					end
				end
			end
		end
	end
end

-- Clicks every live BUY / EQUIP / price button on a cosmetic tab and reads the remote log.
local function checkCosmeticButtons(where, frame, idOfRow)
	for _, row in ipairs(itemRows(frame)) do
		for _, button in ipairs(row:GetDescendants()) do
			if button:IsA("GuiButton") and live(button) then
				local text = tostring(button.Text)
				local expect = (text == "EQUIP" or text == "UNEQUIP") and "EquipCosmetic" or (text:match(" C$") and "BuyCosmetic") or nil
				if expect then
					bump("clicked")
					local before = #M.remoteLog
					button.Activated:Fire()
					local call = M.remoteLog[before + 1]
					local id = idOfRow(row)
					if not call or call[1] ~= expect or (id and call[2] ~= id) then
						fail(string.format("%s: %q did not reach %s(%s); got %s(%s)", where, text, expect, tostring(id),
							call and tostring(call[1]) or "nothing", call and tostring(call[2]) or ""))
					end
				end
			end
		end
	end
end

local nameToId = {}
for id, item in pairs(CosmeticData.Items) do
	-- A name two items share (a Traffic Cone accessory and parachute) says nothing about which row.
	nameToId[item.name] = nameToId[item.name] == nil and id or false
end
local function idOfRow(row)
	for _, child in ipairs(row:GetChildren()) do
		if child:IsA("TextLabel") and nameToId[child.Text] ~= nil then return nameToId[child.Text] or nil end
	end
end

for _, size in ipairs(fixtures.sizes) do
	local name, w, h, touch = size[1], size[2], size[3], size[4]
	M.service("UserInputService").TouchEnabled = touch
	M.setViewport(w, h)
	for _, screen in ipairs(MenuScreens.Screens) do
		local where = name .. " " .. screen.key
		if shell:IsOpen() then shell.onClose() end
		local button = hudButton(screen.button)
		if not button then
			fail(where .. ": no HUD button labelled " .. screen.button)
		else
			local ok, err = pcall(function() button.Activated:Fire() end)
			if not ok then fail(where .. ": HUD button errored: " .. tostring(err)) end
			if not shell:IsOpen() then fail(where .. ": HUD button did not open the menu") end
			if shell.Title ~= screen.title then fail(where .. ": title is " .. tostring(shell.Title) .. ", not " .. screen.title) end
			local keys = {}
			for _, d in ipairs(shell.destinations) do table.insert(keys, d.key) end
			if table.concat(keys, ",") ~= table.concat(screen.tabs, ",") then
				fail(where .. ": navigation is " .. table.concat(keys, ",") .. ", not " .. table.concat(screen.tabs, ","))
			end
			if #screen.tabs == 1 and shell.nav.Visible then fail(where .. ": a one-tab screen still draws navigation") end
			if #screen.tabs > 1 then
				bump("navRows:" .. name .. ":" .. screen.key, shell.navRows or 1)
			end
			local cells = navButtons()
			for index, key in ipairs(screen.tabs) do
				local tabWhere = where .. "/" .. key
				bump("tabRenders")
				if #screen.tabs > 1 then
					local cell = cells[index]
					if not cell then
						fail(tabWhere .. ": no navigation cell")
					else
						local okClick, errClick = pcall(function() cell.Activated:Fire() end)
						if not okClick then fail(tabWhere .. ": errored: " .. tostring(errClick)) end
					end
				end
				if shell.active ~= key then fail(tabWhere .. ": navigation cell selected " .. tostring(shell.active)) end
				local frame = contentFrame()
				local drawn = frame and #frame:GetChildren() > 1
				if not drawn then fail(tabWhere .. ": drew nothing") end
				measure(tabWhere)
				if key == "Cosmetics" or key == "KillAnimations" then
					checkPreviews(tabWhere, frame)
					checkCosmeticButtons(tabWhere, frame, idOfRow)
				end
				if key == "KillAnimations" then
					local rows = #itemRows(frame)
					local text = contentText(frame)
					if rows ~= fixtures.killCount then
						fail(string.format("%s: %d kill animation rows, CosmeticData has %d", tabWhere, rows, fixtures.killCount))
					end
					if fixtures.killCount == 0 and not text:find("No death effects yet", 1, true) then
						fail(tabWhere .. ": no kill animations and no empty line")
					end
				end
				if key == "Cosmetics" then
					for _, row in ipairs(itemRows(frame)) do
						local id = idOfRow(row)
						if id and CosmeticData.Get(id).kind == "KillAnimation" then fail(tabWhere .. ": kill animation " .. id .. " listed on Cosmetics") end
					end
				end
				if key == "Robux" then
					local text = contentText(frame)
					local odds = 0
					for _ in text:gmatch("%d%%") do odds = odds + 1 end
					bump("robuxOddsFigures:" .. name, odds)
					if odds == 0 then fail(tabWhere .. ": the Robux shop shows no odds") end
				end
			end
		end
	end
end
if not M.tabs then
	fail("screens: the menu never asked for its navigation")
else
	for _, p in ipairs(MenuScreens.Problems(M.tabs)) do fail("screens: " .. p) end
end
return out
"""


def run(overrides=None, kills="fixtures", sizes=SIZES):
    overrides = overrides or {}
    lua = LuaRuntime(unpack_returned_tuples=True)
    mocks = lua.execute(read("tools/menu_mocks.lua"))

    def get_source(path):
        text = read(path)
        if text is None:
            raise RuntimeError("no such file " + path)
        return luau_to_lua(text)

    converted = lua.table_from({k: luau_to_lua(v) for k, v in overrides.items()})
    M = lua.execute(DRIVER, mocks, get_source, converted)

    def names(folder, suffix=".lua"):
        out = []
        for f in sorted(os.listdir(os.path.join(ROOT, folder))):
            if f.endswith(suffix) and not f.endswith(".client.lua") and not f.endswith(".server.lua"):
                out.append(f[: -len(suffix)])
        return lua.table_from(out)

    M.setup(names("ReplicatedStorage/Shared"), names("StarterPlayerScripts"), names("ServerScriptService/Modules"))

    # `kills`: "real" is CosmeticData as it is; "fixtures" adds five test entries to the real ones (two
    # forced in stock, one crate-only, one owned and equipped, one owned and not) so every branch of a
    # row draws whatever today's stock is; "empty" removes every kill animation, for the empty line.
    if kills == "empty":
        lua.execute(r"""
        local M = ...
        local CosmeticData = M.requireShared("CosmeticData")
        for id, item in pairs(CosmeticData.Items) do
            if item.kind == "KillAnimation" then CosmeticData.Items[id] = nil end
        end
        """, M)
    if kills == "fixtures":
        lua.execute(r"""
        local M = ...
        local CosmeticData = M.requireShared("CosmeticData")
        local ShopRotation = M.requireShared("ShopRotation")
        local function add(id, fields)
            fields.id, fields.kind = id, "KillAnimation"
            fields.color = fields.color or Color3.fromRGB(255, 120, 60)
            CosmeticData.Items[id] = fields
        end
        add("KillTestConfetti", { name = "Confetti Pop", rarity = "Rare", price = 1500, description = "Bursts into confetti." })
        add("KillTestTaco", { name = "Taco Rain", rarity = "Epic", price = 4000, description = "Tacos, from above." })
        add("KillTestVault", { name = "Vault Spark", rarity = "Legendary", crateOnly = true, description = "Crate exclusive." })
        add("KillTestOwned", { name = "Owned Swirl", rarity = "Common", price = 500, description = "Already yours." })
        add("KillTestSpare", { name = "Spare Fizz", rarity = "Uncommon", price = 800, description = "Owned, not worn." })
        -- Stock is ShopRotation's, which draws kill animations only once the other worker adds them to
        -- its slots; two are forced in stock here so the BUY branch is exercised.
        local inStock = ShopRotation.IsCosmeticInStock
        ShopRotation.IsCosmeticInStock = function(id, at)
            if id == "KillTestConfetti" or id == "KillTestTaco" then return true end
            return inStock(id, at)
        end
        """, M)
    kill_count = lua.eval(
        "function(M) return #M.requireClient('MenuScreens').KillAnimationRows({ cosmetics = { owned = {} } }) end")(M)

    # The profile: the server's own StateSync.Build over PlayerData's defaults, with things in it.
    lua.execute(r"""
    local M = ...
    local PlayerData = M.requireServer("PlayerData")
    local StateSync = M.requireServer("StateSync")
    local BrainrotData = M.requireShared("BrainrotData")
    local CosmeticData = M.requireShared("CosmeticData")
    -- Every product and pass is id 0 until Oliver pastes the real ones in, and the Robux shop hides
    -- what isn't set up. Numbered here so the shop draws its cards and their odds.
    local GamepassConfig = M.requireShared("GamepassConfig")
    local nextId = 1000
    for _, list in ipairs({ GamepassConfig.Products or {}, GamepassConfig.Passes or {} }) do
        for _, entry in pairs(list) do
            if type(entry) == "table" and entry.id == 0 then nextId = nextId + 1; entry.id = nextId end
        end
    end
    PlayerData.Load(M.player)
    local data = PlayerData.Get(M.player)
    data.SahurCoins = 250000
    local n = 0
    for name in pairs(BrainrotData.ByName or BrainrotData.Brainrots or {}) do
        n = n + 1
        if n > 12 then break end
        table.insert(data.Brainrots, name)
    end
    local owned = 0
    for id, item in pairs(CosmeticData.Items) do
        if not item.kind:find("Kill") and owned < 6 and item.price then
            data.Cosmetics.owned[id] = true
            owned = owned + 1
        end
    end
    if CosmeticData.Items.KillTestOwned then
        data.Cosmetics.owned.KillTestOwned = true
        data.Cosmetics.owned.KillTestSpare = true
    end
    local profile = StateSync.Build(M.player)
    -- The slot is the other worker's (PlayerData / StateSync); the tab reads any slot generically.
    if CosmeticData.Items.KillTestOwned then profile.cosmetics.killAnimation = "KillTestOwned" end
    M.profileHolder.profile = profile
    """, M)

    # Capture the shell MenuClient builds, and the tab list it hands the screens.
    lua.execute(r"""
    local M = ...
    local MenuShell = M.requireClient("MenuShell")
    local new = MenuShell.new
    MenuShell.new = function(options)
        local shell = new(options)
        M.shell = shell
        return shell
    end
    local MenuScreens = M.requireClient("MenuScreens")
    local destinations = MenuScreens.Destinations
    MenuScreens.Destinations = function(key, labelOf)
        -- Recover the host's tab list from its labeller: every key it can name is a TABS entry.
        local tabs = {}
        for _, candidate in ipairs({ "Brainrots", "Trade", "Crates", "Style", "Cosmetics", "KillAnimations", "Pass", "Rank",
            "Mastery", "Index", "CellShop", "Quests", "Robux", "Settings" }) do
            if labelOf(candidate) then table.insert(tabs, { key = candidate }) end
        end
        M.tabs = tabs
        return destinations(key, labelOf)
    end
    """, M)

    M.runClient("MenuClient")
    # The profile arrives the way it does in the game: the RequestProfile answer, or a push.
    lua.execute(r"""
    local M = ...
    local event = M.remotes.ProfileChanged
    if event then event.OnClientEvent:Fire(M.profileHolder.profile) end
    """, M)

    fixtures = lua.table_from({
        "sizes": lua.table_from([lua.table_from(list(s)) for s in sizes]),
        "killCount": kill_count,
    })
    out = lua.execute(CHECKS, M, fixtures)
    failures = list(out.failures.values())
    counts = dict(out.counts.items())
    text = list(out.text.values())
    warnings = list(M.warnings.values())
    return failures, counts, text, warnings, kill_count


def plant(path, old, new):
    source = read(path)
    assert source.count(old) == 1, (path, old)
    return {path: source.replace(old, new)}


PLANTS = [
    ("content wider than the panel (overflow)",
     plant("StarterPlayerScripts/MenuShell.lua",
           "self.Content.Size = UDim2.new(1, -railWidth - left",
           "self.Content.Size = UDim2.new(1, -left"), "fixtures"),
    ("EQUIP drawn live with no handler (wiring)",
     plant("StarterPlayerScripts/MenuScreens.lua",
           'host.addButton(buttons, 2, "EQUIP", C.Green, function()',
           'host.addButton(buttons, 2, "EQUIP", C.Green, nil, true, function()'), "fixtures"),
    ("BUY sends the wrong remote (wiring)",
     plant("StarterPlayerScripts/MenuScreens.lua",
           "\t\t\t\thost.buy(id)",
           "\t\t\t\thost.equip(id)"), "fixtures"),
    ("Kill Animations left off the SHOP screen (screens)",
     plant("StarterPlayerScripts/MenuScreens.lua",
           '"Cosmetics", "KillAnimations" } }',
           '"Cosmetics" } }'), "fixtures"),
    ("stacked preview moved onto the buttons (previews)",
     plant("StarterPlayerScripts/MenuScreens.lua",
           "position = UDim2.new(0, 14, 1, -9)",
           "position = UDim2.new(1, -80, 1, -9)"), "fixtures"),
    ("empty line dropped (kill animations, no entries)",
     plant("StarterPlayerScripts/MenuScreens.lua",
           '\t\thost.emptyMessage("No death effects yet.',
           '\t\tlocal _ = ("No death effects yet.'), "empty"),
    ("settings slider back to a flat 240 px (overflow, phone)",
     plant("StarterPlayerScripts/MenuClient.client.lua",
           "Size = UDim2.new(0.55, -92, 0, 10),",
           "Size = UDim2.fromOffset(240, 10),"), "fixtures"),
    ("one-tab screen keeps its rail (screens)",
     plant("StarterPlayerScripts/MenuShell.lua",
           "self.nav.Visible = not solo",
           "self.nav.Visible = true"), "fixtures"),
]


def main():
    failures, counts, text, warnings, kills = run(kills="fixtures")
    print("menu screens check: %d sizes x %d tabs rendered, %d GUI objects measured, %d live buttons, "
          "%d item rows, %d previews, %d buy/equip clicks, %d kill animation fixtures"
          % (len(SIZES), counts.get("tabRenders", 0) // len(SIZES), counts.get("objects", 0), counts.get("liveButtons", 0),
             counts.get("itemRows", 0), counts.get("previews", 0), counts.get("clicked", 0), kills))
    for key in sorted(counts):
        if key.startswith("navRows:") and counts[key] > 1:
            print("  note: %s navigation needs %d bar rows" % (key[8:], counts[key]))
    for key in sorted(counts):
        if key.startswith("robuxOddsFigures:"):
            print("  robux odds figures on %s: %d" % (key[17:], counts[key]))
    print("  text estimated tighter than its label (advice, font not modelled): %d" % counts.get("textTight", 0))
    for line in text[:8]:
        print("    " + line)
    for line in warnings[:5]:
        print("  warn: " + line)
    for line in failures[:40]:
        print("  FAIL " + line)
    print("menu screens: %d failures" % len(failures))

    # The real entries alone, and none at all (the empty line).
    empty_failures = []
    for mode in ("real", "empty"):
        mode_failures, _, _, _, mode_kills = run(kills=mode, sizes=SIZES[:1] + SIZES[-1:])
        print("menu screens (%s: %d kill animations listed): %d failures" % (mode, mode_kills, len(mode_failures)))
        for line in mode_failures[:10]:
            print("  FAIL " + line)
        empty_failures += mode_failures

    bad = len(failures) + len(empty_failures)
    if "--no-plants" not in sys.argv:
        caught = 0
        for name, override, mode in PLANTS:
            plant_failures = run(override, kills=mode, sizes=SIZES[:1] + SIZES[-1:])[0]
            ok = len(plant_failures) > 0
            caught += ok
            print("  plant %-50s %s (%d)%s" % (name, "CAUGHT" if ok else "MISSED", len(plant_failures),
                                              ("  e.g. " + plant_failures[0][:110]) if ok else ""))
        print("planted faults caught: %d / %d" % (caught, len(PLANTS)))
        bad += len(PLANTS) - caught
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
