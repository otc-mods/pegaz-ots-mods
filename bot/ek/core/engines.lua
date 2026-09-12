-- Cavebot + TargetBot engines (stock cavebot 1.3 layout of dofiles), registered as features.
local cavebotTab = "Cave"
local targetingTab = "Target"

setDefaultTab(cavebotTab)
CaveBot = {} -- global namespace
CaveBot.Extensions = {}
importStyle("/cavebot/cavebot.otui")
importStyle("/cavebot/config.otui")
importStyle("/cavebot/editor.otui")
importStyle("/cavebot/supply.otui")
dofile("/cavebot/actions.lua")
dofile("/cavebot/config.lua")
dofile("/cavebot/editor.lua")
dofile("/cavebot/example_functions.lua")
dofile("/cavebot/recorder.lua")
dofile("/cavebot/walking.lua")
-- extensions, see extension_template.lua
dofile("/cavebot/depositer.lua")
dofile("/cavebot/supply.lua")
-- main cavebot file, must be last
dofile("/cavebot/cavebot.lua")

setDefaultTab(targetingTab)
local targetTabPanel = panel
TargetBot = {} -- global namespace
importStyle("/targetbot/looting.otui")
importStyle("/targetbot/target.otui")
importStyle("/targetbot/creature_editor.otui")
dofile("/targetbot/creature.lua")
dofile("/targetbot/creature_attack.lua")
dofile("/targetbot/creature_editor.lua")
dofile("/targetbot/creature_priority.lua")
panel = UI.section("targetLooting", "Looting", targetTabPanel)
dofile("/targetbot/looting.lua")
panel = targetTabPanel
dofile("/targetbot/walking.lua")
-- main targetbot file, must be last
dofile("/targetbot/target.lua")
dofile("/features/targeting.lua") -- attack mode selector + AoE safety, placed right under the config selector

-- "All" is the whole engine block at once: both bots and the attack spells with them
Features.register{ id = "allEngines", name = "All", group = "Engine", order = 1,
  -- green only when the whole block is running: both engines and the attack spells
  isOn = function()
    return CaveBot.isOn() and TargetBot.isOn() and (not Hunt or Hunt.spellsOn())
  end,
  setOn = function(v)
    CaveBot.setOn(v)
    TargetBot.setOn(v)
    if Hunt and Hunt.setSpellsOn then Hunt.setSpellsOn(v) end
  end }
Features.register{ id = "cavebot", name = "Cavebot", group = "Engine", order = 3,
  isOn = function() return CaveBot.isOn() end, setOn = function(v) CaveBot.setOn(v) end }
Features.register{ id = "targetbot", name = "Targeting", group = "Engine", order = 4,
  isOn = function() return TargetBot.isOn() end, setOn = function(v) TargetBot.setOn(v) end }
