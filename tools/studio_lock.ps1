# Machine-wide lock for every script that drives Roblox Studio (runtest.ps1, gallery.ps1, and any
# renamed copy of them). Dot-source it:
#
#   . "C:\Users\oliver\Downloads\claude\brain-rot-royale\tools\studio_lock.ps1"
#   Enter-StudioLock "gallery tools/gun_gallery.lua"
#   ... install plugin, open Studio, read logs, close only your own window ...
#   Exit-StudioLock
#
# Several Claude sessions work on this project at once. Local plugins are loaded by EVERY open
# Studio, harness logs are found by scanning files modified since launch, and the old runtest
# force-closed every Studio process, so two runs at the same time clobber each other's plugin,
# read each other's output and kill each other's windows. This serialises them.
#
# It is a named mutex, not a lock file: a run that crashes or is killed abandons the mutex and the
# next waiter takes it (measured 2026-09-16), so nothing can go stale. The owner file is only
# informational -- it tells a waiter who it is waiting for.
#
# First come, first served (2026-09-17). A mutex hands itself to whichever waiter happens to wake
# first, and with ~35 runs queued, runs from an hour earlier kept losing to new ones. Each waiter
# now drops a ticket in .studio_queue ("<utc ticks>_<pid>.txt", holding that process's start time)
# and only the OLDEST live ticket tries the mutex. A ticket whose process has gone (killed, crashed,
# or a recycled pid with a different start time) is skipped and removed by the next waiter, so a
# dead run can't block the queue. Runs started from an older copy of this file don't take tickets
# and still compete for the mutex directly; that only costs order, never safety.

# The queue and owner file live with the PROJECT's tools, never beside a scratch copy of this script:
# a tree copy with its own .studio_queue would see only its own ticket and jump the shared queue.
$script:StudioToolsDir = "C:\Users\oliver\Downloads\claude\brain-rot-royale\tools"
if (-not (Test-Path $script:StudioToolsDir)) { $script:StudioToolsDir = $PSScriptRoot }
$script:StudioLockOwnerFile = Join-Path $script:StudioToolsDir ".studio_lock_owner.txt"
$script:StudioQueueDir = Join-Path $script:StudioToolsDir ".studio_queue"
$script:StudioMutexName = "Local\BRR_StudioRun"
$script:StudioMutex = $null
$script:StudioLockHeld = $false

function Test-StudioTicketLive($Ticket) {
	$parts = $Ticket.BaseName -split '_'
	if ($parts.Count -ne 2) { return $false }
	# A foreign file in the queue folder must never throw here: an error inside Enter-StudioLock
	# would let the caller carry on WITHOUT the lock.
	if ($parts[1] -notmatch '^\d{1,9}$') { return $false }
	# Nobody waits longer than the longest timeout; an older ticket is debris whatever its pid says.
	if (((Get-Date) - $Ticket.LastWriteTime).TotalHours -gt 12) { return $false }
	$owner = Get-Process -Id ([int]$parts[1]) -ErrorAction SilentlyContinue
	if (-not $owner) { return $false }
	# Every waiter is one of Oliver's PowerShell runs. A recycled pid belonging to anything else (a
	# service, an elevated process) is debris: treating it as live once stalled the whole queue.
	if ($owner.ProcessName -notin @("powershell", "pwsh")) { return $false }
	$started = Get-Content $Ticket.FullName -TotalCount 1 -ErrorAction SilentlyContinue
	try {
		return ($owner.StartTime.ToUniversalTime().Ticks.ToString() -eq "$started".Trim())
	} catch {
		# Can't read that process's start time: it isn't one of ours, so don't let it hold the queue.
		return $false
	}
}

