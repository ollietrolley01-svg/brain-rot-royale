-- The drop-location picker: a real picture of the terrain you are about to land on.
--
-- A ModuleScript, not a LocalScript, for two reasons: tools/gallery.ps1 can only render UI that a
-- gallery file can require, and HudClient's main chunk is three locals from Luau's 200-local limit,
-- which is a compile failure no check in this project can see.
--
-- WHAT IT DRAWS, and why each piece is there rather than being a flat grey disc with dots on it
-- (which is what this screen was):
--   * the ground, from the server's raster: height-shaded with a hillshade from the north-west, an
--     elevation tint, and a contour every 20 studs, so a ridge reads as a ridge;
--   * water, with a lighter shore line;
--   * the roads, drawn from their REAL footprints as lines at the resolution the map is drawn at —
--     roads are what a player navigates by and a raster cell is wider than a road;
--   * the river, likewise;
--   * town rings sized by the town's own claimed radius, so a hamlet and a downtown look different;
--   * landmark diamonds, all of them named;
--   * a compass, a scale bar, and your pick as a pin with a readout that says where it is in words.
--
-- TWO RENDERERS, both proven in the same gallery run. EditableImage draws one image pixel by pixel
-- and is the good path; where `AssetService:CreateEditableImage` is unavailable or refuses, the
-- same data is drawn as a grid of Frames with runs merged along each row. The fallback is not a
-- placeholder — it is drawn from the same raster, with the same roads, labels and overlays.
--
-- THE CURSOR. Oliver: "my mouse gets locked up on the drop location checker too". The fix, which
-- this module keeps intact from HudClient's version and which must not be lost in any rewrite:
--   * a full-screen VISIBLE GuiButton with `Modal = true` behind the panel. That is the one thing
--     that beats a first-person camera relocking the mouse every frame, and it lives for exactly
--     the window's lifetime, so a window you can see is always a window you can click.
--   * the `MenuOpen` player attribute, set while the picker is up and released on a pick or a
--     close. Different job: CombatClient reads it so a click on the map does not also fire the gun.
-- The owner of the attribute is the caller (VoteDropClient) through `onMenuOpen`, because a module
-- that can be rendered in a gallery has no player to set attributes on. Both halves are checked
-- live, on real instances, by tools/vote_drop_gallery.lua's `cursor` view, with a planted fault.

-- static-check: globals Content, buffer

local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local UiKit = require(script.Parent:WaitForChild("UiKit"))
local UiParts = require(script.Parent:WaitForChild("UiParts"))

local create = UiKit.create
local Role, Type, Space, Radius, Stroke = UiKit.Role, UiKit.Type, UiKit.Space, UiKit.Radius, UiKit.Stroke

local DropPicker = {}

-- TEST SEAMS. Never set by game code; the gallery sets them to render a path a player's machine
-- would not take (the Frame fallback) and a viewport this screen cannot otherwise be given (a
-- probe frame can choose a width but not a viewport height, and `short` is decided by height).
DropPicker.ForceCells = false
DropPicker.ViewportForTest = nil

--------------------------------------------------------------------------------
-- Palette
--------------------------------------------------------------------------------

local PALETTE = {
	g = { 92, 146, 70 },
	s = { 214, 190, 140 },
	d = { 150, 124, 92 },
	k = { 132, 126, 118 },
	n = { 226, 230, 236 },
	p = { 126, 122, 116 },
	b = { 108, 84, 70 },
	l = { 206, 166, 64 },
	w = { 52, 112, 190 },
}
-- Where water meets anything else.
local SHORE = { 104, 172, 226 }
-- Roads, and the casing drawn under them. The fill is taken from what the roads on the map ACTUALLY
-- look like from above — pale grey concrete, not the near-black a map symbol would use — because the
-- question this screen has to answer is "is that the place I am about to land in". The dark casing
-- is what keeps a 2 px pale line from disappearing into grass.
local ROAD = { 156, 154, 150 }
local ROAD_EDGE = { 52, 50, 54 }
-- High ground dries out towards this; low ground deepens towards the other. The map gains relief
-- without anybody having to invent a second raster for it.
local HIGH_TINT = { 214, 206, 172 }
local LOW_TINT = { 46, 92, 58 }

local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local CONTOUR_STUDS = 20

--------------------------------------------------------------------------------
-- Decoding the server's payload
--------------------------------------------------------------------------------

local function parseSegments(text, fields)
	local out = {}
	if type(text) ~= "string" or text == "" then
		return out
	end
	for chunk in string.gmatch(text, "[^;]+") do
		local values = {}
		for value in string.gmatch(chunk, "-?%d+") do
			table.insert(values, tonumber(value))
		end
		if #values >= fields then
			table.insert(out, values)
		end
	end
	return out
end

-- The payload carries the alphabet it was encoded with, so this cannot drift from the server's.
function DropPicker.Decode(payload)
	local n = payload.n
	local alphabet = payload.alphabet or ""
	local index = {}
	for i = 1, #alphabet do
		index[string.sub(alphabet, i, i)] = i - 1
	end
	local span = payload.max - payload.min
	local classes = table.create(n * n, "g")
	local heights = table.create(n * n, 0)
	for i = 1, n * n do
		classes[i] = string.sub(payload.classes, i, i)
		local q = index[string.sub(payload.heights, i, i)] or 0
		heights[i] = payload.min + q / 63 * span
	end

	local river = {}
	for _, point in ipairs(parseSegments(payload.river, 2)) do
		table.insert(river, Vector2.new(point[1], point[2]))
	end

	return {
		n = n,
		radius = payload.radius,
		cell = 2 * payload.radius / n,
		min = payload.min,
		max = payload.max,
		classes = classes,
		heights = heights,
		roads = parseSegments(payload.roads, 5),
		river = river,
		towns = payload.towns or {},
		landmarks = payload.landmarks or {},
		mapName = payload.mapName,
		counts = payload.counts,
	}
end

--------------------------------------------------------------------------------
-- Sampling the raster
--------------------------------------------------------------------------------

