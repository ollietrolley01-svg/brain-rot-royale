-- Probe for tools/runtest.ps1 -Probe: rebuilds what the lobby's arena does with a Legendary gun
-- (build, pivot onto a display, anchor) and scans it, to chase any flush faces left there.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZFight = require(Shared:WaitForChild("ZFight"))
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local WeaponService = require(modules:WaitForChild("WeaponService"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))

for _, def in pairs(WeaponData.Weapons) do
	if def.rarity == "Legendary" then
		local display = Instance.new("Part")
		display.Name = "Display"
		display.Size = Vector3.new(1, 1, 1)
		display.Transparency = 1
		display.Anchored = true
		display.CanCollide = false
		display.CFrame = CFrame.new(76, 512.4, 18)
		local model, receiver = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal)
		local atOrigin = ZFight.Scan({ model })
		model:PivotTo(display.CFrame * CFrame.Angles(0, math.pi / 2, math.rad(-12)))
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("WeldConstraint") then
				descendant:Destroy()
			end
		end
		for _, piece in ipairs(model:GetChildren()) do
			if piece:IsA("BasePart") then
				piece.Anchored = true
				piece.CanQuery = false
				piece.Parent = display
			end
		end
		model:Destroy()
		display.Parent = workspace
		local placed = ZFight.Scan({ display })
		print(string.format("[PROBE] %s: flush at origin %d, on the display %d", def.id, #atOrigin, #placed))
		for _, line in ipairs(ZFight.Describe(placed, function() return def.id end, 10)) do
			print("[PROBE]   " .. line)
		end
		for _, pair in ipairs(placed) do
			print(string.format("[PROBE]   %s size %s pos %s | %s size %s pos %s", pair.a.Name, tostring(pair.a.Size), tostring(pair.a.Position),
				pair.b.Name, tostring(pair.b.Size), tostring(pair.b.Position)))
		end
		display:Destroy()
	end
end
