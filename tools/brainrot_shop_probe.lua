-- Brainrot shop probe for tools/runtest.ps1 -Probe: buying one specific brainrot with Robux, driven
-- through the real BrainrotShopService, Monetization.HandleReceipt and PlayerData.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/brainrot_shop_probe.lua
--
-- THE INVARIANT, which is what every check here is written against:
--
--     A receipt hands over a brainrot the player picked for THAT purchase, every pick is paid out
--     exactly once, and the random fallback runs only when no pick exists at all.
--
-- It is written that way on purpose. The bug that prompted this probe was "a second pick overwrites
-- the first while its receipt is in flight" -- but a check aimed at a bug dies with the bug and then
-- sits there printing green. The invariant outlives any particular fix: rewrite the storage, change
-- the queue, keep the guard, it still has to hold.
--
-- Why the invariant can break at all: Roblox clears the open-prompt hold the moment a purchase
-- completes, but the RECEIPT can arrive much later -- delayed, retried after NotProcessedYet, or
-- re-delivered on the next join after a disconnect. Everything in that window is what these cases
-- reproduce.
--
-- PlayerData.Save is stubbed: a stand-in profile must never reach a real DataStore.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local PlayerData = require(modules:WaitForChild("PlayerData"))
local Monetization = require(modules:WaitForChild("Monetization"))
local StateSync = require(modules:WaitForChild("StateSync"))
local BrainrotShopService = require(modules:WaitForChild("BrainrotShopService"))

StateSync.Push = function() end
StateSync.Notify = function() end
PlayerData.Save = function()
	return true
end
PlayerData.CanSave = function()
	return true
end
PlayerData.HasStore = function()
	return true
end

local failures, passes = 0, 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[ShopProbe] %s %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. tostring(detail) .. ")") or ""))
end

local player = { UserId = -424275, Name = "ShopProbe", DisplayName = "ShopProbe" }
local data = PlayerData.Load(player)

-- Nothing is purchasable yet (every product id is 0), so the probe gives the two rarities it uses
-- real-looking ids and puts them back at the end.
local RARITY = "Epic"
local product = GamepassConfig.BrainrotProduct(RARITY)
local savedId = product.id
product.id = 9995001

-- The shop opens Roblox's purchase prompt; here it only counts.
local prompts = 0
BrainrotShopService.Prompt = function()
	prompts += 1
end
-- The receipt path is the real one, through Monetization.HandleReceipt. The handler has to be
-- registered here: Bootstrap does it in a live server, but a -Probe run never executes Bootstrap, so
-- the first version of this probe measured nothing at all -- every receipt logged "No handler for
-- grant kind Brainrot" and granted nothing, and eight checks failed for that reason rather than for
-- anything about the fix. The wiring below is Bootstrap's, minus the client-side reveal.
Monetization.RegisterGrantHandler("Brainrot", function(who, profile, grant)
	BrainrotShopService.Grant(who, profile, grant)
end)
local receipts = 0
local function receipt()
	receipts += 1
	return Monetization.HandleReceipt(player, {
		PlayerId = player.UserId,
		ProductId = product.id,
		PurchaseId = "shop-probe-" .. receipts,
	})
end

local pool = BrainrotData.OfRarity(RARITY)
local A, B, C = pool[1].name, pool[2].name, pool[3].name

local function owned(name)
	local count = 0
	for _, held in ipairs(data.Brainrots) do
		if held == name then
			count += 1
		end
	end
	return count
end
local function reset()
	-- Close any prompt a case left open, or the next case's first Choose is refused by the hold and
	-- passes for the wrong reason. (Case 7 leaves one open on purpose.)
	BrainrotShopService.PromptFinished(player, RARITY, false)
	table.clear(data.Brainrots)
	data.PendingBrainrot = {}
	prompts = 0
end
-- What the profile is holding, as a readable string, for failure detail.
local function pendingNames()
	local slot = data.PendingBrainrot[RARITY]
	if not slot then
		return "(none)"
	end
	local names = { slot.name .. (slot.paid and "*" or "") }
	for _, entry in ipairs(slot.more or {}) do
		table.insert(names, entry.name .. (entry.paid and "*" or ""))
	end
	return table.concat(names, ", ")
