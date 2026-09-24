-- Rot Vendors: a vending machine on every town square that sells a heal, a shield or an ammo
-- refill for SahurCoins, mid-match. Coins earned in a match (kills, streaks, bounties) become
-- something to spend before the match ends, and a square becomes somewhere worth running to.
--
--   VendorService.Build(parent, cframe)   builds one, its base on `cframe`, facing -Z
--   VendorService.Buy(player, product)    what the buttons do; returns ok, message
--   VendorService.ResetMatch()            MatchService, as each match starts: the per-match caps
--
-- Only serves players who are alive in a running match, and only if the item fits.
--
-- PER-MATCH CAPS (findings C5, Oliver's option a). Coins can be bought with Robux, so an uncapped Med
-- Kit button was healing for money: a player could refill to full after every fight. Each player gets
-- MatchCaps[kind] of each kind a match, across every vendor on the map -- 2 heals, 1 shield -- and the
-- button says so when they are gone. Ammo is not capped: it only refills what the guns already hold.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemData = require(Shared:WaitForChild("ItemData"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local DestructibleService = require(script.Parent:WaitForChild("DestructibleService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local VendorService = {}

VendorService.Products = {
	{ id = "MedKit", label = "MED KIT", price = 250, kind = "item", itemId = "MedKit", amount = 1 },
	{ id = "ShieldPotion", label = "SHIELD POTION", price = 300, kind = "item", itemId = "ShieldPotion", amount = 1 },
	{ id = "Ammo", label = "AMMO REFILL", price = 150, kind = "ammo", fraction = 0.6 },
}

-- How many of each ItemData kind one player may buy in one match, from all the vendors together.
VendorService.MatchCaps = { heal = 2, shield = 1 }
local CAP_NAMES = { heal = { "heal", "heals" }, shield = { "shield potion", "shield potions" } }

-- [player] = { [kind] = bought this match }. Strong, cleared on leave and by ResetMatch.
local boughtThisMatch = {}

-- The capped kind a product counts against, or nil (ammo).
local function cappedKind(product)
	local item = product.kind == "item" and ItemData.Get(product.itemId)
	return item and VendorService.MatchCaps[item.kind] and item.kind or nil
end

function VendorService.ResetMatch()
	table.clear(boughtThisMatch)
end

Players.PlayerRemoving:Connect(function(player)
	boughtThisMatch[player] = nil
end)

-- Every vendor built this map, so one can be put down again if what it stands on breaks.
local built = {}

local BODY = Color3.fromRGB(44, 40, 58)
local TRIM = Color3.fromRGB(255, 110, 200)
local GLASS = Color3.fromRGB(120, 200, 255)
local DARK = Color3.fromRGB(22, 22, 30)
local WHITE = Color3.fromRGB(236, 238, 246)

local function part(parent, name, size, cframe, color, material, shape)
	local instance = Instance.new("Part")
	instance.Name = name
	if shape then
		instance.Shape = shape
	end
	instance.Size = size
	instance.CFrame = cframe
	instance.Color = color
	instance.Material = material
	instance.Anchored = true
	instance.TopSurface = Enum.SurfaceType.Smooth
	instance.BottomSurface = Enum.SurfaceType.Smooth
	instance.Parent = parent
	return instance
end

local function decor(instance)
	instance.CanCollide = false
	instance.CanQuery = false
	instance.CanTouch = false
	return instance
end

local function text(instance, face, rows, pixelsPerStud)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 40
	gui.LightInfluence = 0
	for _, row in ipairs(rows) do
		local label = Instance.new("TextLabel")
		label.Position = UDim2.fromScale(0, row.y)
		label.Size = UDim2.fromScale(1, row.h)
		label.BackgroundTransparency = 1
		label.Font = row.font or Enum.Font.FredokaOne
		label.Text = row.text
		label.TextColor3 = row.color or WHITE
		label.TextStrokeTransparency = 0.5
		label.TextScaled = true
		label.Parent = gui
	end
	gui.Parent = instance
end

-- Charges and delivers. Nothing is charged unless the thing actually fits.
function VendorService.Buy(player, product)
	if not CombatService.IsEnabled() or not Combatants.IsAlive(player) then
		return false, "The vendor only serves during a match."
	end
	local data = PlayerData.Get(player)
	if not data then
		return false, "Couldn't reach your coins."
	end
	local capKind = cappedKind(product)
	local bought = boughtThisMatch[player] or {}
	if capKind and (bought[capKind] or 0) >= VendorService.MatchCaps[capKind] then
		local cap = VendorService.MatchCaps[capKind]
		return false, string.format("Sold out for you — the vendors sell each player %d %s a match.",
			cap, CAP_NAMES[capKind][cap == 1 and 1 or 2])
	end
	if (data.SahurCoins or 0) < product.price then
		return false, string.format("Not enough SahurCoins — %s costs %d.", product.label, product.price)
	end

	if product.kind == "item" then
		local added = WeaponService.GiveConsumable(player, product.itemId, product.amount)
		if not added or added <= 0 then
			return false, "No room in your slots for that."
		end
	elseif product.kind == "ammo" then
		if not WeaponService.GiveAmmo(player, product.fraction) then
			-- GiveAmmo adds nothing when every reserve is at its cap or there is no gun; nothing is charged.
			return false, "Your ammo is already full (or you have no gun to refill)."
		end
	else
		return false, "Out of order."
	end

	data.SahurCoins -= product.price
	if capKind then
		bought[capKind] = (bought[capKind] or 0) + 1
		boughtThisMatch[player] = bought
	end
	StateSync.Push(player)
	QuestService.Progress(player, "vendor", 1)
	return true, string.format("Bought %s for %d SahurCoins", product.label, product.price)
end

-- The machine: a tall cabinet with a lit glass front listing the prices, a button per product
-- (each with its own prompt), a coin slot, a tray at the bottom and a sign on top.
function VendorService.Build(parent, cframe)
	local model = Instance.new("Model")
	model.Name = "RotVendor"

	local body = part(model, "VendorBody", Vector3.new(5, 8, 3), cframe * CFrame.new(0, 4, 0), BODY, Enum.Material.Metal)
	decor(part(model, "VendorPlinth", Vector3.new(5.4, 0.4, 3.4), cframe * CFrame.new(0, 0.2, 0), DARK, Enum.Material.Metal))
	-- Trim strips down the front edges, standing proud of the front.
	for _, x in ipairs({ -2.35, 2.35 }) do
		decor(part(model, "VendorTrim", Vector3.new(0.3, 7.6, 0.3), cframe * CFrame.new(x, 4.1, -1.56), TRIM, Enum.Material.Neon))
	end
	-- The glass window with the menu on it.
	local window = decor(part(model, "VendorGlass", Vector3.new(3.6, 3.4, 0.2), cframe * CFrame.new(0, 5.5, -1.62), GLASS, Enum.Material.Glass))
	window.Transparency = 0.35
	local menu = decor(part(model, "VendorMenu", Vector3.new(3.4, 3.2, 0.1), cframe * CFrame.new(0, 5.5, -1.5), DARK, Enum.Material.SmoothPlastic))
	local rows = { { y = 0, h = 0.26, text = "ROT VENDOR", color = TRIM } }
	for index, product in ipairs(VendorService.Products) do
		table.insert(rows, {
			y = 0.26 + (index - 1) * 0.24, h = 0.22, font = Enum.Font.GothamBold,
			text = string.format("%s  %d C", product.label, product.price), color = WHITE,
		})
	end
	text(menu, Enum.NormalId.Front, rows, 40)
	local light = Instance.new("PointLight")
	light.Color = GLASS
	light.Range = 12
	light.Brightness = 1.2
	light.Parent = window

	-- Buttons: one per product, each with a prompt.
	for index, product in ipairs(VendorService.Products) do
		local button = part(model, "VendorButton", Vector3.new(1.1, 0.7, 0.3), cframe * CFrame.new(-1.3 + (index - 1) * 1.3, 3.1, -1.66),
			index == 1 and Color3.fromRGB(94, 214, 122) or index == 2 and Color3.fromRGB(80, 170, 255) or Color3.fromRGB(255, 196, 64),
			Enum.Material.Neon)
		button.CanCollide = false
		text(button, Enum.NormalId.Front, { { y = 0, h = 1, text = tostring(index), color = DARK } }, 60)
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Buy"
		-- The ammo row says what a refill is, so it can be judged before buying (#86).
		local capKind = cappedKind(product)
		prompt.ObjectText = product.kind == "ammo"
			and string.format("%s (+%d%% every gun) · %d C", product.label, math.floor(product.fraction * 100 + 0.5), product.price)
			or capKind and string.format("%s · %d C · %d a match", product.label, product.price, VendorService.MatchCaps[capKind])
			or string.format("%s · %d C", product.label, product.price)
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonB
		prompt.HoldDuration = 0.35
		prompt.MaxActivationDistance = 9
		prompt.RequiresLineOfSight = false
		prompt.UIOffset = Vector2.new(0, -20 * index)
		prompt.Parent = button
		prompt.Triggered:Connect(function(player)
			local ok, message = VendorService.Buy(player, product)
			StateSync.Notify(player, message, not ok)
		end)
	end

	-- Coin slot, tray, and the sign on top.
	decor(part(model, "VendorSlot", Vector3.new(0.6, 0.16, 0.2), cframe * CFrame.new(1.7, 4.3, -1.6), DARK, Enum.Material.Metal))
	decor(part(model, "VendorTray", Vector3.new(2.6, 1.0, 0.5), cframe * CFrame.new(0, 1.3, -1.7), DARK, Enum.Material.Metal))
	local sign = decor(part(model, "VendorSign", Vector3.new(5.2, 1.2, 0.4), cframe * CFrame.new(0, 8.7, -1.0), DARK, Enum.Material.Metal))
	text(sign, Enum.NormalId.Front, { { y = 0, h = 1, text = "ROT VENDOR", color = TRIM } }, 40)
	local glow = Instance.new("PointLight")
	glow.Color = TRIM
	glow.Range = 14
	glow.Brightness = 1
	glow.Parent = sign

	model.PrimaryPart = body
	ZFight.Fix({ model }, { all = true })
	model.Parent = parent
	table.insert(built, model)
	return model
end

-- A vendor standing on a floor or a porch roof that then breaks goes down onto whatever is under it
-- (DestructibleService.OnPartBroken). Nothing on it turns from a frame the client remembers, so
-- moving it is safe. Vendors from an earlier map are dropped from the list as they're found gone.
DestructibleService.OnPartBroken(function(cframe, size)
	local live = {}
	for _, model in ipairs(built) do
		if model.Parent then
			table.insert(live, model)
		end
	end
	built = live
	local resting = DestructibleService.RestingOn(cframe, size, live)
	if #resting == 0 then
		return
	end
	task.defer(function()
		for _, model in ipairs(resting) do
			DestructibleService.SettleDown(model)
		end
	end)
end)

return VendorService
