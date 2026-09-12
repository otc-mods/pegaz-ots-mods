-- HP tab: healing spells, potions, mana shield, haste, anti-paralyze, food.
-- Storage keys are the stock cavebot_1.3 ones, so existing thresholds carry over.
setDefaultTab("HP")

local function pct(cur, max) return math.min(100, math.floor(100 * (cur / math.max(1, max)))) end

local tabPanel = panel
local function section(id, title) panel = UI.section(id, title, tabPanel) end
local function endSection() panel = tabPanel end

-- healing spells ---------------------------------------------------------------
section("hpSpells", "Healing spells")
if type(storage.healing1) ~= "table" then storage.healing1 = {on=false, title="HP%", text="exura", min=51, max=90} end
if type(storage.healing2) ~= "table" then storage.healing2 = {on=false, title="HP%", text="exura vita", min=0, max=50} end

local spellRows = {}
for _, info in ipairs({storage.healing1, storage.healing2}) do
  local row = { params = info }
  row.macro = macro(20, function()
    local hp = player:getHealthPercent()
    if info.max >= hp and hp >= info.min then
      if TargetBot then TargetBot.saySpell(info.text) else say(info.text) end
    end
  end)
  row.macro.setOn(info.on)
  UI.DualScrollPanel(info, function(widget, newParams)
    info = newParams
    row.params = newParams
    row.macro.setOn(newParams.on)
  end)
  row.widget = panel:getLastChild() -- the stock builder returns nothing
  table.insert(spellRows, row)
end

local function setRows(rows, v, valid)
  local turnedOn = 0
  for _, row in ipairs(rows) do
    local want = v and valid(row.params) and true or false
    if want then turnedOn = turnedOn + 1 end
    row.params.on = want
    row.widget.title:setOn(want)
    row.macro.setOn(want)
  end
  if v and turnedOn == 0 then warn("Nothing to enable: configure a spell / potion on the HP tab first") end
end
local function anyOn(rows)
  for _, row in ipairs(rows) do if row.params.on then return true end end
  return false
end

Features.register{ id = "healSpells", order = 1, name = "Heal spells", group = "HP",
  isOn = function() return anyOn(spellRows) end,
  setOn = function(v) setRows(spellRows, v, function(p) return p.text and p.text:len() > 0 end) end }

-- potions -------------------------------------------------------------------------
endSection()
section("hpPotions", "Potions")
if type(storage.hpitem1) ~= "table" then storage.hpitem1 = {on=false, title="HP%", item=266, min=51, max=90} end
if type(storage.hpitem2) ~= "table" then storage.hpitem2 = {on=false, title="HP%", item=3160, min=0, max=50} end
if type(storage.manaitem1) ~= "table" then storage.manaitem1 = {on=false, title="MP%", item=268, min=51, max=90} end
if type(storage.manaitem2) ~= "table" then storage.manaitem2 = {on=false, title="MP%", item=3157, min=0, max=50} end

local potionRows = {}
for i, info in ipairs({storage.hpitem1, storage.hpitem2, storage.manaitem1, storage.manaitem2}) do
  local row = { params = info }
  row.macro = macro(20, function()
    if Hunt.isEquipPending() then return end -- ring swap in flight, don't fight it for the "use" slot
    local v = i <= 2 and player:getHealthPercent() or pct(player:getMana(), player:getMaxMana())
    if info.max >= v and v >= info.min then
      if TargetBot then
        TargetBot.useItem(info.item, info.subType, player)
      else
        g_game.useInventoryItemWith(info.item, player, info.subType or 0)
      end
    end
  end)
  row.macro.setOn(info.on and info.item > 100)
  UI.DualScrollItemPanel(info, function(widget, newParams)
    info = newParams
    row.params = newParams
    row.macro.setOn(newParams.on and newParams.item > 100)
  end)
  row.widget = panel:getLastChild()
  table.insert(potionRows, row)
end

Features.register{ id = "potions", order = 2, name = "Potions", group = "HP",
  isOn = function() return anyOn(potionRows) end,
  setOn = function(v) setRows(potionRows, v, function(p) return p.item and p.item > 100 end) end }

