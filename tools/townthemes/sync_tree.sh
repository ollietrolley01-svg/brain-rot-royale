#!/bin/bash
# TownThemes is ASSEMBLED, not authored: ServerScriptService/Modules/TownThemes.lua is the
# concatenation of the parts in this folder, in this order:
#
#   core.lua.part            requires, colours, the Kit builder, shared Pieces, the springs
#   pieces_*.lua.part        shared district pieces (fences, chain-link, bay markings...), name order
#   themes_a..f.lua.part     the eighteen themes, in name order of the files
#   placement.lua.part       taglines, siting, pads, flags, props, districts, Build / BuildAll
#
# Edit the PARTS and run this; never edit the assembled file (the next sync overwrites it silently).
# The parts are *.lua.part, not *.lua, on purpose: verify.py and lua_static_check.py walk the whole
# tree for *.lua and half a module reports dozens of undeclared names. The assembled module is the
# thing the checks read.
#
#   tools/townthemes/sync_tree.sh                 assemble -> ServerScriptService/Modules/TownThemes.lua
#   tools/townthemes/sync_tree.sh check           assemble to a temp file and compare byte for byte with
#                                                 the landed module (exit 1 on any difference)
#   tools/townthemes/sync_tree.sh tree <dir> [pads]
#                                                 assemble, then copy the project into <dir>, inject the
#                                                 TownThemes hook into that copy's MapGenerator (hook.py;
#                                                 "pads" adds the private FlattenPad stand-in) and build a
#                                                 private place there for runtest.ps1 -PlaceFile. The
#                                                 shared project is never touched by this mode.
set -e
D="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$D/../.." && pwd)"
LANDED="$P/ServerScriptService/Modules/TownThemes.lua"

parts=("$D/core.lua.part")
for f in $(ls "$D"/pieces_*.lua.part 2>/dev/null | sort); do parts+=("$f"); done
for f in $(ls "$D"/themes_*.lua.part | sort); do parts+=("$f"); done
parts+=("$D/placement.lua.part")

assemble() {
  cat "${parts[@]}" > "$1"
}

md5of() {
  md5sum "$1" | cut -d' ' -f1
}

case "$1" in
  check)
    tmp="$(mktemp)"
    assemble "$tmp"
    echo "parts:     $(md5of "$tmp")  ($(wc -c < "$tmp") bytes, ${#parts[@]} parts)"
    echo "landed:    $(md5of "$LANDED")  ($(wc -c < "$LANDED") bytes)"
    if cmp -s "$tmp" "$LANDED"; then
      echo "IDENTICAL: the parts assemble byte for byte to the landed TownThemes.lua"
      rm -f "$tmp"
    else
      echo "DIFFERENT: first differing byte: $(cmp "$tmp" "$LANDED" 2>&1 | head -1)"
      diff "$tmp" "$LANDED" | head -20
      rm -f "$tmp"
      exit 1
    fi
    ;;
  tree)
    T="$2"
    [ -n "$T" ] || { echo "usage: sync_tree.sh tree <dir> [pads]"; exit 2; }
    before="$(md5of "$LANDED")"
    assemble "$LANDED"
    echo "assembled TownThemes.lua: $before -> $(md5of "$LANDED")"
    rm -rf "$T"; mkdir -p "$T"
    cp -r "$P/ReplicatedStorage" "$P/ServerScriptService" "$P/StarterPlayerScripts" "$P/build_place.py" "$P/default.project.json" "$T/"
    [ -d "$P/StarterGui" ] && cp -r "$P/StarterGui" "$T/"
    python "$D/hook.py" "$T/ServerScriptService/Modules/MapGenerator.lua" $3
    (cd "$T" && python build_place.py . > /dev/null) && echo "built $T/BrainRotRoyale.rbxlx ($(wc -c < "$T/BrainRotRoyale.rbxlx") bytes) with the TownThemes hook ($([ "$3" = "pads" ] && echo 'pads stand-in' || echo 'no pads stand-in'))"
    ;;
  "")
    before="$(md5of "$LANDED")"
    assemble "$LANDED"
    echo "assembled TownThemes.lua: $before -> $(md5of "$LANDED") ($(wc -c < "$LANDED") bytes)"
    ;;
  *)
    echo "usage: sync_tree.sh [check | tree <dir> [pads]]"; exit 2
    ;;
esac
