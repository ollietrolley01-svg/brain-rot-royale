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
local UiKit = require(script.Parent:WaitForChild("UiKit"))
local UiParts = require(script.Parent:WaitForChild("UiParts"))
local AdminFly = require(script.Parent:WaitForChild("AdminFly"))

local player = Players.LocalPlayer
local create = UiKit.create
local Role, Type, Space, Radius = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius

local hello = Remotes.Event("AdminHello")
local action = Remotes.Event("AdminAction")
local matchChanged = Remotes.Event("MatchChanged")

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

	heading("PASSES")
	for key, pass in pairs(GamepassConfig.Passes) do
		row(pass.name or key, "Pass", key)
	end

	heading("MOVEMENT")
	row("Fly on", "Fly", true)
	row("Fly off", "Fly", false)

	heading("EVENTS")
	for _, event in ipairs(MatchEvents.List) do
		row(event.name or event.id, "Event", event.id)
	end

	heading("WEAPONS")
	for id, def in pairs(WeaponData.Weapons) do
		row(def.name or id, "Weapon", id)
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
	-- for the flight module's own leak/teardown proof; the six lines below are every place THIS file
	-- must call AdminFly.Stop() so nothing outlives its reason to exist:
	--   (1) the attribute going false, (2) death, (3) respawn, (4) the character being removed,
	--   (5) the match ending, (6) this HUD being destroyed.
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

	matchChanged.OnClientEvent:Connect(function(state)
		if state.state ~= "InProgress" then
			AdminFly.Stop() -- (5) match ended
		end
	end)

	gui.Destroying:Connect(function()
		AdminFly.Stop() -- (6) HUD destroyed
	end)

	applyFlyState()
end

hello.OnClientEvent:Connect(build)
