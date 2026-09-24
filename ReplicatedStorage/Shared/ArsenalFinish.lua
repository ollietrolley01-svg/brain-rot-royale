-- Individual finishes and stamped badges for the expansion's mechanical builds.
-- No changes to sights, muzzle positions, action travel or hand keypoints.
local Finish = {}
local C = Color3.fromRGB
local looks = {
	PawnshopNine = { C(112, 117, 125), C(53, 49, 43), C(188, 153, 90), "PISTACCHIO", "USED / TESTED", "bars" },
	RustbeltMarshal = { C(76, 80, 86), C(119, 72, 45), C(184, 145, 91), "SCERIFFO", "SGRUNF x6", "star" },
	NightShiftPump = { C(51, 57, 64), C(48, 60, 64), C(214, 170, 70), "CIABATTA", "SECURITY / 03", "bars" },
	DoomscrollSMG = { C(40, 49, 68), C(42, 53, 78), C(120, 180, 200), "SCROLLA SCROLLA", "ONE MORE MAG", "signal" },
	TrailheadCarbine = { C(66, 73, 69), C(100, 112, 79), C(219, 199, 147), "SCARPONCINO", "TROTTO / 25", "mountain" },
	TouchGrassScout = { C(55, 67, 63), C(80, 106, 64), C(179, 207, 133), "PRATO PRATO", "OUTSIDE / 14", "grass" },
	DeadAirPrecision = { C(76, 89, 103), C(101, 114, 124), C(200, 217, 222), "SILENZIO", "NO SIGNAL", "signal" },
	RatioPDW = { C(49, 44, 56), C(114, 54, 82), C(235, 155, 182), "L + RATIO", "REPLY / 36", "bars" },
	BackroomsBreacher = { C(70, 67, 52), C(168, 153, 78), C(240, 223, 139), "PORTA PORTA", "EXIT  >>>", "exit" },
	ReceiptPrinterLMG = { C(57, 61, 64), C(205, 197, 168), C(229, 204, 138), "SCONTRINO", "ITEM: 70\nTOTAL: GG", "receipt" },
	SundaySpecial = { C(93, 79, 63), C(92, 48, 35), C(200, 161, 86), "PRANZO / NONNA", "FAMILY RESERVE", "star" },
	AuraAuditRifle = { C(141, 149, 156), C(215, 213, 198), C(209, 105, 144), "OCCHIETTO", "APPROVED +1", "bars" },
	QuietHours = { C(48, 50, 61), C(66, 51, 75), C(175, 184, 224), "NANNA NANNA", "DO NOT DISTURB", "moon" },
	AdminOverride = { C(31, 38, 40), C(38, 54, 51), C(126, 216, 191), "CAPO SUPREMO", "AUTH / LOCAL", "terminal" },
	FinalNotice = { C(54, 54, 59), C(107, 49, 49), C(205, 169, 99), "ULTIMO BUM", "PAST DUE / GG", "receipt" },
}

-- Print into the host face, so labels cannot obstruct a sight and remain attached to
-- the magazine/slide during every animation. Never use AlwaysOnTop on weapon markings.
--
-- Oliver's #72, "some guns have random floating texts on their texture in fps". Measured across all
-- 62 guns: 50 stamps, and the hosts were far too small to carry them. "CAPO SUPREMO" was printed onto
-- an AdminOverride slide face **0.019 studs wide** -- nineteen thousandths of a stud -- and a magazine
-- stamp covered 0.29 studs of a 0.365-stud face, i.e. four fifths of the magazine was lettering. Every
-- one was drawn from up to 80 studs away. A word squeezed onto a face that size, still being rendered
-- across a street, is not a marking; it is the floating text he is describing.
--
-- Two rules now, and both are in STUDS, because a fraction of "whatever face this happens to be" is
-- what produced the bug:
--   * a host whose printable face is smaller than MIN_FACE simply does not get a stamp;
--   * the lettering is at most MAX_INK studs tall whatever the face is, so it reads as a stencil on
--     the metal rather than as a banner stretched over the part.
-- MaxDistance drops to 10: a serial number is something you read with the gun in your hands.
local MIN_FACE = 0.09
local MAX_INK = 0.035

-- The two dimensions of `host`'s left face, in studs: along the barrel (Z) and up the side (Y).
local function leftFace(host)
	return host.Size.Z, host.Size.Y
end

local function stamp(host, text, ink, motif)
	local along, up = leftFace(host)
	if math.min(along, up) < MIN_FACE then
		return false
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "ArsenalStamp"
	gui.Face = Enum.NormalId.Left
	gui.CanvasSize = Vector2.new(640, 160)
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.AlwaysOnTop = false
	gui.LightInfluence = 1
	gui.MaxDistance = 10
	gui.Parent = host
	-- The canvas is 160 tall and maps onto `up` studs of gun, so this is MAX_INK studs of lettering.
	local inkScale = math.min(0.8, MAX_INK / math.max(up, 1e-3))
	local word = Instance.new("TextLabel")
	word.BackgroundTransparency = 1
	word.Position = UDim2.fromScale(0.22, (1 - inkScale) / 2)
	word.Size = UDim2.fromScale(0.74, inkScale)
	word.Text = text
	word.TextColor3 = ink
	word.TextScaled = true
	word.Font = Enum.Font.RobotoMono
	word.Parent = gui
	local glyph = Instance.new("TextLabel")
	glyph.BackgroundTransparency = 1
	glyph.Position = UDim2.fromScale(0.02, (1 - inkScale) / 2)
	glyph.Size = UDim2.fromScale(0.18, inkScale)
	local symbols = { bars = "///", star = "*", signal = ")))", mountain = "/\\", grass = "\\|/", exit = ">>", receipt = "$", moon = ")", terminal = ">_" }
	glyph.Text = symbols[motif] or "///"
	glyph.TextColor3 = ink
	glyph.TextScaled = true
	glyph.Font = Enum.Font.RobotoMono
	glyph.Parent = gui
	return true
