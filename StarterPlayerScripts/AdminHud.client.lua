-- The admin panel (Oliver's list #52), client half.
--
-- This script exists in every player's StarterPlayerScripts — that is how Roblox works, and no
-- client script can be kept off a machine. What matters is that it BUILDS NOTHING unless the server
-- tells it to, and the server only tells Oliver. So for every other player there is no panel in
-- PlayerGui to find, no frame to un-hide, and no button to fire a remote with.
--
-- It also holds no power of its own. Every control below sends a request; the server checks the
-- UserId and does the work, or silently does nothing. A player who edits this file to build the
-- panel anyway gets a panel whose every button is refused.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local MatchEvents = require(Shared:WaitForChild("MatchEvents"))
local CrateData = require(Shared:WaitForChild("CrateData"))
local UiKit = require(script.Parent:WaitForChild("UiKit"))
local UiParts = require(script.Parent:WaitForChild("UiParts"))
local AdminFly = require(script.Parent:WaitForChild("AdminFly"))

local player = Players.LocalPlayer
local create = UiKit.create
local Role, Type, Space, Radius = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius

local hello = Remotes.Event("AdminHello")
local action = Remotes.Event("AdminAction")

local built = false

local function build()
	if built then
		return
	end
	built = true

	local gui = create("ScreenGui", {
		Name = "AdminHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 50,
		Parent = player:WaitForChild("PlayerGui"),
	})

	local panel = create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(300, 440),
		BackgroundColor3 = Role.Base,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	}, { UiKit.rounded(Radius.Panel) })
	create("UIStroke", { Color = Role.Accent, Thickness = 1, Transparency = 0.4, Parent = panel })

	UiParts.text(panel, Type.Heading, "ADMIN", Role.Accent, {
		Position = UDim2.fromOffset(Space.LG, Space.MD),
		Size = UDim2.fromOffset(200, 22),
	})

	local body = create("ScrollingFrame", {
		Position = UDim2.fromOffset(Space.MD, 44),
		Size = UDim2.new(1, -Space.MD * 2, 1, -56),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = panel,
	}, { create("UIListLayout", { Padding = UDim.new(0, Space.SM), SortOrder = Enum.SortOrder.LayoutOrder }) })

	local order = 0
	local function heading(text)
		order += 1
		UiParts.text(body, Type.Label, text, Role.TextMuted, {
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = order,
		})
	end
	local function row(label, kind, payload)
		order += 1
		UiParts.button({
			parent = body,
			kind = "secondary",
			text = label,
			grow = true,
			layoutOrder = order,
			onClick = function()
				action:FireServer(kind, payload)
			end,
		})
	end

	heading("MONEY")
	row("+10,000 coins", "Coins", 10000)
	row("+100,000 coins", "Coins", 100000)

	heading("CRATES")
	for _, tier in ipairs(CrateData.Order) do
		local crate = CrateData.Get(tier)
		if crate then
			row("+1 " .. (crate.name or (tier .. " Crate")), "Crate", tier)
		end
	end

	heading("PASSES")
	for key, pass in pairs(GamepassConfig.Passes) do
		row(pass.name or key, "Pass", key)
	end

	heading("GOD MODE")
	row("God mode on", "God", true)
	row("God mode off", "God", false)

	heading("MOVEMENT")
	row("Fly on", "Fly", true)
	row("Fly off", "Fly", false)

	heading("EVENTS")
	for _, event in ipairs(MatchEvents.List) do
		row(event.name or event.id, "Event", event.id)
	end

	heading("WEAPONS")
	-- Grouped by rarity, lowest first, A to Z inside each (Oliver, 2026-09-23: "sort the guns in the
	-- admin menu by rarity"). Each group has a heading in its rarity colour.
	do
		local Rarity = require(Shared:WaitForChild("Rarity"))
		local groups = {}
		for id, def in pairs(WeaponData.Weapons) do
			local rarity = Rarity.Index[def.rarity] and def.rarity or "Other"
			groups[rarity] = groups[rarity] or {}
			table.insert(groups[rarity], { id = id, name = def.name or id })
		end
		local order_ = table.clone(Rarity.Order)
		table.insert(order_, "Other")
		for _, rarity in ipairs(order_) do
			local list = groups[rarity]
			if list then
				table.sort(list, function(a, b)
					return a.name < b.name
				end)
				order += 1
				UiParts.text(body, Type.Label, string.upper(rarity) .. "  (" .. #list .. ")",
					rarity == "Other" and Role.TextMuted or Rarity.Color(rarity), {
						Size = UDim2.new(1, 0, 0, 18),
						LayoutOrder = order,
					})
				for _, entry in ipairs(list) do
					row(entry.name, "Weapon", entry.id)
				end
			end
		end
	end

	-- A pill to open it, so the panel isn't sitting over the game the whole match.
	local toggle = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 120),
		Size = UDim2.fromOffset(80, 28),
		BackgroundColor3 = Role.Accent,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Type.Label.Font,
		Text = "ADMIN",
		TextColor3 = Role.AccentInk,
		TextSize = Type.Caption.Size,
		Parent = gui,
	}, { UiKit.rounded(Radius.Pill) })
	toggle.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)

	-- Fly. AdminService.lua sets the `AdminFly` attribute on this Player after its own isAdmin gate
	-- passes; this block only ever runs after `hello` has fired, which the server only ever fires at
	-- the real admin -- so a non-admin client that locally forged its own copy of this attribute
	-- (SetAttribute from a modified client is local-only, never reaches the server) still gets
	-- nothing, because this listener was never created on their client at all. See admin_fly_probe.lua
	-- for the flight module's own leak/teardown proof; the five lines below are every place THIS file
	-- must call AdminFly.Stop() so nothing outlives its reason to exist:
	--   (1) the attribute going false, (2) death, (3) respawn, (4) the character being removed,
	--   (5) this HUD being destroyed.
	--
	-- There WAS a sixth, "the match ending" via MatchChanged -- removed (bug-hunt tab's find): that
	-- remote is a snapshot broadcast about once a SECOND in Waiting/Intermission/Countdown, not an
	-- edge, so it tore Fly down roughly every second in the lobby. Oliver would lift off and drop
	-- within a second, and since applyFlyState only runs on the attribute CHANGING, pressing "Fly on"
	-- again did nothing -- the attribute was already true. It worked fine mid-match, which is what
	-- made it look random rather than broken ("fly only worked for a second in the lobby"). Not
	-- needed anyway: a match ending calls player:LoadCharacter() for every participant
	-- (MatchService.lua ~1040-1047), which fires CharacterRemoving -- path (4) already covers it.
	local function applyFlyState()
		if player:GetAttribute("AdminFly") == true then
			if player.Character then
				AdminFly.Start(player.Character) -- Start() tears down any old body itself.
			end
		else
			AdminFly.Stop() -- (1) attribute false
		end
	end
	player:GetAttributeChangedSignal("AdminFly"):Connect(applyFlyState)

	local function onCharacterAdded(character)
		AdminFly.Stop() -- (3) respawn: always start the new body clean
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid then
			humanoid.Died:Connect(function()
				AdminFly.Stop() -- (2) death
			end)
		end
		applyFlyState()
	end
	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		AdminFly.Stop() -- (4) character removed
	end)

	gui.Destroying:Connect(function()
		AdminFly.Stop() -- (5) HUD destroyed
	end)

	applyFlyState()
end

hello.OnClientEvent:Connect(build)
