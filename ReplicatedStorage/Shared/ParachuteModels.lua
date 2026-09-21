-- Parachute cosmetics: the canopies bought in the shop or pulled from crates, opened over your
-- head on the match drop-in and by the Rot Glider.
--
-- ParachuteModels.Build(id, options) keeps the contract of ItemModels.Build("RotGlider",
-- { open = true }), which MovementService hangs over every character. It returns the model and
-- its body: the harness bar at the design origin, which the model pivots on, with the canopy
-- above it and the straps down to the shoulders. An id with no design here, nil included, builds
-- that default Rot Glider canopy instead, so nothing changes for anyone without a parachute.
--
-- Every canopy is solid.
--   Wings: a row of cells round an arc, each exactly as wide as its slice of the arc along the top
--   skin, so neighbours meet along the top and overlap underneath. A shaped outline (a swept manta,
--   a scalloped membrane, feather tips) is cells plus a wedge from each cell to its seams' depths,
--   so the edge runs straight from seam to seam.
--   Domes: gores and rows tiled the same way in both directions.
-- Paint, trim and decoration sit on that skin, never in place of it, so nothing anywhere is
-- see-through. tools/parachute_probe.lua raycasts every canopy from six sides and from the pilot's
-- eye to prove it. No canopy has Neon or transparency.
--
-- Designs are authored at the Rot Glider's size (1 unit = 1 stud at scale 1) and worn at scale 3.
-- Offsets that only keep two faces apart are held in world studs (`k.gap`), clear of the z-fight
-- guard's tolerance; anything smaller than worn is built worn and shrunk (see Build).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local ParachuteModels = {}

-- The scale MovementService wears a canopy at.
ParachuteModels.WornScale = 3

local V = Vector3.new
local rgb = Color3.fromRGB

-- Canopy cloth is smooth: at the worn size Roblox's Fabric texture reads as chunky knitting and
-- dulls every colour (compared in tools/parachute_gallery.lua renders, 2026-09-17). Fabric is kept
-- for sewn-on patches, where the weave is the point.
local CLOTH = Enum.Material.SmoothPlastic
local TEXTILE = Enum.Material.Fabric
local PLASTIC = Enum.Material.SmoothPlastic
local METAL = Enum.Material.Metal
local FOIL = Enum.Material.Foil
local WOOD = Enum.Material.Wood
local SAND = Enum.Material.Sand
-- Clouds and cotton candy: a soft, matte texture rather than shiny balloons.
local PUFF = Enum.Material.Snow

local DARK = rgb(40, 42, 48)
local LINE = rgb(236, 232, 220)
local BLACK = rgb(24, 24, 28)

-- The Rot Glider's wing: its arc, how far round it goes, where its top sits over the harness bar,
-- and how thick and deep its cells are.
local RADIUS = 2.3
local SPAN = math.rad(150)
local TOP = 2.6
local THICK = 0.16
local CHORD = 1.6

-- The step between two faces that must not fight, in world studs: clear of ZFight's 0.055 fix
-- tolerance at any scale.
local GAP_STUDS = 0.075

-- Where the harness lines meet the bar, either side of the head.
local RISER_X = 0.55

local function pick(value, ...)
	if type(value) == "function" then
		return value(...)
	end
	return value
end

--------------------------------------------------------------------------------
-- The kit every design builds with
--------------------------------------------------------------------------------

