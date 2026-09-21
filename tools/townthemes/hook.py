import sys

# hook.py <MapGenerator.lua> [pads]
#   pads: also give MapTerrain a PRIVATE stand-in FlattenPad (this test tree only) until claude-79's
#   real one lands, so the pad path in TownThemes can be exercised.
path = sys.argv[1]
pads = len(sys.argv) > 2 and sys.argv[2] == "pads"
source = open(path, encoding="utf-8").read()
anchor = "\t-- The river's line for the minimap"
assert source.count(anchor) == 1, "anchor not found once"
standin = (
    "\tif not MapTerrain.FlattenPad then\n"
    "\t\t-- PRIVATE TEST STAND-IN (the Cities tab's private tree only): cut/fill the rectangle flat at cframe.Y.\n"
    "\t\tMapTerrain.FlattenPad = function(cframe, size, options)\n"
    "\t\t\tlocal margin = options and options.margin or 0\n"
    "\t\t\tlocal material = options and options.material or Enum.Material.Ground\n"
    "\t\t\tlocal top = cframe.Position.Y - MapTerrain.SurfaceLift\n"
    "\t\t\tlocal extent = Vector3.new(size.X + margin * 2, 40, size.Z + margin * 2)\n"
    "\t\t\tworkspace.Terrain:FillBlock(CFrame.new(cframe.Position.X, top + 20, cframe.Position.Z) * cframe.Rotation, extent, Enum.Material.Air)\n"
    "\t\t\tworkspace.Terrain:FillBlock(CFrame.new(cframe.Position.X, top - 5, cframe.Position.Z) * cframe.Rotation, Vector3.new(extent.X, 10, extent.Z), material)\n"
    "\t\t\treturn cframe.Position.Y\n"
    "\t\tend\n"
    "\tend\n"
) if pads else ""
hook = (
    standin +
    # Wall clock, not os.clock(): in Roblox os.clock() is process CPU time and a build is mostly
    # yielding, so it under-reads by whatever the yields cost (COORDINATION.md, measured lessons).
    "\tlocal themeStart = DateTime.now().UnixTimestampMillis\n"
    "\tlocal TownThemes = require(script.Parent:WaitForChild(\"TownThemes\"))\n"
    "\tlocal themed = TownThemes.Build(map, space, MapGenerator.GroundHeightAt, preset)\n"
    "\tmap:SetAttribute(\"ThemeParts\", themed.parts)\n"
    "\tmap:SetAttribute(\"ThemeSeconds\", (DateTime.now().UnixTimestampMillis - themeStart) / 1000)\n"
    "\ttask.wait()\n\n"
)
source = source.replace(anchor, hook + anchor)
open(path, "w", encoding="utf-8", newline="\n").write(source)