local function classAt(data, u, v)
	local n = data.n
	local col = math.clamp(math.floor(u) + 1, 1, n)
	local row = math.clamp(math.floor(v) + 1, 1, n)
	return data.classes[(row - 1) * n + col]
end

-- THE LIGHT IS COMPUTED PER CELL, NOT PER PIXEL, and this is the difference between a map that
-- appears and a map you wait for. A hillshade costs a gradient and a contour test per sample: done
-- per pixel that is 147,456 samples on a 384 px disc, done per cell it is 16,384, and the pixels
-- only interpolate between them. The CLASS stays nearest-cell, so a building's edge is still an
-- edge while the light across it is smooth — interpolating the classes as well would smear a town
-- into the field around it.
local function buildFields(data)
	if data.shade then
		return
	end
	local n, cell = data.n, data.cell
	local h = data.heights
	local shade = table.create(n * n, 1)
	local tint = table.create(n * n, 0)
	local span = math.max(data.max - data.min, 1)
	for row = 1, n do
		local base = (row - 1) * n
		local above = base - (row > 1 and n or 0)
		local below = base + (row < n and n or 0)
		for col = 1, n do
			local i = base + col
			local left = base + math.max(col - 1, 1)
			local right = base + math.min(col + 1, n)
			local gx = (h[right] - h[left]) / (2 * cell)
			local gz = (h[below + col] - h[above + col]) / (2 * cell)
			-- Light from the north-west, which is the convention every paper map uses.
			local value = math.clamp(1 + 1.9 * (-gx - gz), 0.55, 1.35)
			local band = math.floor(h[i] / CONTOUR_STUDS)
			if math.floor(h[left] / CONTOUR_STUDS) ~= band
				or math.floor(h[above + col] / CONTOUR_STUDS) ~= band then
				value *= 0.87
			end
			shade[i] = value
			tint[i] = (h[i] - data.min) / span
		end
	end
	data.shade = shade
	data.tint = tint
end

-- Bilinear over a per-cell field.
local function fieldAt(field, n, u, v)
	local fx = math.clamp(u - 0.5, 0, n - 1)
	local fz = math.clamp(v - 0.5, 0, n - 1)
	local x0, z0 = math.floor(fx), math.floor(fz)
	local tx, tz = fx - x0, fz - z0
	local x1, z1 = math.min(x0 + 1, n - 1), math.min(z0 + 1, n - 1)
	local a = field[z0 * n + x0 + 1] * (1 - tx) + field[z0 * n + x1 + 1] * tx
	local b = field[z1 * n + x0 + 1] * (1 - tx) + field[z1 * n + x1 + 1] * tx
	return a * (1 - tz) + b * tz
end

-- The colour of one point of ground: class, elevation tint, hillshade, contour.
local function groundColour(data, u, v)
	local n = data.n
	local class = classAt(data, u, v)
	if class == "." then
		class = "g"
	end
	local base = PALETTE[class] or PALETTE.g
	if class == "w" then
		for _, off in ipairs(NEIGHBOURS) do
			local near = classAt(data, u + off[1], v + off[2])
			if near ~= "w" and near ~= "." then
				return SHORE[1], SHORE[2], SHORE[3]
			end
		end
		return base[1], base[2], base[3]
	end

	local r, g, b = base[1], base[2], base[3]
	-- Ground that grows takes an elevation tint — high ground dries out, low ground deepens — so a
	-- ridge reads as a ridge even where the hillshade is flat. Built and paved ground is painted,
	-- not grown, and keeps its own colour rather than fading into the hillside it stands on.
	if class == "g" or class == "d" or class == "k" or class == "s" then
		local t = fieldAt(data.tint, n, u, v)
		local up = math.max(t - 0.55, 0) / 0.45 * 0.34
		local down = math.max(0.35 - t, 0) / 0.35 * 0.18
		r = r + (HIGH_TINT[1] - r) * up + (LOW_TINT[1] - r) * down
		g = g + (HIGH_TINT[2] - g) * up + (LOW_TINT[2] - g) * down
		b = b + (HIGH_TINT[3] - b) * up + (LOW_TINT[3] - b) * down
	end
	local shade = fieldAt(data.shade, n, u, v)
	return r * shade, g * shade, b * shade
end

--------------------------------------------------------------------------------
-- The image renderer
--------------------------------------------------------------------------------

local function byteClamp(value)
	return math.clamp(math.floor(value + 0.5), 0, 255)
end

-- Paints a thick line into the pixel buffer, in PIXEL coordinates, with a one-pixel soft edge. This
-- is why the roads are vectors: at 384 px across a 2560-stud map, a road is 2.7 px wide and a
-- raster cell is 3 — drawn from the raster it is a staircase, drawn from its own footprint it is a
-- road. `alphaOf` returns nil for a pixel outside the disc so the rim stays clean.
local function paintLine(buf, W, ax, ay, bx, by, halfWidth, colour, alphaOf)
	local dx, dy = bx - ax, by - ay
	local lengthSq = dx * dx + dy * dy
	local pad = halfWidth + 1.5
	local x0 = math.max(0, math.floor(math.min(ax, bx) - pad))
	local x1 = math.min(W - 1, math.ceil(math.max(ax, bx) + pad))
	local y0 = math.max(0, math.floor(math.min(ay, by) - pad))
	local y1 = math.min(W - 1, math.ceil(math.max(ay, by) + pad))
	local painted = 0
	for py = y0, y1 do
		for px = x0, x1 do
			local cx, cy = px + 0.5, py + 0.5
			local t = 0
			if lengthSq > 0 then
				t = math.clamp(((cx - ax) * dx + (cy - ay) * dy) / lengthSq, 0, 1)
			end
			local qx, qy = ax + dx * t, ay + dy * t
			local distance = math.sqrt((cx - qx) ^ 2 + (cy - qy) ^ 2)
			local cover = math.clamp(halfWidth + 0.5 - distance, 0, 1)
			if cover > 0 then
				local disc = alphaOf(cx, cy)
				if disc > 0 then
					local o = (py * W + px) * 4
					local mix = cover * disc
					buffer.writeu8(buf, o, byteClamp(buffer.readu8(buf, o) * (1 - mix) + colour[1] * mix))
					buffer.writeu8(buf, o + 1, byteClamp(buffer.readu8(buf, o + 1) * (1 - mix) + colour[2] * mix))
					buffer.writeu8(buf, o + 2, byteClamp(buffer.readu8(buf, o + 2) * (1 - mix) + colour[3] * mix))
					painted += 1
				end
			end
		end
	end
	return painted
