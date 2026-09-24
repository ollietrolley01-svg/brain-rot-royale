# Visual gallery for Brain Rot Royale.
#
# Guns, viewmodel poses and effects are all built from parts at runtime, so Studio's edit mode
# never shows them and nothing in the text-only checks can say whether a model *looks* right.
# This makes them visible:
#
#   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/gun_gallery.lua -OutDir <folder>
#
# It never touches a Studio you already have open. It copies the place to BRR_Gallery.rbxlx next to
# the output, opens THAT in its own Studio window, and closes only that window at the end. A local
# plugin is loaded by every open Studio, so the temporary plugin checks the place's name and does
# nothing anywhere but the gallery copy -- otherwise it would build guns in your workspace and take
# over your camera while you play.
#
# The gallery file returns a list of views, `{ name = "...", setup = function(folder, camera) ... end }`;
# each builds its scene into `folder` and points the edit camera at it. As each view is ready the
# plugin prints a marker, which reaches Studio's log file within a moment; this script tails the
# log, captures the gallery window with PrintWindow (so it works even when covered) and crops it to
# the 3D viewport. Lines the gallery prints as "[BRR_Gallery] note ..." are echoed too, so a
# gallery can double as a measurement run (see tools/jump_probe.lua).
param(
	[Parameter(Mandatory = $true)][string]$Gallery,
	[Parameter(Mandatory = $true)][string]$OutDir,
	# Seconds each view stays up after "ready". Capture is frame-driven (the picture carries its own
	# view index), so 1 s -- five 200 ms polls -- is safe; it used to need 3-4 s to outrun Studio's log.
	[double]$Hold = 1,
	[int]$TimeoutSeconds = 600,
	[int]$CropLeft = 296, [int]$CropTop = 172, [int]$CropRight = 190, [int]$CropBottom = 80,
	[switch]$NoCrop,
	# Render a place built somewhere else (e.g. a session's private copy of the source tree) instead
	# of the project's own BrainRotRoyale.rbxlx -- so nobody needs a private copy of this script.
	[string]$PlaceFile = ""
)

# Two gallery runs (or a gallery and a runtest) at once would share the plugin file, window title
# and log scan, so every Studio-driving script waits for the machine-wide lock first.
. "$PSScriptRoot\studio_lock.ps1"
$what = "gallery.ps1 -Gallery $Gallery"
if ($PlaceFile -ne "") { $what += " -PlaceFile $PlaceFile" }
Enter-StudioLock $what
Assert-StudioLock

$source = if ($PlaceFile -ne "") { $PlaceFile } else { "C:\Users\oliver\Downloads\claude\brain-rot-royale\BrainRotRoyale.rbxlx" }
$pluginDir = "$env:LOCALAPPDATA\Roblox\Plugins"
$logDir = "$env:LOCALAPPDATA\Roblox\logs"
New-Item -ItemType Directory -Force $pluginDir | Out-Null
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$place = Join-Path $OutDir "BRR_Gallery.rbxlx"
# Both markers, matched on the command line: while we hold the lock, any harness Studio still open
# (of either kind) was abandoned by a run that died, and a leftover one would share this run's
# plugin, log file and window search.
Stop-StudioWindows "BRR_Gallery.rbxlx"
Stop-StudioWindows "BRR_RunTest.rbxlx"
Copy-PlaceSnapshot $source $place
$plugin = Join-Path $pluginDir "BRR_Gallery_TEMP.rbxmx"

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class BrrWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
}
"@

# Matched by THIS run's snapshot path (its OutDir is unique), never by window title: a title is set
# late, so an orphan from another run could otherwise be captured instead.
function Gallery-Process {
	$p = @(Get-StudioRunProcesses $place | Select-Object -First 1)
	if ($p.Count -eq 0) { return $null }
	return (Get-Process -Id $p[0].ProcessId -ErrorAction SilentlyContinue)
}

