-- Where the team picker goes, and how big it is: one pure decision, so tools/team_picker_check.py can
-- sweep every screen size without a Studio window and the gallery renders exactly what a player sees.
--
-- The picker is up during a team mode's Loading, in the lobby, so what it must stay clear of is the
-- LOBBY'S screen, in screen pixels (the frame a ScreenGui with IgnoreGuiInset uses):
--   * Roblox's top bar (the GuiInset band) and the device's safe area (notches, rounded corners, the
--     home indicator) -- the picker lives inside both;
--   * the chat window, top-left -- read from TextChatService when it has one open, else (desktop) the
--     default window's footprint; a phone starts with chat closed behind its top-bar button;
--   * the lobby HUD: HudClient's banner (and the ready button, which hides in Loading but is reserved
--     anyway), the coin chip, the MENU stack and its MenuStackToggle tab, and on a touch screen every
--     rect PhoneLayout gives those plus Roblox's own jump button and thumbstick;
--   * and everything else drawn at that moment by any other ScreenGui (Measure): the pet tile, the
--     event pill, whatever the lobby HUD grows next;
--   * the vote: it is never up at the same time (the server opens the picker only after the vote's
--     winner reveal), which tools/team_picker_check.py asserts rather than this module dodging it.
-- The stamina bar is not in the list: it hides while a screen holds the cursor (HudClient reads the
-- MenuOpen attribute), and the picker holds it (MenuOpenClaims).
--
-- The panel is then fitted into what is left: of every empty rectangle between those zones, the one
-- that takes the best panel -- its variant (cards side by side or stacked, regular or the phone-sized
-- compact) and roster rows chosen for the biggest scale that keeps every text at 12 px or more.

local TeamPickerLayout = {}

-- The panel's natural (scale 1) measurements, per size class. TeamPickerScreen builds from these and
-- nothing else. "regular" is drawn at 0.86x to 1.2x; "compact" is the phone version, drawn at exactly
-- its own size (its smallest text is already 12 px), for the screens where the lobby HUD leaves only a
-- phone-sized hole.
TeamPickerLayout.Metrics = {
	regular = {
		pad = 16, header = 62, gap = 12, footer = 52, band = 60, row = 22, botsLine = 22, action = 40,
		cardPad = 10, wideWidth = 660, tallWidth = 360, emblem = 44, timerW = 76, key = 24, autoW = 250,
		footButton = 44, panelRadius = 16, cardRadius = 12, controlRadius = 8, check = 20,
		text = { title = 26, sub = 14, name = 20, count = 14, row = 15, bots = 14, action = 16, key = 14,
			timer = 24, initial = 20, note = 14, auto = 16 },
		maxScale = 1.2,
	},
	-- The phone version: AUTO sits in the header (no footer), the bots share the count line, and the
	-- seconds are a figure beside the title, so a card and the chrome round it cost as little as they can.
	compact = {
		pad = 8, header = 44, gap = 6, footer = 0, band = 42, row = 18, botsLine = 0, action = 28,
		cardPad = 6, wideWidth = 300, tallWidth = 280, emblem = 30, timerW = 30, key = 20, autoW = 104,
		footButton = 40, panelRadius = 12, cardRadius = 10, controlRadius = 8, check = 16, autoInHeader = true,
		text = { title = 18, sub = 12, name = 15, count = 12, row = 13, bots = 12, action = 13, key = 12,
			timer = 18, initial = 14, note = 12, auto = 13 },
		maxScale = 1.0,
	},
}
-- Each variant: which metrics, and whether the two cards sit side by side or stacked.
TeamPickerLayout.Variants = {
	{ id = "wide", metrics = "regular", stacked = false },
	{ id = "tall", metrics = "regular", stacked = true },
	{ id = "compact", metrics = "compact", stacked = false },
	{ id = "compactTall", metrics = "compact", stacked = true },
}
-- The smallest text a set of metrics has at scale 1; the scale floor keeps it at 12 px or more.
function TeamPickerLayout.MinText(metrics)
	local least = math.huge
	for _, size in pairs(metrics.text) do
		least = math.min(least, size)
	end
	return least