end

-- Draws the ground, then the river, then the roads, into one ImageLabel. Returns the label and the
-- pixel size, or nil and the reason it could not.
function DropPicker.DrawImage(parent, data, px)
	-- Up to 640 px (was 384) so a large drop screen draws the map at its own size instead of stretching
	-- a 384 px picture (Oliver 09-22 15:34).
	local W = math.clamp(math.floor(px), 192, 640)
	local ok, result = pcall(function()
		local AssetService = game:GetService("AssetService")
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(W, W) })
		local buf = buffer.create(W * W * 4)
		local cellsPerPixel = data.n / W
		local centre = W / 2
		buildFields(data)

		local function alphaOf(cx, cy)
			local dx, dy = cx - centre, cy - centre
			return math.clamp(centre - math.sqrt(dx * dx + dy * dy) + 0.5, 0, 1)
		end

		for py = 0, W - 1 do
			local v = (py + 0.5) * cellsPerPixel
			for pxl = 0, W - 1 do
				local alpha = alphaOf(pxl + 0.5, py + 0.5)
				local r, g, b = 0, 0, 0
				if alpha > 0 then
					r, g, b = groundColour(data, (pxl + 0.5) * cellsPerPixel, v)
				end
				local o = (py * W + pxl) * 4
				buffer.writeu8(buf, o, byteClamp(r))
				buffer.writeu8(buf, o + 1, byteClamp(g))
				buffer.writeu8(buf, o + 2, byteClamp(b))
				buffer.writeu8(buf, o + 3, byteClamp(alpha * 255))
			end
			if py % 48 == 47 then
				task.wait()
			end
		end

		-- World studs to pixels.
		local k = (W / 2) / data.radius
		local function toPx(x, z)
			return x * k + centre, z * k + centre
		end

		for index = 2, #data.river do
			local a, b = data.river[index - 1], data.river[index]
			local ax, ay = toPx(a.X, a.Y)
			local bx, by = toPx(b.X, b.Y)
			-- MapTerrain cuts the river 34 studs wide (MapTerrain.lua:33). The raster already paints
			-- the wide stretches as water; this line is what keeps the narrow ones continuous.
			paintLine(buf, W, ax, ay, bx, by, math.max(1.2, 17 * k), SHORE, alphaOf)
		end

		local drawn = 0
		for index, seg in ipairs(data.roads) do
			local ax, ay = toPx(seg[1], seg[2])
			local bx, by = toPx(seg[3], seg[4])
			local half = math.max(1.1, seg[5] * k / 2)
			-- Casing first, then the road on top: a 2 px line with no edge disappears into grass.
			paintLine(buf, W, ax, ay, bx, by, half + 0.8, ROAD_EDGE, alphaOf)
			paintLine(buf, W, ax, ay, bx, by, half, ROAD, alphaOf)
			drawn += 1
			if index % 40 == 0 then
				task.wait()
			end
		end

		image:WritePixelsBuffer(Vector2.zero, Vector2.new(W, W), buf)
		local label = create("ImageLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScaleType = Enum.ScaleType.Stretch,
			ZIndex = 1,
			Parent = parent,
		})
		label.ImageContent = Content.fromObject(image)
		return { label = label, pixels = W, roads = drawn }
	end)
	if ok then
		return result
	end
	return nil, tostring(result)
end

--------------------------------------------------------------------------------
-- The Frame fallback
--------------------------------------------------------------------------------

-- The same data as Frames: 56 rows of merged runs for the ground, then the roads and the river as
-- thin rotated Frames so they stay lines rather than becoming a staircase.
function DropPicker.DrawCells(parent, data, px)
	local m = 56
	local ratio = data.n / m
	local cellPx = px / m
	local frames = 0
	buildFields(data)
	for row = 1, m do
		local v = (row - 0.5) * ratio
		local runStart, runColour = nil, nil
		local function flush(endCol)
			if runStart then
				create("Frame", {
					Position = UDim2.fromOffset(math.floor((runStart - 1) * cellPx), math.floor((row - 1) * cellPx)),
					Size = UDim2.fromOffset(math.ceil((endCol - runStart + 1) * cellPx) + 1, math.ceil(cellPx) + 1),
					BackgroundColor3 = runColour,
					BorderSizePixel = 0,
					ZIndex = 1,
					Parent = parent,
				})
				frames += 1
			end
			runStart, runColour = nil, nil
		end
		for col = 1, m do
			local u = (col - 0.5) * ratio
			if classAt(data, u, v) == "." then
				flush(col - 1)
			else
				local r, g, b = groundColour(data, u, v)
				-- Quantised to 12 steps a channel: without it every cell differs by a digit and no
				-- two neighbours ever merge, which is 3,136 Frames instead of a few hundred.
				local colour = Color3.fromRGB(
					math.floor(byteClamp(r) / 12) * 12,
					math.floor(byteClamp(g) / 12) * 12,
					math.floor(byteClamp(b) / 12) * 12)
				if not runColour or colour ~= runColour then
					flush(col - 1)
					runStart, runColour = col, colour
				end
			end
		end
		flush(m)
	end

	local k = (px / 2) / data.radius
	-- A road or river drawn as a rotated Frame is clipped by the disc's SQUARE bounds, not by the
	-- circle — so a river leaving the map ran out to the corner and squared off the disc's edge in
	-- the first render. The image renderer never had this because it tests the circle per pixel.
	-- Each segment is therefore clipped against the circle before it is drawn.
	local limit = data.radius * 0.995
	local function clipToDisc(a, b)
		local d = b - a
		local length = d.Magnitude
		if length < 0.001 then
			return (a.Magnitude <= limit) and a or nil, b
		end
		local dir = d / length
		-- Distance along the ray to the two circle crossings, if there are any.
		local t = -a:Dot(dir)
		local closest = a + dir * t
		local gap = limit * limit - closest:Dot(closest)
		if gap <= 0 then
			return nil
		end
		local half = math.sqrt(gap)
		local t0 = math.max(t - half, 0)
		local t1 = math.min(t + half, length)
		if t1 <= t0 then
			return nil
		end
		return a + dir * t0, a + dir * t1
	end
	local function line(rawA, rawB, width, colour, zIndex)
		local a, b = clipToDisc(rawA, rawB)
		if not a or not b then
			return
		end
		local mid = (a + b) / 2
		local length = (b - a).Magnitude * k
		if length < 0.5 then
			return
		end
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, mid.X * k, 0.5, mid.Y * k),
			Size = UDim2.fromOffset(length + width, width),
			BackgroundColor3 = Color3.fromRGB(colour[1], colour[2], colour[3]),
			BorderSizePixel = 0,
			Rotation = math.deg(math.atan2(b.Y - a.Y, b.X - a.X)),
			ZIndex = zIndex,
			Parent = parent,
		})
		frames += 1
	end
	for index = 2, #data.river do
		line(data.river[index - 1], data.river[index], math.max(2, 34 * k), SHORE, 2)
	end
	local roads = 0
	for _, seg in ipairs(data.roads) do
		line(Vector2.new(seg[1], seg[2]), Vector2.new(seg[3], seg[4]), math.max(2, seg[5] * k), ROAD, 2)
		roads += 1
	end
	return { frames = frames, roads = roads }