# A rendered 3D view is never one flat colour, so 64 identical samples mean PrintWindow handed back
# an empty frame. That happens silently, e.g. while the screen is locked or asleep and nothing is
# being composed: a whole run once saved 54 identical white PNGs, each reported as "captured".
function Test-BlankFrame($bitmap) {
	$first = $null
	for ($i = 1; $i -le 8; $i++) {
		for ($j = 1; $j -le 8; $j++) {
			$c = $bitmap.GetPixel([int]($bitmap.Width * $i / 9), [int]($bitmap.Height * $j / 9)).ToArgb()
			if ($null -eq $first) { $first = $c } elseif ($c -ne $first) { return $false }
		}
	}
	return $true
}

# The gallery plugin draws a tag in its own viewport's bottom-left corner: a magenta square with a
# green one beside it. PrintWindow on a GPU-rendered window can hand back whatever is ON SCREEN in that
# rectangle, so a capture taken while another window covers the gallery (e.g. Oliver playtesting in his
# own Studio) came back as his play session and was saved as a "view". A frame without the tag didn't
# come from the gallery and is rejected. The pair is searched for, not assumed at an exact pixel,
# because the crop margins depend on Studio's panel layout.
# Returns the VIEW INDEX the frame is showing (1..1023), 0 while the plugin is between views, or
# -1 when the frame carries no tag at all (another window on top). The index is read from ten
# black/white squares after the magenta/green pair, so a capture can never be filed under the wrong
# view's name however short the plugin holds: the picture says which view it is. (A 1.2 s hold once
# shifted a whole run one view late with nothing flagged, because capture was triggered from
# Studio's log, which flushes late, and the old tag only said "a gallery frame", not which one.)
function Get-GalleryTagIndex($bitmap) {
	$w = $bitmap.Width; $h = $bitmap.Height
	# Full width, not just the left half: with Explorer/Properties docked wide, the viewport's own
	# bottom-left corner sits well past the middle of the window.
	for ($y = $h - 1; $y -ge [int]($h / 2); $y -= 3) {
		for ($x = 0; $x -le ($w - 14 - 120); $x += 3) {
			$c = $bitmap.GetPixel($x, $y)
			if ($c.R -gt 220 -and $c.G -lt 50 -and $c.B -gt 220) {
				$g = $bitmap.GetPixel($x + 12, $y)
				if ($g.G -gt 220 -and $g.R -lt 50 -and $g.B -lt 50) {
					# Sample the centre of each 10 px index square (bit 0 first), 12 px apart from x+24.
					$index = 0
					for ($b = 0; $b -lt 10; $b++) {
						$p = $bitmap.GetPixel($x + 24 + $b * 12 + 5, $y)
						if ($p.R -gt 200 -and $p.G -gt 200 -and $p.B -gt 200) { $index = $index -bor (1 -shl $b) }
					}
					return $index
				}
			}
		}
	}
	return -1
}
function Test-GalleryTag($bitmap) { return ((Get-GalleryTagIndex $bitmap) -ge 0) }

$script:blankShots = 0
$script:lastCaptureBlank = $false
$script:wrongWindowShots = 0
$script:lastCaptureWrongWindow = $false
$script:missedShots = 0
$script:lastCaptureMissed = $false
$script:tinyWindowShots = 0
$script:lastCaptureTinyWindow = $false