end
function TeamPickerLayout.MinScale(metrics)
	return 12 / TeamPickerLayout.MinText(metrics) - 1e-6
end
-- The most and fewest roster rows a card shows.
TeamPickerLayout.MaxRows, TeamPickerLayout.MinRows = 5, 1

-- The default Roblox chat window's footprint (TextChatService, top-left under the bar), for when
-- the real one has not drawn yet. Generous on purpose: a picker a little smaller beats one under chat.
TeamPickerLayout.ChatDefault = { desktop = Vector2.new(420, 270) }

-- Desktop lobby pieces, from their owners' constants (checked against the real modules by
-- tools/team_picker_check.py so a move there fails here instead of silently overlapping).
TeamPickerLayout.Desktop = {
	-- HudClient's banner: centred, 440x56 at y 10. The ready button: (0.5, 232) + 230x60 at y 8.
	banner = { dx = -220, y = 10, w = 440, h = 56 },
	ready = { dx = 232, y = 8, w = 230, h = 60 },
	-- MenuClient's coin chip at (16, 78) and the MENU stack from y 124, 300 wide, in a ScreenGui that
	-- KEEPS the inset (so + inset here). MenuStackToggle's STACK_TOP / STACK_SIZE.
	coins = { x = 16, y = 78, w = 210, h = 44, inset = true },
	stack = { x = 0, y = 124, w = 300, h = 460, inset = true },
}

local function rect(x, y, w, h)
	return { x = x, y = y, w = w, h = h, x1 = x + w, y1 = y + h }
end
TeamPickerLayout.rect = rect

local function intersects(a, b)
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end
TeamPickerLayout.intersects = intersects

-- The PhoneLayout rects that are drawn in the lobby on a touch screen, plus Roblox's own controls. Not
-- the ready button or the event pill: both are down in Loading, and Measure sees them if that changes.
TeamPickerLayout.TouchZones = { "topBar", "menu", "stackTab", "cam", "banner", "coins", "companion",
	"petIcon", "jump", "stick" }

-- Every rect the picker must not touch. `ctx`: { inset, touch, phone = PhoneLayout.Rects(viewport) or
-- nil, chat = rect or nil }.
function TeamPickerLayout.Zones(viewport, ctx)
	local W, H = viewport.X, viewport.Y
	local inset = ctx.inset or 0
	local zones = {}
	local function add(name, r)
		if r and r.w > 0 and r.h > 0 then
			r.name = name
			table.insert(zones, r)
		end
	end
	add("topBar", rect(0, 0, W, inset))
	-- Chat: the live window when TextChatService has one open. Otherwise, on a desktop screen, the
	-- default window (open from the start there); on a touch screen chat starts closed behind its
	-- button in Roblox's top bar, which the topBar zone already covers.
	local chat = ctx.chat
	if not chat and not ctx.touch then
		local size = TeamPickerLayout.ChatDefault.desktop
		chat = rect(0, inset, math.min(size.X, W * 0.5), size.Y)
	end
	if chat then
		add("chat", rect(chat.x, chat.y, chat.w, chat.h))
	end
	if ctx.phone then
		for _, name in ipairs(TeamPickerLayout.TouchZones) do
			local r = ctx.phone[name]
			if type(r) == "table" and r.w then
				add(name, rect(r.x, r.y, r.w, r.h))
			end
		end
	else
		local D = TeamPickerLayout.Desktop
		add("banner", rect(W / 2 + D.banner.dx, D.banner.y, D.banner.w, D.banner.h))
		add("ready", rect(W / 2 + D.ready.dx, D.ready.y, D.ready.w, D.ready.h))
		add("coins", rect(D.coins.x, D.coins.y + inset, D.coins.w, D.coins.h))
		add("stack", rect(D.stack.x, D.stack.y + inset, D.stack.w, math.min(D.stack.h, H - D.stack.y - inset)))
	end
	-- Whatever else is on screen right now, measured (TeamPickerLayout.Measure): the pet tile, an event
	-- pill, anything a later change adds to the lobby HUD, without this list having to know about it.
	for _, r in ipairs(ctx.measured or {}) do
		add(r.name or "measured", rect(r.x, r.y, r.w, r.h))
	end
	return zones
