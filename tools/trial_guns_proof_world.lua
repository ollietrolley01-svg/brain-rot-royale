-- #117 lobby trial guns: the stand-in world and the scenes for tools/trial_guns_proof_check.py.
--
-- Run by the check as `lua.execute(this, S, C)`. S maps module names to the game's REAL source (already
-- converted from Luau): RangeService, WeaponService, WeaponData and its three arsenal packs, ItemData,
-- MatchConfig, Rarity, SafeValue. C holds the pieces cut from files too big to load whole: the range block
-- of LobbyService's buildArena (SetArea and the podium loop, prompts and all) and MatchService's
-- PlaceInLobby, lobbyCFrame and OnCharacterAdded. Everything else is a stand-in, named below.
--
-- What is real here: every inventory rule (Reset, GiveWeapon, Equip, Push, Clear, SwapSlots, Reload, the
-- held-gun refresh on Heartbeat), every range rule (Give, stop, the 0.4 s poll as a coroutine), the prompt
-- handler each podium connects, which gun each podium stands, and the lobby death -> respawn path.
-- What is not: Roblox itself (prompts are fired by hand at a player standing within their reach), the
-- network (a client is the last LoadoutChanged / RangeState it was sent, which is what HudClient and
-- CombatClient keep), and the gun models (a HeldGun here is an empty model carrying its WeaponId).

local S, C = ...
-- Plain Lua's loader (the world runs in lupa, not Roblox).
local loadChunk = _G["load"]