# The plugin holds each view for a few seconds only. A retry (or a backlog after a window covered
# the gallery) could land after the plugin moved on, and the NEXT view would be saved under this
# view's name: tagged, so accepted, and silently mislabelled. So each attempt first checks whether a
# later view has already been announced, and gives up on this one instead.
function Get-MaxReadyIndex([string]$logPath) {
	$max = -1
	try {
		$fs = [System.IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite')
		$reader = New-Object System.IO.StreamReader($fs)
		$text = $reader.ReadToEnd()
		$reader.Close(); $fs.Close()
		foreach ($m in [regex]::Matches($text, "\[BRR_Gallery\] ready (\d+) ")) {
			$n = [int]$m.Groups[1].Value
			if ($n -gt $max) { $max = $n }
		}
	} catch {}
	return $max
}

# Returns only $true/$false. Anything else a PowerShell function writes becomes part of its return
# value, and a non-empty array would read as success, so the caller does the reporting.
function Capture-Gallery([string]$path, [int]$viewKey = -1, [string]$logPath = "") {
	$script:lastCaptureBlank = $false
	$script:lastCaptureWrongWindow = $false
	$script:lastCaptureMissed = $false
	$script:lastCaptureTinyWindow = $false
	$p = Gallery-Process
	if (-not $p) { return $false }
	$r = New-Object BrrWin+RECT
	[BrrWin]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
	$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
	if ($w -lt 200 -or $h -lt 200) {
		# Minimised or collapsed: PrintWindow would hand back a 160x28 stub, and silently skipping it
		# used to leave the run looking complete.
		$script:tinyWindowShots++
		$script:lastCaptureTinyWindow = $true
		return $false
	}
	$sawBlank = $false; $sawUntagged = $false
	# Up to ~3 s of quick retries. A frame is saved ONLY when its tag decodes to this view's index, so
	# "the plugin moved on" is read from the picture itself (index greater than ours), not from the log.
	for ($attempt = 1; $attempt -le 20; $attempt++) {
		if ($viewKey -ge 0 -and $logPath -ne "" -and (Get-MaxReadyIndex $logPath) -gt $viewKey) {
			$script:missedShots++
			$script:lastCaptureMissed = $true
			return $false
		}
		$bmp = New-Object System.Drawing.Bitmap $w, $h
		$g = [System.Drawing.Graphics]::FromImage($bmp)
		# From the screen, not PrintWindow: PrintWindow returns this window's chrome with the GPU
		# viewport unpainted -- measured 1 distinct colour against the screen grab's 68 -- so the
		# capture tag is never in the picture. Numbers in pending/gallery_screen_capture.py.
		$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
		$g.Dispose()
		$image = $bmp
		if (-not $NoCrop) {
			$cw = $w - $CropLeft - $CropRight; $ch = $h - $CropTop - $CropBottom
			$image = $bmp.Clone((New-Object System.Drawing.Rectangle $CropLeft, $CropTop, $cw, $ch), $bmp.PixelFormat)
		}
		$blank = Test-BlankFrame $image
		# The tag is read on the whole window capture, so a crop that happens to trim the corner can't
		# reject a good frame.
		$shown = if ($blank) { -1 } else { Get-GalleryTagIndex $bmp }
		$match = ($shown -eq $viewKey) -or ($viewKey -lt 0 -and $shown -gt 0)
		if ($match) {
			$image.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
		}
		if ($image -ne $bmp) { $image.Dispose() }
		$bmp.Dispose()
		if ($match) { return $true }
		if ($viewKey -ge 0 -and $shown -gt $viewKey) {
			$script:missedShots++
			$script:lastCaptureMissed = $true
			return $false
		}
		if ($blank) { $sawBlank = $true } elseif ($shown -lt 0) { $sawUntagged = $true }
		Start-Sleep -Milliseconds 150
	}
	if ($sawUntagged) {
		$script:wrongWindowShots++
		$script:lastCaptureWrongWindow = $true
	} else {
		$script:blankShots++
		$script:lastCaptureBlank = $true
	}
	return $false
}

$gallerySource = [System.IO.File]::ReadAllText((Resolve-Path $Gallery))
$lua = @'
-- TEMPORARY gallery plugin (written by tools/gallery.ps1, deleted by it too). Acts only inside the
-- gallery's own copy of the place.
if not string.find(game.Name, "BRR_Gallery", 1, true) then
	return
end
local HOLD = HOLD_SECONDS
-- True when -Hold was passed explicitly. `view.hold or HOLD` meant a gallery that hard-codes its own
-- hold SILENTLY IGNORED the flag, so a tab slowing a run down to chase a capture problem changed
-- nothing and had no way to tell. An explicit -Hold now wins; a view's own hold is still the default.
local HOLD_FORCED = HOLD_WAS_PASSED
task.delay(10, function()
	print("[BRR_Gallery] start")
	local ok, views = pcall(function()
GALLERY_SOURCE
	end)
	if not ok or type(views) ~= "table" then
		warn("[BRR_Gallery] gallery failed to load: " .. tostring(views))
		print("[BRR_Gallery] finished")
		return
	end
	-- The capture tag gallery.ps1 reads (see Get-GalleryTagIndex): magenta then green, 10 px each, in
	-- the viewport's bottom-left corner, then TEN black/white squares carrying the current view's index
	-- in binary (bit 0 nearest). The index is 0 between views and is set to N only once view N has
	-- settled, so any frame that shows N is a frame of view N -- the picture names itself, and a
	-- short hold can no longer file the next scene under this view's name.
	local indexSquares = {}
	pcall(function()
		local tag = Instance.new("ScreenGui")
		tag.Name = "BRR_GalleryTag"
		tag.IgnoreGuiInset = true
		tag.DisplayOrder = 100000
		for i, colour in ipairs({ Color3.fromRGB(255, 0, 255), Color3.fromRGB(0, 255, 0) }) do
			local square = Instance.new("Frame")
			square.BorderSizePixel = 0
			square.BackgroundColor3 = colour
			square.Size = UDim2.fromOffset(10, 10)
			square.Position = UDim2.new(0, (i - 1) * 12, 1, -12)
			square.Parent = tag
		end
		for b = 0, 9 do
			local square = Instance.new("Frame")
			square.BorderSizePixel = 0
			square.BackgroundColor3 = Color3.new(0, 0, 0)
			square.Size = UDim2.fromOffset(10, 10)
			square.Position = UDim2.new(0, 24 + b * 12, 1, -12)
			square.Parent = tag
			indexSquares[b] = square
		end
		tag.Parent = game:GetService("CoreGui")
	end)
	local function setTagIndex(n)
		for b = 0, 9 do
			local square = indexSquares[b]
			if square then
				local bit = math.floor(n / (2 ^ b)) % 2
				square.BackgroundColor3 = bit == 1 and Color3.new(1, 1, 1) or Color3.new(0, 0, 0)
			end
		end
	end
	local folder = Instance.new("Folder")
	folder.Name = "BRR_Gallery"
	folder.Parent = workspace
	local camera = workspace.CurrentCamera
	for index, view in ipairs(views) do
		setTagIndex(0)
		folder:ClearAllChildren()
		local okView, err = pcall(view.setup, folder, camera)
		if not okView then
			warn("[BRR_Gallery] view " .. tostring(view.name) .. " failed: " .. tostring(err))
		else
			-- Studio's edit camera controller takes the camera back if it is only set once, so hold it
			-- on the view's framing the whole time.
			local held, fov = camera.CFrame, camera.FieldOfView
			local focus = held * CFrame.new(0, 0, -8)
			local function hold(seconds)
				local untilTime = os.clock() + seconds
				while os.clock() < untilTime do
					camera.CFrame = held
					camera.Focus = focus
					camera.FieldOfView = fov
					if view.step then
						pcall(view.step, folder, camera)
					end
					task.wait()
				end
			end
			hold(view.settle or 1.2)
			-- Only now does the frame say "this is view N": the scene has settled, so any capture that
			-- reads N is a ready frame. (A first version of this forgot this line and every run came
			-- back with 0 shots -- the tag sat at 0 for the whole run.)
			setTagIndex(index)
			print(string.format("[BRR_Gallery] ready %03d %s", index, tostring(view.name)))
			hold(HOLD_FORCED and HOLD or (view.hold or HOLD))
		end
	end
	print("[BRR_Gallery] finished")
end)
'@
$lua = $lua.Replace("HOLD_WAS_PASSED", $(if ($PSBoundParameters.ContainsKey("Hold")) { "true" } else { "false" })).Replace("HOLD_SECONDS", [string]$Hold).Replace("GALLERY_SOURCE", $gallerySource)
$xml = "<roblox version=`"4`">`n`t<Item class=`"Script`" referent=`"RBX0`">`n`t`t<Properties>`n`t`t`t<string name=`"Name`">BRR_Gallery_TEMP</string>`n`t`t`t<ProtectedString name=`"Source`">" + $lua.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;") + "</ProtectedString>`n`t`t</Properties>`n`t</Item>`n</roblox>`n"
[System.IO.File]::WriteAllText($plugin, $xml, (New-Object System.Text.UTF8Encoding $false))