end

-- Every empty rectangle inside `safe` bounded by the safe edges and the zones' edges (each zone grown
-- by half the gutter, so the panel keeps a gap), handed to `score`; the best one wins. A few thousand
-- candidates on a busy phone screen, once per open or resize.
function TeamPickerLayout.Free(safe, zones, gutter, score)
	gutter = gutter or 0
	local x0, y0 = safe.x + gutter, safe.y + gutter
	local x1, y1 = safe.x + safe.w - gutter, safe.y + safe.h - gutter
	local grown = {}
	for _, z in ipairs(zones) do
		table.insert(grown, rect(z.x - gutter / 2, z.y - gutter / 2, z.w + gutter, z.h + gutter))
	end
	local lefts, rights, tops, bottoms = { x0 }, { x1 }, { y0 }, { y1 }
	for _, g in ipairs(grown) do
		if g.x1 > x0 and g.x1 < x1 then table.insert(lefts, g.x1) end
		if g.x > x0 and g.x < x1 then table.insert(rights, g.x) end
		if g.y1 > y0 and g.y1 < y1 then table.insert(tops, g.y1) end
		if g.y > y0 and g.y < y1 then table.insert(bottoms, g.y) end
	end
	local best, bestScore = nil, -math.huge
	for _, l in ipairs(lefts) do
		for _, r in ipairs(rights) do
			if r - l >= 120 then
				for _, t in ipairs(tops) do
					for _, b in ipairs(bottoms) do
						if b - t >= 120 then
							local candidate = rect(l, t, r - l, b - t)
							local clear = true
							for _, g in ipairs(grown) do
								if intersects(candidate, g) then
									clear = false
									break
								end
							end
							if clear then
								local value = score and score(candidate) or candidate.w * candidate.h
								if value > bestScore then
									best, bestScore = candidate, value
								end
							end
						end
					end
				end
			end
		end
	end
	return best or rect(x0, y0, math.max(x1 - x0, 0), math.max(y1 - y0, 0))
end

-- Every drawn element of every other enabled ScreenGui under `playerGui`, in screen pixels: a visible
-- GuiObject that paints something (a background, text or an image), or, for a transparent holder, the
-- painted things inside it (three levels down). `skip` is our own ScreenGui. Roblox-only: the check
-- passes its own measured rects instead.
function TeamPickerLayout.Measure(playerGui, skip, inset)
	local out = {}
	local function paints(g)
		if g.BackgroundTransparency < 0.99 then
			return true
		end
		if (g:IsA("TextLabel") or g:IsA("TextButton")) and g.Text ~= "" and g.TextTransparency < 0.99 then
			return true
		end
		return (g:IsA("ImageLabel") or g:IsA("ImageButton")) and g.Image ~= "" and g.ImageTransparency < 0.99
	end
	local function visit(g, depth, offsetY)
		if not g:IsA("GuiObject") or not g.Visible then
			return
		end
		local p, sz = g.AbsolutePosition, g.AbsoluteSize
		if sz.X < 1 or sz.Y < 1 then
			return
		end
		-- A full-screen wash (a vignette, a fade) is drawn under everything and dodges nothing.
		local camera = workspace.CurrentCamera
		local vp = camera and camera.ViewportSize
		if vp and sz.X >= vp.X * 0.95 and sz.Y >= vp.Y * 0.95 then
			if depth < 3 then
				for _, child in ipairs(g:GetChildren()) do
					visit(child, depth + 1, offsetY)
				end
			end
			return
		end
		if paints(g) then
			table.insert(out, { name = g.Name, x = p.X, y = p.Y + offsetY, w = sz.X, h = sz.Y })
		elseif depth < 3 then
			for _, child in ipairs(g:GetChildren()) do
				visit(child, depth + 1, offsetY)
			end
		end
	end
	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and gui ~= skip and gui.Enabled then
			-- A ScreenGui that keeps the top bar measures from under it.
			local offsetY = gui.IgnoreGuiInset and 0 or (inset or 0)
			for _, child in ipairs(gui:GetChildren()) do
				visit(child, 0, offsetY)
			end
		end
	end
	return out
