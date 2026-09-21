-- World labels that name a key: the ready pad's "(or press [F] anywhere)", the companion practice
-- sign. Every player can rebind those keys, so the server writes such a label without naming one
-- and tags it "KeyHint" with a template in its KeyHint attribute, {ActionId} standing for a
-- Settings action's key. This fills the template in with this player's own key, and again when a
-- binding changes. On a gamepad or a touch screen a keyboard key means nothing, so there the
-- server's key-free wording stays.

local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")

local Settings = require(script.Parent:WaitForChild("Settings"))

local TAG = "KeyHint"

-- The server's wording for each label, kept to go back to when the player picks up a gamepad.
--
-- A strong table cleared on Destroying, not a weak-keyed one: Roblox collects an Instance's Lua
-- handle as soon as nothing but a weak table holds it, so a weak table here would quietly lose the
-- original wording of a label that is still on screen — and the next fill would take the text it had
-- already written as the "server's" version, so a player who picked up a gamepad would be shown a
-- keyboard key anyway.
local serverText = {}

local function onKeyboard()
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch or string.find(last.Name, "Gamepad", 1, true) then
		return false
	end
	return UserInputService.KeyboardEnabled
end

local keyboard = onKeyboard()

local function fill(label)
	local template = label:GetAttribute("KeyHint")
	if not label:IsA("TextLabel") or type(template) ~= "string" then
		return
	end
	if serverText[label] == nil then
		serverText[label] = label.Text
		label.Destroying:Connect(function()
			serverText[label] = nil
		end)
	end
	if not keyboard then
		label.Text = serverText[label]
		return
	end
	local ok, text = pcall(function()
		return (string.gsub(template, "{(%w+)}", function(actionId)
			return Settings.KeyLabel(actionId)
		end))
	end)
	label.Text = ok and text or serverText[label]
end

local function fillAll()
	for _, label in ipairs(CollectionService:GetTagged(TAG)) do
		fill(label)
	end
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(fill)
fillAll()

Settings.Changed:Connect(fillAll)

UserInputService.LastInputTypeChanged:Connect(function()
	local now = onKeyboard()
	if now ~= keyboard then
		keyboard = now
		fillAll()
	end
end)