end

function Finish.Apply(model, id, skinned)
	local look = looks[id]
	-- A signature rebuild (GunModelsSignature) has its own colours and markings, and none of the parts this
	-- recolours by name are where the stock build put them.
	if not look or model:GetAttribute("Signature") then return end
	model:SetAttribute("ArsenalPack", "AfterHours15")
	-- The legacy lever builder supplies a loading gate but no ejection keypoint.
	-- Its firing clip emits an eject event, so give this gun a real outlet there.
	if id == "SundaySpecial" then
		local gate = model:GetAttribute("KP_Load")
		model:SetAttribute("KP_Eject", CFrame.new(gate.Position) * CFrame.Angles(0, -math.pi / 2, 0))
	end
	local action = model:GetAttribute("Action")
	-- A revolver is one steel all over. Every metal part still in the frame's own finish takes the body
	-- colour (the darker flutes follow it), and only the wood is furniture; recolouring the frame alone
	-- left a bright barrel, cylinder, crane and hammer on a dark frame.
	local steel
	if action == "revolver" then
		local frame = model:FindFirstChild("Frame")
		steel = frame and frame.Color
	end
	local function sameColour(a, b)
		return math.abs(a.R - b.R) < 0.002 and math.abs(a.G - b.G) < 0.002 and math.abs(a.B - b.B) < 0.002
	end
	local badgeHost, magazine
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			local name = part.Name
			local body, furniture
			if action == "pistol" then
				-- A polymer pistol is two-tone, slide over frame: the frame, its grip, trigger guard, beavertail
				-- and the magazine's grip-shaped extension are one moulding, so they take one colour (a grip in
				-- one colour on a frame in another read as a sleeve that didn't sit flush).
				body = string.match(name, "^Slide") and not string.match(name, "^SlideStop")
				furniture = (string.match(name, "^Frame") and name ~= "FramePin") or string.match(name, "^Grip")
					or string.match(name, "^TriggerGuard") or string.match(name, "^Beavertail") or string.match(name, "^MagazineExtension")
			elseif steel then
				body = part.Material == Enum.Material.Metal and sameColour(part.Color, steel)
				furniture = string.match(name, "^Grip") and part.Material == Enum.Material.Wood
			else
				body = string.match(name, "^Receiver") or string.match(name, "^UpperWall") or string.match(name, "^Slide") or name == "Frame" or name == "TopStrap"
				furniture = string.match(name, "^Stock") or string.match(name, "^Handguard") or string.match(name, "^Grip") or string.match(name, "^Forend") or string.match(name, "^Pump") or name == "Magazine"
			end
			if not skinned and part.Transparency == 0 then
				if body then part.Color = look[1]
				elseif furniture then part.Color = look[2]
				elseif steel and name == "DrumFlute" then part.Color = look[1]:Lerp(Color3.new(0, 0, 0), 0.32) end
			end
			-- Rectangular hosts only; a cylinder's local X is its bore, not its left face.
			-- The BIGGEST candidate wins, not the first one found: several guns carry more than one part
			-- called Slide or Frame, and picking whichever came first landed a whole word on a
			-- nineteen-thousandths-of-a-stud sliver (#72). Compared by printable face area.
			if part:IsA("Part") and part.Shape == Enum.PartType.Block then
				local function bigger(a, b)
					return b == nil or (a.Size.Z * a.Size.Y) > (b.Size.Z * b.Size.Y)
				end
				if (name == "Receiver" or name == "Slide" or name == "Frame") and bigger(part, badgeHost) then
					badgeHost = part
				end
				if name == "Magazine" and bigger(part, magazine) then
					magazine = part
				end
			end
		end
	end
	if badgeHost then stamp(badgeHost, look[4], look[3], look[6]) end
	if magazine then stamp(magazine, look[5], look[3], look[6]) end
	-- A bonded identification plate below the receiver's left face. It is thin,
	-- physically attached, and copies the host's moving group (not a floating charm).
	if badgeHost then
		local plate = Instance.new("Part")
		plate.Name = "ArsenalSerialPlate"
		plate.Size = Vector3.new(0.009, math.min(0.028, badgeHost.Size.Y * 0.2), math.min(0.12, badgeHost.Size.Z * 0.25))
		plate.CFrame = badgeHost.CFrame * CFrame.new(-badgeHost.Size.X / 2 - 0.003, -badgeHost.Size.Y * 0.27, badgeHost.Size.Z * 0.3)
		plate.Color = look[3]
		plate.Material = Enum.Material.Metal
		plate.CanCollide = false
		plate.CanTouch = false
		plate.CanQuery = false
		plate.Massless = true
		plate:SetAttribute("Anim", badgeHost:GetAttribute("Anim"))
		plate.Parent = model
	end
end

return Finish