end

-- The invariant itself, as a function, so every case below is judged by the same rule: the player
-- holds exactly the brainrots they picked, once each, and nothing else of this rarity.
local function holdsExactly(picked)
	local wanted = {}
	for _, name in ipairs(picked) do
		wanted[name] = (wanted[name] or 0) + 1
	end
	local held = {}
	for _, name in ipairs(data.Brainrots) do
		local def = BrainrotData.Get(name)
		if def and def.rarity == RARITY then
			held[name] = (held[name] or 0) + 1
		end
	end
	for name, count in pairs(wanted) do
		if held[name] ~= count then
			return false, string.format("%s: wanted %d, holds %d", name, count, held[name] or 0)
		end
	end
	for name, count in pairs(held) do
		if wanted[name] ~= count then
			return false, string.format("%s: holds %d, never picked it", name, count)
		end
	end
	return true, table.concat(data.Brainrots, ", ")
end

-- 1. The plain case ---------------------------------------------------------------------------
reset()
local ok = BrainrotShopService.Choose(player, A)
BrainrotShopService.PromptFinished(player, RARITY, true)
receipt()
local held, detail = holdsExactly({ A })
expect("one pick, one purchase: the player gets the brainrot they picked", ok and held, detail)

-- 2. THE CASE THE BUG WAS IN ---------------------------------------------------------------------
-- Pick A, pay for it, and pick B before A's receipt is processed -- which the player can do, because
-- the prompt-finished event has already cleared the hold. Both purchases are real money.
reset()
BrainrotShopService.Choose(player, A)
BrainrotShopService.PromptFinished(player, RARITY, true)
local second = BrainrotShopService.Choose(player, B)
expect("a second pick is allowed once the first purchase has completed", second == true, pendingNames())
BrainrotShopService.PromptFinished(player, RARITY, true)
receipt()
receipt()
held, detail = holdsExactly({ A, B })
expect("two purchases before either receipt lands hand over BOTH picks, and nothing else", held, detail)
expect("...and nothing is left waiting afterwards", data.PendingBrainrot[RARITY] == nil, pendingNames())

-- 3. Order ---------------------------------------------------------------------------------------
-- Three, to be sure the queue isn't just holding two.
reset()
for _, name in ipairs({ A, B, C }) do
	BrainrotShopService.Choose(player, name)
	BrainrotShopService.PromptFinished(player, RARITY, true)
