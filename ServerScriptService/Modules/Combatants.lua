-- A combatant is anything that can fight in a match: a real Player, or a bot record.
-- Every system downstream of this one deals in opaque "tokens" so it never has to care
-- which it is holding.
--
--   player token = the Player instance
--   bot token    = the bot record table created by BotService

local Players = game:GetService("Players")

local Combatants = {}

local byCharacter = {}

function Combatants.Register(character, token)
	byCharacter[character] = token
end

function Combatants.Unregister(character)
	byCharacter[character] = nil
end

-- Falls back to the Players service: a real player's character could be shot in the window
-- between spawning and registering, and missing that would silently break player damage.
function Combatants.FromCharacter(character)
	if not character then
		return nil
	end
	local token = byCharacter[character]
	if token then
		return token
	end
	return Players:GetPlayerFromCharacter(character)
end

function Combatants.IsPlayer(token)
	return typeof(token) == "Instance" and token:IsA("Player")
end

function Combatants.IsBot(token)
	return type(token) == "table" and token.isBot == true
end

function Combatants.GetName(token)
	if Combatants.IsPlayer(token) then
		return token.Name
	end
	if type(token) == "table" then
		return token.name or "Bot"
	end
	return "?"
end

function Combatants.GetCharacter(token)
	if Combatants.IsPlayer(token) then
		return token.Character
	end
	if type(token) == "table" then
		return token.character
	end
	return nil
end

function Combatants.GetHumanoid(token)
	local character = Combatants.GetCharacter(token)
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

function Combatants.GetRoot(token)
	local character = Combatants.GetCharacter(token)
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
end

function Combatants.IsAlive(token)
	local humanoid = Combatants.GetHumanoid(token)
	return humanoid ~= nil and humanoid.Health > 0
end

-- Still around to be fought: a player who left is gone even if their token lingers.
function Combatants.Exists(token)
	if Combatants.IsPlayer(token) then
		return token.Parent ~= nil
	end
	return type(token) == "table"
end

function Combatants.All()
	return byCharacter
end

return Combatants