end

-- A card's natural height with `rows` roster rows.
function TeamPickerLayout.CardHeight(metrics, rows)
	local N = metrics
	return N.band + N.cardPad + rows * N.row + N.botsLine + N.cardPad + N.action + N.cardPad
end

function TeamPickerLayout.Natural(variant, rows)
	local N = TeamPickerLayout.Metrics[variant.metrics]
	local card = TeamPickerLayout.CardHeight(N, rows)
	local chrome = N.pad + N.header + N.gap + (N.footer > 0 and (N.gap + N.footer) or 0) + N.pad
	if variant.stacked then
		return Vector2.new(N.tallWidth, chrome + 2 * card + N.gap)
	end
	return Vector2.new(N.wideWidth, chrome + card)
end

-- The best variant, rows and scale for a rect: readable first, then the most names, then the biggest.
function TeamPickerLayout.Best(free)
	local best = nil
	for _, variant in ipairs(TeamPickerLayout.Variants) do
		local metrics = TeamPickerLayout.Metrics[variant.metrics]
		for rows = TeamPickerLayout.MaxRows, TeamPickerLayout.MinRows, -1 do
			local natural = TeamPickerLayout.Natural(variant, rows)
			local scale = math.min(metrics.maxScale, free.w / natural.X, free.h / natural.Y)
			local ok = scale >= TeamPickerLayout.MinScale(metrics)
			-- Readable first, then the most names, then the biggest panel on screen.
			local area = natural.X * natural.Y * scale * scale
			local score = (ok and 1e8 or 0) + (ok and rows * 1e6 or 0) + area / 100
			if not best or score > best.score then
				best = { variant = variant.id, stacked = variant.stacked, metrics = metrics, rows = rows,
					scale = scale, natural = natural, score = score, readable = ok }
			end
		end
	end
	return best
end

-- Centres the best fit for `free` in it.
function TeamPickerLayout.Fit(free)
	local best = TeamPickerLayout.Best(free)
	local w, h = best.natural.X * best.scale, best.natural.Y * best.scale
	best.panel = rect(math.floor(free.x + (free.w - w) / 2 + 0.5), math.floor(free.y + (free.h - h) / 2 + 0.5),
		math.floor(w + 0.5), math.floor(h + 0.5))
	best.free = free
	return best
end

-- The whole decision. `ctx` as for Zones, plus `safe` (the device's safe area in screen pixels; the
-- viewport when there is none).
function TeamPickerLayout.Compute(viewport, ctx)
	local safe = ctx.safe or rect(0, 0, viewport.X, viewport.Y)
	local top = math.max(safe.y, ctx.inset or 0)
	safe = rect(safe.x, top, safe.w, safe.y + safe.h - top)
	local zones = TeamPickerLayout.Zones(viewport, ctx)
	-- The rect that takes the best panel; among equals, the one nearest the middle of the screen.
	local cx, cy = viewport.X / 2, viewport.Y / 2
	local free = TeamPickerLayout.Free(safe, zones, ctx.touch and 8 or 16, function(r)
		local fit = TeamPickerLayout.Best(r)
		local dx, dy = (r.x + r.w / 2 - cx) / viewport.X, (r.y + r.h / 2 - cy) / viewport.Y
		return fit.score - (dx * dx + dy * dy) * 10
	end)
	local fit = TeamPickerLayout.Fit(free)
	fit.zones, fit.safe = zones, safe
	return fit
end

return TeamPickerLayout