# Opening the .rbxlx with Start-Process relies on the shell's file association, which throws
# "Application not found" in a non-interactive or sandboxed shell even though Studio is installed.
# Launch the executable directly when we can find it, and fall back to the association.
function Start-StudioPlace($placePath) {
	foreach ($root in @("$env:LOCALAPPDATA\Roblox\Versions", "${env:ProgramFiles(x86)}\Roblox\Versions", "$env:ProgramFiles\Roblox\Versions")) {
		if (-not $root -or -not (Test-Path $root)) { continue }
		$exe = Get-ChildItem $root -Filter RobloxStudioBeta.exe -Recurse -ErrorAction SilentlyContinue |
			Sort-Object LastWriteTime -Descending | Select-Object -First 1
		if ($exe) { Start-Process -FilePath $exe.FullName -ArgumentList $placePath; return $exe.FullName }
	}
	Start-Process $placePath
	return "(file association)"
}
# Studio autosaves an open place every few minutes into %LOCALAPPDATA%\Roblox\RobloxStudio\AutoSaves as
# <PlaceName>_AutoRecovery_N.rbxl. This harness ends its own window with Stop-Process, so any run long enough
# to autosave leaves one behind, and from then on EVERY launch of the same place name opens with an "Auto
# Recovery File Found" dialog drawn over the middle of the viewport -- in the middle of every screenshot
# (measured 2026-09-24: a 9-minute gun gallery left BRR_Gallery_AutoRecovery_32.rbxl and the next five
# galleries all photographed the dialog; 43 such files had piled up). The dialog is not the "Auto-Recovery"
# window closed below, so it was never dismissed. These files are copies of this harness's own throwaway
# place, never anyone's work, so they are moved aside (not deleted) before launching, while the lock is held.
$autoSaveDir = Join-Path $env:LOCALAPPDATA "Roblox\RobloxStudio\AutoSaves"
$staleSaves = @(Get-ChildItem $autoSaveDir -Filter "BRR_Gallery_AutoRecovery_*" -File -ErrorAction SilentlyContinue)
if ($staleSaves.Count -gt 0) {
	$quarantine = Join-Path $env:TEMP "BRR_harness_autosaves"
	New-Item -ItemType Directory -Force $quarantine | Out-Null
	foreach ($save in $staleSaves) {
		Move-Item -LiteralPath $save.FullName -Destination (Join-Path $quarantine ((Get-Date -Format "yyyyMMdd_HHmmss") + "_" + $save.Name)) -Force
	}
	"moved $($staleSaves.Count) stale BRR_Gallery autosave(s) to $quarantine (they raise an Auto Recovery dialog over the viewport)"
}
$since = Get-Date
$studioExe = Start-StudioPlace $place