end

--------------------------------------------------------------------------------
-- Overlays: compass, rings, labels, scale, pin
--------------------------------------------------------------------------------

local function textWidth(text, size, font)
	local ok, measured = pcall(function()
		return TextService:GetTextSize(text, size, font, Vector2.new(4000, 200)).X
	end)
	return ok and measured or #text * size * 0.58
end

local function bearingName(dx, dz)
	local degrees = (math.deg(math.atan2(dx, -dz)) + 360) % 360
	local names = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
	return names[math.floor((degrees + 22.5) / 45) % 8 + 1]
end

local function overlaps(a, b)
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- A label in a dark pill, so a name is legible over grass, water or a roof alike.
local function makePill(parent, text, size, font, colour, zIndex)
	local width = textWidth(text, size, font) + 12
	local height = size + 6
	local frame = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = Role.Scrim,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		ZIndex = zIndex,
		Parent = parent,
	}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	local label = create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = font,
		Text = text,
		TextColor3 = colour,
		TextSize = size,
		ZIndex = zIndex + 1,
		Parent = frame,
	})
	return frame, label, width, height
end

-- Everything over the ground. Returns a view the panel drives: `setPick` moves the pin and answers
-- the readout, `labels` reports how the de-collision pass went.
function DropPicker.DrawOverlays(disc, px, data, options)
	options = options or {}
	local labelSize = options.labelSize or 12
	local k = (px / 2) / data.radius
	local half = px / 2
	local function at(x, z)
		return UDim2.new(0.5, x * k, 0.5, z * k)
	end

	-- The rim: a dark band that hides the raster's own edge, and a thin accent ring outside it.
	create("UIStroke", { Color = Role.Base, Thickness = 4, Parent = disc })
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 10, 1, 10),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = disc,
	}, {
		create("UICorner", { CornerRadius = UDim.new(1, 0) }),
		create("UIStroke", { Color = Role.Accent, Thickness = 1, Transparency = 0.4 }),
	})

	-- Compass INSIDE the rim. Outside it, on a 296 px phone panel, the letters land outside the
	-- panel — which is exactly what the first draft did.
	local inset = half - labelSize
	for _, point in ipairs({ { "N", 0, -1 }, { "E", 1, 0 }, { "S", 0, 1 }, { "W", -1, 0 } }) do
		create("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, point[2] * inset, 0.5, point[3] * inset),
			Size = UDim2.fromOffset(18, 18),
			BackgroundTransparency = 1,
			Font = Type.Label.Font,
			Text = point[1],
			TextColor3 = point[1] == "N" and Role.Accent or Role.Text,
			TextStrokeColor3 = Role.Scrim,
			TextStrokeTransparency = 0.2,
			TextSize = labelSize + 1,
			ZIndex = 9,
			Parent = disc,
		})
	end

	-- Town rings, at the town's own radius.
	for _, town in ipairs(data.towns) do
		local ring = math.max(town.r * k, 8)
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = at(town.x, town.z),
			Size = UDim2.fromOffset(ring * 2, ring * 2),
			BackgroundTransparency = 1,
			ZIndex = 4,
			Parent = disc,
		}, {
			create("UICorner", { CornerRadius = UDim.new(1, 0) }),
			create("UIStroke", { Color = Role.Text, Thickness = 1, Transparency = 0.5 }),
		})
	end

	-- Landmark diamonds.
	for _, landmark in ipairs(data.landmarks) do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = at(landmark.x, landmark.z),
			Size = UDim2.fromOffset(10, 10),
			BackgroundColor3 = Role.Accent,
			BorderSizePixel = 0,
			Rotation = 45,
			ZIndex = 5,
			Parent = disc,
		}, { create("UIStroke", { Color = Role.Base, Thickness = 2 }) })
	end

	--------------------------------------------------------------------------------
	-- Labels, placed so they do not sit on each other
	--
	-- The first draft put every name at a fixed offset under its marker. On a real map that reads
	-- as "SIX SEVEN SQUARE" clipped to "EN SQUARE" by a landmark 40 studs away. So: towns first
	-- (they are the bigger thing), then landmarks, each trying four anchors in turn, and a name
	-- that fits nowhere gives up its text and keeps a marker that says something is there.
	--------------------------------------------------------------------------------

	-- The compass and the scale bar are placed before any name is, so they are in the list the
	-- de-collision pass avoids. Leaving them out is the same bug one level down: a town name would
	-- clear every other name and still land on top of the "W".
	local barStuds = data.radius >= 1100 and 400 or 200
	local barPx = barStuds * k
	local placed = {
		{ x = half - (barPx + 88) / 2, y = half + px * 0.355 - 9, w = barPx + 88, h = 18 },
	}
	for _, point in ipairs({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }) do
		table.insert(placed, { x = half + point[1] * inset - 11, y = half + point[2] * inset - 11, w = 22, h = 22 })
	end
	local reserved = #placed
	-- `rects` is the evidence: the gallery asserts no two of them overlap, which is the whole point
	-- of the pass below and cannot be judged from a screenshot at 375 px wide.
	local labels = { placed = 0, moved = 0, dropped = 0, rects = placed, reserved = reserved }
	local requests = {}
	for _, town in ipairs(data.towns) do
		table.insert(requests, {
			text = string.upper(town.name), x = town.x, z = town.z, colour = Role.Text,
			font = Type.Label.Font, size = labelSize, gap = math.max(town.r * k, 8) + 4, zIndex = 6,
		})
	end
	for _, landmark in ipairs(data.landmarks) do
		table.insert(requests, {
			text = landmark.name, x = landmark.x, z = landmark.z, colour = Role.Accent,
			font = Type.Caption.Font, size = labelSize - 1, gap = 9, zIndex = 6,
		})
	end

	local pills = {}
	for _, request in ipairs(requests) do
		local frame, label, w, h = makePill(disc, request.text, request.size, request.font, request.colour, request.zIndex)
		local cx, cz = request.x * k + half, request.z * k + half
		local candidates = {
			{ cx, cz + request.gap + h / 2 },
			{ cx, cz - request.gap - h / 2 },
			{ cx + request.gap + w / 2 + 2, cz },
			{ cx - request.gap - w / 2 - 2, cz },
		}
		local chosen, index = nil, 0
		for try, candidate in ipairs(candidates) do
			local rect = { x = candidate[1] - w / 2, y = candidate[2] - h / 2, w = w, h = h }
			-- Inside the disc's box, and clear of everything already placed.
			if rect.x >= 0 and rect.y >= 0 and rect.x + w <= px and rect.y + h <= px then
				local clear = true
				for _, other in ipairs(placed) do
					if overlaps(rect, other) then
						clear = false
						break
					end
				end
				if clear then
					chosen, index = rect, try
					break
				end
			end
		end
		if chosen then
			frame.Position = UDim2.fromOffset(chosen.x + w / 2, chosen.y + h / 2)
			table.insert(placed, chosen)
			table.insert(pills, { frame = frame, label = label, rect = chosen })
			labels.placed += 1
			if index > 1 then
				labels.moved += 1
			end
		else
			-- No room anywhere: the name goes, the place does not. A hollow ring marks it, so this
			-- reads as "somewhere with no room for its name" rather than as nothing at all.
			frame:Destroy()
			create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = at(request.x, request.z),
				Size = UDim2.fromOffset(14, 14),
				BackgroundTransparency = 1,
				ZIndex = 6,
				Parent = disc,
			}, {
				create("UICorner", { CornerRadius = UDim.new(1, 0) }),
				create("UIStroke", { Color = request.colour, Thickness = 1.5, Transparency = 0.2 }),
			})
			labels.dropped += 1
		end
	end

	-- Scale bar, inside the disc at the bottom so it can never collide with the words underneath
	-- the map — which is where the first draft put it, on top of the LANDING readout. Its space was
	-- reserved above, before any name was placed.
	local scale = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, px * 0.355),
		Size = UDim2.fromOffset(barPx + 88, 18),
		BackgroundColor3 = Role.Scrim,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		ZIndex = 8,
		Parent = disc,
	}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	local bar = create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
		Size = UDim2.fromOffset(barPx, 2),
		BackgroundColor3 = Role.Text,
		BorderSizePixel = 0,
		ZIndex = 9,
		Parent = scale,
	})
	for _, side in ipairs({ 0, 1 }) do
		create("Frame", {
			AnchorPoint = Vector2.new(side, 0.5),
			Position = UDim2.new(side, 0, 0.5, 0),
			Size = UDim2.fromOffset(2, 8),
			BackgroundColor3 = Role.Text,
			BorderSizePixel = 0,
			ZIndex = 9,
			Parent = bar,
		})
	end
	create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		-- 64 px, not 50: "400 studs" at 11 px measures 55 and a right-aligned label in a 50 px box
		-- does not shrink, it loses its first characters — the render read "00 studs".
		Size = UDim2.fromOffset(64, 14),
		BackgroundTransparency = 1,
		Font = Type.Caption.Font,
		Text = string.format("%d studs", barStuds),
		TextColor3 = Role.Text,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 9,
		Parent = scale,
	})

	-- The pick: a ring, a pin and a stalk, drawn over everything.
	local pinRing = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(34, 34),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 10,
		Parent = disc,
	}, {
		create("UICorner", { CornerRadius = UDim.new(1, 0) }),
		create("UIStroke", { Color = Role.Accent, Thickness = 2, Transparency = 0.3 }),
	})
	local pin = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = Role.Accent,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 11,
		Parent = disc,
	}, {
		create("UICorner", { CornerRadius = UDim.new(1, 0) }),
		create("UIStroke", { Color = Role.Scrim, Thickness = 3 }),
	})

	local places = {}
	for _, town in ipairs(data.towns) do
		table.insert(places, town)
	end
	for _, landmark in ipairs(data.landmarks) do
		table.insert(places, landmark)
	end

	local view = { labels = labels }

	-- Moves the pin and answers what to say about it. A label the pin covers fades rather than
	-- being hidden by it: the player put the pin there, and a name under it is still information.
	function view.setPick(x, z)
		if not x then
			pin.Visible = false
			pinRing.Visible = false
			for _, entry in ipairs(pills) do
				entry.label.TextTransparency = 0
				entry.frame.BackgroundTransparency = 0.25
			end
			return nil
		end
		pin.Position = at(x, z)
		pinRing.Position = pin.Position
		pin.Visible = true
		pinRing.Visible = true

		-- A name the pin sits on FADES rather than being covered: the player put the pin there, and
		-- the name underneath is still the thing that tells them where "there" is. The first render
		-- faded it to 0.55 over a 0.7 pill, which made "Sahur Hot Springs" unreadable — the point is
		-- to let the pin read as the top layer, not to delete the label.
		local pinRect = { x = x * k + half - 15, y = z * k + half - 15, w = 30, h = 30 }
		for _, entry in ipairs(pills) do
			local under = overlaps(pinRect, entry.rect)
			entry.label.TextTransparency = under and 0.3 or 0
			entry.frame.BackgroundTransparency = under and 0.45 or 0.25
		end

		local nearest, best = nil, math.huge
		for _, place in ipairs(places) do
			local distance = math.sqrt((place.x - x) ^ 2 + (place.z - z) ^ 2)
			if distance < best then
				nearest, best = place, distance
			end
		end
		if not nearest then
			return "Landing spot set"
		end
		if best < 70 then
			return string.format("Landing at %s", nearest.name)
		end
		return string.format("%d studs %s of %s", math.floor(best / 10 + 0.5) * 10,
			bearingName(x - nearest.x, z - nearest.z), nearest.name)
	end

	return view