local function newKit(model, scale, anchored)
	-- `layout` records the wings and domes a design built, for tools/parachute_probe.lua's seam test.
	local k = { scale = scale, gap = GAP_STUDS / scale, layout = { wings = {}, domes = {} } }

	local function place(part, name, size, cframe, color, material)
		part.Name = name
		part.Size = size * scale
		part.CFrame = CFrame.new(cframe.Position * scale) * cframe.Rotation
		part.Color = color
		part.Material = material or CLOTH
		part.Transparency = 0
		part.Reflectance = 0
		part.Anchored = anchored
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		return part
	end

	local function frameOf(at)
		return typeof(at) == "CFrame" and at or CFrame.new(at)
	end

	function k.block(name, size, cframe, color, material)
		return place(Instance.new("Part"), name, size, frameOf(cframe), color, material)
	end

	function k.ball(name, diameter, at, color, material)
		local part = Instance.new("Part")
		part.Shape = Enum.PartType.Ball
		return place(part, name, V(diameter, diameter, diameter), CFrame.new(frameOf(at).Position), color, material)
	end

	-- A cylinder along `cframe`'s X axis.
	function k.cylinder(name, length, diameter, cframe, color, material)
		local part = Instance.new("Part")
		part.Shape = Enum.PartType.Cylinder
		return place(part, name, V(length, diameter, diameter), cframe, color, material)
	end

	-- A disc lying on a surface frame (its +Y the surface normal).
	function k.disc(name, thickness, diameter, cframe, color, material)
		return k.cylinder(name, thickness, diameter, cframe * CFrame.Angles(0, 0, math.pi / 2), color, material)
	end

	local function lookFrame(a, b)
		local direction = (b - a).Unit
		local up = math.abs(direction.Y) > 0.99 and Vector3.xAxis or Vector3.yAxis
		return CFrame.lookAt((a + b) / 2, b, up)
	end

	-- A cylinder from `a` to `b`.
	function k.rod(name, a, b, diameter, color, material)
		return k.cylinder(name, (b - a).Magnitude, diameter, lookFrame(a, b) * CFrame.Angles(0, math.pi / 2, 0), color, material)
	end

	-- A square-section strip from `a` to `b`: lines and cords.
	function k.strip(name, a, b, width, color, material)
		return k.block(name, V(width, width, (b - a).Magnitude), lookFrame(a, b), color, material)
	end

	function k.wedge(name, size, cframe, color, material)
		return place(Instance.new("WedgePart"), name, size, cframe, color, material)
	end

	-- A flat triangle `thickness` thick, centred on the plane through a, b and c. A right triangle
	-- is one wedge; any other is split at the foot of its height into two.
	function k.triangle(name, a, b, c, thickness, color, material)
		-- A right angle at any corner: one wedge, its right-angled edge at that corner (a wedge's
		-- bottom-back edge), one leg up its height and the other forward along its depth.
		for _, corner in ipairs({ { a, b, c }, { b, c, a }, { c, a, b } }) do
			local p, q, r = corner[1], corner[2], corner[3]
			local legUp, legForward = q - p, r - p
			if math.abs(legUp.Unit:Dot(legForward.Unit)) < 1e-3 then
				local up, back = legUp.Unit, -legForward.Unit
				return k.wedge(name, V(thickness, legUp.Magnitude, legForward.Magnitude),
					CFrame.fromMatrix(p + (legUp + legForward) / 2, up:Cross(back), up, back), color, material)
			end
		end

		local ab, ac, bc = b - a, c - a, c - b
		local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
		if abd > acd and abd > bcd then
			c, a = a, c
		elseif acd > bcd and acd > abd then
			a, b = b, a
		end
		ab, ac, bc = b - a, c - a, c - b
		local right = ac:Cross(ab).Unit
		local up = bc:Cross(right).Unit
		local back = bc.Unit
		local height = math.abs(ab:Dot(up))
		local first, second = nil, nil
		local nearDepth = math.abs(ab:Dot(back))
		if nearDepth > 1e-3 then
			first = k.wedge(name, V(thickness, height, nearDepth), CFrame.fromMatrix((a + b) / 2, right, up, back), color, material)
		end
		local farDepth = math.abs(ac:Dot(back))
		if farDepth > 1e-3 then
			second = k.wedge(name, V(thickness, height, farDepth), CFrame.fromMatrix((a + c) / 2, -right, up, -back), color, material)
		end
		return first, second
	end

	-- Rigging: how a canopy is hung from the harness.
	--
	-- Real canopies aren't hung on a handful of wires from one point. A webbing riser comes off each
	-- end of the bar, one trunk line per bundle rises from it, and each trunk cascades into thinner
	-- branches that spread to their own points under the canopy. That's what this builds, out of round
	-- cord (cylinders, which have no long flat sides to catch the light as a flat strip does).
	--
	-- `anchors` are points under the canopy, in design space. They're split by side and then into a
	-- front and a back bundle, so eight anchors come out as two risers, four trunks and eight branches
	-- rather than eight wires from two points.
	function k.rigging(anchors, color, thickness)
		local cord = color or LINE
		local thick = thickness or 0.026
		for _, side in ipairs({ -1, 1 }) do
			local mine = {}
			for _, anchor in ipairs(anchors) do
				if (anchor.X < 0 and -1 or 1) == side then
					table.insert(mine, anchor)
				end
			end
			if #mine > 0 then
				table.sort(mine, function(a, b)
					return a.Z < b.Z
				end)
				-- The riser: a short length of webbing standing off the bar's end, which the trunks leave from.
				local top = V(side * (RISER_X - 0.03), 0.44, 0)
				k.block("Riser", V(0.09, 0.52, 0.07), CFrame.new(side * (RISER_X - 0.015), 0.2, 0) * CFrame.Angles(0, 0, side * 0.08), DARK, CLOTH)
				local half = math.ceil(#mine / 2)
				for bundle = 1, 2 do
					local first = bundle == 1 and 1 or half + 1
					local last = bundle == 1 and half or #mine
					if last >= first then
						local middle = V(0, 0, 0)
						for index = first, last do
							middle += mine[index]
						end
						middle /= (last - first + 1)
						-- The cascade knot, part way up: one trunk to here, then a branch to each anchor.
						local knot = top:Lerp(middle, 0.58)
						k.rod("Line", top, knot, thick * 1.35, cord)
						for index = first, last do
							-- Each branch starts a little back down the trunk, so the joint has no gap in it.
							k.rod("Line", knot:Lerp(top, 0.06), mine[index], thick, cord)
						end
					end
				end
			end
		end
	end

	-- The Rot Glider's harness: the bar the canopy is welded over the head by, and the straps down
	-- to the shoulders.
	function k.harness(barColor, strapColor)
		local body = k.block("Body", V(1.4, 0.12, 0.12), CFrame.new(), barColor or DARK, METAL)
		-- The straps are a little deeper than the bar, so their front and back faces clear its.
		for _, x in ipairs({ -RISER_X, RISER_X }) do
			k.block("Strap", V(0.12, 1.1, 0.12 + 2 * k.gap), CFrame.new(x, -0.55, 0) * CFrame.Angles(0, 0, x * 0.3), strapColor or DARK, CLOTH)
		end
		return body
	end

	--------------------------------------------------------------------------------
	-- Wings
	--------------------------------------------------------------------------------

	-- spec: cells (odd, so there's a middle cell and the tips are alike), radius, span, top, thick.
	-- The outline is either
	--   chord and sweep: each cell's depth and how far back its middle sits (numbers, or functions of
	--     the cell's place along the span t, -1 .. 1, and its index), or
	--   frontAt and backAt: how far forward and back the wing reaches at each seam (functions of the
	--     seam's index and place along the span; either defaults to the Rot Glider's). Each cell is
	--     then the part both its seams reach, and `w.edges` fills out to the seams.
	function k.wing(spec)
		spec = spec or {}
		local w = {
			cells = spec.cells or 11,
			radius = spec.radius or RADIUS,
			span = spec.span or SPAN,
			top = spec.top or TOP,
			thick = spec.thick or THICK,
		}
		assert(w.cells % 2 == 1, "a wing needs an odd number of cells")
		table.insert(k.layout.wings, w)
		w.step = w.span / (w.cells - 1)
		local centreY = w.top - w.radius

		-- The frame `lift` out from the wing's mid-surface at `angle` round the arc: +Y outward, X
		-- along the span (towards the right-hand tip), Z front (-) to back (+).
		function w.arc(angle, lift)
			local r = w.radius + (lift or 0)
			return CFrame.new(math.sin(angle) * r, math.cos(angle) * r + centreY, 0) * CFrame.Angles(0, 0, -angle)
		end

		-- How wide a tile has to be for its face `outer` out from the mid-surface to meet its
		-- neighbours' along the seam.
		function w.tile(outer)
			return 2 * (w.radius + outer) * math.tan(w.step / 2)
		end

		-- Seam `s` runs between cells s and s + 1; seams 0 and `cells` are the two tips.
		function w.seamAngle(s)
			return -w.span / 2 + (s - 0.5) * w.step
		end

		-- A frame on a cell: `x` across it, `y` out from the mid-surface, `z` front to back. The arc
		-- turns about Z, so `z` is the same number in the cell's frame and the model's.
		function w.at(cell, x, y, z)
			return w.arc(cell.angle) * CFrame.new(x, y, z)
		end

		-- A frame on seam `s`, as `w.at` is on a cell.
		function w.onSeam(s, y, z)
			return w.arc(w.seamAngle(s)) * CFrame.new(0, y, z)
		end

		-- Where the cells either side of seam `s` overlap front to back (just the tip cell's chord at a
		-- tip).
		function w.seamChord(s)
			local left, right = w.list[s], w.list[s + 1]
			if left and right then
				return math.max(left.front, right.front), math.min(left.back, right.back)
			end
			local cell = left or right
			return cell.front, cell.back
		end

		-- Which way along X is further out past tip seam `s`.
		function w.outward(s)
			return s == 0 and -1 or 1
		end

		local seamed = spec.frontAt ~= nil or spec.backAt ~= nil
		local function seamT(s)
			return w.seamAngle(s) / (w.span / 2)
		end

		w.list = {}
		for i = 1, w.cells do
			local angle = -w.span / 2 + (i - 1) * w.step
			local t = angle / (w.span / 2)
			local cell = {
				i = i,
				t = t,
				angle = angle,
				-- A hundredth over, as the Rot Glider's cells are, so the seams close on the top skin.
				width = w.tile(w.thick / 2) + 0.01,
				-- The arc turns each cell about Z, so every cell's front face lies in the same plane as
				-- its neighbours', and they overlap underneath: flush faces. Every second cell stands a
				-- gap longer at both ends, and what's laid on it steps in a gap, so none are.
				stagger = i % 2 == 0 and k.gap or 0,
			}
			if seamed then
				local function front(s)
					return spec.frontAt and spec.frontAt(s, seamT(s)) or -CHORD / 2
				end
				local function back(s)
					return spec.backAt and spec.backAt(s, seamT(s)) or CHORD / 2
				end
				-- Index 1 is the seam on the cell's -X side, 2 the one on its +X side.
				cell.seamFront = { front(i - 1), front(i) }
				cell.seamBack = { back(i - 1), back(i) }
				cell.front = math.max(cell.seamFront[1], cell.seamFront[2])
				cell.back = math.min(cell.seamBack[1], cell.seamBack[2])
				cell.chord = cell.back - cell.front
				cell.sweep = (cell.front + cell.back) / 2
			else
				local chord = CHORD
				if type(spec.chord) == "function" then
					chord = spec.chord(t, i)
				elseif spec.chord then
					chord = spec.chord
				end
				local sweep = 0
				if type(spec.sweep) == "function" then
					sweep = spec.sweep(t, i)
				end
				cell.chord = chord
				cell.sweep = sweep
				cell.front = sweep - chord / 2
				cell.back = sweep + chord / 2
			end
			w.list[i] = cell
		end
		-- On a shaped wing a staggered cell's end can still land within a gap of a neighbour's (their
		-- depths differ by about the stagger), which brings back the flush faces the stagger is for. So
		-- each staggered cell takes the first stagger that clears BOTH neighbours at BOTH ends —
		-- checking only one neighbour just moves the problem to the other. A stagger can also go the
		-- other way (the cell a little shorter), which keeps every one of them small: the outline moves
		-- by at most three gaps, about a tenth of a stud as worn.
		for i = 2, w.cells - 1, 2 do
			local cell = w.list[i]
			for _, candidate in ipairs({ k.gap, -k.gap, 2 * k.gap, -2 * k.gap, 3 * k.gap, -3 * k.gap }) do
				cell.stagger = candidate
				local clear = true
				for _, neighbour in ipairs({ w.list[i - 1], w.list[i + 1] }) do
					if math.abs((cell.front - candidate) - neighbour.front) < 0.8 * k.gap
						or math.abs((cell.back + candidate) - neighbour.back) < 0.8 * k.gap then
						clear = false
					end
				end
				if clear then
					break
				end
			end
		end

		-- The cells themselves, one block each.
		function w.skin(color, material)
			for _, cell in ipairs(w.list) do
				-- Never a part with no depth, however the stagger and a shaped outline work out.
				local depth = math.max(cell.chord + 2 * cell.stagger, 0.05)
				cell.part = k.block("Cell", V(cell.width, w.thick, depth), w.at(cell, 0, 0, cell.sweep), pick(color, cell), material)
			end
		end

		-- For a wing built with frontAt/backAt: on each cell, a wedge from its end out to the deeper
		-- of its two seams, so the edge runs straight from seam to seam. Both cells at a seam reach
		-- that seam's depth there, so the outline is unbroken. `color(cell, edge)` colours them.
		function w.edges(color, material)
			for _, cell in ipairs(w.list) do
				for _, edge in ipairs({ "front", "back" }) do
					local out = edge == "front" and -1 or 1
					local depths = edge == "front" and cell.seamFront or cell.seamBack
					if depths then
						local base = cell[edge] + out * cell.stagger
						local deepSide = (depths[2] - depths[1]) * out > 0 and 2 or 1
						local deep = depths[deepSide]
						-- Only worth a wedge if the step is big enough to see: below a few gaps (about a fifth
						-- of a stud as worn) the cell's own edge is close enough, and the tiny wedges two
						-- neighbours would make meet along the seam with their sloped faces parallel — flush.
						if (deep - base) * out > 3 * k.gap then
							-- Two neighbouring wedges meet along a seam, and where the outline runs nearly
							-- straight their sloped faces come out parallel and touching: flush. Every second
							-- cell stops two gaps short of its seam's depth, which tilts its slope a few degrees
							-- clear of its neighbours' and moves the outline by about a tenth of a stud.
							if cell.i % 2 == 0 and (deep - base) * out > 3 * k.gap then
								deep -= out * 2 * k.gap
							end
							local x = (deepSide == 2 and 1 or -1) * cell.width / 2
							k.triangle("Edge", w.at(cell, x, 0, base).Position, w.at(cell, x, 0, deep).Position, w.at(cell, -x, 0, base).Position,
								w.thick, pick(color, cell, edge), material)
						end
					end
				end
			end
		end

		-- The cells as bands front to back instead: `bounds` are chord fractions (-1 front, 1 back) and
		-- `color(cell, band)` colours each. Every second band stands a gap proud on both faces and
		-- overlaps its neighbours by a gap, so no two faces are flush and no crack can open between.
		-- On staggered cells every band grows a gap at both ends, which keeps each end clear of the
		-- neighbouring cells' band ends as well as of its own cell's.
		function w.bands(bounds, color, material)
			local g = k.gap
			local last = #bounds - 1
			for _, cell in ipairs(w.list) do
				for band = 1, last do
					local z0 = cell.front + (bounds[band] + 1) / 2 * cell.chord - cell.stagger
					local z1 = cell.front + (bounds[band + 1] + 1) / 2 * cell.chord + cell.stagger
					local raised = band % 2 == 0
					local size
					if raised then
						if band > 1 then
							z0 -= g
						end
						if band < last then
							z1 += g
						end
						size = V(w.tile(w.thick / 2 + g) + 0.01 + 2 * g, w.thick + 2 * g, z1 - z0)
					else
						size = V(cell.width, w.thick, z1 - z0)
					end
					k.block("Cell", size, w.at(cell, 0, 0, (z0 + z1) / 2), color(cell, band), material)
				end
			end
		end

		-- A panel over `v0`..`v1` of a cell's chord, on its top ("top") or underside ("bottom"). It's
		-- sunk a gap into the cell and stands `proud` gaps (default 1) out of it. `inset` pulls its
		-- sides in from the seams; without one it runs a gap past them, under its neighbour's panel.
		-- An end that would land on the cell's own front or back is pulled in a gap. Returns the panel
		-- and where its ends really are, front to back, for anything laid along them.
		function w.plate(cell, v0, v1, side, color, material, inset, proud, name)
			local g = k.gap
			proud = (proud or 1) * g
			local z0 = cell.front + (v0 + 1) / 2 * cell.chord
			local z1 = cell.front + (v1 + 1) / 2 * cell.chord
			if v0 <= -1 then
				z0 += g
			end
			if v1 >= 1 then
				z1 -= g
			end
			-- On a staggered cell a panel steps in at both ends, by however far the cell is staggered
			-- (whichever way): clear of its own cell's ends and of the same panel on the cells either side.
			z0 += math.abs(cell.stagger)
			z1 -= math.abs(cell.stagger)
			local width
			if inset then
				width = cell.width - 2 * math.max(inset, g)
			else
				width = w.tile(w.thick / 2 + proud) + 0.01 + 2 * g
			end
			local sign = side == "bottom" and -1 or 1
			local y = sign * (w.thick / 2 + (proud - g) / 2)
			-- Never a panel with no depth, however narrow a band and wide a stagger are asked for.
			local depth = math.max(z1 - z0, 0.02)
			return k.block(name or "Panel", V(width, proud + g, depth), w.at(cell, 0, y, (z0 + z1) / 2), color, material), z0, z1
		end

		-- A rounded leading edge along a cell, `diameter` thick. Its ends run past the seams under
		-- its neighbours' and its front stands just proud of the cell's.
		function w.nose(cell, diameter, color, material)
			local g = k.gap
			local length = w.tile(diameter / 2) + 0.01 + 4 * g
			return k.cylinder("Nose", length, diameter, w.at(cell, 0, 0, w.noseZ(cell, diameter)), color, material)
		end

		-- Where a nose of `diameter` along a cell has its middle, front to back.
		function w.noseZ(cell, diameter)
			return cell.front - cell.stagger + diameter / 2 - 2 * k.gap
		end

		-- A rib over every seam, standing a gap proud of the skin and spanning the chord the two cells
		-- share, and a cap on each tip. A rib is only the top half: underneath, the two cells' flat
		-- faces meet in a shallow groove along the seam, and a rib hanging into it would close over a
		-- sliver of sky (a pinhole seen straight along the wing). options: tipsOnly, tipColor, tipWidth,
		-- tipHeight, tipLift (how far the cap is moved out from the mid-surface; negative hangs it below).
		function w.ribs(color, width, material, options)
			options = options or {}
			local g = k.gap
			for s = 0, w.cells do
				local tip = s == 0 or s == w.cells
				if tip or not options.tipsOnly then
					local front, back = w.seamChord(s)
					local size
					-- Two gaps past the chord for a rib, so its ends clear both the plain and the staggered
					-- cells' ends; the tip cells are never staggered (the count is odd), so a cap needs one.
					local lift
					if tip then
						size = V(options.tipWidth or (0.1 + 4 * g), options.tipHeight or (w.thick + 4 * g), back - front + 2 * g)
						lift = options.tipLift or 0
					else
						size = V(width, w.thick / 2 + g, back - front + 4 * g)
						lift = (w.thick / 2 + g) / 2
					end
					k.block(tip and "TipCap" or "Rib", size, w.arc(w.seamAngle(s), lift) * CFrame.new(0, 0, (front + back) / 2),
						tip and options.tipColor or color, material)
				end
			end
		end

		-- Suspension lines from under seams `seams`, at chord fractions `rows` of the chord either side
		-- shares, down to the riser at that end of the harness bar. Each starts inside the skin and ends
		-- inside the bar.
		function w.lines(seams, rows, color, width)
			local anchors = {}
			for _, s in ipairs(seams) do
				local front, back = w.seamChord(s)
				for _, v in ipairs(rows) do
					local z = front + (v + 1) / 2 * (back - front)
					table.insert(anchors, w.onSeam(s, -w.thick / 2 + 0.02, z).Position)
				end
			end
			k.rigging(anchors, color, width)
		end

		return w
	end

	--------------------------------------------------------------------------------
	-- Domes
	--------------------------------------------------------------------------------

	-- A round canopy on a sphere of `radius`: `gores` panels round it and `rows` of them from the
	-- crown (`crown` from the top) to the hem (`hem` from the top), the hem at height `hemY`.
	--
	-- Flat panels can't tile a sphere exactly. Each is as wide as the dome at its lower edge, so it
	-- meets the next gore all the way down, and its narrower top runs a little past its neighbours'.
	-- Where two gores are different colours that overlap shows as a small triangle of the wrong
	-- colour, so a dome is coloured by row (rings), where panels meet edge to edge.
	function k.dome(spec)
		spec = spec or {}
		local d = {
			gores = spec.gores or 16,
			rows = spec.rows or 4,
			radius = spec.radius or 2.3,
			thick = spec.thick or 0.14,
			crown = spec.crown or math.rad(12),
			hem = spec.hem or math.rad(66),
			hemY = spec.hemY or 1.35,
		}
		d.centreY = d.hemY - d.radius * math.cos(d.hem)
		d.rowAngle = (d.hem - d.crown) / d.rows
		table.insert(k.layout.domes, d)

		-- The frame `lift` out from the mid-surface at `polar` from the top and `azimuth` round: +Y
		-- outward, X round the dome, Z down towards the hem.
		function d.frame(polar, azimuth, lift)
			local r = d.radius + (lift or 0)
			local out = V(math.sin(polar) * math.sin(azimuth), math.cos(polar), math.sin(polar) * math.cos(azimuth))
			local round = V(math.cos(azimuth), 0, -math.sin(azimuth))
			return CFrame.fromMatrix(V(0, d.centreY, 0) + out * r, round, out)
		end

		d.panels = {}
		local outer = d.radius + d.thick / 2
		for gore = 0, d.gores - 1 do
			local azimuth = (gore + 0.5) / d.gores * 2 * math.pi
			for row = 0, d.rows - 1 do
				local polar = d.crown + (row + 0.5) * d.rowAngle
				local length = 2 * outer * math.tan(d.rowAngle / 2) + 0.01
				local reach = outer * math.sin(polar) + length / 2 * math.cos(polar)
				local width = 2 * reach * math.tan(math.pi / d.gores) + 0.01
				table.insert(d.panels, {
					gore = gore,
					row = row,
					polar = polar,
					azimuth = azimuth,
					size = V(width, d.thick, length),
					frame = d.frame(polar, azimuth),
				})
			end
		end

		return d
	end

	return k
end

--------------------------------------------------------------------------------
-- Designs
--------------------------------------------------------------------------------

local DESIGNS = {}

-- The Rot Glider's six line seams on an 11-cell wing, and the two rows they hang from.
local LINE_SEAMS = { 2, 4, 5, 6, 7, 9 }
local LINE_ROWS = { -0.45, 0.4 }

-- Common ------------------------------------------------------------------------

-- A striped bedsheet pressed into service: sky and cream stripes, woven patches sewn on top and
-- underneath, a hem stitched along each patch, and the corners knotted at the tips.
DESIGNS.PatchworkChute = function(k)
	local body = k.harness()
	-- A deep sky blue against warm cream: the first pair (a pale blue and an off-white) washed out to
	-- much the same near-white in full sun, so the stripes didn't read from the ground.
	local SKY = rgb(78, 142, 198)
	local CREAM = rgb(238, 226, 194)
	local SEAM = rgb(196, 182, 152)
	local MUSTARD = rgb(230, 176, 52)
	local RUST = rgb(196, 84, 58)
	local DENIM = rgb(48, 78, 132)
	local MINT = rgb(108, 198, 142)
	local g = k.gap

	local w = k.wing()
	w.skin(function(cell)
		return cell.i % 2 == 1 and CREAM or SKY
	end, CLOTH)
	w.ribs(SEAM, 0.05, CLOTH)

	-- Warm patches on the blue stripes (the even cells) and dark ones on the cream, so every patch
	-- stands off the cloth it's sewn to.
	local patches = {
		{ 2, -0.55, 0.2, "top", MUSTARD },
		{ 4, 0.15, 0.85, "top", RUST },
		{ 6, -0.85, -0.15, "top", MUSTARD },
		{ 8, -0.2, 0.55, "top", MINT },
		{ 10, -0.7, 0.05, "top", RUST },
		{ 3, -0.4, 0.4, "bottom", DENIM },
		{ 5, 0.2, 0.9, "bottom", RUST },
		{ 7, -0.9, -0.2, "bottom", DENIM },
		{ 9, -0.1, 0.7, "bottom", MINT },
	}
	for _, patch in ipairs(patches) do
		local cell = w.list[patch[1]]
		local inset = 0.07
		local _, patchFront, patchBack = w.plate(cell, patch[2], patch[3], patch[4], patch[5], TEXTILE, inset, 1, "Patch")
		-- A hem stitched just inside its front and back edges (measured from where the patch really
		-- ends, staggered cells included), from the cell's skin to a gap proud of the patch, so it
		-- shares no face with either.
		local sign = patch[4] == "bottom" and -1 or 1
		local z0 = patchFront + 2 * g + 0.0175
		local z1 = patchBack - 2 * g - 0.0175
		for _, z in ipairs({ z0, z1 }) do
			k.block("Stitch", V(cell.width - 2 * inset - 0.1, 2 * g, 0.035), w.at(cell, 0, sign * (w.thick / 2 + g), z),
				patch[5]:Lerp(BLACK, 0.4), CLOTH)
		end
	end

	-- The sheet's corners, knotted at the back of each tip with a tail hanging down from the knot
	-- (past a tip, further along the arc is down).
	for _, s in ipairs({ 0, w.cells }) do
		local _, back = w.seamChord(s)
		local knot = w.onSeam(s, 0, back - 0.06)
		k.ball("Knot", 0.26, knot, CREAM, CLOTH)
		k.rod("KnotTail", knot.Position, (knot * CFrame.new(w.outward(s) * 0.34, -0.04, 0.2)).Position, 0.08, CREAM, CLOTH)
	end

	w.lines(LINE_SEAMS, LINE_ROWS)
	return body
end

-- Traffic-cone orange with two white reflective bands on both faces, black rubber stabilisers at
-- the tips, and a little cone riding on top.
DESIGNS.ConeChute = function(k)
	local body = k.harness(DARK, rgb(30, 30, 34))
	local ORANGE = rgb(255, 118, 26)
	local REFLECT = rgb(244, 244, 238)
	local RUBBER = rgb(34, 34, 38)
	local g = k.gap

	local w = k.wing()
	w.skin(ORANGE, PLASTIC)
	for _, cell in ipairs(w.list) do
		for _, band in ipairs({ { -0.52, -0.22 }, { 0.2, 0.5 } }) do
			w.plate(cell, band[1], band[2], "top", REFLECT, PLASTIC, nil, 1, "Band")
			w.plate(cell, band[1], band[2], "bottom", REFLECT, PLASTIC, nil, 1, "Band")
		end
	end
	-- Seams in a deeper orange, and slim black rubber stabilisers for tip caps.
	w.ribs(rgb(214, 92, 18), 0.05, PLASTIC, { tipColor = RUBBER, tipWidth = 0.12, tipHeight = 0.36, tipLift = -0.07 })

	-- The cone: a rubber base, orange, a reflective band, orange again and a rounded tip.
	local centre = w.list[math.ceil(w.cells / 2)]
	local surface = w.thick / 2
	-- Sunk two gaps, so its underside clears the reflective band's.
	k.block("ConeBase", V(0.5, 4 * g, 0.5), w.at(centre, 0, surface, 0.1), RUBBER, PLASTIC)
	local stack = {
		{ 0.36, 0.16, ORANGE },
		{ 0.28, 0.1, REFLECT },
		{ 0.2, 0.16, ORANGE },
	}
	local y = surface + 2 * g
	for _, layer in ipairs(stack) do
		k.disc("Cone", layer[2] + g, layer[1], w.at(centre, 0, y + layer[2] / 2 - g / 2, 0.1), layer[3], PLASTIC)
		y += layer[2]
	end
	k.ball("ConeTip", 0.14, w.at(centre, 0, y, 0.1), ORANGE, PLASTIC)

	w.lines(LINE_SEAMS, LINE_ROWS, rgb(198, 200, 206))
	return body
end

-- Red and white picnic gingham right through the cloth, with a folded napkin corner hanging from
-- each tip.
DESIGNS.GinghamChute = function(k)
	local body = k.harness()
	local RED = rgb(212, 40, 48)
	local PINK = rgb(240, 150, 152)
	local WHITE = rgb(250, 247, 240)

	local w = k.wing()
	w.bands({ -1, -0.5, 0, 0.5, 1 }, function(cell, band)
		local across, along = cell.i % 2 == 0, band % 2 == 0
		if across and along then
			return RED
		elseif across or along then
			return PINK
		end
		return WHITE
	end, CLOTH)
	w.ribs(WHITE, 0.05, CLOTH, { tipsOnly = true })

	-- A napkin corner hanging down past each tip, at the back.
	for _, s in ipairs({ 0, w.cells }) do
		-- Its back edge two gaps in front of the cloth's back edge, so their faces aren't level.
		local _, back = w.seamChord(s)
		back -= 2 * k.gap
		local frame = w.arc(w.seamAngle(s))
		k.triangle("Napkin", (frame * CFrame.new(0, 0, back - 0.55)).Position, (frame * CFrame.new(0, 0, back)).Position,
			(frame * CFrame.new(w.outward(s) * 0.55, 0, back)).Position, 0.06, RED, CLOTH)
	end

	w.lines(LINE_SEAMS, LINE_ROWS)
	return body
end

-- Uncommon ----------------------------------------------------------------------

-- A slice of watermelon: striped green rind underneath and round the leading edge, the pale pith
-- behind it, and pink flesh with seeds across the top.
DESIGNS.MelonChute = function(k)
	local body = k.harness()
	local RIND = rgb(52, 140, 58)
	local RIND_LIGHT = rgb(118, 190, 88)
	local PITH = rgb(222, 244, 196)
	local FLESH = rgb(246, 82, 104)
	local SEED = rgb(34, 24, 20)
	local g = k.gap

	local w = k.wing()
	w.skin(function(cell)
		return cell.i % 2 == 1 and RIND or RIND_LIGHT
	end, CLOTH)
	for _, cell in ipairs(w.list) do
		w.nose(cell, 0.28, RIND, CLOTH)
		w.plate(cell, -0.8, -0.62, "top", PITH, CLOTH, nil, 1, "Pith")
		w.plate(cell, -0.62, 1, "top", FLESH, CLOTH, nil, 1, "Flesh")
		local x = cell.i % 2 == 0 and 0.13 or -0.13
		for _, seed in ipairs({ { x, -0.1 }, { -x, 0.5 } }) do
			local z = cell.front + (seed[2] + 1) / 2 * cell.chord
			k.ball("Seed", 0.1, w.at(cell, seed[1], w.thick / 2 + g, z), SEED, PLASTIC)
		end
	end
	w.ribs(RIND, 0.05, CLOTH, { tipsOnly = true, tipHeight = 0.28 + 2 * g + 0.02 })

	w.lines(LINE_SEAMS, { -0.3, 0.45 })
	return body
end

-- Pizza: cheese across the top with pepperoni and basil, a sauce line behind a crust leading edge,
-- golden crust underneath, and cheese dripping off the back.
DESIGNS.PizzaChute = function(k)
	local body = k.harness()
	local CHEESE = rgb(252, 204, 84)
	local CRUST = rgb(196, 128, 60)
	local CRUST_UNDER = rgb(214, 156, 88)
	local SAUCE = rgb(196, 52, 36)
	local PEPPERONI = rgb(170, 38, 34)
	local BASIL = rgb(56, 140, 60)
	local g = k.gap

	local w = k.wing()
	w.skin(CHEESE, PLASTIC)
	for _, cell in ipairs(w.list) do
		w.nose(cell, 0.34, CRUST, SAND)
		w.plate(cell, -1, 1, "bottom", CRUST_UNDER, SAND, nil, 1, "Crust")
		w.plate(cell, -0.72, -0.56, "top", SAUCE, PLASTIC, nil, 1, "Sauce")
		local even = cell.i % 2 == 0
		local z = cell.front + ((even and -0.15 or 0.4) + 1) / 2 * cell.chord
		k.disc("Pepperoni", 3 * g, 0.34, w.at(cell, even and 0.06 or -0.06, w.thick / 2 + g / 2, z), PEPPERONI, PLASTIC)
	end

	-- Basil leaves on the middle cells, lying flat on the cheese.
	for _, i in ipairs({ 4, 6, 8 }) do
		local cell = w.list[i]
		local y = w.thick / 2 + g / 2
		local z = cell.front + 0.75 * cell.chord
		k.triangle("Basil", w.at(cell, -0.12, y, z).Position, w.at(cell, 0.12, y, z).Position, w.at(cell, 0.02, y, z + 0.24).Position,
			3 * g, BASIL, PLASTIC)
	end
	-- Cheese dripping off the back edge.
	for _, i in ipairs({ 3, 5, 7, 9 }) do
		local cell = w.list[i]
		k.ball("Drip", 0.2, w.at(cell, 0, -0.03, cell.back + 0.02), CHEESE, PLASTIC)
	end
	w.ribs(CRUST, 0.05, SAND, { tipsOnly = true, tipHeight = 0.34 + 2 * g + 0.02 })

	w.lines(LINE_SEAMS, { -0.3, 0.45 })
	return body
end

-- A rainbow along the arc, red at the leading edge to blue at the back, with a cloud at each end.
DESIGNS.RainbowChute = function(k)
	local body = k.harness()
	local COLORS = {
		rgb(236, 48, 48),
		rgb(250, 136, 34),
		rgb(252, 214, 48),
		rgb(92, 198, 70),
		rgb(50, 164, 228),
		rgb(70, 88, 210),
	}
	local CLOUD = rgb(252, 252, 255)

	local w = k.wing()
	w.bands({ -1, -2 / 3, -1 / 3, 0, 1 / 3, 2 / 3, 1 }, function(_, band)
		return COLORS[band]
	end, CLOTH)
	w.ribs(CLOUD, 0.05, PLASTIC, { tipsOnly = true })

	-- The clouds hang down past the tips (further along the arc), a core puff filling the middle of
	-- each so no light gets between them, and none reach out further than the wing's own width allows.
	for _, s in ipairs({ 0, w.cells }) do
		local out = w.outward(s)
		for _, puff in ipairs({
			{ 0.2, -0.12, 0.05, 0.62 },
			{ 0.22, -0.16, -0.45, 0.52 },
			{ 0.34, -0.2, 0.08, 0.56 },
			{ 0.2, -0.12, 0.55, 0.5 },
			{ 0.44, -0.3, -0.25, 0.4 },
		}) do
			k.ball("Cloud", puff[4], w.onSeam(s, puff[2], puff[3]) * CFrame.new(out * puff[1], 0, 0), CLOUD, PUFF)
		end
	end

	w.lines(LINE_SEAMS, LINE_ROWS, CLOUD)
	return body
end

-- Rare --------------------------------------------------------------------------

-- The classic round parachute: a dome in red and white rings, a vent cap on the crown, and lines
-- gathered from the hem to the harness.
DESIGNS.RoundChute = function(k)
	local body = k.harness()
	local RED = rgb(220, 44, 44)
	local WHITE = rgb(248, 246, 240)
	local g = k.gap

	local d = k.dome({ gores = 16, rows = 5 })
	for _, panel in ipairs(d.panels) do
		k.block("Gore", panel.size, panel.frame, panel.row % 2 == 0 and RED or WHITE, CLOTH)
	end

	-- The vent cap: over the crown's opening and down past the first row's inner face, a gap above
	-- the dome's top, with a red button on it.
	local capRadius = d.radius * math.sin(d.crown) + 0.14
	local top = d.centreY + d.radius + d.thick / 2 + g
	local bottom = d.centreY + (d.radius - d.thick / 2) * math.cos(math.asin(capRadius / d.radius)) - 0.03
	k.disc("VentCap", top - bottom, 2 * capRadius, CFrame.new(0, (top + bottom) / 2, 0), WHITE, CLOTH)
	k.disc("VentButton", 3 * g, 0.34, CFrame.new(0, top + g / 2, 0), RED, CLOTH)

	-- Rigging from every other gore seam at the hem, cascaded off a riser at each end of the bar.
	local anchors = {}
	for seam = 1, d.gores - 1, 2 do
		table.insert(anchors, d.frame(d.hem - 0.03, seam / d.gores * 2 * math.pi).Position)
	end
	k.rigging(anchors, LINE)
	return body
end

-- A shark: slate above with a dorsal fin, white belly, eyes on the leading edge, a toothy grin
-- underneath it, and tail fins hanging from the tips.
DESIGNS.SharkChute = function(k)
	local body = k.harness()
	local SLATE = rgb(74, 94, 118)
	local BELLY = rgb(238, 240, 242)
	local MOUTH = rgb(40, 44, 54)
	local TOOTH = rgb(252, 252, 248)
	local EYE = rgb(18, 20, 24)
	local g = k.gap

	local w = k.wing()
	w.skin(SLATE, PLASTIC)
	local nose = 0.3
	for _, cell in ipairs(w.list) do
		w.nose(cell, nose, SLATE, PLASTIC)
		w.plate(cell, -0.55, 1, "bottom", BELLY, PLASTIC, nil, 1, "Belly")
	end

	-- The grin: a dark band under the leading edge with a white tooth pointing back on each cell.
	for i = 3, 9 do
		local cell = w.list[i]
		local _, mouthFront, mouthBack = w.plate(cell, -0.92, -0.6, "bottom", MOUTH, PLASTIC, nil, 1, "Mouth")
		-- From the cell's skin to a gap past the band, so it shares no face with the band, and two gaps
		-- inside its front and back edges.
		local y = -(w.thick / 2 + g)
		local z0 = mouthFront + 2 * g
		local z1 = mouthBack - 2 * g
		k.triangle("Tooth", w.at(cell, -0.15, y, z0).Position, w.at(cell, 0.15, y, z0).Position, w.at(cell, 0, y, z1).Position, 2 * g, TOOTH, PLASTIC)
	end

	-- Eyes on the leading edge, each with a glint.
	for _, i in ipairs({ 4, 8 }) do
		local cell = w.list[i]
		local eye = w.at(cell, 0, 0.09, w.noseZ(cell, nose) - 0.11)
		k.ball("Eye", 0.13, eye, EYE, PLASTIC)
		k.ball("Glint", 0.045, eye * CFrame.new(0.03, 0.05, -0.04), TOOTH, PLASTIC)
	end

	-- The dorsal fin, standing up the middle, its back edge upright.
	local centre = w.list[math.ceil(w.cells / 2)]
	local base = w.thick / 2 - g
	k.triangle("Fin", w.at(centre, 0, base, -0.3).Position, w.at(centre, 0, base, 0.62).Position, w.at(centre, 0, w.thick / 2 + 0.9, 0.62).Position,
		0.1, SLATE, PLASTIC)

	w.ribs(SLATE, 0.05, PLASTIC, { tipsOnly = true, tipHeight = nose + 2 * g + 0.02 })
	-- Tail fins hanging down past the tips, upright at the back (two gaps in front of the cloth's back
	-- edge, so their faces aren't level).
	for _, s in ipairs({ 0, w.cells }) do
		local _, back = w.seamChord(s)
		back -= 2 * g
		local frame = w.arc(w.seamAngle(s))
		k.triangle("TailFin", (frame * CFrame.new(0, 0, back - 0.95)).Position, (frame * CFrame.new(0, 0, back)).Position,
			(frame * CFrame.new(w.outward(s) * 0.8, 0, back)).Position, 0.08, SLATE, PLASTIC)
	end

	w.lines(LINE_SEAMS, { -0.35, 0.45 })
	return body
end

-- A bomber's wing: olive drab over sky grey, roundels top and bottom, a riveted steel leading edge,
-- yellow tips and a twin tail.
DESIGNS.BomberChute = function(k)
	local body = k.harness()
	local OLIVE = rgb(104, 114, 62)
	local UNDER = rgb(150, 170, 182)
	local STEEL = rgb(150, 156, 162)
	local NAVY = rgb(34, 54, 120)
	local ROUNDEL_WHITE = rgb(244, 244, 238)
	local ROUNDEL_RED = rgb(204, 40, 40)
	local YELLOW = rgb(246, 196, 40)
	local g = k.gap

	local w = k.wing()
	w.skin(OLIVE, CLOTH)
	local nose = 0.26
	for _, cell in ipairs(w.list) do
		w.nose(cell, nose, STEEL, METAL)
		local tip = cell.i == 1 or cell.i == w.cells
		w.plate(cell, -1, 1, "bottom", tip and YELLOW or UNDER, CLOTH, nil, 1, "Underside")
		if tip then
			w.plate(cell, -0.72, 1, "top", YELLOW, CLOTH, nil, 1, "TipPaint")
		end
		k.ball("Rivet", 0.06, w.at(cell, 0, nose / 2, w.noseZ(cell, nose)), STEEL, METAL)
	end

	-- Roundels: blue, white and a red centre, each ring a gap prouder than the last and sunk as far
	-- again, so no two faces meet. Underneath they start a step further out, past the underside
	-- panel's faces.
	for _, i in ipairs({ 3, 9 }) do
		local cell = w.list[i]
		local z = cell.front + (0.15 + 1) / 2 * cell.chord
		for _, sign in ipairs({ 1, -1 }) do
			local first = sign == 1 and 0 or 1
			for layer, ring in ipairs({ { 0.5, NAVY }, { 0.34, ROUNDEL_WHITE }, { 0.16, ROUNDEL_RED } }) do
				k.disc("Roundel", 2 * (layer + first) * g, ring[1], w.at(cell, 0, sign * w.thick / 2, z), ring[2], CLOTH)
			end
		end
	end

	-- A twin tail either side of the middle, low and swept.
	for _, i in ipairs({ 5, 7 }) do
		local cell = w.list[i]
		local base = w.thick / 2 - g
		k.triangle("TailFin", w.at(cell, 0, base, cell.back - 0.6).Position, w.at(cell, 0, base, cell.back - 2 * g).Position,
			w.at(cell, 0, w.thick / 2 + 0.42, cell.back - 2 * g).Position, 0.08, OLIVE, CLOTH)
	end

	w.ribs(OLIVE, 0.05, CLOTH, { tipsOnly = true, tipHeight = nose + 2 * g + 0.02 })
	w.lines(LINE_SEAMS, { -0.35, 0.45 }, rgb(186, 190, 168))
	return body
end

-- Epic --------------------------------------------------------------------------

-- Cotton candy: a pink and blue wing lost in sugar puffs that spill over both edges and underneath.
DESIGNS.CandyChute = function(k)
	local body = k.harness(rgb(250, 246, 240), rgb(250, 246, 240))
	local PINK = rgb(255, 164, 212)
	local BLUE = rgb(160, 212, 255)
	local CREAM = rgb(255, 238, 248)

	local w = k.wing()
	w.skin(function(cell)
		return cell.i % 2 == 1 and PINK or BLUE
	end, CLOTH)
	for _, cell in ipairs(w.list) do
		local odd = cell.i % 2 == 1
		k.ball("Puff", 0.66, w.at(cell, 0, w.thick / 2 - 0.1, cell.front + 0.26), odd and BLUE or PINK, PUFF)
		k.ball("Puff", 0.6, w.at(cell, odd and 0.06 or -0.06, w.thick / 2 - 0.06, cell.back - 0.3), odd and CREAM or PINK, PUFF)
		-- Underneath, wide enough to overlap the next cell's all the way down its curve, so there's no
		-- chink between them from any angle.
		k.ball("Puff", 0.8, w.at(cell, 0, -w.thick / 2 - 0.02, cell.sweep + 0.05), odd and PINK or BLUE, PUFF)
	end
	w.ribs(PINK, 0.05, CLOTH, { tipsOnly = true })
	for _, s in ipairs({ 0, w.cells }) do
		k.ball("Puff", 0.7, w.onSeam(s, -0.12, 0.05) * CFrame.new(w.outward(s) * 0.2, 0, 0), CREAM, PUFF)
	end

	w.lines(LINE_SEAMS, LINE_ROWS, CREAM)
	return body
end

-- A dragon's wing: a crimson membrane drawn out to a point at every ivory finger bone and scalloped
-- between them, the bones ending in claws, a dark leading edge, spines down the middle and horns
-- curling off the tips.
DESIGNS.DragonChute = function(k)
	local body = k.harness(rgb(60, 20, 24), rgb(60, 20, 24))
	local MEMBRANE = rgb(168, 26, 36)
	local EDGE = rgb(110, 16, 26)
	local BONE = rgb(236, 226, 200)
	local CLAW = rgb(58, 46, 40)
	local g = k.gap

	-- Bones on the tip seams and these; the membrane reaches furthest back at a bone and least
	-- halfway between two.
	local FRONT = -0.85
	local BONE_SEAMS = { 0, 2, 5, 8, 11, 13 }
	local BONES = {}
	for _, s in ipairs(BONE_SEAMS) do
		BONES[s] = true
	end
	local POINT, BESIDE_TIP, SCALLOP = 0.95, 0.55, 0.42
	local w = k.wing({
		cells = 13,
		frontAt = function()
			return FRONT
		end,
		backAt = function(s)
			if BONES[s] then
				return POINT
			elseif s == 1 or s == 12 then
				return BESIDE_TIP
			end
			return SCALLOP
		end,
	})
	w.skin(MEMBRANE, CLOTH)
	w.edges(MEMBRANE, CLOTH)
	local nose = 0.24
	for _, cell in ipairs(w.list) do
		w.nose(cell, nose, EDGE, CLOTH)
	end
	w.ribs(EDGE, 0.05, CLOTH, { tipsOnly = true, tipHeight = nose + 2 * g + 0.02 })

	-- The bones along their seams, from inside the leading edge to past the point, ending in a claw.
	local surface = w.thick / 2
	-- In a fixed order (pairs has none), so two builds make their parts in the same order, which the
	-- probes' part-by-part comparisons rely on.
	for _, s in ipairs(BONE_SEAMS) do
		local finish = POINT + 0.36
		k.rod("Bone", w.onSeam(s, surface, FRONT + 0.06).Position, w.onSeam(s, surface, finish).Position, 0.1, BONE, PLASTIC)
		-- The claw's root runs back inside the bone's end, so it's held by it.
		k.triangle("Claw", w.onSeam(s, surface + 0.02, finish - 0.12).Position, w.onSeam(s, surface + 0.02, finish + 0.2).Position,
			w.onSeam(s, surface - 0.22, finish + 0.2).Position, 0.07, CLAW, PLASTIC)
	end

	-- Spines down the middle cell.
	local centre = w.list[math.ceil(w.cells / 2)]
	for _, z in ipairs({ -0.62, -0.3, 0.02 }) do
		k.triangle("Spine", w.at(centre, 0, surface - g, z).Position, w.at(centre, 0, surface - g, z + 0.26).Position,
			w.at(centre, 0, surface + 0.24, z + 0.26).Position, 0.07, EDGE, CLOTH)
	end

	-- A horn curling up and out of each tip's leading corner.
	for _, s in ipairs({ 0, w.cells }) do
		local out = w.outward(s)
		-- Mostly up rather than out, so the wing stays its width.
		local p0 = w.onSeam(s, 0.02, FRONT + 0.22).Position
		local p1 = p0 + V(out * 0.12, 0.3, -0.1)
		local p2 = p1 + V(out * 0.02, 0.28, 0.02)
		local p3 = p2 + V(-out * 0.1, 0.18, 0.1)
		k.rod("Horn", p0, p1, 0.16, BONE, PLASTIC)
		k.rod("Horn", p1, p2, 0.11, BONE, PLASTIC)
		k.rod("Horn", p2, p3, 0.06, BONE, PLASTIC)
	end

	w.lines({ 2, 4, 6, 7, 9, 11 }, { -0.4, 0.3 }, rgb(206, 184, 156))
	return body
end

-- Legendary ---------------------------------------------------------------------

-- Golden Sahur: gold over royal velvet, engraved foil trim, a ruby on every rib and a pair of crossed
-- bats on top.
DESIGNS.SahurChute = function(k)
	local body = k.harness(rgb(186, 122, 28), rgb(140, 28, 56))
	local GOLD = rgb(255, 200, 70)
	local GOLD_DEEP = rgb(236, 170, 44)
	local TRIM = rgb(196, 132, 32)
	local VELVET = rgb(140, 28, 56)
	local RUBY = rgb(214, 22, 56)
	local BAT = rgb(160, 106, 58)
	local g = k.gap

	local w = k.wing()
	w.skin(function(cell)
		return cell.i % 2 == 1 and GOLD or GOLD_DEEP
	end, CLOTH)
	local nose = 0.26
	for _, cell in ipairs(w.list) do
		w.nose(cell, nose, GOLD, FOIL)
		w.plate(cell, -1, 1, "bottom", VELVET, CLOTH, nil, 1, "Velvet")
		w.plate(cell, 0.62, 0.82, "top", TRIM, FOIL, nil, 1, "Trim")
	end
	local tipHeight = nose + 4 * g
	w.ribs(TRIM, 0.06, FOIL, { tipHeight = tipHeight })

	-- A ruby at the front of every rib, set into its top.
	for s = 0, w.cells do
		local front = w.seamChord(s)
		local tip = s == 0 or s == w.cells
		local y = tip and tipHeight / 2 or w.thick / 2 + g
		k.ball("Ruby", 0.12, w.onSeam(s, y, front + 0.34), RUBY, PLASTIC)
	end
	-- Gold finials on the tips.
	for _, s in ipairs({ 0, w.cells }) do
		k.ball("Finial", 0.24, w.onSeam(s, 0, 0.05) * CFrame.new(w.outward(s) * 0.08, 0, 0), GOLD, FOIL)
	end

	-- A gold coin underneath, in the middle of the velvet.
	local centre = w.list[math.ceil(w.cells / 2)]
	k.disc("Coin", 3 * g, 0.46, w.at(centre, 0, -w.thick / 2 - 1.5 * g, 0.1), GOLD, FOIL)

	-- Two bats crossed on top, one lying a little over the other.
	local crossing = V(0, w.top + 0.04, 0.05)
	for index, angle in ipairs({ math.rad(38), math.rad(-38) }) do
		local along = V(math.sin(angle), 0, math.cos(angle))
		local lift = V(0, (index - 1) * 0.04, 0)
		local function point(distance)
			return crossing + lift + along * distance
		end
		k.rod("Bat", point(-0.7), point(-0.14), 0.1, BAT, WOOD)
		k.rod("Bat", point(-0.14), point(0.66), 0.19, BAT, WOOD)
		k.ball("BatKnob", 0.15, point(-0.71), BAT, WOOD)
		k.rod("BatBand", point(-0.14 - 2 * g), point(-0.14 + 2 * g), 0.21, GOLD, FOIL)
	end

	w.lines(LINE_SEAMS, LINE_ROWS, rgb(230, 190, 90))
	return body
end

-- A phoenix: flame from deep red in the middle to gold at the tips, the back edge drawn out into
-- golden feather tips with a longer tail in the middle, a fan of tail feathers under it, plumes off
-- each tip, and flame tongues licking back across the top.
DESIGNS.PhoenixChute = function(k)
	local body = k.harness(rgb(120, 30, 14), rgb(120, 30, 14))
	local EMBER = rgb(190, 30, 20)
	local FLAME = rgb(250, 110, 24)
	local GOLD = rgb(255, 200, 60)
	local g = k.gap
	local function flame(t)
		local a = math.abs(t)
		if a < 0.55 then
			return EMBER:Lerp(FLAME, a / 0.55)
		end
		return FLAME:Lerp(GOLD, math.min(1, (a - 0.55) / 0.45))
	end

	-- Feather points every second seam out from the middle, where the two seams either side of the
	-- centre cell are both points, so the middle runs long like a tail.
	local POINTS = { [0] = true, [2] = true, [4] = true, [6] = true, [7] = true, [9] = true, [11] = true, [13] = true }
	local w = k.wing({
		cells = 13,
		frontAt = function()
			return -0.75
		end,
		backAt = function(s)
			return POINTS[s] and 1.08 or 0.7
		end,
	})
	w.skin(function(cell)
		return flame(cell.t)
	end, CLOTH)
	-- The feather tips shade to gold.
	w.edges(function(cell, edge)
		return edge == "back" and flame(cell.t):Lerp(GOLD, 0.55) or flame(cell.t)
	end, CLOTH)
	local nose = 0.24
	for _, cell in ipairs(w.list) do
		w.nose(cell, nose, GOLD, CLOTH)
	end

	-- A fan of three tail feathers hanging back from under the middle cell. Each is two gaps thick
	-- and a gap below the last, so they overlap one another (and the first the cloth) without any
	-- two faces level.
	local centreIndex = math.ceil(w.cells / 2)
	local centre = w.list[centreIndex]
	for index, feather in ipairs({ { -0.2, 0.75, FLAME }, { 0, 1.0, GOLD }, { 0.2, 0.75, EMBER } }) do
		local y = -w.thick / 2 - index * g
		-- Roots two gaps apart, so no two feathers' root edges lie level.
		local root = centre.back - 0.3 - (index - 1) * 2 * g
		k.triangle("TailFeather", w.at(centre, feather[1] - 0.2, y, root).Position, w.at(centre, feather[1] + 0.2, y, root).Position,
			w.at(centre, feather[1] * 1.8, y, centre.back + feather[2]).Position, 2 * g, feather[3], CLOTH)
	end

	-- Flame tongues across the middle of the top.
	for offset = -1, 1 do
		local cell = w.list[centreIndex + offset]
		local y = w.thick / 2 + g / 2
		local z0 = cell.front + 0.45
		k.triangle("Flame", w.at(cell, -0.2, y, z0).Position, w.at(cell, 0.2, y, z0).Position,
			w.at(cell, offset * 0.08, y, z0 + (offset == 0 and 0.9 or 0.68)).Position, 3 * g, offset == 0 and GOLD or FLAME, CLOTH)
	end

	w.ribs(GOLD, 0.05, CLOTH, { tipsOnly = true, tipHeight = nose + 4 * g })

	-- Three plumes fanning back and out from each tip, each in its own layer.
	for _, s in ipairs({ 0, w.cells }) do
		local out = w.outward(s)
		local frame = w.arc(w.seamAngle(s))
		for index, plume in ipairs({ { 25, 1.15, GOLD }, { 50, 1.35, FLAME }, { 75, 1.0, EMBER } }) do
			local angle = math.rad(plume[1])
			local along = V(out * math.sin(angle), 0, math.cos(angle))
			local across = V(math.cos(angle), 0, -out * math.sin(angle))
			-- Roots wide and close together, so the fan overlaps all the way out and leaves no chink
			-- between feathers.
			local root = V(0, (index - 2) * 2 * g, -0.2 + 0.24 * index)
			k.triangle("Plume", (frame * CFrame.new(root + across * 0.26)).Position, (frame * CFrame.new(root - across * 0.26)).Position,
				(frame * CFrame.new(root + along * plume[2])).Position, 2 * g, plume[3], CLOTH)
		end
	end

	w.lines({ 2, 4, 6, 7, 9, 11 }, { -0.35, 0.3 }, rgb(238, 200, 156))
	return body
end

-- Mythic ------------------------------------------------------------------------

-- A thundercloud: a dark wing in rolling grey cloud, with a lightning bolt zig-zagging along it on top
-- and underneath.
DESIGNS.StormChute = function(k)
	local body = k.harness(rgb(50, 52, 60), rgb(50, 52, 60))
	local SLATE = rgb(58, 62, 76)
	local UNDER = rgb(40, 43, 52)
	local CLOUD_DARK = rgb(118, 124, 140)
	local CLOUD_LIGHT = rgb(156, 162, 178)
	local BOLT = rgb(255, 214, 40)
	local g = k.gap

	local w = k.wing()
	w.skin(SLATE, CLOTH)
	for _, cell in ipairs(w.list) do
		local odd = cell.i % 2 == 1
		w.plate(cell, -1, 1, "bottom", UNDER, CLOTH, nil, 1, "Underside")
		k.ball("Cloud", odd and 0.86 or 0.76, w.at(cell, 0, w.thick / 2 - 0.2, cell.front + 0.18), odd and CLOUD_LIGHT or CLOUD_DARK, PUFF)
		k.ball("Cloud", odd and 0.74 or 0.84, w.at(cell, 0, w.thick / 2 - 0.2, cell.back - 0.2), odd and CLOUD_DARK or CLOUD_LIGHT, PUFF)
	end

	-- The bolt: one straight stroke per cell, each running seam to seam between two depths in turn,
	-- so they join into a zig-zag along the clear strip between the clouds. On top it sits on the
	-- cloth; underneath it runs from the cloth to a gap past the underside panel.
	for _, side in ipairs({ 1, -1 }) do
		local y = side == 1 and (w.thick / 2 + g / 2) or -(w.thick / 2 + g)
		local thickness = side == 1 and 3 * g or 2 * g
		for i = 2, w.cells - 1 do
			local cell = w.list[i]
			local near, far = cell.front + 0.66, cell.front + 0.96
			local fromZ, toZ = near, far
			if i % 2 == 1 then
				fromZ, toZ = far, near
			end
			local a = w.at(cell, -cell.width / 2, y, fromZ).Position
			local b = w.at(cell, cell.width / 2, y, toZ).Position
			local frame = CFrame.lookAt((a + b) / 2, b, w.at(cell, 0, 0, 0).UpVector)
			k.block("Bolt", V(0.13, thickness, (b - a).Magnitude + 0.06), frame, BOLT, PLASTIC)
		end
	end

	w.ribs(SLATE, 0.05, CLOTH, { tipsOnly = true })
	for _, s in ipairs({ 0, w.cells }) do
		k.ball("Cloud", 0.84, w.onSeam(s, -0.2, 0) * CFrame.new(w.outward(s) * 0.3, 0, 0), CLOUD_DARK, PUFF)
	end

	w.lines(LINE_SEAMS, { -0.3, 0.45 }, rgb(178, 184, 196))
	return body
end

-- Secret ------------------------------------------------------------------------

-- A galaxy manta: a swept ray's wing in deep space blue, stars above and below, sparkles and a ringed
-- planet on top, curled head fins and a long tail.
DESIGNS.MantaChute = function(k)
	local body = k.harness(rgb(20, 26, 62), rgb(20, 26, 62))
	local NAVY = rgb(24, 32, 78)
	local STAR = rgb(255, 250, 236)
	local PLANET = rgb(232, 146, 82)
	local RING = rgb(238, 216, 172)
	local EYE = rgb(214, 224, 240)
	local g = k.gap

	-- The outline, seam by seam: the leading edge swept back towards the tips, the chord deepest in
	-- the middle, so the tips trail behind like a ray's.
	local function chord(t)
		return 0.4 + 1.9 * (1 - math.min(1, math.abs(t)) ^ 1.6)
	end
	local function front(t)
		return -1.15 + 1.25 * math.min(1, math.abs(t)) ^ 1.5
	end
	local w = k.wing({
		cells = 15,
		thick = 0.14,
		frontAt = function(_, t)
			return front(t)
		end,
		backAt = function(_, t)
			return front(t) + chord(t)
		end,
	})
	w.skin(NAVY, PLASTIC)
	w.edges(NAVY, PLASTIC)

	-- Star specks above and below, half sunk into the skin.
	local specks = {
		{ 2, 0.1, 0, 1 }, { 3, -0.12, 0.3, 1 }, { 4, 0.08, 0.7, 1 }, { 6, -0.1, -0.4, 1 }, { 7, 0.12, 0.35, 1 }, { 8, 0, -0.6, 1 },
		{ 9, -0.06, 0.55, 1 }, { 10, 0.1, -0.2, 1 }, { 12, -0.08, 0.2, 1 }, { 13, 0.06, -0.3, 1 },
		{ 3, 0.1, -0.2, -1 }, { 5, -0.1, 0.4, -1 }, { 6, 0.08, -0.5, -1 }, { 8, -0.12, 0.2, -1 }, { 9, 0.1, -0.35, -1 },
		{ 11, -0.06, 0.45, -1 }, { 12, 0.08, -0.1, -1 }, { 7, 0, 0.7, -1 },
	}
	for index, speck in ipairs(specks) do
		local cell = w.list[speck[1]]
		local z = cell.front + (speck[3] + 1) / 2 * cell.chord
		k.ball("Star", index % 3 == 0 and 0.09 or 0.06, w.at(cell, speck[2], speck[4] * w.thick / 2, z), STAR, PLASTIC)
	end
	-- Four-point sparkles: crossed bars, the second a gap prouder than the first.
	for _, spec in ipairs({ { 4, 0.1 }, { 11, 0.25 } }) do
		local cell = w.list[spec[1]]
		local z = cell.front + (spec[2] + 1) / 2 * cell.chord
		k.block("Sparkle", V(0.3, 3 * g, 0.05), w.at(cell, 0, w.thick / 2 + g / 2, z), STAR, PLASTIC)
		k.block("Sparkle", V(0.05, 4 * g, 0.3), w.at(cell, 0, w.thick / 2 + 2 * g, z), STAR, PLASTIC)
	end

	-- A ringed planet.
	local planetCell = w.list[10]
	local planet = w.at(planetCell, 0, w.thick / 2 + 0.06, planetCell.front + 0.55 * planetCell.chord)
	k.ball("Planet", 0.34, planet, PLANET, PLASTIC)
	k.disc("PlanetRing", 0.03, 0.64, planet * CFrame.Angles(0.3, 0, 0.25), RING, PLASTIC)

	-- Head fins curling down off the leading edge either side of the middle, with pale eyes.
	local centreIndex = math.ceil(w.cells / 2)
	for _, offset in ipairs({ -1, 1 }) do
		local cell = w.list[centreIndex + offset]
		local p0 = w.at(cell, 0, 0, cell.front + 0.08).Position
		local p1 = p0 + V(offset * 0.06, -0.06, -0.32)
		local p2 = p1 + V(-offset * 0.03, -0.16, -0.14)
		local p3 = p2 + V(-offset * 0.05, -0.12, 0.06)
		k.rod("HeadFin", p0, p1, 0.13, NAVY, PLASTIC)
		k.ball("HeadFinJoint", 0.13, p1, NAVY, PLASTIC)
		k.rod("HeadFin", p1, p2, 0.1, NAVY, PLASTIC)
		k.ball("HeadFinJoint", 0.1, p2, NAVY, PLASTIC)
		k.rod("HeadFin", p2, p3, 0.07, NAVY, PLASTIC)
		k.ball("Eye", 0.08, p0 + V(offset * 0.12, 0.05, 0.05), EYE, PLASTIC)
	end

	-- The tail, from under the back of the middle cell.
	local centre = w.list[centreIndex]
	local t0 = w.at(centre, 0, 0, centre.back - 0.1).Position
	local t1 = t0 + V(0, -0.12, 0.7)
	local t2 = t1 + V(0, -0.04, 0.55)
	local t3 = t2 + V(0, 0.06, 0.4)
	k.rod("Tail", t0, t1, 0.09, NAVY, PLASTIC)
	k.ball("TailJoint", 0.09, t1, NAVY, PLASTIC)
	k.rod("Tail", t1, t2, 0.06, NAVY, PLASTIC)
	k.ball("TailJoint", 0.06, t2, NAVY, PLASTIC)
	k.rod("Tail", t2, t3, 0.035, NAVY, PLASTIC)

	w.ribs(NAVY, 0.05, PLASTIC, { tipsOnly = true })
	w.lines({ 3, 5, 7, 8, 10, 12 }, { -0.3, 0.3 }, rgb(170, 186, 214))
	return body
end

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

-- Every design, cheapest rarity first.
ParachuteModels.Order = {
	"PatchworkChute", "ConeChute", "GinghamChute",
	"MelonChute", "PizzaChute", "RainbowChute",
	"RoundChute", "SharkChute", "BomberChute",
	"CandyChute", "DragonChute",
	"SahurChute", "PhoenixChute",
	"StormChute",
	"MantaChute",
}

function ParachuteModels.Has(id)
	return id ~= nil and DESIGNS[id] ~= nil
end

-- options: scale (default 1), anchored (default true), name (default "Parachute").
--
-- Below the worn scale a canopy is built at the worn scale and then shrunk whole (Model:ScaleTo), so
-- it is exactly the canopy players wear, only smaller: the gaps that keep faces apart are set in
-- world studs for the worn size, and building small directly would make stacked details (roundels,
-- a cone's base) thicker than the cloth they sit in. Shrunk, those gaps are far finer than anything
-- a close-up camera can make flicker.
--
-- A design is built once per set of options and cloned after that. MovementService builds a canopy
-- on every drop-in and Rot Glider, and a clone skips the maths and the z-fight pass (about a tenth
-- of the time). Probes that need a fresh build switch CacheBuilds off; so does switching ZFight off.
ParachuteModels.CacheBuilds = true
local templates = {}

-- The default Rot Glider canopy, guarded: a canopy is what caps a player's fall on the drop-in, so
-- nothing here may throw. A build that fails returns nil and says why.
local function defaultCanopy(options)
	local ok, model, body = pcall(ItemModels.Build, "RotGlider", {
		scale = options.scale,
		anchored = options.anchored,
		name = options.name or "Parachute",
		open = true,
	})
	if ok and model then
		return model, body
	end
	warn("[ParachuteModels] the default Rot Glider canopy failed to build: " .. tostring(model))
	return nil
end

function ParachuteModels.Build(id, options)
	options = options or {}
	local design = id and DESIGNS[id]
	if not design then
		return defaultCanopy(options)
	end

	local scale = options.scale or 1
	local anchored = options.anchored ~= false
	local buildScale = math.max(scale, ParachuteModels.WornScale)

	local caching = ParachuteModels.CacheBuilds and ZFight.Enabled
	local key = string.format("%s|%s|%s|%s", id, tostring(scale), tostring(anchored), options.name or "Parachute")
	if caching and templates[key] then
		local copy = templates[key]:Clone()
		return copy, copy.PrimaryPart
	end

	local model = Instance.new("Model")
	model.Name = options.name or "Parachute"
	model:SetAttribute("ParachuteId", id)

	-- A design that fails takes the default canopy instead, rather than leaving a player to fall with
	-- nothing over their head: MovementService only caps the fall once a canopy is up.
	local kit = newKit(model, buildScale, anchored)
	local built, body = pcall(design, kit)
	if not built or not body then
		warn(string.format("[ParachuteModels] %s failed to build (%s); using the default canopy", tostring(id), tostring(body)))
		model:Destroy()
		return defaultCanopy(options)
	end

	-- No two faces left flush, before the welds so only the one part moves. What it had to touch, and
	-- the wings and domes the design laid out (in design units, at `buildScale`), are kept for
	-- tools/parachute_probe.lua.
	ParachuteModels.LastFix = ZFight.Fix({ model }, { all = true })
	ParachuteModels.LastLayout = { wings = kit.layout.wings, domes = kit.layout.domes, scale = buildScale }

	model.PrimaryPart = body
	body.PivotOffset = body.CFrame:Inverse()
	if buildScale ~= scale then
		model:ScaleTo(scale / buildScale)
	end

	if not anchored then
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") and part ~= body then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = body
				weld.Part1 = part
				weld.Parent = part
			end
		end
	end

	if caching then
		templates[key] = model:Clone()
	end
	return model, body
end

-- Points a camera at a canopy built by Build: from in front, a little above and to one side,
-- close enough that the canopy fills the view.
function ParachuteModels.FrameCamera(camera, model)
	local box, size = model:GetBoundingBox()
	local radius = size.Magnitude / 2
	local direction = box:VectorToWorldSpace(V(0.5, 0.45, -1).Unit)
	local distance = radius / math.tan(math.rad(camera.FieldOfView / 2)) * 0.95
	camera.CFrame = CFrame.lookAt(box.Position + direction * distance, box.Position)
end

return ParachuteModels
