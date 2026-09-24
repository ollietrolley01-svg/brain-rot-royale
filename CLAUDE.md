# Working on Brain Rot Royale with Claude

## Usage budget (Oliver, 2026-09-24)
- Run at most 1-2 subagents at a time.
- Routine fixes and checks go to Sonnet (or Haiku for pure lookups). Opus is for hard problems only.
- No competitions or referee passes unless Oliver asks for one.
- Give each agent a specific task with named files. Never "sweep everything".
- Don't read the huge modules whole (BotService.lua, HudClient.client.lua, CombatClient.client.lua). Grep, then read the lines you need.
- Start a fresh session for each new batch of work.

## Checks
- `pip install lupa`, then `python3 tools/quality_gate.py` (full gate; add `--timeout-scale 3` on a loaded machine).
- Fast set: `tools/verify.py .`, `tools/balance.py .`, `tools/lua_static_check.py`, `tools/local_limit_check.py`, `tools/clock_ratchet.py .`.
- Build a playtest: `python3 build_place.py .` → `BrainRotRoyale.rbxlx` (git-ignored).