endSection()
section("hpSupport", "Support & food")

-- support spells (same macro names as before, so on/off state carries over) ----------
storage.manaShield = storage.manaShield or "utamo vita"
storage.hasteSpell = storage.hasteSpell or "utani hur"
storage.antiParalyze = storage.antiParalyze or "utani hur"

-- returns false only when the spell was actually refused, so a caller can retry instead of pretending it cast
local blockedSince = {}
local function cast(text, key)
  if not TargetBot then say(text) return true end
  if TargetBot.saySpell(text) ~= false then
    if key then blockedSince[key] = nil end
    return true
  end
  if not key then return false end
  -- the targetbot talks constantly; after 3s of losing that race, say it anyway
  blockedSince[key] = blockedSince[key] or now
  if now - blockedSince[key] < 3000 then return false end
  say(text)
  blockedSince[key] = nil
  return true
end

-- Mana shield used to be recast only after it had already dropped, so every lapse cost one unshielded hit.
-- It now measures its own length the first time it runs out and recasts a few seconds before that.
local msCast, msDuration, msWasUp = 0, nil, false
local manaShieldMacro = macro(200, "mana shield", function()
  local up = hasManaShield()
  if msWasUp and not up and msCast > 0 then
    local d = now - msCast
    if d > 5000 and d < 900000 then msDuration = d end
  end
  msWasUp = up
  local margin = math.min(8000, math.max(3000, (msDuration or 0) * 0.15))
  local due = msDuration and (now - msCast >= msDuration - margin)
  if (not up or due) and now - msCast >= 2200 then
    if cast(storage.manaShield, "manaShield") then msCast = now end
  end
end)
Features.register{ id = "manaShield", order = 4, name = "Mana shield", group = "HP", macro = manaShieldMacro }

local hasteMacro = macro(500, "haste", function()
  if hasHaste() then return end
  cast(storage.hasteSpell)
end)
Features.register{ id = "haste", order = 6, name = "Haste", group = "HP", macro = hasteMacro }

local antiParalyzeMacro = macro(100, "anti paralyze", function()
  if not isParalyzed() then return end
  cast(storage.antiParalyze)
end)
Features.register{ id = "antiParalyze", order = 3, name = "Anti-paralyze", group = "HP", macro = antiParalyzeMacro }

-- food ----------------------------------------------------------------------------
if type(storage.foodItems) ~= "table" then storage.foodItems = {3582, 3577} end

local foodMacro = macro(10000, "eat food", function()
  if not storage.foodItems[1] then return end
  for _, container in pairs(g_game.getContainers()) do
    for __, item in ipairs(container:getItems()) do
      for _, food in ipairs(storage.foodItems) do
        if item:getId() == food.id then return g_game.use(item) end
      end
    end
  end
  local toEat = storage.foodItems[math.random(1, #storage.foodItems)]
  if toEat then g_game.useInventoryItem(toEat.id) end
end)
Features.register{ id = "eatFood", name = "Eat food", group = "Other", macro = foodMacro }

-- rarely changed: spell texts and food list -------------------------------------------
local saveQueued = false
local function persist()                 -- storage is only written on save(); an edit must not wait for one
  if saveQueued then return end
  saveQueued = true
  schedule(1500, function()
    saveQueued = false
    pcall(function() modules.game_bot.save() end)
  end)
end

UI.Button("Spell words & food...", function()
  UI.popup("HP settings", 280, function(content)
    UI.LabelAndTextEdit({left = "Mana shield", right = storage.manaShield}, function(w, p) storage.manaShield = p.right persist() end, content)
    UI.LabelAndTextEdit({left = "Haste", right = storage.hasteSpell}, function(w, p) storage.hasteSpell = p.right persist() end, content)
    UI.LabelAndTextEdit({left = "Anti-paralyze", right = storage.antiParalyze}, function(w, p) storage.antiParalyze = p.right persist() end, content)
    UI.Label("Food items (drag in):", content)
    local food = UI.Container(function(widget, items) storage.foodItems = items end, true, content)
    food:setHeight(70)
    food:setItems(storage.foodItems)
  end)
end)

endSection()
