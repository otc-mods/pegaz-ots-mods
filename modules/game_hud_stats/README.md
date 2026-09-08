# game_hud_stats

Stats mini-window for OTClientV8 (3.x): Next Level ETA, Exp/H, Raw Exp/H (server rate from `!serverinfo`),
DPS, HPS, MPS, Damage received/s, Kills - each with current / session max / lifetime max and a 15-minute graph.

## Install

1. Unzip into the client's `modules/` folder (you should get `modules/game_hud_stats/`).
2. Restart the client. The window appears in the second left panel (or the first one), with a
   "Stats" toggle button in the top menu.

## Controls

- Left-click a section header: collapse / expand it. Right-click: hide / show only its graph.
- Graphs button: all graphs on / off. Color dots: theme for headers and graph lines.
- Reset session / Reset lifetime (asks for confirmation). Hover `(?)` for the same summary in-game.

## Server-specific bits (top of `hudstats.lua`)

- `DAMAGE_PATTERNS`, `DAMAGE_RECEIVED_PATTERNS`: Server Log wording (TFS English defaults).
- `SERVERINFO_COMMAND` / `SERVERINFO_PATTERN`: how the exp rate is asked and parsed.
- `EXP_STAGES`: fallback stage table if the server has no `!serverinfo`.
- `KILL_SOURCE`: `"health"` (monster on screen drops to 0%) or `"messages"` (loot lines).

Lifetime records are stored per character in the client's `config.otml` under `hudStats`.