local rows, findings, counts = {}, {}, {}
local function check(ok, line) rows[#rows + 1] = { ok = ok and true or false, line = line } end
local function finding(line) findings[#findings + 1] = line end
local function count(key, n) counts[key] = (counts[key] or 0) + (n or 1) end

--------------------------------------------------------------------------------
-- Time: a hand-cranked clock, task.defer / task.delay queues, Heartbeat, the range's poll coroutine
--------------------------------------------------------------------------------
local clock = 1000
local wall = os.time({ year = 2026, month = 9, day = 25, hour = 12 })
local deferred, delayed, coroutines = {}, {}, {}
local heartbeat = {}

local function pack(...) return { n = select("#", ...), ... } end
local task = {}
function task.defer(fn, ...) local a = pack(...); deferred[#deferred + 1] = function() fn(table.unpack(a, 1, a.n)) end end
function task.delay(t, fn, ...) local a = pack(...); delayed[#delayed + 1] = { at = clock + (t or 0), fn = function() fn(table.unpack(a, 1, a.n)) end } end
function task.spawn(fn, ...)
	local co = coroutine.create(fn)
	local ok, err = coroutine.resume(co, ...)
	if not ok then error(err, 0) end
	if coroutine.status(co) ~= "dead" then coroutines[#coroutines + 1] = co end
	return co
end
function task.wait(t)
	if coroutine.isyieldable() then return coroutine.yield(t) end
	clock = clock + (t or 0)
	return t or 0
end

-- One server frame: deferred work, then Heartbeat (where the held gun is rebuilt), then due timers.
local function frame(dt)
	clock = clock + (dt or 1 / 60)
	local d = deferred; deferred = {}
	for _, fn in ipairs(d) do fn() end
	for _, fn in ipairs(heartbeat) do fn(dt or 1 / 60) end
	local due, keep = {}, {}
	for _, e in ipairs(delayed) do if e.at <= clock then due[#due + 1] = e else keep[#keep + 1] = e end end
	delayed = keep
	for _, e in ipairs(due) do e.fn() end
end
-- One pass of RangeService's 0.4 s poll (the loop the module task.spawns).
local function poll()
	clock = clock + 0.4
	for _, co in ipairs(coroutines) do
		local ok, err = coroutine.resume(co)
		if not ok then error(err, 0) end
	end
	frame()
end

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------
local V3m = {}
local V3 = {}
V3.__index = function(v, k)
	if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
	if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z); return V3m.new(v.X / m, v.Y / m, v.Z / m) end
	return V3m[k]
end
function V3m.new(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3) end
function V3m.Lerp(a, b, t) return a + (b - a) * t end
V3.__add = function(a, b) return V3m.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return V3m.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__mul = function(a, b)
	if type(a) == "number" then a, b = b, a end
	return V3m.new(a.X * b, a.Y * b, a.Z * b)
end
V3.__unm = function(a) return V3m.new(-a.X, -a.Y, -a.Z) end
local Vector3 = { new = V3m.new, zero = V3m.new(0, 0, 0) }

local CFm = {}
local CF = {}
CF.__index = CFm
local function cframe(pos) return setmetatable({ Position = pos or Vector3.zero, LookVector = V3m.new(0, 0, -1) }, CF) end
CF.__mul = function(a, b)
	if getmetatable(b) == CF then return cframe(a.Position + b.Position) end
	return a.Position + b
end
CF.__add = function(a, v) return cframe(a.Position + v) end
CF.__sub = function(a, v) if getmetatable(v) == V3 then return cframe(a.Position - v) end return cframe(a.Position) end
function CFm.PointToObjectSpace(cf, v) return v - cf.Position end
local CFrame = {
	new = function(x, y, z) if type(x) == "number" then return cframe(V3m.new(x, y, z)) end return cframe(x) end,
	Angles = function() return cframe() end,
	lookAt = function(at) return cframe(at) end,
	fromEulerAnglesXYZ = function() return cframe() end,
}
local Color3 = {
	fromRGB = function(r, g, b) return { R = r / 255, G = g / 255, B = b / 255 } end,
	new = function(r, g, b) return { R = r, G = g, B = b } end,
}
local Enum = setmetatable({}, { __index = function(_, kind)
	return setmetatable({}, { __index = function(_, name) return { Name = name, EnumType = kind } end })
end })

--------------------------------------------------------------------------------
-- Instances: enough of the tree for characters, prompts and the podium displays
--------------------------------------------------------------------------------
local function signal()
	local s = { fns = {} }
	function s:Connect(fn) table.insert(self.fns, fn); return { Disconnect = function() end } end
	function s:Fire(...) local list = { table.unpack(self.fns) }; for _, fn in ipairs(list) do fn(...) end end
	function s:Wait() end
	return s
end

local InstMeta = {}
local methods = {}
InstMeta.__index = function(self, k)
	local v = rawget(self, "_p")[k]
	if v ~= nil then return v end
	if methods[k] then return methods[k] end
	-- A child by name, as Roblox allows (character.HumanoidRootPart).
	for _, c in ipairs(rawget(self, "_c")) do if c.Name == k then return c end end
	return nil
end
InstMeta.__newindex = function(self, k, v)
	local p = rawget(self, "_p")
	if k == "Parent" then
		local old = p.Parent
		if old then
			local list = rawget(old, "_c")
			for i, c in ipairs(list) do if c == self then table.remove(list, i); break end end
		end
		p.Parent = v
		if v then table.insert(rawget(v, "_c"), self) end
	else
		p[k] = v
	end
end
local prompts = {}
local Instance = {}
function Instance.new(class, parent)
	local p = { ClassName = class, Name = class, Destroying = signal() }
	if class == "ProximityPrompt" then p.Triggered = signal() end
	if class == "Humanoid" then p.Died = signal(); p.Health = 100; p.MaxHealth = 100 end
	local self = setmetatable({ _p = p, _c = {}, _a = {} }, InstMeta)
	if class == "ProximityPrompt" then prompts[#prompts + 1] = self end
	if parent then self.Parent = parent end
	return self
end
function methods:FindFirstChild(name) for _, c in ipairs(rawget(self, "_c")) do if c.Name == name then return c end end end
function methods:WaitForChild(name) return self:FindFirstChild(name) end
function methods:FindFirstChildOfClass(cls) for _, c in ipairs(rawget(self, "_c")) do if c.ClassName == cls then return c end end end
function methods:GetChildren() return { table.unpack(rawget(self, "_c")) } end
function methods:IsA(cls) return self.ClassName == cls end
function methods:SetAttribute(k, v) rawget(self, "_a")[k] = v end
function methods:GetAttribute(k) return rawget(self, "_a")[k] end
function methods:GetAttributeChangedSignal() return signal() end
function methods:Destroy()
	self.Destroying:Fire()
	for _, c in ipairs(self:GetChildren()) do c:Destroy() end
	self.Parent = nil
end
function methods:PivotTo(cf)
	local root = self:FindFirstChild("HumanoidRootPart")
	if root then root.Position = cf.Position; root.CFrame = cf end
end
function methods:GetPivot() return self.CFrame or cframe(self.Position) end

local function typeof(v)
	local mt = getmetatable(v)
	if mt == InstMeta then return "Instance" end
	if mt == V3 then return "Vector3" end
	if mt == CF then return "CFrame" end
	return type(v)
end

local workspace = Instance.new("Workspace")
local Players = Instance.new("Players")
Players.PlayerRemoving = signal()
function Players:GetPlayers()
	local out = {}
	for _, c in ipairs(self:GetChildren()) do if c.ClassName == "Player" then out[#out + 1] = c end end
	return out
end
local RunService = { Heartbeat = { Connect = function(_, fn) heartbeat[#heartbeat + 1] = fn end }, Stepped = signal() }
function RunService:IsServer() return true end
function RunService:IsClient() return false end

local function node(name) return { Name = name, WaitForChild = function(_, child) return node(child) end, FindFirstChild = function(_, child) return node(child) end } end
local services = {
	ReplicatedStorage = node("ReplicatedStorage"), RunService = RunService, Players = Players,
	CollectionService = { GetTagged = function() return {} end },
}
local game = { GetService = function(_, name) return services[name] or error("no service " .. name) end }

--------------------------------------------------------------------------------
-- Stand-ins for the modules outside the question, and the client as the remotes leave it
--------------------------------------------------------------------------------
-- The client of each player: the last LoadoutChanged and RangeState it was sent. HudClient
-- (HudClient.client.lua:4534) and CombatClient (:2219, :2164) replace their copy with each arrival.
local client = {}
local function clientOf(p) client[p] = client[p] or { pushes = 0, rangeSends = 0 }; return client[p] end
local remotes = {}
local function remote(name)
	if not remotes[name] then
		local r = { OnServerEvent = signal(), OnClientEvent = signal() }
		function r:FireClient(p, arg)
			local c = clientOf(p)
			if name == "LoadoutChanged" then c.loadout = arg; c.pushes = c.pushes + 1
			elseif name == "RangeState" then c.range = arg; c.rangeSends = c.rangeSends + 1 end
		end
		function r:FireAllClients() end
		remotes[name] = r
	end
	return remotes[name]
end

local combatEnabled = false
local notices = {}
local profiles, dataCalls = {}, {}
local function profileOf(p)
	profiles[p] = profiles[p] or { Cosmetics = { gunSkin = nil }, SahurCoins = 250, Stats = { kills = 0 }, Owned = {} }
	return profiles[p]
end
local stubs = {
	Remotes = { Event = remote, Function = remote },
	CombatService = {
		IsEnabled = function() return combatEnabled end,
		SetEnabled = function(on) combatEnabled = on end,
		IsDriving = function() return false end,
	},
	PracticeDummy = {}, RateLimit = { Take = function() return true end },
	StateSync = { Notify = function(p, text) notices[p] = text end, Push = function() end },
	-- Every call is logged by name: the proof is that the range and the inventory only ever read a profile.
	PlayerData = setmetatable({}, { __index = function(_, name)
		return function(p, ...) dataCalls[name] = (dataCalls[name] or 0) + 1; if name == "Get" then return profileOf(p) end end
	end }),
	QuestService = setmetatable({}, { __index = function() return function() end end }),
	CosmeticData = { Get = function() return nil end },
	ItemModels = { Build = function() return nil end },
	GunModels = { Supports = function() return false end },
	ZFight = { Fix = function() end },
	CreativeRounds = {},
}

local cache, env = {}, nil
local function requireModule(name)
	if cache[name] ~= nil then return cache[name] end
	local m = stubs[name]
	if m == nil then
		local src = S[name] or error("the world has no module " .. tostring(name))
		m = assert(loadChunk(src, "=" .. name, "t", env))()
	end
	cache[name] = m
	return m
end
local mathx = setmetatable({ clamp = function(x, a, b) return math.max(a, math.min(b, x)) end }, { __index = math })
local tablex = setmetatable({
	clone = function(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return c end,
	clear = function(t) for k in pairs(t) do t[k] = nil end end,
	find = function(t, v) for i, x in ipairs(t) do if x == v then return i end end end,
}, { __index = table })
local warnings = {}
env = setmetatable({
	game = game, workspace = workspace, script = { Parent = node("Modules") },
	require = function(n) return requireModule(n.Name) end,
	task = task, Vector3 = Vector3, CFrame = CFrame, Color3 = Color3, Enum = Enum, Instance = Instance,
	typeof = typeof, math = mathx, table = tablex, tick = function() return wall end,
	os = setmetatable({ clock = function() return clock end, time = function() return wall end }, { __index = os }),
	warn = function(...) warnings[#warnings + 1] = table.concat({ ... }, " ") end,
	print = function() end,
}, { __index = _G })

local function chunk(src, name, extra)
	local e = setmetatable(extra or {}, { __index = env })
	return assert(loadChunk(src, "=" .. name, "t", e))(), e
end

--------------------------------------------------------------------------------
-- The real modules, and the cuts
--------------------------------------------------------------------------------
local WeaponData = requireModule("WeaponData")
local WS = requireModule("WeaponService")
local Range = requireModule("RangeService")
local Rarity = requireModule("Rarity")
local MatchConfig = requireModule("MatchConfig")

-- The held gun: an empty model carrying its id, mounted where the real MountGun puts it (HeldGun on the
-- character). Everything that decides WHICH gun is in hand is the real refreshHeldGunNow / buildHeldGun.
WS.BuildGunModel = function(def)
	local model = Instance.new("Model")
	model.Name = "HeldGun"
	model:SetAttribute("WeaponId", def.id)
	return model, nil
end
WS.MountGun = function(character, model)
	model.Name = "HeldGun"
	model.Parent = character
	return true
end

-- Lobby geometry, as parsed from LobbyService / MatchConfig by the check.
local base = MatchConfig.LobbyPosition
local center = base + Vector3.new(C.centerX, 0, C.centerZ)
local spawnOffset = Vector3.new(C.spawnX, C.spawnY, C.spawnZ)

-- Builds the range: RangeService.SetArea and the podium loop, cut from buildArena, run with the real
-- RangeService, WeaponData, Rarity and StateSync stand-in. The builders it calls (disc, decor, newDisplay,
-- billboard, pointLight, BuildStaticGun) only make parts here. Returns the three podiums in order.
local lobby = Instance.new("Model", workspace)
lobby.Name = "Lobby"
local function buildRange(day)
	wall = os.time({ year = 2026, month = 9, day = 25, hour = 12 }) + day * 86400
	for i = #prompts, 1, -1 do prompts[i] = nil end
	local labels = {}
	local function part(pos) local x = Instance.new("Part", lobby); x.Position = pos; x.CFrame = cframe(pos); return x end
	chunk(C.range, "LobbyService(range)", {
		lobby = lobby, center = center, terraceRadius = C.terraceRadius, ARENA_HEIGHT = C.arenaHeight,
		RangeService = Range, StateSync = stubs.StateSync, Rarity = Rarity, WeaponData = WeaponData,
		DARK = Color3.fromRGB(0, 0, 0), WHITE = Color3.fromRGB(255, 255, 255),
		disc = function(_, _, _, pos) return part(pos) end,
		decor = function(x) return x end,
		newDisplay = function(pos) return part(pos) end,
		pointLight = function() end,
		billboard = function(display, text) labels[#labels + 1] = { display = display, text = text } end,
		WeaponService = setmetatable({ BuildStaticGun = function(_, _, _, _, parent)
			return Instance.new("Part", parent), {}, 1
		end }, { __index = WS }),
	})
	local podiums = {}
	for i, prompt in ipairs(prompts) do
		-- The first label over each display is the gun's name (buildArena: billboard(display, def.name ...)).
		local label = labels[(i - 1) * 2 + 1]
		podiums[i] = { prompt = prompt, at = prompt.Parent.Position, name = prompt.ObjectText, label = label and label.text }
	end
	return podiums
end

-- MatchService's lobby path, cut from the real file: OnCharacterAdded's lobby branch -> PlaceInLobby.
local MS = { alive = {} }
local matchEnv = {
	MatchService = {}, state = "Waiting", alive = MS.alive, baseSpeeds = {}, MatchConfig = MatchConfig,
	WeaponService = WS, LobbyService = { SpawnOffset = spawnOffset, SpawnHalfWidth = C.spawnHalfWidth },
	buildLobby = function() end, watchDeath = function() end, reapplyBoosts = function() end,
	currentMode = {}, currentEvent = nil, StateSync = stubs.StateSync,
	Combatants = { Register = function() end }, DeathFxService = { Prepare = function() end, Apply = function() end },
}
chunk(C.lobbyCFrame .. "\n" .. C.placeInLobby .. "\n" .. C.onCharacterAdded .. "\nlobbyCFrameFn = lobbyCFrame\n", "MatchService(lobby)", matchEnv)
local MatchService = matchEnv.MatchService

--------------------------------------------------------------------------------
-- People
--------------------------------------------------------------------------------
local function body(player, at)
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part", model); root.Name = "HumanoidRootPart"; root.Position = at; root.CFrame = cframe(at)
	local torso = Instance.new("Part", model); torso.Name = "Torso"
	local head = Instance.new("Part", model); head.Name = "Head"
	Instance.new("Humanoid", model)
	model.Parent = workspace
	return model
end
local serial = 0
-- A player as the server sees one joining: a body on the pier, through the real OnCharacterAdded.
local function newPlayer(tag)
	serial = serial + 1
	local p = Instance.new("Player")
	p.Name = tag .. serial
	p.UserId = serial
	p.Parent = Players
	function p.LoadCharacter(self)
		if self.Character then self.Character:Destroy() end
		self.Character = body(self, base + spawnOffset)
		MatchService.OnCharacterAdded(self, self.Character)
	end
	p:LoadCharacter()
	frame()
	return p
end
local function standAt(p, pos) p.Character.HumanoidRootPart.Position = pos + Vector3.new(0, 3, 0) end
local function flat(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2) end

--------------------------------------------------------------------------------
-- What the player has, as the server keeps it and as their client was told it
--------------------------------------------------------------------------------
local function guns(l)
	if not l then return "(no loadout)" end
	local out = {}
	for i = 1, WS.SlotCount do local s = l.slots[i]; if s then out[#out + 1] = i .. ":" .. s.id end end
	return table.concat(out, " ")
end
local function inHand(l)
	local s = l and l.equipped and l.slots[l.equipped]
	return s and s.id or nil
end
local function snapshot(l)
	if not l then return "nil" end
	local out = {}
	for i = 1, WS.SlotCount do
		local s = l.slots[i]
		out[#out + 1] = s and (s.id .. "/" .. tostring(s.mag or s.count)) or "-"
	end
	return table.concat(out, ",") .. " held=" .. tostring(l.equipped) .. " reloading=" .. tostring(l.reloading and true or false)
end
local function heldModel(p)
	local g = p.Character and p.Character:FindFirstChild("HeldGun")
	return g and g:GetAttribute("WeaponId") or nil
end

-- I5: after the frame, the client's copy is the server's loadout, the gun on the character is the gun in
-- the held slot, and the range mode it was told matches whether it holds a range loadout.
local syncChecks, syncBad = 0, {}
local function inSync(p, label, rangeOn)
	frame()
	syncChecks = syncChecks + 1
	local l = WS.Get(p)
	local c = clientOf(p)
	local problems = {}
	if snapshot(l) ~= snapshot(c.loadout) then
		problems[#problems + 1] = "client shows " .. snapshot(c.loadout) .. " but server has " .. snapshot(l)
	end
	if heldModel(p) ~= inHand(l) then
		problems[#problems + 1] = "character holds " .. tostring(heldModel(p)) .. " but held slot is " .. tostring(inHand(l))
	end
	if rangeOn ~= nil and (c.range == true) ~= rangeOn then
		problems[#problems + 1] = "RangeState told " .. tostring(c.range) .. ", expected " .. tostring(rangeOn)
	end
	if #problems > 0 then syncBad[#syncBad + 1] = label .. ": " .. table.concat(problems, "; ") end
end

--------------------------------------------------------------------------------
-- The range as built today
--------------------------------------------------------------------------------
local podiums = buildRange(0)
local nameToId = {}
local eligible = {}
for id, def in pairs(WeaponData.Weapons) do
	count("weapons")
	if def.rarity == "Legendary" and not def.staged then eligible[#eligible + 1] = id end
	nameToId[def.name] = nameToId[def.name] and "<duplicate name>" or id
end
table.sort(eligible, function(a, b) return WeaponData.Get(a).name < WeaponData.Get(b).name end)
counts.eligible = #eligible
counts.podiums = #podiums

local function take(p, k)
	local pod = podiums[k]
	standAt(p, pod.at)
	-- A prompt only fires within its reach; standing on the pedestal's centre is always inside it.
	assert(flat(p.Character.HumanoidRootPart.Position, pod.at) <= pod.prompt.MaxActivationDistance)
	pod.prompt.Triggered:Fire(p)
	count("takes")
end
local function idOf(k) return nameToId[podiums[k].name] end

--------------------------------------------------------------------------------
-- S0. The podiums: how many, which guns, and does each one always hand out the gun it shows?
--------------------------------------------------------------------------------
check(#podiums == 3, "S0: the range has " .. #podiums .. " podiums (expected 3)")
check(#podiums < WS.SlotCount, string.format("S0: %d podiums < %d hotbar slots, so the range alone cannot fill a hotbar", #podiums, WS.SlotCount))
do
	-- Every day of one full rotation (the pick is (day + podium) mod the eligible count), every podium
	-- taken five times in a row by a fresh player: the gun received is the podium's, every time.
	local days = math.max(1, #eligible)
	local mismatches, repeatsBad, notDistinct = {}, 0, 0
	for day = 0, days - 1 do
		local pods = buildRange(day)
		local seen = {}
		for k, pod in ipairs(pods) do
			if seen[pod.name] then notDistinct = notDistinct + 1 end
			seen[pod.name] = true
			if pod.label ~= pod.name then mismatches[#mismatches + 1] = string.format("day %d podium %d: label %s, prompt %s", day, k, tostring(pod.label), pod.name) end
			local p = newPlayer("S0_")
			for n = 1, 5 do
				standAt(p, pod.at)
				pod.prompt.Triggered:Fire(p)
				count("S0 takes")
				local l = WS.Get(p)
				local got = inHand(l)
				if got ~= nameToId[pod.name] then
					mismatches[#mismatches + 1] = string.format("day %d podium %d take %d: shows %s, handed %s", day, k, n, pod.name, tostring(got))
				end
				if n > 1 and guns(l) ~= "1:" .. tostring(nameToId[pod.name]) then repeatsBad = repeatsBad + 1 end
			end
			standAt(p, base + spawnOffset); poll()
		end
		count("S0 days")
	end
	podiums = buildRange(0)
	check(#mismatches == 0, "S0: every podium hands out the gun its label and prompt name, on every take of every day"
		.. (#mismatches > 0 and (" -- " .. mismatches[1]) or ""))
	check(repeatsBad == 0, "S0: five takes in a row off one podium leave exactly one copy of its gun (" .. repeatsBad .. " bad)")
	check(notDistinct == 0 or #eligible < 3, "S0: the three podiums show three different guns every day (" .. notDistinct .. " repeats)")
	-- Prompt reach: on a half-stud grid over the terrace, how many prompts reach each spot. Horizontal
	-- distance only, which is never more than the real 3-D distance, so this over-counts if anything.
	local worst, spots = 0, 0
	local reach = podiums[1].prompt.MaxActivationDistance
	for x = -C.terraceRadius, C.terraceRadius, 0.5 do
		for z = -C.terraceRadius, C.terraceRadius, 0.5 do
			if x * x + z * z <= C.terraceRadius ^ 2 then
				spots = spots + 1
				local at = center + Vector3.new(x, 0, z)
				local n = 0
				for _, pod in ipairs(podiums) do if flat(at, pod.at) <= pod.prompt.MaxActivationDistance then n = n + 1 end end
				worst = math.max(worst, n)
			end
		end
	end
	counts.spots = spots
	counts.reach = reach
	check(worst <= 1, string.format("S0: no spot on the terrace is in reach of two podium prompts (reach %s; worst spot reaches %d; %d spots)", tostring(reach), worst, spots))
	counts.podiumGuns = idOf(1) .. ", " .. idOf(2) .. ", " .. idOf(3)
end

--------------------------------------------------------------------------------
-- S1. Every order of the three podiums: each take ADDS, nothing else moves, the new gun is in hand
--------------------------------------------------------------------------------
do
	local orders = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }
	local bad = {}
	for _, order in ipairs(orders) do
		local p = newPlayer("S1_")
		inSync(p, "S1 before any take", false)
		local want = {}
		for step, k in ipairs(order) do
			-- Spend a round from whatever is in hand, so a take that quietly refills or rebuilds the other
			-- guns shows up as a changed magazine.
			if WS.Get(p) then WS.ConsumeAmmo(p) end
			local before = {}
			local l0 = WS.Get(p)
			if l0 then for i = 1, WS.SlotCount do local s = l0.slots[i]; if s then before[i] = { ref = s, id = s.id, mag = s.mag } end end end
			take(p, k)
			local l = WS.Get(p)
			want[#want + 1] = step .. ":" .. idOf(k)
			local label = "order " .. table.concat(order, "") .. " take " .. step
			if guns(l) ~= table.concat(want, " ") then bad[#bad + 1] = label .. ": hotbar " .. guns(l) .. ", expected " .. table.concat(want, " ") end
			if inHand(l) ~= idOf(k) then bad[#bad + 1] = label .. ": in hand " .. tostring(inHand(l)) .. ", expected " .. idOf(k) end
			for i, b in pairs(before) do
				local s = l.slots[i]
				if s ~= b.ref or s.id ~= b.id or s.mag ~= b.mag then bad[#bad + 1] = label .. ": slot " .. i .. " (" .. b.id .. ") was changed" end
			end
			inSync(p, "S1 " .. label, true)
			count("S1 takes")
		end
	end
	counts.orders = #orders
	check(#bad == 0, "S1: in all 6 orders, each take adds the podium's gun to the next free slot, puts it in hand, and leaves every other gun (and its ammo) as it was"
		.. (#bad > 0 and (" -- " .. bad[1]) or ""))
end

--------------------------------------------------------------------------------
-- S2. A gun you already hold: in hand or not, once or twice in the same frame
--------------------------------------------------------------------------------
do
	local bad = {}
	local three = "1:" .. idOf(1) .. " 2:" .. idOf(2) .. " 3:" .. idOf(3)
	for k = 1, 3 do
		for _, heldFirst in ipairs({ true, false }) do
			local p = newPlayer("S2_")
			take(p, 1); take(p, 2); take(p, 3)
			local l = WS.Get(p)
			local slotOf
			for i = 1, WS.SlotCount do if l.slots[i] and l.slots[i].id == idOf(k) then slotOf = i end end
			-- Retaking needs the three guns to be held first; if S1's rule is broken, say so and skip.
			if guns(l) ~= three or not slotOf then
				bad[#bad + 1] = "could not hold all three guns to start from: " .. guns(l)
			else
				-- Hold the gun first, or hold a different one.
				WS.Equip(p, heldFirst and slotOf or (slotOf % 3) + 1)
				frame(); clock = clock + 1
				local other = {}
				for i = 1, 3 do if i ~= slotOf then l.slots[i].mag = 1; other[i] = l.slots[i] end end
				l.slots[slotOf].mag = 0
				local before = guns(l)
				local label = string.format("retake %s (%s)", idOf(k), heldFirst and "already in hand" or "not in hand")
				take(p, k)
				l = WS.Get(p)
				if guns(l) ~= before then bad[#bad + 1] = label .. ": hotbar became " .. guns(l) .. " (was " .. before .. ")" end
				if inHand(l) ~= idOf(k) then bad[#bad + 1] = label .. ": in hand " .. tostring(inHand(l)) end
				if l.slots[slotOf].mag ~= WeaponData.Get(idOf(k)).magSize then bad[#bad + 1] = label .. ": magazine " .. tostring(l.slots[slotOf].mag) .. ", not topped up" end
				for i, s in pairs(other) do if l.slots[i] ~= s or s.mag ~= 1 then bad[#bad + 1] = label .. ": slot " .. i .. " changed" end end
				inSync(p, "S2 " .. label, true)
				count("S2 cases")
			end
		end
	end
	-- Twice fast: two triggers with no frame between them (a double press, or two prompt events queued in
	-- one frame). From empty hands, and holding one gun already.
	local p = newPlayer("S2fast_")
	take(p, 1); take(p, 1)
	if guns(WS.Get(p)) ~= "1:" .. idOf(1) then bad[#bad + 1] = "double take from empty: " .. guns(WS.Get(p)) end
	inSync(p, "S2 double take from empty", true)
	take(p, 2); take(p, 2)
	if guns(WS.Get(p)) ~= "1:" .. idOf(1) .. " 2:" .. idOf(2) then bad[#bad + 1] = "double take holding one: " .. guns(WS.Get(p)) end
	if inHand(WS.Get(p)) ~= idOf(2) then bad[#bad + 1] = "double take holding one: in hand " .. tostring(inHand(WS.Get(p))) end
	inSync(p, "S2 double take holding one", true)
	count("S2 cases", 2)
	-- Rearranged in the Inventory panel (the real SwapSlots), then retaken: found where it now is.
	take(p, 3)
	WS.SwapSlots(p, 1, 3)
	local after = guns(WS.Get(p))
	take(p, 1)
	if guns(WS.Get(p)) ~= after or inHand(WS.Get(p)) ~= idOf(1) then bad[#bad + 1] = "retake after a slot swap: " .. guns(WS.Get(p)) .. " in hand " .. tostring(inHand(WS.Get(p))) end
	inSync(p, "S2 retake after a slot swap", true)
	count("S2 cases")
	check(#bad == 0, "S2: retaking a held gun (in hand or not, once or twice in one frame, after a slot swap) never adds a copy or touches another gun; it is put in hand and topped up"
		.. (#bad > 0 and (" -- " .. bad[1]) or ""))
end

--------------------------------------------------------------------------------
-- S3. Stepping off the terrace, and the edge slack
--------------------------------------------------------------------------------
do
	local p = newPlayer("S3_")
	take(p, 1); take(p, 2); take(p, 3)
	-- On the rim plus the slack: still on the range.
	standAt(p, center + Vector3.new(C.terraceRadius + 5.5, 0, 0)); poll()
	check(guns(WS.Get(p)) == "1:" .. idOf(1) .. " 2:" .. idOf(2) .. " 3:" .. idOf(3), "S3: 5.5 studs past the rim (inside the 6 stud slack) the guns stay: " .. guns(WS.Get(p)))
	standAt(p, base + spawnOffset); poll()
	check(WS.Get(p) == nil, "S3: walking off the terrace hands every range gun back (loadout " .. guns(WS.Get(p)) .. ")")
	check(heldModel(p) == nil, "S3: ...and no gun is left welded in the player's hand (" .. tostring(heldModel(p)) .. ")")
	inSync(p, "S3 walked off", false)
	check(notices[p] == "Range gun handed back.", "S3: the player is told: " .. tostring(notices[p]))
	-- Back on: a fresh start, nothing from before.
	take(p, 2)
	check(guns(WS.Get(p)) == "1:" .. idOf(2), "S3: coming back and taking one gun gives just that gun: " .. guns(WS.Get(p)))
end

--------------------------------------------------------------------------------
-- S4. Death and respawn in the lobby, through the real Died -> LoadCharacter -> OnCharacterAdded path
--------------------------------------------------------------------------------
do
	for _, pollFirst in ipairs({ true, false }) do
		local p = newPlayer("S4_")
		take(p, 1); take(p, 2)
		local hum = p.Character:FindFirstChildOfClass("Humanoid")
		hum.Health = 0
		hum.Died:Fire()
		local label = pollFirst and "(range poll runs before the next take)" or "(next take before the poll runs)"
		check(WS.Get(p) == nil, "S4: a lobby death and respawn empties the hotbar " .. label .. ": " .. guns(WS.Get(p)))
		inSync(p, "S4 respawned " .. label, nil)
		if pollFirst then
			poll()
			check(clientOf(p).range == false, "S4: the range lets go of the respawned player " .. label .. ": RangeState " .. tostring(clientOf(p).range))
		end
		take(p, 3)
		check(guns(WS.Get(p)) == "1:" .. idOf(3) and inHand(WS.Get(p)) == idOf(3),
			"S4: the first take after respawning gives exactly that gun, in hand " .. label .. ": " .. guns(WS.Get(p)))
		inSync(p, "S4 first take after respawn " .. label, true)
		take(p, 1)
		check(guns(WS.Get(p)) == "1:" .. idOf(3) .. " 2:" .. idOf(1), "S4: and the next one adds to it " .. label .. ": " .. guns(WS.Get(p)))
		count("S4 cases")
	end
end

--------------------------------------------------------------------------------
-- S5. A match starts: range guns never reach a match loadout, and the match loadout is never touched
--------------------------------------------------------------------------------
-- startMatch (MatchService.lua) LoadCharacters each joining player, then WeaponService.Reset(player) once
-- the body is in, and sets CombatService.SetEnabled(true) at its end. The spawn threads wait for bodies,
-- so the range's poll can see combat on before OR after a player's Reset. Both orders are run.
local function openingSpawn(p)
	matchEnv.state = "Loading"
	MS.alive[p] = true
	p:SetAttribute("OpeningSpawn", clock)
	p:LoadCharacter()
end
do
	for _, pollFirst in ipairs({ true, false }) do
		local label = pollFirst and "(poll sees the match before the player's Reset)" or "(Reset before the poll)"
		combatEnabled = false
		local p = newPlayer("S5_")
		local bystander = newPlayer("S5by_")
		take(p, 1); take(p, 2); take(p, 3)
		take(bystander, 1); take(bystander, 2)
		openingSpawn(p)
		local matchLoadout
		if pollFirst then
			combatEnabled = true
			poll()
			WS.Reset(p)
			matchLoadout = WS.Get(p)
		else
			WS.Reset(p)
			matchLoadout = WS.Get(p)
			combatEnabled = true
			poll()
		end
		p:SetAttribute("InMatch", true)
		matchEnv.state = "InProgress"
		poll(); poll()
		check(WS.Get(p) == matchLoadout, "S5: the match loadout survives the range's polls " .. label)
		check(guns(WS.Get(p)) == "", "S5: the match loadout holds no range gun " .. label .. ": " .. guns(WS.Get(p)))
		check(clientOf(p).range == false, "S5: the player's client leaves range mode " .. label .. ": " .. tostring(clientOf(p).range))
		-- A floor pickup in the match (LootService calls exactly this) lands in the match loadout.
		local ok = WS.GiveWeapon(p, eligible[1])
		check(ok and guns(WS.Get(p)) == "1:" .. eligible[1], "S5: a match pickup after that works " .. label .. ": " .. guns(WS.Get(p)))
		inSync(p, "S5 match pickup " .. label, false)
		-- A player who stayed in the lobby, standing on the terrace with range guns, when someone else's
		-- match starts: the range closes on them.
		check(WS.Get(bystander) == nil, "S5: a lobby player still on the terrace loses the range guns when a match starts " .. label .. ": " .. guns(WS.Get(bystander)))
		check(clientOf(bystander).range == false, "S5: ...and their client leaves range mode " .. label)
		-- Taking a podium gun while a match runs is refused and changes nothing.
		take(bystander, 1)
		check(WS.Get(bystander) == nil and notices[bystander] == "The range is closed once a match starts.",
			"S5: a take while a match runs is refused " .. label .. ": " .. guns(WS.Get(bystander)) .. " / " .. tostring(notices[bystander]))
		count("S5 cases")
		matchEnv.state = "Waiting"
		MS.alive[p] = nil
		combatEnabled = false
		p:SetAttribute("InMatch", false)
	end
end

--------------------------------------------------------------------------------
-- S6. A loadout the range did not make (#106's identity rule): never written into
--------------------------------------------------------------------------------
do
	local p = newPlayer("S6_")
	WS.Reset(p)
	WS.GiveWeapon(p, eligible[#eligible])
	local other = WS.Get(p)
	local otherBefore = guns(other)
	take(p, 1)
	check(guns(other) == otherBefore, "S6: a take never writes into a loadout the range did not make (it was " .. otherBefore .. ", now " .. guns(other) .. ")")
	check(WS.Get(p) ~= other and guns(WS.Get(p)) == "1:" .. idOf(1), "S6: the take starts a fresh range loadout instead: " .. guns(WS.Get(p)))
	take(p, 2)
	check(guns(WS.Get(p)) == "1:" .. idOf(1) .. " 2:" .. idOf(2), "S6: and the next take adds to that fresh one: " .. guns(WS.Get(p)))
	finding(string.format("S6: that other loadout (%s) is dropped by the first take, not kept. In the lobby no other loadout exists "
		.. "(PlaceInLobby clears it); a match's does, but a take then is refused while combat is on", otherBefore))
end

--------------------------------------------------------------------------------
-- S7. A full hotbar (unreachable from the podiums: 3 guns, 8 slots; measured anyway)
--------------------------------------------------------------------------------
do
	local p = newPlayer("S7_")
	take(p, 1)
	local l = WS.Get(p)
	local fillers = {}
	for _, id in ipairs(eligible) do
		if #fillers < WS.SlotCount - 1 and id ~= idOf(1) and id ~= idOf(2) then fillers[#fillers + 1] = id end
	end
	local extra = 0
	for id in pairs(WeaponData.Weapons) do
		if #fillers >= WS.SlotCount - 1 then break end
		local dup = id == idOf(1) or id == idOf(2)
		for _, f in ipairs(fillers) do if f == id then dup = true end end
		if not dup then fillers[#fillers + 1] = id; extra = extra + 1 end
	end
	for _, id in ipairs(fillers) do WS.GiveWeapon(p, id) end
	WS.Equip(p, 5)
	frame()
	local before = {}
	for i = 1, WS.SlotCount do before[i] = l.slots[i] end
	local replacedId = l.slots[5] and l.slots[5].id
	check(guns(l):match("8:") ~= nil, "S7: the hotbar is full before the take: " .. guns(l))
	take(p, 2)
	local changed = {}
	for i = 1, WS.SlotCount do
		if WS.Get(p).slots[i] ~= before[i] then changed[#changed + 1] = i end
	end
	finding(string.format("S7: full hotbar (8 guns, slot 5 in hand), take podium %s: slot(s) %s replaced; %s is gone (not dropped); in hand: %s",
		idOf(2), table.concat(changed, ","), replacedId, tostring(inHand(WS.Get(p)))))
	check(#changed == 1 and changed[1] == 5 and inHand(WS.Get(p)) == idOf(2),
		"S7: with every slot full, a new podium gun replaces only the gun in hand, the same rule as a floor pickup in a match")
	inSync(p, "S7 full hotbar take", true)
	-- Retaking a gun already in a full hotbar replaces nothing.
	local full = guns(WS.Get(p))
	take(p, 1)
	check(guns(WS.Get(p)) == full and inHand(WS.Get(p)) == idOf(1), "S7: retaking a gun already in a full hotbar replaces nothing: " .. guns(WS.Get(p)))
	inSync(p, "S7 full hotbar retake", true)
end

--------------------------------------------------------------------------------
-- S8. Retaking the gun in hand during its reload (the real Reload). The retake fills the magazine, so
-- it has to end the reload too: RangeService.Fire refuses every shot while `reloading` is set, and
-- Equip does nothing for the slot already held (pc/range-reload-fix; reports/trial-guns-proof.md).
--------------------------------------------------------------------------------
do
	local p = newPlayer("S8_")
	take(p, 1)
	WS.ConsumeAmmo(p)
	frame(); clock = clock + 1
	WS.Reload(p)
	local def = WeaponData.Get(idOf(1))
	local l = WS.Get(p)
	local started = l.reloading
	take(p, 1)
	local c = clientOf(p)
	local ended = started and not l.reloading and l.slots[l.equipped].mag == def.magSize
		and p.Character:GetAttribute("Reloading") == nil and c.loadout ~= nil and not c.loadout.reloading
	-- The cancelled timer must never land afterwards and start (or end) anything.
	local relapsed, waited = false, 0
	while waited < def.reloadTime + 0.5 do
		frame(0.05); waited = waited + 0.05
		if l.reloading or l.slots[l.equipped].mag ~= def.magSize then relapsed = true end
	end
	check(ended and not relapsed, string.format("S8: retaking the gun in hand mid-reload tops it up (%d/%d) and ends the reload at once, "
		.. "server, character and client, and the cancelled timer never lands (%s, reloadTime %.2f)", l.slots[l.equipped].mag, def.magSize, def.id, def.reloadTime))
	counts.reloadStuck = (started and l.reloading) and 1 or 0
	inSync(p, "S8 after retake", true)
	-- An ordinary reload afterwards still runs its full time and finishes.
	WS.ConsumeAmmo(p)
	frame(); clock = clock + 1
	WS.Reload(p)
	waited = 0
	while l.reloading and waited < 30 do frame(0.05); waited = waited + 0.05 end
	check(not l.reloading and l.slots[l.equipped].mag == def.magSize and waited >= def.reloadTime - 0.1,
		string.format("S8: a reload after that still finishes, full, in its own time (%.2f s)", waited))
	inSync(p, "S8 after reload", true)
end

--------------------------------------------------------------------------------
-- S9. How many snapshots a take sends (the client redraws on each)
--------------------------------------------------------------------------------
do
	local p = newPlayer("S9_")
	local c = clientOf(p)
	local n0 = c.pushes; take(p, 1); local first = c.pushes - n0
	n0 = c.pushes; take(p, 2); local add = c.pushes - n0
	n0 = c.pushes; take(p, 2); local again = c.pushes - n0
	counts.pushes = string.format("first take %d, adding take %d, retake of the gun in hand %d", first, add, again)
	check(add >= 1 and again >= 1 and first >= 1, "S9: every take sends the client at least one snapshot (" .. counts.pushes .. ")")
end

--------------------------------------------------------------------------------
-- Across everything: the client was told the truth, and saved data was only ever read
--------------------------------------------------------------------------------
check(#syncBad == 0, string.format("I5: after every take, retake, walk-off, respawn and match start (%d moments), the client's hotbar and held slot, "
	.. "the gun on the character and the range mode all match the server", syncChecks) .. (#syncBad > 0 and (" -- " .. syncBad[1]) or ""))
counts.syncChecks = syncChecks
local calls = {}
for name, n in pairs(dataCalls) do calls[#calls + 1] = name .. " x" .. n end
table.sort(calls)
local onlyReads = true
for name in pairs(dataCalls) do if name ~= "Get" then onlyReads = false end end
local touched = 0
for _, prof in pairs(profiles) do
	if prof.SahurCoins ~= 250 or prof.Stats.kills ~= 0 or next(prof.Owned) ~= nil or prof.Cosmetics.gunSkin ~= nil then touched = touched + 1 end
	for k in pairs(prof) do if k ~= "Cosmetics" and k ~= "SahurCoins" and k ~= "Stats" and k ~= "Owned" then touched = touched + 1 end end
end
check(onlyReads and touched == 0, "I7: saved data is only read (for the gun skin), never written: PlayerData calls " .. table.concat(calls, ", ")
	.. ", profiles changed " .. touched)
for _, w in ipairs(warnings) do finding("warn: " .. w) end

return rows, findings, counts