end
receipt()
local firstOut = data.Brainrots[#data.Brainrots]
receipt()
receipt()
held, detail = holdsExactly({ A, B, C })
expect("three purchases hand over all three picks", held, detail)
expect("the first receipt pays out the first pick", firstOut == A, firstOut)

-- 4. Closing the prompt without buying ------------------------------------------------------------
reset()
BrainrotShopService.Choose(player, A)
BrainrotShopService.PromptFinished(player, RARITY, true)
BrainrotShopService.Choose(player, B)
BrainrotShopService.PromptFinished(player, RARITY, false) -- changed their mind about B
receipt()
held, detail = holdsExactly({ A })
expect("closing the second prompt forgets only that pick", held, detail)
expect("...and leaves nothing pending", data.PendingBrainrot[RARITY] == nil, pendingNames())

-- 5. A rejoin between paying and the receipt ------------------------------------------------------
-- Pay, disconnect, come back: Roblox re-delivers the receipt on the next join, and the pick has to
-- still be there -- every waiting pick, not just the first. The save round trip is PlayerData's own
-- `Reconcile`, which is the function a real load runs, and the receipt half is `Grant` called with
-- the reconciled profile (HandleReceipt reads the live profile, which is not the reloaded one).
do
	local saved = { PendingBrainrot = { [RARITY] = { name = A, at = 1, paid = true, more = { { name = B, at = 2, paid = true } } } } }
	local reloaded = PlayerData.Reconcile(saved)
	-- A head naming a brainrot that no longer exists must not take the paid picks behind it down too:
	-- the first valid pick is promoted instead.
	local salvaged = PlayerData.Reconcile({
		PendingBrainrot = { [RARITY] = { name = "NoSuchBrainrotAtAll", at = 1, more = { { name = B, at = 2, paid = true } } } },
	})
	local salvagedSlot = salvaged.PendingBrainrot[RARITY]
	expect("a corrupt first pick does not lose the paid ones behind it", salvagedSlot ~= nil and salvagedSlot.name == B,
		salvagedSlot and salvagedSlot.name or "the whole queue was dropped")
	local slot = reloaded.PendingBrainrot[RARITY]
	expect("a queue of paid picks survives the save and reload", slot ~= nil and slot.name == A and slot.more ~= nil and #slot.more == 1 and slot.more[1].name == B,
		slot and (slot.name .. " + " .. tostring(slot.more and #slot.more or 0)) or "nil")

	local firstDef, firstChosen = BrainrotShopService.Grant(player, reloaded, { kind = "Brainrot", rarity = RARITY })
	local secondDef, secondChosen = BrainrotShopService.Grant(player, reloaded, { kind = "Brainrot", rarity = RARITY })
	expect("after a rejoin both receipts pay out the picks, in order",
		firstChosen and secondChosen and firstDef.name == A and secondDef.name == B,
		string.format("%s then %s", firstDef and firstDef.name or "nil", secondDef and secondDef.name or "nil"))
	expect("...and the reloaded profile is left holding nothing", reloaded.PendingBrainrot[RARITY] == nil)
end

-- 6. The fallback runs ONLY when there is no pick --------------------------------------------------
reset()
receipt()
expect("a receipt with nothing pending still pays out a brainrot of the rarity paid for", #data.Brainrots == 1,
	table.concat(data.Brainrots, ", "))
local fallback = data.Brainrots[1]
expect("...and it is one of that rarity", BrainrotData.Get(fallback) and BrainrotData.Get(fallback).rarity == RARITY, fallback)

-- 7. While a prompt is open, a second pick for that rarity is refused ------------------------------
reset()
BrainrotShopService.Choose(player, A)
local refused, message = BrainrotShopService.Choose(player, B)
expect("a second pick is refused while the first prompt is still open", refused == false, message)
expect("...and the open pick is untouched", pendingNames():find(A, 1, true) ~= nil, pendingNames())

-- 8. The queue is bounded --------------------------------------------------------------------------
reset()
local allowed, blocked = 0, nil
for index = 1, 8 do
	local accepted, why = BrainrotShopService.Choose(player, pool[math.min(index, #pool)].name)
	if accepted then
		allowed += 1
		BrainrotShopService.PromptFinished(player, RARITY, true)
	else
		blocked = blocked or why
	end
end
expect("a player cannot stack up unbounded pending picks", allowed <= 5 and blocked ~= nil, string.format("%d allowed, %s", allowed, tostring(blocked)))

-- 9. PLANTED: the invariant must FAIL on the old behaviour ------------------------------------------
-- The bug was that a later pick REPLACED the one waiting on its receipt. That is simulated here by
-- overwriting the slot the way the old code did, so the check above is shown to be capable of
-- failing. If this case ever passes, every PASS in this file is worthless.
reset()
BrainrotShopService.Choose(player, A)
BrainrotShopService.PromptFinished(player, RARITY, true)
-- The old Choose, in one line: the slot is replaced rather than appended to.
data.PendingBrainrot[RARITY] = { name = B, at = os.time(), paid = true }
receipt()
-- Judged on the FIRST receipt alone, which is deterministic: the purchase made for A handed over
-- something else. Letting both receipts run first would leave the random fallback free to hand back
-- A by chance and make this case pass sometimes, which is worse than not testing it.
held, detail = holdsExactly({ A })
expect("planted: overwriting a pending pick breaks the invariant and is caught", not held,
	string.format("first receipt gave %s", tostring(data.Brainrots[#data.Brainrots])))

product.id = savedId
print(string.format("[ShopProbe] %d passed, %d failed", passes, failures))
print("[PROBE] brainrot shop: " .. (failures == 0 and "OK" or (failures .. " FAILURES")))
