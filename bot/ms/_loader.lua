-- rp config: single entry point, fixed load order.
-- core/     registry (features + presets), hunting state, UI helpers
-- features/ heal (HP tab), targeting (top of Target tab), equip + tools (Tools tab), main (built last, from the registry)
-- cavebot/ targetbot/  engines (targetbot carries the lure / priority / pathing / attack-mode patches)
VERSION = "rp 2.0"

importStyle("/core/ui.otui")
dofile("/vocation.lua")          -- per-vocation defaults, seeded only when unset
dofile("/core/registry.lua")
dofile("/core/hunt.lua")
dofile("/core/ui.lua")

dofile("/features/heal.lua")
dofile("/core/engines.lua")
dofile("/features/buff.lua")   -- Buffs section on the Target tab (damage buffs)
dofile("/features/equip.lua") -- top of the Tools tab (a 6th tab would shrink the tab font)
dofile("/features/tools.lua")
dofile("/features/icons.lua")
dofile("/features/main.lua")