end

-- The whole map at a given pixel size: ground, roads, overlays. `options.cells` forces the fallback.
function DropPicker.DrawMap(parent, data, px, options)
	options = options or {}
	local disc = create("Frame", {
		AnchorPoint = options.anchor or Vector2.zero,
		Position = options.position or UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(px, px),
		BackgroundColor3 = Role.Surface,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = options.zIndex or 1,
		Parent = parent,
	}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	local renderer, detail = "image", nil
	if not (options.cells or DropPicker.ForceCells) then
		local image, reason = DropPicker.DrawImage(disc, data, px)
		if image then
			detail = string.format("%dx%d pixels, %d road segments", image.pixels, image.pixels, image.roads)
		else
			renderer = "cells-after-image-failed"
			warn("[DropPicker] EditableImage unavailable, drawing cells instead: " .. tostring(reason))
		end
	else
		renderer = "cells"
	end
	if renderer ~= "image" then
		local cells = DropPicker.DrawCells(disc, data, px)
		detail = string.format("%d Frames, %d road segments", cells.frames, cells.roads)
	end

	local view = DropPicker.DrawOverlays(disc, px, data, options)
	view.frame = disc
	view.renderer = renderer
	view.detail = detail
	return view
end

--------------------------------------------------------------------------------
-- The screen
--------------------------------------------------------------------------------

local function viewportOf()
	if DropPicker.ViewportForTest then
		return DropPicker.ViewportForTest
	end
	local camera = workspace.CurrentCamera
	return camera and camera.ViewportSize or Vector2.new(1280, 720)
end

local Picker = {}
Picker.__index = Picker

-- `parent` is a ScreenGui. `onPick(x, z)` is called with studs; `onMenuOpen(open)` with the window's
-- state, and it is the caller's job to write the player attribute — see the note at the top.
function DropPicker.new(options)
	local self = setmetatable({}, Picker)
	self.parent = options.parent
	self.onPick = options.onPick
	self.onMenuOpen = options.onMenuOpen
	self.zIndex = options.zIndex or 40
	self.touch = options.touch
	self.seconds = options.seconds or 0
	self.totalSeconds = options.totalSeconds or 15
	self.visible = false
	self.menuOpenHeld = false
	self.data = nil
	self.pick = nil

	-- THE CURSOR FIX, half one. A VISIBLE GuiButton with Modal = true frees the mouse for as long
	-- as it is up, which is the one thing that beats a first-person camera relocking it every
	-- frame. It is created with the picker and lives exactly as long as the window, so a window you
	-- can see is always a window you can click. `options.noModal` exists for one reason: the
	-- gallery builds a deliberately broken picker with it, to prove the check that reads these
	-- properties can actually fail.
	if not options.noModal then
		self.modal = create("TextButton", {
			Name = "DropSelectOverlay",
			Size = UDim2.fromScale(1, 1),
			Position = UDim2.fromScale(0, 0),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.45,
			AutoButtonColor = false,
			Modal = true,
			Selectable = false,
			Text = "",
			Visible = false,
			ZIndex = self.zIndex - 1,
			Parent = self.parent,
		})
	end

	self.root = create("Frame", {
		Name = "DropPicker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = self.zIndex,
		Parent = self.parent,
	})
	return self
end

function Picker:isTouch()
	if self.touch ~= nil then
		return self.touch
	end
	local ok, touch = pcall(function()
		return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	end)
	return ok and touch or false
end

-- Studs from a click inside the disc, held to the playable limit so the pin shows where you will
-- actually land rather than where you clicked.
function Picker:worldFromInput(position)
	local disc = self.discFrame
	if not disc or not self.data then
		return nil
	end
	local size, origin = disc.AbsoluteSize, disc.AbsolutePosition
	local px = position.X - origin.X - size.X / 2
	local py = position.Y - origin.Y - size.Y / 2
	local scale = self.data.radius / math.max(size.X / 2, 1)
	local x, z = px * scale, py * scale
	local limit = self.data.radius * 0.96
	local distance = math.sqrt(x * x + z * z)
	if distance > limit then
		local pull = limit / math.max(distance, 1)
		x, z = x * pull, z * pull
	end
	return x, z
end

function Picker:SetPayload(payload)
	if payload then
		self.data = DropPicker.Decode(payload)
	else
		self.data = nil
	end
	self.pick = nil
	self.built = nil
	if self.visible then
		self:Layout()
	end
end

function Picker:SetSeconds(seconds)
	self.seconds = seconds or 0
	if self.clock then
		self.clock.Text = tostring(math.max(0, math.floor(self.seconds)))
	end
	if self.timeFill then
		self.timeFill.Size = UDim2.fromScale(math.clamp(self.seconds / math.max(self.totalSeconds, 1), 0, 1), 1)
	end
end

function Picker:SetPick(x, z, fromServer)
	self.pick = x and { x = x, z = z } or nil
	if self.mapView then
		local readout = self.mapView.setPick(x, z)
		if self.readout then
			self.readout.Text = readout or self.emptyReadout
			self.readout.TextColor3 = readout and Role.Positive or Role.Text
		end
		if self.readoutCard then
			local stroke = self.readoutCard:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = readout and Role.Positive or Role.Line
			end
		end
	end
	if x and not fromServer and self.onPick then
		self.onPick(x, z)
	end
end

function Picker:SetVisible(visible)
	visible = visible == true
	if visible and not self.built then
		self:Layout()
	end
	self.visible = visible
	self.root.Visible = visible
	if self.modal then
		-- Half one, the other end of it: the overlay follows the window exactly, so the cursor is
		-- freed while it is up and handed straight back when the phase ends.
		self.modal.Visible = visible
	end
	-- THE CURSOR FIX, half two: MenuOpen, so a click on the map does not also fire the gun. Held
	-- while the window is up and released once, never left set.
	if visible and not self.menuOpenHeld then
		self.menuOpenHeld = true
		if self.onMenuOpen then
			self.onMenuOpen(true)
		end
	elseif not visible and self.menuOpenHeld then
		self.menuOpenHeld = false
		if self.onMenuOpen then
			self.onMenuOpen(false)
		end
	end
end

function Picker:Destroy()
	self:SetVisible(false)
	if self.modal then
		self.modal:Destroy()
	end
	self.root:Destroy()
end

-- Rebuilds the panel for the viewport it is on now. Called on open, on a new map, and whenever the
-- viewport changes — a screen that only ever lays out once is how the short and tall forms end up
-- shipped untested.
function Picker:Layout()
	for _, child in ipairs(self.root:GetChildren()) do
		child:Destroy()
	end
	self.clock, self.timeFill, self.readout, self.readoutCard, self.mapView, self.discFrame = nil, nil, nil, nil, nil, nil
	self.built = true

	local viewport = viewportOf()
	local form = UiKit.form(viewport)
	local touch = self:isTouch()
	local safe = UiKit.safeArea(viewport, touch)
	-- The safe area's 96 px of thumb room at the bottom exists so the HUD does not put controls
	-- under a thumb. This screen IS the control, it is modal, and there is no HUD under it — so
	-- spending 96 px of a 390 px landscape phone on clearance would shrink the map for nothing.
	-- The top inset stays: Roblox's own bar really is there.
	local bottomInset = touch and Space.LG or safe.Bottom
	local hint = touch and "Tap anywhere on the map. Tap again to move it."
		or "Click anywhere on the map. Click again to move it."
	self.emptyReadout = touch and "Tap the map to choose where you land"
		or "Click the map to choose where you land"
	local fallbackNote = "Pick nothing and you land on a random spot, spread out from everyone else."

	local panel = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = Role.Base,
		BorderSizePixel = 0,
		ZIndex = self.zIndex,
		Parent = self.root,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, Radius.Panel) }),
		create("UIStroke", { Color = Role.Line, Thickness = Stroke.Hairline }),
	})
	self.panel = panel

	local function header(x, y, width, titleStyle, clockStyle)
		UiParts.text(panel, titleStyle, "CHOOSE YOUR DROP", Role.Accent, {
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(width - 76, titleStyle.Size + 8),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = self.zIndex + 1,
		})
		self.clock = UiParts.text(panel, clockStyle, tostring(math.floor(self.seconds)), Role.Text, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromOffset(x + width, y - 4),
			Size = UDim2.fromOffset(72, clockStyle.Size + 10),
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = self.zIndex + 1,
		})
		local track = create("Frame", {
			Position = UDim2.fromOffset(x, y + titleStyle.Size + 12),
			Size = UDim2.fromOffset(width, 4),
			BackgroundColor3 = Role.SurfaceAlt,
			BorderSizePixel = 0,
			ZIndex = self.zIndex + 1,
			Parent = panel,
		}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		self.timeFill = create("Frame", {
			Size = UDim2.fromScale(math.clamp(self.seconds / math.max(self.totalSeconds, 1), 0, 1), 1),
			BackgroundColor3 = Role.Accent,
			BorderSizePixel = 0,
			ZIndex = self.zIndex + 2,
			Parent = track,
		}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
		return y + titleStyle.Size + 16
	end

	local function readoutCard(x, y, width, height)
		local card = create("Frame", {
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(width, height),
			BackgroundColor3 = Role.Surface,
			BorderSizePixel = 0,
			ZIndex = self.zIndex + 1,
			Parent = panel,
		}, {
			create("UICorner", { CornerRadius = UDim.new(0, Radius.Card) }),
			create("UIStroke", { Color = Role.Line, Thickness = Stroke.Hairline }),
		})
		UiParts.text(card, Type.Label, "LANDING", Role.TextMuted, {
			Position = UDim2.fromOffset(Space.MD, 6),
			Size = UDim2.new(1, -Space.MD * 2, 0, 16),
			ZIndex = self.zIndex + 2,
		})
		self.readout = UiParts.text(card, Type.Body, self.emptyReadout, Role.Text, {
			Position = UDim2.fromOffset(Space.MD, 24),
			Size = UDim2.new(1, -Space.MD * 2, 0, 22),
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = self.zIndex + 2,
		})
		self.readoutCard = card
		return card
	end

	-- The map is a button: the whole disc takes the click, and the panel around it does not.
	local function drawMap(x, y, size, labelSize)
		local holder = create("TextButton", {
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(size, size),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			ZIndex = self.zIndex + 1,
			Parent = panel,
		})
		if self.data then
			self.mapView = DropPicker.DrawMap(holder, self.data, size, {
				labelSize = labelSize,
				zIndex = self.zIndex + 1,
			})
			self.discFrame = self.mapView.frame
		else
			UiParts.text(holder, Type.Body, "Drawing the map…", Role.TextMuted, {
				Size = UDim2.fromScale(1, 1),
				TextXAlignment = Enum.TextXAlignment.Center,
				ZIndex = self.zIndex + 2,
			})
		end
		holder.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			if not self.visible then
				return
			end
			local wx, wz = self:worldFromInput(input.Position)
			if wx then
				self:SetPick(wx, wz)
			end
		end)
		return holder
	end

	if form == "tall" then
		-- Portrait: one column, the map as wide as the panel allows.
		local width = math.clamp(viewport.X - safe.Left - safe.Right, 300, 420)
		local inner = width - Space.MD * 2
		local y = Space.MD
		y = header(Space.MD, y, inner, Type.Heading, Type.Title)
		y += Space.SM
		drawMap(Space.MD, y, inner, 11)
		y += inner + Space.MD
		readoutCard(Space.MD, y, inner, 50)
		y += 50 + Space.SM
		UiParts.text(panel, Type.Caption, hint .. " " .. fallbackNote, Role.TextMuted, {
			Position = UDim2.fromOffset(Space.MD, y),
			Size = UDim2.fromOffset(inner, 30),
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = self.zIndex + 1,
		})
		y += 30 + Space.MD
		panel.Size = UDim2.fromOffset(width, y)
		-- Held below Roblox's own top bar, and centred in what is left.
		local top = safe.Top + (viewport.Y - safe.Top - bottomInset - y) / 2
		panel.AnchorPoint = Vector2.new(0.5, 0)
		panel.Position = UDim2.new(0.5, 0, 0, math.max(safe.Top, math.floor(top)))
		if self.data and self.pick then
			self:SetPick(self.pick.x, self.pick.z, true)
		end
		return
	end

	-- Landscape. The map on the left, the words in a column on the right. The map is sized off the
	-- HEIGHT that is actually free, header and padding already taken out — sizing it off the raw
	-- viewport is how the first draft came out taller than an 844x390 screen.
	local column = form == "short" and 300 or 340
	local chrome = Space.MD * 2
	local free = viewport.Y - safe.Top - bottomInset - chrome
	local mapPx = math.clamp(math.floor(free), 200, form == "short" and 340 or 520)
	local width = Space.MD + mapPx + Space.LG + column + Space.MD
	local height = mapPx + chrome

	panel.Size = UDim2.fromOffset(width, height)
	panel.Position = UDim2.new(0.5, 0, 0, math.max(safe.Top, math.floor(safe.Top + (viewport.Y - safe.Top - bottomInset - height) / 2)))
	panel.AnchorPoint = Vector2.new(0.5, 0)

	drawMap(Space.MD, Space.MD, mapPx, form == "short" and 11 or 12)

	local x = Space.MD + mapPx + Space.LG
	local y = Space.MD
	y = header(x, y, column, form == "short" and Type.Heading or Type.Title,
		form == "short" and Type.Title or Type.Display)
	y += Space.SM
	readoutCard(x, y, column, 52)
	y += 52 + Space.SM
	UiParts.text(panel, Type.Body, hint, Role.Text, {
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(column, 40),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = self.zIndex + 1,
	})
	y += 44

	-- The legend, in the COLUMN. The first draft drew it at the panel's own x = 0, which put it
	-- behind the map and half outside the panel.
	local legend = create("Frame", {
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(column, 46),
		BackgroundTransparency = 1,
		ZIndex = self.zIndex + 1,
		Parent = panel,
	})
	local lx, ly = 0, 0
	for _, item in ipairs({
		{ "Town", "ring" }, { "Landmark", "diamond" }, { "Road", "road" },
		{ "Water", "w" }, { "Buildings", "b" },
	}) do
		local w = textWidth(item[1], Type.Caption.Size, Type.Caption.Font)
		if lx + 16 + w + 12 > column then
			lx, ly = 0, ly + 20
		end
		if item[2] == "ring" then
			create("Frame", {
				Position = UDim2.fromOffset(lx, ly + 1),
				Size = UDim2.fromOffset(12, 12),
				BackgroundTransparency = 1,
				ZIndex = self.zIndex + 2,
				Parent = legend,
			}, {
				create("UICorner", { CornerRadius = UDim.new(1, 0) }),
				create("UIStroke", { Color = Role.Text, Thickness = 1, Transparency = 0.4 }),
			})
		elseif item[2] == "diamond" then
			create("Frame", {
				Position = UDim2.fromOffset(lx + 2, ly + 3),
				Size = UDim2.fromOffset(9, 9),
				BackgroundColor3 = Role.Accent,
				BorderSizePixel = 0,
				Rotation = 45,
				ZIndex = self.zIndex + 2,
				Parent = legend,
			})
		elseif item[2] == "road" then
			create("Frame", {
				Position = UDim2.fromOffset(lx, ly + 6),
				Size = UDim2.fromOffset(12, 3),
				BackgroundColor3 = Color3.fromRGB(ROAD[1], ROAD[2], ROAD[3]),
				BorderSizePixel = 0,
				ZIndex = self.zIndex + 2,
				Parent = legend,
			})
		else
			local base = PALETTE[item[2]]
			create("Frame", {
				Position = UDim2.fromOffset(lx, ly + 1),
				Size = UDim2.fromOffset(12, 12),
				BackgroundColor3 = Color3.fromRGB(base[1], base[2], base[3]),
				BorderSizePixel = 0,
				ZIndex = self.zIndex + 2,
				Parent = legend,
			}, { create("UICorner", { CornerRadius = UDim.new(0, 3) }) })
		end
		UiParts.text(legend, Type.Caption, item[1], Role.TextMuted, {
			Position = UDim2.fromOffset(lx + 16, ly),
			Size = UDim2.fromOffset(w + 4, 14),
			ZIndex = self.zIndex + 2,
		})
		lx += 16 + w + 12
	end

	y += 48
	UiParts.text(panel, Type.Caption, fallbackNote, Role.TextMuted, {
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(column, 30),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = self.zIndex + 1,
	})

	if self.data and self.pick then
		self:SetPick(self.pick.x, self.pick.z, true)
	end
end

return DropPicker
