# Publishes BrainRotRoyale.rbxlx to an existing Roblox experience through the Open Cloud API,
# so the newest build can be played on a phone without opening Studio.
#
# One-time setup (all on create.roblox.com, logged in as you):
#   1. Create the experience once: in Studio, File -> Publish to Roblox As... (or Creator
#      Dashboard -> Create). Note its Universe ID and the start Place ID (both on the Creator
#      Dashboard: Creations -> your experience -> the numbers in the URL / the Places page).
#   2. Creator Dashboard -> Open Cloud -> API Keys -> Create: add the "Place Management" API
#      system with "Write" permission, scoped to that experience. Copy the key.
#   3. In this terminal, set it as an environment variable for the session (never paste it into
#      a file):  $env:ROBLOX_API_KEY = "..."
#
# Then:  powershell -ExecutionPolicy Bypass -File tools/publish.ps1 -UniverseId 123 -PlaceId 456
# Add -Saved to upload without publishing (a new saved version you can publish from Studio later).
param(
	[Parameter(Mandatory = $true)][long]$UniverseId,
	[Parameter(Mandatory = $true)][long]$PlaceId,
	[switch]$Saved
)

$key = $env:ROBLOX_API_KEY
if (-not $key) {
	Write-Error "Set `$env:ROBLOX_API_KEY first (Creator Dashboard -> Open Cloud -> API Keys, Place Management: Write)."
	exit 1
}

$place = Join-Path (Split-Path -Parent $PSScriptRoot) "BrainRotRoyale.rbxlx"
if (-not (Test-Path $place)) {
	Write-Error "Build the place first: python build_place.py ."
	exit 1
}

$versionType = if ($Saved) { "Saved" } else { "Published" }
$url = "https://apis.roblox.com/universes/v1/$UniverseId/places/$PlaceId/versions?versionType=$versionType"
# Open Cloud rejects a leading <?xml ...?> declaration with 400 "Invalid Content stream"
# (found 2026-09-23), and build_place.py writes one, so send the document from <roblox onward.
$xml = [System.IO.File]::ReadAllText($place)
$xml = $xml.Substring($xml.IndexOf("<roblox"))
$bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($xml)
"Uploading $([Math]::Round($bytes.Length / 1MB, 1)) MB as $versionType..."

try {
	$response = Invoke-RestMethod -Method Post -Uri $url -Headers @{ "x-api-key" = $key } -ContentType "application/xml" -Body $bytes
	"Done: version $($response.versionNumber) is $versionType."
	if (-not $Saved) {
		"Open the Roblox app on your phone -> your avatar/profile -> Creations (or search the experience name) -> Play."
	}
} catch {
	Write-Error ("Upload failed: " + $_.Exception.Message)
	if ($_.ErrorDetails) { $_.ErrorDetails.Message }
	exit 1
}