# Capture is driven by the FRAME, not the log. Every 200 ms the gallery window is grabbed and the
# view index read off its tag; the first frame of each new index is saved at once. Studio's log
# (which flushes late) only supplies each view's NAME and the finish marker, so a short hold can no
# longer cause a miss or a mislabel: by the time the log says "ready N", N is already on disk.
function Grab-GalleryFrame {
	$p = Gallery-Process
	if (-not $p) { return $null }
	$r = New-Object BrrWin+RECT
	[BrrWin]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
	$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
	if ($w -lt 200 -or $h -lt 200) { $script:tinyWindowShots++; return $null }
	$bmp = New-Object System.Drawing.Bitmap $w, $h
	$g = [System.Drawing.Graphics]::FromImage($bmp)
	# From the screen, not PrintWindow: PrintWindow returns this window's chrome with the GPU
	# viewport unpainted -- measured 1 distinct colour against the screen grab's 68 -- so the
	# capture tag is never in the picture. Numbers in pending/gallery_screen_capture.py.
	$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
	$g.Dispose()
	$index = if (Test-BlankFrame $bmp) { -2 } else { Get-GalleryTagIndex $bmp }
	$image = $bmp
	if (-not $NoCrop) {
		$cw = $w - $CropLeft - $CropRight; $ch = $h - $CropTop - $CropBottom
		$image = $bmp.Clone((New-Object System.Drawing.Rectangle $CropLeft, $CropTop, $cw, $ch), $bmp.PixelFormat)
		$bmp.Dispose()
	}
	return @{ Index = $index; Image = $image }
}

