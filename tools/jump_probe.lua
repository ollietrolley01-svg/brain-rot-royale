-- Jump reach probe: how far a real humanoid actually gets, for designing jumps that are hard but
-- possible. Run with:
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/jump_probe.lua -OutDir <folder> -TimeoutSeconds 400
--
-- Switches the gallery copy into Run mode (physics on), builds pairs of blocks far from the lobby
-- and has an R15 rig with the player's own jump settings run off one and try to land on the next.
-- Each lane binary-searches the widest gap it can still clear for one (speed, rise); the widest
-- clear is edge to edge, so it already includes however far past an edge a body can stand.
-- The rig jumps as late as it can and steers in the air, so these are the ceilings a perfect
-- player gets — design jumps some way inside them.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local ORIGIN = Vector3.new(3000, 1500, 3000)
local SPEEDS = { 18, 18 * 1.45 }
local RISES = { -6, -3, 0, 1.5, 3, 4, 5, 6 }

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function block(folder, size, cframe, color)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.Parent = folder
	return part
end

return {
	{
		name = "jump_probe",
		settle = 1,
		hold = 1,
		setup = function(folder, camera)
			if not RunService:IsRunning() then
				RunService:Run()
			end
			task.wait(4)
			note(string.format("gravity %.1f useJumpPower %s jumpPower %.2f jumpHeight %.2f maxSlope %.1f",
				workspace.Gravity, tostring(StarterPlayer.CharacterUseJumpPower), StarterPlayer.CharacterJumpPower,
				StarterPlayer.CharacterJumpHeight, StarterPlayer.CharacterMaxSlopeAngle))

			local template
			for attempt = 1, 3 do
				local ok, model = pcall(function()
					return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
				end)
				if ok and model then
					template = model
					break
				end
				note("rig attempt " .. attempt .. " failed: " .. tostring(model))
				task.wait(2)
			end
			if not template then
				note("no rig, giving up")
				return
			end
			local templateHumanoid = template:FindFirstChildOfClass("Humanoid")
			note(string.format("rig hipHeight %.2f root %s", templateHumanoid.HipHeight, tostring(template.HumanoidRootPart.Size)))

			-- One trial: returns whether the rig landed on the far block.
			local function trial(lane, speed, rise, gap)
				local laneFolder = Instance.new("Folder")
				laneFolder.Parent = folder
				local base = ORIGIN + Vector3.new(0, 0, lane * 30)
				block(laneFolder, Vector3.new(40, 4, 10), CFrame.new(base + Vector3.new(-20, -2, 0)), Color3.fromRGB(120, 120, 130))
				local far = block(laneFolder, Vector3.new(30, 4, 10), CFrame.new(base + Vector3.new(gap + 15, rise - 2, 0)), Color3.fromRGB(90, 170, 90))
				local rig = template:Clone()
				local humanoid = rig:FindFirstChildOfClass("Humanoid")
				humanoid.UseJumpPower = StarterPlayer.CharacterUseJumpPower
				humanoid.JumpPower = StarterPlayer.CharacterJumpPower
				humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
				humanoid.WalkSpeed = speed
				rig:PivotTo(CFrame.lookAt(base + Vector3.new(-14, 3.2, 0), base + Vector3.new(0, 3.2, 0)))
				rig.Parent = laneFolder
				local root = rig.HumanoidRootPart
				-- The ray down from the root would otherwise stop on the rig's own legs.
				local rayParams = RaycastParams.new()
				rayParams.FilterType = Enum.RaycastFilterType.Exclude
				rayParams.FilterDescendantsInstances = { rig }
				task.wait(0.8)

				local jumped, airborne, done, landed = false, false, false, false
				local touchdown = nil
				local started = os.clock()
				local connection
				connection = RunService.Heartbeat:Connect(function()
					if done then
						return
					end
					humanoid:Move(Vector3.new(1, 0, 0), false)
					local x = root.Position.X - base.X
					if not jumped and x >= -0.35 then
						jumped = true
						humanoid.Jump = true
					end
					local state = humanoid:GetState()
					if jumped and (state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping) then
						airborne = true
					end
					if airborne and not touchdown and (state == Enum.HumanoidStateType.Landed or state == Enum.HumanoidStateType.Running) then
						touchdown = os.clock()
					end
					if touchdown and os.clock() - touchdown > 0.5 then
						-- Still up on the far block half a second later: standing on it, even if only
						-- by the edge of the body where a ray from the root would miss.
						done = true
						local floor = workspace:Raycast(root.Position, Vector3.new(0, -8, 0), rayParams)
						landed = root.Position.Y > base.Y + rise + 1 and (floor == nil or floor.Instance == far)
					elseif root.Position.Y < base.Y - 12 or os.clock() - started > 5 then
						done = true
					end
				end)
				while not done do
					task.wait()
				end
				connection:Disconnect()
				local info = string.format("jumped %s airborne %s touchdown %s end x %.1f y %.1f state %s",
					tostring(jumped), tostring(airborne), tostring(touchdown ~= nil), root.Position.X - base.X, root.Position.Y - base.Y,
					humanoid:GetState().Name)
				laneFolder:Destroy()
				return landed, info
			end

			local results = {}
			local running = 0
			local lane = 0
			for _, speed in ipairs(SPEEDS) do
				for _, rise in ipairs(RISES) do
					lane += 1
					local myLane = lane
					running += 1
					task.spawn(function()
						local lo, hi = 1, 20
						local ok, info = trial(myLane, speed, rise, lo)
						if not ok then
							results[myLane] = string.format("speed %.1f rise %+.1f: cannot clear even %.1f (%s)", speed, rise, lo, info)
						else
							for _ = 1, 8 do
								local mid = (lo + hi) / 2
								if trial(myLane, speed, rise, mid) then
									lo = mid
								else
									hi = mid
								end
							end
							results[myLane] = string.format("speed %.1f rise %+.1f: widest gap %.2f", speed, rise, lo)
						end
						running -= 1
					end)
				end
			end
			-- The highest step up a jump reaches, with the ledge right in front.
			for _, speed in ipairs({ 18 }) do
				lane += 1
				local myLane = lane
				running += 1
				task.spawn(function()
					local lo, hi = 2, 12
					for _ = 1, 8 do
						local mid = (lo + hi) / 2
						if trial(myLane, speed, mid, 1.2) then
							lo = mid
						else
							hi = mid
						end
					end
					results[myLane] = string.format("speed %.1f gap 1.2: highest rise %.2f", speed, lo)
					running -= 1
				end)
			end
			while running > 0 do
				task.wait(0.5)
			end
			for index = 1, lane do
				note(string.format("%02d %s", index, tostring(results[index])))
			end
			camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(-30, 30, -40), ORIGIN)
		end,
	},
}