function Enter-StudioLock([string]$What, [int]$TimeoutMinutes = 360) {
	$script:StudioMutex = New-Object System.Threading.Mutex($false, $script:StudioMutexName)
	$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
	New-Item -ItemType Directory -Force $script:StudioQueueDir | Out-Null
	$name = "{0:D19}_{1}" -f [DateTime]::UtcNow.Ticks, $PID
	$ticket = Join-Path $script:StudioQueueDir "$name.txt"
	$ticketLines = @((Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString(), $What)
	# Written aside and moved in, so a reader never sees a ticket without its start time.
	$writeTicket = {
		New-Item -ItemType Directory -Force $script:StudioQueueDir | Out-Null
		$tmp = Join-Path $script:StudioQueueDir "$name.tmp"
		$ticketLines | Set-Content $tmp -Encoding utf8
		Move-Item $tmp $ticket -Force
	}
	& $writeTicket
	$lastAhead = -1
	$lastSaid = Get-Date
	try {
		while ($true) {
			if (-not (Test-Path $ticket)) { & $writeTicket }
			$ahead = 0
			foreach ($other in @(Get-ChildItem $script:StudioQueueDir -Filter *.txt -ErrorAction SilentlyContinue | Sort-Object Name)) {
				if ($other.Name -eq "$name.txt") { break }
				if (Test-StudioTicketLive $other) {
					$ahead++
				} else {
					Remove-Item $other.FullName -ErrorAction SilentlyContinue
				}
			}
			$got = $false
			if ($ahead -eq 0) {
				try {
					$got = $script:StudioMutex.WaitOne(5000)
				} catch {
					# A holder that died abandons the mutex; WaitOne then throws but we DO own it.
					$e = $_.Exception
					while ($e) {
						if ($e -is [System.Threading.AbandonedMutexException]) { $got = $true }
						$e = $e.InnerException
					}
					if (-not $got) { throw }
				}
			} else {
				Start-Sleep -Seconds 5
			}
			if ($got) { break }
			# Print on every change of position, and at least every 5 minutes so a stalled queue is
			# visible instead of silent.
			if ($ahead -ne $lastAhead -or ((Get-Date) - $lastSaid).TotalMinutes -ge 5) {
				$holder = Get-Content $script:StudioLockOwnerFile -Raw -ErrorAction SilentlyContinue
				"studio lock busy -- $ahead queued ahead of this run; running now: $holder"
				$lastAhead = $ahead
				$lastSaid = Get-Date
			}
			if ((Get-Date) -gt $deadline) {
				throw "studio lock: still busy after $TimeoutMinutes minutes, giving up"
			}
		}
	} finally {
		Remove-Item $ticket -ErrorAction SilentlyContinue
	}
	$script:StudioLockHeld = $true
	"$What | pid $PID | since $(Get-Date -Format 'HH:mm:ss')" | Set-Content $script:StudioLockOwnerFile -Encoding utf8
	"studio lock acquired: $What"
}

# Callers must check this straight after Enter-StudioLock: a non-throwing error inside the wait loop
# would otherwise let a run drive Studio with no lock held, killing the real holder's window.
function Assert-StudioLock {
	if (-not $script:StudioLockHeld) {
		throw "studio lock was NOT acquired (Enter-StudioLock failed without throwing); refusing to drive Studio"
	}
}

function Exit-StudioLock {
	# The owner file goes first: releasing first lets the next holder write its own line, which this
	# Remove-Item would then delete.
	Remove-Item $script:StudioLockOwnerFile -ErrorAction SilentlyContinue
	if ($script:StudioMutex) {
		try { $script:StudioMutex.ReleaseMutex() } catch {}
		$script:StudioMutex.Dispose()
		$script:StudioMutex = $null
	}
	$script:StudioLockHeld = $false
	"studio lock released"
}

# Copies the built place for a harness run to open privately, so a rebuild during the run can't
# touch it and Oliver's own Studio (which has the real BrainRotRoyale.rbxlx open) is never used.
# Retries until the copy is a complete document in case a build is mid-write.
function Copy-PlaceSnapshot([string]$Source, [string]$Destination) {
	New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
	for ($attempt = 1; $attempt -le 20; $attempt++) {
		try {
			Copy-Item $Source $Destination -Force -ErrorAction Stop
			$fs = [System.IO.File]::OpenRead($Destination)
			try {
				$len = [Math]::Min(64, $fs.Length)
				$fs.Seek(-$len, 'End') | Out-Null
				$buf = New-Object byte[] $len
				$fs.Read($buf, 0, $len) | Out-Null
			} finally {
				$fs.Close()
			}
			if ([System.Text.Encoding]::UTF8.GetString($buf) -match "</roblox>\s*$") { return }
		} catch {}
		Start-Sleep 1
	}
	throw "could not take a complete snapshot of $Source"
}

# Studio windows are separate processes, and a window TITLE is set late: a Studio that is still
# loading (Oliver's own, or its Start Server / Start Players helpers) has an EMPTY title. Matching on
# the title therefore risked killing his Studio, so every match here is on the place path that
# Studio was launched with, which is set at birth and never changes.
function Get-StudioRunProcesses([string]$PathMarker) {
	return @(Get-CimInstance Win32_Process -Filter "Name='RobloxStudioBeta.exe'" -ErrorAction SilentlyContinue |
		Where-Object { $_.CommandLine -and $_.CommandLine -like "*$PathMarker*" })
}

# Close only harness windows: pass the snapshot's file name (BRR_RunTest.rbxlx / BRR_Gallery.rbxlx)
# or a full snapshot path. Safe while the lock is held, since any harness window still open then was
# abandoned by a run that died.
function Stop-StudioWindows([string]$PathMarker) {
	foreach ($p in Get-StudioRunProcesses $PathMarker) {
		Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
		"closed leftover/finished harness Studio: pid $($p.ProcessId)"
	}
}