$log = $null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$seen = @{}          # note/failure lines already echoed
$names = @{}         # view index -> sanitised name, from the log
$pending = @{}       # view index -> temp file saved before its name was known
$saved = @{}         # view index -> final file
$shots = 0
$finished = $false
$finishSeen = $null
$taglessFrames = 0
$blankFrames = 0
# Roblox Studio opens a modal "Auto-Recovery" dialog when a previous Studio did not exit cleanly.
# It blocks the place from loading, so the plugin never draws its capture tag, every frame is
# legitimately untagged, and the run saves nothing -- and because a blocked run also cannot exit
# cleanly, it writes the file that re-arms the dialog for the NEXT run. Measured 2026-09-22: the
# dialog reappeared on a fresh launch even with %LOCALAPPDATA%\Roblox\AutoSaves emptied first, and
# three tabs lost days to that loop while every theory reached past it.
#
# WM_CLOSE is deliberate: it is the X button, which leaves the recovery files alone. Not "Open",
# which would load someone's recovered work into a render; not "Delete", which would throw away
# their recovery data to unblock a screenshot. Studio decides what happens to those files; the
# harness only stops the asking.
if (-not ("BrrAutoRecovery" -as [type])) {
	Add-Type @"
using System;using System.Text;using System.Runtime.InteropServices;
public class BrrAutoRecovery {
 public delegate bool EP(IntPtr h, IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EP e, IntPtr p);
 [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@
}
function Close-AutoRecoveryDialog {
	$ids = @(Get-Process -Name RobloxStudioBeta, RobloxStudio -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
	if ($ids.Count -eq 0) { return }
	$script:brrAutoRecoveryHits = @()
	$cb = [BrrAutoRecovery+EP]{ param($h, $p)
		$owner = 0
		[BrrAutoRecovery]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
		if ($ids -contains [int]$owner -and [BrrAutoRecovery]::IsWindowVisible($h)) {
			$sb = New-Object System.Text.StringBuilder 200
			[BrrAutoRecovery]::GetWindowText($h, $sb, 200) | Out-Null
			if ($sb.ToString() -eq "Auto-Recovery") { $script:brrAutoRecoveryHits += $h }
		}
		return $true }
	[BrrAutoRecovery]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
	foreach ($h in $script:brrAutoRecoveryHits) {
		[BrrAutoRecovery]::SendMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
		"closed a Studio Auto-Recovery dialog (it blocks the place from loading)"
	}
}

while ((Get-Date) -lt $deadline) {
	Start-Sleep -Milliseconds 200
	Close-AutoRecoveryDialog
	if (-not $log) {
		$log = Get-ChildItem $logDir -File -Filter "*Studio*" -ErrorAction SilentlyContinue |
			Where-Object { $_.LastWriteTime -gt $since } | Sort-Object LastWriteTime -Descending |
			Where-Object { (Select-String -Path $_.FullName -Pattern "[BRR_Gallery] start" -SimpleMatch -List) } | Select-Object -First 1
		if (-not $log) { continue }
	}
	# 1. The frame: save the first sight of each new view index, under a temp name until the log names it.
	$frame = Grab-GalleryFrame
	if ($frame) {
		$idx = [int]$frame.Index
		if ($idx -eq -2) { $blankFrames++ }
		elseif ($idx -eq -1) { $taglessFrames++ }
		elseif ($idx -ge 1 -and -not $pending.ContainsKey($idx) -and -not $saved.ContainsKey($idx)) {
			$tmp = Join-Path $OutDir ("{0:D3}_pending.png" -f $idx)
			$frame.Image.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
			$pending[$idx] = $tmp
		}
		$frame.Image.Dispose()
	}
	# 2. The log: names, notes, and the finish marker.
	$fs = [System.IO.File]::Open($log.FullName, 'Open', 'Read', 'ReadWrite')
	$reader = New-Object System.IO.StreamReader($fs)
	$text = $reader.ReadToEnd()
	$reader.Close(); $fs.Close()
	foreach ($m in [regex]::Matches($text, "\[BRR_Gallery\] ready (\d+) ([^\r\n]+)")) {
		$key = [int]$m.Groups[1].Value
		if (-not $names.ContainsKey($key)) { $names[$key] = ($m.Groups[2].Value.Trim() -replace '[^A-Za-z0-9_\-]', '_') }
	}
	foreach ($key in @($pending.Keys)) {
		if ($names.ContainsKey($key)) {
			$file = Join-Path $OutDir ("{0:D3}_{1}.png" -f $key, $names[$key])
			Move-Item -LiteralPath $pending[$key] -Destination $file -Force
			$saved[$key] = $file; $pending.Remove($key)
			$shots++; "captured $file"
		}
	}
	foreach ($m in [regex]::Matches($text, "\[BRR_Gallery\] ([^\r\n]*: \d+ parts[^\r\n]*|note [^\r\n]+|view[^\r\n]+ failed[^\r\n]*|gallery failed[^\r\n]*)")) {
		$line = $m.Groups[1].Value
		if (-not $seen.ContainsKey($line)) { $seen[$line] = $true; "  $line" }
	}
	if ($text -match "\[BRR_Gallery\] finished") {
		$finished = $true
		if (-not $finishSeen) { $finishSeen = Get-Date }
		# Give the log a few seconds to name anything already on disk, then stop.
		$allNamed = $true
		foreach ($key in $names.Keys) { if (-not $saved.ContainsKey($key)) { $allNamed = $false } }
		if ($allNamed -or ((Get-Date) - $finishSeen).TotalSeconds -gt 6) { break }
	}
}
if (-not $finished) { "timed out waiting for the gallery to finish" }
# The plugin announced views but no frame ever carried an index above 0, and the frames were neither
# blank nor tagless: the tag was drawn but never advanced. That is the plugin's setTagIndex(index)
# call missing or broken, not a capture problem -- say so, rather than listing every view as MISSED.
if ($names.Count -gt 0 -and $saved.Count -eq 0 -and $pending.Count -eq 0 -and $taglessFrames -eq 0 -and $blankFrames -eq 0) {
	"ERROR: TAG NEVER ADVANCED -- the gallery announced $($names.Count) view(s) but every captured frame read index 0. The plugin's setTagIndex(index) after settle is missing or broken (gallery.ps1's own Lua), NOT the scene. Fix the harness before re-running."
}
# A view the log announced but no frame ever showed: the plugin moved on before one 200 ms poll saw
# it (hold too short for this machine), or the window was covered for its whole hold.
foreach ($key in ($names.Keys | Sort-Object)) {
	if (-not $saved.ContainsKey($key)) {
		$script:missedShots++
		"WARNING: MISSED view $key ($($names[$key])) -- no frame carrying this view's index was ever captured; nothing was saved rather than saving the wrong scene under this name."
	}
}
foreach ($key in @($pending.Keys)) { "WARNING: frame for view index $key was captured but the log never named it; left as $($pending[$key])" }
if ($taglessFrames -gt 0) { "note: $taglessFrames frame(s) carried no gallery tag (another window on top, or the tag not yet drawn)" }
if ($blankFrames -gt 0) { "note: $blankFrames frame(s) were blank" }
"shots: $shots"
if ($script:wrongWindowShots -gt 0) { "WARNING: $($script:wrongWindowShots) view(s) captured ANOTHER window instead of the gallery and were not saved; this gallery run is incomplete." }
if ($script:blankShots -gt 0) { "WARNING: $($script:blankShots) view(s) came back BLANK and were not saved; this gallery run is incomplete." }
if ($script:missedShots -gt 0) { "WARNING: $($script:missedShots) view(s) were MISSED (the run moved on before they could be captured); this gallery run is incomplete." }
if ($script:tinyWindowShots -gt 0) { "WARNING: $($script:tinyWindowShots) view(s) found the gallery window minimised or tiny; this gallery run is incomplete." }

$galleryWindow = Gallery-Process
if ($galleryWindow) { Stop-Process -Id $galleryWindow.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep 2
[System.IO.File]::Delete($plugin)
"plugin removed: " + (-not (Test-Path $plugin))
Remove-Item "$place.lock" -ErrorAction SilentlyContinue
Exit-StudioLock
