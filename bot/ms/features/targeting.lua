-- Target tab: attack mode selector and AoE player safety. Targetbot on/off is the config switch right above.
-- Loaded after targetbot/target.lua, then moved to sit right under the config selector (child 1).
local MODES = { {id = "aoe", text = "AoE"}, {id = "single", text = "Single"}, {id = "rule", text = "Rule"} }

local tabPanel = panel
local attackBody, attackHeader = UI.section("targetAttack", "Attack", tabPanel)
panel = attackBody

local spellSwitch = addSwitch("attackSpells", "Attack spells", function(widget)
  Hunt.setSpellsOn(not Hunt.spellsOn())
  widget:setOn(Hunt.spellsOn())
end)
spellSwitch:setOn(Hunt.spellsOn())
Features.register{ id = "attackSpells", name = "Spells", group = "Engine", order = 2,
  isOn = function() return Hunt.spellsOn() end,
  setOn = function(v) Hunt.setSpellsOn(v) spellSwitch:setOn(v) end }

local modeRow = UI.buttonRow({MODES[1].text, MODES[2].text, MODES[3].text})
for i, b in ipairs(modeRow.buttons) do
  b.onClick = function() Hunt.setAttackMode(MODES[i].id) end
end
modeRow.buttons[1]:setTooltip("Group spell when enough monsters and no player in the safe range, else the single spell")
modeRow.buttons[2]:setTooltip("Single-target spell only")
modeRow.buttons[3]:setTooltip("The 'Use ... attack spell' boxes of each creature rule decide (stock behaviour)")

local rangeRow = UI.scrollRow("AoE safe range (sqm)", 0, 8, Hunt.aoeSafeRange(), function(v) Hunt.setAoeSafeRange(v) end)
panel = tabPanel

-- This file runs last, so it is the only place that can order the whole tab: looting is built first (it is
-- dofile'd before the target list) and belongs at the bottom, our attack controls belong right under the
-- config selector.
pcall(function()
  local lootBody, lootHeader = UI.section("targetLooting", "Looting", tabPanel)
  if lootHeader then
    local n = tabPanel:getChildCount()
    tabPanel:moveChildToIndex(lootHeader, n - 1)
    tabPanel:moveChildToIndex(lootBody, n)
  end
  tabPanel:moveChildToIndex(attackHeader, 2)
  tabPanel:moveChildToIndex(attackBody, 3)
  -- the engine's own status block (Status/Target/Config/Danger + target editor) is part of attacking, so it
  -- goes inside the section instead of floating underneath it
  local status = tabPanel:recursiveGetChildById('status')
  local block = status and status:getParent()
  while block and block:getParent() ~= tabPanel do block = block:getParent() end
  if block then block:setParent(attackBody) end
end)

macro(500, function()
  UI.fitButtonRow(modeRow)
  for i, b in ipairs(modeRow.buttons) do UI.pick(b, MODES[i].id == Hunt.attackMode()) end
end)
